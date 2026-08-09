//! Windows index stat fill (go-git `worktree_windows.go`).
//!
//! go-git sets `CreatedAt` from Win32 creation time; not dev/inode/uid/gid.
//!
//! On `fs.Mem` we proxy creation time from mtime (same as available Mem stat)
//! and leave dev/inode/uid/gid at zero (matches go-git Windows behaviour).

const index_fmt = @import("index");
const fs_pkg = @import("fs");

const Entry = index_fmt.Entry;

/// go-git `fillSystemInfo` body for windows.
pub fn fillSystemInfoWindows(e: *Entry, filesystem: anytype, path: []const u8) void {
    const info = filesystem.stat(path) catch return;
    // Mem proxy for CreationTime; Windows go-git does not set dev/ino/uid/gid.
    e.created_at = .{ .sec = info.mtime_sec, .nsec = 0 };
    e.dev = 0;
    e.inode = 0;
    e.uid = 0;
    e.gid = 0;
}

/// go-git `isSymlinkWindowsNonAdmin` — privilege error when creating symlinks
/// without SeCreateSymbolicLinkPrivilege (ERROR_PRIVILEGE_NOT_HELD = 1314).
///
/// Mem never surfaces that host error; always false until Os FS is wired.
pub fn isSymlinkWindowsNonAdmin(_: anyerror) bool {
    return false;
}
