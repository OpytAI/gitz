//! OS-backed filesystem (go-billy `osfs` analogue) via Zig 0.16 `std.Io`.
//!
//! All host I/O goes through `std.Io` (`Dir` / `File` / `Threaded`). Callers
//! supply an `std.Io` (tests: `std.testing.io`; production: `std.Io.Threaded.io()`).
//!
//! Path model matches `Mem`: logical paths use `/`; the backend is rooted at
//! an open directory handle (absolute root path stored for `root()` / chroot).

const std = @import("std");
const error_mod = @import("error.zig");
const fileinfo_mod = @import("fileinfo.zig");
const path_mod = @import("path.zig");
const root_mod = @import("root.zig");

const Allocator = std.mem.Allocator;
const Error = error_mod.Error;
const FileInfo = fileinfo_mod.FileInfo;
const O = root_mod.O;
const Io = std.Io;
const Dir = std.Io.Dir;
const IoFile = std.Io.File;

/// Host filesystem rooted at an open directory, driven by `std.Io`.
pub const Os = struct {
    /// Associated open-file type (matches Mem.File / billy File).
    pub const File = OsFile;

    allocator: Allocator,
    io: Io,
    /// Absolute (or process-relative) path string of the root; owned.
    root_path: []u8,
    /// Open directory handle for path resolution; closed on `deinit` when owned.
    root_dir: Dir,
    owns_root_dir: bool = true,
    temp_seq: u32 = 0,
    /// Names of still-open files; `OsFile.close` frees and recycles slots.
    open_names: std.ArrayListUnmanaged([]u8) = .empty,
    /// Free indices into `open_names` (empty slots ready for reuse).
    open_name_free: std.ArrayListUnmanaged(usize) = .empty,

    /// Open `root_path` (created if missing) as the filesystem root.
    pub fn init(allocator: Allocator, io: Io, root_path: []const u8) (Allocator.Error || Error)!Os {
        const owned = try allocator.dupe(u8, root_path);
        errdefer allocator.free(owned);

        // Prefer createDirPathOpen so empty temp roots work; fall back to openDir.
        const dir = Dir.cwd().createDirPathOpen(io, root_path, .{
            .open_options = .{ .iterate = true, .access_sub_paths = true },
        }) catch |err| switch (err) {
            error.PathAlreadyExists => Dir.cwd().openDir(io, root_path, .{
                .iterate = true,
                .access_sub_paths = true,
            }) catch |e| return mapHostErr(e),
            else => |e| return mapHostErr(e),
        };

        return .{
            .allocator = allocator,
            .io = io,
            .root_path = owned,
            .root_dir = dir,
            .owns_root_dir = true,
        };
    }

    /// Create a unique temporary directory under process cwd `gitz-os-*`.
    /// Prefer `initFromDir` + `std.testing.tmpDir` in unit tests.
    pub fn initTemp(allocator: Allocator, io: Io) (Allocator.Error || Error)!Os {
        var name_buf: [64]u8 = undefined;
        // Unique-enough name without depending on std.time (slim in Zig 0.16).
        const stamp = @intFromPtr(allocator.ptr) ^ @intFromPtr(&name_buf);
        const name = std.fmt.bufPrint(&name_buf, "gitz-os-{x}", .{stamp}) catch return error.InvalidMode;

        // Prefer cache/tmp when present; else cwd.
        const base: Dir = Dir.cwd();
        const dir = base.createDirPathOpen(io, name, .{
            .open_options = .{ .iterate = true, .access_sub_paths = true },
        }) catch |e| return mapHostErr(e);

        // Best-effort absolute-ish path for root() display.
        var abs_buf: [Dir.max_path_bytes]u8 = undefined;
        const abs_len = base.realPath(io, &abs_buf) catch 0;
        const root_owned = if (abs_len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ abs_buf[0..abs_len], name })
        else
            try allocator.dupe(u8, name);
        errdefer allocator.free(root_owned);

        return .{
            .allocator = allocator,
            .io = io,
            .root_path = root_owned,
            .root_dir = dir,
            .owns_root_dir = true,
        };
    }

    /// Wrap an already-open directory (e.g. `std.testing.tmpDir().dir`).
    /// Does not take ownership of `dir` unless `take_ownership` is true.
    pub fn initFromDir(
        allocator: Allocator,
        io: Io,
        dir: Dir,
        root_path: []const u8,
        take_ownership: bool,
    ) Allocator.Error!Os {
        return .{
            .allocator = allocator,
            .io = io,
            .root_path = try allocator.dupe(u8, root_path),
            .root_dir = dir,
            .owns_root_dir = take_ownership,
        };
    }

    pub fn deinit(self: *Os) void {
        for (self.open_names.items) |n| {
            if (n.len > 0) self.allocator.free(n);
        }
        self.open_names.deinit(self.allocator);
        self.open_name_free.deinit(self.allocator);
        if (self.owns_root_dir) self.root_dir.close(self.io);
        self.allocator.free(self.root_path);
        self.* = undefined;
    }

    /// Register an owned open-file name; reuses a free slot when available.
    fn registerOpenName(self: *Os, name_owned: []u8) Allocator.Error!usize {
        if (self.open_name_free.pop()) |idx| {
            self.open_names.items[idx] = name_owned;
            return idx;
        }
        const idx = self.open_names.items.len;
        try self.open_names.append(self.allocator, name_owned);
        return idx;
    }

    /// Free the name at `idx` and recycle the slot.
    fn releaseOpenName(self: *Os, idx: usize, name: []u8) void {
        if (idx < self.open_names.items.len) {
            const slot = &self.open_names.items[idx];
            if (slot.len > 0 and slot.ptr == name.ptr) {
                self.allocator.free(slot.*);
                slot.* = &.{};
                self.open_name_free.append(self.allocator, idx) catch {
                    // Slot stays empty; next open appends instead of reuse.
                };
                return;
            }
        }
        if (name.len > 0) self.allocator.free(name);
    }

    pub fn root(self: *const Os) []const u8 {
        return self.root_path;
    }

    pub fn joinPath(self: *const Os, parts: []const []const u8) Allocator.Error![]u8 {
        return try path_mod.join(self.allocator, parts);
    }

    pub fn mkdirAll(self: *Os, path: []const u8, _: u32) (Allocator.Error || Error)!void {
        const rel = try self.relPath(path);
        defer self.allocator.free(rel);
        if (rel.len == 0 or std.mem.eql(u8, rel, ".")) return;
        self.root_dir.createDirPath(self.io, rel) catch |e| return mapHostErr(e);
    }

    pub fn create(self: *Os, filename: []const u8) (Allocator.Error || Error)!OsFile {
        return self.openFile(filename, O.RDWR | O.CREATE | O.TRUNC, 0o666);
    }

    pub fn open(self: *Os, filename: []const u8) (Allocator.Error || Error)!OsFile {
        return self.openFile(filename, O.RDONLY, 0);
    }

    pub fn openFile(self: *Os, filename: []const u8, flag: u32, _: u32) (Allocator.Error || Error)!OsFile {
        // `rel` is freed via defer unless ownership transfers into open_names.
        const rel = try self.relPath(filename);
        var rel_owned = true;
        defer if (rel_owned) self.allocator.free(rel);

        // Ensure parent dirs for create.
        if (flag & O.CREATE != 0) {
            if (path_mod.parentRel(rel)) |parent| {
                if (parent.len > 0 and !std.mem.eql(u8, parent, ".")) {
                    self.root_dir.createDirPath(self.io, parent) catch |e| return mapHostErr(e);
                }
            }
        }

        var file: IoFile = if (flag & O.CREATE != 0) blk: {
            break :blk self.root_dir.createFile(self.io, rel, .{
                .read = (flag & O.RDONLY != 0) or (flag & O.RDWR != 0) or (flag & O.WRONLY == 0),
                .truncate = flag & O.TRUNC != 0,
                .exclusive = flag & O.EXCL != 0,
            }) catch |e| return mapHostErr(e);
        } else blk: {
            const mode: Dir.OpenFileOptions.Mode = if (flag & O.RDWR != 0)
                .read_write
            else if (flag & O.WRONLY != 0)
                .write_only
            else
                .read_only;
            break :blk self.root_dir.openFile(self.io, rel, .{
                .mode = mode,
                .allow_directory = false,
            }) catch |e| return mapHostErr(e);
        };
        errdefer file.close(self.io);

        var pos: i64 = 0;
        if (flag & O.APPEND != 0) {
            const st = file.stat(self.io) catch |e| return mapHostErr(e);
            pos = @intCast(st.size);
        }

        // Transfer name ownership to open_names + OsFile (index for O(1) close).
        const name_index = try self.registerOpenName(rel);
        rel_owned = false;

        return .{
            .os = self,
            .file = file,
            .name = rel,
            .open_name_index = name_index,
            .flag = flag,
            .pos = pos,
        };
    }

    pub fn stat(self: *Os, filename: []const u8) (Allocator.Error || Error)!FileInfo {
        const rel = try self.relPath(filename);
        defer self.allocator.free(rel);
        const st = self.root_dir.statFile(self.io, rel, .{ .follow_symlinks = true }) catch |e| return mapHostErr(e);
        // Empty name: do not return a view into freed `rel` (FileInfo.name is
        // only owned for readDir entries — see fileinfo.zig).
        return fileInfoFromStat(st, "");
    }

    pub fn lstat(self: *Os, filename: []const u8) (Allocator.Error || Error)!FileInfo {
        const rel = try self.relPath(filename);
        defer self.allocator.free(rel);
        const st = self.root_dir.statFile(self.io, rel, .{ .follow_symlinks = false }) catch |e| return mapHostErr(e);
        return fileInfoFromStat(st, "");
    }

    /// Caller frees with `freeReadDir`.
    pub fn readDir(self: *Os, path: []const u8) (Allocator.Error || Error)![]FileInfo {
        const rel = try self.relPath(path);
        defer self.allocator.free(rel);

        var dir = if (rel.len == 0 or std.mem.eql(u8, rel, ".") or std.mem.eql(u8, rel, "/"))
            self.root_dir
        else
            self.root_dir.openDir(self.io, rel, .{ .iterate = true }) catch |e| return mapHostErr(e);
        const close_dir = !(rel.len == 0 or std.mem.eql(u8, rel, ".") or std.mem.eql(u8, rel, "/"));
        defer if (close_dir) dir.close(self.io);

        var list: std.ArrayList(FileInfo) = .empty;
        errdefer {
            for (list.items) |e| {
                if (e.name.len > 0) self.allocator.free(@constCast(e.name));
            }
            list.deinit(self.allocator);
        }

        var it = dir.iterate();
        while (true) {
            const entry = it.next(self.io) catch |e| return mapHostErr(e);
            const ent = entry orelse break;
            if (std.mem.eql(u8, ent.name, ".") or std.mem.eql(u8, ent.name, "..")) continue;
            const name_owned = try self.allocator.dupe(u8, ent.name);
            const mode: u32 = switch (ent.kind) {
                .directory => 0o040755,
                .sym_link => 0o120777,
                .file => 0o100644,
                else => 0o100644,
            };
            try list.append(self.allocator, .{
                .name = name_owned,
                .size = 0,
                .mode = mode,
            });
        }
        std.mem.sort(FileInfo, list.items, {}, struct {
            fn less(_: void, a: FileInfo, b: FileInfo) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);
        return try list.toOwnedSlice(self.allocator);
    }

    pub fn freeReadDir(self: *Os, entries: []FileInfo) void {
        for (entries) |e| {
            if (e.name.len > 0) self.allocator.free(@constCast(e.name));
        }
        // Match Mem: free only non-empty owned slices (never static `&.{}`).
        if (entries.len > 0) self.allocator.free(entries);
    }

    pub fn remove(self: *Os, filename: []const u8) (Allocator.Error || Error)!void {
        const rel = try self.relPath(filename);
        defer self.allocator.free(rel);
        // Try file first, then directory.
        self.root_dir.deleteFile(self.io, rel) catch |err| switch (err) {
            error.FileNotFound => return error.NotExist,
            error.IsDir => {
                self.root_dir.deleteDir(self.io, rel) catch |e| return mapHostErr(e);
            },
            else => |e| return mapHostErr(e),
        };
    }

    pub fn rename(self: *Os, oldpath: []const u8, newpath: []const u8) (Allocator.Error || Error)!void {
        const old_rel = try self.relPath(oldpath);
        defer self.allocator.free(old_rel);
        const new_rel = try self.relPath(newpath);
        defer self.allocator.free(new_rel);
        if (path_mod.parentRel(new_rel)) |parent| {
            if (parent.len > 0 and !std.mem.eql(u8, parent, ".")) {
                self.root_dir.createDirPath(self.io, parent) catch |e| return mapHostErr(e);
            }
        }
        self.root_dir.rename(old_rel, self.root_dir, new_rel, self.io) catch |e| return mapHostErr(e);
    }

    pub fn tempFile(self: *Os, dir: []const u8, prefix: []const u8) (Allocator.Error || Error)!OsFile {
        self.temp_seq += 1;
        var buf: [160]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "{s}_{d}", .{ prefix, self.temp_seq }) catch return error.InvalidMode;
        const d = if (dir.len == 0) "." else dir;
        const path = try self.joinPath(&.{ d, name });
        defer self.allocator.free(path);
        return self.openFile(path, O.RDWR | O.CREATE | O.EXCL, 0o600);
    }

    pub fn chroot(self: *Os, path: []const u8) (Allocator.Error || Error)!Os {
        // Single ownership of `rel`: free on every error path, transfer into
        // new_root formatting on success. No errdefer + manual free pairs.
        const rel = try self.relPath(path);
        const st = self.root_dir.statFile(self.io, rel, .{}) catch |e| {
            self.allocator.free(rel);
            return mapHostErr(e);
        };
        if (st.kind != .directory) {
            self.allocator.free(rel);
            return error.NotDir;
        }
        const sub = self.root_dir.openDir(self.io, rel, .{
            .iterate = true,
            .access_sub_paths = true,
        }) catch |e| {
            self.allocator.free(rel);
            return mapHostErr(e);
        };
        errdefer sub.close(self.io);

        const new_root = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root_path, rel }) catch |e| {
            self.allocator.free(rel);
            return e;
        };
        self.allocator.free(rel);
        return .{
            .allocator = self.allocator,
            .io = self.io,
            .root_path = new_root,
            .root_dir = sub,
            .owns_root_dir = true,
            .temp_seq = self.temp_seq,
        };
    }

    pub fn symlink(self: *Os, target: []const u8, link: []const u8) (Allocator.Error || Error)!void {
        const rel = try self.relPath(link);
        defer self.allocator.free(rel);
        if (path_mod.parentRel(rel)) |parent| {
            if (parent.len > 0 and !std.mem.eql(u8, parent, ".")) {
                self.root_dir.createDirPath(self.io, parent) catch |e| return mapHostErr(e);
            }
        }
        self.root_dir.symLink(self.io, target, rel, .{}) catch |e| return mapHostErr(e);
    }

    pub fn readlink(self: *Os, link: []const u8) (Allocator.Error || Error)![]u8 {
        const rel = try self.relPath(link);
        defer self.allocator.free(rel);
        var buf: [Dir.max_path_bytes]u8 = undefined;
        const n = self.root_dir.readLink(self.io, rel, &buf) catch |e| return mapHostErr(e);
        return try self.allocator.dupe(u8, buf[0..n]);
    }

    fn relPath(self: *const Os, path: []const u8) (Allocator.Error || Error)![]u8 {
        // Billy chroot: reject paths that clean to `..` / `../…`.
        if (path_mod.crossesBoundary(path)) return error.CrossedBoundary;
        // Strip leading `/` so paths are relative to root_dir.
        var p = path;
        while (p.len > 0 and p[0] == '/') p = p[1..];
        if (p.len == 0) return try self.allocator.dupe(u8, ".");
        return try path_mod.clean(self.allocator, p);
    }
};

pub const OsFile = struct {
    os: *Os,
    file: IoFile,
    name: []u8,
    open_name_index: usize,
    flag: u32,
    pos: i64 = 0,
    closed: bool = false,

    pub fn fileName(self: *const OsFile) []const u8 {
        return self.name;
    }

    pub fn read(self: *OsFile, buf: []u8) Error!usize {
        if (self.closed) return error.Closed;
        if (self.flag & O.WRONLY != 0 and self.flag & O.RDWR == 0) return error.InvalidMode;
        const n = try self.readAt(buf, self.pos);
        self.pos += @intCast(n);
        return n;
    }

    pub fn readAt(self: *OsFile, buf: []u8, off: i64) Error!usize {
        if (self.closed) return error.Closed;
        if (off < 0) return error.InvalidMode;
        if (buf.len == 0) return 0;
        const n = self.file.readPositional(self.os.io, &.{buf}, @intCast(off)) catch |e| return mapHostErr(e);
        return n;
    }

    pub fn write(self: *OsFile, data: []const u8) Error!usize {
        if (self.closed) return error.Closed;
        if (self.flag == O.RDONLY) return error.InvalidMode;
        const n = try self.writeAt(data, self.pos);
        self.pos += @intCast(n);
        return n;
    }

    pub fn writeAt(self: *OsFile, data: []const u8, off: i64) Error!usize {
        if (self.closed) return error.Closed;
        if (off < 0) return error.InvalidMode;
        if (data.len == 0) return 0;
        self.file.writePositionalAll(self.os.io, data, @intCast(off)) catch |e| return mapHostErr(e);
        return data.len;
    }

    pub fn seek(self: *OsFile, offset: i64, whence: enum { start, current, end }) Error!i64 {
        if (self.closed) return error.Closed;
        const new_pos: i64 = switch (whence) {
            .start => offset,
            .current => self.pos + offset,
            .end => blk: {
                const st = self.file.stat(self.os.io) catch |e| return mapHostErr(e);
                break :blk @as(i64, @intCast(st.size)) + offset;
            },
        };
        if (new_pos < 0) return error.InvalidMode;
        self.pos = new_pos;
        return self.pos;
    }

    pub fn truncate(self: *OsFile, size: i64) Error!void {
        if (self.closed) return error.Closed;
        if (size < 0) return error.InvalidMode;
        self.file.setLength(self.os.io, @intCast(size)) catch |e| return mapHostErr(e);
    }

    pub fn lock(_: *OsFile) Error!void {}
    pub fn unlock(_: *OsFile) Error!void {}

    pub fn close(self: *OsFile) Error!void {
        if (self.closed) return error.Closed;
        self.closed = true;
        self.file.close(self.os.io);
        self.os.releaseOpenName(self.open_name_index, self.name);
        self.name = &.{};
    }
};

// --- error mapping -----------------------------------------------------------

/// Map host / `std.Io` errors into the billy-shaped `Error` set.
/// Unmapped errors become `Unexpected` (not `NotSupported` — that means intentional).
fn mapHostErr(err: anyerror) Error {
    return switch (err) {
        error.FileNotFound => error.NotExist,
        error.PathAlreadyExists => error.Exist,
        error.IsDir => error.IsDir,
        error.NotDir => error.NotDir,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => error.ReadOnly,
        error.NoSpaceLeft, error.DiskQuota => error.NoSpace,
        error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => error.SystemResources,
        error.Canceled => error.Unexpected,
        else => error.Unexpected,
    };
}

fn fileInfoFromStat(st: IoFile.Stat, name: []const u8) FileInfo {
    const mode: u32 = switch (st.kind) {
        .directory => 0o040000 | 0o755,
        .sym_link => 0o120000 | 0o777,
        .file => 0o100000 | 0o644,
        else => 0o100000 | 0o644,
    };
    return .{
        .name = name,
        .size = @intCast(st.size),
        .mode = mode,
        .mtime_sec = st.mtime.toSeconds(),
    };
}

// ---------------------------------------------------------------------------
// Tests — use std.testing.io (std.Io.Threaded under the test runner)
// ---------------------------------------------------------------------------

test "Os round-trip via std.Io" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var fs = try Os.initFromDir(allocator, io, tmp.dir, "tmp", false);
    defer fs.deinit();

    try fs.mkdirAll("objects/pack", 0o755);
    {
        var f = try fs.create("objects/pack/foo");
        defer f.close() catch {};
        _ = try f.write("hello");
    }
    {
        var f = try fs.open("objects/pack/foo");
        defer f.close() catch {};
        var buf: [8]u8 = undefined;
        const n = try f.read(&buf);
        try std.testing.expectEqualStrings("hello", buf[0..n]);
    }
    const st = try fs.stat("objects/pack/foo");
    try std.testing.expect(st.isRegular());
    try std.testing.expectEqual(@as(i64, 5), st.size);

    const entries = try fs.readDir("objects/pack");
    defer fs.freeReadDir(entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("foo", entries[0].name);

    try fs.rename("objects/pack/foo", "objects/pack/bar");
    _ = try fs.stat("objects/pack/bar");
    try std.testing.expectError(error.NotExist, fs.stat("objects/pack/foo"));

    try fs.remove("objects/pack/bar");
    try std.testing.expectError(error.NotExist, fs.stat("objects/pack/bar"));
}

test "Os tempFile and symlink" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var fs = try Os.initFromDir(allocator, io, tmp.dir, "tmp", false);
    defer fs.deinit();

    try fs.mkdirAll("objects/pack", 0o755);
    {
        var tf = try fs.tempFile("objects/pack", "tmp_obj_");
        defer tf.close() catch {};
        _ = try tf.write("x");
        try std.testing.expect(std.mem.indexOf(u8, tf.fileName(), "tmp_obj_") != null);
    }

    try fs.symlink("target-path", "linkname");
    const tgt = try fs.readlink("linkname");
    defer allocator.free(tgt);
    try std.testing.expectEqualStrings("target-path", tgt);
}

test "Os init opens path with createDirPathOpen" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Nested path relative to tmp: create via absolute open from cwd is hard;
    // use initFromDir as primary test path; init() for process-relative roots.
    var nested = try tmp.dir.createDirPathOpen(io, "nested-root", .{
        .open_options = .{ .iterate = true },
    });
    defer nested.close(io);

    var fs = try Os.initFromDir(allocator, io, nested, "nested-root", false);
    defer fs.deinit();
    try fs.mkdirAll("a/b", 0o755);
    try std.testing.expect((try fs.stat("a/b")).isDir());
}

// stat/lstat leave name empty (no dangling view into freed path buffer)
test "Os stat name is empty" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var fs = try Os.initFromDir(allocator, io, tmp.dir, "tmp", false);
    defer fs.deinit();
    {
        var f = try fs.create("x");
        try f.close();
    }
    const st = try fs.stat("x");
    try std.testing.expectEqualStrings("", st.name);
    try std.testing.expect(st.isRegular());
}

// chroot of a subdir is independent and closable without double-free
test "Os chroot subdir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var fs = try Os.initFromDir(allocator, io, tmp.dir, "tmp", false);
    defer fs.deinit();
    try fs.mkdirAll("sub/a", 0o755);
    {
        var f = try fs.create("sub/a/f");
        try f.close();
    }

    var ch = try fs.chroot("sub");
    defer ch.deinit();
    try std.testing.expect((try ch.stat("a")).isDir());
    _ = try ch.stat("a/f");
}
