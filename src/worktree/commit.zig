//! Worktree.Commit — port of go-git `worktree_commit.go`.
//!
//! Stages the index into tree object(s), builds a commit, and updates HEAD.
//! Pin: go-git v5.19.2.

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const objpkg = @import("object");
const memory = @import("memory");
const index_fmt = @import("index");
const storer = @import("storer");
const fs_pkg = @import("fs");

const error_mod = @import("error.zig");
const options_mod = @import("options.zig");
const worktree_mod = @import("worktree.zig");
const util = @import("util.zig");
const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const Reference = plumbing.Reference;
const Signature = objpkg.Signature;
const Commit = objpkg.Commit;
const Tree = objpkg.Tree;
const MemoryObject = plumbing.MemoryObject;
const CommitOptions = options_mod.CommitOptions;
const Index = index_fmt.Index;
const Entry = index_fmt.Entry;
const FileMode = filemode.FileMode;

// Characters stripped from author/committer name and email (go-git `invalidCharactersRe`).
// See https://git-scm.com/docs/git-commit#_commit_information
fn sanitizeIdentityPart(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        if (c == '<' or c == '>' or c == '\n') continue;
        try out.append(allocator, c);
    }
    return try out.toOwnedSlice(allocator);
}

/// go-git `Worktree.Commit`.
pub fn commit(w: anytype, msg: []const u8, o: CommitOptions) !Hash {
    try o.validate();

    var author_opt = o.author;
    var committer_opt = o.committer;

    // Resolve author/committer from config when Author is unset (go-git Validate).
    if (author_opt == null) {
        try loadConfigAuthorAndCommitter(w, &author_opt, &committer_opt);
    }
    if (committer_opt == null) {
        committer_opt = author_opt;
    }
    const author = author_opt orelse return error_mod.Error.MissingAuthor;
    const committer = committer_opt orelse author;

    // Parents: default HEAD; amend replaces with first parent of HEAD commit.
    var parent_buf: [1]Hash = undefined;
    var parents: []const Hash = o.parents;

    if (o.amend) {
        const head_ref = try util.resolveReference(w.storer, plumbing.HEAD);
        defer w.storer.freeReference(head_ref);
        const head_commit = try objpkg.getCommit(w.allocator, w.storer, head_ref.hash);
        defer {
            head_commit.deinit();
            w.allocator.destroy(head_commit);
        }
        if (head_commit.parent_hashes.len != 0) {
            parent_buf[0] = head_commit.parent_hashes[0];
            parents = parent_buf[0..1];
        } else {
            parents = &.{};
        }
    } else if (parents.len == 0) {
        if (util.resolveReference(w.storer, plumbing.HEAD)) |head_ref| {
            defer w.storer.freeReference(head_ref);
            parent_buf[0] = head_ref.hash;
            parents = parent_buf[0..1];
        } else |err| switch (err) {
            error.ReferenceNotFound => {},
            else => return err,
        }
    }

    if (o.all) {
        try autoAddModifiedAndDeleted(w);
    }

    const idx = try w.storer.index();

    // First commit with empty index is empty (go-git early check).
    if (parents.len == 0 and idx.entries.items.len == 0 and !o.allow_empty_commits) {
        return error_mod.Error.EmptyCommit;
    }

    const tree_hash = try buildTreeFromIndex(w.allocator, w.storer, idx);

    var previous_tree = ZeroHash;
    if (parents.len > 0) {
        const parent_commit = try objpkg.getCommit(w.allocator, w.storer, parents[0]);
        defer {
            parent_commit.deinit();
            w.allocator.destroy(parent_commit);
        }
        previous_tree = parent_commit.tree_hash;
    }

    if (tree_hash.eql(previous_tree) and !o.allow_empty_commits) {
        return error_mod.Error.EmptyCommit;
    }

    const commit_hash = try buildCommitObject(
        w,
        msg,
        author,
        committer,
        parents,
        tree_hash,
        o.signer,
        o.sign_key,
    );
    try updateHEAD(w, commit_hash);
    return commit_hash;
}

/// Load Author / Committer / User identity from memory config (go-git
/// `CommitOptions.loadConfigAuthorAndCommitter` + Author-then-User order).
fn loadConfigAuthorAndCommitter(
    w: anytype,
    author: *?Signature,
    committer: *?Signature,
) !void {
    const cfg = try w.storer.config();
    const Storage = @TypeOf(w.storer.*);
    const when = if (comptime @hasDecl(Storage, "now"))
        w.storer.now().sec
    else
        return error_mod.Error.MissingAuthor;

    if (author.* == null and cfg.author_email.len != 0 and cfg.author_name.len != 0) {
        author.* = .{
            .name = cfg.author_name,
            .email = cfg.author_email,
            .when = when,
            .tz_offset_minutes = 0,
        };
    }

    if (committer.* == null and cfg.committer_email.len != 0 and cfg.committer_name.len != 0) {
        committer.* = .{
            .name = cfg.committer_name,
            .email = cfg.committer_email,
            .when = when,
            .tz_offset_minutes = 0,
        };
    }

    if (author.* == null and cfg.user_email.len != 0 and cfg.user_name.len != 0) {
        author.* = .{
            .name = cfg.user_name,
            .email = cfg.user_email,
            .when = when,
            .tz_offset_minutes = 0,
        };
    }

    if (author.* == null) return error_mod.Error.MissingAuthor;
}

/// go-git `Worktree.autoAddModifiedAndDeleted` — stage modified/deleted index paths.
///
/// Re-stats each index entry against the worktree (same effect as status + doAddFile
/// for Modified/Deleted). Untracked files are not added (`CommitOptions.All`).
fn autoAddModifiedAndDeleted(w: anytype) !void {
    const idx = try w.storer.index();

    var remove_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (remove_paths.items) |p| w.allocator.free(p);
        remove_paths.deinit(w.allocator);
    }

    for (idx.entries.items) |*e| {
        const info = w.filesystem.stat(e.name) catch {
            // Missing → deleted; stage removal.
            try remove_paths.append(w.allocator, try w.allocator.dupe(u8, e.name));
            continue;
        };

        // Symlinks: read link target as blob content (go-git add symlink path).
        const content = try readWorktreePath(w, e.name, info);
        defer w.allocator.free(content);

        const blob_hash = try storeBlob(w.storer, content);
        const mode = modeFromFileInfo(info);

        if (!blob_hash.eql(e.hash) or e.mode != mode) {
            e.hash = blob_hash;
            e.mode = mode;
            e.size = @intCast(content.len);
            e.modified_at = index_fmt.Time.unix(info.mtime_sec, 0);
        }
    }

    for (remove_paths.items) |p| {
        var rem = idx.remove(p) catch continue;
        rem.deinit(w.allocator);
    }

    // Stamp mod_time like go-git SetIndex after auto-add.
    try util.setIndex(w.storer, idx);
}

fn readWorktreePath(w: anytype, path: []const u8, info: fs_pkg.FileInfo) ![]u8 {
    if (info.isSymlink()) {
        return try w.filesystem.readlink(path);
    }
    var f = try w.filesystem.open(path);
    defer f.close() catch {};
    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(w.allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try f.read(buf[0..]);
        if (n == 0) break;
        try content.appendSlice(w.allocator, buf[0..n]);
    }
    return try content.toOwnedSlice(w.allocator);
}

fn modeFromFileInfo(info: fs_pkg.FileInfo) FileMode {
    if (info.isSymlink()) return filemode.Symlink;
    if (info.isDir()) return filemode.Dir;
    const perms = info.mode & 0o777;
    if (perms & 0o111 != 0) return filemode.Executable;
    return filemode.Regular;
}

fn storeBlob(s: anytype, content: []const u8) !Hash {
    const obj = try s.newEncodedObject();
    errdefer {
        obj.deinit();
        s.allocator.destroy(obj);
    }
    obj.setType(.blob);
    try obj.setContent(content);
    return try s.setEncodedObject(obj);
}

/// go-git `Worktree.updateHEAD`.
fn updateHEAD(w: anytype, commit_hash: Hash) !void {
    const head = try w.storer.reference(plumbing.HEAD);
    defer w.storer.freeReference(head);
    const name = if (head.type != .hash) head.target else plumbing.HEAD;
    const ref = Reference.newHashReference(name, commit_hash);
    try w.storer.setReference(ref);
}

/// go-git `Worktree.buildCommitObject` (+ sanitize + optional OpenPGP sign).
fn buildCommitObject(
    w: anytype,
    msg: []const u8,
    author: Signature,
    committer: Signature,
    parents: []const Hash,
    tree_hash: Hash,
    signer: ?options_mod.Signer,
    sign_key: ?*objpkg.Entity,
) !Hash {
    const allocator = w.allocator;

    const a_name = try sanitizeIdentityPart(allocator, author.name);
    defer allocator.free(a_name);
    const a_email = try sanitizeIdentityPart(allocator, author.email);
    defer allocator.free(a_email);
    const c_name = try sanitizeIdentityPart(allocator, committer.name);
    defer allocator.free(c_name);
    const c_email = try sanitizeIdentityPart(allocator, committer.email);
    defer allocator.free(c_email);

    var c = Commit.init(allocator);
    // Borrowed slices live for this function (defer frees + msg from caller).
    c.author = .{
        .name = a_name,
        .email = a_email,
        .when = author.when,
        .tz_offset_minutes = author.tz_offset_minutes,
    };
    c.committer = .{
        .name = c_name,
        .email = c_email,
        .when = committer.when,
        .tz_offset_minutes = committer.tz_offset_minutes,
    };
    c.message = msg;
    c.tree_hash = tree_hash;
    // parent_hashes: Commit.deinit frees when non-empty; use a stack-owned dupe
    // only if we need to transfer — encode only reads the slice, so borrow.
    var parents_copy: []Hash = &.{};
    if (parents.len > 0) {
        parents_copy = try allocator.dupe(Hash, parents);
    }
    defer if (parents_copy.len > 0) allocator.free(parents_copy);
    c.parent_hashes = parents_copy;

    var pgp_owned: ?[]u8 = null;
    defer if (pgp_owned) |p| allocator.free(p);

    if (signer) |custom| {
        var unsigned = MemoryObject.init(allocator);
        defer unsigned.deinit();
        try c.encodeWithoutSignature(&unsigned);
        const sig = try custom.sign(allocator, unsigned.readerBytes());
        pgp_owned = sig;
        c.pgp_signature = sig;
    } else if (sign_key) |key| {
        var unsigned = MemoryObject.init(allocator);
        defer unsigned.deinit();
        try c.encodeWithoutSignature(&unsigned);
        const signing_time = std.math.cast(u32, committer.when) orelse return error.InvalidTimestamp;
        const sig = try objpkg.armoredDetachSignAt(allocator, key, unsigned.readerBytes(), signing_time);
        pgp_owned = sig;
        c.pgp_signature = sig;
    }

    const obj = try w.storer.newEncodedObject();
    errdefer {
        obj.deinit();
        w.storer.allocator.destroy(obj);
    }
    try c.encode(obj);
    // Clear parent_hashes before Commit would free it — we own via defer.
    c.parent_hashes = &.{};
    c.pgp_signature = "";
    c.message = "";
    c.author = .{};
    c.committer = .{};
    return try w.storer.setEncodedObject(obj);
}

// ---------------------------------------------------------------------------
// buildTreeFromIndex (go-git `buildTreeHelper`)
// ---------------------------------------------------------------------------

/// Build tree object(s) from index entries and store them. Returns root tree hash.
/// go-git `buildTreeHelper.BuildTree`.
pub fn buildTreeFromIndex(allocator: Allocator, s: anytype, idx: *const Index) !Hash {
    const Storage = @TypeOf(s.*);
    var h = BuildTreeHelper(Storage){
        .allocator = allocator,
        .s = s,
    };
    defer h.deinit();

    try h.trees.put(allocator, try allocator.dupe(u8, ""), try createEmptyTree(allocator));

    for (idx.entries.items) |*e| {
        try h.commitIndexEntry(e);
    }

    const root = h.trees.get("").?;
    return try h.copyTreeToStorageRecursive("", root);
}

fn BuildTreeHelper(comptime Storage: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        s: *Storage,
        /// Path → tree being built (owned keys and trees).
        trees: std.StringHashMapUnmanaged(*Tree) = .empty,
        /// Paths already registered as entries (owned keys).
        entry_seen: std.StringHashMapUnmanaged(void) = .empty,

        fn deinit(self: *Self) void {
            var tit = self.trees.iterator();
            while (tit.next()) |e| {
                e.value_ptr.*.deinit();
                self.allocator.destroy(e.value_ptr.*);
                self.allocator.free(e.key_ptr.*);
            }
            self.trees.deinit(self.allocator);

            var eit = self.entry_seen.iterator();
            while (eit.next()) |e| {
                self.allocator.free(e.key_ptr.*);
            }
            self.entry_seen.deinit(self.allocator);
            self.* = undefined;
        }

        fn commitIndexEntry(self: *Self, e: *const Entry) !void {
            // Walk path components: parent/fullpath like go-git path.Join chain.
            var fullpath: std.ArrayList(u8) = .empty;
            defer fullpath.deinit(self.allocator);

            var it = std.mem.splitScalar(u8, e.name, '/');
            while (it.next()) |part| {
                if (part.len == 0) continue;

                const parent = try self.allocator.dupe(u8, fullpath.items);
                defer self.allocator.free(parent);

                if (fullpath.items.len > 0) try fullpath.append(self.allocator, '/');
                try fullpath.appendSlice(self.allocator, part);

                try self.doBuildTree(e, parent, fullpath.items);
            }
        }

        fn doBuildTree(self: *Self, e: *const Entry, parent: []const u8, fullpath: []const u8) !void {
            if (self.trees.contains(fullpath)) return;
            if (self.entry_seen.contains(fullpath)) return;

            const base = pathBase(fullpath);
            const is_leaf = std.mem.eql(u8, fullpath, e.name);

            const parent_tree = self.trees.get(parent).?;

            if (is_leaf) {
                try parent_tree.appendEntry(base, e.mode, e.hash);
                const key = try self.allocator.dupe(u8, fullpath);
                errdefer self.allocator.free(key);
                try self.entry_seen.put(self.allocator, key, {});
            } else {
                try parent_tree.appendEntry(base, filemode.Dir, ZeroHash);
                const key = try self.allocator.dupe(u8, fullpath);
                errdefer self.allocator.free(key);
                const t = try createEmptyTree(self.allocator);
                errdefer {
                    t.deinit();
                    self.allocator.destroy(t);
                }
                try self.trees.put(self.allocator, key, t);
            }
        }

        fn copyTreeToStorageRecursive(self: *Self, parent: []const u8, t: *Tree) !Hash {
            t.sortEntries();
            for (t.entries.items) |*ent| {
                // Skip non-dir entries that already have a blob/submodule hash.
                if (ent.mode != filemode.Dir and !ent.hash.isZero()) continue;

                var child_path_buf: std.ArrayList(u8) = .empty;
                defer child_path_buf.deinit(self.allocator);
                if (parent.len > 0) {
                    try child_path_buf.appendSlice(self.allocator, parent);
                    try child_path_buf.append(self.allocator, '/');
                }
                try child_path_buf.appendSlice(self.allocator, ent.name);
                const child_path = child_path_buf.items;

                const child_tree = self.trees.get(child_path).?;
                ent.hash = try self.copyTreeToStorageRecursive(child_path, child_tree);
            }

            // Re-sort after hash fills (order unchanged, but ensure flag).
            t.sortEntries();

            const o = try self.s.newEncodedObject();
            errdefer {
                o.deinit();
                self.s.allocator.destroy(o);
            }
            try t.encode(o);

            const hash = o.hash();
            if (self.s.hasEncodedObject(hash)) |_| {
                o.deinit();
                self.s.allocator.destroy(o);
                return hash;
            } else |_| {
                return try self.s.setEncodedObject(o);
            }
        }
    };
}

fn createEmptyTree(allocator: Allocator) Allocator.Error!*Tree {
    const t = try allocator.create(Tree);
    t.* = Tree.init(allocator, null);
    return t;
}

fn pathBase(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        return path[i + 1 ..];
    }
    return path;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn defaultSignature() Signature {
    // go-git defaultSignature: "Thu May 04 00:03:43 2017 +0200"
    return .{
        .name = "foo",
        .email = "foo@foo.foo",
        .when = 1493841823,
        .tz_offset_minutes = 120,
    };
}

fn stageFile(w: anytype, path: []const u8, content: []const u8, mode: FileMode) !void {
    // Write worktree file.
    var f = try w.filesystem.create(path);
    _ = try f.write(content);
    try f.close();

    const h = try storeBlob(w.storer, content);
    const idx = try w.storer.index();
    // Replace existing entry if any.
    if (idx.entry(path)) |existing| {
        existing.hash = h;
        existing.mode = mode;
        existing.size = @intCast(content.len);
    } else |_| {
        const e = try idx.add(path);
        e.hash = h;
        e.mode = mode;
        e.size = @intCast(content.len);
    }
    try util.setIndex(w.storer, idx);
}

test "commit initial: object fields and HEAD branch" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem_fs = try fs_pkg.Mem.init(gpa);
    defer mem_fs.deinit();

    try sto.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

    var w = worktree_mod.newWorktree(gpa, sto, &mem_fs);
    try stageFile(&w, "foo", "foo", filemode.Regular);

    const h = try commit(&w, "foo\n", .{ .author = defaultSignature() });
    try std.testing.expect(!h.isZero());

    // HEAD (branch) points at commit.
    const master = try sto.reference(plumbing.master);
    try std.testing.expect(master.type == .hash);
    try std.testing.expect(master.hash.eql(h));

    const c = try objpkg.getCommit(gpa, sto, h);
    defer {
        c.deinit();
        gpa.destroy(c);
    }
    try std.testing.expectEqualStrings("foo", c.author.name);
    try std.testing.expectEqualStrings("foo@foo.foo", c.author.email);
    try std.testing.expectEqual(@as(i64, 1493841823), c.author.when);
    try std.testing.expectEqualStrings("foo\n", c.message);
    try std.testing.expectEqual(@as(usize, 0), c.parent_hashes.len);
    try std.testing.expect(!c.tree_hash.isZero());
}

test "commit empty tree without allow_empty fails" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem_fs = try fs_pkg.Mem.init(gpa);
    defer mem_fs.deinit();
    try sto.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

    var w = worktree_mod.newWorktree(gpa, sto, &mem_fs);
    try std.testing.expectError(
        error_mod.Error.EmptyCommit,
        commit(&w, "failed empty commit\n", .{ .author = defaultSignature() }),
    );
}

test "commit empty tree with allow_empty" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem_fs = try fs_pkg.Mem.init(gpa);
    defer mem_fs.deinit();
    try sto.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

    var w = worktree_mod.newWorktree(gpa, sto, &mem_fs);
    const h = try commit(&w, "enable empty commits\n", .{
        .author = defaultSignature(),
        .allow_empty_commits = true,
    });
    try std.testing.expect(!h.isZero());
}

test "commit with parent and nested path tree" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem_fs = try fs_pkg.Mem.init(gpa);
    defer mem_fs.deinit();
    try sto.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

    var w = worktree_mod.newWorktree(gpa, sto, &mem_fs);
    try stageFile(&w, "dir/sub/a.txt", "hello", filemode.Regular);

    const h1 = try commit(&w, "first\n", .{ .author = defaultSignature() });
    try std.testing.expect(!h1.isZero());

    // Second commit: add another file, parent should be h1.
    try stageFile(&w, "dir/sub/b.txt", "world", filemode.Regular);
    const h2 = try commit(&w, "second\n", .{ .author = defaultSignature() });

    const c2 = try objpkg.getCommit(gpa, sto, h2);
    defer {
        c2.deinit();
        gpa.destroy(c2);
    }
    try std.testing.expectEqual(@as(usize, 1), c2.parent_hashes.len);
    try std.testing.expect(c2.parent_hashes[0].eql(h1));
    try std.testing.expectEqualStrings("second\n", c2.message);

    // Tree has nested structure dir/sub/{a,b}.
    const tree = try c2.tree();
    defer objpkg.freeTree(gpa, tree);
    try std.testing.expect(tree.entries.items.len >= 1);
}

test "commit author from user config when options omit author" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem_fs = try fs_pkg.Mem.init(gpa);
    defer mem_fs.deinit();
    try sto.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

    const cfg = try sto.config();
    try cfg.setUser("Config User", "user@example.com");

    var w = worktree_mod.newWorktree(gpa, sto, &mem_fs);
    try stageFile(&w, "x", "x", filemode.Regular);

    const h = try commit(&w, "cfg\n", .{});
    const c = try objpkg.getCommit(gpa, sto, h);
    defer {
        c.deinit();
        gpa.destroy(c);
    }
    try std.testing.expectEqualStrings("Config User", c.author.name);
    try std.testing.expectEqualStrings("user@example.com", c.author.email);
}

test "commit missing author is error" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem_fs = try fs_pkg.Mem.init(gpa);
    defer mem_fs.deinit();
    try sto.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

    var w = worktree_mod.newWorktree(gpa, sto, &mem_fs);
    try stageFile(&w, "x", "x", filemode.Regular);
    try std.testing.expectError(error_mod.Error.MissingAuthor, commit(&w, "m\n", .{}));
}

test "commit sanitizes invalid characters in signature" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem_fs = try fs_pkg.Mem.init(gpa);
    defer mem_fs.deinit();
    try sto.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

    var w = worktree_mod.newWorktree(gpa, sto, &mem_fs);
    try stageFile(&w, "y", "y", filemode.Regular);

    const h = try commit(&w, "s\n", .{
        .author = .{
            .name = "foo <bad>\n",
            .email = "<bad>\nfoo@foo.foo",
            .when = 1493841823,
            .tz_offset_minutes = 120,
        },
    });
    const c = try objpkg.getCommit(gpa, sto, h);
    defer {
        c.deinit();
        gpa.destroy(c);
    }
    try std.testing.expectEqualStrings("foo bad", c.author.name);
    try std.testing.expectEqualStrings("badfoo@foo.foo", c.author.email);
}

test "generic signer signs unsigned commit" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem_fs = try fs_pkg.Mem.init(gpa);
    defer mem_fs.deinit();
    try sto.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

    const Callback = struct {
        fn sign(_: ?*anyopaque, allocator: Allocator, message: []const u8) anyerror![]u8 {
            try std.testing.expect(std.mem.indexOf(u8, message, "tree ") != null);
            try std.testing.expect(std.mem.indexOf(u8, message, "gpgsig ") == null);
            return allocator.dupe(u8, "custom-signature");
        }
    };

    var w = worktree_mod.newWorktree(gpa, sto, &mem_fs);
    try stageFile(&w, "signed.txt", "payload", filemode.Regular);
    const h = try commit(&w, "signed\n", .{
        .author = defaultSignature(),
        .signer = .{ .sign_fn = Callback.sign },
    });

    const c = try objpkg.getCommit(gpa, sto, h);
    defer {
        c.deinit();
        gpa.destroy(c);
    }
    // go-git's commit scanner appends a newline to each decoded gpgsig line.
    // The encoder trims one trailing newline before writing, so this is the
    // canonical decode result even when Signer returned no newline.
    try std.testing.expectEqualStrings("custom-signature\n", c.pgp_signature);
}

test "buildTreeFromIndex empty index is empty tree" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    const idx = try sto.index();
    const h = try buildTreeFromIndex(gpa, sto, idx);
    const empty = plumbing.computeHash(.tree, "");
    try std.testing.expect(h.eql(empty));
}

test "buildTreeFromIndex nested paths" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    const blob = try storeBlob(sto, "data");
    const idx = try sto.index();
    const e1 = try idx.add("a/b/c.txt");
    e1.hash = blob;
    e1.mode = filemode.Regular;
    const e2 = try idx.add("a/d.txt");
    e2.hash = blob;
    e2.mode = filemode.Regular;

    const root_h = try buildTreeFromIndex(gpa, sto, idx);
    try std.testing.expect(!root_h.isZero());

    const root = try objpkg.getTree(gpa, sto, root_h);
    defer objpkg.freeTree(gpa, root);
    try std.testing.expectEqual(@as(usize, 1), root.entries.items.len);
    try std.testing.expectEqualStrings("a", root.entries.items[0].name);
    try std.testing.expectEqual(filemode.Dir, root.entries.items[0].mode);
}

test "autoAdd modified then commit" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem_fs = try fs_pkg.Mem.init(gpa);
    defer mem_fs.deinit();
    try sto.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

    var w = worktree_mod.newWorktree(gpa, sto, &mem_fs);
    try stageFile(&w, "f", "v1", filemode.Regular);
    const h1 = try commit(&w, "one\n", .{ .author = defaultSignature() });

    // Modify worktree file without updating index; commit with All.
    var f = try mem_fs.openFile("f", fs_pkg.O.RDWR | fs_pkg.O.TRUNC, 0o666);
    _ = try f.write("v2");
    try f.close();

    const h2 = try commit(&w, "two\n", .{
        .author = defaultSignature(),
        .all = true,
    });
    try std.testing.expect(!h2.eql(h1));

    const c1 = try objpkg.getCommit(gpa, sto, h1);
    defer {
        c1.deinit();
        gpa.destroy(c1);
    }
    const c2 = try objpkg.getCommit(gpa, sto, h2);
    defer {
        c2.deinit();
        gpa.destroy(c2);
    }
    try std.testing.expect(!c2.tree_hash.eql(c1.tree_hash));
    try std.testing.expect(c2.parent_hashes[0].eql(h1));
}

test "commit same tree as parent is EmptyCommit" {
    const gpa = std.testing.allocator;
    var sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    var mem_fs = try fs_pkg.Mem.init(gpa);
    defer mem_fs.deinit();
    try sto.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

    var w = worktree_mod.newWorktree(gpa, sto, &mem_fs);
    try stageFile(&w, "z", "z", filemode.Regular);
    _ = try commit(&w, "once\n", .{ .author = defaultSignature() });

    try std.testing.expectError(
        error_mod.Error.EmptyCommit,
        commit(&w, "again\n", .{ .author = defaultSignature() }),
    );
}
