//! Shared worktree path and gitignore helpers.
//!
//! Keeps add/status/clean free of copy-pasted join/match/clean logic.

const std = @import("std");
const plumbing = @import("plumbing");
const storer = @import("storer");
const fs_pkg = @import("fs");
const gitignore = @import("gitignore");

const Allocator = std.mem.Allocator;

/// Normalize the memory and filesystem `SetIndex` contracts.
///
/// Memory storage adopts the index and cannot fail. Filesystem storage writes
/// the index and reports I/O errors. Callers use one fallible worktree path for
/// both backends.
pub fn setIndex(storage: anytype, idx: anytype) !void {
    const Storage = @TypeOf(storage.*);
    if (comptime @hasDecl(Storage, "setIndexOwned")) {
        try storage.setIndexOwned(idx);
    } else if (comptime @hasDecl(Storage, "set_index_can_fail") and Storage.set_index_can_fail) {
        try storage.setIndex(idx);
    } else {
        storage.setIndex(idx);
    }
}

/// Resolve a symbolic reference while honoring each backend's ownership rule.
/// The returned reference must be passed to `freeReference`.
pub fn resolveReference(storage: anytype, name: plumbing.ReferenceName) !plumbing.Reference {
    var current = try storage.reference(name);
    var recursion: usize = 0;
    while (current.type == .symbolic) {
        if (recursion > storer.MaxResolveRecursion) {
            storage.freeReference(current);
            return error.MaxResolveRecursion;
        }
        const next = storage.reference(current.target) catch |err| {
            storage.freeReference(current);
            return err;
        };
        storage.freeReference(current);
        current = next;
        recursion += 1;
    }
    return current;
}

/// Join relative worktree path segments with `/` (billy / go-git slash paths).
///
/// Empty or `"."` dir yields a dupe of `name`. Caller frees.
pub fn joinRel(allocator: Allocator, dir: []const u8, name: []const u8) Allocator.Error![]u8 {
    if (dir.len == 0 or std.mem.eql(u8, dir, ".")) {
        return try allocator.dupe(u8, name);
    }
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
}

/// Normalize a path to slash form and drop a single leading `./` (go-git Clean).
/// Caller frees.
pub fn cleanToSlash(allocator: Allocator, path: []const u8) Allocator.Error![]u8 {
    const cleaned = try fs_pkg.path.clean(allocator, path);
    errdefer allocator.free(cleaned);
    for (cleaned) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    if (std.mem.startsWith(u8, cleaned, "./") and cleaned.len > 2) {
        const trimmed = try allocator.dupe(u8, cleaned[2..]);
        allocator.free(cleaned);
        return trimmed;
    }
    return cleaned;
}

/// go-git gitignore matcher over `/`-split path segments.
///
/// Paths deeper than 64 segments are truncated for matching (same bound as the
/// historical add/status helpers; deep trees are rare in hermetic Mem tests).
pub fn matchIgnore(patterns: []const gitignore.Pattern, path: []const u8, is_dir: bool) bool {
    if (patterns.len == 0) return false;
    const m = gitignore.newMatcher(patterns);
    var segs_buf: [64][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (n >= segs_buf.len) break;
        segs_buf[n] = seg;
        n += 1;
    }
    return m.match(segs_buf[0..n], is_dir);
}

test "joinRel root nested and dot" {
    const gpa = std.testing.allocator;
    {
        const p = try joinRel(gpa, "", "foo.txt");
        defer gpa.free(p);
        try std.testing.expectEqualStrings("foo.txt", p);
    }
    {
        const p = try joinRel(gpa, ".", "bar");
        defer gpa.free(p);
        try std.testing.expectEqualStrings("bar", p);
    }
    {
        const p = try joinRel(gpa, "pkgA", "bar");
        defer gpa.free(p);
        try std.testing.expectEqualStrings("pkgA/bar", p);
    }
}

test "cleanToSlash drops dot slash" {
    const gpa = std.testing.allocator;
    const p = try cleanToSlash(gpa, "./a/b");
    defer gpa.free(p);
    try std.testing.expectEqualStrings("a/b", p);
}

test "matchIgnore empty patterns" {
    try std.testing.expect(!matchIgnore(&.{}, "foo", false));
}
