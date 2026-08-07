//! IsDotGitName — go-git internal/pathutil/dotgit.go.

const std = @import("std");

/// Reports whether name is `.git` or its 8.3 NTFS short alias `git~1`,
/// case-insensitively. Both are forbidden as path components (and as
/// submodule names) because they refer to the repository's own metadata
/// directory.
///
/// Port of go-git `pathutil.IsDotGitName`.
pub fn isDotGitName(name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, ".git")) return true;
    if (std.ascii.eqlIgnoreCase(name, "git~1")) return true;
    return false;
}

test "IsDotGitName table" {
    const Case = struct { name: []const u8, want: bool };
    const cases = [_]Case{
        .{ .name = ".git", .want = true },
        .{ .name = ".GIT", .want = true },
        .{ .name = ".Git", .want = true },
        .{ .name = ".gIt", .want = true },
        .{ .name = "git~1", .want = true },
        .{ .name = "GIT~1", .want = true },
        .{ .name = "Git~1", .want = true },
        .{ .name = "git", .want = false },
        .{ .name = "GIT", .want = false },
        .{ .name = ".gitmodules", .want = false },
        .{ .name = ".gitignore", .want = false },
        .{ .name = "git~", .want = false },
        .{ .name = "git~10", .want = false },
        .{ .name = "git~2", .want = false },
        .{ .name = "", .want = false },
    };
    for (cases) |tc| {
        try std.testing.expectEqual(tc.want, isDotGitName(tc.name));
    }
}
