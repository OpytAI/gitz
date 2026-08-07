//! ValidTreePath — go-git internal/pathutil/tree.go.

const std = @import("std");
const dotgit = @import("dotgit.zig");
const hfs = @import("hfs.zig");
const ntfs = @import("ntfs.zig");

/// Returned by `validTreePath` when its argument is not a safe path to
/// materialise into the worktree.
/// Port of go-git `pathutil.ErrInvalidPath`.
pub const ErrInvalidPath = error{InvalidPath};

/// Rejects path strings that, if materialised into a worktree, would let an
/// attacker-controlled tree entry escape the worktree or rewrite repository
/// metadata. It rejects:
///
/// - control characters (< 0x20, 0x7f);
/// - empty paths and "." / ".." components;
/// - Windows volume name prefixes (e.g. C:);
/// - .git, its 8.3 NTFS short-name git~1, plus their HFS+ and NTFS variants —
///   at every position, not just the root.
///
/// Windows reserved device names (CON, NUL, etc.) are not policed here.
///
/// Port of go-git `pathutil.ValidTreePath`.
pub fn validTreePath(p: []const u8) ErrInvalidPath!void {
    for (p) |c| {
        if (c < 0x20 or c == 0x7f) return error.InvalidPath;
    }

    // Volume names: drive letter (C:) and UNC (\\ or //).
    // go-git uses filepath.VolumeName (OS-dependent); we always reject the
    // Windows forms so tree paths stay portable and match the documented intent.
    if (hasWindowsVolumeName(p)) return error.InvalidPath;

    var start: usize = 0;
    var i: usize = 0;
    var any_part = false;
    while (i <= p.len) : (i += 1) {
        const at_sep = i == p.len or p[i] == '/' or p[i] == '\\';
        if (!at_sep) continue;
        const part = p[start..i];
        start = i + 1;
        if (part.len == 0) continue; // FieldsFunc collapses separators
        any_part = true;

        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) {
            return error.InvalidPath;
        }
        if (dotgit.isDotGitName(part) or hfs.isHFSDotGit(part) or ntfs.isNTFSDotGit(part)) {
            return error.InvalidPath;
        }
    }
    if (!any_part) return error.InvalidPath;
}

/// True when `p` starts with a Windows volume name: `X:` drive or UNC `\\` / `//`.
fn hasWindowsVolumeName(p: []const u8) bool {
    if (p.len >= 2 and p[1] == ':' and std.ascii.isAlphabetic(p[0])) return true;
    // UNC: \\host\share or //host/share
    if (p.len >= 2 and ((p[0] == '\\' and p[1] == '\\') or (p[0] == '/' and p[1] == '/'))) {
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests (from tree_test.go)
// ---------------------------------------------------------------------------

test "ValidTreePath table" {
    const Case = struct { path: []const u8, want_err: bool };
    const zwnj = "\u{200c}";

    const cases = [_]Case{
        // Strict positional rejection at every component.
        .{ .path = "submodule/.git", .want_err = true },
        .{ .path = "a/.git", .want_err = true },
        .{ .path = "a\\.git", .want_err = true },
        .{ .path = ".git", .want_err = true },
        .{ .path = ".git/config", .want_err = true },
        .{ .path = "a/.git/b", .want_err = true },
        .{ .path = "git~1", .want_err = true },
        .{ .path = "sub/git~1/HEAD", .want_err = true },
        .{ .path = "a/../b", .want_err = true },
        .{ .path = ".", .want_err = true },
        .{ .path = "", .want_err = true },
        .{ .path = "a\x01b", .want_err = true },
        .{ .path = "foo\x7fbar", .want_err = true },

        // Always-on NTFS .git-disguise variants.
        .{ .path = "sub/.git . /x", .want_err = true },
        .{ .path = ".git::$INDEX_ALLOCATION/x", .want_err = true },
        .{ .path = "sub/git~1 /x", .want_err = true },
        .{ .path = "git~1./x", .want_err = true },
        .{ .path = "git~1::$INDEX_ALLOCATION/x", .want_err = true },

        // Always-on HFS+ variants.
        .{ .path = ".g" ++ zwnj ++ "it/x", .want_err = true },
        .{ .path = "sub/.g" ++ zwnj ++ "it/x", .want_err = true },

        // Legitimate paths pass.
        .{ .path = "readme.md", .want_err = false },
        .{ .path = "src/main.go", .want_err = false },
        .{ .path = ".gitmodules", .want_err = false },
        .{ .path = ".gitignore", .want_err = false },
        .{ .path = "vendor/.gitignore", .want_err = false },
        .{ .path = "a..b", .want_err = false },
        .{ .path = "submodule", .want_err = false },
        .{ .path = "vendor/sub", .want_err = false },
        .{ .path = "\u{00c7}ircle/file", .want_err = false }, // Çircle/file
        // Windows reserved device names are not policed at this layer.
        .{ .path = "CON/file", .want_err = false },
        .{ .path = "CON.txt", .want_err = false },
        .{ .path = "dir/NUL", .want_err = false },
    };
    for (cases) |tc| {
        const result = validTreePath(tc.path);
        if (tc.want_err) {
            try std.testing.expectError(error.InvalidPath, result);
        } else {
            try result;
        }
    }
}
