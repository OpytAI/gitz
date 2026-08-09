//! Packfile Parser — port of go-git v5.19.2 `plumbing/format/packfile/parser.go`.
//!
//! Decodes a packfile via a `Scanner`, resolves OFS/REF deltas, and notifies
//! `Observer`s (e.g. `idxfile.Writer` when building an index).
//!
//! Prefer a seekable scanner (`Scanner.initSeekable`) so the pack image can be
//! re-read while resolving deltas. Non-seekable sources require an
//! `EncodedObjectStore` (thin packs / stream-only).

const std = @import("std");
const plumbing = @import("plumbing");

const common = @import("common.zig");
const pack_error = @import("error.zig");
const scanner_mod = @import("scanner.zig");
const patch_delta = @import("patch_delta.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const ObjectType = plumbing.ObjectType;
const MemoryObject = plumbing.MemoryObject;
const Hasher = plumbing.Hasher;
const Size = plumbing.Size;

const Scanner = scanner_mod.Scanner;
const ObjectHeader = scanner_mod.ObjectHeader;
const Error = pack_error.Error;

const max_objects_prealloc = common.max_objects_prealloc;
const max_object_prealloc_bytes = common.max_object_prealloc_bytes;
const max_delta_chain_depth = common.max_delta_chain_depth;

const HashKey = Hash;

// ---------------------------------------------------------------------------
// EncodedObjectStore — parser storage boundary
// ---------------------------------------------------------------------------

/// The subset of go-git's `storer.EncodedObjectStorer` used by the parser.
///
/// This boundary lets callers parse directly into a repository transaction.
/// It avoids materializing every decoded object in a parser-only map and then
/// copying the same content into the destination storer.
pub const EncodedObjectStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ptr: *anyopaque, h: Hash, out: **MemoryObject) u16,
        put_content: *const fn (ptr: *anyopaque, t: ObjectType, content: []const u8, out: *Hash) u16,
    };

    pub fn get(self: EncodedObjectStore, h: Hash) anyerror!*MemoryObject {
        var out: *MemoryObject = undefined;
        const error_code = self.vtable.get(self.ptr, h, &out);
        if (error_code != 0) return @errorFromInt(error_code);
        return out;
    }

    pub fn putContent(self: EncodedObjectStore, t: ObjectType, content: []const u8) anyerror!Hash {
        var out: Hash = undefined;
        const error_code = self.vtable.put_content(self.ptr, t, content, &out);
        if (error_code != 0) return @errorFromInt(error_code);
        return out;
    }

    pub fn from(comptime T: type, impl: *T) EncodedObjectStore {
        const gen = struct {
            fn cbGet(ptr: *anyopaque, h: Hash, out: **MemoryObject) u16 {
                const self: *T = @ptrCast(@alignCast(ptr));
                out.* = self.get(h) catch |err| return @intFromError(err);
                return 0;
            }

            fn cbPutContent(ptr: *anyopaque, t: ObjectType, content: []const u8, out: *Hash) u16 {
                const self: *T = @ptrCast(@alignCast(ptr));
                out.* = self.putContent(t, content) catch |err| return @intFromError(err);
                return 0;
            }

            const vtable = VTable{
                .get = cbGet,
                .put_content = cbPutContent,
            };
        };

        return .{ .ptr = impl, .vtable = &gen.vtable };
    }
};

// ---------------------------------------------------------------------------
// Security prealloc hints (go-git parser.go growHint / objectsHint)
// ---------------------------------------------------------------------------

/// Non-negative size clamped for buffer grow hints (package-private).
fn growHint(n: i64) usize {
    if (n <= 0) return 0;
    if (n > max_object_prealloc_bytes) return max_object_prealloc_bytes;
    return @intCast(n);
}

/// Non-negative count clamped for slice/map capacity (package-private).
fn objectsHint(n: u32) usize {
    if (n > max_objects_prealloc) return max_objects_prealloc;
    return n;
}

// ---------------------------------------------------------------------------
// Observer (go-git Observer interface)
// ---------------------------------------------------------------------------

/// Pack parse callbacks (go-git `Observer`). Implemented by idx encoders.
pub const Observer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onHeader: *const fn (ptr: *anyopaque, count: u32) anyerror!void,
        onInflatedObjectHeader: *const fn (ptr: *anyopaque, t: ObjectType, obj_size: i64, pos: i64) anyerror!void,
        onInflatedObjectContent: *const fn (ptr: *anyopaque, h: Hash, pos: i64, crc: u32, content: []const u8) anyerror!void,
        onFooter: *const fn (ptr: *anyopaque, h: Hash) anyerror!void,
    };

    pub fn onHeader(self: Observer, count: u32) anyerror!void {
        return self.vtable.onHeader(self.ptr, count);
    }

    pub fn onInflatedObjectHeader(self: Observer, t: ObjectType, obj_size: i64, pos: i64) anyerror!void {
        return self.vtable.onInflatedObjectHeader(self.ptr, t, obj_size, pos);
    }

    pub fn onInflatedObjectContent(self: Observer, h: Hash, pos: i64, crc: u32, content: []const u8) anyerror!void {
        return self.vtable.onInflatedObjectContent(self.ptr, h, pos, crc, content);
    }

    pub fn onFooter(self: Observer, h: Hash) anyerror!void {
        return self.vtable.onFooter(self.ptr, h);
    }

    /// Build an Observer from a type that implements the four callbacks.
    pub fn from(comptime T: type, impl: *T) Observer {
        const gen = struct {
            fn cbHeader(ptr: *anyopaque, count: u32) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.onHeader(count);
            }
            fn cbInflatedObjectHeader(ptr: *anyopaque, t: ObjectType, obj_size: i64, pos: i64) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.onInflatedObjectHeader(t, obj_size, pos);
            }
            fn cbInflatedObjectContent(ptr: *anyopaque, h: Hash, pos: i64, crc: u32, content: []const u8) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.onInflatedObjectContent(h, pos, crc, content);
            }
            fn cbFooter(ptr: *anyopaque, h: Hash) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.onFooter(h);
            }
            const vtable = VTable{
                .onHeader = cbHeader,
                .onInflatedObjectHeader = cbInflatedObjectHeader,
                .onInflatedObjectContent = cbInflatedObjectContent,
                .onFooter = cbFooter,
            };
        };
        return .{
            .ptr = impl,
            .vtable = &gen.vtable,
        };
    }
};

// ---------------------------------------------------------------------------
// ObjectStore — minimal optional storage for thin / non-seekable packs
// ---------------------------------------------------------------------------

/// In-memory object store for thin packs and non-seekable sources.
/// Subset of go-git `storer.EncodedObjectStorer` used by the parser.
pub const ObjectStore = struct {
    allocator: Allocator,
    map: std.AutoHashMapUnmanaged(HashKey, *MemoryObject) = .empty,

    pub fn init(allocator: Allocator) ObjectStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ObjectStore) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            self.allocator.destroy(e.value_ptr.*);
        }
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    /// go-git `EncodedObject(AnyObject, hash)`.
    pub fn get(self: *ObjectStore, h: Hash) error{ObjectNotFound}!*MemoryObject {
        return self.map.get(h) orelse error.ObjectNotFound;
    }

    /// Store a fully populated memory object (takes ownership of `obj` heap node).
    pub fn set(self: *ObjectStore, obj: *MemoryObject) (Allocator.Error)!Hash {
        const h = obj.hash();
        const gop = try self.map.getOrPut(self.allocator, h);
        // Overwrite frees the previous owned object; same pointer is a no-op free.
        if (gop.found_existing) {
            if (gop.value_ptr.* != obj) {
                gop.value_ptr.*.deinit();
                self.allocator.destroy(gop.value_ptr.*);
            }
        }
        gop.value_ptr.* = obj;
        return h;
    }

    /// Create, fill, hash, and store an object from type + content.
    pub fn putContent(self: *ObjectStore, t: ObjectType, content: []const u8) (Allocator.Error)!Hash {
        const obj = try self.allocator.create(MemoryObject);
        errdefer self.allocator.destroy(obj);
        obj.* = MemoryObject.init(self.allocator);
        errdefer obj.deinit();
        obj.setType(t);
        try obj.setContent(content);
        return self.set(obj);
    }
};

// ---------------------------------------------------------------------------
// objectInfo (internal parse graph node)
// ---------------------------------------------------------------------------

const ObjectInfo = struct {
    offset: i64,
    length: i64,
    object_type: ObjectType,
    disk_type: ObjectType,
    external_ref: bool = false,
    crc32: u32 = 0,
    parent: ?*ObjectInfo = null,
    children: std.ArrayListUnmanaged(*ObjectInfo) = .empty,
    sha1: Hash = ZeroHash,

    fn isDelta(self: *const ObjectInfo) bool {
        return self.object_type.isDelta();
    }
};

fn newBaseObject(allocator: Allocator, offset: i64, length: i64, t: ObjectType) Allocator.Error!*ObjectInfo {
    return newDeltaObject(allocator, offset, length, t, null);
}

fn newDeltaObject(
    allocator: Allocator,
    offset: i64,
    length: i64,
    t: ObjectType,
    parent: ?*ObjectInfo,
) Allocator.Error!*ObjectInfo {
    const obj = try allocator.create(ObjectInfo);
    obj.* = .{
        .offset = offset,
        .length = length,
        .object_type = t,
        .disk_type = t,
        .parent = parent,
    };
    return obj;
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

/// Decodes a packfile and calls associated observers (go-git `Parser`).
pub const Parser = struct {
    allocator: Allocator,
    scanner: *Scanner,
    storage: ?EncodedObjectStore,
    count: u32 = 0,
    oi: std.ArrayListUnmanaged(*ObjectInfo) = .empty,
    oi_by_hash: std.AutoHashMapUnmanaged(HashKey, *ObjectInfo) = .empty,
    oi_by_offset: std.AutoHashMapUnmanaged(i64, *ObjectInfo) = .empty,
    /// Content cache by pack offset (go-git BufferLRU, simplified HashMap).
    cache: std.AutoHashMapUnmanaged(i64, []u8) = .empty,
    /// Delta content by offset when source is not seekable.
    deltas: ?std.AutoHashMapUnmanaged(i64, []u8) = null,
    observers: []const Observer,

    /// Create a parser. Scanner must be seekable (go-git `NewParser`).
    pub fn init(
        allocator: Allocator,
        scanner: *Scanner,
        observers: []const Observer,
    ) Error!Parser {
        return initWithStore(allocator, scanner, null, observers);
    }

    /// Create a parser with optional storage (go-git `NewParserWithStorage`).
    /// Scanner must be seekable or `storage` must be non-null.
    pub fn initWithStorage(
        allocator: Allocator,
        scanner: *Scanner,
        storage: anytype,
        observers: []const Observer,
    ) Error!Parser {
        return initWithStore(
            allocator,
            scanner,
            EncodedObjectStore.from(@TypeOf(storage.*), storage),
            observers,
        );
    }

    /// Create a parser from an already type-erased object store.
    pub fn initWithStore(
        allocator: Allocator,
        scanner: *Scanner,
        storage: ?EncodedObjectStore,
        observers: []const Observer,
    ) Error!Parser {
        if (!scanner.is_seekable and storage == null) {
            return error.NotSeekableSource;
        }

        var deltas: ?std.AutoHashMapUnmanaged(i64, []u8) = null;
        if (!scanner.is_seekable) {
            deltas = .{};
        }

        return .{
            .allocator = allocator,
            .scanner = scanner,
            .storage = storage,
            .observers = observers,
            .deltas = deltas,
        };
    }

    pub fn deinit(self: *Parser) void {
        for (self.oi.items) |info| {
            info.children.deinit(self.allocator);
            self.allocator.destroy(info);
        }
        // Placeholder external-ref parents may sit only in oi_by_hash.
        var hash_it = self.oi_by_hash.iterator();
        while (hash_it.next()) |e| {
            const info = e.value_ptr.*;
            if (!self.oiContains(info)) {
                info.children.deinit(self.allocator);
                self.allocator.destroy(info);
            }
        }

        self.oi.deinit(self.allocator);
        self.oi_by_hash.deinit(self.allocator);
        self.oi_by_offset.deinit(self.allocator);

        var cache_it = self.cache.iterator();
        while (cache_it.next()) |e| {
            self.allocator.free(e.value_ptr.*);
        }
        self.cache.deinit(self.allocator);

        if (self.deltas) |*d| {
            var dit = d.iterator();
            while (dit.next()) |e| {
                self.allocator.free(e.value_ptr.*);
            }
            d.deinit(self.allocator);
        }

        self.* = undefined;
    }

    /// Decode the packfile; return pack checksum (go-git `Parse`).
    pub fn parse(self: *Parser) !Hash {
        self.initParse() catch |err| return wrapEof(err);

        self.indexObjects() catch |err| return wrapEof(err);

        // go-git tolerates io.EOF from Checksum and continues; any other error
        // is wrapped as MalformedPackFile when it is unexpected-EOF/EOF-like.
        const checksum = self.scanner.checksum() catch |err| {
            if (err == error.EndOfStream) {
                // No hash value available on pure error return — treat as
                // truncated pack (stricter than go-git's ZeroHash+continue).
                return error.MalformedPackFile;
            }
            return wrapEof(err);
        };

        self.resolveDeltas() catch |err| return wrapEof(err);

        try self.onFooter(checksum);
        return checksum;
    }

    fn initParse(self: *Parser) !void {
        const hdr = try self.scanner.header();
        const c = hdr[1];
        try self.onHeader(c);
        self.count = c;
        const hint = objectsHint(self.count);
        try self.oi_by_hash.ensureTotalCapacity(self.allocator, @intCast(hint));
        try self.oi_by_offset.ensureTotalCapacity(self.allocator, @intCast(hint));
        try self.oi.ensureTotalCapacity(self.allocator, hint);
    }

    fn indexObjects(self: *Parser) !void {
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            const oh = try self.scanner.nextObjectHeader();

            var delta = false;
            var ota: *ObjectInfo = undefined;

            switch (oh.object_type) {
                .ofs_delta => {
                    delta = true;
                    const parent = self.oi_by_offset.get(oh.offset_reference) orelse {
                        return error.ObjectNotFound;
                    };
                    ota = try newDeltaObject(self.allocator, oh.offset, oh.length, oh.object_type, parent);
                    try parent.children.append(self.allocator, ota);
                },
                .ref_delta => {
                    delta = true;
                    var parent: *ObjectInfo = undefined;
                    if (self.oi_by_hash.get(oh.reference)) |p| {
                        parent = p;
                    } else {
                        // Thin pack: placeholder external reference.
                        parent = try self.allocator.create(ObjectInfo);
                        parent.* = .{
                            .offset = 0,
                            .length = 0,
                            .sha1 = oh.reference,
                            .external_ref = true,
                            .object_type = .any,
                            .disk_type = .any,
                        };
                        try self.oi_by_hash.put(self.allocator, oh.reference, parent);
                    }
                    ota = try newDeltaObject(self.allocator, oh.offset, oh.length, oh.object_type, parent);
                    try parent.children.append(self.allocator, ota);
                },
                else => {
                    ota = try newBaseObject(self.allocator, oh.offset, oh.length, oh.object_type);
                },
            }
            // Free ota if inflate or later steps fail before it is stored in `oi`.
            errdefer {
                if (ota.parent) |p| {
                    var ci: usize = 0;
                    while (ci < p.children.items.len) {
                        if (p.children.items[ci] == ota) {
                            _ = p.children.orderedRemove(ci);
                        } else ci += 1;
                    }
                }
                ota.children.deinit(self.allocator);
                self.allocator.destroy(ota);
            }

            // Inflate object content into a buffer (also used for hashing / cache).
            var aw: std.Io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();

            const obj_res = try self.scanner.nextObject(&aw.writer);
            const crc = obj_res[1];
            const content = aw.written();

            // go-git indexObjects: non-delta pack objects → SetEncodedObject when
            // storage is set. REF/OFS deltas are not stored until resolveObject.
            // External bases for thin REF-deltas are loaded later via storage.get
            // in get() (placeholders are not written here).
            if (self.storage != null and !delta) {
                _ = try self.storage.?.putContent(oh.object_type, content);
            }

            ota.crc32 = crc;
            ota.length = oh.length;

            if (!delta) {
                // Match go-git NewHasher(type, declaredLength) + Write(content).
                var hasher = Hasher.init(oh.object_type, oh.length);
                hasher.update(content);
                const sha1 = hasher.sum();

                // Move children of placeholder parent into actual parent.
                if (self.oi_by_hash.get(sha1)) |placeholder| {
                    if (placeholder != ota) {
                        ota.children = placeholder.children;
                        placeholder.children = .empty;
                        for (ota.children.items) |child| {
                            child.parent = ota;
                        }
                        if (placeholder.external_ref and !self.oiContains(placeholder)) {
                            placeholder.children.deinit(self.allocator);
                            self.allocator.destroy(placeholder);
                        }
                    }
                }

                ota.sha1 = sha1;
                try self.oi_by_hash.put(self.allocator, ota.sha1, ota);
            }

            if (delta and !self.scanner.is_seekable) {
                const copy = try self.allocator.dupe(u8, content);
                errdefer self.allocator.free(copy);
                try self.deltas.?.put(self.allocator, oh.offset, copy);
            }

            try self.oi_by_offset.put(self.allocator, oh.offset, ota);
            try self.oi.append(self.allocator, ota);
        }
    }

    fn resolveDeltas(self: *Parser) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        for (self.oi.items) |obj| {
            try checkDeltaChainDepth(obj);

            buf.clearRetainingCapacity();
            try buf.ensureTotalCapacity(self.allocator, growHint(obj.length));
            try self.get(obj, &buf);

            try self.onInflatedObjectHeader(obj.object_type, obj.length, obj.offset);
            // go-git passes nil content to observers here.
            try self.onInflatedObjectContent(obj.sha1, obj.offset, obj.crc32, &.{});

            if (!obj.isDelta() and obj.children.items.len > 0) {
                for (obj.children.items) |child| {
                    try checkDeltaChainDepth(child);
                    // Discard resolved content; side-effect: sets child hash/type/size.
                    try self.resolveObject(null, child, buf.items);
                    self.resolveExternalRef(child);
                }

                if (obj.disk_type.isDelta() and !self.scanner.is_seekable) {
                    if (self.deltas) |*d| {
                        if (d.get(obj.offset)) |data| {
                            self.allocator.free(data);
                            _ = d.remove(obj.offset);
                        }
                    }
                }
            }
        }
    }

    fn resolveExternalRef(self: *Parser, o: *ObjectInfo) void {
        if (self.oi_by_hash.get(o.sha1)) |ref| {
            if (ref.external_ref) {
                self.oi_by_hash.put(self.allocator, o.sha1, o) catch return;
                o.children = ref.children;
                ref.children = .empty;
                for (o.children.items) |c| {
                    c.parent = o;
                }
                if (!self.oiContains(ref)) {
                    ref.children.deinit(self.allocator);
                    self.allocator.destroy(ref);
                }
            }
        }
    }

    fn oiContains(self: *const Parser, info: *ObjectInfo) bool {
        for (self.oi.items) |known| {
            if (known == info) return true;
        }
        return false;
    }

    fn get(self: *Parser, o: *ObjectInfo, buf: *std.ArrayList(u8)) !void {
        if (!o.external_ref) {
            if (self.cache.get(o.offset)) |cached| {
                try buf.appendSlice(self.allocator, cached);
                return;
            }
        }

        // Non-delta (or external thin-pack ref) from storage.
        // go-git: storage.EncodedObject error is returned as-is (ObjectNotFound
        // when the external base is missing from a thin pack with storage).
        // External placeholders always enter here when storage is set (Type is Any).
        // Early return without BufferLRU — go-git does not cache storage loads.
        // Caching at offset 0 would also collide across external placeholders.
        if (self.storage != null and !o.object_type.isDelta()) {
            const e = try self.storage.?.get(o.sha1);
            o.object_type = e.object_type;
            try buf.appendSlice(self.allocator, e.readerBytes());
            return;
        }

        // Thin pack external base with no storage (or storage path skipped).
        if (o.external_ref) {
            return error.ReferenceDeltaNotFound;
        }

        if (o.disk_type.isDelta()) {
            var parent_buf: std.ArrayList(u8) = .empty;
            defer parent_buf.deinit(self.allocator);
            try parent_buf.ensureTotalCapacity(self.allocator, growHint(o.length));
            try self.get(o.parent.?, &parent_buf);
            try self.resolveObject(buf, o, parent_buf.items);
        } else {
            try self.readData(buf, o);
        }

        if (o.children.items.len > 0) {
            try self.putCache(o.offset, buf.items);
        }
    }

    fn putCache(self: *Parser, offset: i64, data: []const u8) !void {
        if (self.cache.get(offset)) |_| return;
        const copy = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(copy);
        try self.cache.put(self.allocator, offset, copy);
    }

    /// Resolve delta object `o` against `base` content.
    /// When `out` is non-null, append inflated content there.
    /// Side-effect: sets o.object_type, o.length, o.sha1 when still zero hash.
    fn resolveObject(
        self: *Parser,
        out: ?*std.ArrayList(u8),
        o: *ObjectInfo,
        base: []const u8,
    ) !void {
        if (!o.disk_type.isDelta()) return;

        var delta_buf: std.ArrayList(u8) = .empty;
        defer delta_buf.deinit(self.allocator);
        try self.readData(&delta_buf, o);

        const typ: ObjectType = if (o.sha1.isZero())
            o.parent.?.object_type
        else
            o.object_type;

        const target = try patch_delta.patchDelta(self.allocator, base, delta_buf.items);
        defer self.allocator.free(target);

        if (o.sha1.isZero()) {
            o.object_type = typ;
            o.length = @intCast(target.len);
            // Match go-git patchDeltaWriter hasher (type + target size).
            var hasher = Hasher.init(typ, @intCast(target.len));
            hasher.update(target);
            o.sha1 = hasher.sum();
        }

        if (out) |buf| {
            try buf.appendSlice(self.allocator, target);
        }

        // go-git resolveObject: SetEncodedObject for resolved deltas when storage set.
        // Thin-pack REF-deltas against external bases land here after get(parent).
        if (self.storage) |store| {
            _ = try store.putContent(o.object_type, target);
        }
    }

    fn readData(self: *Parser, buf: *std.ArrayList(u8), o: *ObjectInfo) !void {
        if (!self.scanner.is_seekable and o.disk_type.isDelta()) {
            const data = self.deltas.?.get(o.offset) orelse return error.DeltaNotCached;
            try buf.appendSlice(self.allocator, data);
            return;
        }

        _ = try self.scanner.seekObjectHeader(o.offset);

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        _ = try self.scanner.nextObject(&aw.writer);
        try buf.appendSlice(self.allocator, aw.written());
    }

    // --- observer fan-out ---

    fn onHeader(self: *Parser, count: u32) !void {
        for (self.observers) |ob| {
            try ob.onHeader(count);
        }
    }

    fn onInflatedObjectHeader(self: *Parser, t: ObjectType, obj_size: i64, pos: i64) !void {
        for (self.observers) |ob| {
            try ob.onInflatedObjectHeader(t, obj_size, pos);
        }
    }

    fn onInflatedObjectContent(self: *Parser, h: Hash, pos: i64, crc: u32, content: []const u8) !void {
        for (self.observers) |ob| {
            try ob.onInflatedObjectContent(h, pos, crc, content);
        }
    }

    fn onFooter(self: *Parser, h: Hash) !void {
        for (self.observers) |ob| {
            try ob.onFooter(h);
        }
    }
};

/// Walk OFS/REF parents and reject chains deeper than `max_delta_chain_depth`.
/// go-git: `fmt.Errorf("%w: delta chain depth exceeds %d", ErrMalformedPackFile, ...)`.
/// Zig has no error wrapping; `MalformedPackFile` is the portable equivalent
/// (tests assert this error for over-depth chains).
fn checkDeltaChainDepth(o: *ObjectInfo) Error!void {
    var depth: usize = 0;
    var current: ?*ObjectInfo = o;
    while (current) |c| {
        if (!c.disk_type.isDelta()) break;
        depth += 1;
        if (depth > max_delta_chain_depth) {
            // Concept: delta chain depth exceeded (go-git message includes
            // "delta chain depth exceeds N").
            return error.MalformedPackFile;
        }
        current = c.parent;
    }
}

fn wrapEof(err: anyerror) anyerror {
    return switch (err) {
        // Truncated / mid-object failure while indexing (go-git "malformed PACK").
        error.EndOfStream, error.ZLib => error.MalformedPackFile,
        else => err,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const basic_pack_checksum_hex = "a3fed42da1e8189a077c0e6846c040dcf73fc9dd";
const basic_pack_object_count: u32 = 31;

/// Collects observer callbacks for tests.
const TestObserver = struct {
    count: u32 = 0,
    checksum: Hash = ZeroHash,
    hashes: std.ArrayListUnmanaged(Hash) = .empty,
    allocator: Allocator,

    fn deinit(self: *TestObserver) void {
        self.hashes.deinit(self.allocator);
    }

    fn onHeader(self: *TestObserver, count: u32) !void {
        self.count = count;
    }

    fn onInflatedObjectHeader(_: *TestObserver, _: ObjectType, _: i64, _: i64) !void {}

    fn onInflatedObjectContent(self: *TestObserver, h: Hash, _: i64, _: u32, _: []const u8) !void {
        try self.hashes.append(self.allocator, h);
    }

    fn onFooter(self: *TestObserver, h: Hash) !void {
        self.checksum = h;
    }
};

test "growHint and objectsHint caps" {
    try std.testing.expectEqual(@as(usize, 0), growHint(0));
    try std.testing.expectEqual(@as(usize, 0), growHint(-1));
    try std.testing.expectEqual(@as(usize, 100), growHint(100));
    try std.testing.expectEqual(max_object_prealloc_bytes, growHint(@as(i64, @intCast(max_object_prealloc_bytes)) + 1));
    try std.testing.expectEqual(@as(usize, 10), objectsHint(10));
    try std.testing.expectEqual(max_objects_prealloc, objectsHint(@as(u32, @intCast(max_objects_prealloc)) + 1));
}

test "non-seekable without storage returns NotSeekableSource" {
    const data = @import("basic_pack.zig").data();
    var r: std.Io.Reader = .fixed(data);
    var sc = Scanner.init(&r);
    try std.testing.expect(!sc.is_seekable);

    const err = Parser.init(std.testing.allocator, &sc, &.{});
    try std.testing.expectError(error.NotSeekableSource, err);
}

test "parse basic.pack seekable: checksum and 31 objects" {
    const allocator = std.testing.allocator;
    const data = @import("basic_pack.zig").data();
    // Prefer initSeekable so pack SHA-1 / CRC match the mem hashing path
    // (streaming tee can diverge with flate lookahead).
    var sc = Scanner.initSeekable(data);

    var obs: TestObserver = .{ .allocator = allocator };
    defer obs.deinit();
    const observers = [_]Observer{Observer.from(TestObserver, &obs)};

    var parser = try Parser.init(allocator, &sc, &observers);
    defer parser.deinit();

    const checksum = try parser.parse();

    var hex: [plumbing.MaxHexSize]u8 = undefined;
    try std.testing.expectEqualStrings(basic_pack_checksum_hex, checksum.string(&hex));
    try std.testing.expectEqualStrings(basic_pack_checksum_hex, obs.checksum.string(&hex));
    try std.testing.expectEqual(basic_pack_object_count, obs.count);
    try std.testing.expectEqual(@as(usize, basic_pack_object_count), obs.hashes.items.len);

    // First object hash from go-git parser_test.go TestParserHashes.
    const first_hex = "e8d3ffab552895c19b9fcf7aa264d277cde33881";
    try std.testing.expectEqualStrings(first_hex, obs.hashes.items[0].string(&hex));
}

test "ObjectStore put and get" {
    const allocator = std.testing.allocator;
    var store = ObjectStore.init(allocator);
    defer store.deinit();

    const content = "hello store";
    const h = try store.putContent(.blob, content);
    const obj = try store.get(h);
    try std.testing.expect(obj.object_type == .blob);
    try std.testing.expectEqualStrings(content, obj.readerBytes());
    try std.testing.expectError(error.ObjectNotFound, store.get(ZeroHash));
}

// ---------------------------------------------------------------------------
// UpdateObjectStorage (go-git common.go — non-PackfileWriter path)
// ---------------------------------------------------------------------------

/// go-git `UpdateObjectStorage` when the backend is **not** a `PackfileWriter`.
///
/// Parses a seekable pack image into `storage` (same as
/// `NewParserWithStorage` + `Parse`). Empty input yields `error.EmptyPackfile`
/// via `Scanner.header` (go-git `CommonSuite.TestEmptyUpdateObjectStorage`).
///
/// For backends that implement PackfileWriter, use
/// `writePackfileToObjectStorage` instead (go-git type-assert branch).
pub fn updateObjectStorage(
    allocator: Allocator,
    storage: *ObjectStore,
    pack_bytes: []const u8,
) !Hash {
    var sc = Scanner.initSeekable(pack_bytes);
    var p = try Parser.initWithStorage(allocator, &sc, storage, &.{});
    defer p.deinit();
    return p.parse();
}

test "CommonSuite.TestEmptyUpdateObjectStorage" {
    // go-git common_test.go TestEmptyUpdateObjectStorage
    const allocator = std.testing.allocator;
    var store = ObjectStore.init(allocator);
    defer store.deinit();
    try std.testing.expectError(error.EmptyPackfile, updateObjectStorage(allocator, &store, &.{}));
}

test "UpdateObjectStorage ingests basic pack into ObjectStore" {
    const allocator = std.testing.allocator;
    var store = ObjectStore.init(allocator);
    defer store.deinit();

    const pack = @import("basic_pack.zig").data();
    const checksum = try updateObjectStorage(allocator, &store, pack);
    try std.testing.expect(!checksum.isZero());

    // First object hash from go-git parser_test.go TestParserHashes.
    const first = plumbing.newHash("e8d3ffab552895c19b9fcf7aa264d277cde33881");
    const obj = try store.get(first);
    try std.testing.expect(obj.object_type != .invalid);
    try std.testing.expect(obj.size >= 0);
}

// ---------------------------------------------------------------------------
// Adversarial / security tests (go-git parser_test.go + internal_test.go)
// ---------------------------------------------------------------------------

// go-git `TestChecksumMismatch`: mutate last pack trailer byte → parse fails.
test "TestChecksumMismatch" {
    const allocator = std.testing.allocator;
    const src = @import("basic_pack.zig").data();
    const mutated = try allocator.dupe(u8, src);
    defer allocator.free(mutated);
    // Corrupt the final checksum byte (go-git seeks -1 and writes 0).
    mutated[mutated.len - 1] = 0;

    var sc = Scanner.initSeekable(mutated);
    var parser = try Parser.init(allocator, &sc, &.{});
    defer parser.deinit();

    // go-git: ErrorContains "checksum mismatch" (wrapped MalformedPackFile).
    try std.testing.expectError(error.MalformedPackFile, parser.parse());
}

// go-git `TestMalformedPack`: LimitReader(basic, 200) → malformed PACK.
test "TestMalformedPack truncated" {
    const allocator = std.testing.allocator;
    const src = @import("basic_pack.zig").data();
    const truncated = src[0..@min(200, src.len)];

    var sc = Scanner.initSeekable(truncated);
    var parser = try Parser.init(allocator, &sc, &.{});
    defer parser.deinit();

    // go-git: ErrorContains "malformed PACK" (ZLib/EOF mid-object wrap to MalformedPackFile).
    try std.testing.expectError(error.MalformedPackFile, parser.parse());
}

// go-git `TestParserRejectsOverflowingObjectHeader`.
test "TestParserRejectsOverflowingObjectHeader" {
    const allocator = std.testing.allocator;

    // PACK + version 2 + count 1 + type=commit continuation size VLQ that
    // overflows int64 shift guard, then a dummy SHA-1 trailer.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    try body.appendSlice(allocator, "PACK");
    var be: [4]u8 = undefined;
    std.mem.writeInt(u32, &be, 2, .big);
    try body.appendSlice(allocator, &be);
    std.mem.writeInt(u32, &be, 1, .big);
    try body.appendSlice(allocator, &be);
    try body.append(allocator, 0x90); // type=commit, continuation=1, low nibble=0
    try body.appendNTimes(allocator, 0x80, 9);

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(body.items);
    var sum: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    hasher.final(&sum);
    try body.appendSlice(allocator, &sum);

    var sc = Scanner.initSeekable(body.items);
    var parser = try Parser.init(allocator, &sc, &.{});
    defer parser.deinit();

    // go-git wraps LengthOverflow as MalformedPackFile ("malformed PACK").
    // Zig scanner may surface either; both reject the bad header.
    _ = parser.parse() catch |err| {
        try std.testing.expect(err == error.LengthOverflow or err == error.MalformedPackFile);
        return;
    };
    try std.testing.expect(false); // must not succeed
}

// go-git `TestParserRejectsDeepDeltaChain`.
test "TestParserRejectsDeepDeltaChain" {
    const allocator = std.testing.allocator;
    const pack = try buildLinearDeltaChainPack(allocator, max_delta_chain_depth + 1);
    defer allocator.free(pack);

    var sc = Scanner.initSeekable(pack);
    var parser = try Parser.init(allocator, &sc, &.{});
    defer parser.deinit();

    // go-git: ErrorIs ErrMalformedPackFile, ErrorContains "delta chain depth".
    try std.testing.expectError(error.MalformedPackFile, parser.parse());
}

// go-git `TestParserAcceptsMaxDepthDeltaChain`.
test "TestParserAcceptsMaxDepthDeltaChain" {
    const allocator = std.testing.allocator;
    const pack = try buildLinearDeltaChainPack(allocator, max_delta_chain_depth);
    defer allocator.free(pack);

    var sc = Scanner.initSeekable(pack);
    var parser = try Parser.init(allocator, &sc, &.{});
    defer parser.deinit();

    _ = try parser.parse();
}

// go-git `TestResolveExternalRefs` (delta-before-base fixture).
test "TestResolveExternalRefs delta-before-base" {
    const allocator = std.testing.allocator;
    const pack = @import("delta_before_base_pack.zig").data();
    var sc = Scanner.initSeekable(pack);
    var parser = try Parser.init(allocator, &sc, &.{});
    defer parser.deinit();
    _ = try parser.parse();
}

// go-git `TestResolveExternalRefsInThinPack` (codecommit fixture).
test "TestResolveExternalRefsInThinPack codecommit" {
    const allocator = std.testing.allocator;
    const pack = @import("codecommit_pack.zig").data();
    var sc = Scanner.initSeekable(pack);
    var parser = try Parser.init(allocator, &sc, &.{});
    defer parser.deinit();
    _ = try parser.parse();
}

// ---------------------------------------------------------------------------
// Synthetic pack builders (go-git internal_test.go)
// ---------------------------------------------------------------------------

const flate = std.compress.flate;
const binary_util = @import("binary");

/// go-git `buildLinearDeltaChainPack`: one base blob + `delta_count` OFS deltas.
fn buildLinearDeltaChainPack(allocator: Allocator, delta_count: usize) ![]u8 {
    var objects: std.ArrayList(TestPackObject) = .empty;
    defer {
        for (objects.items) |*o| {
            if (o.owned_content) allocator.free(o.content);
        }
        objects.deinit(allocator);
    }

    try objects.append(allocator, .{
        .typ = .blob,
        .content = &[_]u8{ 0, 0 },
        .owned_content = false,
    });

    var i: usize = 0;
    while (i < delta_count) : (i += 1) {
        const content = [_]u8{ @truncate(i + 1), @truncate((i + 1) >> 8) };
        const delta = try buildDeltaInsert(allocator, 2, 2, &content);
        try objects.append(allocator, .{
            .typ = .ofs_delta,
            .content = delta,
            .owned_content = true,
            .offset_delta_distance = -1, // previous object
        });
    }

    return try buildTestPack(allocator, objects.items);
}

const TestPackObject = struct {
    typ: ObjectType,
    declared_size: i64 = 0,
    content: []const u8,
    owned_content: bool = false,
    reference: Hash = ZeroHash,
    /// For OFS deltas; -1 means "immediately preceding object".
    offset_delta_distance: i64 = 0,
};

/// go-git `buildTestPack`.
fn buildTestPack(allocator: Allocator, objects: []const TestPackObject) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);

    try body.appendSlice(allocator, "PACK");
    var be: [4]u8 = undefined;
    std.mem.writeInt(u32, &be, 2, .big);
    try body.appendSlice(allocator, &be);
    std.mem.writeInt(u32, &be, @intCast(objects.len), .big);
    try body.appendSlice(allocator, &be);

    var offsets: std.ArrayList(i64) = .empty;
    defer offsets.deinit(allocator);

    for (objects) |obj| {
        try offsets.append(allocator, @intCast(body.items.len));

        var declared = obj.declared_size;
        if (declared == 0 and obj.content.len > 0) {
            declared = @intCast(obj.content.len);
        }
        try writeTestObjectHeader(&body, allocator, obj.typ, declared);

        switch (obj.typ) {
            .ref_delta => {
                try body.appendSlice(allocator, obj.reference.slice());
            },
            .ofs_delta => {
                var distance = obj.offset_delta_distance;
                if (distance == -1) {
                    // Reference the immediately preceding object.
                    const n = offsets.items.len;
                    distance = offsets.items[n - 1] - offsets.items[n - 2];
                }
                var vlq_buf: [16]u8 = undefined;
                var vw: std.Io.Writer = .fixed(&vlq_buf);
                try binary_util.writeVariableWidthInt(&vw, distance);
                try body.appendSlice(allocator, vw.buffered());
            },
            else => {},
        }

        const compressed = try zlibCompress(allocator, obj.content);
        defer allocator.free(compressed);
        try body.appendSlice(allocator, compressed);
    }

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(body.items);
    var sum: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    hasher.final(&sum);
    try body.appendSlice(allocator, &sum);

    return try body.toOwnedSlice(allocator);
}

/// go-git `writeTestObjectHeader`.
fn writeTestObjectHeader(list: *std.ArrayList(u8), allocator: Allocator, typ: ObjectType, size: i64) !void {
    var remaining: u64 = @intCast(size);
    var first: u8 = (@as(u8, @intCast(@intFromEnum(typ))) << 4) | @as(u8, @truncate(remaining & 0x0f));
    remaining >>= 4;
    if (remaining > 0) first |= 0x80;
    try list.append(allocator, first);
    while (remaining > 0) {
        var next: u8 = @truncate(remaining & 0x7f);
        remaining >>= 7;
        if (remaining > 0) next |= 0x80;
        try list.append(allocator, next);
    }
}

/// go-git `buildDelta` + `insertOp` for a single insert payload.
fn buildDeltaInsert(allocator: Allocator, src_sz: usize, target_sz: usize, data: []const u8) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(allocator);
    try deltaEncodeSizeAppend(&b, allocator, src_sz);
    try deltaEncodeSizeAppend(&b, allocator, target_sz);
    // insertOp: size byte (data.len must fit in 7 bits) + payload.
    std.debug.assert(data.len < 0x80);
    try b.append(allocator, @intCast(data.len));
    try b.appendSlice(allocator, data);
    return try b.toOwnedSlice(allocator);
}

/// go-git `deltaEncodeSize` (unsigned LEB128).
fn deltaEncodeSizeAppend(list: *std.ArrayList(u8), allocator: Allocator, size: usize) !void {
    var s = size;
    var c: u8 = @truncate(s & 0x7f);
    s >>= 7;
    while (s != 0) {
        try list.append(allocator, c | 0x80);
        c = @truncate(s & 0x7f);
        s >>= 7;
    }
    try list.append(allocator, c);
}

/// go-git `zlibCompress` via `std.compress.flate.Compress` (.zlib).
fn zlibCompress(allocator: Allocator, content: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 64);
    defer out.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var comp = try flate.Compress.init(&out.writer, &window, .zlib, .default);
    try comp.writer.writeAll(content);
    try comp.finish();
    return try allocator.dupe(u8, out.writer.buffered());
}

// ---------------------------------------------------------------------------
// Thin pack / REF-delta + ObjectStore (initWithStorage path)
//
// Full fixture coverage for real thin packs lives in thin_pack_tests / fixture
// workers. These unit tests use a 1-object synthetic pack that is only a
// REF-delta against an external base hash (true thin pack).
// ---------------------------------------------------------------------------

/// One-object thin pack: single REF-delta against `base_hash` producing `target`.
fn buildThinRefDeltaPack(allocator: Allocator, base_hash: Hash, base_len: usize, target: []const u8) ![]u8 {
    const delta = try buildDeltaInsert(allocator, base_len, target.len, target);
    defer allocator.free(delta);
    return try buildTestPack(allocator, &[_]TestPackObject{.{
        .typ = .ref_delta,
        .content = delta,
        .reference = base_hash,
    }});
}

test "thin pack REF-delta: missing external base with storage → ObjectNotFound" {
    // go-git parser_test.go thin pack without bases → plumbing.ErrObjectNotFound.
    const allocator = std.testing.allocator;
    const base_content = "base-blob";
    const base_hash = plumbing.computeHash(.blob, base_content);
    const target = "resolved!";

    const pack = try buildThinRefDeltaPack(allocator, base_hash, base_content.len, target);
    defer allocator.free(pack);

    var store = ObjectStore.init(allocator);
    defer store.deinit();
    // Intentionally empty — base not present.

    var sc = Scanner.initSeekable(pack);
    var parser = try Parser.initWithStorage(allocator, &sc, &store, &.{});
    defer parser.deinit();

    try std.testing.expectError(error.ObjectNotFound, parser.parse());
}

test "thin pack REF-delta: no storage → ReferenceDeltaNotFound" {
    const allocator = std.testing.allocator;
    const base_content = "base-blob";
    const base_hash = plumbing.computeHash(.blob, base_content);
    const target = "resolved!";

    const pack = try buildThinRefDeltaPack(allocator, base_hash, base_content.len, target);
    defer allocator.free(pack);

    var sc = Scanner.initSeekable(pack);
    var parser = try Parser.init(allocator, &sc, &.{});
    defer parser.deinit();

    try std.testing.expectError(error.ReferenceDeltaNotFound, parser.parse());
}

test "thin pack REF-delta: external base in ObjectStore resolves and stores result" {
    // Present external base → resolve REF-delta and put resolved object in store.
    const allocator = std.testing.allocator;
    const base_content = "base-blob";
    const base_hash = plumbing.computeHash(.blob, base_content);
    const target = "resolved!";
    const target_hash = plumbing.computeHash(.blob, target);

    const pack = try buildThinRefDeltaPack(allocator, base_hash, base_content.len, target);
    defer allocator.free(pack);

    var store = ObjectStore.init(allocator);
    defer store.deinit();
    _ = try store.putContent(.blob, base_content);

    var sc = Scanner.initSeekable(pack);
    var parser = try Parser.initWithStorage(allocator, &sc, &store, &.{});
    defer parser.deinit();

    _ = try parser.parse();

    // Resolved object written to storage (go-git SetEncodedObject in resolveObject).
    const resolved = try store.get(target_hash);
    try std.testing.expect(resolved.object_type == .blob);
    try std.testing.expectEqualStrings(target, resolved.readerBytes());
    // Base remains available.
    const base_obj = try store.get(base_hash);
    try std.testing.expectEqualStrings(base_content, base_obj.readerBytes());
}
