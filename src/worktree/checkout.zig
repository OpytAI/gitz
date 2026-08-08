//! Worktree Checkout (go-git `Worktree.Checkout` core).
//!
//! Flow: validate → optional create branch → resolve commit → set HEAD →
//! Reset (Force→Hard, Keep→Soft, default→Merge) or ResetSparsely when sparse
//! dirs are set. Tree materialisation lives in `checkoutTree` for hard reset.

const std = @import("std");
const plumbing = @import("plumbing");
const objpkg = @import("object");
const filemode = @import("filemode");
const index_fmt = @import("index");
const memory = @import("memory");
const fs_pkg = @import("fs");
const storer = @import("storer");

const worktree_mod = @import("worktree.zig");
const options_mod = @import("options.zig");
const error_mod = @import("error.zig");
const platform_mod = @import("platform.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const Worktree = worktree_mod.Worktree;
const CheckoutOptions = options_mod.CheckoutOptions;
const ResetOptions = options_mod.ResetOptions;
const Index = index_fmt.Index;
const FileMode = filemode.FileMode;

/// go-git `Worktree.Checkout`.
pub fn checkout(w: *Worktree, o: CheckoutOptions) !void {
    var opts = o;
    try opts.validate();

    if (opts.create) {
        try createBranch(w, &opts);
    }

    const commit_hash = try getCommitFromCheckoutOptions(w, &opts);

    // Mode selection matches go-git: default MergeReset; Force → Hard; Keep → Soft.
    var ro: ResetOptions = .{
        .commit = commit_hash,
        .mode = .merge,
    };
    if (opts.force) {
        ro.mode = .hard;
    } else if (opts.keep) {
        ro.mode = .soft;
    }

    // Update HEAD (symbolic branch or detached). go-git does this before Reset.
    if (!opts.hash.isZero() and !opts.create) {
        try setHEADToCommit(w, opts.hash);
    } else {
        try setHEADToBranch(w, opts.branch, commit_hash);
    }

    // Lazy import avoids a module-level cycle with reset.zig (which imports
    // checkoutTree only inside hard-reset).
    const reset_mod = @import("reset.zig");
    if (opts.sparse_checkout_directories.len > 0) {
        try reset_mod.resetSparsely(w, ro, opts.sparse_checkout_directories);
    } else {
        try reset_mod.reset(w, ro);
    }
}

/// Write every regular/symlink blob from `tree_hash` into the worktree FS and
/// rebuild the index to match (go-git hard/merge reset materialisation subset).
pub fn checkoutTree(w: *Worktree, tree_hash: Hash) !void {
    const allocator = w.allocator;

    // Drop files tracked by the previous index so force-style checkouts do not
    // leave stale paths (simplified vs full merkletrie diff).
    try removeIndexFiles(w);

    const tree = try objpkg.getTree(allocator, w.storer, tree_hash);
    defer objpkg.freeTree(allocator, tree);

    const idx = try allocator.create(Index);
    errdefer {
        idx.deinit();
        allocator.destroy(idx);
    }
    idx.* = Index.init(allocator);
    idx.version = 2;

    var files = try tree.files();
    defer files.close();

    while (true) {
        const f = files.next() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        try checkoutFile(w, &f);
        try addIndexFromFile(w, idx, f.name, f.blob.hash, f.mode);
    }

    w.storer.setIndex(idx);
}

// ---------------------------------------------------------------------------
// HEAD helpers (go-git setHEADToCommit / setHEADToBranch / setHEADCommit)
// ---------------------------------------------------------------------------

/// Detach HEAD at `commit` (go-git `setHEADToCommit`).
pub fn setHEADToCommit(w: *Worktree, commit: Hash) !void {
    const head = Reference.newHashReference(plumbing.HEAD, commit);
    try w.storer.setReference(head);
}

/// Point HEAD at `branch` (symbolic when it is a branch), else detach at `commit`.
/// go-git `setHEADToBranch`.
pub fn setHEADToBranch(w: *Worktree, branch: ReferenceName, commit: Hash) !void {
    const target = try w.storer.reference(branch);
    const head = if (target.name.isBranch())
        Reference.newSymbolicReference(plumbing.HEAD, target.name)
    else
        Reference.newHashReference(plumbing.HEAD, commit);
    try w.storer.setReference(head);
}

// ---------------------------------------------------------------------------
// createBranch / resolve commit (go-git helpers)
// ---------------------------------------------------------------------------

fn createBranch(w: *Worktree, opts: *CheckoutOptions) !void {
    try opts.branch.validate();

    if (w.storer.reference(opts.branch)) |_| {
        return error.BranchAlreadyExists;
    } else |err| {
        if (err != error.ReferenceNotFound) return err;
    }

    if (opts.hash.isZero()) {
        const head = try storer.resolveReference(w.storer, plumbing.HEAD);
        opts.hash = head.hash;
    }

    try w.storer.setReference(Reference.newHashReference(opts.branch, opts.hash));
}

fn getCommitFromCheckoutOptions(w: *Worktree, opts: *const CheckoutOptions) !Hash {
    var hash = opts.hash;
    if (hash.isZero()) {
        const b = try storer.resolveReference(w.storer, opts.branch);
        hash = b.hash;
    }

    var obj = try objpkg.getObject(w.allocator, w.storer, hash);
    defer obj.deinit(w.allocator);

    return switch (obj) {
        .commit => |c| c.hash,
        .tag => |t| blk: {
            if (t.target_type != .commit) return error.UnsupportedObject;
            break :blk t.target;
        },
        else => error.UnsupportedObject,
    };
}

// ---------------------------------------------------------------------------
// File materialisation
// ---------------------------------------------------------------------------

fn checkoutFile(w: *Worktree, f: *const objpkg.File) !void {
    try ensureParentDirs(w.filesystem, f.name);

    if (f.mode == filemode.Symlink) {
        const target = f.blob.readerBytes();
        // Replace existing path if present.
        w.filesystem.remove(f.name) catch {};
        w.filesystem.symlink(target, f.name) catch {
            // Windows non-admin fallback spirit: write link text as a regular file.
            try writeRegularFile(w, f.name, target, filemode.Regular);
        };
        return;
    }

    // Submodules are skipped by FileIter; other modes write as regular content.
    try writeRegularFile(w, f.name, f.blob.readerBytes(), f.mode);
}

fn writeRegularFile(w: *Worktree, path: []const u8, content: []const u8, mode: FileMode) !void {
    w.filesystem.remove(path) catch {};
    const perm: u32 = if (mode == filemode.Executable) 0o755 else 0o644;
    var file = try w.filesystem.openFile(path, fs_pkg.O.WRONLY | fs_pkg.O.CREATE | fs_pkg.O.TRUNC, perm);
    defer file.close() catch {};
    _ = try file.write(content);
}

fn ensureParentDirs(filesystem: *fs_pkg.Mem, path: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        if (i > 0) try filesystem.mkdirAll(path[0..i], 0o755);
    }
}

fn addIndexFromFile(
    w: *Worktree,
    idx: *Index,
    name: []const u8,
    hash: Hash,
    mode: FileMode,
) !void {
    const e = try idx.add(name);
    e.hash = hash;
    e.mode = mode;

    if (w.filesystem.lstat(name)) |info| {
        e.size = @intCast(@min(info.size, std.math.maxInt(u32)));
        e.modified_at = .{ .sec = info.mtime_sec, .nsec = 0 };
    } else |_| {
        e.size = 0;
    }
    // go-git fillSystemInfo(e, fi.Sys()) — platform ctime/dev/ino/uid/gid.
    platform_mod.fillSystemInfo(e, w.filesystem, name);
}

fn removeIndexFiles(w: *Worktree) !void {
    const idx = try w.storer.index();
    // Collect names first: remove may not touch the index list itself.
    var i: usize = 0;
    while (i < idx.entries.items.len) : (i += 1) {
        const name = idx.entries.items[i].name;
        w.filesystem.remove(name) catch {};
    }
}

// ---------------------------------------------------------------------------
// Tests (Mem FS + memory.Storage)
// ---------------------------------------------------------------------------

fn storeBlob(sto: *memory.Storage, content: []const u8) !Hash {
    const o = try sto.newEncodedObject();
    o.setType(.blob);
    try o.setContent(content);
    return try sto.setEncodedObject(o);
}

fn storeTree(sto: *memory.Storage, allocator: Allocator, entries: []const struct {
    name: []const u8,
    mode: FileMode,
    hash: Hash,
}) !Hash {
    var tree = objpkg.Tree.init(allocator, null);
    defer tree.deinit();
    for (entries) |e| {
        try tree.appendEntry(e.name, e.mode, e.hash);
    }
    tree.sortEntries();
    const o = try sto.newEncodedObject();
    try tree.encode(o);
    return try sto.setEncodedObject(o);
}

fn storeCommit(sto: *memory.Storage, allocator: Allocator, tree_h: Hash, msg: []const u8) !Hash {
    var c = objpkg.Commit.init(allocator);
    defer c.deinit();
    c.tree_hash = tree_h;
    c.author = .{ .name = "a", .email = "a@example.com", .when = 1, .tz_offset_minutes = 0 };
    c.committer = .{ .name = "a", .email = "a@example.com", .when = 1, .tz_offset_minutes = 0 };
    // Commit.deinit always frees message when non-empty.
    c.message = try allocator.dupe(u8, msg);
    const o = try sto.newEncodedObject();
    try c.encode(o);
    return try sto.setEncodedObject(o);
}

fn readFileAll(filesystem: *fs_pkg.Mem, allocator: Allocator, path: []const u8) ![]u8 {
    var f = try filesystem.open(path);
    defer f.close() catch {};
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [256]u8 = undefined;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
    }
    return try list.toOwnedSlice(allocator);
}

/// Two commits (A: a.txt, B: a.txt + sub/b.txt) with index/worktree at A.
fn setupTwoCommitCheckout(gpa: Allocator) !struct {
    sto: *memory.Storage,
    mem: *fs_pkg.Mem,
    wt: Worktree,
    commit_a: Hash,
    commit_b: Hash,
    blob_a: Hash,
} {
    const sto = try gpa.create(memory.Storage);
    errdefer gpa.destroy(sto);
    sto.* = memory.Storage.init(gpa);
    errdefer sto.deinit();

    const mem = try gpa.create(fs_pkg.Mem);
    errdefer gpa.destroy(mem);
    mem.* = try fs_pkg.Mem.init(gpa);
    errdefer mem.deinit();

    var wt = worktree_mod.newWorktree(gpa, sto, mem);

    const blob_a = try storeBlob(sto, "content-a");
    const tree_a = try storeTree(sto, gpa, &.{
        .{ .name = "a.txt", .mode = filemode.Regular, .hash = blob_a },
    });
    const commit_a = try storeCommit(sto, gpa, tree_a, "A\n");

    const blob_b_root = try storeBlob(sto, "content-a-at-b");
    const blob_b_sub = try storeBlob(sto, "content-sub");
    const sub_tree = try storeTree(sto, gpa, &.{
        .{ .name = "b.txt", .mode = filemode.Regular, .hash = blob_b_sub },
    });
    const tree_b = try storeTree(sto, gpa, &.{
        .{ .name = "a.txt", .mode = filemode.Regular, .hash = blob_b_root },
        .{ .name = "sub", .mode = filemode.Dir, .hash = sub_tree },
    });
    const commit_b = try storeCommit(sto, gpa, tree_b, "B\n");

    try sto.setReference(Reference.newHashReference(plumbing.master, commit_a));
    try sto.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

    // Materialise commit A into index + worktree.
    try checkoutTree(&wt, tree_a);
    try sto.setReference(Reference.newHashReference(plumbing.master, commit_a));

    return .{
        .sto = sto,
        .mem = mem,
        .wt = wt,
        .commit_a = commit_a,
        .commit_b = commit_b,
        .blob_a = blob_a,
    };
}

fn deinitTwoCommitCheckout(gpa: Allocator, env: anytype) void {
    env.mem.deinit();
    gpa.destroy(env.mem);
    env.sto.deinit();
    gpa.destroy(env.sto);
}

test "checkout materialises tree and detaches HEAD on hash" {
    const gpa = std.testing.allocator;
    var sto = memory.Storage.init(gpa);
    defer sto.deinit();
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var w = worktree_mod.newWorktree(gpa, &sto, &mem);

    const blob_h = try storeBlob(&sto, "hello world");
    const tree_h = try storeTree(&sto, gpa, &.{
        .{ .name = "readme.txt", .mode = filemode.Regular, .hash = blob_h },
    });
    const commit_h = try storeCommit(&sto, gpa, tree_h, "init\n");

    // Empty branch required with Hash (options.zig exclusive rule + default master).
    try checkout(&w, .{
        .hash = commit_h,
        .branch = .{ .raw = "" },
        .force = true,
    });

    const body = try readFileAll(&mem, gpa, "readme.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello world", body);

    const head = try sto.reference(plumbing.HEAD);
    try std.testing.expect(head.type == .hash);
    try std.testing.expect(head.hash.eql(commit_h));

    const idx = try sto.index();
    try std.testing.expectEqual(@as(usize, 1), idx.entries.items.len);
    try std.testing.expectEqualStrings("readme.txt", idx.entries.items[0].name);
    try std.testing.expect(idx.entries.items[0].hash.eql(blob_h));
}

test "checkout branch create and symbolic HEAD" {
    const gpa = std.testing.allocator;
    var sto = memory.Storage.init(gpa);
    defer sto.deinit();
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var w = worktree_mod.newWorktree(gpa, &sto, &mem);

    const blob_h = try storeBlob(&sto, "feature body");
    const tree_h = try storeTree(&sto, gpa, &.{
        .{ .name = "f.txt", .mode = filemode.Regular, .hash = blob_h },
    });
    const commit_h = try storeCommit(&sto, gpa, tree_h, "feat\n");

    // Seed HEAD so createBranch can fall back if hash were zero (here we pass hash).
    try sto.setReference(Reference.newHashReference(plumbing.HEAD, commit_h));

    const branch = plumbing.ReferenceName.init("refs/heads/feature");
    try checkout(&w, .{
        .hash = commit_h,
        .branch = branch,
        .create = true,
        .force = true,
    });

    const head = try sto.reference(plumbing.HEAD);
    try std.testing.expect(head.type == .symbolic);
    try std.testing.expectEqualStrings("refs/heads/feature", head.target.raw);

    const tip = try sto.reference(branch);
    try std.testing.expect(tip.hash.eql(commit_h));

    const body = try readFileAll(&mem, gpa, "f.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("feature body", body);
}

test "checkout keep leaves worktree untouched" {
    const gpa = std.testing.allocator;
    var sto = memory.Storage.init(gpa);
    defer sto.deinit();
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var w = worktree_mod.newWorktree(gpa, &sto, &mem);

    const blob_h = try storeBlob(&sto, "tracked");
    const tree_h = try storeTree(&sto, gpa, &.{
        .{ .name = "t.txt", .mode = filemode.Regular, .hash = blob_h },
    });
    const commit_h = try storeCommit(&sto, gpa, tree_h, "c\n");

    // Pre-existing worktree file not from tree.
    {
        var f = try mem.create("local-only.txt");
        defer f.close() catch {};
        _ = try f.write("local");
    }

    try checkout(&w, .{
        .hash = commit_h,
        .branch = .{ .raw = "" },
        .keep = true,
    });

    // HEAD moved…
    const head = try sto.reference(plumbing.HEAD);
    try std.testing.expect(head.hash.eql(commit_h));
    // …but worktree was not materialised.
    try std.testing.expectError(error.NotExist, mem.stat("t.txt"));
    const local = try readFileAll(&mem, gpa, "local-only.txt");
    defer gpa.free(local);
    try std.testing.expectEqualStrings("local", local);
}

test "checkout dirty without force returns UnstagedChanges" {
    const gpa = std.testing.allocator;
    var env = try setupTwoCommitCheckout(gpa);
    defer deinitTwoCommitCheckout(gpa, &env);

    // Unstaged modification of a tracked file.
    {
        var f = try env.mem.openFile("a.txt", fs_pkg.O.WRONLY | fs_pkg.O.TRUNC, 0o644);
        defer f.close() catch {};
        _ = try f.write("dirty");
    }

    try std.testing.expectError(
        error_mod.Error.UnstagedChanges,
        checkout(&env.wt, .{
            .hash = env.commit_b,
            .branch = .{ .raw = "" },
        }),
    );

    // Worktree still dirty; content not restored.
    const body = try readFileAll(env.mem, gpa, "a.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("dirty", body);
}

test "checkout dirty with force restores file" {
    const gpa = std.testing.allocator;
    var env = try setupTwoCommitCheckout(gpa);
    defer deinitTwoCommitCheckout(gpa, &env);

    {
        var f = try env.mem.openFile("a.txt", fs_pkg.O.WRONLY | fs_pkg.O.TRUNC, 0o644);
        defer f.close() catch {};
        _ = try f.write("dirty");
    }

    try checkout(&env.wt, .{
        .hash = env.commit_b,
        .branch = .{ .raw = "" },
        .force = true,
    });

    const body = try readFileAll(env.mem, gpa, "a.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("content-a-at-b", body);

    const head = try env.sto.reference(plumbing.HEAD);
    try std.testing.expect(head.hash.eql(env.commit_b));
}

test "checkout keep moves HEAD and leaves dirty file" {
    const gpa = std.testing.allocator;
    var env = try setupTwoCommitCheckout(gpa);
    defer deinitTwoCommitCheckout(gpa, &env);

    {
        var f = try env.mem.openFile("a.txt", fs_pkg.O.WRONLY | fs_pkg.O.TRUNC, 0o644);
        defer f.close() catch {};
        _ = try f.write("dirty-keep");
    }

    try checkout(&env.wt, .{
        .hash = env.commit_b,
        .branch = .{ .raw = "" },
        .keep = true,
    });

    const head = try env.sto.reference(plumbing.HEAD);
    try std.testing.expect(head.hash.eql(env.commit_b));

    const body = try readFileAll(env.mem, gpa, "a.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("dirty-keep", body);

    // Index still at A (soft reset).
    const idx = try env.sto.index();
    const ent = try idx.entry("a.txt");
    try std.testing.expect(ent.hash.eql(env.blob_a));
}

test "checkout sparse_checkout_directories marks skip_worktree via skipUnless" {
    const gpa = std.testing.allocator;
    var env = try setupTwoCommitCheckout(gpa);
    defer deinitTwoCommitCheckout(gpa, &env);

    // MergeReset sparse checkout of commit B with only "sub" prefix active.
    try checkout(&env.wt, .{
        .hash = env.commit_b,
        .branch = .{ .raw = "" },
        .sparse_checkout_directories = &.{"sub"},
    });

    const idx = try env.sto.index();
    // Both tree paths are in the index; skipUnless only flags non-matching.
    try std.testing.expectEqual(@as(usize, 2), idx.entries.items.len);

    const a_ent = try idx.entry("a.txt");
    try std.testing.expect(a_ent.skip_worktree);

    const b_ent = try idx.entry("sub/b.txt");
    try std.testing.expect(!b_ent.skip_worktree);

    // Active sparse path is on disk.
    const sub_body = try readFileAll(env.mem, gpa, "sub/b.txt");
    defer gpa.free(sub_body);
    try std.testing.expectEqualStrings("content-sub", sub_body);
}

test "checkoutTree nested path and index rebuild" {
    const gpa = std.testing.allocator;
    var sto = memory.Storage.init(gpa);
    defer sto.deinit();
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var w = worktree_mod.newWorktree(gpa, &sto, &mem);

    const blob_h = try storeBlob(&sto, "nested-content");
    const sub_h = try storeTree(&sto, gpa, &.{
        .{ .name = "inner.txt", .mode = filemode.Regular, .hash = blob_h },
    });
    const root_h = try storeTree(&sto, gpa, &.{
        .{ .name = "dir", .mode = filemode.Dir, .hash = sub_h },
    });

    try checkoutTree(&w, root_h);

    const body = try readFileAll(&mem, gpa, "dir/inner.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("nested-content", body);

    const idx = try sto.index();
    try std.testing.expectEqual(@as(usize, 1), idx.entries.items.len);
    try std.testing.expectEqualStrings("dir/inner.txt", idx.entries.items[0].name);
}

test "checkout options force+keep exclusive" {
    const gpa = std.testing.allocator;
    var sto = memory.Storage.init(gpa);
    defer sto.deinit();
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var w = worktree_mod.newWorktree(gpa, &sto, &mem);

    try std.testing.expectError(
        error_mod.Error.CheckoutForceKeepExclusive,
        checkout(&w, .{ .force = true, .keep = true }),
    );
}

test "createBranch rejects existing branch" {
    const gpa = std.testing.allocator;
    var sto = memory.Storage.init(gpa);
    defer sto.deinit();
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var w = worktree_mod.newWorktree(gpa, &sto, &mem);

    const blob_h = try storeBlob(&sto, "x");
    const tree_h = try storeTree(&sto, gpa, &.{
        .{ .name = "x", .mode = filemode.Regular, .hash = blob_h },
    });
    const commit_h = try storeCommit(&sto, gpa, tree_h, "m\n");

    try sto.setReference(Reference.newHashReference(plumbing.master, commit_h));
    try sto.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

    try std.testing.expectError(error.BranchAlreadyExists, checkout(&w, .{
        .branch = plumbing.master,
        .create = true,
        .hash = commit_h,
    }));
}

test "checkout symlink writes link target" {
    const gpa = std.testing.allocator;
    var sto = memory.Storage.init(gpa);
    defer sto.deinit();
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var w = worktree_mod.newWorktree(gpa, &sto, &mem);

    const target_h = try storeBlob(&sto, "some/target");
    const tree_h = try storeTree(&sto, gpa, &.{
        .{ .name = "link", .mode = filemode.Symlink, .hash = target_h },
    });
    const commit_h = try storeCommit(&sto, gpa, tree_h, "sym\n");

    try checkout(&w, .{
        .hash = commit_h,
        .branch = .{ .raw = "" },
        .force = true,
    });

    const tgt = try mem.readlink("link");
    defer gpa.free(tgt);
    try std.testing.expectEqualStrings("some/target", tgt);
}
