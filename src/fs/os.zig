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
const Capability = root_mod.Capability;
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
    /// Resolve every component from the open root and reject symbolic-link
    /// traversal. This is the mode for hostile repository paths.
    secure_beneath: bool = false,
    temp_seq: u32 = 0,
    /// Names of still-open files; `OsFile.close` frees and recycles slots.
    open_names: std.ArrayListUnmanaged([]u8) = .empty,
    /// Free indices into `open_names` (empty slots ready for reuse).
    open_name_free: std.ArrayListUnmanaged(usize) = .empty,

    /// Open `root_path` (created if missing) as the filesystem root.
    pub fn init(allocator: Allocator, io: Io, root_path: []const u8) (Allocator.Error || Error)!Os {
        return initWithOptions(allocator, io, root_path, .{});
    }

    pub const Options = struct {
        secure_beneath: bool = false,
    };

    pub fn initWithOptions(allocator: Allocator, io: Io, root_path: []const u8, options: Options) (Allocator.Error || Error)!Os {
        const owned = try allocator.dupe(u8, root_path);
        errdefer allocator.free(owned);

        const dir = if (options.secure_beneath)
            try openRootSecure(io, root_path)
        else
            // Prefer createDirPathOpen so empty temp roots work; fall back to openDir.
            Dir.cwd().createDirPathOpen(io, root_path, .{
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
            .secure_beneath = options.secure_beneath,
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
        return initFromDirWithOptions(allocator, io, dir, root_path, take_ownership, .{});
    }

    pub fn initFromDirWithOptions(
        allocator: Allocator,
        io: Io,
        dir: Dir,
        root_path: []const u8,
        take_ownership: bool,
        options: Options,
    ) Allocator.Error!Os {
        return .{
            .allocator = allocator,
            .io = io,
            .root_path = try allocator.dupe(u8, root_path),
            .root_dir = dir,
            .owns_root_dir = take_ownership,
            .secure_beneath = options.secure_beneath,
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

    pub fn capabilities(_: *const Os) Capability {
        return root_mod.AllCapabilities;
    }

    /// Synchronize the root directory entry namespace. Callers sync file
    /// contents first, then use this as the rename/create/remove barrier.
    pub fn syncRoot(self: *Os) Error!void {
        try self.syncOpenDir(self.root_dir);
    }

    /// Synchronize directory-entry changes in `path` itself.
    pub fn syncDir(self: *Os, path: []const u8) (Allocator.Error || Error)!void {
        const rel = try self.relPath(path);
        defer self.allocator.free(rel);
        var dir = if (self.secure_beneath)
            try self.openSecureDir(rel, false, false)
        else if (std.mem.eql(u8, rel, "."))
            self.root_dir.openDir(self.io, ".", .{ .access_sub_paths = true, .follow_symlinks = false }) catch |e| return mapHostErr(e)
        else
            self.root_dir.openDir(self.io, rel, .{ .access_sub_paths = true, .follow_symlinks = false }) catch |e| return mapHostErr(e);
        defer dir.close(self.io);
        try self.syncOpenDir(dir);
    }

    /// Flush all regular files and directory namespaces beneath the root.
    /// Symlinks are persisted as directory entries and are never followed.
    pub fn syncTree(self: *Os) Error!void {
        try self.syncOpenTree(self.root_dir);
    }

    fn syncOpenDir(self: *Os, dir: Dir) Error!void {
        const dir_file = dir.openFile(self.io, ".", .{
            .mode = .read_only,
            .allow_directory = true,
            .follow_symlinks = false,
        }) catch |e| return mapHostErr(e);
        defer dir_file.close(self.io);
        dir_file.sync(self.io) catch |e| return mapHostErr(e);
    }

    fn syncOpenTree(self: *Os, dir: Dir) Error!void {
        var iterable = dir.openDir(self.io, ".", .{ .iterate = true, .access_sub_paths = true, .follow_symlinks = false }) catch |e| return mapHostErr(e);
        defer iterable.close(self.io);
        var it = iterable.iterate();
        while (it.next(self.io) catch |e| return mapHostErr(e)) |entry| {
            if (entry.kind == .sym_link) continue;
            if (entry.kind == .directory) {
                var child = iterable.openDir(self.io, entry.name, .{ .access_sub_paths = true, .follow_symlinks = false }) catch |e| return mapSecureComponentErr(iterable, self.io, entry.name, e);
                defer child.close(self.io);
                try self.syncOpenTree(child);
            } else if (entry.kind == .file) {
                const file = iterable.openFile(self.io, entry.name, .{ .mode = .read_only, .follow_symlinks = false }) catch |e| return mapHostErr(e);
                defer file.close(self.io);
                file.sync(self.io) catch |e| return mapHostErr(e);
            }
        }
        try self.syncOpenDir(dir);
    }

    pub fn chmod(self: *Os, filename: []const u8, mode: u32) (Allocator.Error || Error)!void {
        var file = try self.openFile(filename, O.RDONLY, 0);
        defer file.close() catch {};
        file.file.setPermissions(self.io, IoFile.Permissions.fromMode(@intCast(mode & 0o7777))) catch |e| return mapHostErr(e);
    }

    pub fn chown(self: *Os, filename: []const u8, uid: i64, gid: i64) (Allocator.Error || Error)!void {
        var file = try self.openFile(filename, O.RDONLY, 0);
        defer file.close() catch {};
        const owner: ?IoFile.Uid = if (uid < 0) null else @intCast(uid);
        const group: ?IoFile.Gid = if (gid < 0) null else @intCast(gid);
        file.file.setOwner(self.io, owner, group) catch |e| return mapHostErr(e);
    }

    pub fn lchown(_: *Os, _: []const u8, _: i64, _: i64) Error!void {
        // std.Io has no path-level no-follow owner operation. Report the
        // unsupported distinction instead of silently following the link.
        return error.NotSupported;
    }

    pub fn chtimes(self: *Os, filename: []const u8, atime_sec: i64, mtime_sec: i64) (Allocator.Error || Error)!void {
        var file = try self.openFile(filename, O.RDONLY, 0);
        defer file.close() catch {};
        file.file.setTimestamps(self.io, .{
            .access_timestamp = .{ .new = Io.Timestamp.fromNanoseconds(@as(i96, atime_sec) * std.time.ns_per_s) },
            .modify_timestamp = .{ .new = Io.Timestamp.fromNanoseconds(@as(i96, mtime_sec) * std.time.ns_per_s) },
        }) catch |e| return mapHostErr(e);
    }

    pub fn joinPath(self: *const Os, parts: []const []const u8) Allocator.Error![]u8 {
        return try path_mod.join(self.allocator, parts);
    }

    pub fn mkdirAll(self: *Os, path: []const u8, _: u32) (Allocator.Error || Error)!void {
        const rel = try self.relPath(path);
        defer self.allocator.free(rel);
        if (rel.len == 0 or std.mem.eql(u8, rel, ".")) return;
        if (self.secure_beneath) {
            var dir = try self.openSecureDir(rel, true, false);
            dir.close(self.io);
            return;
        }
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

        if (self.secure_beneath) {
            const file = try self.openFileSecure(rel, flag);
            errdefer file.close(self.io);
            if (flag & O.APPEND != 0) {
                const st = file.stat(self.io) catch |e| return mapHostErr(e);
                return self.finishOpenFile(rel, &rel_owned, file, flag, @intCast(st.size));
            }
            return self.finishOpenFile(rel, &rel_owned, file, flag, 0);
        }

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

        return self.finishOpenFile(rel, &rel_owned, file, flag, pos);
    }

    pub fn stat(self: *Os, filename: []const u8) (Allocator.Error || Error)!FileInfo {
        const rel = try self.relPath(filename);
        defer self.allocator.free(rel);
        if (self.secure_beneath) return self.secureStat(rel, true);
        const st = self.root_dir.statFile(self.io, rel, .{ .follow_symlinks = true }) catch |e| return mapHostErr(e);
        // Empty name: do not return a view into freed `rel` (FileInfo.name is
        // only owned for readDir entries — see fileinfo.zig).
        return fileInfoFromStat(st, "");
    }

    pub fn lstat(self: *Os, filename: []const u8) (Allocator.Error || Error)!FileInfo {
        const rel = try self.relPath(filename);
        defer self.allocator.free(rel);
        if (self.secure_beneath) return self.secureStat(rel, false);
        const st = self.root_dir.statFile(self.io, rel, .{ .follow_symlinks = false }) catch |e| return mapHostErr(e);
        return fileInfoFromStat(st, "");
    }

    /// Caller frees with `freeReadDir`.
    pub fn readDir(self: *Os, path: []const u8) (Allocator.Error || Error)![]FileInfo {
        const rel = try self.relPath(path);
        defer self.allocator.free(rel);

        if (self.secure_beneath) return self.readSecureDir(rel);

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
        var parent = if (self.secure_beneath) try self.resolveSecureParent(rel, false) else SecureParent.borrowed(self.root_dir, rel);
        defer parent.deinit(self.io);
        // Try file first, then directory.
        parent.dir.deleteFile(self.io, parent.name) catch |err| switch (err) {
            error.FileNotFound => return error.NotExist,
            error.IsDir => {
                parent.dir.deleteDir(self.io, parent.name) catch |e| return mapHostErr(e);
            },
            else => |e| return mapHostErr(e),
        };
    }

    pub fn rename(self: *Os, oldpath: []const u8, newpath: []const u8) (Allocator.Error || Error)!void {
        const old_rel = try self.relPath(oldpath);
        defer self.allocator.free(old_rel);
        const new_rel = try self.relPath(newpath);
        defer self.allocator.free(new_rel);
        if (self.secure_beneath) {
            var old_parent = try self.resolveSecureParent(old_rel, false);
            defer old_parent.deinit(self.io);
            var new_parent = try self.resolveSecureParent(new_rel, true);
            defer new_parent.deinit(self.io);
            old_parent.dir.rename(old_parent.name, new_parent.dir, new_parent.name, self.io) catch |e| return mapHostErr(e);
            return;
        }
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
        if (self.secure_beneath) {
            const sub = self.openSecureDir(rel, false, false) catch |e| {
                self.allocator.free(rel);
                return e;
            };
            const new_root = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root_path, rel }) catch |e| {
                sub.close(self.io);
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
                .secure_beneath = true,
                .temp_seq = self.temp_seq,
            };
        }
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
            .secure_beneath = self.secure_beneath,
            .temp_seq = self.temp_seq,
        };
    }

    pub fn symlink(self: *Os, target: []const u8, link: []const u8) (Allocator.Error || Error)!void {
        const rel = try self.relPath(link);
        defer self.allocator.free(rel);
        if (self.secure_beneath) {
            var parent = try self.resolveSecureParent(rel, true);
            defer parent.deinit(self.io);
            parent.dir.symLink(self.io, target, parent.name, .{}) catch |e| return mapHostErr(e);
            return;
        }
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
        var parent = if (self.secure_beneath) try self.resolveSecureParent(rel, false) else SecureParent.borrowed(self.root_dir, rel);
        defer parent.deinit(self.io);
        var buf: [Dir.max_path_bytes]u8 = undefined;
        const n = parent.dir.readLink(self.io, parent.name, &buf) catch |e| return mapHostErr(e);
        return try self.allocator.dupe(u8, buf[0..n]);
    }

    const SecureParent = struct {
        dir: Dir,
        name: []const u8,
        owns_dir: bool,

        fn borrowed(dir: Dir, name: []const u8) SecureParent {
            return .{ .dir = dir, .name = name, .owns_dir = false };
        }

        fn deinit(self: *SecureParent, io: Io) void {
            if (self.owns_dir) self.dir.close(io);
            self.* = undefined;
        }
    };

    fn finishOpenFile(self: *Os, rel: []u8, rel_owned: *bool, file: IoFile, flag: u32, pos: i64) Allocator.Error!OsFile {
        const name_index = try self.registerOpenName(rel);
        rel_owned.* = false;
        return .{ .os = self, .file = file, .name = rel, .open_name_index = name_index, .flag = flag, .pos = pos };
    }

    fn resolveSecureParent(self: *Os, rel: []const u8, create_missing: bool) (Allocator.Error || Error)!SecureParent {
        const slash = std.mem.lastIndexOfScalar(u8, rel, '/');
        const parent_path = if (slash) |at| rel[0..at] else "";
        const name = if (slash) |at| rel[at + 1 ..] else rel;
        if (name.len == 0 or std.mem.eql(u8, name, ".")) return error.InvalidMode;
        if (parent_path.len == 0) return SecureParent.borrowed(self.root_dir, name);
        return .{ .dir = try self.openSecureDir(parent_path, create_missing, false), .name = name, .owns_dir = true };
    }

    fn openSecureDir(self: *Os, rel: []const u8, create_missing: bool, iterate: bool) (Allocator.Error || Error)!Dir {
        var current = self.root_dir;
        var owns_current = false;
        errdefer if (owns_current) current.close(self.io);

        var components = std.mem.splitScalar(u8, rel, '/');
        while (components.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
            const next = current.openDir(self.io, component, .{
                .access_sub_paths = true,
                .iterate = iterate and components.rest().len == 0,
                .follow_symlinks = false,
            }) catch |err| switch (err) {
                error.FileNotFound => blk: {
                    if (!create_missing) return error.NotExist;
                    current.createDir(self.io, component, .default_dir) catch |create_err| switch (create_err) {
                        error.PathAlreadyExists => {},
                        else => |e| return mapHostErr(e),
                    };
                    break :blk current.openDir(self.io, component, .{
                        .access_sub_paths = true,
                        .iterate = iterate and components.rest().len == 0,
                        .follow_symlinks = false,
                    }) catch |e| return mapSecureComponentErr(current, self.io, component, e);
                },
                else => |e| return mapSecureComponentErr(current, self.io, component, e),
            };
            if (owns_current) current.close(self.io);
            current = next;
            owns_current = true;
        }
        if (!owns_current) {
            return self.root_dir.openDir(self.io, ".", .{ .access_sub_paths = true, .iterate = iterate, .follow_symlinks = false }) catch |e| return mapHostErr(e);
        }
        return current;
    }

    fn openFileSecure(self: *Os, rel: []const u8, flag: u32) (Allocator.Error || Error)!IoFile {
        var parent = try self.resolveSecureParent(rel, flag & O.CREATE != 0);
        defer parent.deinit(self.io);
        const mode: Dir.OpenFileOptions.Mode = if (flag & O.RDWR != 0) .read_write else if (flag & O.WRONLY != 0) .write_only else .read_only;

        if (flag & O.CREATE == 0) return parent.dir.openFile(self.io, parent.name, .{
            .mode = mode,
            .allow_directory = false,
            .follow_symlinks = false,
        }) catch |e| return mapHostErr(e);

        if (flag & O.EXCL != 0) return parent.dir.createFile(self.io, parent.name, .{
            .read = mode != .write_only,
            .truncate = flag & O.TRUNC != 0,
            .exclusive = true,
        }) catch |e| return mapHostErr(e);

        const existing = parent.dir.openFile(self.io, parent.name, .{
            .mode = mode,
            .allow_directory = false,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                return parent.dir.createFile(self.io, parent.name, .{
                    .read = mode != .write_only,
                    .truncate = flag & O.TRUNC != 0,
                    .exclusive = true,
                }) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => parent.dir.openFile(self.io, parent.name, .{
                        .mode = mode,
                        .allow_directory = false,
                        .follow_symlinks = false,
                    }) catch |e| return mapHostErr(e),
                    else => |e| return mapHostErr(e),
                };
            },
            else => |e| return mapHostErr(e),
        };
        if (flag & O.TRUNC != 0) existing.setLength(self.io, 0) catch |e| {
            existing.close(self.io);
            return mapHostErr(e);
        };
        return existing;
    }

    fn secureStat(self: *Os, rel: []const u8, follow_final: bool) (Allocator.Error || Error)!FileInfo {
        var parent = try self.resolveSecureParent(rel, false);
        defer parent.deinit(self.io);
        const st = parent.dir.statFile(self.io, parent.name, .{ .follow_symlinks = false }) catch |e| return mapHostErr(e);
        // Following a final symlink safely requires resolving its target from
        // this same root. Secure mode deliberately fails closed; lstat and
        // readlink remain available for operating on the symlink object.
        if (follow_final and st.kind == .sym_link) return error.CrossedBoundary;
        return fileInfoFromStat(st, "");
    }

    fn readSecureDir(self: *Os, rel: []const u8) (Allocator.Error || Error)![]FileInfo {
        var dir = try self.openSecureDir(rel, false, true);
        defer dir.close(self.io);
        return self.readDirFromOpen(dir);
    }

    fn readDirFromOpen(self: *Os, dir: Dir) (Allocator.Error || Error)![]FileInfo {
        var list: std.ArrayList(FileInfo) = .empty;
        errdefer {
            for (list.items) |entry| if (entry.name.len > 0) self.allocator.free(@constCast(entry.name));
            list.deinit(self.allocator);
        }
        var it = dir.iterate();
        while (it.next(self.io) catch |e| return mapHostErr(e)) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            const name = try self.allocator.dupe(u8, entry.name);
            const mode: u32 = switch (entry.kind) {
                .directory => 0o040755,
                .sym_link => 0o120777,
                .file => 0o100644,
                else => 0o100644,
            };
            try list.append(self.allocator, .{ .name = name, .size = 0, .mode = mode });
        }
        std.mem.sort(FileInfo, list.items, {}, struct {
            fn less(_: void, a: FileInfo, b: FileInfo) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);
        return try list.toOwnedSlice(self.allocator);
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

    pub fn lock(self: *OsFile) Error!void {
        if (self.closed) return error.Closed;
        self.file.lock(self.os.io, .exclusive) catch |e| return mapHostErr(e);
    }

    pub fn unlock(self: *OsFile) Error!void {
        if (self.closed) return error.Closed;
        self.file.unlock(self.os.io);
    }

    pub fn sync(self: *OsFile) Error!void {
        if (self.closed) return error.Closed;
        self.file.sync(self.os.io) catch |e| return mapHostErr(e);
    }

    pub fn close(self: *OsFile) Error!void {
        if (self.closed) return error.Closed;
        self.closed = true;
        self.file.close(self.os.io);
        self.os.releaseOpenName(self.open_name_index, self.name);
        self.name = &.{};
    }
};

/// Create/open a configured root without following a symbolic link in any
/// component. The returned directory handle is the permanent resolution
/// anchor used by secure `Os` operations.
fn openRootSecure(io: Io, root_path: []const u8) Error!Dir {
    const absolute = root_path.len > 0 and root_path[0] == '/';
    var current = if (absolute)
        Dir.openDirAbsolute(io, "/", .{ .iterate = true, .access_sub_paths = true, .follow_symlinks = false }) catch |e| return mapHostErr(e)
    else
        Dir.cwd();
    var owns_current = absolute;
    errdefer if (owns_current) current.close(io);

    var opened_component = false;
    var components = std.mem.splitScalar(u8, root_path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) return error.CrossedBoundary;
        const next = current.openDir(io, component, .{
            .iterate = true,
            .access_sub_paths = true,
            .follow_symlinks = false,
        }) catch |err| switch (err) {
            error.FileNotFound => blk: {
                current.createDir(io, component, .default_dir) catch |create_err| switch (create_err) {
                    error.PathAlreadyExists => {},
                    else => |e| return mapHostErr(e),
                };
                break :blk current.openDir(io, component, .{
                    .iterate = true,
                    .access_sub_paths = true,
                    .follow_symlinks = false,
                }) catch |e| return mapSecureComponentErr(current, io, component, e);
            },
            else => |e| return mapSecureComponentErr(current, io, component, e),
        };
        if (owns_current) current.close(io);
        current = next;
        owns_current = true;
        opened_component = true;
    }
    if (!opened_component and !absolute) {
        return Dir.cwd().openDir(io, ".", .{ .iterate = true, .access_sub_paths = true, .follow_symlinks = false }) catch |e| return mapHostErr(e);
    }
    return current;
}

// --- error mapping -----------------------------------------------------------

/// Map host / `std.Io` errors into the billy-shaped `Error` set.
/// Unmapped errors become `Unexpected` (not `NotSupported` — that means intentional).
fn mapHostErr(err: anyerror) Error {
    return switch (err) {
        error.FileNotFound => error.NotExist,
        error.PathAlreadyExists => error.Exist,
        error.IsDir => error.IsDir,
        error.NotDir => error.NotDir,
        error.SymLinkLoop => error.CrossedBoundary,
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => error.ReadOnly,
        error.NoSpaceLeft, error.DiskQuota => error.NoSpace,
        error.SystemResources, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => error.SystemResources,
        error.FileLocksUnsupported => error.NotSupported,
        error.Canceled => error.Unexpected,
        else => error.Unexpected,
    };
}

fn mapSecureComponentErr(dir: Dir, io: Io, name: []const u8, err: anyerror) Error {
    if (err == error.SymLinkLoop) return error.CrossedBoundary;
    if (err == error.NotDir) {
        const st = dir.statFile(io, name, .{ .follow_symlinks = false }) catch return error.NotDir;
        if (st.kind == .sym_link) return error.CrossedBoundary;
    }
    return mapHostErr(err);
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
        .atime_sec = if (st.atime) |atime| atime.toSeconds() else 0,
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

test "Os secure mode contains every operation beneath its directory handle" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var outer = try Os.initFromDir(allocator, io, tmp.dir, "tmp", false);
    defer outer.deinit();
    try outer.mkdirAll("root/safe", 0o755);
    try outer.mkdirAll("outside", 0o755);
    {
        var sentinel = try outer.create("outside/sentinel");
        defer sentinel.close() catch {};
        _ = try sentinel.write("unchanged");
    }
    try outer.symlink("../outside", "root/escape");
    try outer.symlink("../outside/sentinel", "root/final-link");

    var root_dir = try tmp.dir.openDir(io, "root", .{ .iterate = true, .access_sub_paths = true });
    defer root_dir.close(io);
    var secure = try Os.initFromDirWithOptions(allocator, io, root_dir, "root", false, .{ .secure_beneath = true });
    defer secure.deinit();

    // Ancestor symlinks cannot redirect reads or any mutating operation.
    try std.testing.expectError(error.CrossedBoundary, secure.open("escape/sentinel"));
    try std.testing.expectError(error.CrossedBoundary, secure.create("escape/created"));
    try std.testing.expectError(error.CrossedBoundary, secure.mkdirAll("escape/new-dir", 0o755));
    try std.testing.expectError(error.CrossedBoundary, secure.remove("escape/sentinel"));
    try std.testing.expectError(error.CrossedBoundary, secure.rename("safe/source", "escape/moved"));
    try std.testing.expectError(error.CrossedBoundary, secure.chmod("escape/sentinel", 0o600));
    try std.testing.expectError(error.CrossedBoundary, secure.stat("escape/sentinel"));
    try std.testing.expectError(error.CrossedBoundary, secure.readDir("escape"));
    try std.testing.expectError(error.CrossedBoundary, secure.chroot("escape"));

    // Final symlinks remain inspectable as objects, but are never followed.
    try std.testing.expect((try secure.lstat("final-link")).isSymlink());
    const target = try secure.readlink("final-link");
    defer allocator.free(target);
    try std.testing.expectEqualStrings("../outside/sentinel", target);
    try std.testing.expectError(error.CrossedBoundary, secure.open("final-link"));
    try std.testing.expectError(error.CrossedBoundary, secure.stat("final-link"));

    // Ordinary paths retain full read/write/rename behavior.
    {
        var source = try secure.create("safe/source");
        defer source.close() catch {};
        _ = try source.write("inside");
    }
    try secure.rename("safe/source", "safe/destination");
    try std.testing.expect((try secure.stat("safe/destination")).isRegular());
    try secure.syncTree();

    // The sibling tree was not touched by any rejected operation.
    {
        var sentinel = try outer.open("outside/sentinel");
        defer sentinel.close() catch {};
        var buf: [16]u8 = undefined;
        const n = try sentinel.read(&buf);
        try std.testing.expectEqualStrings("unchanged", buf[0..n]);
    }
    try std.testing.expectError(error.NotExist, outer.stat("outside/created"));
    try std.testing.expectError(error.NotExist, outer.stat("outside/new-dir"));
}

test "Os secure init rejects a symlink in the configured root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var outer = try Os.initFromDir(allocator, io, tmp.dir, "tmp", false);
    defer outer.deinit();
    try outer.mkdirAll("real-root", 0o755);
    try outer.symlink("real-root", "root-link");

    var path_buf: [Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const linked_root = try std.fmt.allocPrint(allocator, "{s}/root-link", .{path_buf[0..path_len]});
    defer allocator.free(linked_root);
    try std.testing.expectError(error.CrossedBoundary, Os.initWithOptions(allocator, io, linked_root, .{ .secure_beneath = true }));
}
