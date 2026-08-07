//! Transactional shallow storer (go-git `storage/transactional` ShallowStorage).
//!
//! Writes go to temporal. Reads prefer non-empty temporal list, else base.

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;

/// go-git `transactional.ShallowStorage`.
pub const ShallowStorage = struct {
    base: *memory.Storage,
    temporal: *memory.Storage,

    pub fn init(base: *memory.Storage, temporal: *memory.Storage) ShallowStorage {
        return .{ .base = base, .temporal = temporal };
    }

    /// go-git `SetShallow` — always temporal.
    pub fn setShallow(self: *ShallowStorage, commits: []const Hash) Allocator.Error!void {
        return self.temporal.setShallow(commits);
    }

    /// go-git `Shallow` — temporal if non-empty, else base.
    pub fn shallow(self: *const ShallowStorage) []const Hash {
        const t = self.temporal.shallow();
        if (t.len != 0) return t;
        return self.base.shallow();
    }

    /// go-git `Commit` — copy non-empty temporal shallow list into base.
    pub fn commit(self: *ShallowStorage) Allocator.Error!void {
        const commits = self.temporal.shallow();
        if (commits.len == 0) return;
        try self.base.setShallow(commits);
    }
};

/// go-git `NewShallowStorage(base, temporal)`.
pub fn newShallowStorage(base: *memory.Storage, temporal: *memory.Storage) ShallowStorage {
    return ShallowStorage.init(base, temporal);
}

// ---------------------------------------------------------------------------
// Tests (go-git shallow_test.go)
// ---------------------------------------------------------------------------

test "Shallow demux temporal overrides base" {
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

    var rs = ShallowStorage.init(base, temporal);

    const commit_a = plumbing.newHash("bc9968d75e48de59f0870ffb71f5e160bbbdcf52");
    const commit_b = plumbing.newHash("aa9968d75e48de59f0870ffb71f5e160bbbdcf52");

    try base.setShallow(&[_]Hash{commit_a});
    try rs.setShallow(&[_]Hash{commit_b});

    const commits = rs.shallow();
    try std.testing.expectEqual(@as(usize, 1), commits.len);
    try std.testing.expect(commits[0].eql(commit_b));

    const base_commits = base.shallow();
    try std.testing.expectEqual(@as(usize, 1), base_commits.len);
    try std.testing.expect(base_commits[0].eql(commit_a));
}

test "Shallow Commit copies temporal to base" {
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

    var rs = ShallowStorage.init(base, temporal);

    const commit_a = plumbing.newHash("bc9968d75e48de59f0870ffb71f5e160bbbdcf52");
    const commit_b = plumbing.newHash("aa9968d75e48de59f0870ffb71f5e160bbbdcf52");

    try base.setShallow(&[_]Hash{commit_a});
    try rs.setShallow(&[_]Hash{commit_b});
    try rs.commit();

    const commits = rs.shallow();
    try std.testing.expectEqual(@as(usize, 1), commits.len);
    try std.testing.expect(commits[0].eql(commit_b));

    const base_commits = base.shallow();
    try std.testing.expectEqual(@as(usize, 1), base_commits.len);
    try std.testing.expect(base_commits[0].eql(commit_b));
}
