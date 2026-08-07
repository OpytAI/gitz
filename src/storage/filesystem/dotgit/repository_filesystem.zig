//! go-git `RepositoryFilesystem` — routes paths to worktree `.git` vs commondir.
//!
//! See gitrepository-layout.txt: most of objects/refs/config live in the common
//! dir when set; worktree-private paths (e.g. logs/HEAD, refs/bisect) stay local.
//!
//! Monomorphised over billy-style `Fs` (`Mem` / `Os`) so both backends share the
//! same routing rules. Default export is `RepositoryFilesystem` = Mem.

const std = @import("std");
const fs_mod = @import("fs");

const Allocator = std.mem.Allocator;
const FileInfo = fs_mod.FileInfo;
const Error = fs_mod.Error;
const Mem = fs_mod.Mem;
const Os = fs_mod.Os;

const objects_path = "objects";
const refs_path = "refs";
const packed_refs_path = "packed-refs";
const config_path = "config";
const branches_path = "branches";
const hooks_path = "hooks";
const info_path = "info";
const remotes_path = "remotes";
const logs_path = "logs";
const shallow_path = "shallow";
const worktrees_path = "worktrees";

/// go-git `RepositoryFilesystem` monomorphised over billy-style `Fs`.
///
/// Both backends must use the **same allocator** so `freeReadDir` can free names
/// allocated by either side.
pub fn RepositoryFilesystemFor(comptime Fs: type) type {
    return struct {
        const Self = @This();
        pub const File = Fs.File;

        /// Worktree-local `.git` (or the only FS when common is null).
        dot_git_fs: *Fs,
        /// Optional shared common dir (objects, refs, config, …).
        common_dot_git_fs: ?*Fs = null,

        /// go-git `NewRepositoryFilesystem`.
        pub fn init(dot_git_fs: *Fs, common_dot_git_fs: ?*Fs) Self {
            if (common_dot_git_fs) |c| {
                std.debug.assert(dot_git_fs.allocator.ptr == c.allocator.ptr);
            }
            return .{
                .dot_git_fs = dot_git_fs,
                .common_dot_git_fs = common_dot_git_fs,
            };
        }

        pub fn newRepositoryFilesystem(dot_git_fs: *Fs, common_dot_git_fs: ?*Fs) Self {
            return init(dot_git_fs, common_dot_git_fs);
        }

        fn mapByPath(self: *const Self, path: []const u8) *Fs {
            const common = self.common_dot_git_fs orelse return self.dot_git_fs;

            // Normalize: strip leading `./` and collapse to first segment.
            var clean = path;
            while (std.mem.startsWith(u8, clean, "./")) clean = clean[2..];
            while (clean.len > 0 and clean[0] == '/') clean = clean[1..];

            // Exceptions always on worktree FS (gitrepository-layout).
            if (std.mem.eql(u8, clean, "logs/HEAD") or
                std.mem.eql(u8, clean, "refs/bisect") or
                std.mem.eql(u8, clean, "refs/rewritten") or
                std.mem.eql(u8, clean, "refs/worktree") or
                std.mem.startsWith(u8, clean, "refs/bisect/") or
                std.mem.startsWith(u8, clean, "refs/rewritten/") or
                std.mem.startsWith(u8, clean, "refs/worktree/"))
            {
                return self.dot_git_fs;
            }

            var first = clean;
            if (std.mem.indexOfScalar(u8, clean, '/')) |i| first = clean[0..i];

            if (std.mem.eql(u8, first, objects_path) or
                std.mem.eql(u8, first, refs_path) or
                std.mem.eql(u8, first, packed_refs_path) or
                std.mem.eql(u8, first, config_path) or
                std.mem.eql(u8, first, branches_path) or
                std.mem.eql(u8, first, hooks_path) or
                std.mem.eql(u8, first, info_path) or
                std.mem.eql(u8, first, remotes_path) or
                std.mem.eql(u8, first, logs_path) or
                std.mem.eql(u8, first, shallow_path) or
                std.mem.eql(u8, first, worktrees_path))
            {
                return common;
            }
            return self.dot_git_fs;
        }

        pub fn root(self: *const Self) []const u8 {
            return self.dot_git_fs.root();
        }

        pub fn joinPath(self: *const Self, parts: []const []const u8) Allocator.Error![]u8 {
            return self.dot_git_fs.joinPath(parts);
        }

        pub fn mkdirAll(self: *Self, path: []const u8, mode: u32) (Allocator.Error || Error)!void {
            return self.mapByPath(path).mkdirAll(path, mode);
        }

        pub fn create(self: *Self, filename: []const u8) (Allocator.Error || Error)!File {
            return self.mapByPath(filename).create(filename);
        }

        pub fn open(self: *Self, filename: []const u8) (Allocator.Error || Error)!File {
            return self.mapByPath(filename).open(filename);
        }

        pub fn openFile(self: *Self, filename: []const u8, flag: u32, perm: u32) (Allocator.Error || Error)!File {
            return self.mapByPath(filename).openFile(filename, flag, perm);
        }

        pub fn stat(self: *Self, filename: []const u8) (Allocator.Error || Error)!FileInfo {
            return self.mapByPath(filename).stat(filename);
        }

        pub fn lstat(self: *Self, filename: []const u8) (Allocator.Error || Error)!FileInfo {
            return self.mapByPath(filename).lstat(filename);
        }

        pub fn readDir(self: *Self, path: []const u8) (Allocator.Error || Error)![]FileInfo {
            return self.mapByPath(path).readDir(path);
        }

        pub fn freeReadDir(self: *Self, entries: []FileInfo) void {
            // Names were allocated with the shared allocator (asserted in init).
            self.dot_git_fs.freeReadDir(entries);
        }

        pub fn remove(self: *Self, filename: []const u8) (Allocator.Error || Error)!void {
            return self.mapByPath(filename).remove(filename);
        }

        pub fn rename(self: *Self, oldpath: []const u8, newpath: []const u8) (Allocator.Error || Error)!void {
            return self.mapByPath(oldpath).rename(oldpath, newpath);
        }

        pub fn tempFile(self: *Self, dir: []const u8, prefix: []const u8) (Allocator.Error || Error)!File {
            return self.mapByPath(dir).tempFile(dir, prefix);
        }

        pub fn chroot(self: *Self, path: []const u8) (Allocator.Error || Error)!Fs {
            return self.mapByPath(path).chroot(path);
        }

        pub fn symlink(self: *Self, target: []const u8, link: []const u8) (Allocator.Error || Error)!void {
            return self.mapByPath(link).symlink(target, link);
        }

        pub fn readlink(self: *Self, link: []const u8) (Allocator.Error || Error)![]u8 {
            return self.mapByPath(link).readlink(link);
        }
    };
}

/// Mem specialisation (default call sites / go-git tests).
pub const RepositoryFilesystemMem = RepositoryFilesystemFor(Mem);
/// Os specialisation (on-disk worktree + common dir).
pub const RepositoryFilesystemOs = RepositoryFilesystemFor(Os);
/// Default export — Mem (backward compatible).
pub const RepositoryFilesystem = RepositoryFilesystemMem;

// go-git RepositoryFilesystem: objects → common, worktree file → local
test "RepositoryFilesystem routes objects to common" {
    const gpa = std.testing.allocator;
    var local = try Mem.init(gpa);
    defer local.deinit();
    var common = try Mem.init(gpa);
    defer common.deinit();

    var rfs = RepositoryFilesystem.init(&local, &common);
    try rfs.mkdirAll("objects/pack", fs_mod.Mode.dir);
    // objects path should hit common
    try std.testing.expect((try common.stat("objects/pack")).isDir());
    try std.testing.expectError(error.NotExist, local.stat("objects/pack"));

    // worktree-private path stays on local
    {
        var f = try rfs.create("logs/HEAD");
        defer f.close() catch {};
        _ = try f.write("ref: refs/heads/main\n");
    }
    _ = try local.stat("logs/HEAD");
    try std.testing.expectError(error.NotExist, common.stat("logs/HEAD"));
}

// monomorphisation surface: Os specialisation is a real type
test "RepositoryFilesystemOs type exists" {
    try std.testing.expect(@TypeOf(RepositoryFilesystemOs) != void);
    try std.testing.expect(@TypeOf(RepositoryFilesystemFor) != void);
}
