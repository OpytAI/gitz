//! Shallow commit storer contract (go-git `plumbing/storer/shallow.go`).
//!
//! # ShallowStorer method set
//!
//! Storage of hashes for shallow commits (commits with missing parents after a
//! shallow fetch). Zig has no Go interfaces; concrete storages implement:
//!
//! | Method | go-git | Role |
//! |--------|--------|------|
//! | `setShallow(commits: []const Hash) !void` | `SetShallow([]plumbing.Hash) error` | Replace the shallow set. |
//! | `shallow() ![]const Hash` (or owned slice) | `Shallow() ([]plumbing.Hash, error)` | Current shallow hashes. |
//!
//! Memory backends typically keep a slice of `plumbing.Hash`. Filesystem
//! backends map this to `.git/shallow`.
//!
//! This file documents the contract and provides a tiny test helper
//! (`ShallowList`). Backend implementations live under `src/storage/*`.

const std = @import("std");
const plumbing = @import("plumbing");

/// Re-export for callers that only import the shallow contract module.
pub const Hash = plumbing.Hash;

/// Documented method names for inventories / implementors (not callables).
pub const method_set = struct {
    pub const set_shallow = "setShallow";
    pub const shallow = "shallow";
};

/// In-memory helper for unit tests: holds a borrowed shallow list.
/// Not a full storage backend; memory `ShallowStorage` owns its slice.
pub const ShallowList = struct {
    commits: []const Hash = &.{},

    pub fn setShallow(self: *ShallowList, commits: []const Hash) void {
        self.commits = commits;
    }

    pub fn shallow(self: ShallowList) []const Hash {
        return self.commits;
    }
};

test "ShallowList set and get" {
    const a = plumbing.newHash("1111111111111111111111111111111111111111");
    const b = plumbing.newHash("2222222222222222222222222222222222222222");
    const list = [_]Hash{ a, b };
    var s: ShallowList = .{};
    s.setShallow(&list);
    try std.testing.expectEqual(@as(usize, 2), s.shallow().len);
    try std.testing.expect(s.shallow()[0].eql(a));
    try std.testing.expect(s.shallow()[1].eql(b));
}
