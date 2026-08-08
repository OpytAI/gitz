//! Platform index stat fill — go-git `worktree_linux.go` / `worktree_windows.go`.
//!
//! Dispatch: `fillSystemInfo` selects the host platform helper. Both OS
//! helpers are always compiled and tested. On Mem FS they fill synthetic
//! stable fields (see platform_linux / platform_windows headers) rather than
//! leaving all zeros.

const std = @import("std");
const builtin = @import("builtin");
const index_fmt = @import("index");
const fs_pkg = @import("fs");

const linux_mod = @import("platform_linux.zig");
const windows_mod = @import("platform_windows.zig");

const Entry = index_fmt.Entry;

pub const fillSystemInfoLinux = linux_mod.fillSystemInfoLinux;
pub const fillSystemInfoWindows = windows_mod.fillSystemInfoWindows;
pub const isSymlinkWindowsNonAdminLinux = linux_mod.isSymlinkWindowsNonAdmin;
pub const isSymlinkWindowsNonAdminWindows = windows_mod.isSymlinkWindowsNonAdmin;

/// Host-platform `isSymlinkWindowsNonAdmin` (go-git per-OS definition).
pub fn isSymlinkWindowsNonAdmin(err: anyerror) bool {
    if (builtin.os.tag == .windows) {
        return windows_mod.isSymlinkWindowsNonAdmin(err);
    }
    return linux_mod.isSymlinkWindowsNonAdmin(err);
}

/// Fill index entry system fields from worktree path stats when available.
///
/// go-git: `fillSystemInfo(e, fi.Sys())` — only ctime/dev/ino/uid/gid (or
/// windows creation time). Callers set size, mtime, mode, and hash first.
pub fn fillSystemInfo(e: *Entry, filesystem: *fs_pkg.Mem, path: []const u8) void {
    if (builtin.os.tag == .windows) {
        windows_mod.fillSystemInfoWindows(e, filesystem, path);
    } else {
        // Linux and other Unix targets use the linux stub (Mem has no Stat_t).
        linux_mod.fillSystemInfoLinux(e, filesystem, path);
    }
}

// ---------------------------------------------------------------------------
// Tests — force-call both helpers so both stubs stay live on every host.
// ---------------------------------------------------------------------------

test "fillSystemInfo missing path leaves entry fields" {
    const gpa = std.testing.allocator;
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var e: Entry = .{};
    e.size = 42;
    e.created_at = .{ .sec = 1, .nsec = 2 };
    fillSystemInfo(&e, &mem, "nope");
    // Missing path: platform helper returns without mutating (size stays).
    try std.testing.expectEqual(@as(u32, 42), e.size);
    try std.testing.expectEqual(@as(i64, 1), e.created_at.sec);
}

test "fillSystemInfoLinux and fillSystemInfoWindows both callable" {
    const gpa = std.testing.allocator;
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    var f = try mem.create("statme.txt");
    _ = try f.write("abc");
    try f.close();

    var e_linux: Entry = .{};
    e_linux.size = 3;
    e_linux.modified_at = .{ .sec = 99, .nsec = 0 };
    fillSystemInfoLinux(&e_linux, &mem, "statme.txt");
    // Caller size/mtime preserved; Mem synthetic dev/inode filled.
    try std.testing.expectEqual(@as(u32, 3), e_linux.size);
    try std.testing.expectEqual(@as(i64, 99), e_linux.modified_at.sec);
    try std.testing.expectEqual(@as(u32, 1), e_linux.dev);
    try std.testing.expect(e_linux.inode != 0);
    try std.testing.expectEqual(@as(u32, 0), e_linux.uid);
    try std.testing.expectEqual(@as(u32, 0), e_linux.gid);

    var e_win: Entry = .{};
    e_win.size = 3;
    e_win.modified_at = .{ .sec = 88, .nsec = 0 };
    fillSystemInfoWindows(&e_win, &mem, "statme.txt");
    try std.testing.expectEqual(@as(u32, 3), e_win.size);
    try std.testing.expectEqual(@as(i64, 88), e_win.modified_at.sec);
    // Windows Mem: creation proxy from mtime (often 0 on Mem).
    try std.testing.expectEqual(@as(u32, 0), e_win.dev);

    try std.testing.expect(!isSymlinkWindowsNonAdmin(error.NotExist));
    try std.testing.expect(!isSymlinkWindowsNonAdminLinux(error.NotExist));
    try std.testing.expect(!isSymlinkWindowsNonAdminWindows(error.NotExist));
}

test "fillSystemInfo host dispatch preserves caller size" {
    const gpa = std.testing.allocator;
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var f = try mem.create("host.txt");
    _ = try f.write("xy");
    try f.close();

    var e: Entry = .{};
    e.size = 2;
    e.modified_at = .{ .sec = 7, .nsec = 0 };
    fillSystemInfo(&e, &mem, "host.txt");
    try std.testing.expectEqual(@as(u32, 2), e.size);
    try std.testing.expectEqual(@as(i64, 7), e.modified_at.sec);
}
