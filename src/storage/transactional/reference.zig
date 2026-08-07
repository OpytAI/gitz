//! Transactional reference storer (go-git `storage/transactional` ReferenceStorage).
//!
//! Writes go to `temporal`. Reads check temporal then base (unless deleted).
//! `deleted` tracks RemoveReference until Commit applies removals on base.

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");

const Allocator = std.mem.Allocator;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;

/// go-git `transactional.ReferenceStorage`.
pub const ReferenceStorage = struct {
    allocator: Allocator,
    base: *memory.Storage,
    temporal: *memory.Storage,
    /// Names marked deleted until commit (go-git `deleted` map).
    deleted: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: Allocator, base: *memory.Storage, temporal: *memory.Storage) ReferenceStorage {
        return .{
            .allocator = allocator,
            .base = base,
            .temporal = temporal,
        };
    }

    pub fn deinit(self: *ReferenceStorage) void {
        var it = self.deleted.keyIterator();
        while (it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.deleted.deinit(self.allocator);
        self.* = undefined;
    }

    /// go-git `SetReference` — clears deleted flag; writes temporal.
    pub fn setReference(self: *ReferenceStorage, ref: Reference) Allocator.Error!void {
        self.clearDeleted(ref.name);
        return self.temporal.setReference(ref);
    }

    /// go-git `CheckAndSetReference`.
    pub fn checkAndSetReference(
        self: *ReferenceStorage,
        ref: ?Reference,
        old: ?Reference,
    ) (Allocator.Error || error{ReferenceHasChanged} || plumbing.Error)!void {
        const new_ref = ref orelse return;

        if (old) |o| {
            // Prefer temporal, then base (go-git order).
            const tmp = self.temporal.reference(o.name) catch |err| switch (err) {
                error.ReferenceNotFound => try self.base.reference(o.name),
                else => return err,
            };

            if (!tmp.hash.eql(o.hash)) return error.ReferenceHasChanged;
        }

        try self.setReference(new_ref);
    }

    /// go-git `Reference` — deleted → not found; else temporal then base.
    pub fn reference(self: *const ReferenceStorage, n: ReferenceName) plumbing.Error!Reference {
        if (self.deleted.contains(n.raw)) return error.ReferenceNotFound;

        return self.temporal.reference(n) catch |err| switch (err) {
            error.ReferenceNotFound => return self.base.reference(n),
            else => return err,
        };
    }

    /// go-git `IterReferences` — multi base then temporal (no deleted filter; go-git).
    pub fn iterReferences(self: *const ReferenceStorage) Allocator.Error!MultiReferenceIter {
        const base_iter = try self.base.iterReferences();
        errdefer {
            var bi = base_iter;
            bi.deinit();
        }
        const temporal_iter = try self.temporal.iterReferences();
        return MultiReferenceIter.init(base_iter, temporal_iter);
    }

    /// go-git `CountLooseRefs` — sum of temporal + base.
    pub fn countLooseRefs(self: *const ReferenceStorage) usize {
        return self.temporal.countLooseRefs() + self.base.countLooseRefs();
    }

    /// go-git `PackRefs` — no-op.
    pub fn packRefs(_: *ReferenceStorage) void {}

    /// go-git `RemoveReference` — mark deleted and remove from temporal.
    pub fn removeReference(self: *ReferenceStorage, n: ReferenceName) Allocator.Error!void {
        try self.markDeleted(n);
        self.temporal.removeReference(n);
    }

    /// go-git `Commit` — apply deletions on base, then copy temporal refs to base.
    pub fn commit(self: *ReferenceStorage) Allocator.Error!void {
        var del_it = self.deleted.keyIterator();
        while (del_it.next()) |k| {
            self.base.removeReference(ReferenceName.init(k.*));
        }

        var iter = try self.temporal.iterReferences();
        defer iter.deinit();
        while (true) {
            const ref = iter.next() catch |err| switch (err) {
                error.EndOfStream => break,
            };
            try self.base.setReference(ref);
        }
    }

    fn clearDeleted(self: *ReferenceStorage, n: ReferenceName) void {
        if (self.deleted.fetchRemove(n.raw)) |old| {
            self.allocator.free(old.key);
        }
    }

    fn markDeleted(self: *ReferenceStorage, n: ReferenceName) Allocator.Error!void {
        if (self.deleted.contains(n.raw)) return;
        const key = try self.allocator.dupe(u8, n.raw);
        errdefer self.allocator.free(key);
        try self.deleted.put(self.allocator, key, {});
    }
};

/// go-git `NewReferenceStorage(base, temporal)`.
/// Allocator is taken from `base.allocator` for the deleted-name map.
pub fn newReferenceStorage(base: *memory.Storage, temporal: *memory.Storage) ReferenceStorage {
    return ReferenceStorage.init(base.allocator, base, temporal);
}

/// Concatenate two reference iters (go-git `MultiReferenceIter`).
pub const MultiReferenceIter = struct {
    first: memory.ReferenceSliceIter,
    second: memory.ReferenceSliceIter,
    on_second: bool = false,

    pub fn init(first: memory.ReferenceSliceIter, second: memory.ReferenceSliceIter) MultiReferenceIter {
        return .{ .first = first, .second = second };
    }

    pub fn deinit(self: *MultiReferenceIter) void {
        self.first.deinit();
        self.second.deinit();
        self.* = undefined;
    }

    pub fn next(self: *MultiReferenceIter) error{EndOfStream}!Reference {
        if (!self.on_second) {
            return self.first.next() catch {
                self.on_second = true;
                return self.second.next();
            };
        }
        return self.second.next();
    }

    pub fn close(self: *MultiReferenceIter) void {
        self.first.close();
        self.second.close();
        self.on_second = true;
    }

    pub fn forEach(self: *MultiReferenceIter, cb: anytype) anyerror!void {
        defer self.close();
        while (true) {
            const ref = self.next() catch |err| switch (err) {
                error.EndOfStream => return,
            };
            @call(.auto, cb, .{ref}) catch |err| {
                const e: anyerror = err;
                if (e == error.Stop) return;
                return e;
            };
        }
    }
};

// ---------------------------------------------------------------------------
// Tests (go-git reference_test.go)
// ---------------------------------------------------------------------------

test "Reference demux temporal not in base" {
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

    var rs = ReferenceStorage.init(allocator, base, temporal);
    defer rs.deinit();

    const ref_a = plumbing.Reference.fromStrings("refs/a", "bc9968d75e48de59f0870ffb71f5e160bbbdcf52");
    const ref_b = plumbing.Reference.fromStrings("refs/b", "bc9968d75e48de59f0870ffb71f5e160bbbdcf52");

    try base.setReference(ref_a);
    try rs.setReference(ref_b);

    _ = try rs.reference(ReferenceName.init("refs/a"));
    _ = try rs.reference(ReferenceName.init("refs/b"));
    try std.testing.expectError(
        error.ReferenceNotFound,
        base.reference(ReferenceName.init("refs/b")),
    );
}

test "RemoveReference temporal only" {
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

    var rs = ReferenceStorage.init(allocator, base, temporal);
    defer rs.deinit();

    const ref = plumbing.Reference.fromStrings("refs/a", "bc9968d75e48de59f0870ffb71f5e160bbbdcf52");
    try rs.setReference(ref);
    try rs.removeReference(ReferenceName.init("refs/a"));
    try std.testing.expectError(
        error.ReferenceNotFound,
        rs.reference(ReferenceName.init("refs/a")),
    );
}

test "RemoveReference base via deleted flag" {
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

    var rs = ReferenceStorage.init(allocator, base, temporal);
    defer rs.deinit();

    const ref = plumbing.Reference.fromStrings("refs/a", "bc9968d75e48de59f0870ffb71f5e160bbbdcf52");
    try base.setReference(ref);
    try rs.removeReference(ReferenceName.init("refs/a"));
    try std.testing.expectError(
        error.ReferenceNotFound,
        rs.reference(ReferenceName.init("refs/a")),
    );
}

test "CheckAndSetReference in base" {
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

    var rs = ReferenceStorage.init(allocator, base, temporal);
    defer rs.deinit();

    try base.setReference(plumbing.Reference.fromStrings(
        "foo",
        "482e0eada5de4039e6f216b45b3c9b683b83bfa",
    ));

    try rs.checkAndSetReference(
        plumbing.Reference.fromStrings("foo", "bc9968d75e48de59f0870ffb71f5e160bbbdcf52"),
        plumbing.Reference.fromStrings("foo", "482e0eada5de4039e6f216b45b3c9b683b83bfa"),
    );

    const e = try rs.reference(ReferenceName.init("foo"));
    var buf: [plumbing.HexSize]u8 = undefined;
    try std.testing.expectEqualStrings(
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
        e.hash.string(&buf),
    );
}

test "ReferenceStorage Commit copies refs to base" {
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

    var rs = ReferenceStorage.init(allocator, base, temporal);
    defer rs.deinit();

    try rs.setReference(plumbing.Reference.fromStrings("refs/a", "bc9968d75e48de59f0870ffb71f5e160bbbdcf52"));
    try rs.setReference(plumbing.Reference.fromStrings("refs/b", "b66c08ba28aa1f81eb06a1127aa3936ff77e5e2c"));
    try rs.setReference(plumbing.Reference.fromStrings("refs/c", "c3f4688a08fd86f1bf8e055724c84b7a40a09733"));

    try rs.commit();

    var iter = try base.iterReferences();
    defer iter.deinit();
    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    } else |err| {
        try std.testing.expect(err == error.EndOfStream);
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "ReferenceStorage Commit with deletes" {
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

    var rs = ReferenceStorage.init(allocator, base, temporal);
    defer rs.deinit();

    const ref_a = plumbing.Reference.fromStrings("refs/a", "bc9968d75e48de59f0870ffb71f5e160bbbdcf52");
    const ref_b = plumbing.Reference.fromStrings("refs/b", "b66c08ba28aa1f81eb06a1127aa3936ff77e5e2c");
    const ref_c = plumbing.Reference.fromStrings("refs/c", "c3f4688a08fd86f1bf8e055724c84b7a40a09733");

    try base.setReference(ref_a);
    try base.setReference(ref_b);
    try base.setReference(ref_c);

    try rs.removeReference(ref_a.name);
    try rs.removeReference(ref_b.name);
    try rs.removeReference(ref_c.name);
    try rs.setReference(ref_c);

    try rs.commit();

    var iter = try base.iterReferences();
    defer iter.deinit();
    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    } else |err| {
        try std.testing.expect(err == error.EndOfStream);
    }
    try std.testing.expectEqual(@as(usize, 1), count);

    const ref = try rs.reference(ref_c.name);
    var buf: [plumbing.HexSize]u8 = undefined;
    try std.testing.expectEqualStrings(
        "c3f4688a08fd86f1bf8e055724c84b7a40a09733",
        ref.hash.string(&buf),
    );
}
