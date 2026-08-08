//! Linux index stat fill (go-git `worktree_linux.go`).
//!
//! go-git sets `CreatedAt` (Ctim), `Dev`, `Inode`, `UID`, and `GID` from
//! `*syscall.Stat_t` when `FileInfo.Sys()` yields that type.
//!
//! gitz worktree currently uses `fs.Mem`, which has no `Stat_t`. This helper
//! is a documented stub: leave platform fields unchanged (zeros / prior values)
//! so callers that already set size/mtime keep those values. When a real OS FS
//! is wired, fill ctime/dev/ino/uid/gid from host stat here.

const index_fmt = @import("index");
const fs_pkg = @import("fs");

const Entry = index_fmt.Entry;

/// go-git `fillSystemInfo` body for linux (`worktree_linux.go`).
///
/// Mem FS: no-op on platform fields (equivalent to a failed type assert on Sys()).
pub fn fillSystemInfoLinux(e: *Entry, filesystem: *fs_pkg.Mem, path: []const u8) void {
    // Stat for path existence / future OS FS fields. Size and mtime are set by
    // the caller (add/reset/checkout), matching go-git which only fills Sys().
    _ = filesystem.stat(path) catch return;
    _ = e;
    // Real OS path (future):
    //   e.created_at = from Ctim
    //   e.dev = Stat_t.Dev
    //   e.inode = Stat_t.Ino
    //   e.uid = Stat_t.Uid
    //   e.gid = Stat_t.Gid
}

/// go-git `isSymlinkWindowsNonAdmin` on linux — always false.
pub fn isSymlinkWindowsNonAdmin(_: anyerror) bool {
    return false;
}
