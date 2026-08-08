//! Windows index stat fill (go-git `worktree_windows.go`).
//!
//! go-git sets `CreatedAt` from `Win32FileAttributeData.CreationTime` when
//! `FileInfo.Sys()` yields that type. It does not fill dev/inode/uid/gid.
//!
//! gitz worktree currently uses `fs.Mem`, which has no Win32 attributes. This
//! helper is a documented stub: leave platform fields unchanged. When a real
//! OS FS is wired, fill creation time from host file attributes here.

const index_fmt = @import("index");
const fs_pkg = @import("fs");

const Entry = index_fmt.Entry;

/// go-git `fillSystemInfo` body for windows (`worktree_windows.go`).
///
/// Mem FS: no-op on platform fields (equivalent to a failed type assert on Sys()).
pub fn fillSystemInfoWindows(e: *Entry, filesystem: *fs_pkg.Mem, path: []const u8) void {
    // Stat for path existence / future OS FS fields. Size and mtime are set by
    // the caller (add/reset/checkout), matching go-git which only fills Sys().
    _ = filesystem.stat(path) catch return;
    _ = e;
    // Real OS path (future):
    //   e.created_at = from CreationTime seconds + nanoseconds
    //   (dev/inode/uid/gid remain zero on Windows, as in go-git)
}

/// go-git `isSymlinkWindowsNonAdmin` — privilege error when creating symlinks
/// without SeCreateSymbolicLinkPrivilege (ERROR_PRIVILEGE_NOT_HELD = 1314).
///
/// Mem FS never surfaces that host error; always false until OS FS is wired.
pub fn isSymlinkWindowsNonAdmin(_: anyerror) bool {
    return false;
}
