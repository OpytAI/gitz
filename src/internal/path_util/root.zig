//! Tilde path expansion helpers.
//!
//! Port of go-git v5.19.2 `internal/path_util`. Home directory is injected
//! (go-git uses `os.UserHomeDir`) so callers control the expansion source.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Errors from `replaceTildeWithHome` beyond allocator failures.
pub const Error = error{
    /// Path is `~user/...` and no user-home lookup was provided / succeeded.
    /// go-git returns `user.Lookup` errors for this case.
    UserNotFound,
};

/// Expand a leading tilde in `path`.
///
/// - `~/...` → replace `~` with `home` (go-git: `os.UserHomeDir`).
/// - `~user/...` → if `user_home` is non-null, replace `~user` with it;
///   otherwise return `error.UserNotFound` (go-git: `user.Lookup`).
/// - no leading `~`, or `~` / `~user` without `/` → return a copy of `path`.
///
/// Caller owns the returned slice. Port of go-git
/// `path_util.ReplaceTildeWithHome` with injectable home directories.
pub fn replaceTildeWithHome(
    allocator: Allocator,
    path: []const u8,
    home: []const u8,
    user_home: ?[]const u8,
) (Allocator.Error || Error)![]u8 {
    if (!std.mem.startsWith(u8, path, "~")) {
        return try allocator.dupe(u8, path);
    }

    const first_slash = std.mem.indexOfScalar(u8, path, '/');
    if (first_slash == null) {
        // "~" or "~username" with no slash — go-git leaves unchanged.
        return try allocator.dupe(u8, path);
    }

    if (first_slash.? == 1) {
        // "~/..." — Replace("~", home, 1)
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, path[1..] });
    }

    // "~user/..."
    if (user_home) |uh| {
        // Replace path[:firstSlash] ("~user") with user home.
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ uh, path[first_slash.?..] });
    }
    return error.UserNotFound;
}

test "replaceTildeWithHome ~/ expands" {
    const gpa = std.testing.allocator;
    const got = try replaceTildeWithHome(gpa, "~/projects/repo", "/home/alice", null);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/home/alice/projects/repo", got);
}

test "replaceTildeWithHome no tilde is copy" {
    const gpa = std.testing.allocator;
    const got = try replaceTildeWithHome(gpa, "/abs/path", "/home/alice", null);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/abs/path", got);
}

test "replaceTildeWithHome bare tilde unchanged" {
    const gpa = std.testing.allocator;
    const got = try replaceTildeWithHome(gpa, "~", "/home/alice", null);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("~", got);
}

test "replaceTildeWithHome ~user without slash unchanged" {
    const gpa = std.testing.allocator;
    const got = try replaceTildeWithHome(gpa, "~bob", "/home/alice", null);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("~bob", got);
}

test "replaceTildeWithHome ~user/ needs lookup" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.UserNotFound,
        replaceTildeWithHome(gpa, "~bob/src", "/home/alice", null),
    );

    const got = try replaceTildeWithHome(gpa, "~bob/src", "/home/alice", "/home/bob");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/home/bob/src", got);
}

test "replaceTildeWithHome only tilde slash" {
    const gpa = std.testing.allocator;
    const got = try replaceTildeWithHome(gpa, "~/", "/home/alice", null);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/home/alice/", got);
}
