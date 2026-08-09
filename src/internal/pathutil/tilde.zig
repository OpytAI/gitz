//! Home-relative path expansion.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Errors from `replaceTildeWithHome` beyond allocator failures.
pub const Error = error{
    /// The path names another user and no matching home directory was supplied.
    UserNotFound,
};

/// Expand a leading tilde in `path`.
///
/// The caller supplies home directories because Zig has no portable equivalent
/// of Go's `os.UserHomeDir` and `user.Lookup` calls. The caller owns the result.
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
        return try allocator.dupe(u8, path);
    }

    if (first_slash.? == 1) {
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, path[1..] });
    }

    if (user_home) |other_home| {
        return try std.fmt.allocPrint(
            allocator,
            "{s}{s}",
            .{ other_home, path[first_slash.?..] },
        );
    }
    return error.UserNotFound;
}

test "replaceTildeWithHome expands the current user's home" {
    const allocator = std.testing.allocator;
    const got = try replaceTildeWithHome(allocator, "~/projects/repo", "/home/alice", null);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("/home/alice/projects/repo", got);
}

test "replaceTildeWithHome returns a copy for an ordinary path" {
    const allocator = std.testing.allocator;
    const got = try replaceTildeWithHome(allocator, "/abs/path", "/home/alice", null);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("/abs/path", got);
}

test "replaceTildeWithHome leaves a bare tilde unchanged" {
    const allocator = std.testing.allocator;
    const got = try replaceTildeWithHome(allocator, "~", "/home/alice", null);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("~", got);
}

test "replaceTildeWithHome leaves a bare username unchanged" {
    const allocator = std.testing.allocator;
    const got = try replaceTildeWithHome(allocator, "~bob", "/home/alice", null);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("~bob", got);
}

test "replaceTildeWithHome requires a supplied home for another user" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.UserNotFound,
        replaceTildeWithHome(allocator, "~bob/src", "/home/alice", null),
    );

    const got = try replaceTildeWithHome(allocator, "~bob/src", "/home/alice", "/home/bob");
    defer allocator.free(got);
    try std.testing.expectEqualStrings("/home/bob/src", got);
}

test "replaceTildeWithHome expands tilde slash" {
    const allocator = std.testing.allocator;
    const got = try replaceTildeWithHome(allocator, "~/", "/home/alice", null);
    defer allocator.free(got);
    try std.testing.expectEqualStrings("/home/alice/", got);
}
