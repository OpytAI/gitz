//! Filesystem object storage (go-git `storage/filesystem/object.go` subset).
//!
//! Loose objects via DotGit + objfile. Pack path: requireIndex loads pack idx
//! files into `Hash → *MemoryIndex`, then getFromPackfile seeks via Packfile
//! (full pack image in memory). PackfileWriter Notify injects the live idx;
//! KeepDescriptors / MaxOpenDescriptors retain pack images in `packfiles`.
//!
//! Monomorphised over `Fs` (`Mem` / `Os`): `ObjectStorageFor(Fs)`.

const std = @import("std");
const plumbing = @import("plumbing");
const objfile = @import("objfile");
const cache_pkg = @import("cache");
const fs_pkg = @import("fs");
const idxfile = @import("idxfile");
const packfile = @import("packfile");

const dotgit = @import("dotgit");
const deltaobject = @import("deltaobject.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ObjectType = plumbing.ObjectType;
const MemoryObject = plumbing.MemoryObject;
const ObjectLru = cache_pkg.ObjectLru;
const MemoryIndex = idxfile.MemoryIndex;

pub const Options = struct {
    exclusive_access: bool = false,
    keep_descriptors: bool = false,
    max_open_descriptors: i32 = 0,
    /// go-git `LargeObjectThreshold`: max plaintext size (bytes) that may enter
    /// the object cache. `0` = no limit (every object is cache-eligible).
    /// Objects larger than the threshold are still returned as `*MemoryObject`
    /// (Zig storer surface is concrete, not an EncodedObject interface) but are
    /// **not** inserted into `object_cache` (go-git skips cache for large objs).
    large_object_threshold: i64 = 0,
};

pub const Error = error{
    ObjectNotFound,
    InvalidType,
    WriteFailed,
    MalformedIdxFile,
} || Allocator.Error || fs_pkg.Error || objfile.Error || plumbing.Error ||
    dotgit.Error || idxfile.Error || packfile.Error ||
    std.Io.Writer.Error || std.Io.Reader.Error || error{IntegerOverflow};

/// Owned pack image + Packfile for KeepDescriptors / MaxOpenDescriptors cache.
const PackCacheEntry = struct {
    /// Full pack bytes; owned; Packfile.pack_data points here.
    pack_data: []u8,
    pf: packfile.Packfile,
};

fn destroyPackEntry(allocator: Allocator, entry: *PackCacheEntry) void {
    entry.pf.close();
    allocator.free(entry.pack_data);
    allocator.destroy(entry);
}

/// go-git `filesystem.ObjectStorage` monomorphised over billy-style `Fs`.
/// Default export is `ObjectStorage` = Mem specialisation (see bottom of file).
///
/// # EncodedObject ownership (unified with memory)
/// - `newEncodedObject`: caller owns until successful `setEncodedObject` or `discardEncodedObject`
/// - `setEncodedObject`: storage takes ownership on success; pure pre-write failures leave caller ownership
/// - `encodedObject` / loads: **borrow**; storage owns
/// - Borrow validity: until storage `deinit`, `deleteLooseObject` for that hash, or same-kind
///   replace of that hash (set/re-load of the same representation). Delta and resolved
///   forms of one hash may both be live (`owned` + `owned_extra`); either borrow stays valid.
/// - `discardEncodedObject`: abandon a never-set create (safe with storage deinit)
pub fn ObjectStorageFor(comptime Fs: type) type {
    const DotGit = dotgit.DotGitFor(Fs);
    const PackWriter = dotgit.PackWriterFor(Fs);
    const ObjectWriter = dotgit.ObjectWriterFor(Fs);

    return struct {
        const Self = @This();

        /// `setEncodedObject` adopts the pointer on success.
        pub const set_encoded_object_takes_ownership = true;
        /// `newEncodedObject` does not register storage ownership.
        pub const new_encoded_object_storage_owned = false;

        allocator: Allocator,
        options: Options = .{},
        object_cache: ?*ObjectLru = null,
        dir: *DotGit,
        /// Primary owned objects keyed by hash (loads + successful sets). Prefer non-delta.
        /// ObjectLru does not free them; on destroy/deinit we `remove(h)` so a shared cache
        /// never retains a dangling pointer. Never `clear()` a shared external cache.
        owned: std.AutoHashMapUnmanaged(Hash, *MemoryObject) = .empty,
        /// Extra owned pointers when delta and resolved forms share one hash (free on deinit).
        owned_extra: std.ArrayListUnmanaged(*MemoryObject) = .empty,
        /// Pack hash → decoded idx (go-git `index map[Hash]idxfile.Index`).
        /// `null` means not loaded yet; empty map means loaded with zero packs.
        index: ?std.AutoHashMapUnmanaged(Hash, *MemoryIndex) = null,
        /// Pack hash → open pack image (go-git `packfiles map[Hash]*packfile.Packfile`).
        /// `null` means caching disabled or not yet initialized.
        packfiles: ?std.AutoHashMapUnmanaged(Hash, *PackCacheEntry) = null,
        /// Ring buffer of pack hashes for MaxOpenDescriptors eviction (go-git `packList`).
        pack_list: []Hash = &.{},
        pack_list_idx: usize = 0,

        pub fn init(allocator: Allocator, dir: *DotGit, object_cache: ?*ObjectLru, options: Options) Self {
            // freeAlternates / freeHashes must use fs.allocator; keep them equal.
            std.debug.assert(allocator.ptr == dir.fs.allocator.ptr);
            return .{
                .allocator = allocator,
                .options = options,
                .object_cache = object_cache,
                .dir = dir,
            };
        }

        pub fn deinit(self: *Self) void {
            self.clearPackCache();
            self.clearIndex();
            var it = self.owned.iterator();
            while (it.next()) |e| {
                // Scrub shared LRU per owned hash; do not clear() the whole cache.
                if (self.object_cache) |c| c.remove(e.key_ptr.*);
                e.value_ptr.*.deinit();
                self.allocator.destroy(e.value_ptr.*);
            }
            self.owned.deinit(self.allocator);
            for (self.owned_extra.items) |obj| {
                if (self.object_cache) |c| c.remove(obj.hash());
                obj.deinit();
                self.allocator.destroy(obj);
            }
            self.owned_extra.deinit(self.allocator);
            self.* = undefined;
        }

        /// Free all cached pack images (go-git `Close` packfiles loop).
        fn clearPackCache(self: *Self) void {
            if (self.packfiles) |*map| {
                var it = map.iterator();
                while (it.next()) |e| {
                    destroyPackEntry(self.allocator, e.value_ptr.*);
                }
                map.deinit(self.allocator);
                self.packfiles = null;
            }
            if (self.pack_list.len != 0) {
                self.allocator.free(self.pack_list);
                self.pack_list = &.{};
            }
            self.pack_list_idx = 0;
        }

        /// go-git `packfileFromCache`.
        fn packfileFromCache(self: *Self, hash: Hash) ?*packfile.Packfile {
            if (self.packfiles == null) {
                if (self.options.keep_descriptors) {
                    self.packfiles = .{};
                } else if (self.options.max_open_descriptors > 0) {
                    const n: usize = @intCast(self.options.max_open_descriptors);
                    self.pack_list = self.allocator.alloc(Hash, n) catch return null;
                    for (self.pack_list) |*slot| slot.* = plumbing.ZeroHash;
                    self.pack_list_idx = 0;
                    self.packfiles = .{};
                } else {
                    return null;
                }
            }
            const map = self.packfiles orelse return null;
            const entry = map.get(hash) orelse return null;
            return &entry.pf;
        }

        /// go-git `storePackfileInCache`. Returns true when `entry` is retained.
        fn storePackfileInCache(self: *Self, hash: Hash, entry: *PackCacheEntry) Error!bool {
            if (self.options.keep_descriptors) {
                if (self.packfiles == null) self.packfiles = .{};
                if (self.packfiles.?.fetchRemove(hash)) |kv| {
                    destroyPackEntry(self.allocator, kv.value);
                }
                try self.packfiles.?.put(self.allocator, hash, entry);
                return true;
            }

            if (self.options.max_open_descriptors <= 0) {
                return false;
            }

            if (self.packfiles == null) {
                const n: usize = @intCast(self.options.max_open_descriptors);
                self.pack_list = try self.allocator.alloc(Hash, n);
                for (self.pack_list) |*slot| slot.* = plumbing.ZeroHash;
                self.pack_list_idx = 0;
                self.packfiles = .{};
            }

            // Start over as the limit of packList is hit.
            if (self.pack_list_idx >= self.pack_list.len) {
                self.pack_list_idx = 0;
            }

            // Close the existing packfile if open at this ring slot.
            const next = self.pack_list[self.pack_list_idx];
            if (!next.isZero()) {
                if (self.packfiles.?.fetchRemove(next)) |kv| {
                    destroyPackEntry(self.allocator, kv.value);
                }
            }

            self.pack_list[self.pack_list_idx] = hash;
            try self.packfiles.?.put(self.allocator, hash, entry);
            self.pack_list_idx += 1;
            return true;
        }

        /// go-git `packfile` — open pack from cache or load bytes from DotGit.
        /// When not retained, caller must `destroyPackEntry` the returned entry.
        fn openPackfile(
            self: *Self,
            idx: *MemoryIndex,
            pack: Hash,
        ) Error!struct { entry: *PackCacheEntry, retained: bool } {
            if (self.packfileFromCache(pack)) |p| {
                const entry: *PackCacheEntry = @fieldParentPtr("pf", p);
                return .{ .entry = entry, .retained = true };
            }

            var f = try self.dir.objectPack(pack);
            defer f.close() catch {};
            const pack_data = try dotgit.readFileAll(self.allocator, &f);
            errdefer self.allocator.free(pack_data);

            const entry = try self.allocator.create(PackCacheEntry);
            errdefer self.allocator.destroy(entry);
            entry.pack_data = pack_data;
            entry.pf.init(self.allocator, idx, pack_data);
            errdefer entry.pf.close();

            // On success, errdefer does not run: entry (and pack_data) are owned by
            // the cache or the caller. On store failure, close/destroy/free reverse order.
            const retained = try self.storePackfileInCache(pack, entry);
            return .{ .entry = entry, .retained = retained };
        }

        fn removePackFromCache(self: *Self, h: Hash) void {
            if (self.packfiles) |*map| {
                if (map.fetchRemove(h)) |kv| {
                    destroyPackEntry(self.allocator, kv.value);
                }
            }
            for (self.pack_list) |*slot| {
                if (slot.eql(h)) slot.* = plumbing.ZeroHash;
            }
        }

        /// go-git `NewEncodedObject` — caller owns until set or discard.
        pub fn newEncodedObject(self: *Self) Allocator.Error!*MemoryObject {
            const obj = try self.allocator.create(MemoryObject);
            obj.* = MemoryObject.init(self.allocator);
            return obj;
        }

        /// go-git `SetEncodedObject` — write loose object; storage takes ownership on success.
        ///
        /// Delta types fail before any write (`error.InvalidType`); caller retains.
        /// Ownership slot is reserved **before** durable install so `OutOfMemory` cannot
        /// leave an on-disk object without storage bookkeeping. On success, `obj` is in
        /// `owned` and must not be freed by the caller.
        pub fn setEncodedObject(self: *Self, obj: *MemoryObject) Error!Hash {
            if (obj.object_type == .ofs_delta or obj.object_type == .ref_delta) {
                return error.InvalidType;
            }

            // Reserve adopt capacity before close so durable write ⇔ bookkeeping succeed together.
            try prepareAdopt(self, obj);

            var ow = try self.dir.newObject();
            errdefer ow.abandon();

            try ow.writeHeader(obj.object_type, obj.size);
            const content = obj.readerBytes();
            if (content.len > 0) {
                _ = try ow.write(content);
            }
            try ow.close();
            adoptPrepared(self, obj);
            return obj.hash();
        }

        /// Abandon a never-set create. Removes from `owned` if present; frees with `obj.allocator`.
        /// For never-set creates only — do not discard lookup borrows or post-set objects.
        pub fn discardEncodedObject(self: *Self, obj: *MemoryObject) void {
            const h = obj.hash();
            removeOwned(self, obj);
            if (self.object_cache) |c| c.remove(h);
            const a = obj.allocator;
            obj.deinit();
            a.destroy(obj);
        }

        /// Ensure room to adopt `obj` (no-op if already tracked by pointer). Call before durable write.
        fn prepareAdopt(self: *Self, obj: *MemoryObject) Allocator.Error!void {
            if (ownedContainsPointer(self, obj)) return;
            try self.owned.ensureUnusedCapacity(self.allocator, 1);
        }

        /// Record ownership after `prepareAdopt` (no allocation). Hash must be final.
        /// Set path: same-hash replace frees the previous pointer (caller transferred `obj`).
        fn adoptPrepared(self: *Self, obj: *MemoryObject) void {
            const h = obj.hash();
            const gop = self.owned.getOrPutAssumeCapacity(h);
            if (gop.found_existing) {
                if (gop.value_ptr.* == obj) return;
                const old = gop.value_ptr.*;
                if (self.object_cache) |c| c.remove(h);
                destroyOwnedPointer(self, old);
            }
            gop.value_ptr.* = obj;
        }

        /// Register `obj` in `owned` if not already tracked (load / adopt paths).
        fn ensureOwned(self: *Self, obj: *MemoryObject) Allocator.Error!void {
            try prepareAdopt(self, obj);
            adoptPrepared(self, obj);
        }

        fn ownedContainsPointer(store: *const Self, obj: *MemoryObject) bool {
            var it = store.owned.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* == obj) return true;
            }
            for (store.owned_extra.items) |o| {
                if (o == obj) return true;
            }
            return false;
        }

        fn destroyOwnedPointer(self: *Self, obj: *MemoryObject) void {
            // Drop from extra if present so deinit cannot double-free.
            for (self.owned_extra.items, 0..) |o, i| {
                if (o == obj) {
                    _ = self.owned_extra.swapRemove(i);
                    break;
                }
            }
            obj.deinit();
            self.allocator.destroy(obj);
        }

        /// Insert ownership for `h`. Same-kind replace frees the old pointer; delta vs
        /// non-delta keeps both (primary prefers non-delta; other in `owned_extra`).
        fn putOwned(self: *Self, h: Hash, obj: *MemoryObject) Allocator.Error!void {
            if (ownedContainsPointer(self, obj)) return;

            const gop = try self.owned.getOrPut(self.allocator, h);
            if (gop.found_existing) {
                const old = gop.value_ptr.*;
                if (old == obj) return;

                if (old.isDeltaObject() != obj.isDeltaObject()) {
                    // Dual representation under one hash: both borrows stay valid.
                    if (obj.isDeltaObject()) {
                        // Keep non-delta as primary; hold delta in extra.
                        try self.owned_extra.append(self.allocator, obj);
                        return;
                    }
                    // Promote non-delta; retain prior delta in extra.
                    try self.owned_extra.append(self.allocator, old);
                    gop.value_ptr.* = obj;
                    if (self.object_cache) |c| c.remove(h);
                    return;
                }

                // Same kind: free displaced (true dedupe).
                if (self.object_cache) |c| c.remove(h);
                destroyOwnedPointer(self, old);
                gop.value_ptr.* = obj;
                return;
            }
            gop.value_ptr.* = obj;
        }

        fn findOwnedDelta(self: *const Self, h: Hash) ?*MemoryObject {
            if (self.owned.get(h)) |o| {
                if (o.isDeltaObject()) return o;
            }
            for (self.owned_extra.items) |o| {
                if (!o.isDeltaObject()) continue;
                if (o.cached_hash.eql(h) or o.hash().eql(h)) return o;
            }
            return null;
        }

        /// Free primary + extra owned objects for `h` (invalidates borrows of that hash).
        fn freeOwnedHash(self: *Self, h: Hash) void {
            if (self.owned.fetchRemove(h)) |kv| {
                if (self.object_cache) |c| c.remove(h);
                destroyOwnedPointer(self, kv.value);
            }
            var i: usize = 0;
            while (i < self.owned_extra.items.len) {
                const o = self.owned_extra.items[i];
                const oh = if (!o.cached_hash.isZero()) o.cached_hash else o.hash();
                if (oh.eql(h)) {
                    _ = self.owned_extra.swapRemove(i);
                    if (self.object_cache) |c| c.remove(h);
                    o.deinit();
                    self.allocator.destroy(o);
                } else {
                    i += 1;
                }
            }
        }

        /// go-git `ObjectStorage.LazyWriter` result.
        ///
        /// go-git returns `(io.WriteCloser, WriteHeader func)`. Zig binds both
        /// to this value: call `writeHeader` before `write`, then `close`.
        pub const LazyWriter = struct {
            ow: ObjectWriter,

            /// go-git `objectHeaderWriter` / `ObjectWriter.WriteHeader`.
            pub fn writeHeader(self: *Self.LazyWriter, t: ObjectType, size: i64) !void {
                try self.ow.writeHeader(t, size);
            }

            /// go-git `io.Writer.Write` on the lazy object writer.
            pub fn write(self: *Self.LazyWriter, p: []const u8) !usize {
                return try self.ow.write(p);
            }

            /// Hash of object data so far (after header; final after full content).
            pub fn hash(self: *const Self.LazyWriter) Hash {
                return self.ow.hash();
            }

            /// Finish and install the loose object (go-git `Close`).
            pub fn close(self: *Self.LazyWriter) !void {
                try self.ow.close();
            }

            /// Drop without saving (error path).
            pub fn abandon(self: *Self.LazyWriter) void {
                self.ow.abandon();
            }
        };

        /// go-git `LazyWriter` — open a DotGit ObjectWriter for deferred header+content.
        ///
        /// Call `writeHeader` before `write`. Call `close` (or `abandon` on
        /// error) exactly once.
        pub fn lazyWriter(self: *Self) Error!Self.LazyWriter {
            const ow = try self.dir.newObject();
            return .{ .ow = ow };
        }

        /// go-git `HasEncodedObject` — local loose/pack, then alternates.
        pub fn hasEncodedObject(self: *Self, h: Hash) Error!void {
            self.hasEncodedObjectLocal(h) catch |err| switch (err) {
                error.ObjectNotFound => return self.hasEncodedObjectFromAlternates(h),
                else => |e| return e,
            };
        }

        fn hasEncodedObjectLocal(self: *Self, h: Hash) Error!void {
            // Check loose objects first.
            var loose = self.dir.object(h) catch |err| switch (err) {
                error.NotExist, error.ObjectNotFound => {
                    // Fall through to packed objects.
                    try self.requireIndex();
                    if (self.findObjectInPackfile(h) == null) return error.ObjectNotFound;
                    return;
                },
                else => |e| return e,
            };
            defer loose.close() catch {};
        }

        fn hasEncodedObjectFromAlternates(self: *Self, h: Hash) Error!void {
            const alts = self.dir.alternates() catch |e| switch (e) {
                error.NotExist => return error.ObjectNotFound,
                else => |err| return err,
            };
            // Free with the same allocator DotGit.alternates used (fs.allocator).
            defer DotGit.freeAlternates(self.dir.fs.allocator, alts);

            for (alts) |dg| {
                var alt_store = Self.init(self.allocator, dg, self.object_cache, self.options);
                defer alt_store.deinit();
                alt_store.hasEncodedObject(h) catch |err| switch (err) {
                    error.ObjectNotFound => continue,
                    else => |e| return e,
                };
                return;
            }
            return error.ObjectNotFound;
        }

        /// go-git `EncodedObjectSize` — local loose/pack, then alternates.
        pub fn encodedObjectSize(self: *Self, h: Hash) Error!i64 {
            return self.encodedObjectSizeLocal(h) catch |err| switch (err) {
                error.ObjectNotFound => return self.encodedObjectSizeFromAlternates(h),
                else => |e| return e,
            };
        }

        fn encodedObjectSizeLocal(self: *Self, h: Hash) Error!i64 {
            return self.encodedObjectSizeFromUnpacked(h) catch |err| switch (err) {
                error.ObjectNotFound => return self.encodedObjectSizeFromPackfile(h),
                else => |e| return e,
            };
        }

        fn encodedObjectSizeFromAlternates(self: *Self, h: Hash) Error!i64 {
            const alts = self.dir.alternates() catch |e| switch (e) {
                error.NotExist => return error.ObjectNotFound,
                else => |err| return err,
            };
            // Free with the same allocator DotGit.alternates used (fs.allocator).
            defer DotGit.freeAlternates(self.dir.fs.allocator, alts);

            for (alts) |dg| {
                var alt_store = Self.init(self.allocator, dg, self.object_cache, self.options);
                defer alt_store.deinit();
                if (alt_store.encodedObjectSize(h)) |sz| return sz else |_| continue;
            }
            return error.ObjectNotFound;
        }

        fn encodedObjectSizeFromUnpacked(self: *Self, h: Hash) Error!i64 {
            var f = self.dir.object(h) catch |err| switch (err) {
                error.NotExist, error.ObjectNotFound => return error.ObjectNotFound,
                else => |e| return e,
            };
            defer f.close() catch {};

            const data = try dotgit.readFileAll(self.allocator, &f);
            defer self.allocator.free(data);

            var src: std.Io.Reader = .fixed(data);
            var r = try objfile.Reader.open(self.allocator, &src);
            defer r.close();
            const hdr = try r.header();
            return hdr.size;
        }

        fn encodedObjectSizeFromPackfile(self: *Self, h: Hash) Error!i64 {
            try self.requireIndex();
            const found = self.findObjectInPackfile(h) orelse return error.ObjectNotFound;

            if (self.object_cache) |c| {
                if (c.get(h)) |obj| return obj.size;
            }

            const idx = self.index.?.get(found.pack) orelse return error.ObjectNotFound;

            const opened = try self.openPackfile(idx, found.pack);
            defer if (!opened.retained) destroyPackEntry(self.allocator, opened.entry);

            return opened.entry.pf.getSizeByOffset(found.offset) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ObjectNotFound => return error.ObjectNotFound,
                else => return error.ObjectNotFound,
            };
        }

        /// go-git `EncodedObject` — pack-first when index loaded, else loose-first,
        /// then shared object directories listed in `objects/info/alternates`.
        /// Type check runs after a successful local or alternate load (go-git order).
        pub fn encodedObject(self: *Self, t: ObjectType, h: Hash) Error!*MemoryObject {
            const obj = self.getEncodedObjectAnyType(h) catch |err| switch (err) {
                error.ObjectNotFound => try self.encodedObjectFromAlternates(t, h),
                else => |e| return e,
            };
            if (t != .any and obj.object_type != t) return error.ObjectNotFound;
            return obj;
        }

        /// Local loose/pack lookup without type filter (go-git body before type check).
        fn getEncodedObjectAnyType(self: *Self, h: Hash) Error!*MemoryObject {
            if (self.index != null)
                return self.getFromPackfile(h, false) catch |err| switch (err) {
                    error.ObjectNotFound => return self.getFromUnpacked(h),
                    else => |e| return e,
                };
            return self.getFromUnpacked(h) catch |err| switch (err) {
                error.ObjectNotFound => return self.getFromPackfile(h, false),
                else => |e| return e,
            };
        }

        fn encodedObjectFromAlternates(self: *Self, t: ObjectType, h: Hash) Error!*MemoryObject {
            const alts = self.dir.alternates() catch |e| switch (e) {
                error.NotExist => return error.ObjectNotFound,
                else => |err| return err,
            };
            // Free with the same allocator DotGit.alternates used (fs.allocator).
            defer DotGit.freeAlternates(self.dir.fs.allocator, alts);

            for (alts) |dg| {
                // Share object_cache with parent (go-git NewObjectStorage(dg, s.objectCache)).
                var alt_store = Self.init(self.allocator, dg, self.object_cache, self.options);
                // Always deinit: adoptObject removes `obj` from alt.owned first so
                // deinit will not free a transferred MemoryObject.
                defer alt_store.deinit();
                if (alt_store.encodedObject(t, h)) |obj| {
                    try self.adoptObject(&alt_store, obj);
                    return obj;
                } else |_| continue;
            }
            return error.ObjectNotFound;
        }

        /// Move `obj` from an alternate store into this store's ownership map.
        ///
        /// Alternate ObjectStorage shares `object_cache` and must not free the
        /// returned MemoryObject on deinit. Insert into `self.owned` first so a
        /// failed put leaves the object still owned by `alt`.
        fn adoptObject(self: *Self, alt: *Self, obj: *MemoryObject) Allocator.Error!void {
            const h = obj.hash();
            if (self.owned.get(h)) |existing| {
                if (existing == obj) {
                    removeOwned(alt, obj);
                    return;
                }
                // Already own another copy of this hash: keep ours, drop alt's.
                removeOwned(alt, obj);
                if (self.object_cache) |c| {
                    if (c.get(h) == obj) {
                        c.remove(h);
                        c.put(existing) catch {};
                    }
                }
                obj.deinit();
                self.allocator.destroy(obj);
                return;
            }
            try self.owned.put(self.allocator, h, obj);
            removeOwned(alt, obj);
        }

        fn removeOwned(store: *Self, obj: *MemoryObject) void {
            const h = obj.hash();
            if (store.owned.get(h)) |o| {
                if (o == obj) {
                    _ = store.owned.remove(h);
                    return;
                }
            }
            var it = store.owned.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* == obj) {
                    _ = store.owned.remove(e.key_ptr.*);
                    return;
                }
            }
            for (store.owned_extra.items, 0..) |o, i| {
                if (o == obj) {
                    _ = store.owned_extra.swapRemove(i);
                    return;
                }
            }
        }

        /// go-git `DeltaObject` — loose first, then pack allowing unresolved deltas.
        /// After local miss, consult alternates (extended for shared object dbs).
        pub fn deltaObject(self: *Self, t: ObjectType, h: Hash) Error!*MemoryObject {
            const obj = self.getDeltaObjectAnyType(h) catch |err| switch (err) {
                error.ObjectNotFound => try self.deltaObjectFromAlternates(t, h),
                else => |e| return e,
            };
            if (t != .any and obj.object_type != t) return error.ObjectNotFound;
            return obj;
        }

        fn getDeltaObjectAnyType(self: *Self, h: Hash) Error!*MemoryObject {
            return self.getFromUnpacked(h) catch |err| switch (err) {
                error.ObjectNotFound => return self.getFromPackfile(h, true),
                else => |e| return e,
            };
        }

        fn deltaObjectFromAlternates(self: *Self, t: ObjectType, h: Hash) Error!*MemoryObject {
            const alts = self.dir.alternates() catch |e| switch (e) {
                error.NotExist => return error.ObjectNotFound,
                else => |err| return err,
            };
            // Free with the same allocator DotGit.alternates used (fs.allocator).
            defer DotGit.freeAlternates(self.dir.fs.allocator, alts);

            for (alts) |dg| {
                var alt_store = Self.init(self.allocator, dg, self.object_cache, self.options);
                defer alt_store.deinit();
                if (alt_store.deltaObject(t, h)) |obj| {
                    try self.adoptObject(&alt_store, obj);
                    return obj;
                } else |_| continue;
            }
            return error.ObjectNotFound;
        }

        fn getFromUnpacked(self: *Self, h: Hash) Error!*MemoryObject {
            if (self.object_cache) |c| {
                if (c.get(h)) |cached| return cached;
            }

            // Loose must exist for this path (do not return owned after loose delete —
            // pack/delta paths need ObjectNotFound here).
            var f = self.dir.object(h) catch |err| switch (err) {
                error.NotExist, error.ObjectNotFound => return error.ObjectNotFound,
                else => |e| return e,
            };
            defer f.close() catch {};

            // Dedupe: already-owned non-delta for this hash (avoids owned-map growth).
            if (self.owned.get(h)) |existing| {
                if (!existing.isDeltaObject()) {
                    self.cacheIfEligible(existing, existing.size);
                    return existing;
                }
            }

            const data = try dotgit.readFileAll(self.allocator, &f);
            defer self.allocator.free(data);

            var src: std.Io.Reader = .fixed(data);
            var r = try objfile.Reader.open(self.allocator, &src);
            defer r.close();

            const hdr = try r.header();

            const obj = try self.allocator.create(MemoryObject);
            errdefer {
                obj.deinit();
                self.allocator.destroy(obj);
            }
            obj.* = MemoryObject.init(self.allocator);
            obj.setType(hdr.t);
            obj.setSize(hdr.size);

            if (hdr.size > 0) {
                var content: std.ArrayList(u8) = .empty;
                defer content.deinit(self.allocator);
                var tmp: [4096]u8 = undefined;
                while (true) {
                    const n = r.read(&tmp) catch |e| switch (e) {
                        error.EndOfStream => break,
                        else => |err| return err,
                    };
                    try content.appendSlice(self.allocator, tmp[0..n]);
                }
                try obj.setContent(content.items);
            }

            // Force cached hash to requested id when content matches (objfile validates stream).
            obj.cached_hash = Hash.fromBytes(h.slice());

            try self.putOwned(h, obj);
            self.cacheIfEligible(obj, hdr.size);
            return obj;
        }

        /// go-git: skip object cache when size exceeds `large_object_threshold`.
        fn cacheIfEligible(self: *Self, obj: *MemoryObject, size: i64) void {
            if (self.options.large_object_threshold > 0 and size > self.options.large_object_threshold)
                return;
            if (self.object_cache) |c| {
                c.put(obj) catch {};
            }
        }

        /// go-git `getFromPackfile`.
        fn getFromPackfile(self: *Self, h: Hash, can_be_delta: bool) Error!*MemoryObject {
            try self.requireIndex();
            const found = self.findObjectInPackfile(h) orelse return error.ObjectNotFound;
            const idx = self.index.?.get(found.pack) orelse return error.ObjectNotFound;

            const opened = try self.openPackfile(idx, found.pack);
            defer if (!opened.retained) destroyPackEntry(self.allocator, opened.entry);
            const pf = &opened.entry.pf;

            if (can_be_delta) {
                return self.decodeDeltaObjectAt(pf, found.offset, found.hash);
            }
            return self.decodeObjectAt(pf, found.offset);
        }

        fn decodeObjectAt(self: *Self, p: *packfile.Packfile, offset: i64) Error!*MemoryObject {
            // Prefer object cache / owned non-delta when hash is known.
            if (p.index.findHash(offset)) |hash| {
                if (self.object_cache) |c| {
                    if (c.get(hash)) |cached| return cached;
                }
                if (self.owned.get(hash)) |existing| {
                    if (!existing.isDeltaObject()) {
                        const sz = if (existing.size > 0) existing.size else @as(i64, @intCast(existing.readerBytes().len));
                        self.cacheIfEligible(existing, sz);
                        return existing;
                    }
                }
            } else |_| {}

            const pf_obj = p.getByOffset(offset) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ObjectNotFound => return error.ObjectNotFound,
                else => return error.ObjectNotFound,
            };
            // Packfile owns pf_obj until close — clone into storage-owned MemoryObject.
            return self.cloneOwned(pf_obj);
        }

        fn decodeDeltaObjectAt(
            self: *Self,
            p: *packfile.Packfile,
            offset: i64,
            hash: Hash,
        ) Error!*MemoryObject {
            // Same-kind dedupe: return existing unresolved delta if already owned.
            if (self.findOwnedDelta(hash)) |existing| return existing;

            const header = p.scanner.seekObjectHeader(offset) catch return error.ObjectNotFound;

            const base: Hash = switch (header.object_type) {
                .ref_delta => header.reference,
                .ofs_delta => p.index.findHash(header.offset_reference) catch return error.ObjectNotFound,
                else => return self.decodeObjectAt(p, offset),
            };

            var aw: std.Io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            _ = p.scanner.nextObject(&aw.writer) catch return error.ObjectNotFound;

            const obj = try self.allocator.create(MemoryObject);
            errdefer {
                obj.deinit();
                self.allocator.destroy(obj);
            }
            obj.* = MemoryObject.init(self.allocator);
            obj.setType(header.object_type);
            try obj.setContent(aw.written());
            // Canonicalize once at the boundary for cache identity and DeltaMeta keys.
            const id = Hash.fromBytes(hash.slice());
            const base_id = Hash.fromBytes(base.slice());
            obj.cached_hash = id;
            _ = deltaobject.newDeltaObject(obj, id, base_id, header.length);

            try self.putOwned(hash, obj);
            return obj;
        }

        /// Copy a packfile-owned object into storage ownership.
        fn cloneOwned(self: *Self, src: *MemoryObject) Error!*MemoryObject {
            const h = src.hash();
            if (!h.isZero()) {
                if (self.owned.get(h)) |existing| {
                    if (!existing.isDeltaObject()) {
                        const sz = if (existing.size > 0) existing.size else @as(i64, @intCast(existing.readerBytes().len));
                        self.cacheIfEligible(existing, sz);
                        return existing;
                    }
                }
            }

            const obj = try self.allocator.create(MemoryObject);
            errdefer {
                obj.deinit();
                self.allocator.destroy(obj);
            }
            obj.* = MemoryObject.init(self.allocator);
            obj.setType(src.object_type);
            try obj.setContent(src.readerBytes());
            if (!h.isZero()) obj.cached_hash = Hash.fromBytes(h.slice());
            if (src.delta) |d| {
                obj.setDeltaMeta(.{
                    .base_hash = Hash.fromBytes(d.base_hash.slice()),
                    .actual_hash = Hash.fromBytes(d.actual_hash.slice()),
                    .actual_size = d.actual_size,
                });
            }

            if (!h.isZero()) {
                try self.putOwned(h, obj);
            } else {
                // Zero hash should not occur for real objects; still track under computed hash.
                const computed = obj.hash();
                try self.putOwned(computed, obj);
            }
            const sz = if (src.size > 0) src.size else @as(i64, @intCast(src.readerBytes().len));
            self.cacheIfEligible(obj, sz);
            return obj;
        }

        const PackHit = struct {
            pack: Hash,
            hash: Hash,
            offset: i64,
        };

        fn findObjectInPackfile(self: *Self, h: Hash) ?PackHit {
            const map = self.index orelse return null;
            var it = map.iterator();
            while (it.next()) |e| {
                const offset = e.value_ptr.*.findOffset(h) catch continue;
                return .{ .pack = e.key_ptr.*, .hash = h, .offset = offset };
            }
            return null;
        }

        /// go-git `requireIndex` — load all pack idx files.
        pub fn requireIndex(self: *Self) Error!void {
            if (self.index != null) return;

            var map: std.AutoHashMapUnmanaged(Hash, *MemoryIndex) = .empty;
            errdefer {
                var it = map.iterator();
                while (it.next()) |e| {
                    e.value_ptr.*.deinit();
                    self.allocator.destroy(e.value_ptr.*);
                }
                map.deinit(self.allocator);
            }

            const packs = try self.dir.objectPacks();
            defer dotgit.freeHashes(self.allocator, packs);

            for (packs) |h| {
                try self.loadIdxFileInto(&map, h);
            }

            self.index = map;
        }

        fn loadIdxFileInto(
            self: *Self,
            map: *std.AutoHashMapUnmanaged(Hash, *MemoryIndex),
            h: Hash,
        ) Error!void {
            var f = try self.dir.objectPackIdx(h);
            defer f.close() catch {};

            const data = try dotgit.readFileAll(self.allocator, &f);
            defer self.allocator.free(data);

            const idx_ptr = try self.allocator.create(MemoryIndex);
            errdefer self.allocator.destroy(idx_ptr);
            idx_ptr.* = MemoryIndex.init(self.allocator);
            errdefer idx_ptr.deinit();

            var r: std.Io.Reader = .fixed(data);
            var d = idxfile.Decoder.initWithSize(&r, @intCast(data.len));
            try d.decode(idx_ptr);

            if (!idx_ptr.packfile_checksum.eql(h)) {
                return error.MalformedIdxFile;
            }

            try map.put(self.allocator, h, idx_ptr);
        }

        /// go-git `Reindex` — drop cached pack indexes so the next lookup reloads.
        pub fn reindex(self: *Self) void {
            self.clearIndex();
        }

        fn clearIndex(self: *Self) void {
            if (self.index) |*map| {
                var it = map.iterator();
                while (it.next()) |e| {
                    e.value_ptr.*.deinit();
                    self.allocator.destroy(e.value_ptr.*);
                }
                map.deinit(self.allocator);
                self.index = null;
            }
        }

        /// go-git `PackfileWriter` — opens a DotGit pack writer.
        ///
        /// On successful `close`, Notify installs the live MemoryIndex under the
        /// pack checksum (go-git `w.Notify` → `s.index[h] = index`).
        pub fn packfileWriter(self: *Self) Error!PackWriter {
            try self.requireIndex();
            var w = try self.dir.newObjectPack();
            w.notify_ctx = self;
            w.notify_fn = packNotifyInstallIndex;
            return w;
        }

        /// go-git PackWriter.Notify: install live idx into `index` under pack hash.
        ///
        /// Takes ownership of the Writer's MemoryIndex via `takeIndex`. Does not
        /// clear the index map — the new pack is immediately visible without
        /// re-reading `.idx` from disk.
        fn packNotifyInstallIndex(ctx: ?*anyopaque, h: Hash, writer: *idxfile.Writer) void {
            const s: *Self = @ptrCast(@alignCast(ctx orelse return));
            const idx = writer.takeIndex() catch return;

            // Drop any cached pack for this hash before replacing the idx pointer.
            s.removePackFromCache(h);

            if (s.index) |*map| {
                if (map.fetchRemove(h)) |kv| {
                    kv.value.deinit();
                    s.allocator.destroy(kv.value);
                }
                map.put(s.allocator, h, idx) catch {
                    idx.deinit();
                    s.allocator.destroy(idx);
                    return;
                };
                return;
            }

            // packfileWriter always requireIndex first; keep a defensive path.
            var map: std.AutoHashMapUnmanaged(Hash, *MemoryIndex) = .empty;
            map.put(s.allocator, h, idx) catch {
                idx.deinit();
                s.allocator.destroy(idx);
                return;
            };
            s.index = map;
        }

        /// go-git `IterEncodedObjects` — loose objects then pack index entries.
        ///
        /// Mirrors go-git: `objectsIter` + `buildPackfileIters` (`lazyPackfilesIter` /
        /// `packfileIter`) combined as one multi-source iterator (same role as
        /// `storer.NewMultiEncodedObjectIter`). Loose hashes fill `seen` so pack
        /// entries that also exist as loose objects are skipped.
        pub fn iterEncodedObjects(self: *Self, t: ObjectType) Error!Self.ObjectHashIter {
            const loose = try self.dir.objects();
            errdefer dotgit.freeHashes(self.allocator, loose);

            var seen: std.AutoHashMapUnmanaged(Hash, void) = .empty;
            errdefer seen.deinit(self.allocator);
            for (loose) |h| {
                try seen.put(self.allocator, h, {});
            }

            // go-git `buildPackfileIters` → `requireIndex` + `ObjectPacks`.
            try self.requireIndex();
            const packs = try self.dir.objectPacks();
            errdefer dotgit.freeHashes(self.allocator, packs);

            return .{
                .storage = self,
                .allocator = self.allocator,
                .want = t,
                .loose_hashes = loose,
                .loose_pos = 0,
                .seen = seen,
                .pack_hashes = packs,
                .pack_pos = 0,
                .active = null,
            };
        }

        /// Context-aware `ForEachObjectHash` (see DotGit.forEachObjectHash).
        pub fn forEachObjectHash(
            self: *Self,
            ctx: anytype,
            comptime fun: *const fn (@TypeOf(ctx), Hash) anyerror!void,
        ) anyerror!void {
            return self.dir.forEachObjectHash(ctx, fun);
        }

        /// List pack hashes. Non-empty: caller frees with `dotgit.freeHashes`.
        /// Empty: static zero-length slice — do not free.
        pub fn objectPacks(self: *Self) (Allocator.Error || fs_pkg.Error)![]Hash {
            return self.dir.objectPacks();
        }

        /// go-git `LooseObjectTime` — mtime_sec of the loose object file.
        pub fn looseObjectTime(self: *Self, h: Hash) Error!i64 {
            const path = try self.dir.objectPath(h);
            defer self.allocator.free(path);
            const fi = self.dir.fs.stat(path) catch |err| switch (err) {
                error.NotExist => return error.ObjectNotFound,
                else => |e| return e,
            };
            return fi.mtime_sec;
        }

        /// go-git `DeleteLooseObject`.
        /// Drops the hash from `object_cache` and frees any owned objects for `h`
        /// (invalidates borrows of that hash). Pack-only objects can be reloaded later.
        pub fn deleteLooseObject(self: *Self, h: Hash) Error!void {
            try self.dir.objectDelete(h);
            if (self.object_cache) |c| c.remove(h);
            self.freeOwnedHash(h);
        }

        /// go-git `HashesWithPrefix` — loose + pack index entries.
        /// Caller frees with `dotgit.freeHashes` (or `allocator.free` when non-empty).
        pub fn hashesWithPrefix(self: *Self, prefix: []const u8) Error![]Hash {
            if (prefix.len > plumbing.digestSize()) return &.{};

            var hashes: std.ArrayList(Hash) = .empty;
            errdefer hashes.deinit(self.allocator);

            var seen: std.AutoHashMapUnmanaged(Hash, void) = .empty;
            defer seen.deinit(self.allocator);

            // Loose objects (go-git ObjectsWithPrefix slow path via Objects).
            const loose = try self.dir.objects();
            defer dotgit.freeHashes(self.allocator, loose);
            for (loose) |h| {
                if (prefix.len == 0 or std.mem.startsWith(u8, h.bytes[0..], prefix)) {
                    try hashes.append(self.allocator, h);
                    try seen.put(self.allocator, h, {});
                }
            }

            try self.requireIndex();
            if (self.index) |*map| {
                var it = map.iterator();
                while (it.next()) |e| {
                    var ei = e.value_ptr.*.entries();
                    defer ei.close();
                    while (try ei.next()) |entry| {
                        if (prefix.len == 0 or std.mem.startsWith(u8, entry.hash.bytes[0..], prefix)) {
                            if (seen.contains(entry.hash)) continue;
                            try hashes.append(self.allocator, entry.hash);
                            try seen.put(self.allocator, entry.hash, {});
                        }
                    }
                }
            }

            if (hashes.items.len == 0) {
                hashes.deinit(self.allocator);
                return &.{};
            }
            return try hashes.toOwnedSlice(self.allocator);
        }

        /// go-git `DeleteOldObjectPackAndIndex`.
        /// `t` is Unix mtime seconds; `0` means always delete (go-git zero time).
        pub fn deleteOldObjectPackAndIndex(self: *Self, h: Hash, t: i64) Error!void {
            try self.dir.deleteOldObjectPackAndIndex(h, t);
            // Drop cached pack image first (holds *MemoryIndex), then index entry.
            self.removePackFromCache(h);
            if (self.index) |*map| {
                if (map.fetchRemove(h)) |kv| {
                    kv.value.deinit();
                    self.allocator.destroy(kv.value);
                }
            }
        }

        /// go-git `Close` — close cached packfiles and DotGit descriptors.
        pub fn close(self: *Self) void {
            self.clearPackCache();
            self.dir.close();
        }

        /// Multi-source encoded-object iterator (go-git `IterEncodedObjects`).
        ///
        /// Yields loose objects first (`objectsIter`), then objects from each pack
        /// index (`packfileIter` / `lazyPackfilesIter`), skipping hashes already seen
        /// as loose. Type filter is applied after decode (go-git pack path uses
        /// `GetByType`; we decode and skip mismatches).
        pub const ObjectHashIter = struct {
            storage: *Self,
            allocator: Allocator,
            want: ObjectType,

            loose_hashes: []Hash,
            loose_pos: usize = 0,

            /// Loose-object set (go-git `seen`); pack entries in this set are skipped.
            seen: std.AutoHashMapUnmanaged(Hash, void) = .empty,

            pack_hashes: []Hash,
            pack_pos: usize = 0,
            /// Open pack image + entry cursor for the current pack, if any.
            active: ?ActivePack = null,

            const ActivePack = struct {
                data: []u8,
                pf: packfile.Packfile,
                entries: idxfile.EntryIterator,
            };

            pub fn deinit(self: *Self.ObjectHashIter) void {
                self.close();
            }

            /// go-git `EncodedObjectIter.Close` — free lists, seen map, open pack.
            pub fn close(self: *Self.ObjectHashIter) void {
                self.closeActivePack();
                dotgit.freeHashes(self.allocator, self.loose_hashes);
                self.loose_hashes = &.{};
                self.loose_pos = 0;
                dotgit.freeHashes(self.allocator, self.pack_hashes);
                self.pack_hashes = &.{};
                self.pack_pos = 0;
                self.seen.deinit(self.allocator);
                self.seen = .empty;
            }

            fn closeActivePack(self: *Self.ObjectHashIter) void {
                if (self.active) |*a| {
                    a.entries.close();
                    a.pf.close();
                    self.allocator.free(a.data);
                    self.active = null;
                }
            }

            /// Open pack `pack_hash` into `active`. Leaves `active` null on failure/missing idx.
            fn tryOpenPack(self: *Self.ObjectHashIter, pack_hash: Hash) void {
                self.closeActivePack();
                const map = self.storage.index orelse return;
                const idx = map.get(pack_hash) orelse return;

                var f = self.storage.dir.objectPack(pack_hash) catch return;
                defer f.close() catch {};
                const data = dotgit.readFileAll(self.allocator, &f) catch return;

                var pf: packfile.Packfile = undefined;
                pf.init(self.allocator, idx, data);

                self.active = .{
                    .data = data,
                    .pf = pf,
                    .entries = idx.entries(),
                };
            }

            /// Next object or `error.EndOfStream` (go-git `io.EOF`; matches memory suite).
            pub fn next(self: *Self.ObjectHashIter) error{EndOfStream}!*MemoryObject {
                // First, loose objects (go-git `objectsIter`).
                while (self.loose_pos < self.loose_hashes.len) {
                    const h = self.loose_hashes[self.loose_pos];
                    self.loose_pos += 1;
                    const obj = self.storage.getFromUnpacked(h) catch continue;
                    if (self.want != .any and obj.object_type != self.want) continue;
                    return obj;
                }

                // Then pack index entries (go-git `lazyPackfilesIter` + `packfileIter`).
                while (true) {
                    while (self.active == null) {
                        if (self.pack_pos >= self.pack_hashes.len) return error.EndOfStream;
                        const ph = self.pack_hashes[self.pack_pos];
                        self.pack_pos += 1;
                        self.tryOpenPack(ph);
                    }

                    var act = &self.active.?;
                    const entry = act.entries.next() catch {
                        self.closeActivePack();
                        continue;
                    } orelse {
                        self.closeActivePack();
                        continue;
                    };

                    if (self.seen.contains(entry.hash)) continue;

                    // Prefer decodeObjectAt at the known idx offset (same pack already open).
                    const obj = self.storage.decodeObjectAt(&act.pf, @intCast(entry.offset)) catch continue;
                    if (self.want != .any and obj.object_type != self.want) continue;
                    return obj;
                }
            }
        };
    };
}

/// Mem specialisation (default call sites).
pub const ObjectStorageMem = ObjectStorageFor(fs_pkg.Mem);
/// Os specialisation (on-disk via `std.Io`).
pub const ObjectStorageOs = ObjectStorageFor(fs_pkg.Os);
/// Default ObjectStorage — Mem (matches `DotGit` default).
pub const ObjectStorage = ObjectStorageMem;
/// Nested hash iterator for Mem ObjectStorage.
pub const ObjectHashIter = ObjectStorageMem.ObjectHashIter;
/// Nested hash iterator for Os ObjectStorage.
pub const ObjectHashIterOs = ObjectStorageOs.ObjectHashIter;
/// go-git LazyWriter for Mem ObjectStorage.
pub const LazyWriter = ObjectStorageMem.LazyWriter;
/// LazyWriter for Os ObjectStorage.
pub const LazyWriterOs = ObjectStorageOs.LazyWriter;

/// go-git `NewObjectStorage` (Mem DotGit).
pub fn newObjectStorage(
    allocator: Allocator,
    dir: *dotgit.DotGit,
    object_cache: ?*ObjectLru,
) ObjectStorageMem {
    return ObjectStorageMem.init(allocator, dir, object_cache, .{});
}

/// go-git `NewObjectStorageWithOptions` (Mem DotGit).
pub fn newObjectStorageWithOptions(
    allocator: Allocator,
    dir: *dotgit.DotGit,
    object_cache: ?*ObjectLru,
    ops: Options,
) ObjectStorageMem {
    return ObjectStorageMem.init(allocator, dir, object_cache, ops);
}

/// `NewObjectStorage` over Os DotGit.
pub fn newObjectStorageOs(
    allocator: Allocator,
    dir: *dotgit.DotGitOs,
    object_cache: ?*ObjectLru,
) ObjectStorageOs {
    return ObjectStorageOs.init(allocator, dir, object_cache, .{});
}

/// `NewObjectStorageWithOptions` over Os DotGit.
pub fn newObjectStorageOsWithOptions(
    allocator: Allocator,
    dir: *dotgit.DotGitOs,
    object_cache: ?*ObjectLru,
    ops: Options,
) ObjectStorageOs {
    return ObjectStorageOs.init(allocator, dir, object_cache, ops);
}

// Re-export helper used by pack delta path.
pub const newDeltaObject = deltaobject.newDeltaObject;
