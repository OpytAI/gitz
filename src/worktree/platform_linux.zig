//! Linux index stat fill (go-git `worktree_linux.go`).
//!
//! go-git sets CreatedAt (Ctim), Dev, Inode, UID, GID from `*syscall.Stat_t`.
//!
//! Gitz worktrees use both `fs.Mem` and `fs.Os`. When `stat` succeeds we fill
//! stable fields from the common filesystem information surface:
//! - `created_at` ← mtime (best ctime proxy Mem provides)
//! - `dev` = 1 (single synthetic memfs device)
//! - `inode` = FNV-1a path hash (stable across runs for the same path)
//! - `uid`/`gid` = 0 (no identity in Mem)
//!
//! These are backend-stable values, not a claim to expose the complete host
//! `Stat_t` through the billy-style filesystem interface.

const std = @import("std");
const index_fmt = @import("index");
const fs_pkg = @import("fs");

const Entry = index_fmt.Entry;

/// go-git `fillSystemInfo` body for linux.
pub fn fillSystemInfoLinux(e: *Entry, filesystem: anytype, path: []const u8) void {
    const info = filesystem.stat(path) catch return;
    // Synthetic Mem platform fields (see file header).
    e.created_at = .{ .sec = info.mtime_sec, .nsec = 0 };
    e.dev = 1;
    e.inode = pathInode(path);
    e.uid = 0;
    e.gid = 0;
}

/// Stable non-zero inode from path (FNV-1a 32-bit, never zero).
fn pathInode(path: []const u8) u32 {
    var h: u32 = 2166136261;
    for (path) |c| {
        h ^= c;
        h *%= 16777619;
    }
    if (h == 0) h = 1;
    return h;
}

/// go-git `isSymlinkWindowsNonAdmin` on linux — always false.
pub fn isSymlinkWindowsNonAdmin(_: anyerror) bool {
    return false;
}

test "pathInode stable and non-zero" {
    try std.testing.expect(pathInode("a/b") != 0);
    try std.testing.expectEqual(pathInode("x"), pathInode("x"));
    try std.testing.expect(pathInode("a") != pathInode("b"));
}
