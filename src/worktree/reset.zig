//! Worktree Reset (go-git `Worktree.Reset` / `ResetSparsely`).
//!
//! Soft: move HEAD only (branch tip or detached).
//! Mixed: HEAD + reset index to commit tree (default).
//! Hard: HEAD + index + worktree files to commit tree.
//! Merge: abort on unstaged changes; else like mixed + update worktree for
//!        paths that changed between the old index and the commit tree.

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const objpkg = @import("object");
const index_fmt = @import("index");
const memory = @import("memory");
const fs_pkg = @import("fs");
const storer = @import("storer");
const merkletrie = @import("merkletrie");
const mindex = @import("merkletrie_index");
const mfs = @import("merkletrie_filesystem");
const noder = @import("noder");
const pathutil = @import("pathutil");

const worktree_mod = @import("worktree.zig");
const options_mod = @import("options.zig");
const error_mod = @import("error.zig");
const platform_mod = @import("platform.zig");

const Allocator = std.mem.Allocator;
const Worktree = worktree_mod.Worktree;
const ResetOptions = options_mod.ResetOptions;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const Reference = plumbing.Reference;
const Tree = objpkg.Tree;
const Index = index_fmt.Index;
const Entry = index_fmt.Entry;

/// go-git `(*Worktree).Reset`.
pub fn reset(w: *Worktree, o: ResetOptions) !void {
    return resetSparsely(w, o, &.{});
}

/// go-git `(*Worktree).Restore`.
///
/// - Staged only → mixed reset of `files` (index from HEAD).
/// - Staged + Worktree → hard reset of `files`.
/// - Worktree only / neither → `RestoreWorktreeOnlyNotSupported`.
/// - Empty files → `NoRestorePaths`.
pub fn restore(w: *Worktree, o: options_mod.RestoreOptions) !void {
    try o.validate();
    if (o.staged) {
        const mode: options_mod.ResetMode = if (o.worktree) .hard else .mixed;
        return reset(w, .{
            .files = o.files,
            .mode = mode,
        });
    }
    return error_mod.Error.RestoreWorktreeOnlyNotSupported;
}

/// go-git `(*Worktree).ResetSparsely` (`dirs` = sparse checkout prefixes; empty = full).
pub fn resetSparsely(w: *Worktree, o: ResetOptions, dirs: []const []const u8) !void {
    var opts = o;
    try validate(w, &opts);

    if (opts.mode == .merge) {
        if (try containsUnstagedChanges(w)) return error_mod.Error.UnstagedChanges;
    }

    try setHEADCommit(w, opts.commit);

    if (opts.mode == .soft) return;

    const tree = try getTreeFromCommitHash(w, opts.commit);
    defer objpkg.freeTree(w.allocator, tree);

    var removed_files: []const []const u8 = &.{};
    defer freePathList(w.allocator, removed_files);

    if (opts.mode == .mixed or opts.mode == .merge or opts.mode == .hard) {
        removed_files = try resetIndex(w, tree, dirs, opts.files);
    }

    if (opts.mode == .merge and removed_files.len > 0) {
        try resetWorktree(w, tree, removed_files);
    }

    if (opts.mode == .hard) {
        // Sparse hard: preserve skipUnless from resetIndex; full checkoutTree
        // rebuilds the entire index and would wipe sparse flags.
        if (dirs.len > 0) {
            try resetWorktree(w, tree, opts.files);
            return;
        }
        // Full materialization: rebuild index + worktree from commit tree
        // (more reliable than change-walk alone for Mem FS).
        const checkout_mod = @import("checkout.zig");
        try checkout_mod.checkoutTree(w, tree.id());
    }
}

// ---------------------------------------------------------------------------
// Validate / HEAD
// ---------------------------------------------------------------------------

/// go-git `(*ResetOptions).Validate`.
fn validate(w: *Worktree, o: *ResetOptions) !void {
    if (o.commit.isZero()) {
        const resolved = try storer.resolveReference(w.storer, plumbing.HEAD);
        o.commit = resolved.hash;
    } else {
        const c = objpkg.getCommit(w.allocator, w.storer, o.commit) catch |err| {
            if (err == error.ObjectNotFound or err == error.UnsupportedObject)
                return error.ObjectNotFound;
            return err;
        };
        c.deinit();
        w.allocator.destroy(c);
    }
}

/// go-git `(*Worktree).setHEADCommit`.
fn setHEADCommit(w: *Worktree, commit: Hash) !void {
    const head = try w.storer.reference(plumbing.HEAD);
    if (head.type == .hash) {
        try w.storer.setReference(Reference.newHashReference(plumbing.HEAD, commit));
        return;
    }

    const branch = try w.storer.reference(head.target);
    if (!branch.name.isBranch()) return error.InvalidReferenceName;

    try w.storer.setReference(Reference.newHashReference(branch.name, commit));
}

fn getTreeFromCommitHash(w: *Worktree, commit: Hash) !*Tree {
    const c = try objpkg.getCommit(w.allocator, w.storer, commit);
    defer {
        c.deinit();
        w.allocator.destroy(c);
    }
    return try c.tree();
}

// ---------------------------------------------------------------------------
// Index reset (tree ↔ staging)
// ---------------------------------------------------------------------------

/// go-git `(*Worktree).resetIndex`. Returns paths touched (caller frees each string + slice).
fn resetIndex(
    w: *Worktree,
    t: *Tree,
    dirs: []const []const u8,
    files: []const []const u8,
) ![]const []const u8 {
    const gpa = w.allocator;
    const idx = try w.storer.index();

    // Keep tree/index noders alive for the whole walk — Path.string reads
    // through noder pointers that die with the session / index root.
    var session = objpkg.TreeNoderSession.init(gpa);
    defer session.deinit();
    const tree_node = try objpkg.newTreeRootNode(&session, t);
    var idx_root = try mindex.newRootNode(gpa, idx);
    defer idx_root.deinit();

    var changes = try merkletrie.diffTree(gpa, idx_root.noder(), tree_node.asNoder(), diffTreeIsEquals);
    defer changes.deinit();

    var removed: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (removed.items) |p| gpa.free(p);
        removed.deinit(gpa);
    }

    const files_map = try buildFilePathMap(gpa, files);
    defer freeFilePathMap(gpa, files_map);

    for (changes.items.items) |*ch| {
        const act = try ch.action();
        var name_owned: []const u8 = undefined;
        var tree_ent: ?*const objpkg.TreeEntry = null;

        switch (act) {
            .modify, .insert => {
                const path_s = try ch.to.?.string(gpa);
                defer gpa.free(path_s);
                tree_ent = try t.findEntry(path_s);
                name_owned = try gpa.dupe(u8, path_s);
            },
            .delete => {
                const path_s = try ch.from.?.string(gpa);
                defer gpa.free(path_s);
                name_owned = try gpa.dupe(u8, path_s);
            },
        }

        pathutil.validTreePath(name_owned) catch |err| {
            gpa.free(name_owned);
            return err;
        };

        if (files_map) |*fm| {
            if (!inFiles(fm, name_owned)) {
                gpa.free(name_owned);
                continue;
            }
        }

        // Drop existing index entry (if any).
        if (idx.remove(name_owned)) |old| {
            var e = old;
            e.deinit(gpa);
        } else |_| {}

        // Ownership of name_owned transfers to `removed`.
        removed.append(gpa, name_owned) catch |err| {
            gpa.free(name_owned);
            return err;
        };

        if (tree_ent) |e| {
            const ent = try idx.add(name_owned);
            ent.hash = e.hash;
            ent.mode = e.mode;
        }
    }

    if (dirs.len > 0) {
        idx.skipUnless(dirs);
    }

    w.storer.setIndex(idx);
    return try removed.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Worktree reset (staging ↔ worktree)
// ---------------------------------------------------------------------------

/// go-git `(*Worktree).resetWorktree`.
fn resetWorktree(w: *Worktree, t: *Tree, files: []const []const u8) !void {
    const gpa = w.allocator;
    const idx = try w.storer.index();

    // Paths read through noders — keep roots alive for the whole loop.
    var from_root = try mindex.newRootNode(gpa, idx);
    defer from_root.deinit();
    const to_root = try mfs.newRootNodeMemWithOptions(gpa, w.filesystem, null, .{ .index = idx });
    defer to_root.deinit();

    var changes = try merkletrie.diffTree(gpa, to_root.noder(), from_root.noder(), diffTreeIsEquals);
    defer changes.deinit();

    const files_map = try buildFilePathMap(gpa, files);
    defer freeFilePathMap(gpa, files_map);

    for (changes.items.items) |*ch| {
        if (files_map) |*fm| {
            var file_path: []const u8 = "";
            var owned: ?[]u8 = null;
            defer if (owned) |p| gpa.free(p);

            if (ch.from) |from| {
                owned = try from.string(gpa);
                file_path = owned.?;
            } else if (ch.to) |to| {
                owned = try to.string(gpa);
                file_path = owned.?;
            }
            if (file_path.len == 0) continue;
            if (!inFiles(fm, file_path)) continue;
        }

        try checkoutChange(w, ch, t, idx);
    }

    w.storer.setIndex(idx);
}

/// go-git `(*Worktree).checkoutChange` (regular files + delete; submodule → index only).
fn checkoutChange(
    w: *Worktree,
    ch: *const merkletrie.Change,
    t: *Tree,
    idx: *Index,
) !void {
    const act = try ch.action();
    const gpa = w.allocator;

    switch (act) {
        .delete => {
            const path_s = try ch.from.?.string(gpa);
            defer gpa.free(path_s);
            try rmFileAndDirsIfEmpty(w.filesystem, path_s);
            // Index already matches tree after resetIndex; no index remove needed for hard.
            // Still remove stale entry if present (defensive).
            if (idx.remove(path_s)) |old| {
                var e = old;
                e.deinit(gpa);
            } else |_| {}
            return;
        },
        .modify, .insert => {
            const path_s = try ch.to.?.string(gpa);
            defer gpa.free(path_s);

            const e = try t.findEntry(path_s);
            if (e.mode == filemode.Submodule) {
                // Index-only materialisation of submodule gitlink (no nested checkout).
                if (idx.remove(path_s)) |old| {
                    var old_e = old;
                    old_e.deinit(gpa);
                } else |_| {}
                const ent = try idx.add(path_s);
                ent.hash = e.hash;
                ent.mode = filemode.Submodule;
                return;
            }

            try checkoutChangeRegularFile(w, path_s, act, t, e, idx);
        },
    }
}

/// go-git `(*Worktree).checkoutChangeRegularFile`.
fn checkoutChangeRegularFile(
    w: *Worktree,
    name: []const u8,
    act: merkletrie.Action,
    t: *Tree,
    e: *const objpkg.TreeEntry,
    idx: *Index,
) !void {
    const gpa = w.allocator;
    try pathutil.validTreePath(name);

    if (act == .modify) {
        if (idx.remove(name)) |old| {
            var old_e = old;
            old_e.deinit(gpa);
        } else |_| {}
        w.filesystem.remove(name) catch |err| {
            if (err != error.NotExist) return err;
        };
    }

    const f = try t.file(name);
    try checkoutFile(w, &f);
    try addIndexFromFile(w, name, e.hash, f.mode, idx);
}

/// go-git `(*Worktree).checkoutFile` (regular + symlink via Mem FS).
fn checkoutFile(w: *Worktree, f: *const objpkg.File) !void {
    try clearBlockingSymlinks(w.filesystem, f.name);

    const content = f.blob.readerBytes();
    if (f.mode == filemode.Symlink) {
        try ensureParentDirs(w.filesystem, f.name);
        w.filesystem.symlink(content, f.name) catch {
            // Fall back to plain file (go-git Windows non-admin path).
            try writeRegularFile(w.filesystem, f.name, content, f.mode);
        };
        return;
    }
    try writeRegularFile(w.filesystem, f.name, content, f.mode);
}

fn writeRegularFile(filesystem: *fs_pkg.Mem, path: []const u8, content: []const u8, mode: filemode.FileMode) !void {
    try ensureParentDirs(filesystem, path);
    const perm: u32 = if (mode == filemode.Executable) 0o755 else 0o644;
    var file = try filesystem.openFile(path, fs_pkg.O.WRONLY | fs_pkg.O.CREATE | fs_pkg.O.TRUNC, perm);
    defer file.close() catch {};
    _ = try file.write(content);
}

fn ensureParentDirs(filesystem: *fs_pkg.Mem, path: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        if (i > 0) try filesystem.mkdirAll(path[0..i], 0o755);
    }
}

/// go-git `clearBlockingSymlinks` subset: remove a final-component symlink if present.
fn clearBlockingSymlinks(filesystem: *fs_pkg.Mem, name: []const u8) !void {
    // Leading components that are symlinks.
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(filesystem.allocator);
    var dir = name;
    while (std.mem.lastIndexOfScalar(u8, dir, '/')) |i| {
        dir = dir[0..i];
        if (dir.len == 0) break;
        try dirs.append(filesystem.allocator, dir);
    }
    var i = dirs.items.len;
    while (i > 0) {
        i -= 1;
        const d = dirs.items[i];
        const info = filesystem.lstat(d) catch |err| {
            if (err == error.NotExist) continue;
            return err;
        };
        if (info.isSymlink()) {
            try filesystem.remove(d);
            return;
        }
    }
    const info = filesystem.lstat(name) catch |err| {
        if (err == error.NotExist) return;
        return err;
    };
    if (info.isSymlink()) try filesystem.remove(name);
}

fn addIndexFromFile(
    w: *Worktree,
    name: []const u8,
    h: Hash,
    mode: filemode.FileMode,
    idx: *Index,
) !void {
    const gpa = w.allocator;
    if (idx.remove(name)) |old| {
        var e = old;
        e.deinit(gpa);
    } else |_| {}

    const ent = try idx.add(name);
    ent.hash = h;
    ent.mode = mode;
    fillEntryFromFs(ent, w.filesystem, name);
}

/// Fill size / mtime from Mem FS, then platform fillSystemInfo (go-git Sys fields).
fn fillEntryFromFs(e: *Entry, filesystem: *fs_pkg.Mem, path: []const u8) void {
    const info = filesystem.lstat(path) catch return;
    e.size = @intCast(@min(info.size, std.math.maxInt(u32)));
    e.modified_at = index_fmt.Time.unix(info.mtime_sec, 0);
    platform_mod.fillSystemInfo(e, filesystem, path);
}

/// go-git `rmFileAndDirsIfEmpty`.
fn rmFileAndDirsIfEmpty(filesystem: *fs_pkg.Mem, path: []const u8) !void {
    try pathutil.validTreePath(path);
    filesystem.remove(path) catch |err| {
        if (err == error.NotExist) return;
        return err;
    };
    var dir = path;
    while (std.mem.lastIndexOfScalar(u8, dir, '/')) |i| {
        dir = dir[0..i];
        if (dir.len == 0) break;
        filesystem.remove(dir) catch break;
    }
}

// ---------------------------------------------------------------------------
// Unstaged check
// ---------------------------------------------------------------------------

/// go-git `(*Worktree).containsUnstagedChanges`.
fn containsUnstagedChanges(w: *Worktree) !bool {
    const gpa = w.allocator;
    const idx = try w.storer.index();

    var from_root = try mindex.newRootNode(gpa, idx);
    defer from_root.deinit();
    const to_root = try mfs.newRootNodeMemWithOptions(gpa, w.filesystem, null, .{ .index = idx });
    defer to_root.deinit();

    // Action() only inspects from/to presence; still keep roots alive for safety.
    var changes = try merkletrie.diffTree(gpa, from_root.noder(), to_root.noder(), diffTreeIsEquals);
    defer changes.deinit();

    for (changes.items.items) |*c| {
        const a = try c.action();
        if (a == .insert) continue; // untracked only
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Diffs (tree ↔ index ↔ worktree)
// ---------------------------------------------------------------------------

/// go-git `diffTreeIsEquals`.
fn diffTreeIsEquals(a: noder.Noder, b: noder.Noder) bool {
    const ha = a.hash();
    const hb = b.hash();
    if (isEmptyCompositeHash(ha) or isEmptyCompositeHash(hb)) return false;
    return std.mem.eql(u8, ha, hb);
}

fn isEmptyCompositeHash(h: []const u8) bool {
    for (h) |b| {
        if (b != 0) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// File path filter helpers
// ---------------------------------------------------------------------------

fn buildFilePathMap(allocator: Allocator, files: []const []const u8) !?std.StringHashMapUnmanaged(void) {
    if (files.len == 0) return null;
    var map: std.StringHashMapUnmanaged(void) = .empty;
    errdefer freeFilePathMap(allocator, map);
    for (files) |f| {
        const cleaned = try cleanPathOwned(allocator, f);
        errdefer allocator.free(cleaned);
        try map.put(allocator, cleaned, {});
    }
    return map;
}

fn freeFilePathMap(allocator: Allocator, map: ?std.StringHashMapUnmanaged(void)) void {
    var m = map orelse return;
    var it = m.keyIterator();
    while (it.next()) |k| allocator.free(k.*);
    m.deinit(allocator);
}

fn inFiles(map: *const std.StringHashMapUnmanaged(void), v: []const u8) bool {
    // Paths are already slash-form; clean `.`/`..` lightly.
    var buf: [512]u8 = undefined;
    const cleaned = cleanPathBuf(&buf, v) orelse v;
    return map.contains(cleaned);
}

fn cleanPathOwned(allocator: Allocator, p: []const u8) ![]u8 {
    var buf: [1024]u8 = undefined;
    const c = cleanPathBuf(&buf, p) orelse p;
    return try allocator.dupe(u8, c);
}

fn cleanPathBuf(buf: []u8, p: []const u8) ?[]const u8 {
    if (p.len == 0 or p.len > buf.len) return null;
    // Minimal clean: strip leading `./` and collapse duplicate `/`.
    var out_len: usize = 0;
    var i: usize = 0;
    if (std.mem.startsWith(u8, p, "./")) i = 2;
    while (i < p.len) {
        if (p[i] == '/') {
            if (out_len == 0 or buf[out_len - 1] != '/') {
                buf[out_len] = '/';
                out_len += 1;
            }
            i += 1;
            continue;
        }
        buf[out_len] = p[i];
        out_len += 1;
        i += 1;
    }
    if (out_len > 1 and buf[out_len - 1] == '/') out_len -= 1;
    return buf[0..out_len];
}

fn freePathList(allocator: Allocator, paths: []const []const u8) void {
    for (paths) |p| {
        if (p.len > 0) allocator.free(p);
    }
    if (paths.len > 0) allocator.free(paths);
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn storeBlob(sto: *memory.Storage, content: []const u8) !Hash {
    const obj = try sto.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write(content);
    return try sto.setEncodedObject(obj);
}

fn storeTreeOne(gpa: Allocator, sto: *memory.Storage, name: []const u8, mode: filemode.FileMode, blob: Hash) !Hash {
    var t = Tree.init(gpa, storer.ObjectGetter.from(memory.Storage, sto));
    defer t.deinit();
    try t.appendEntry(name, mode, blob);
    t.sortEntries();
    const obj = try sto.newEncodedObject();
    try t.encode(obj);
    return try sto.setEncodedObject(obj);
}

fn storeCommit(gpa: Allocator, sto: *memory.Storage, tree_h: Hash, parent: ?Hash, msg: []const u8) !Hash {
    var c = objpkg.Commit.init(gpa);
    defer c.deinit();
    c.tree_hash = tree_h;
    c.author = .{ .name = "a", .email = "a@b", .when = 1, .tz_offset_minutes = 0 };
    c.committer = c.author;
    c.message = try gpa.dupe(u8, msg);
    if (parent) |p| {
        const parents = try gpa.alloc(Hash, 1);
        parents[0] = p;
        c.parent_hashes = parents;
    }
    const obj = try sto.newEncodedObject();
    try c.encode(obj);
    return try sto.setEncodedObject(obj);
}

fn writeFs(filesystem: *fs_pkg.Mem, path: []const u8, content: []const u8) !void {
    try ensureParentDirs(filesystem, path);
    var f = try filesystem.create(path);
    defer f.close() catch {};
    _ = try f.write(content);
}

fn readFs(gpa: Allocator, filesystem: *fs_pkg.Mem, path: []const u8) ![]u8 {
    var f = try filesystem.open(path);
    defer f.close() catch {};
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var tmp: [256]u8 = undefined;
    while (true) {
        const n = try f.read(&tmp);
        if (n == 0) break;
        try buf.appendSlice(gpa, tmp[0..n]);
    }
    return try buf.toOwnedSlice(gpa);
}

fn setIndexFile(gpa: Allocator, sto: *memory.Storage, name: []const u8, h: Hash, mode: filemode.FileMode) !void {
    const idx = try sto.index();
    // Replace single-path entry.
    if (idx.remove(name)) |old| {
        var e = old;
        e.deinit(gpa);
    } else |_| {}
    const ent = try idx.add(name);
    ent.hash = h;
    ent.mode = mode;
    sto.setIndex(idx);
}

fn headHash(sto: *memory.Storage) !Hash {
    const r = try storer.resolveReference(sto, plumbing.HEAD);
    return r.hash;
}

const TestEnv = struct {
    sto: *memory.Storage,
    filesystem: *fs_pkg.Mem,
    wt: Worktree,
    commit_a: Hash,
    commit_b: Hash,
    blob_a: Hash,
    blob_b: Hash,
};

/// Build a two-commit repo. Heap Mem so `wt.filesystem` is not a dangling pointer.
fn setupTwoCommits(gpa: Allocator) !TestEnv {
    const sto = try memory.newStorage(gpa);
    errdefer {
        sto.deinit();
        gpa.destroy(sto);
    }

    const blob_a = try storeBlob(sto, "content-a");
    const blob_b = try storeBlob(sto, "content-b");
    const tree_a = try storeTreeOne(gpa, sto, "foo.txt", filemode.Regular, blob_a);
    const tree_b = try storeTreeOne(gpa, sto, "foo.txt", filemode.Regular, blob_b);
    const commit_a = try storeCommit(gpa, sto, tree_a, null, "A\n");
    const commit_b = try storeCommit(gpa, sto, tree_b, commit_a, "B\n");

    try sto.setReference(Reference.newHashReference(plumbing.master, commit_a));
    try sto.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
    try setIndexFile(gpa, sto, "foo.txt", blob_a, filemode.Regular);

    const filesystem = try gpa.create(fs_pkg.Mem);
    errdefer gpa.destroy(filesystem);
    filesystem.* = try fs_pkg.Mem.init(gpa);
    errdefer filesystem.deinit();

    try writeFs(filesystem, "foo.txt", "content-a");
    return .{
        .sto = sto,
        .filesystem = filesystem,
        .wt = worktree_mod.newWorktree(gpa, sto, filesystem),
        .commit_a = commit_a,
        .commit_b = commit_b,
        .blob_a = blob_a,
        .blob_b = blob_b,
    };
}

fn deinitTestEnv(gpa: Allocator, env: *TestEnv) void {
    env.filesystem.deinit();
    gpa.destroy(env.filesystem);
    env.sto.deinit();
    gpa.destroy(env.sto);
}

test "reset soft moves HEAD only" {
    const gpa = testing.allocator;
    var env = try setupTwoCommits(gpa);
    defer deinitTestEnv(gpa, &env);

    try reset(&env.wt, .{ .mode = .soft, .commit = env.commit_b });

    try testing.expect((try headHash(env.sto)).eql(env.commit_b));
    // Index still at A.
    const idx = try env.sto.index();
    const ent = try idx.entry("foo.txt");
    try testing.expect(ent.hash.eql(env.blob_a));
    // Worktree still at A.
    const body = try readFs(gpa, env.filesystem, "foo.txt");
    defer gpa.free(body);
    try testing.expectEqualStrings("content-a", body);
}

test "reset mixed updates index not worktree" {
    const gpa = testing.allocator;
    var env = try setupTwoCommits(gpa);
    defer deinitTestEnv(gpa, &env);

    try reset(&env.wt, .{ .mode = .mixed, .commit = env.commit_b });

    try testing.expect((try headHash(env.sto)).eql(env.commit_b));
    const idx = try env.sto.index();
    const ent = try idx.entry("foo.txt");
    try testing.expect(ent.hash.eql(env.blob_b));
    const body = try readFs(gpa, env.filesystem, "foo.txt");
    defer gpa.free(body);
    try testing.expectEqualStrings("content-a", body);
}

test "reset hard updates index and worktree" {
    const gpa = testing.allocator;
    var env = try setupTwoCommits(gpa);
    defer deinitTestEnv(gpa, &env);

    // Dirty worktree before hard reset.
    try writeFs(env.filesystem, "foo.txt", "dirty");

    try reset(&env.wt, .{ .mode = .hard, .commit = env.commit_b });

    try testing.expect((try headHash(env.sto)).eql(env.commit_b));
    const idx = try env.sto.index();
    const ent = try idx.entry("foo.txt");
    try testing.expect(ent.hash.eql(env.blob_b));
    const body = try readFs(gpa, env.filesystem, "foo.txt");
    defer gpa.free(body);
    try testing.expectEqualStrings("content-b", body);
}

test "reset merge aborts on unstaged changes" {
    const gpa = testing.allocator;
    var env = try setupTwoCommits(gpa);
    defer deinitTestEnv(gpa, &env);

    // Unstaged modification of a tracked file.
    try writeFs(env.filesystem, "foo.txt", "unstaged");

    try testing.expectError(
        error_mod.Error.UnstagedChanges,
        reset(&env.wt, .{ .mode = .merge, .commit = env.commit_b }),
    );
    // HEAD must remain at A.
    try testing.expect((try headHash(env.sto)).eql(env.commit_a));
}

test "reset ZeroHash defaults to HEAD" {
    const gpa = testing.allocator;
    var env = try setupTwoCommits(gpa);
    defer deinitTestEnv(gpa, &env);

    try writeFs(env.filesystem, "foo.txt", "dirty");
    try reset(&env.wt, .{ .mode = .hard, .commit = ZeroHash });

    try testing.expect((try headHash(env.sto)).eql(env.commit_a));
    const body = try readFs(gpa, env.filesystem, "foo.txt");
    defer gpa.free(body);
    try testing.expectEqualStrings("content-a", body);
}

test "reset rejects missing commit" {
    const gpa = testing.allocator;
    var env = try setupTwoCommits(gpa);
    defer deinitTestEnv(gpa, &env);

    const missing = plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    try testing.expectError(
        error.ObjectNotFound,
        reset(&env.wt, .{ .mode = .soft, .commit = missing }),
    );
}
