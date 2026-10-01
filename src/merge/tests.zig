//! Behavioral tests for Git merge strategies.
//! The oracle is Git 2.55. These tests recompute that behavior in-process.

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const obj = @import("object");
const index_fmt = @import("index");
const memory = @import("memory");
const filesystem = @import("filesystem");
const fs_pkg = @import("fs");

const merge = @import("root.zig");
const model = @import("model.zig");
const utils_sync = @import("utils/sync");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;

const Ent = struct {
    path: []const u8,
    body: []const u8,
    mode: filemode.FileMode = filemode.Regular,
};

const Repo = struct {
    allocator: Allocator,
    storer: *memory.Storage,
    filesystem: *fs_pkg.Mem,
    written: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Repo) void {
        for (self.written.items) |p| self.allocator.free(p);
        self.written.deinit(self.allocator);
        self.filesystem.deinit();
        self.allocator.destroy(self.filesystem);
        self.storer.deinit();
        self.allocator.destroy(self.storer);
        self.* = undefined;
    }
};

fn initRepo(allocator: Allocator) !Repo {
    const sto = try memory.newStorage(allocator);
    errdefer {
        sto.deinit();
        allocator.destroy(sto);
    }
    try sto.setReference(plumbing.Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
    const tree = try allocator.create(fs_pkg.Mem);
    errdefer allocator.destroy(tree);
    tree.* = try fs_pkg.Mem.init(allocator);
    var repo = Repo{ .allocator = allocator, .storer = sto, .filesystem = tree };
    try ensureUser(&repo);
    return repo;
}

fn ensureUser(w: anytype) !void {
    const cfg = try w.storer.config();
    try cfg.setUser("T", "t@t.t");
}

fn storeCommit(w: anytype, tree: Hash, parents: []const Hash) !Hash {
    var c = obj.Commit.init(w.allocator);
    c.tree_hash = tree;
    c.message = "c\n";
    c.author = .{ .name = "T", .email = "t@t.t", .when = 1, .tz_offset_minutes = 0 };
    c.committer = c.author;
    const copy = try w.allocator.dupe(Hash, parents);
    defer w.allocator.free(copy);
    c.parent_hashes = copy;
    const enc = try w.storer.newEncodedObject();
    errdefer w.storer.discardEncodedObject(enc);
    try c.encode(enc);
    c.parent_hashes = &.{};
    c.message = "";
    c.author = .{};
    c.committer = .{};
    return w.storer.setEncodedObject(enc);
}

fn commitFiles(w: anytype, parents: []const Hash, files: []const Ent) !Hash {
    var items: std.ArrayList(model.TreeItem) = .empty;
    defer items.deinit(w.allocator);
    for (files) |f| {
        const hash = try model.storeBlob(w.storer, f.body);
        try items.append(w.allocator, .{ .path = f.path, .mode = f.mode, .hash = hash });
    }
    std.mem.sort(model.TreeItem, items.items, {}, struct {
        fn less(_: void, a: model.TreeItem, b: model.TreeItem) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.less);
    const tree = if (items.items.len == 0)
        try model.emptyTree(w.allocator, w.storer)
    else
        try model.storeTree(w.allocator, w.storer, items.items);
    return storeCommit(w, tree, parents);
}

fn commitItems(w: anytype, parents: []const Hash, items_in: []const model.TreeItem) !Hash {
    var items: std.ArrayList(model.TreeItem) = .empty;
    defer items.deinit(w.allocator);
    try items.appendSlice(w.allocator, items_in);
    std.mem.sort(model.TreeItem, items.items, {}, struct {
        fn less(_: void, a: model.TreeItem, b: model.TreeItem) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.less);
    const tree = if (items.items.len == 0)
        try model.emptyTree(w.allocator, w.storer)
    else
        try model.storeTree(w.allocator, w.storer, items.items);
    return storeCommit(w, tree, parents);
}

fn adoptIndex(w: anytype, idx: *index_fmt.Index) !void {
    const Storage = @TypeOf(w.storer.*);
    if (comptime @hasDecl(Storage, "setIndexOwned")) {
        try w.storer.setIndexOwned(idx);
    } else if (comptime @hasDecl(Storage, "set_index_can_fail") and Storage.set_index_can_fail) {
        try w.storer.setIndex(idx);
    } else {
        w.storer.setIndex(idx);
    }
}

fn setHead(w: anytype, hash: Hash) !void {
    try w.storer.setReference(plumbing.Reference.newHashReference(plumbing.master, hash));
    try sync(w, hash);
}

fn sync(w: anytype, hash: Hash) !void {
    for (w.written.items) |p| w.filesystem.remove(p) catch {};
    for (w.written.items) |p| w.allocator.free(p);
    w.written.deinit(w.allocator);
    w.written = .empty;

    const commit = try obj.getCommit(w.allocator, w.storer, hash);
    defer obj.freeCommit(w.allocator, commit);
    var leaves = model.LeafMap{};
    defer leaves.deinit(w.allocator);
    try model.walkTree(w.allocator, w.storer, commit.tree_hash, &leaves);

    const idx = try w.allocator.create(index_fmt.Index);
    idx.* = index_fmt.Index.init(w.allocator);
    idx.version = 2;
    errdefer {
        idx.deinit();
        w.allocator.destroy(idx);
    }
    var it = leaves.map.iterator();
    while (it.next()) |e| {
        const leaf = e.value_ptr.*;
        const entry = try idx.add(e.key_ptr.*);
        entry.hash = leaf.hash;
        entry.mode = leaf.mode;
        entry.stage = 0;
        if (leaf.mode == filemode.Submodule) continue;
        try ensureParent(w, e.key_ptr.*);
        const bytes = try model.blobBytes(w.allocator, w.storer, leaf.hash);
        defer w.allocator.free(bytes);
        if (leaf.mode == filemode.Symlink) {
            w.filesystem.remove(e.key_ptr.*) catch {};
            try w.filesystem.symlink(bytes, e.key_ptr.*);
        } else {
            var file = try w.filesystem.create(e.key_ptr.*);
            errdefer file.close() catch {};
            var off: usize = 0;
            while (off < bytes.len) {
                const n = try file.write(bytes[off..]);
                if (n == 0) return error.ShortWrite;
                off += n;
            }
            try file.close();
        }
        try w.written.append(w.allocator, try w.allocator.dupe(u8, e.key_ptr.*));
    }
    try adoptIndex(w, idx);
}

fn ensureParent(w: anytype, path: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        if (i > 0) try w.filesystem.mkdirAll(path[0..i], 0o755);
    }
}

fn readHead(w: anytype) !Hash {
    const ref = try w.storer.reference(plumbing.master);
    defer w.storer.freeReference(ref);
    return ref.hash;
}

fn readFile(w: anytype, path: []const u8) ![]u8 {
    var file = try w.filesystem.open(path);
    defer file.close() catch {};
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(w.allocator);
    var tmp: [256]u8 = undefined;
    while (true) {
        const n = try file.read(&tmp);
        if (n == 0) break;
        try buf.appendSlice(w.allocator, tmp[0..n]);
    }
    return buf.toOwnedSlice(w.allocator);
}

fn stageHash(w: anytype, name: []const u8, stage: i32) !?Hash {
    const idx = try w.storer.index();
    for (idx.entries.items) |e| {
        if (e.stage == stage and std.mem.eql(u8, e.name, name)) return e.hash;
    }
    return null;
}

fn hasStage(w: anytype, name: []const u8, stage: i32) !bool {
    return (try stageHash(w, name, stage)) != null;
}

fn gitText(w: anytype, name: []const u8) !?[]u8 {
    return w.storer.readGitFile(w.allocator, name);
}

test "clean merge keeps edits separated by one unchanged line" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\nb\nc\nd\n" }});
    try setHead(&repo, base);
    const ours = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nX\nc\nd\n" }});
    try setHead(&repo, ours);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nb\nc\nY\n" }});

    const result = try merge.merge(&repo, &.{side}, .{ .message = "m\n" });
    try std.testing.expect(result.clean);
    const id = result.commit.?;
    const body = try readFile(&repo, "f.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("a\nX\nc\nY\n", body);
    const commit = try obj.getCommit(gpa, repo.storer, id);
    defer obj.freeCommit(gpa, commit);
    try std.testing.expectEqual(@as(usize, 2), commit.parent_hashes.len);
    try std.testing.expect(commit.parent_hashes[0].eql(ours));
    try std.testing.expect(commit.parent_hashes[1].eql(side));
    try std.testing.expect((try readHead(&repo)).eql(id));
    const mh = try gitText(&repo, "MERGE_HEAD");
    try std.testing.expect(mh == null);
}

test "adjacent edits conflict inside one marker region" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\nb\nc\n" }});
    try setHead(&repo, base);
    const ours = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nX\nc\n" }});
    try setHead(&repo, ours);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nb\nY\n" }});

    const result = try merge.merge(&repo, &.{side}, .{ .message = "m\n" });
    try std.testing.expect(!result.clean);
    try std.testing.expect(result.commit == null);
    try std.testing.expect((try readHead(&repo)).eql(ours));
    const body = try readFile(&repo, "f.txt");
    defer gpa.free(body);
    var hex: [plumbing.MaxHexSize]u8 = undefined;
    const label = side.string(&hex);
    const expect = try std.fmt.allocPrint(gpa, "a\n<<<<<<< HEAD\nX\nc\n=======\nb\nY\n>>>>>>> {s}\n", .{label});
    defer gpa.free(expect);
    try std.testing.expectEqualStrings(expect, body);
    try std.testing.expect((try stageHash(&repo, "f.txt", 1)).?.eql(try model.storeBlob(repo.storer, "a\nb\nc\n")));
    try std.testing.expect((try stageHash(&repo, "f.txt", 2)).?.eql(try model.storeBlob(repo.storer, "a\nX\nc\n")));
    try std.testing.expect((try stageHash(&repo, "f.txt", 3)).?.eql(try model.storeBlob(repo.storer, "a\nb\nY\n")));
    try std.testing.expect(try hasStage(&repo, "f.txt", 0) == false);
    const mh = try gitText(&repo, "MERGE_HEAD");
    defer if (mh) |b| gpa.free(b);
    try std.testing.expect(mh != null);
    const auto = try gitText(&repo, "AUTO_MERGE");
    defer if (auto) |b| gpa.free(b);
    try std.testing.expect(auto != null);
}

test "favor ours replaces an adjacent conflict with HEAD" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\nb\nc\n" }});
    try setHead(&repo, base);
    const ours = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nX\nc\n" }});
    try setHead(&repo, ours);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nb\nY\n" }});
    const result = try merge.merge(&repo, &.{side}, .{ .message = "m\n", .favor = .ours });
    try std.testing.expect(result.clean);
    const body = try readFile(&repo, "f.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("a\nX\nc\n", body);
}

test "identical edits are taken once" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\nb\nc\n" }});
    try setHead(&repo, base);
    const ours = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nZ\nc\n" }});
    try setHead(&repo, ours);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nZ\nc\n" }});
    const result = try merge.merge(&repo, &.{side}, .{ .message = "m\n" });
    try std.testing.expect(result.clean);
    const body = try readFile(&repo, "f.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("a\nZ\nc\n", body);
}

test "fast-forward checks out the descendant and writes no MERGE_HEAD" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\n" }});
    try setHead(&repo, base);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "b\n" }});
    const result = try merge.merge(&repo, &.{side}, .{});
    try std.testing.expect(result.clean);
    try std.testing.expect(result.commit == null);
    try std.testing.expect((try readHead(&repo)).eql(side));
    const body = try readFile(&repo, "f.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("b\n", body);
    const mh = try gitText(&repo, "MERGE_HEAD");
    try std.testing.expect(mh == null);
    const orig = try gitText(&repo, "ORIG_HEAD");
    defer if (orig) |b| gpa.free(b);
    try std.testing.expect(orig != null);
}

test "no-ff of a descendant creates a merge commit with the incoming tree" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\n" }});
    try setHead(&repo, base);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "b\n" }});
    const result = try merge.merge(&repo, &.{side}, .{ .message = "m\n", .fast_forward = .no_ff });
    const id = result.commit.?;
    try std.testing.expect(!id.eql(side));
    const body = try readFile(&repo, "f.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("b\n", body);
    const commit = try obj.getCommit(gpa, repo.storer, id);
    defer obj.freeCommit(gpa, commit);
    try std.testing.expectEqual(@as(usize, 2), commit.parent_hashes.len);
    try std.testing.expect(commit.parent_hashes[0].eql(base));
    try std.testing.expect(commit.parent_hashes[1].eql(side));
}

test "ff-only refuses a diverged head without writing MERGE_HEAD" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\n" }});
    try setHead(&repo, base);
    const ours = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "ours\n" }});
    try setHead(&repo, ours);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "side\n" }});
    try std.testing.expectError(error.NotFastForward, merge.merge(&repo, &.{side}, .{ .fast_forward = .ff_only }));
    try std.testing.expect((try readHead(&repo)).eql(ours));
    const body = try readFile(&repo, "f.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("ours\n", body);
    const mh = try gitText(&repo, "MERGE_HEAD");
    try std.testing.expect(mh == null);
}

test "ours of a descendant keeps the current tree and records two parents" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\n" }});
    try setHead(&repo, base);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "b\n" }});
    const head_c = try obj.getCommit(gpa, repo.storer, base);
    defer obj.freeCommit(gpa, head_c);
    const result = try merge.merge(&repo, &.{side}, .{ .message = "m\n", .strategy = .ours });
    const id = result.commit.?;
    const commit = try obj.getCommit(gpa, repo.storer, id);
    defer obj.freeCommit(gpa, commit);
    try std.testing.expect(commit.tree_hash.eql(head_c.tree_hash));
    try std.testing.expectEqual(@as(usize, 2), commit.parent_hashes.len);
    const body = try readFile(&repo, "f.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("a\n", body);
}

test "octopus of disjoint edits has three parents" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{
        .{ .path = "a.txt", .body = "a\n" },
        .{ .path = "b.txt", .body = "b\n" },
    });
    try setHead(&repo, base);
    const head = try commitFiles(&repo, &.{base}, &.{
        .{ .path = "a.txt", .body = "A\n" },
        .{ .path = "b.txt", .body = "b\n" },
    });
    try setHead(&repo, head);
    const s1 = try commitFiles(&repo, &.{base}, &.{
        .{ .path = "a.txt", .body = "a\n" },
        .{ .path = "b.txt", .body = "B\n" },
    });
    const s2 = try commitFiles(&repo, &.{base}, &.{
        .{ .path = "a.txt", .body = "a\n" },
        .{ .path = "b.txt", .body = "b\n" },
        .{ .path = "c.txt", .body = "C\n" },
    });
    const heads = [_]Hash{ s1, s2 };
    const result = try merge.merge(&repo, &heads, .{ .message = "m\n", .strategy = .octopus });
    try std.testing.expect(result.clean);
    const commit = try obj.getCommit(gpa, repo.storer, result.commit.?);
    defer obj.freeCommit(gpa, commit);
    try std.testing.expectEqual(@as(usize, 3), commit.parent_hashes.len);
    const a = try readFile(&repo, "a.txt");
    defer gpa.free(a);
    const b = try readFile(&repo, "b.txt");
    defer gpa.free(b);
    const c = try readFile(&repo, "c.txt");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("A\n", a);
    try std.testing.expectEqualStrings("B\n", b);
    try std.testing.expectEqualStrings("C\n", c);
}

test "octopus conflict writes nothing" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "a.txt", .body = "a\n" }});
    try setHead(&repo, base);
    const head = try commitFiles(&repo, &.{base}, &.{.{ .path = "a.txt", .body = "A\n" }});
    try setHead(&repo, head);
    const s1 = try commitFiles(&repo, &.{base}, &.{.{ .path = "a.txt", .body = "S1\n" }});
    const s2 = try commitFiles(&repo, &.{base}, &.{.{ .path = "a.txt", .body = "S2\n" }});
    const heads = [_]Hash{ s1, s2 };
    try std.testing.expectError(error.OctopusConflict, merge.merge(&repo, &heads, .{ .strategy = .octopus }));
    try std.testing.expect((try readHead(&repo)).eql(head));
    const body = try readFile(&repo, "a.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("A\n", body);
    const mh = try gitText(&repo, "MERGE_HEAD");
    try std.testing.expect(mh == null);
}

test "ort rename follows an exact hash move" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "a.txt", .body = "hello\n" }});
    try setHead(&repo, base);
    const ours = try commitFiles(&repo, &.{base}, &.{.{ .path = "b.txt", .body = "hello\n" }});
    try setHead(&repo, ours);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "a.txt", .body = "hello\nworld\n" }});
    const result = try merge.merge(&repo, &.{side}, .{ .message = "m\n", .strategy = .ort });
    try std.testing.expect(result.clean);
    const body = try readFile(&repo, "b.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello\nworld\n", body);
    try std.testing.expectError(error.NotExist, repo.filesystem.lstat("a.txt"));
}

test "resolve does not detect the rename and leaves a modify/delete" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "a.txt", .body = "hello\n" }});
    try setHead(&repo, base);
    const ours = try commitFiles(&repo, &.{base}, &.{.{ .path = "b.txt", .body = "hello\n" }});
    try setHead(&repo, ours);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "a.txt", .body = "hello\nworld\n" }});
    const result = try merge.merge(&repo, &.{side}, .{ .message = "m\n", .strategy = .resolve });
    try std.testing.expect(!result.clean);
    try std.testing.expect(try hasStage(&repo, "b.txt", 0));
    try std.testing.expect(try hasStage(&repo, "a.txt", 1));
    try std.testing.expect(try hasStage(&repo, "a.txt", 3));
    try std.testing.expect(!try hasStage(&repo, "a.txt", 2));
    const body = try readFile(&repo, "a.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("hello\nworld\n", body);
    const auto = try gitText(&repo, "AUTO_MERGE");
    try std.testing.expect(auto == null);
    const mh = try gitText(&repo, "MERGE_HEAD");
    defer if (mh) |b| gpa.free(b);
    try std.testing.expect(mh != null);
}

test "binary conflict leaves the ours bytes in the worktree" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\n" }});
    try setHead(&repo, base);
    const ours = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\x00X\n" }});
    try setHead(&repo, ours);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\x00Y\n" }});
    const result = try merge.merge(&repo, &.{side}, .{ .message = "m\n" });
    try std.testing.expect(!result.clean);
    const body = try readFile(&repo, "f.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("a\x00X\n", body);
}

test "modify/delete keeps theirs and omits stage 2" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\n" }});
    try setHead(&repo, base);
    const ours = try commitFiles(&repo, &.{base}, &.{});
    try setHead(&repo, ours);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "b\n" }});
    const result = try merge.merge(&repo, &.{side}, .{ .message = "m\n" });
    try std.testing.expect(!result.clean);
    try std.testing.expect(try hasStage(&repo, "f.txt", 1));
    try std.testing.expect(!try hasStage(&repo, "f.txt", 2));
    try std.testing.expect(try hasStage(&repo, "f.txt", 3));
    const body = try readFile(&repo, "f.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("b\n", body);
}

test "dirty index and a second merge leave the first conflict in place" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\n" }});
    try setHead(&repo, base);
    const idx = try repo.storer.index();
    idx.entries.items[0].hash = plumbing.ZeroHash;
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "b\n" }});
    try std.testing.expectError(error.DirtyIndex, merge.merge(&repo, &.{side}, .{}));
    const mh = try gitText(&repo, "MERGE_HEAD");
    try std.testing.expect(mh == null);

    idx.entries.items[0].hash = try model.storeBlob(repo.storer, "a\n");
    const ours = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nX\nc\n" }});
    try setHead(&repo, ours);
    const left = try commitFiles(&repo, &.{ours}, &.{.{ .path = "f.txt", .body = "a\nX\nc\n" }});
    _ = left;
    const other = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nY\nc\n" }});
    // Rebuild a real diverged pair from base. HEAD is ours ("a\nX\nc\n" over "a\n"), which is not the adjacent fixture.
    // Use a fresh conflict from the files already at HEAD: merge `other` only if it diverges. It does.
    const first = try merge.merge(&repo, &.{other}, .{ .message = "m\n" });
    try std.testing.expect(!first.clean);
    const mid = try readFile(&repo, "f.txt");
    defer gpa.free(mid);
    const again = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "z\n" }});
    try std.testing.expectError(error.MergeInProgress, merge.merge(&repo, &.{again}, .{}));
    const after = try readFile(&repo, "f.txt");
    defer gpa.free(after);
    try std.testing.expectEqualStrings(mid, after);
    try std.testing.expect((try readHead(&repo)).eql(ours));
}

test "unrelated histories are refused unless the caller allows them" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const head = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\n" }});
    try setHead(&repo, head);
    const side = try commitFiles(&repo, &.{}, &.{.{ .path = "g.txt", .body = "b\n" }});
    try std.testing.expectError(error.UnrelatedHistories, merge.merge(&repo, &.{side}, .{}));
    const result = try merge.merge(&repo, &.{side}, .{ .message = "m\n", .allow_unrelated_histories = true });
    try std.testing.expect(result.clean);
    const f = try readFile(&repo, "f.txt");
    defer gpa.free(f);
    const g = try readFile(&repo, "g.txt");
    defer gpa.free(g);
    try std.testing.expectEqualStrings("a\n", f);
    try std.testing.expectEqualStrings("b\n", g);
}

test "ort and recursive write the same tree" {
    const gpa = std.testing.allocator;
    const ort_tree = try strategyTree(gpa, .ort);
    const rec_tree = try strategyTree(gpa, .recursive);
    try std.testing.expect(ort_tree.eql(rec_tree));
}

fn strategyTree(allocator: Allocator, strategy: merge.Strategy) !Hash {
    var repo = try initRepo(allocator);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\nb\nc\nd\n" }});
    try setHead(&repo, base);
    const ours = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nX\nc\nd\n" }});
    try setHead(&repo, ours);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nb\nc\nY\n" }});
    const result = try merge.merge(&repo, &.{side}, .{ .message = "m\n", .strategy = strategy });
    const commit = try obj.getCommit(allocator, repo.storer, result.commit.?);
    defer obj.freeCommit(allocator, commit);
    return commit.tree_hash;
}

test "subtree shift lines up the same content and conflicts when it differs" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const head = try commitFiles(&repo, &.{}, &.{.{ .path = "sub/f.txt", .body = "a\n" }});
    try setHead(&repo, head);
    const side = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\n" }});
    const result = try merge.merge(&repo, &.{side}, .{
        .message = "m\n",
        .strategy = .subtree,
        .subtree_path = "sub",
        .allow_unrelated_histories = true,
    });
    try std.testing.expect(result.clean);
    const body = try readFile(&repo, "sub/f.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("a\n", body);

    var repo2 = try initRepo(gpa);
    defer repo2.deinit();
    const head2 = try commitFiles(&repo2, &.{}, &.{.{ .path = "sub/f.txt", .body = "a\n" }});
    try setHead(&repo2, head2);
    const side2 = try commitFiles(&repo2, &.{}, &.{.{ .path = "f.txt", .body = "b\n" }});
    const bad = try merge.merge(&repo2, &.{side2}, .{
        .message = "m\n",
        .strategy = .subtree,
        .allow_unrelated_histories = true,
    });
    try std.testing.expect(!bad.clean);
    const mh = try gitText(&repo2, "MERGE_HEAD");
    defer if (mh) |b| gpa.free(b);
    try std.testing.expect(mh != null);
}

test "mergeContinue commits a resolved index and mergeAbort restores ORIG_HEAD" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\nb\nc\n" }});
    try setHead(&repo, base);
    const ours = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nX\nc\n" }});
    try setHead(&repo, ours);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nb\nY\n" }});
    const conflicted = try merge.merge(&repo, &.{side}, .{ .message = "m\n" });
    try std.testing.expect(!conflicted.clean);

    const resolved = try model.storeBlob(repo.storer, "a\nX\nc\n");
    const idx = try gpa.create(index_fmt.Index);
    idx.* = index_fmt.Index.init(gpa);
    idx.version = 2;
    const entry = try idx.add("f.txt");
    entry.hash = resolved;
    entry.mode = filemode.Regular;
    entry.stage = 0;
    repo.storer.setIndex(idx);
    const id = try merge.mergeContinue(&repo, .{});
    const commit = try obj.getCommit(gpa, repo.storer, id);
    defer obj.freeCommit(gpa, commit);
    try std.testing.expectEqual(@as(usize, 2), commit.parent_hashes.len);
    const mh = try gitText(&repo, "MERGE_HEAD");
    try std.testing.expect(mh == null);

    var repo2 = try initRepo(gpa);
    defer repo2.deinit();
    const base2 = try commitFiles(&repo2, &.{}, &.{.{ .path = "f.txt", .body = "a\nb\nc\n" }});
    try setHead(&repo2, base2);
    const ours2 = try commitFiles(&repo2, &.{base2}, &.{.{ .path = "f.txt", .body = "a\nX\nc\n" }});
    try setHead(&repo2, ours2);
    const side2 = try commitFiles(&repo2, &.{base2}, &.{.{ .path = "f.txt", .body = "a\nb\nY\n" }});
    _ = try merge.merge(&repo2, &.{side2}, .{ .message = "m\n" });
    try merge.mergeAbort(&repo2);
    try std.testing.expect((try readHead(&repo2)).eql(ours2));
    const body = try readFile(&repo2, "f.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("a\nX\nc\n", body);
    const left = try gitText(&repo2, "MERGE_HEAD");
    try std.testing.expect(left == null);
}

test "a shallow repository with no merge base does not invent one" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const head = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\n" }});
    try setHead(&repo, head);
    const side = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "b\n" }});
    try repo.storer.setShallow(&.{head});
    try std.testing.expectError(error.ShallowHistory, merge.merge(&repo, &.{side}, .{ .allow_unrelated_histories = true }));
}

test "gitlink fast-forwards when one recorded commit contains the other" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const empty = try commitFiles(&repo, &.{}, &.{});
    const child = try commitFiles(&repo, &.{empty}, &.{.{ .path = "inside", .body = "z\n" }});
    const base = try commitItems(&repo, &.{}, &.{.{ .path = "sub", .mode = filemode.Submodule, .hash = empty }});
    try setHead(&repo, base);
    const ours = try commitItems(&repo, &.{base}, &.{.{ .path = "sub", .mode = filemode.Submodule, .hash = empty }});
    try setHead(&repo, ours);
    const side = try commitItems(&repo, &.{base}, &.{.{ .path = "sub", .mode = filemode.Submodule, .hash = child }});
    // Both sides differ from a missing base only when the base gitlink is a third commit.
    // Here ours equals base, so the take is trivial. Build a real both-sides change:
    _ = side;
    const tip_a = try commitItems(&repo, &.{ours}, &.{.{ .path = "sub", .mode = filemode.Submodule, .hash = empty }});
    try setHead(&repo, tip_a);
    const tip_b = try commitItems(&repo, &.{ours}, &.{.{ .path = "sub", .mode = filemode.Submodule, .hash = child }});
    // tip_a still records `empty`, which equals the merge base `ours`. Use two descendants.
    const later = try commitFiles(&repo, &.{child}, &.{.{ .path = "inside", .body = "zz\n" }});
    const left = try commitItems(&repo, &.{ours}, &.{.{ .path = "sub", .mode = filemode.Submodule, .hash = child }});
    try setHead(&repo, left);
    const right = try commitItems(&repo, &.{ours}, &.{.{ .path = "sub", .mode = filemode.Submodule, .hash = later }});
    const result = try merge.merge(&repo, &.{right}, .{ .message = "m\n" });
    try std.testing.expect(result.clean);
    try std.testing.expect((try stageHash(&repo, "sub", 0)).?.eql(later));
    try std.testing.expectError(error.NotExist, repo.filesystem.lstat("sub"));
    _ = tip_b;
}

test "filesystem storage clean merge matches the memory result" {
    const gpa = std.testing.allocator;
    defer utils_sync.deinitPools(gpa);
    var git_fs = try fs_pkg.Mem.init(gpa);
    defer git_fs.deinit();
    const sto = try filesystem.newStorage(gpa, &git_fs, null);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    try sto.initLayout();
    try sto.setReference(plumbing.Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
    const work = try gpa.create(fs_pkg.Mem);
    defer {
        work.deinit();
        gpa.destroy(work);
    }
    work.* = try fs_pkg.Mem.init(gpa);
    var repo = struct {
        allocator: Allocator,
        storer: *filesystem.StorageMem,
        filesystem: *fs_pkg.Mem,
        written: std.ArrayList([]u8) = .empty,
    }{ .allocator = gpa, .storer = sto, .filesystem = work };
    defer {
        for (repo.written.items) |p| gpa.free(p);
        repo.written.deinit(gpa);
    }
    try ensureUser(&repo);
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\nb\nc\nd\n" }});
    try setHead(&repo, base);
    const ours = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nX\nc\nd\n" }});
    try setHead(&repo, ours);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nb\nc\nY\n" }});
    const result = try merge.merge(&repo, &.{side}, .{ .message = "m\n" });
    try std.testing.expect(result.clean);
    const body = try readFile(&repo, "f.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("a\nX\nc\nY\n", body);
    const mem_tree = try strategyTree(gpa, .ort);
    const commit = try obj.getCommit(gpa, repo.storer, result.commit.?);
    defer obj.freeCommit(gpa, commit);
    try std.testing.expect(commit.tree_hash.eql(mem_tree));
}

test "directory/file conflict moves the file onto a tilde path" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "d", .body = "a\n" }});
    try setHead(&repo, base);
    const ours = try commitFiles(&repo, &.{base}, &.{.{ .path = "d/x.txt", .body = "ours\n" }});
    try setHead(&repo, ours);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "d", .body = "b\n" }});
    const result = try merge.merge(&repo, &.{side}, .{ .message = "m\n" });
    try std.testing.expect(!result.clean);
    const child = try readFile(&repo, "d/x.txt");
    defer gpa.free(child);
    try std.testing.expectEqualStrings("ours\n", child);
    var hex: [plumbing.MaxHexSize]u8 = undefined;
    const moved = try std.fmt.allocPrint(gpa, "d~{s}", .{side.string(&hex)});
    defer gpa.free(moved);
    const file = try readFile(&repo, moved);
    defer gpa.free(file);
    try std.testing.expectEqualStrings("b\n", file);
    try std.testing.expect(!try hasStage(&repo, moved, 2));
    try std.testing.expect(try hasStage(&repo, moved, 3));
}

test "zero heads is rejected before any write" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    try std.testing.expectError(error.NoMergeHeads, merge.merge(&repo, &.{}, .{}));
}

test "virtual base of a criss-cross is a content conflict" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "base\n" }});
    const left = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "left\n" }});
    const right = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "right\n" }});
    const from_left = try commitFiles(&repo, &.{ left, right }, &.{.{ .path = "f.txt", .body = "fromLeft\n" }});
    try setHead(&repo, from_left);
    const from_right = try commitFiles(&repo, &.{ right, left }, &.{.{ .path = "f.txt", .body = "fromRight\n" }});
    const result = try merge.merge(&repo, &.{from_right}, .{ .message = "m\n", .strategy = .ort });
    try std.testing.expect(!result.clean);
    const body = try readFile(&repo, "f.txt");
    defer gpa.free(body);
    var hex: [plumbing.MaxHexSize]u8 = undefined;
    const expect = try std.fmt.allocPrint(gpa, "<<<<<<< HEAD\nfromLeft\n=======\nfromRight\n>>>>>>> {s}\n", .{from_right.string(&hex)});
    defer gpa.free(expect);
    try std.testing.expectEqualStrings(expect, body);
}

test "already up to date writes nothing" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\n" }});
    const head = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "b\n" }});
    try setHead(&repo, head);
    const result = try merge.merge(&repo, &.{base}, .{ .message = "m\n" });
    try std.testing.expect(result.clean);
    try std.testing.expect(result.commit == null);
    const body = try readFile(&repo, "f.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("b\n", body);
    const mh = try gitText(&repo, "MERGE_HEAD");
    defer if (mh) |b| gpa.free(b);
    try std.testing.expect(mh == null);
    try std.testing.expect((try readHead(&repo)).eql(head));
}

test "no-commit does not stop a fast-forward" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\n" }});
    try setHead(&repo, base);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "b\n" }});
    const result = try merge.merge(&repo, &.{side}, .{ .no_commit = true });
    try std.testing.expect(result.clean);
    try std.testing.expect(result.commit == null);
    try std.testing.expect((try readHead(&repo)).eql(side));
    const body = try readFile(&repo, "f.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("b\n", body);
    const mh = try gitText(&repo, "MERGE_HEAD");
    defer if (mh) |b| gpa.free(b);
    try std.testing.expect(mh == null);
}

test "favor ours keeps a separated edit from the other side" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\nb\nc\nd\ne\nf\ng\nh\ni\n" }});
    try setHead(&repo, base);
    const ours = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nX\nc\nd\ne\nf\ng\nh\ni\n" }});
    try setHead(&repo, ours);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nY\nc\nd\ne\nf\ng\nh\nZ\n" }});
    const result = try merge.merge(&repo, &.{side}, .{ .message = "m\n", .favor = .ours });
    try std.testing.expect(result.clean);
    const body = try readFile(&repo, "f.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("a\nX\nc\nd\ne\nf\ng\nh\nZ\n", body);
}

test "diff3 style names the abbreviated merge base" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\nb\nc\n" }});
    try setHead(&repo, base);
    const ours = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nX\nc\n" }});
    try setHead(&repo, ours);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nY\nc\n" }});
    const result = try merge.merge(&repo, &.{side}, .{ .message = "m\n", .conflict_style = .diff3 });
    try std.testing.expect(!result.clean);
    const body = try readFile(&repo, "f.txt");
    defer gpa.free(body);
    var base_hex: [plumbing.MaxHexSize]u8 = undefined;
    var side_hex: [plumbing.MaxHexSize]u8 = undefined;
    const expect = try std.fmt.allocPrint(
        gpa,
        "a\n<<<<<<< HEAD\nX\n||||||| {s}\nb\n=======\nY\n>>>>>>> {s}\nc\n",
        .{ base.string(&base_hex)[0..7], side.string(&side_hex) },
    );
    defer gpa.free(expect);
    try std.testing.expectEqualStrings(expect, body);
}

test "a binary attribute skips the text merge and keeps ours" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\n" }});
    try setHead(&repo, base);
    const ours = try commitFiles(&repo, &.{base}, &.{
        .{ .path = ".gitattributes", .body = "f.txt binary\n" },
        .{ .path = "f.txt", .body = "a\nX\n" },
    });
    try setHead(&repo, ours);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nY\n" }});
    const result = try merge.merge(&repo, &.{side}, .{ .message = "m\n" });
    try std.testing.expect(!result.clean);
    const body = try readFile(&repo, "f.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("a\nX\n", body);
}

test "a provided identity and label are recorded on the merge" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\nb\nc\nd\n" }});
    try setHead(&repo, base);
    const ours = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nX\nc\nd\n" }});
    try setHead(&repo, ours);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "a\nb\nc\nY\n" }});
    const who = merge.Identity{ .name = "Ada", .email = "ada@example.test", .when = 1_700_000_000, .tz_offset_minutes = 60 };
    const result = try merge.merge(&repo, &.{side}, .{
        .message = "m\n",
        .author = who,
        .committer = who,
    });
    const commit = try obj.getCommit(gpa, repo.storer, result.commit.?);
    defer obj.freeCommit(gpa, commit);
    try std.testing.expectEqualStrings("Ada", commit.author.name);
    try std.testing.expectEqualStrings("ada@example.test", commit.author.email);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), commit.author.when);
    try std.testing.expectEqual(@as(i16, 60), commit.author.tz_offset_minutes);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), commit.committer.when);

    var marked = try initRepo(gpa);
    defer marked.deinit();
    const marked_base = try commitFiles(&marked, &.{}, &.{.{ .path = "f.txt", .body = "a\nb\nc\n" }});
    try setHead(&marked, marked_base);
    const marked_ours = try commitFiles(&marked, &.{marked_base}, &.{.{ .path = "f.txt", .body = "a\nX\nc\n" }});
    try setHead(&marked, marked_ours);
    const marked_side = try commitFiles(&marked, &.{marked_base}, &.{.{ .path = "f.txt", .body = "a\nb\nY\n" }});
    const conflicted = try merge.merge(&marked, &.{marked_side}, .{
        .message = "m\n",
        .theirs_label = "side",
    });
    try std.testing.expect(!conflicted.clean);
    const body = try readFile(&marked, "f.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("a\n<<<<<<< HEAD\nX\nc\n=======\nb\nY\n>>>>>>> side\n", body);
}

test "file and symlink stay on different paths" {
    const gpa = std.testing.allocator;
    var repo = try initRepo(gpa);
    defer repo.deinit();
    const base = try commitFiles(&repo, &.{}, &.{.{ .path = "f.txt", .body = "a\n" }});
    try setHead(&repo, base);
    const ours = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "tgt", .mode = filemode.Symlink }});
    try setHead(&repo, ours);
    const side = try commitFiles(&repo, &.{base}, &.{.{ .path = "f.txt", .body = "b\n" }});
    const result = try merge.merge(&repo, &.{side}, .{ .message = "m\n" });
    try std.testing.expect(!result.clean);
    const link = try repo.filesystem.readlink("f.txt");
    defer repo.filesystem.allocator.free(link);
    try std.testing.expectEqualStrings("tgt", link);
    var hex: [plumbing.MaxHexSize]u8 = undefined;
    const moved = try std.fmt.allocPrint(gpa, "f.txt~{s}", .{side.string(&hex)});
    defer gpa.free(moved);
    const file = try readFile(&repo, moved);
    defer gpa.free(file);
    try std.testing.expectEqualStrings("b\n", file);
}
