//! Logical path helpers for billy-style filesystems.
//!
//! Separators are always `/`. Used by both `Mem` and `Os` so join/clean rules
//! stay identical across backends.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// go-billy `isCrossBoundaries` — true when a chroot-relative path escapes via `..`.
///
/// Matches billy v5.9.0: strip leading `/`, clean, then reject `..` / `../…`.
/// Call before joining onto a chroot root so `../etc` cannot leave the jail.
pub fn crossesBoundary(path: []const u8) bool {
    var p = path;
    while (p.len > 0 and p[0] == '/') p = p[1..];
    if (p.len == 0) return false;

    // Depth walk equivalent to path.Clean then check for leading `..`.
    var depth: i32 = 0;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            depth -= 1;
            if (depth < 0) return true;
        } else {
            depth += 1;
        }
    }
    return false;
}

/// Join path elements with `/`, cleaning `.` / `..`.
/// Absolute if any component starts with `/` (resets to absolute from that point).
pub fn join(allocator: Allocator, parts: []const []const u8) Allocator.Error![]u8 {
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(allocator);
    var absolute = false;

    for (parts) |p| {
        if (p.len == 0) continue;
        if (p[0] == '/') {
            segs.clearRetainingCapacity();
            absolute = true;
        }
        var it = std.mem.splitScalar(u8, p, '/');
        while (it.next()) |seg| {
            if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
            if (std.mem.eql(u8, seg, "..")) {
                if (segs.items.len > 0) _ = segs.pop();
                continue;
            }
            try segs.append(allocator, seg);
        }
    }

    if (!absolute and segs.items.len == 0) {
        return try allocator.dupe(u8, ".");
    }

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    if (absolute) try list.append(allocator, '/');
    for (segs.items, 0..) |seg, i| {
        if (i > 0 or (absolute and list.items.len > 1)) {
            if (list.items.len > 0 and list.items[list.items.len - 1] != '/')
                try list.append(allocator, '/');
        }
        try list.appendSlice(allocator, seg);
    }
    if (list.items.len == 0) try list.append(allocator, '/');
    return try list.toOwnedSlice(allocator);
}

/// Clean a single relative or absolute path string.
pub fn clean(allocator: Allocator, path: []const u8) Allocator.Error![]u8 {
    return try join(allocator, &.{path});
}

/// Base name of a `/`-separated path (may be empty for `/`).
pub fn baseName(path: []const u8) []const u8 {
    if (path.len == 0) return path;
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        if (i + 1 < path.len) return path[i + 1 ..];
        return path;
    }
    return path;
}

/// Parent of a relative path, or null if none.
pub fn parentRel(rel: []const u8) ?[]const u8 {
    if (std.mem.lastIndexOfScalar(u8, rel, '/')) |i| {
        if (i == 0) return null;
        return rel[0..i];
    }
    return null;
}

test "join absolute and relative" {
    const gpa = std.testing.allocator;
    {
        const p = try join(gpa, &.{ "a", "b", "c" });
        defer gpa.free(p);
        try std.testing.expectEqualStrings("a/b/c", p);
    }
    {
        const p = try join(gpa, &.{ "/", "objects", "pack" });
        defer gpa.free(p);
        try std.testing.expectEqualStrings("/objects/pack", p);
    }
    {
        const p = try join(gpa, &.{ "a/b", "../c" });
        defer gpa.free(p);
        try std.testing.expectEqualStrings("a/c", p);
    }
}

test "crossesBoundary matches billy isCrossBoundaries" {
    try std.testing.expect(!crossesBoundary(""));
    try std.testing.expect(!crossesBoundary("."));
    try std.testing.expect(!crossesBoundary("a/b"));
    try std.testing.expect(!crossesBoundary("/a/b"));
    try std.testing.expect(!crossesBoundary("a/../b"));
    try std.testing.expect(crossesBoundary(".."));
    try std.testing.expect(crossesBoundary("../x"));
    try std.testing.expect(crossesBoundary("a/../../b"));
    try std.testing.expect(crossesBoundary("/../etc"));
}
