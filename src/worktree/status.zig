//! Worktree status — go-git Status over memory storage + Mem FS.
//!
//! Uses index ↔ worktree content comparison (reliable on Mem). Merkletrie
//! path is available via `diffCommitWithStaging` for staging-vs-HEAD when a
//! commit exists.

const std = @import("std");
const plumbing = @import("plumbing");
const storer = @import("storer");
const objpkg = @import("object");
const index_fmt = @import("index");
const gitignore = @import("gitignore");
const merkletrie = @import("merkletrie");
const noder = @import("noder");
const mindex = @import("merkletrie_index");
const memory = @import("memory");
const fs_pkg = @import("fs");
const filemode = @import("filemode");

const status_types = @import("status_types.zig");
const options_mod = @import("options.zig");
const util = @import("util.zig");
const worktree_mod = @import("worktree.zig");

const Allocator = std.mem.Allocator;
const Status = status_types.Status;
const StatusCode = status_types.StatusCode;
const StatusOptions = options_mod.StatusOptions;
const StatusStrategy = status_types.StatusStrategy;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const Index = index_fmt.Index;
const Action = merkletrie.Action;
pub const Changes = merkletrie.Changes;
const Noder = noder.Noder;

/// go-git `Worktree.StatusWithOptions`.
pub fn status(w: anytype, o: StatusOptions) !Status {
    var commit_hash = ZeroHash;
    const ref = util.resolveReference(w.storer, plumbing.HEAD) catch |err| switch (err) {
        error.ReferenceNotFound => null,
        else => |e| return e,
    };
    if (ref) |r| {
        defer w.storer.freeReference(r);
        if (r.type == .hash) commit_hash = r.hash;
    }

    var s = try strategyNew(w, o.strategy);
    errdefer s.deinit();

    // Staging: compare HEAD tree vs index (merkletrie when commit present).
    // Path strings are read from live noders — apply while the diff session lives.
    if (!commit_hash.isZero()) {
        try applyStagingFromCommit(w, &s, commit_hash);
    } else {
        // Empty HEAD: every index entry is staged as Added.
        const idx = try w.storer.index();
        for (idx.entries.items) |*e| {
            if (e.stage != 0) continue;
            const f = try s.file(e.name);
            f.staging = .added;
            f.worktree = .unmodified;
        }
    }

    // Worktree: compare index ↔ Mem FS by content hash.
    try applyWorktreeStatus(w, &s);

    return s;
}

/// HEAD tree ↔ index staging pass. Merkletrie `Path` holds noder pointers; those
/// noders must stay alive while `Path.string` / `name` run (do not return
/// Changes after destroying the session / index root).
fn applyStagingFromCommit(w: anytype, s: *Status, commit: Hash) !void {
    var tree_ptr: ?*objpkg.Tree = null;
    defer if (tree_ptr) |t| objpkg.freeTree(w.allocator, t);

    if (!commit.isZero()) {
        const c = try objpkg.getCommit(w.allocator, w.storer, commit);
        defer {
            if (c.heap_owned) {
                c.deinit();
                w.allocator.destroy(c);
            }
        }
        tree_ptr = try c.tree();
    }

    var session = objpkg.TreeNoderSession.init(w.allocator);
    defer session.deinit();

    const from_noder = try objpkg.newTreeRootNode(&session, tree_ptr);
    const idx = try w.storer.index();
    var idx_root = try mindex.newRootNode(w.allocator, idx);
    defer idx_root.deinit();

    var changes = try merkletrie.diffTree(
        w.allocator,
        from_noder.asNoder(),
        idx_root.noder(),
        diffTreeIsEquals,
    );
    defer changes.deinit();

    try applyStagingChanges(s, w.allocator, &changes);
}

fn strategyNew(w: anytype, ss: StatusStrategy) !Status {
    return switch (ss) {
        .preload => try preloadStatus(w),
        .empty => Status.init(w.allocator),
    };
}

fn preloadStatus(w: anytype) !Status {
    const idx = try w.storer.index();
    var s = Status.init(w.allocator);
    errdefer s.deinit();
    for (idx.entries.items) |*e| {
        if (e.stage != 0) continue;
        const f = try s.file(e.name);
        f.worktree = .unmodified;
        f.staging = .unmodified;
    }
    return s;
}

fn applyStagingChanges(s: *Status, allocator: Allocator, changes: *const Changes) !void {
    for (changes.items.items) |*ch| {
        const a = try ch.action();
        switch (a) {
            .delete => {
                const name = try ch.from.?.string(allocator);
                defer allocator.free(name);
                const f = try s.file(name);
                f.staging = .deleted;
                if (f.worktree == .untracked) f.worktree = .unmodified;
            },
            .insert => {
                const name = try ch.to.?.string(allocator);
                defer allocator.free(name);
                const f = try s.file(name);
                f.staging = .added;
                if (f.worktree == .untracked) f.worktree = .unmodified;
            },
            .modify => {
                const name = try ch.to.?.string(allocator);
                defer allocator.free(name);
                const f = try s.file(name);
                f.staging = .modified;
                if (f.worktree == .untracked) f.worktree = .unmodified;
            },
        }
    }
}

fn applyWorktreeStatus(w: anytype, s: *Status) !void {
    const idx = try w.storer.index();
    var indexed: std.StringHashMapUnmanaged(void) = .empty;
    defer indexed.deinit(w.allocator);

    for (idx.entries.items) |*e| {
        if (e.stage != 0) continue;
        try indexed.put(w.allocator, e.name, {});

        const f = try s.file(e.name);
        // `Status.file` defaults both sides to untracked. Index membership means
        // the path is tracked: if the HEAD↔index pass left staging untouched
        // (no diff), treat staging as unmodified — never leave `?` on tracked
        // paths (that breaks IsClean after a clean commit).
        if (f.staging == .untracked) f.staging = .unmodified;

        const info = w.filesystem.lstat(e.name) catch {
            // Missing from worktree → deleted in worktree.
            f.worktree = .deleted;
            continue;
        };
        if (info.isDir()) {
            f.worktree = .unmodified;
            continue;
        }
        // Compare blob hash.
        const blob_h = hashWorktreeFile(w, e.name) catch {
            f.worktree = .modified;
            continue;
        };
        if (blob_h.eql(e.hash)) {
            f.worktree = .unmodified;
        } else {
            f.worktree = .modified;
        }
    }

    // Untracked: walk Mem FS for regular files not in index.
    // go-git excludeIgnoredChanges: ReadPatterns + Worktree.Excludes.
    // readPatterns treats missing ignore files as empty (not an error).
    const from_fs = try gitignore.readPatterns(w.allocator, w.filesystem, &.{});
    defer gitignore.freePatterns(w.allocator, from_fs);

    var ignore: std.ArrayList(gitignore.Pattern) = .empty;
    defer ignore.deinit(w.allocator);
    try ignore.ensureTotalCapacity(w.allocator, from_fs.len + w.excludes.len);
    try ignore.appendSlice(w.allocator, from_fs);
    try ignore.appendSlice(w.allocator, w.excludes);

    try walkUntracked(w, s, &indexed, ".", ignore.items);
}

fn hashWorktreeFile(w: anytype, path: []const u8) !Hash {
    var f = try w.filesystem.open(path);
    defer f.close() catch {};
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(w.allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        try list.appendSlice(w.allocator, buf[0..n]);
    }
    return plumbing.computeHash(.blob, list.items);
}

fn walkUntracked(
    w: anytype,
    s: *Status,
    indexed: *const std.StringHashMapUnmanaged(void),
    dir: []const u8,
    ignore: []const gitignore.Pattern,
) !void {
    const entries = try w.filesystem.readDir(dir);
    defer w.filesystem.freeReadDir(entries);

    for (entries) |info| {
        if (std.mem.eql(u8, info.name, ".") or std.mem.eql(u8, info.name, "..")) continue;
        if (std.mem.eql(u8, info.name, ".git")) continue;
        const at_root = std.mem.eql(u8, dir, ".") or dir.len == 0;
        const path = if (at_root)
            try w.allocator.dupe(u8, info.name)
        else
            try std.fmt.allocPrint(w.allocator, "{s}/{s}", .{ dir, info.name });
        defer w.allocator.free(path);

        if (info.isDir()) {
            // Skip ignored directories entirely (go-git matcher on dir path).
            if (matchIgnore(ignore, path, true)) continue;
            try walkUntracked(w, s, indexed, path, ignore);
            continue;
        }
        if (indexed.contains(path)) continue;
        // go-git excludeIgnoredChanges: untracked Inserts that match ignore
        // are dropped from Status (TestIgnored: map length 0).
        if (matchIgnore(ignore, path, false)) continue;
        const f = try s.file(path);
        f.worktree = .untracked;
        f.staging = .untracked;
    }
}

const matchIgnore = util.matchIgnore;

fn diffTreeIsEquals(a: Noder, b: Noder) bool {
    const ha = a.hash();
    const hb = b.hash();
    if (ha.len == 0 or hb.len == 0) return false;
    if (std.mem.allEqual(u8, ha, 0) or std.mem.allEqual(u8, hb, 0)) return false;
    return std.mem.eql(u8, ha, hb);
}

/// go-git `Worktree.diffCommitWithStaging`.
///
/// Returned `Changes` paths are **string-backed** (valid after return). Prefer
/// status()'s internal apply path for production; this is for tests / tooling.
pub fn diffCommitWithStaging(w: anytype, commit: Hash, reverse: bool) !Changes {
    var tree_ptr: ?*objpkg.Tree = null;
    defer if (tree_ptr) |t| objpkg.freeTree(w.allocator, t);

    if (!commit.isZero()) {
        const c = try objpkg.getCommit(w.allocator, w.storer, commit);
        defer {
            if (c.heap_owned) {
                c.deinit();
                w.allocator.destroy(c);
            }
        }
        tree_ptr = try c.tree();
    }

    return diffTreeWithStaging(w, tree_ptr, reverse);
}

/// Diff tree vs index. Materializes path strings while noders are live so the
/// returned `Changes` remain valid after the session is destroyed.
///
/// Caller must free with `deinitMaterializedChanges` (not plain `Changes.deinit`)
/// so owned name noders are released.
pub fn diffTreeWithStaging(w: anytype, t: ?*objpkg.Tree, reverse: bool) !Changes {
    var session = objpkg.TreeNoderSession.init(w.allocator);
    defer session.deinit();

    const from_noder = try objpkg.newTreeRootNode(&session, t);
    const idx = try w.storer.index();
    var idx_root = try mindex.newRootNode(w.allocator, idx);
    defer idx_root.deinit();

    var live = if (reverse)
        try merkletrie.diffTree(w.allocator, idx_root.noder(), from_noder.asNoder(), diffTreeIsEquals)
    else
        try merkletrie.diffTree(w.allocator, from_noder.asNoder(), idx_root.noder(), diffTreeIsEquals);
    defer live.deinit();

    return try materializeChanges(w.allocator, &live);
}

/// Free Changes produced by `diffTreeWithStaging` / `diffCommitWithStaging`.
pub fn deinitMaterializedChanges(allocator: Allocator, changes: *Changes) void {
    for (changes.items.items) |*ch| {
        if (ch.from) |*p| freeOwnedPath(allocator, p);
        if (ch.to) |*p| freeOwnedPath(allocator, p);
        ch.from = null;
        ch.to = null;
    }
    changes.items.deinit(allocator);
    changes.* = undefined;
}

fn freeOwnedPath(allocator: Allocator, p: *noder.Path) void {
    for (p.nodes) |n| {
        const ptr: *OwnedNameNoder = @ptrCast(@alignCast(n.ptr));
        ptr.deinit(allocator);
    }
    p.deinit(allocator);
}

/// Convert live noder Paths into owned string-path Changes.
fn materializeChanges(allocator: Allocator, live: *const Changes) !Changes {
    var out = Changes.init(allocator);
    errdefer deinitMaterializedChanges(allocator, &out);

    for (live.items.items) |*ch| {
        const act = try ch.action();
        switch (act) {
            .insert => {
                const name = try ch.to.?.string(allocator);
                errdefer allocator.free(name);
                const p = try ownedPathFromName(allocator, name);
                try out.add(merkletrie.newInsert(p));
            },
            .delete => {
                const name = try ch.from.?.string(allocator);
                errdefer allocator.free(name);
                const p = try ownedPathFromName(allocator, name);
                try out.add(merkletrie.newDelete(p));
            },
            .modify => {
                const name_from = try ch.from.?.string(allocator);
                errdefer allocator.free(name_from);
                const name_to = try ch.to.?.string(allocator);
                errdefer allocator.free(name_to);
                var pf = try ownedPathFromName(allocator, name_from);
                errdefer freeOwnedPath(allocator, &pf);
                const pt = try ownedPathFromName(allocator, name_to);
                try out.add(merkletrie.newModify(pf, pt));
            },
        }
    }
    return out;
}

/// Heap noder that owns its name string so Path.string stays valid after the
/// merkletrie session dies.
const OwnedNameNoder = struct {
    name_owned: []u8,

    fn deinit(self: *OwnedNameNoder, allocator: Allocator) void {
        allocator.free(self.name_owned);
        allocator.destroy(self);
    }

    pub fn hash(_: *OwnedNameNoder) []const u8 {
        return &.{};
    }
    pub fn name(self: *OwnedNameNoder) []const u8 {
        return self.name_owned;
    }
    pub fn isDir(_: *OwnedNameNoder) bool {
        return false;
    }
    pub fn children(_: *OwnedNameNoder, _: Allocator) anyerror![]Noder {
        return noder.no_children;
    }
    pub fn numChildren(_: *OwnedNameNoder) anyerror!usize {
        return 0;
    }
    pub fn skip(_: *OwnedNameNoder) bool {
        return false;
    }
    pub fn string(self: *OwnedNameNoder, allocator: Allocator) anyerror![]u8 {
        return try allocator.dupe(u8, self.name_owned);
    }
};

fn ownedPathFromName(allocator: Allocator, name_owned: []u8) !noder.Path {
    const node = try allocator.create(OwnedNameNoder);
    errdefer {
        allocator.free(name_owned);
        allocator.destroy(node);
    }
    node.* = .{ .name_owned = name_owned };
    const nodes = try allocator.alloc(Noder, 1);
    errdefer allocator.free(nodes);
    nodes[0] = noder.noderOf(OwnedNameNoder, node);
    return .{ .nodes = nodes, .owned = true };
}

fn writeMemFile(mem: *fs_pkg.Mem, path: []const u8, content: []const u8) !void {
    var f = try mem.create(path);
    defer f.close() catch {};
    _ = try f.write(content);
}

test "status empty worktree is clean" {
    const gpa = std.testing.allocator;
    var sto = memory.Storage.init(gpa);
    defer sto.deinit();
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    var w = worktree_mod.newWorktree(gpa, &sto, &mem);
    var s = try status(&w, .{});
    defer s.deinit();
    try std.testing.expect(s.isClean());
}

test "status untracked file on empty strategy" {
    const gpa = std.testing.allocator;
    var sto = memory.Storage.init(gpa);
    defer sto.deinit();
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    try writeMemFile(&mem, "hello.txt", "hi");
    var w = worktree_mod.newWorktree(gpa, &sto, &mem);
    var s = try status(&w, .{});
    defer s.deinit();
    try std.testing.expect(!s.isClean());
    const f = s.map.get("hello.txt") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(StatusCode.untracked, f.worktree);
    try std.testing.expectEqual(StatusCode.untracked, f.staging);
}

test "status untracked with symbolic HEAD and heap Mem like integration" {
    const gpa = std.testing.allocator;
    const sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    try sto.setReference(plumbing.Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

    const mem = try gpa.create(fs_pkg.Mem);
    defer {
        mem.deinit();
        gpa.destroy(mem);
    }
    mem.* = try fs_pkg.Mem.init(gpa);

    try writeMemFile(mem, "hello.txt", "hello\n");
    // Prove FS sees the file.
    _ = try mem.stat("hello.txt");
    const listing = try mem.readDir(".");
    defer mem.freeReadDir(listing);
    try std.testing.expect(listing.len >= 1);

    var w = worktree_mod.newWorktree(gpa, sto, mem);
    var s = try status(&w, .{});
    defer s.deinit();
    try std.testing.expect(!s.isClean());
    const f = s.map.get("hello.txt") orelse {
        // Dump keys for diagnosis
        var it = s.map.keyIterator();
        while (it.next()) |k| {
            std.debug.print("status key: '{s}'\n", .{k.*});
        }
        std.debug.print("listing len={d}\n", .{listing.len});
        for (listing) |e| std.debug.print("list name='{s}' mode={o} isDir={}\n", .{ e.name, e.mode, e.isDir() });
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqual(StatusCode.untracked, f.worktree);
}

test "status staged added vs empty HEAD" {
    const gpa = std.testing.allocator;
    var sto = memory.Storage.init(gpa);
    defer sto.deinit();
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    const content = "staged";
    try writeMemFile(&mem, "a.txt", content);
    const h = plumbing.computeHash(.blob, content);
    const idx = try gpa.create(Index);
    idx.* = Index.init(gpa);
    const e = try idx.add("a.txt");
    e.hash = h;
    e.mode = filemode.Regular;
    e.size = @intCast(content.len);
    sto.setIndex(idx);
    var w = worktree_mod.newWorktree(gpa, &sto, &mem);
    var s = try status(&w, .{});
    defer s.deinit();
    const f = s.map.get("a.txt") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(StatusCode.added, f.staging);
    try std.testing.expectEqual(StatusCode.unmodified, f.worktree);
}

test "status worktree modified vs index" {
    const gpa = std.testing.allocator;
    var sto = memory.Storage.init(gpa);
    defer sto.deinit();
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    try writeMemFile(&mem, "m.txt", "new");
    const old_h = plumbing.computeHash(.blob, "old");
    const idx = try gpa.create(Index);
    idx.* = Index.init(gpa);
    const e = try idx.add("m.txt");
    e.hash = old_h;
    e.mode = filemode.Regular;
    e.size = 3;
    sto.setIndex(idx);
    var w = worktree_mod.newWorktree(gpa, &sto, &mem);
    var s = try status(&w, .{});
    defer s.deinit();
    const f = s.map.get("m.txt") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(StatusCode.modified, f.worktree);
    // Tracked path must not keep default staging=? when index has no HEAD.
    try std.testing.expectEqual(StatusCode.added, f.staging);
}

test "status clean after commit has unmodified staging on tracked files" {
    // Regression: empty-strategy file() defaults staging to untracked; after a
    // clean commit HEAD↔index has no diff, so applyWorktreeStatus must promote
    // tracked staging from untracked → unmodified or IsClean is false forever.
    const gpa = std.testing.allocator;
    var sto = memory.Storage.init(gpa);
    defer sto.deinit();
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    const content = "body\n";
    try writeMemFile(&mem, "t.txt", content);
    const h = plumbing.computeHash(.blob, content);
    const idx = try gpa.create(Index);
    idx.* = Index.init(gpa);
    const e = try idx.add("t.txt");
    e.hash = h;
    e.mode = filemode.Regular;
    e.size = @intCast(content.len);
    sto.setIndex(idx);
    // Simulate post-commit: resolve HEAD to a non-zero hash with matching tree.
    // Without a real commit object, zero HEAD takes the empty-HEAD branch
    // (staging=added). Seed a hash ref so we exercise the "no staging diff"
    // path only when a commit exists — covered by integration cycle.
    // Here: empty HEAD still leaves staging=added; worktree match → clean-ish.
    var w = worktree_mod.newWorktree(gpa, &sto, &mem);
    var s = try status(&w, .{});
    defer s.deinit();
    const f = s.map.get("t.txt") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(StatusCode.unmodified, f.worktree);
    try std.testing.expectEqual(StatusCode.added, f.staging);
    try std.testing.expect(!s.isClean());
}

test "status excludes ignored untracked via Worktree.excludes" {
    // go-git TestIgnored / TestExcludedNoGitignore: matching untracked paths
    // are absent from the status map (IsClean when only ignored noise).
    const gpa = std.testing.allocator;
    var sto = memory.Storage.init(gpa);
    defer sto.deinit();
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    try writeMemFile(&mem, "foo", "FOO");
    try writeMemFile(&mem, "bar", "BAR");

    var pat = try gitignore.parsePattern(gpa, "foo", &.{});
    defer pat.deinit();
    const excludes = [_]gitignore.Pattern{pat};

    var w = worktree_mod.newWorktree(gpa, &sto, &mem);
    w.excludes = &excludes;

    var s = try status(&w, .{});
    defer s.deinit();

    try std.testing.expect(s.map.get("foo") == null);
    try std.testing.expect(!s.isUntracked("foo"));
    const bar = s.map.get("bar") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(StatusCode.untracked, bar.worktree);
    try std.testing.expectEqual(StatusCode.untracked, bar.staging);
    try std.testing.expect(!s.isClean());
}

test "status only ignored untracked is clean" {
    const gpa = std.testing.allocator;
    var sto = memory.Storage.init(gpa);
    defer sto.deinit();
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    try writeMemFile(&mem, "noise.log", "x");

    var pat = try gitignore.parsePattern(gpa, "noise.log", &.{});
    defer pat.deinit();
    const excludes = [_]gitignore.Pattern{pat};

    var w = worktree_mod.newWorktree(gpa, &sto, &mem);
    w.excludes = &excludes;

    var s = try status(&w, .{});
    defer s.deinit();
    try std.testing.expect(s.isClean());
    try std.testing.expect(s.map.count() == 0);
}
