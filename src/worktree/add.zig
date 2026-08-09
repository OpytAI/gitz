//! Worktree Add / Remove / Move / Glob (go-git `worktree_status.go`).
//!
//! Ports: `Add`, `AddWithOptions`, `AddGlob`, `Remove`, `RemoveGlob`, `Move`,
//! and helpers `doAdd`, `doAddFile`, `doAddDirectory`, `copyFileToStorage`,
//! `addOrUpdateFileToIndex`, `doAddFileToIndex`, `doUpdateFileToIndex`,
//! `doRemoveFile`, `doRemoveDirectory`, `deleteFromIndex`, `deleteFromFilesystem`.

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");
const fs_pkg = @import("fs");
const filemode = @import("filemode");
const index_fmt = @import("index");
const gitignore = @import("gitignore");
const pathutil = @import("pathutil");

const worktree_mod = @import("worktree.zig");
const options_mod = @import("options.zig");
const platform_mod = @import("platform.zig");
const error_mod = @import("error.zig");
const status_types = @import("status_types.zig");
const status_mod = @import("status.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const Worktree = worktree_mod.Worktree;
const AddOptions = options_mod.AddOptions;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const Index = index_fmt.Index;
const Entry = index_fmt.Entry;
const Status = status_types.Status;
const FileInfo = fs_pkg.FileInfo;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// go-git `Worktree.Add` — stage `path` (file or directory). Returns blob hash
/// for a file, or `ZeroHash` when staging a directory.
pub fn add(w: *Worktree, path: []const u8) !Hash {
    return doAdd(w, path, &.{}, false);
}

/// go-git `Worktree.AddWithOptions`.
pub fn addWithOptions(w: *Worktree, o: AddOptions) !void {
    try o.validate();
    if (o.all) {
        _ = try doAdd(w, ".", w.excludes, false);
        return;
    }
    if (o.glob.len > 0) {
        return addGlob(w, o.glob);
    }
    _ = try doAdd(w, o.path, &.{}, o.skip_status);
}

/// go-git `Worktree.Remove` — remove `path` from the index and worktree.
/// Returns the removed blob hash for a file, or `ZeroHash` for a directory.
pub fn remove(w: *Worktree, path: []const u8) !Hash {
    try pathutil.validTreePath(path);
    const idx = try w.storer.index();
    var h = ZeroHash;

    const fi = w.filesystem.lstat(path) catch |err| switch (err) {
        error.NotExist => {
            h = try doRemoveFile(w, idx, path);
            w.storer.setIndex(idx);
            return h;
        },
        else => return err,
    };

    if (!fi.isDir()) {
        h = try doRemoveFile(w, idx, path);
    } else {
        _ = try doRemoveDirectory(w, idx, path);
        h = ZeroHash;
    }
    w.storer.setIndex(idx);
    return h;
}

// ---------------------------------------------------------------------------
// Add core
// ---------------------------------------------------------------------------

fn doAdd(
    w: *Worktree,
    path_in: []const u8,
    ignore_pattern: []const gitignore.Pattern,
    skip_status: bool,
) !Hash {
    // Validate the caller-controlled form before cleaning. Cleaning `..`
    // first can turn an escaping path into an apparently safe relative path.
    if (!std.mem.eql(u8, path_in, ".")) try pathutil.validTreePath(path_in);
    const idx = try w.storer.index();

    const path = try cleanToSlash(w.allocator, path_in);
    defer w.allocator.free(path);
    if (!std.mem.eql(u8, path, ".")) try pathutil.validTreePath(path);

    // Optional Status: skip unmodified worktree files (go-git). When
    // `skip_status` and the path is a regular file, go-git skips Status.
    // Otherwise load real worktree Status so unmodified paths are not re-staged.
    // Directory / all adds still walk the FS for untracked paths.
    var status_opt: ?Status = null;
    defer if (status_opt) |*s| s.deinit();

    const fi_or_err = w.filesystem.lstat(path);
    const fi_opt: ?FileInfo = fi_or_err catch null;
    const need_status = !skip_status or fi_opt == null or fi_opt.?.isDir();
    if (need_status) {
        status_opt = try loadStatus(w);
    }

    var h = ZeroHash;
    var added = false;

    const status_ptr: ?*Status = if (status_opt) |*s| s else null;

    if (fi_opt) |fi| {
        if (!fi.isDir()) {
            const r = try doAddFile(w, idx, status_ptr, path, ignore_pattern);
            added = r.added;
            h = r.hash;
        } else {
            added = try doAddDirectory(w, idx, status_ptr, path, ignore_pattern);
            h = ZeroHash;
        }
    } else {
        // Missing path: stage deletion if indexed (go-git doAddFile NotExist).
        const r = try doAddFile(w, idx, status_ptr, path, ignore_pattern);
        added = r.added;
        h = r.hash;
        if (!added) {
            // Not in index and not on disk → go-git returns the lstat error.
            return error.NotExist;
        }
    }

    if (!added) return h;
    w.storer.setIndex(idx);
    return h;
}

const AddFileResult = struct { added: bool, hash: Hash };

/// go-git `doAddFile` — create/update blob + index entry, or stage deletion.
fn doAddFile(
    w: *Worktree,
    idx: *Index,
    s: ?*Status,
    path: []const u8,
    ignore_pattern: []const gitignore.Pattern,
) !AddFileResult {
    if (s) |st| {
        const fs = try st.file(path);
        if (fs.worktree == .unmodified) {
            return .{ .added = false, .hash = ZeroHash };
        }
    }

    if (ignore_pattern.len > 0) {
        if (matchIgnore(ignore_pattern, path, true)) {
            return .{ .added = false, .hash = ZeroHash };
        }
    }

    const hash_or = copyFileToStorage(w, path);
    if (hash_or) |h| {
        try addOrUpdateFileToIndex(w, idx, path, h);
        return .{ .added = true, .hash = h };
    } else |err| {
        if (err == error.NotExist) {
            const h = deleteFromIndex(idx, path) catch |e| {
                if (e == index_fmt.Error.EntryNotFound) {
                    return .{ .added = false, .hash = ZeroHash };
                }
                return e;
            };
            return .{ .added = true, .hash = h };
        }
        return err;
    }
}

/// Directory add: walk worktree under `directory`, stage each file; also stage
/// deletions for index entries under that directory that are missing on disk.
///
/// go-git iterates the Status map for dirty paths under the directory. We also
/// walk the Mem FS so untracked files under the directory are staged (Status
/// Empty strategy may omit paths that are not yet in the map).
fn doAddDirectory(
    w: *Worktree,
    idx: *Index,
    s: ?*Status,
    directory: []const u8,
    ignore_pattern: []const gitignore.Pattern,
) !bool {
    if (ignore_pattern.len > 0) {
        if (matchIgnore(ignore_pattern, directory, true)) {
            return false;
        }
    }

    var added = false;

    // Status-driven path (go-git): every dirty path under the directory.
    if (s) |st| {
        var it = st.map.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            if (!isPathInDirectory(name, directory)) continue;
            const r = try doAddFile(w, idx, s, name, ignore_pattern);
            added = added or r.added;
        }
    }

    // Filesystem walk: pick up untracked files not already in Status.
    var files: std.ArrayList([]const u8) = .empty;
    defer {
        for (files.items) |p| w.allocator.free(p);
        files.deinit(w.allocator);
    }
    try collectFiles(w, directory, &files);

    for (files.items) |name| {
        // Skip if status already marked unmodified (doAddFile checks again).
        const r = try doAddFile(w, idx, s, name, ignore_pattern);
        added = added or r.added;
    }

    // Stage deletions: index entries under directory missing from the worktree.
    var to_delete: std.ArrayList([]const u8) = .empty;
    defer {
        for (to_delete.items) |p| w.allocator.free(p);
        to_delete.deinit(w.allocator);
    }
    for (idx.entries.items) |e| {
        if (!isPathInDirectory(e.name, directory)) continue;
        _ = w.filesystem.lstat(e.name) catch |err| {
            if (err == error.NotExist) {
                try to_delete.append(w.allocator, try w.allocator.dupe(u8, e.name));
            }
            continue;
        };
    }
    for (to_delete.items) |name| {
        _ = deleteFromIndex(idx, name) catch |e| {
            if (e == index_fmt.Error.EntryNotFound) continue;
            return e;
        };
        added = true;
    }

    return added;
}

fn isPathInDirectory(path: []const u8, directory: []const u8) bool {
    if (std.mem.eql(u8, directory, ".") or directory.len == 0) return true;
    if (!std.mem.startsWith(u8, path, directory)) return false;
    if (path.len == directory.len) return false;
    return path[directory.len] == '/';
}

// ---------------------------------------------------------------------------
// Blob + index helpers
// ---------------------------------------------------------------------------

/// go-git `copyFileToStorage` — read worktree path into a new blob object.
pub fn copyFileToStorage(w: *Worktree, path: []const u8) !Hash {
    try pathutil.validTreePath(path);
    const fi = try w.filesystem.lstat(path);

    const obj = try w.storer.newEncodedObject();
    errdefer {
        obj.deinit();
        w.storer.allocator.destroy(obj);
    }
    obj.setType(.blob);
    obj.setSize(fi.size);

    if (fi.isSymlink()) {
        const target = try w.filesystem.readlink(path);
        defer w.allocator.free(target);
        _ = try obj.write(target);
    } else {
        var f = try w.filesystem.open(path);
        defer f.close() catch {};
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try f.read(&buf);
            if (n == 0) break;
            _ = try obj.write(buf[0..n]);
        }
    }

    // setEncodedObject takes ownership of obj on success (and on
    // UnsupportedObjectType). Blob type always succeeds ownership transfer.
    return try w.storer.setEncodedObject(obj);
}

/// go-git `addOrUpdateFileToIndex`.
pub fn addOrUpdateFileToIndex(w: *Worktree, idx: *Index, filename: []const u8, h: Hash) !void {
    try pathutil.validTreePath(filename);
    const e = idx.entry(filename) catch |err| {
        if (err == index_fmt.Error.EntryNotFound) {
            return doAddFileToIndex(w, idx, filename, h);
        }
        return err;
    };
    return doUpdateFileToIndex(w, e, filename, h);
}

fn doAddFileToIndex(w: *Worktree, idx: *Index, filename: []const u8, h: Hash) !void {
    try pathutil.validTreePath(filename);
    const e = try idx.add(filename);
    return doUpdateFileToIndex(w, e, filename, h);
}

fn doUpdateFileToIndex(w: *Worktree, e: *Entry, filename: []const u8, h: Hash) !void {
    const info = try w.filesystem.lstat(filename);

    e.hash = h;
    e.modified_at = .{
        .sec = info.mtime_sec,
        .nsec = 0,
    };
    e.mode = try fileModeFromInfo(info);
    e.size = @intCast(info.size);

    // go-git fillSystemInfo(e, info.Sys()) — platform ctime/dev/ino/uid/gid.
    platform_mod.fillSystemInfo(e, w.filesystem, filename);
}

/// Map Mem `FileInfo` Unix mode bits to a git `FileMode`.
fn fileModeFromInfo(info: FileInfo) filemode.Error!filemode.FileMode {
    const perm = info.mode & 0o777;
    const t = info.mode & 0o170000;
    const os_mode: filemode.OSFileMode = switch (t) {
        0o040000 => perm | filemode.os_mode_dir,
        0o120000 => perm | filemode.os_mode_symlink,
        else => perm, // regular (0 or 0o100000)
    };
    return filemode.newFromOSFileMode(os_mode);
}

// ---------------------------------------------------------------------------
// Remove helpers
// ---------------------------------------------------------------------------

fn doRemoveDirectory(w: *Worktree, idx: *Index, directory: []const u8) !bool {
    const entries = try w.filesystem.readDir(directory);
    defer w.filesystem.freeReadDir(entries);

    var removed = false;
    for (entries) |file| {
        const name = try joinRel(w.allocator, directory, file.name);
        defer w.allocator.free(name);

        if (file.isDir()) {
            const r = try doRemoveDirectory(w, idx, name);
            removed = removed or r;
        } else {
            _ = doRemoveFile(w, idx, name) catch |err| {
                if (err == index_fmt.Error.EntryNotFound) continue;
                return err;
            };
            // go-git does not set removed=true for single files inside the loop
            // unless a subdirectory reported removed; file removals still mutate
            // the index. Treat any successful file remove as progress.
            removed = true;
        }
    }

    try removeEmptyDirectory(w, directory);
    return removed;
}

fn removeEmptyDirectory(w: *Worktree, path: []const u8) !void {
    const entries = w.filesystem.readDir(path) catch |err| {
        if (err == error.NotExist) return;
        return err;
    };
    defer w.filesystem.freeReadDir(entries);
    if (entries.len != 0) return;
    w.filesystem.remove(path) catch |err| {
        if (err == error.NotExist) return;
        return err;
    };
}

fn doRemoveFile(w: *Worktree, idx: *Index, path: []const u8) !Hash {
    const hash = try deleteFromIndex(idx, path);
    try deleteFromFilesystem(w, path);
    return hash;
}

fn deleteFromIndex(idx: *Index, path: []const u8) !Hash {
    var e = try idx.remove(path);
    const h = e.hash;
    e.deinit(idx.allocator);
    return h;
}

fn deleteFromFilesystem(w: *Worktree, path: []const u8) !void {
    w.filesystem.remove(path) catch |err| {
        if (err == error.NotExist) return;
        return err;
    };
}

// ---------------------------------------------------------------------------
// Move / RemoveGlob / AddGlob
// ---------------------------------------------------------------------------

/// go-git `Worktree.Move` — rename a file in the worktree and the index.
/// Directories are not supported.
pub fn move(w: *Worktree, from: []const u8, to: []const u8) !Hash {
    try pathutil.validTreePath(from);
    try pathutil.validTreePath(to);
    _ = try w.filesystem.lstat(from);

    // Destination must not already exist (go-git ErrDestinationExists).
    if (w.filesystem.lstat(to)) |_| {
        return error_mod.Error.DestinationExists;
    } else |err| {
        if (err != error.NotExist) return err;
    }

    const idx = try w.storer.index();
    // Order matches go-git: drop index entry, rename FS, re-add under `to`.
    const hash = try deleteFromIndex(idx, from);
    try w.filesystem.rename(from, to);
    try addOrUpdateFileToIndex(w, idx, to, hash);
    w.storer.setIndex(idx);
    return hash;
}

/// go-git `Worktree.RemoveGlob` — remove every index entry matching `pattern`
/// from the index and worktree. Empty match list is not an error.
pub fn removeGlob(w: *Worktree, pattern: []const u8) !void {
    const idx = try w.storer.index();
    const entries = try idx.glob(pattern);
    defer w.allocator.free(entries);

    // Collect names first: doRemoveFile mutates `idx.entries` (orderedRemove),
    // which would invalidate pointers returned by Glob.
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| w.allocator.free(n);
        names.deinit(w.allocator);
    }
    for (entries) |e| {
        try names.append(w.allocator, try w.allocator.dupe(u8, e.name));
    }

    for (names.items) |file| {
        try pathutil.validTreePath(file);
        // go-git: Lstat only to surface unexpected FS errors; NotExist is fine.
        _ = w.filesystem.lstat(file) catch |err| {
            if (err != error.NotExist) return err;
        };

        _ = try doRemoveFile(w, idx, file);

        // Immediate parent only (go-git filepath.Split + removeEmptyDirectory).
        if (std.mem.lastIndexOfScalar(u8, file, '/')) |slash| {
            if (slash > 0) {
                try removeEmptyDirectory(w, file[0..slash]);
            }
        }
    }

    w.storer.setIndex(idx);
}

/// go-git `Worktree.AddGlob` — stage all paths matching `pattern`.
/// If the pattern matches a directory, its contents are staged recursively.
/// Returns `GlobNoMatches` when nothing matches.
pub fn addGlob(w: *Worktree, pattern: []const u8) !void {
    var matches: std.ArrayList([]const u8) = .empty;
    defer {
        for (matches.items) |p| w.allocator.free(p);
        matches.deinit(w.allocator);
    }
    try collectGlobMatches(w, ".", pattern, &matches);
    if (matches.items.len == 0) return error_mod.Error.GlobNoMatches;

    var status_val = try loadStatus(w);
    defer status_val.deinit();
    const status_ptr: ?*Status = &status_val;

    const idx = try w.storer.index();
    var save_index = false;

    for (matches.items) |file| {
        const fi = try w.filesystem.lstat(file);
        var added = false;
        if (fi.isDir()) {
            added = try doAddDirectory(w, idx, status_ptr, file, &.{});
        } else {
            const r = try doAddFile(w, idx, status_ptr, file, &.{});
            added = r.added;
        }
        if (added) save_index = true;
    }

    if (save_index) w.storer.setIndex(idx);
}

fn collectGlobMatches(
    w: *Worktree,
    dir: []const u8,
    pattern: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    // Match the directory itself (when pattern matches a dir path).
    if (try index_fmt.match(pattern, dir)) {
        if (!std.mem.eql(u8, dir, ".")) {
            try out.append(w.allocator, try w.allocator.dupe(u8, dir));
        }
    }

    const entries = w.filesystem.readDir(dir) catch |err| {
        if (err == error.NotExist or err == error.NotDir) return;
        return err;
    };
    defer w.filesystem.freeReadDir(entries);

    for (entries) |e| {
        // Skip VCS metadata.
        if (std.mem.eql(u8, e.name, ".git")) continue;
        const child = try joinRel(w.allocator, dir, e.name);
        defer w.allocator.free(child);

        if (e.isDir()) {
            if (try index_fmt.match(pattern, child)) {
                try out.append(w.allocator, try w.allocator.dupe(u8, child));
            }
            try collectGlobMatches(w, child, pattern, out);
        } else {
            if (try index_fmt.match(pattern, child)) {
                try out.append(w.allocator, try w.allocator.dupe(u8, child));
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Path / ignore utilities
// ---------------------------------------------------------------------------

const cleanToSlash = util.cleanToSlash;
const joinRel = util.joinRel;
const matchIgnore = util.matchIgnore;

fn collectFiles(w: *Worktree, dir: []const u8, out: *std.ArrayList([]const u8)) !void {
    const entries = w.filesystem.readDir(dir) catch |err| {
        if (err == error.NotExist or err == error.NotDir) return;
        return err;
    };
    defer w.filesystem.freeReadDir(entries);

    for (entries) |e| {
        if (std.mem.eql(u8, e.name, ".git")) continue;
        const child = try joinRel(w.allocator, dir, e.name);
        errdefer w.allocator.free(child);
        if (e.isDir()) {
            try collectFiles(w, child, out);
            w.allocator.free(child);
        } else {
            try out.append(w.allocator, child);
        }
    }
}

/// Load worktree Status for Add skip-unmodified (go-git always Status unless SkipStatus).
fn loadStatus(w: *Worktree) !Status {
    return try status_mod.status(w, .{});
}

// ---------------------------------------------------------------------------
// Unit tests (Mem + memory.Storage)
// ---------------------------------------------------------------------------

fn writeFile(mem: *fs_pkg.Mem, path: []const u8, data: []const u8) !void {
    var f = try mem.create(path);
    defer f.close() catch {};
    _ = try f.write(data);
}

fn writeFileMode(mem: *fs_pkg.Mem, path: []const u8, data: []const u8, perm: u32) !void {
    var f = try mem.openFile(path, fs_pkg.O.RDWR | fs_pkg.O.CREATE | fs_pkg.O.TRUNC, perm);
    defer f.close() catch {};
    _ = try f.write(data);
}

test "add file stages blob and index entry" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var wt = worktree_mod.newWorktree(gpa, sto, &mem);

    try writeFile(&mem, "foo.txt", "FOO");

    // skip_status skips Status load (go-git SkipStatus for single regular files).
    try addWithOptions(&wt, .{ .path = "foo.txt", .skip_status = true });

    const idx = try sto.index();
    try std.testing.expectEqual(@as(usize, 1), idx.entries.items.len);
    const e = try idx.entry("foo.txt");
    try std.testing.expect(!e.hash.isZero());
    try std.testing.expectEqual(@as(u32, 3), e.size);
    try std.testing.expectEqual(filemode.Regular, e.mode);

    // Blob is in object storage.
    const obj = try sto.encodedObject(.blob, e.hash);
    try std.testing.expectEqualStrings("FOO", obj.readerBytes());
}

test "add returns blob hash for file" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var wt = worktree_mod.newWorktree(gpa, sto, &mem);

    try writeFile(&mem, "foo", "FOO");
    // Direct helper path with skip via addWithOptions then check hash via index.
    try addWithOptions(&wt, .{ .path = "foo", .skip_status = true });
    const idx = try sto.index();
    const e = try idx.entry("foo");

    // Known SHA-1 of blob "FOO".
    // git hash-object -t blob --stdin <<< 'FOO' without newline: d96c7efb…
    // content is exactly 3 bytes F O O
    var hex_buf: [plumbing.MaxHexSize]u8 = undefined;
    const hex = e.hash.string(&hex_buf);
    try std.testing.expectEqualStrings("d96c7efbfec2814ae0301ad054dc8d9fc416c9b5", hex);
}

test "add directory recursively stages children; returns ZeroHash" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var wt = worktree_mod.newWorktree(gpa, sto, &mem);

    try mem.mkdirAll("qux/baz", 0o755);
    try writeFileMode(&mem, "qux/foo", "FOO", 0o755);
    try writeFileMode(&mem, "qux/baz/bar", "BAR", 0o755);

    // Directory add loads Status; Status + FS walk stage untracked children.
    const h = try add(&wt, "qux");
    try std.testing.expect(h.isZero());

    const idx = try sto.index();
    try std.testing.expectEqual(@as(usize, 2), idx.entries.items.len);
    _ = try idx.entry("qux/foo");
    _ = try idx.entry("qux/baz/bar");

    // Executable mode when perm has user-exec bit.
    try std.testing.expectEqual(filemode.Executable, (try idx.entry("qux/foo")).mode);
}

test "add all stages worktree files and respects excludes" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var wt = worktree_mod.newWorktree(gpa, sto, &mem);

    try writeFile(&mem, "file1", "file1");
    try writeFile(&mem, "file2", "file2");
    try writeFile(&mem, "file3", "ignore me");

    var pat = try gitignore.parsePattern(gpa, "file3", &.{});
    defer pat.deinit();
    const excludes = [_]gitignore.Pattern{pat};
    wt.excludes = &excludes;

    try addWithOptions(&wt, .{ .all = true });

    const idx = try sto.index();
    try std.testing.expectEqual(@as(usize, 2), idx.entries.items.len);
    _ = try idx.entry("file1");
    _ = try idx.entry("file2");
    try std.testing.expectError(index_fmt.Error.EntryNotFound, idx.entry("file3"));
}

test "add missing indexed file stages deletion" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var wt = worktree_mod.newWorktree(gpa, sto, &mem);

    try writeFile(&mem, "gone.txt", "x");
    try addWithOptions(&wt, .{ .path = "gone.txt", .skip_status = true });
    try mem.remove("gone.txt");

    try addWithOptions(&wt, .{ .path = "gone.txt", .skip_status = true });

    const idx = try sto.index();
    try std.testing.expectEqual(@as(usize, 0), idx.entries.items.len);
}

test "add symlink stores target as blob" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var wt = worktree_mod.newWorktree(gpa, sto, &mem);

    try writeFile(&mem, "foo", "qux");
    try mem.symlink("foo", "bar");

    try addWithOptions(&wt, .{ .path = "bar", .skip_status = true });
    const idx = try sto.index();
    const e = try idx.entry("bar");
    try std.testing.expectEqual(filemode.Symlink, e.mode);
    try std.testing.expectEqual(@as(u32, 3), e.size); // len("foo")
    const obj = try sto.encodedObject(.blob, e.hash);
    try std.testing.expectEqualStrings("foo", obj.readerBytes());
}

test "remove file from index and filesystem" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var wt = worktree_mod.newWorktree(gpa, sto, &mem);

    try writeFile(&mem, "LICENSE", "license text");
    try addWithOptions(&wt, .{ .path = "LICENSE", .skip_status = true });
    const idx_before = try sto.index();
    const expected_hash = (try idx_before.entry("LICENSE")).hash;

    const h = try remove(&wt, "LICENSE");
    try std.testing.expect(h.eql(expected_hash));

    const idx = try sto.index();
    try std.testing.expectEqual(@as(usize, 0), idx.entries.items.len);
    try std.testing.expectError(error.NotExist, mem.stat("LICENSE"));
}

test "remove directory removes nested index entries and empty dirs" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var wt = worktree_mod.newWorktree(gpa, sto, &mem);

    try mem.mkdirAll("json", 0o755);
    try writeFile(&mem, "json/long.json", "[]");
    try writeFile(&mem, "json/short.json", "{}");
    try addWithOptions(&wt, .{ .path = "json/long.json", .skip_status = true });
    try addWithOptions(&wt, .{ .path = "json/short.json", .skip_status = true });

    const h = try remove(&wt, "json");
    try std.testing.expect(h.isZero());

    const idx = try sto.index();
    try std.testing.expectEqual(@as(usize, 0), idx.entries.items.len);
    try std.testing.expectError(error.NotExist, mem.stat("json"));
}

test "remove missing index entry errors" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var wt = worktree_mod.newWorktree(gpa, sto, &mem);

    try std.testing.expectError(index_fmt.Error.EntryNotFound, remove(&wt, "not-exists"));
}

test "addWithOptions path and glob exclusive" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var wt = worktree_mod.newWorktree(gpa, sto, &mem);

    try std.testing.expectError(
        error_mod.Error.AddPathGlobExclusive,
        addWithOptions(&wt, .{ .path = "a", .glob = "*" }),
    );
}

test "addOrUpdateFileToIndex updates existing entry" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var wt = worktree_mod.newWorktree(gpa, sto, &mem);

    try writeFile(&mem, "x", "v1");
    try addWithOptions(&wt, .{ .path = "x", .skip_status = true });
    const h1 = (try (try sto.index()).entry("x")).hash;

    // Overwrite worktree content and re-add.
    try writeFile(&mem, "x", "v2-longer");
    try addWithOptions(&wt, .{ .path = "x", .skip_status = true });
    const e = try (try sto.index()).entry("x");
    try std.testing.expect(!e.hash.eql(h1));
    try std.testing.expectEqual(@as(u32, 9), e.size);
    try std.testing.expectEqual(@as(usize, 1), (try sto.index()).entries.items.len);
}

test "copyFileToStorage returns stable blob hash" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var wt = worktree_mod.newWorktree(gpa, sto, &mem);

    try writeFile(&mem, "b", "FOO");
    const h = try copyFileToStorage(&wt, "b");
    var hex_buf: [plumbing.MaxHexSize]u8 = undefined;
    try std.testing.expectEqualStrings(
        "d96c7efbfec2814ae0301ad054dc8d9fc416c9b5",
        h.string(&hex_buf),
    );
}

test "move renames file in filesystem and index" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var wt = worktree_mod.newWorktree(gpa, sto, &mem);

    try writeFile(&mem, "LICENSE", "license text");
    try addWithOptions(&wt, .{ .path = "LICENSE", .skip_status = true });
    const expected = (try (try sto.index()).entry("LICENSE")).hash;

    const h = try move(&wt, "LICENSE", "foo");
    try std.testing.expect(h.eql(expected));

    // FS: old gone, new present with same content.
    try std.testing.expectError(error.NotExist, mem.stat("LICENSE"));
    _ = try mem.stat("foo");
    var f = try mem.open("foo");
    defer f.close() catch {};
    var buf: [64]u8 = undefined;
    const n = try f.read(&buf);
    try std.testing.expectEqualStrings("license text", buf[0..n]);

    // Index: only `foo` remains, same blob hash.
    const idx = try sto.index();
    try std.testing.expectEqual(@as(usize, 1), idx.entries.items.len);
    try std.testing.expectError(index_fmt.Error.EntryNotFound, idx.entry("LICENSE"));
    const e = try idx.entry("foo");
    try std.testing.expect(e.hash.eql(expected));
}

test "move to existing path returns DestinationExists" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var wt = worktree_mod.newWorktree(gpa, sto, &mem);

    try writeFile(&mem, ".gitignore", "a");
    try writeFile(&mem, "LICENSE", "b");
    try addWithOptions(&wt, .{ .path = ".gitignore", .skip_status = true });
    try addWithOptions(&wt, .{ .path = "LICENSE", .skip_status = true });

    try std.testing.expectError(
        error_mod.Error.DestinationExists,
        move(&wt, ".gitignore", "LICENSE"),
    );

    // Index and FS unchanged on destination conflict.
    const idx = try sto.index();
    try std.testing.expectEqual(@as(usize, 2), idx.entries.items.len);
    _ = try idx.entry(".gitignore");
    _ = try idx.entry("LICENSE");
    _ = try mem.stat(".gitignore");
    _ = try mem.stat("LICENSE");
}

test "removeGlob removes matching files from index and filesystem" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var wt = worktree_mod.newWorktree(gpa, sto, &mem);

    try mem.mkdirAll("json", 0o755);
    try writeFile(&mem, "json/long.json", "[]");
    try writeFile(&mem, "json/short.json", "{}");
    try writeFile(&mem, "README", "hi");
    try addWithOptions(&wt, .{ .path = "json/long.json", .skip_status = true });
    try addWithOptions(&wt, .{ .path = "json/short.json", .skip_status = true });
    try addWithOptions(&wt, .{ .path = "README", .skip_status = true });

    try removeGlob(&wt, "json/l*");

    const idx = try sto.index();
    try std.testing.expectEqual(@as(usize, 2), idx.entries.items.len);
    try std.testing.expectError(index_fmt.Error.EntryNotFound, idx.entry("json/long.json"));
    _ = try idx.entry("json/short.json");
    _ = try idx.entry("README");
    try std.testing.expectError(error.NotExist, mem.stat("json/long.json"));
    _ = try mem.stat("json/short.json");
}

test "removeGlob directory pattern removes children and empty dir" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var wt = worktree_mod.newWorktree(gpa, sto, &mem);

    try mem.mkdirAll("json", 0o755);
    try writeFile(&mem, "json/long.json", "[]");
    try writeFile(&mem, "json/short.json", "{}");
    try addWithOptions(&wt, .{ .path = "json/long.json", .skip_status = true });
    try addWithOptions(&wt, .{ .path = "json/short.json", .skip_status = true });

    // `js*` matches json/* paths (go-git full-path match spans separators).
    try removeGlob(&wt, "js*");

    const idx = try sto.index();
    try std.testing.expectEqual(@as(usize, 0), idx.entries.items.len);
    try std.testing.expectError(error.NotExist, mem.stat("json"));
}

test "addGlob stages matching paths" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var wt = worktree_mod.newWorktree(gpa, sto, &mem);

    try mem.mkdirAll("qux/bar", 0o755);
    try writeFile(&mem, "qux/qux", "QUX");
    try writeFile(&mem, "qux/baz", "BAZ");
    try writeFile(&mem, "qux/bar/baz", "BAZ");

    try addGlob(&wt, "qux/b*");

    const idx = try sto.index();
    try std.testing.expectEqual(@as(usize, 2), idx.entries.items.len);
    _ = try idx.entry("qux/baz");
    _ = try idx.entry("qux/bar/baz");
    try std.testing.expectError(index_fmt.Error.EntryNotFound, idx.entry("qux/qux"));
}

test "addGlob empty match returns GlobNoMatches" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var wt = worktree_mod.newWorktree(gpa, sto, &mem);

    try std.testing.expectError(error_mod.Error.GlobNoMatches, addGlob(&wt, "foo"));
}
