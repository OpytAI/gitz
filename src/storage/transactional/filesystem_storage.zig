//! Transactional storage over filesystem storers.
//!
//! go-git accepts arbitrary `storage.Storer` values. Zig cannot store an
//! interface value without erasure, so this implementation monomorphises the
//! same demux over `filesystem.StorageFor(Fs)`. It covers both `fs.Mem` and
//! `fs.Os`, including the live PackfileWriter delegation to the temporal store.

const std = @import("std");
const plumbing = @import("plumbing");
const filesystem = @import("filesystem");
const fs_pkg = @import("fs");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const MemoryObject = plumbing.MemoryObject;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;

pub fn StorageFor(comptime Fs: type) type {
    const Store = filesystem.StorageFor(Fs);
    const ObjectIter = Store.ObjectHashIter;
    const ReferenceIter = filesystem.ReferenceSliceIter;

    return struct {
        const Self = @This();

        allocator: Allocator,
        base: *Store,
        temporal: *Store,
        deleted: std.StringHashMapUnmanaged(void) = .empty,
        index_set: bool = false,
        config_set: bool = false,
        nested: std.ArrayListUnmanaged(*Self) = .empty,

        pub const implements_packfile_writer = true;
        pub const Index = Store.Index;
        pub const Config = Store.Config;

        pub fn init(base: *Store, temporal: *Store) Self {
            return .{ .allocator = base.allocator, .base = base, .temporal = temporal };
        }

        pub fn deinit(self: *Self) void {
            for (self.nested.items) |child| {
                child.deinit();
                self.allocator.destroy(child);
            }
            self.nested.deinit(self.allocator);
            var it = self.deleted.keyIterator();
            while (it.next()) |key| self.allocator.free(key.*);
            self.deleted.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn newEncodedObject(self: *Self) Allocator.Error!*MemoryObject {
            return self.base.newEncodedObject();
        }

        pub fn setEncodedObject(self: *Self, obj: *MemoryObject) anyerror!Hash {
            return self.temporal.setEncodedObject(obj);
        }

        pub fn hasEncodedObject(self: *Self, h: Hash) anyerror!void {
            self.base.hasEncodedObject(h) catch |err| switch (err) {
                error.ObjectNotFound => return self.temporal.hasEncodedObject(h),
                else => return err,
            };
        }

        pub fn encodedObjectSize(self: *Self, h: Hash) anyerror!i64 {
            return self.base.encodedObjectSize(h) catch |err| switch (err) {
                error.ObjectNotFound => self.temporal.encodedObjectSize(h),
                else => return err,
            };
        }

        pub fn encodedObject(self: *Self, t: plumbing.ObjectType, h: Hash) anyerror!*MemoryObject {
            return self.base.encodedObject(t, h) catch |err| switch (err) {
                error.ObjectNotFound => self.temporal.encodedObject(t, h),
                else => return err,
            };
        }

        pub fn iterEncodedObjects(self: *Self, t: plumbing.ObjectType) anyerror!MultiObjectIter {
            const first = try self.base.iterEncodedObjects(t);
            errdefer {
                var owned = first;
                owned.deinit();
            }
            return .{ .first = first, .second = try self.temporal.iterEncodedObjects(t) };
        }

        pub const MultiObjectIter = struct {
            first: ObjectIter,
            second: ObjectIter,
            on_second: bool = false,

            pub fn deinit(self: *@This()) void {
                self.first.deinit();
                self.second.deinit();
                self.* = undefined;
            }

            pub fn next(self: *@This()) error{EndOfStream}!*MemoryObject {
                if (!self.on_second) return self.first.next() catch {
                    self.on_second = true;
                    return self.second.next();
                };
                return self.second.next();
            }
        };

        /// Live go-git PackfileWriter demux: raw packs always enter temporal.
        pub fn packfileWriter(self: *Self) @TypeOf(self.temporal.packfileWriter()) {
            return self.temporal.packfileWriter();
        }

        pub fn addAlternate(self: *Self, remote: []const u8) anyerror!void {
            return self.temporal.addAlternate(remote);
        }

        pub fn setReference(self: *Self, ref: Reference) anyerror!void {
            self.clearDeleted(ref.name);
            return self.temporal.setReference(ref);
        }

        pub fn reference(self: *Self, name: ReferenceName) anyerror!Reference {
            if (self.deleted.contains(name.raw)) return error.ReferenceNotFound;
            return self.temporal.reference(name) catch |err| switch (err) {
                error.ReferenceNotFound => self.base.reference(name),
                else => return err,
            };
        }

        pub fn checkAndSetReference(self: *Self, ref: ?Reference, old: ?Reference) anyerror!void {
            const next = ref orelse return;
            if (old) |expected| {
                const current = try self.reference(expected.name);
                defer freeReference(self, current);
                if (!current.hash.eql(expected.hash)) return error.ReferenceHasChanged;
            }
            try self.setReference(next);
        }

        pub fn removeReference(self: *Self, name: ReferenceName) Allocator.Error!void {
            if (!self.deleted.contains(name.raw)) {
                const key = try self.allocator.dupe(u8, name.raw);
                errdefer self.allocator.free(key);
                try self.deleted.put(self.allocator, key, {});
            }
            self.temporal.removeReference(name) catch {};
        }

        pub fn iterReferences(self: *Self) anyerror!MultiReferenceIter {
            const first = try self.base.iterReferences();
            errdefer {
                var owned = first;
                owned.deinit();
            }
            return .{ .first = first, .second = try self.temporal.iterReferences() };
        }

        pub const MultiReferenceIter = struct {
            first: ReferenceIter,
            second: ReferenceIter,
            on_second: bool = false,

            pub fn deinit(self: *@This()) void {
                self.first.deinit();
                self.second.deinit();
                self.* = undefined;
            }

            pub fn next(self: *@This()) error{EndOfStream}!Reference {
                if (!self.on_second) return self.first.next() catch {
                    self.on_second = true;
                    return self.second.next();
                };
                return self.second.next();
            }
        };

        pub fn countLooseRefs(self: *Self) anyerror!usize {
            const base_count = try self.base.countLooseRefs();
            const temporal_count = try self.temporal.countLooseRefs();
            return base_count + temporal_count;
        }

        pub fn packRefs(_: *Self) void {}

        pub fn setShallow(self: *Self, commits: []const Hash) anyerror!void {
            return self.temporal.setShallow(commits);
        }

        pub fn shallow(self: *Self) anyerror![]const Hash {
            const temporal = try self.temporal.shallow();
            if (temporal.len != 0) return temporal;
            return self.base.shallow();
        }

        pub fn setIndex(self: *Self, idx: *Index) anyerror!void {
            try self.temporal.setIndex(idx);
            self.index_set = true;
        }

        pub fn index(self: *Self) anyerror!*Index {
            if (self.index_set) return self.temporal.index();
            return self.base.index();
        }

        pub fn setConfig(self: *Self, cfg: *Config) anyerror!void {
            try self.temporal.setConfig(cfg);
            self.config_set = true;
        }

        pub fn config(self: *Self) anyerror!*Config {
            if (self.config_set) return self.temporal.config();
            return self.base.config();
        }

        pub fn module(self: *Self, name: []const u8) anyerror!*Self {
            const base_module = try self.base.module(name);
            const temporal_module = try self.temporal.module(name);
            const child = try self.allocator.create(Self);
            errdefer self.allocator.destroy(child);
            child.* = Self.init(base_module, temporal_module);
            try self.nested.append(self.allocator, child);
            return child;
        }

        /// Merge the filesystem temporal store into base without transferring
        /// ownership of temporal pointers.
        pub fn commit(self: *Self) anyerror!void {
            var objects = try self.temporal.iterEncodedObjects(.any);
            defer objects.deinit();
            while (objects.next()) |obj| {
                // Filesystem SetEncodedObject serializes immediately and does
                // not retain the pointer. The temporal store keeps ownership.
                _ = try self.base.setEncodedObject(obj);
            } else |err| if (err != error.EndOfStream) return err;

            var deleted = self.deleted.keyIterator();
            while (deleted.next()) |name| self.base.removeReference(ReferenceName.init(name.*)) catch {};

            var refs = try self.temporal.iterReferences();
            defer refs.deinit();
            while (refs.next()) |ref| try self.base.setReference(ref) else |err| if (err != error.EndOfStream) return err;

            const temporal_shallow = try self.temporal.shallow();
            if (temporal_shallow.len != 0) try self.base.setShallow(temporal_shallow);
            if (self.index_set) try self.base.setIndex(try self.temporal.index());
            if (self.config_set) {
                const cfg = try cloneConfig(self.base.allocator, try self.temporal.config());
                self.base.setConfig(cfg) catch |err| {
                    cfg.deinit();
                    self.base.allocator.destroy(cfg);
                    return err;
                };
            }
        }

        fn clearDeleted(self: *Self, name: ReferenceName) void {
            if (self.deleted.fetchRemove(name.raw)) |entry| self.allocator.free(entry.key);
        }

        fn freeReference(self: *Self, ref: Reference) void {
            if (comptime Store.reference_returns_owned) {
                if (ref.name.raw.len > 0) self.allocator.free(ref.name.raw);
                if (ref.type == .symbolic and ref.target.raw.len > 0) self.allocator.free(ref.target.raw);
            }
        }
    };
}

pub const StorageMem = StorageFor(fs_pkg.Mem);
pub const StorageOs = StorageFor(fs_pkg.Os);

fn cloneConfig(allocator: Allocator, src: *const filesystem.Config) Allocator.Error!*filesystem.Config {
    const dst = try allocator.create(filesystem.Config);
    dst.* = filesystem.Config.init(allocator);
    errdefer {
        dst.deinit();
        allocator.destroy(dst);
    }
    dst.is_bare = src.is_bare;
    if (src.repository_format_version.len > 0) try dst.setRepositoryFormatVersion(src.repository_format_version);
    if (src.object_format.len > 0) try dst.setObjectFormat(src.object_format);
    if (src.user_name.len > 0 or src.user_email.len > 0) try dst.setUser(src.user_name, src.user_email);
    if (src.author_name.len > 0 or src.author_email.len > 0) try dst.setAuthor(src.author_name, src.author_email);
    if (src.committer_name.len > 0 or src.committer_email.len > 0) try dst.setCommitter(src.committer_name, src.committer_email);
    var remotes = src.remotes.iterator();
    while (remotes.next()) |entry| {
        var urls: std.ArrayList([]const u8) = .empty;
        defer urls.deinit(allocator);
        for (entry.value_ptr.urls) |url| try urls.append(allocator, url);
        var fetch: std.ArrayList([]const u8) = .empty;
        defer fetch.deinit(allocator);
        for (entry.value_ptr.fetch) |refspec| try fetch.append(allocator, refspec);
        try dst.putRemoteFull(entry.key_ptr.*, urls.items, fetch.items, entry.value_ptr.mirror);
    }
    var branches = src.branches.iterator();
    while (branches.next()) |entry| {
        try dst.putBranch(entry.value_ptr.name, entry.value_ptr.remote, entry.value_ptr.merge);
    }
    return dst;
}

test "filesystem transaction commits temporal objects and exposes PackfileWriter" {
    const allocator = std.testing.allocator;
    // Filesystem loose-object writes retain one zlib writer node and its
    // window in the package free list. Production retains that cache by
    // design; leak-checking tests must explicitly drain it.
    defer @import("utils/sync").deinitPools(allocator);
    var base_fs = try fs_pkg.Mem.init(allocator);
    defer base_fs.deinit();
    var temporal_fs = try fs_pkg.Mem.init(allocator);
    defer temporal_fs.deinit();

    const base = try filesystem.newStorage(allocator, &base_fs, null);
    defer {
        base.deinit();
        allocator.destroy(base);
    }
    const temporal = try filesystem.newStorage(allocator, &temporal_fs, null);
    defer {
        temporal.deinit();
        allocator.destroy(temporal);
    }
    try base.initLayout();
    try temporal.initLayout();

    var tx = StorageMem.init(base, temporal);
    defer tx.deinit();
    try std.testing.expect(StorageMem.implements_packfile_writer);
    try std.testing.expect(@TypeOf(StorageMem.packfileWriter) != void);

    const obj = try tx.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write("transactional filesystem");
    const hash = try tx.setEncodedObject(obj);
    try std.testing.expectError(error.ObjectNotFound, base.hasEncodedObject(hash));
    try tx.commit();
    try base.hasEncodedObject(hash);
}
