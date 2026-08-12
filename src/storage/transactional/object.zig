//! Transactional encoded-object storer (go-git `storage/transactional` ObjectStorage).
//!
//! Writes go to `temporal`. Reads check `base` then `temporal`.
//! `commit` copies temporal objects into base (cloned for Zig ownership).

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ObjectType = plumbing.ObjectType;
const MemoryObject = plumbing.MemoryObject;

/// go-git `transactional.ObjectStorage`.
pub const ObjectStorage = struct {
    base: *memory.Storage,
    temporal: *memory.Storage,

    pub fn init(base: *memory.Storage, temporal: *memory.Storage) ObjectStorage {
        return .{ .base = base, .temporal = temporal };
    }

    /// go-git `SetEncodedObject` — always writes to temporal.
    pub fn setEncodedObject(self: *ObjectStorage, obj: *MemoryObject) (Allocator.Error || memory.ObjectError)!Hash {
        return self.temporal.setEncodedObject(obj);
    }

    /// go-git `HasEncodedObject` — base first, then temporal.
    pub fn hasEncodedObject(self: *const ObjectStorage, h: Hash) error{ObjectNotFound}!void {
        self.base.hasEncodedObject(h) catch |err| switch (err) {
            error.ObjectNotFound => return self.temporal.hasEncodedObject(h),
        };
    }

    /// go-git `EncodedObjectSize` — base first, then temporal.
    pub fn encodedObjectSize(self: *const ObjectStorage, h: Hash) error{ObjectNotFound}!i64 {
        return self.base.encodedObjectSize(h) catch |err| switch (err) {
            error.ObjectNotFound => return self.temporal.encodedObjectSize(h),
        };
    }

    /// go-git `EncodedObject` — base first, then temporal.
    pub fn encodedObject(self: *const ObjectStorage, t: ObjectType, h: Hash) error{ObjectNotFound}!*MemoryObject {
        return self.base.encodedObject(t, h) catch |err| switch (err) {
            error.ObjectNotFound => return self.temporal.encodedObject(t, h),
        };
    }

    /// go-git `IterEncodedObjects` — multi-iter over base then temporal.
    pub fn iterEncodedObjects(self: *const ObjectStorage, t: ObjectType) Allocator.Error!MultiObjectIter {
        const base_iter = try self.base.iterEncodedObjects(t);
        errdefer {
            var bi = base_iter;
            bi.deinit();
        }
        const temporal_iter = try self.temporal.iterEncodedObjects(t);
        return MultiObjectIter.init(base_iter, temporal_iter);
    }

    /// go-git `NewEncodedObject` — factory via base (go-git embeds base storer).
    /// Caller owns until set (on temporal) or discard.
    pub fn newEncodedObject(self: *ObjectStorage) Allocator.Error!*MemoryObject {
        return self.base.newEncodedObject();
    }

    /// Discard a never-set create from `newEncodedObject` (via base factory).
    ///
    /// Frees with `obj.allocator`. If the pointer is in temporal maps (post-set
    /// misuse), removes it first. Do not discard lookup borrows from base/temporal.
    /// Requires base and temporal to share the same allocator as the object (usual).
    pub fn discardEncodedObject(self: *ObjectStorage, obj: *MemoryObject) void {
        self.temporal.discardEncodedObject(obj);
    }

    /// go-git `AddAlternate` — temporal (writes).
    pub fn addAlternate(self: *ObjectStorage, remote: []const u8) memory.ObjectError!void {
        return self.temporal.addAlternate(remote);
    }

    /// go-git `Commit` — copy every temporal object into base.
    ///
    /// Objects are cloned so both storages retain independent ownership
    /// (go-git shares pointers under GC).
    pub fn commit(self: *ObjectStorage) (Allocator.Error || memory.ObjectError)!void {
        var iter = try self.temporal.iterEncodedObjects(.any);
        defer iter.deinit();
        while (true) {
            const obj = iter.next() catch |err| switch (err) {
                error.EndOfStream => return,
            };
            const copy = try obj.cloneHeap(self.base.allocator);
            // Ownership of `copy` transfers to base on success and on
            // UnsupportedObjectType (memory stores then returns the error).
            var transferred = false;
            errdefer if (!transferred) {
                copy.deinit();
                self.base.allocator.destroy(copy);
            };
            _ = self.base.setEncodedObject(copy) catch |err| {
                if (err == error.UnsupportedObjectType) transferred = true;
                return err;
            };
            transferred = true;
        }
    }
};

/// go-git `NewObjectStorage(base, temporal)`.
pub fn newObjectStorage(base: *memory.Storage, temporal: *memory.Storage) ObjectStorage {
    return ObjectStorage.init(base, temporal);
}

/// Concatenate two object snapshot iters (go-git `MultiEncodedObjectIter`).
pub const MultiObjectIter = struct {
    first: memory.ObjectSnapshotIter,
    second: memory.ObjectSnapshotIter,
    on_second: bool = false,

    pub fn init(first: memory.ObjectSnapshotIter, second: memory.ObjectSnapshotIter) MultiObjectIter {
        return .{ .first = first, .second = second };
    }

    pub fn deinit(self: *MultiObjectIter) void {
        self.first.deinit();
        self.second.deinit();
        self.* = undefined;
    }

    pub fn next(self: *MultiObjectIter) error{EndOfStream}!*MemoryObject {
        if (!self.on_second) {
            return self.first.next() catch {
                self.on_second = true;
                return self.second.next();
            };
        }
        return self.second.next();
    }

    pub fn close(self: *MultiObjectIter) void {
        self.first.close();
        self.second.close();
        self.on_second = true;
    }

    pub fn forEach(self: *MultiObjectIter, cb: anytype) anyerror!void {
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

// ---------------------------------------------------------------------------
// Tests (go-git object_test.go)
// ---------------------------------------------------------------------------

test "HasEncodedObject base and temporal demux" {
    const allocator = std.testing.allocator;
    const base = try memory.newStorage(allocator);
    defer {
        base.deinit();
        allocator.destroy(base);
    }
    const temporal = try memory.newStorage(allocator);
    defer {
        temporal.deinit();
        allocator.destroy(temporal);
    }

    var os = ObjectStorage.init(base, temporal);

    const commit = try base.newEncodedObject();
    commit.setType(.commit);
    const ch = try base.setEncodedObject(commit);
    try std.testing.expect(!ch.isZero());

    const tree = try base.newEncodedObject();
    tree.setType(.tree);
    const th = try os.setEncodedObject(tree);
    try std.testing.expect(!th.isZero());

    try os.hasEncodedObject(th);
    try os.hasEncodedObject(ch);
    try std.testing.expectError(error.ObjectNotFound, base.hasEncodedObject(th));
}

test "EncodedObject and EncodedObjectSize demux" {
    const allocator = std.testing.allocator;
    const base = try memory.newStorage(allocator);
    defer {
        base.deinit();
        allocator.destroy(base);
    }
    const temporal = try memory.newStorage(allocator);
    defer {
        temporal.deinit();
        allocator.destroy(temporal);
    }

    var os = ObjectStorage.init(base, temporal);

    const commit = try base.newEncodedObject();
    commit.setType(.commit);
    const ch = try base.setEncodedObject(commit);

    const tree = try base.newEncodedObject();
    tree.setType(.tree);
    const th = try os.setEncodedObject(tree);

    const otree = try os.encodedObject(.tree, th);
    try std.testing.expect(otree.hash().eql(th));
    try std.testing.expectEqual(@as(i64, 0), try os.encodedObjectSize(th));

    const ocommit = try os.encodedObject(.commit, ch);
    try std.testing.expect(ocommit.hash().eql(ch));
    try std.testing.expectEqual(@as(i64, 0), try os.encodedObjectSize(ch));

    try std.testing.expectError(error.ObjectNotFound, base.encodedObject(.tree, th));
    try std.testing.expectError(error.ObjectNotFound, base.encodedObjectSize(th));
}

test "IterEncodedObjects multi base then temporal" {
    const allocator = std.testing.allocator;
    const base = try memory.newStorage(allocator);
    defer {
        base.deinit();
        allocator.destroy(base);
    }
    const temporal = try memory.newStorage(allocator);
    defer {
        temporal.deinit();
        allocator.destroy(temporal);
    }

    var os = ObjectStorage.init(base, temporal);

    const commit = try base.newEncodedObject();
    commit.setType(.commit);
    const ch = try base.setEncodedObject(commit);

    const tree = try base.newEncodedObject();
    tree.setType(.tree);
    const th = try os.setEncodedObject(tree);

    var iter = try os.iterEncodedObjects(.any);
    defer iter.deinit();

    var hashes: [2]Hash = undefined;
    var n: usize = 0;
    while (true) {
        const obj = iter.next() catch |err| switch (err) {
            error.EndOfStream => break,
        };
        try std.testing.expect(n < 2);
        hashes[n] = obj.hash();
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expect(hashes[0].eql(ch));
    try std.testing.expect(hashes[1].eql(th));
}

test "ObjectStorage Commit copies temporal into base" {
    const allocator = std.testing.allocator;
    const base = try memory.newStorage(allocator);
    defer {
        base.deinit();
        allocator.destroy(base);
    }
    const temporal = try memory.newStorage(allocator);
    defer {
        temporal.deinit();
        allocator.destroy(temporal);
    }

    var os = ObjectStorage.init(base, temporal);

    const commit = try base.newEncodedObject();
    commit.setType(.commit);
    _ = try os.setEncodedObject(commit);

    const tree = try base.newEncodedObject();
    tree.setType(.tree);
    _ = try os.setEncodedObject(tree);

    try os.commit();

    var iter = try base.iterEncodedObjects(.any);
    defer iter.deinit();
    var n: usize = 0;
    while (iter.next()) |_| {
        n += 1;
    } else |err| {
        try std.testing.expect(err == error.EndOfStream);
    }
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "write object not in base until Commit" {
    const allocator = std.testing.allocator;
    const base = try memory.newStorage(allocator);
    defer {
        base.deinit();
        allocator.destroy(base);
    }
    const temporal = try memory.newStorage(allocator);
    defer {
        temporal.deinit();
        allocator.destroy(temporal);
    }

    var os = ObjectStorage.init(base, temporal);
    const blob = try base.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write("hello-tx");
    const h = try os.setEncodedObject(blob);

    try std.testing.expectError(error.ObjectNotFound, base.hasEncodedObject(h));
    try os.hasEncodedObject(h);

    try os.commit();
    try base.hasEncodedObject(h);
}

test "memory transactional discard never-set create GPA" {
    const allocator = std.testing.allocator;
    const base = try memory.newStorage(allocator);
    defer {
        base.deinit();
        allocator.destroy(base);
    }
    const temporal = try memory.newStorage(allocator);
    defer {
        temporal.deinit();
        allocator.destroy(temporal);
    }

    var os = ObjectStorage.init(base, temporal);
    const blob = try os.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write("never-set");
    os.discardEncodedObject(blob);
}

test "memory transactional commit clones independent pointers" {
    const allocator = std.testing.allocator;
    const base = try memory.newStorage(allocator);
    defer {
        base.deinit();
        allocator.destroy(base);
    }
    const temporal = try memory.newStorage(allocator);
    defer {
        temporal.deinit();
        allocator.destroy(temporal);
    }

    var os = ObjectStorage.init(base, temporal);
    const blob = try os.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write("tx-clone");
    const h = try os.setEncodedObject(blob);
    try os.commit();

    const from_base = try base.encodedObject(.blob, h);
    const from_temp = try temporal.encodedObject(.blob, h);
    try std.testing.expect(from_base != from_temp);
    try std.testing.expectEqualStrings("tx-clone", from_base.readerBytes());
}
