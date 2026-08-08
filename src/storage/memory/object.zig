//! In-memory encoded object storage (go-git `storage/memory` ObjectStorage + TxObjectStorage).
//!
//! Stores heap-owned `*MemoryObject` values keyed by hash. Type-specific maps
//! (commits/trees/blobs/tags) mirror go-git for `IterEncodedObjects` filtering.

const std = @import("std");
const plumbing = @import("plumbing");
const mem_error = @import("error.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ObjectType = plumbing.ObjectType;
const MemoryObject = plumbing.MemoryObject;

pub const Error = mem_error.Error;

/// Object map keyed by full `Hash` (matches go-git `map[plumbing.Hash]…`).
const ObjectMap = std.AutoHashMapUnmanaged(Hash, *MemoryObject);

/// In-memory object store (go-git `memory.ObjectStorage`).
///
/// # Ownership
/// After a successful `setEncodedObject` (including when it returns
/// `error.UnsupportedObjectType`), the store owns `obj` and the caller must
/// not free it. On pure `Allocator.Error` before the map insert, the caller
/// retains ownership.
pub const ObjectStorage = struct {
    allocator: Allocator,
    objects: ObjectMap = .empty,
    commits: ObjectMap = .empty,
    trees: ObjectMap = .empty,
    blobs: ObjectMap = .empty,
    tags: ObjectMap = .empty,

    pub fn init(allocator: Allocator) ObjectStorage {
        return .{ .allocator = allocator };
    }

    /// Free every owned `MemoryObject` and clear all maps.
    pub fn deinit(self: *ObjectStorage) void {
        var it = self.objects.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            self.allocator.destroy(e.value_ptr.*);
        }
        self.objects.deinit(self.allocator);
        self.commits.deinit(self.allocator);
        self.trees.deinit(self.allocator);
        self.blobs.deinit(self.allocator);
        self.tags.deinit(self.allocator);
        self.* = undefined;
    }

    /// Heap-create an empty `MemoryObject` (go-git `NewEncodedObject`).
    /// Caller owns the pointer until `setEncodedObject` takes ownership.
    pub fn newEncodedObject(self: *const ObjectStorage) Allocator.Error!*MemoryObject {
        const obj = try self.allocator.create(MemoryObject);
        obj.* = MemoryObject.init(self.allocator);
        return obj;
    }

    /// Store `obj` and take ownership (go-git `SetEncodedObject`).
    ///
    /// Always inserts into `objects`. Type maps get commit/tree/blob/tag only.
    /// OFS/REF delta and other types still land in `objects` but return
    /// `error.UnsupportedObjectType` (go-git keeps the object and returns the error).
    pub fn setEncodedObject(self: *ObjectStorage, obj: *MemoryObject) (Allocator.Error || Error)!Hash {
        const h = obj.hash();

        // Peek previous without removing so a failed `put` cannot drop it.
        const previous = self.objects.get(h);

        try self.objects.put(self.allocator, h, obj);

        // Ownership transferred. Free the displaced object (if different).
        if (previous) |old| {
            if (old != obj) {
                self.removeFromTypeMaps(h, old.object_type);
                old.deinit();
                self.allocator.destroy(old);
            } else {
                // Same pointer re-inserted (type may have changed).
                self.removeFromTypeMaps(h, old.object_type);
            }
        }

        switch (obj.object_type) {
            .commit => try self.commits.put(self.allocator, h, obj),
            .tree => try self.trees.put(self.allocator, h, obj),
            .blob => try self.blobs.put(self.allocator, h, obj),
            .tag => try self.tags.put(self.allocator, h, obj),
            else => return error.UnsupportedObjectType,
        }
        return h;
    }

    fn removeFromTypeMaps(self: *ObjectStorage, h: Hash, t: ObjectType) void {
        switch (t) {
            .commit => _ = self.commits.remove(h),
            .tree => _ = self.trees.remove(h),
            .blob => _ = self.blobs.remove(h),
            .tag => _ = self.tags.remove(h),
            else => {},
        }
    }

    /// Look up by hash and type (go-git `EncodedObject`).
    /// `ObjectType.any` matches any stored type.
    pub fn encodedObject(self: *const ObjectStorage, t: ObjectType, h: Hash) error{ObjectNotFound}!*MemoryObject {
        const obj = self.objects.get(h) orelse return error.ObjectNotFound;
        if (t != .any and obj.object_type != t) return error.ObjectNotFound;
        return obj;
    }

    /// `error.ObjectNotFound` if missing; otherwise success (go-git `HasEncodedObject`).
    pub fn hasEncodedObject(self: *const ObjectStorage, h: Hash) error{ObjectNotFound}!void {
        if (!self.objects.contains(h)) return error.ObjectNotFound;
    }

    /// Plaintext size of the stored object (go-git `EncodedObjectSize`).
    pub fn encodedObjectSize(self: *const ObjectStorage, h: Hash) error{ObjectNotFound}!i64 {
        const obj = self.objects.get(h) orelse return error.ObjectNotFound;
        return obj.size;
    }

    /// Snapshot iterator over objects of type `t` (go-git `IterEncodedObjects`).
    /// Caller must `deinit` the iterator (frees the snapshot slice; not the objects).
    pub fn iterEncodedObjects(self: *const ObjectStorage, t: ObjectType) Allocator.Error!ObjectSnapshotIter {
        const map: *const ObjectMap = switch (t) {
            .any => &self.objects,
            .commit => &self.commits,
            .tree => &self.trees,
            .blob => &self.blobs,
            .tag => &self.tags,
            else => {
                // go-git leaves series nil for unknown types → empty iter.
                return ObjectSnapshotIter.empty(self.allocator);
            },
        };
        return try ObjectSnapshotIter.fromMap(self.allocator, map);
    }

    /// Start a write transaction (go-git `Begin`).
    pub fn begin(self: *ObjectStorage) TxObjectStorage {
        return TxObjectStorage.init(self);
    }

    /// Visit every object hash (go-git `ForEachObjectHash`).
    ///
    /// Context-aware callback: `fun(ctx, hash)`. Stack (or heap) context is
    /// passed explicitly — no process-local statics. Concurrent-safe for
    /// distinct `ObjectStorage` instances; a single storage is still not
    /// thread-safe for concurrent mutation.
    ///
    /// If `fun` returns `error.Stop`, iteration ends with success (storer.ErrStop).
    pub fn forEachObjectHash(
        self: *const ObjectStorage,
        ctx: anytype,
        comptime fun: *const fn (@TypeOf(ctx), Hash) anyerror!void,
    ) anyerror!void {
        var it = self.objects.keyIterator();
        while (it.next()) |key| {
            fun(ctx, key.*) catch |err| {
                const e: anyerror = err;
                if (e == error.Stop) return;
                return e;
            };
        }
    }

    /// Memory backend has no packs (go-git `ObjectPacks` → nil).
    /// Returns a zero-length slice; do not free.
    pub fn objectPacks(self: *const ObjectStorage) []const Hash {
        _ = self;
        return &.{};
    }

    /// go-git `DeleteOldObjectPackAndIndex` — no-op for memory.
    pub fn deleteOldObjectPackAndIndex(self: *ObjectStorage, _: Hash, _: i64) void {
        _ = self;
    }

    /// go-git `LooseObjectTime` — not supported.
    pub fn looseObjectTime(self: *const ObjectStorage, _: Hash) Error!i64 {
        _ = self;
        return error.NotSupported;
    }

    /// go-git `DeleteLooseObject` — not supported.
    pub fn deleteLooseObject(self: *ObjectStorage, _: Hash) Error!void {
        _ = self;
        return error.NotSupported;
    }

    /// go-git `AddAlternate` — not supported.
    pub fn addAlternate(self: *ObjectStorage, remote: []const u8) Error!void {
        _ = self;
        _ = remote;
        return error.NotSupported;
    }
};

/// Transactional write buffer (go-git `TxObjectStorage`).
pub const TxObjectStorage = struct {
    storage: *ObjectStorage,
    objects: ObjectMap = .empty,

    pub fn init(storage: *ObjectStorage) TxObjectStorage {
        return .{ .storage = storage };
    }

    /// Free any uncommitted objects and the map (safe after commit/rollback too).
    pub fn deinit(self: *TxObjectStorage) void {
        var it = self.objects.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            self.storage.allocator.destroy(e.value_ptr.*);
        }
        self.objects.deinit(self.storage.allocator);
        self.* = undefined;
    }

    /// Buffer `obj` for this transaction; takes ownership (go-git `SetEncodedObject`).
    pub fn setEncodedObject(self: *TxObjectStorage, obj: *MemoryObject) Allocator.Error!Hash {
        const h = obj.hash();
        const previous = self.objects.get(h);
        try self.objects.put(self.storage.allocator, h, obj);
        if (previous) |old| {
            if (old != obj) {
                old.deinit();
                self.storage.allocator.destroy(old);
            }
        }
        return h;
    }

    /// Look up only in the transaction buffer (go-git `EncodedObject`).
    pub fn encodedObject(self: *const TxObjectStorage, t: ObjectType, h: Hash) error{ObjectNotFound}!*MemoryObject {
        const obj = self.objects.get(h) orelse return error.ObjectNotFound;
        if (t != .any and obj.object_type != t) return error.ObjectNotFound;
        return obj;
    }

    /// Merge buffered objects into the parent store (go-git `Commit`).
    /// Each object is removed from the tx map then handed to parent `setEncodedObject`
    /// (same order as go-git: delete from tx, then Set on parent).
    pub fn commit(self: *TxObjectStorage) (Allocator.Error || Error)!void {
        while (self.objects.count() > 0) {
            var it = self.objects.iterator();
            const e = it.next().?;
            const key = e.key_ptr.*;
            const obj = e.value_ptr.*;
            _ = self.objects.remove(key);
            // Ownership moves to parent (object stays there even on UnsupportedObjectType).
            _ = try self.storage.setEncodedObject(obj);
        }
    }

    /// Drop all buffered objects without applying them (go-git `Rollback`).
    pub fn rollback(self: *TxObjectStorage) void {
        var it = self.objects.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            self.storage.allocator.destroy(e.value_ptr.*);
        }
        self.objects.clearRetainingCapacity();
    }
};

/// Snapshot iterator over stored objects (go-git `IterEncodedObjects` series).
///
/// Distinct from `plumbing/storer.EncodedObjectSliceIter`, which borrows a
/// caller slice. This type owns a heap snapshot of pointers into the store;
/// it does **not** own the `MemoryObject`s themselves. Always `deinit`.
pub const ObjectSnapshotIter = struct {
    allocator: Allocator,
    /// Heap snapshot of object pointers (owned when non-null).
    owned: ?[]*MemoryObject = null,
    items: []*MemoryObject = &.{},
    pos: usize = 0,

    pub fn empty(allocator: Allocator) ObjectSnapshotIter {
        return .{ .allocator = allocator };
    }

    pub fn fromMap(allocator: Allocator, map: *const ObjectMap) Allocator.Error!ObjectSnapshotIter {
        var list: std.ArrayList(*MemoryObject) = .empty;
        errdefer list.deinit(allocator);
        try list.ensureTotalCapacity(allocator, map.count());
        var it = map.valueIterator();
        while (it.next()) |vp| {
            list.appendAssumeCapacity(vp.*);
        }
        const owned = try list.toOwnedSlice(allocator);
        return .{
            .allocator = allocator,
            .owned = owned,
            .items = owned,
        };
    }

    pub fn deinit(self: *ObjectSnapshotIter) void {
        if (self.owned) |o| self.allocator.free(o);
        self.* = undefined;
    }

    /// Next object or `error.EndOfStream` (go-git `io.EOF`).
    pub fn next(self: *ObjectSnapshotIter) error{EndOfStream}!*MemoryObject {
        if (self.pos >= self.items.len) return error.EndOfStream;
        const obj = self.items[self.pos];
        self.pos += 1;
        return obj;
    }

    /// End iteration without freeing the snapshot (go-git `Close`).
    pub fn close(self: *ObjectSnapshotIter) void {
        self.pos = self.items.len;
    }

    /// Call `cb` for each remaining object; `error.Stop` ends successfully.
    /// Closes the iterator when finished (go-git `ForEach`). `cb` is anytype.
    pub fn forEach(self: *ObjectSnapshotIter, cb: anytype) anyerror!void {
        defer self.close();
        while (true) {
            const obj = self.next() catch |err| switch (err) {
                error.EndOfStream => return,
            };
            @call(.auto, cb, .{obj}) catch |err| {
                const e: anyerror = err;
                if (e == error.Stop) return;
                return e;
            };
        }
    }
};

/// Historical alias — prefer `ObjectSnapshotIter` (map snapshot, not storer slice iter).
pub const EncodedObjectSliceIter = ObjectSnapshotIter;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn makeBlob(allocator: Allocator, content: []const u8) !*MemoryObject {
    const obj = try allocator.create(MemoryObject);
    errdefer allocator.destroy(obj);
    obj.* = MemoryObject.init(allocator);
    errdefer obj.deinit();
    obj.setType(.blob);
    try obj.setContent(content);
    return obj;
}

fn makeTyped(allocator: Allocator, t: ObjectType, content: []const u8) !*MemoryObject {
    const obj = try allocator.create(MemoryObject);
    errdefer allocator.destroy(obj);
    obj.* = MemoryObject.init(allocator);
    errdefer obj.deinit();
    obj.setType(t);
    try obj.setContent(content);
    return obj;
}

test "ObjectStorage init deinit empty" {
    var store = ObjectStorage.init(std.testing.allocator);
    defer store.deinit();
}

test "ObjectStorage set get has size" {
    var store = ObjectStorage.init(std.testing.allocator);
    defer store.deinit();

    const obj = try store.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write("hello");
    const h = try store.setEncodedObject(obj);

    try store.hasEncodedObject(h);
    try std.testing.expectError(error.ObjectNotFound, store.hasEncodedObject(plumbing.ZeroHash));

    const got = try store.encodedObject(.blob, h);
    try std.testing.expect(got == obj);
    try std.testing.expectEqualStrings("hello", got.readerBytes());

    const any = try store.encodedObject(.any, h);
    try std.testing.expect(any == obj);

    try std.testing.expectError(error.ObjectNotFound, store.encodedObject(.commit, h));
    try std.testing.expectError(error.ObjectNotFound, store.encodedObject(.blob, plumbing.ZeroHash));

    try std.testing.expectEqual(@as(i64, 5), try store.encodedObjectSize(h));
    try std.testing.expectError(error.ObjectNotFound, store.encodedObjectSize(plumbing.ZeroHash));
}

test "ObjectStorage type maps and iter" {
    var store = ObjectStorage.init(std.testing.allocator);
    defer store.deinit();

    const b1 = try makeBlob(std.testing.allocator, "a");
    const b2 = try makeBlob(std.testing.allocator, "b");
    const c1 = try makeTyped(std.testing.allocator, .commit, "commit-body");
    _ = try store.setEncodedObject(b1);
    _ = try store.setEncodedObject(b2);
    _ = try store.setEncodedObject(c1);

    var blob_iter = try store.iterEncodedObjects(.blob);
    defer blob_iter.deinit();
    var blob_count: usize = 0;
    while (blob_iter.next()) |_| {
        blob_count += 1;
    } else |err| {
        try std.testing.expect(err == error.EndOfStream);
    }
    try std.testing.expectEqual(@as(usize, 2), blob_count);

    var commit_iter = try store.iterEncodedObjects(.commit);
    defer commit_iter.deinit();
    const only = try commit_iter.next();
    try std.testing.expect(only.object_type == .commit);
    try std.testing.expectError(error.EndOfStream, commit_iter.next());

    var any_iter = try store.iterEncodedObjects(.any);
    defer any_iter.deinit();
    var any_count: usize = 0;
    while (any_iter.next()) |_| {
        any_count += 1;
    } else |_| {}
    try std.testing.expectEqual(@as(usize, 3), any_count);
}

test "ObjectStorage UnsupportedObjectType for deltas still stores in objects" {
    var store = ObjectStorage.init(std.testing.allocator);
    defer store.deinit();

    const ofs = try makeTyped(std.testing.allocator, .ofs_delta, "delta");
    const h = ofs.hash();
    try std.testing.expectError(error.UnsupportedObjectType, store.setEncodedObject(ofs));

    // go-git still inserts into Objects before the type switch fails.
    try store.hasEncodedObject(h);
    const got = try store.encodedObject(.any, h);
    try std.testing.expect(got.object_type == .ofs_delta);

    var blob_iter = try store.iterEncodedObjects(.blob);
    defer blob_iter.deinit();
    try std.testing.expectError(error.EndOfStream, blob_iter.next());
}

test "ObjectStorage ref_delta UnsupportedObjectType" {
    var store = ObjectStorage.init(std.testing.allocator);
    defer store.deinit();

    const refd = try makeTyped(std.testing.allocator, .ref_delta, "refd");
    try std.testing.expectError(error.UnsupportedObjectType, store.setEncodedObject(refd));
}

test "ObjectStorage forEachObjectHash and Stop" {
    var store = ObjectStorage.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.setEncodedObject(try makeBlob(std.testing.allocator, "x"));
    _ = try store.setEncodedObject(try makeBlob(std.testing.allocator, "y"));

    const Counter = struct {
        n: usize = 0,
        fn cb(self: *@This(), _: Hash) anyerror!void {
            self.n += 1;
        }
        fn stopAfterOne(self: *@This(), _: Hash) anyerror!void {
            self.n += 1;
            return error.Stop;
        }
    };
    var counter = Counter{};
    try store.forEachObjectHash(&counter, Counter.cb);
    try std.testing.expectEqual(@as(usize, 2), counter.n);

    counter.n = 0;
    try store.forEachObjectHash(&counter, Counter.stopAfterOne);
    try std.testing.expectEqual(@as(usize, 1), counter.n);
}

test "ObjectStorage objectPacks empty and addAlternate" {
    var store = ObjectStorage.init(std.testing.allocator);
    defer store.deinit();

    const packs = store.objectPacks();
    try std.testing.expectEqual(@as(usize, 0), packs.len);
    try std.testing.expectError(error.NotSupported, store.addAlternate("/tmp/alt"));
    try std.testing.expectError(error.NotSupported, store.looseObjectTime(plumbing.ZeroHash));
    try std.testing.expectError(error.NotSupported, store.deleteLooseObject(plumbing.ZeroHash));
}

test "TxObjectStorage commit merges into parent" {
    var store = ObjectStorage.init(std.testing.allocator);
    defer store.deinit();

    var tx = store.begin();
    defer tx.deinit();

    const obj = try makeBlob(std.testing.allocator, "tx-blob");
    const h = try tx.setEncodedObject(obj);

    // Visible in tx, not in parent yet.
    _ = try tx.encodedObject(.blob, h);
    try std.testing.expectError(error.ObjectNotFound, store.encodedObject(.blob, h));

    try tx.commit();
    const got = try store.encodedObject(.blob, h);
    try std.testing.expectEqualStrings("tx-blob", got.readerBytes());
}

test "TxObjectStorage rollback discards" {
    var store = ObjectStorage.init(std.testing.allocator);
    defer store.deinit();

    var tx = store.begin();
    defer tx.deinit();

    const obj = try makeBlob(std.testing.allocator, "gone");
    const h = try tx.setEncodedObject(obj);
    tx.rollback();

    try std.testing.expectError(error.ObjectNotFound, tx.encodedObject(.any, h));
    try std.testing.expectError(error.ObjectNotFound, store.encodedObject(.any, h));
}

test "TxObjectStorage encodedObject type filter" {
    var store = ObjectStorage.init(std.testing.allocator);
    defer store.deinit();

    var tx = store.begin();
    defer tx.deinit();

    const obj = try makeBlob(std.testing.allocator, "t");
    const h = try tx.setEncodedObject(obj);
    try std.testing.expectError(error.ObjectNotFound, tx.encodedObject(.tree, h));
    _ = try tx.encodedObject(.any, h);
    tx.rollback();
}

test "ObjectSnapshotIter forEach Stop" {
    var store = ObjectStorage.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.setEncodedObject(try makeBlob(std.testing.allocator, "1"));
    _ = try store.setEncodedObject(try makeBlob(std.testing.allocator, "2"));
    _ = try store.setEncodedObject(try makeBlob(std.testing.allocator, "3"));

    var iter = try store.iterEncodedObjects(.blob);
    defer iter.deinit();

    const S = struct {
        var n: usize = 0;
        fn cb(_: *MemoryObject) anyerror!void {
            n += 1;
            if (n == 1) return error.Stop;
        }
    };
    S.n = 0;
    try iter.forEach(S.cb);
    try std.testing.expectEqual(@as(usize, 1), S.n);
}

test "ObjectStorage replace same hash frees previous" {
    var store = ObjectStorage.init(std.testing.allocator);
    defer store.deinit();

    // Same content → same hash; second set replaces first.
    const a = try makeBlob(std.testing.allocator, "same");
    const b = try makeBlob(std.testing.allocator, "same");
    const h1 = try store.setEncodedObject(a);
    const h2 = try store.setEncodedObject(b);
    try std.testing.expect(h1.eql(h2));
    const got = try store.encodedObject(.blob, h1);
    try std.testing.expect(got == b);
}

test "ObjectStorage tree tag type maps" {
    var store = ObjectStorage.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.setEncodedObject(try makeTyped(std.testing.allocator, .tree, "tree-data"));
    _ = try store.setEncodedObject(try makeTyped(std.testing.allocator, .tag, "tag-data"));

    var trees = try store.iterEncodedObjects(.tree);
    defer trees.deinit();
    try std.testing.expect((try trees.next()).object_type == .tree);

    var tags = try store.iterEncodedObjects(.tag);
    defer tags.deinit();
    try std.testing.expect((try tags.next()).object_type == .tag);
}

test "ObjectStorage invalid type UnsupportedObjectType still stores" {
    var store = ObjectStorage.init(std.testing.allocator);
    defer store.deinit();

    const inv = try makeTyped(std.testing.allocator, .invalid, "x");
    const h = inv.hash();
    try std.testing.expectError(error.UnsupportedObjectType, store.setEncodedObject(inv));
    try store.hasEncodedObject(h);
    // Not in type maps
    var commits = try store.iterEncodedObjects(.commit);
    defer commits.deinit();
    try std.testing.expectError(error.EndOfStream, commits.next());
}

test "ObjectStorage iter unknown type is empty" {
    var store = ObjectStorage.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.setEncodedObject(try makeBlob(std.testing.allocator, "z"));
    var iter = try store.iterEncodedObjects(.ofs_delta);
    defer iter.deinit();
    try std.testing.expectError(error.EndOfStream, iter.next());
}

test "TxObjectStorage commit UnsupportedObjectType still lands in parent" {
    var store = ObjectStorage.init(std.testing.allocator);
    defer store.deinit();

    var tx = store.begin();
    defer tx.deinit();

    const delta = try makeTyped(std.testing.allocator, .ofs_delta, "d");
    const h = try tx.setEncodedObject(delta);
    // go-git Commit: SetEncodedObject stores then returns ErrUnsupportedObjectType.
    try std.testing.expectError(error.UnsupportedObjectType, tx.commit());
    try store.hasEncodedObject(h);
    const got = try store.encodedObject(.any, h);
    try std.testing.expect(got.object_type == .ofs_delta);
}

test "TxObjectStorage set replaces same hash in buffer" {
    var store = ObjectStorage.init(std.testing.allocator);
    defer store.deinit();

    var tx = store.begin();
    defer tx.deinit();

    const a = try makeBlob(std.testing.allocator, "same-tx");
    const b = try makeBlob(std.testing.allocator, "same-tx");
    const h1 = try tx.setEncodedObject(a);
    const h2 = try tx.setEncodedObject(b);
    try std.testing.expect(h1.eql(h2));
    const got = try tx.encodedObject(.blob, h1);
    try std.testing.expect(got == b);
    tx.rollback();
}

test "ObjectStorage deleteOldObjectPackAndIndex is no-op" {
    var store = ObjectStorage.init(std.testing.allocator);
    defer store.deinit();
    store.deleteOldObjectPackAndIndex(plumbing.ZeroHash, 0);
}
