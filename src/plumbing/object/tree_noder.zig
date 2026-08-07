//! Tree as merkletrie noder (go-git `plumbing/object/treenoder.go`).
//!
//! Wraps git trees so `merkletrie.DiffTree` can walk them. Mode is folded into
//! the noder hash (OID bytes + 4 mode LE bytes = 24) so mode-only changes
//! appear as content modifications, matching `git diff-tree`.

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const noder = @import("noder");
const tree_mod = @import("tree.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const FileMode = filemode.FileMode;
const Tree = tree_mod.Tree;
const Noder = noder.Noder;

/// Session for one DiffTree walk: arena-backed TreeNoders.
///
/// Loaded subtrees are installed into the **root** tree's `path_cache` so they
/// live as long as that root (same lifetime model as go-git's `Tree.t` map).
/// Session deinit only frees arena TreeNoders — never the caller's trees.
pub const TreeNoderSession = struct {
    arena: std.heap.ArenaAllocator,
    /// Allocator for getTree heap trees (not the arena).
    gpa: Allocator,

    pub fn init(gpa: Allocator) TreeNoderSession {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *TreeNoderSession) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *TreeNoderSession) Allocator {
        return self.arena.allocator();
    }
};

/// go-git `treeNoder` — merkletrie noder over a git tree entry (or root).
pub const TreeNoder = struct {
    /// Containing tree (immediate parent of this entry). Root is its own parent.
    /// Null for empty (nil tree) root.
    parent: ?*Tree,
    /// DiffTree-side root tree (for path_cache installs + long-lived ChangeEntry.tree).
    /// Same as `parent` for the root node; null only for nil empty root.
    root: ?*Tree,
    /// Basename; empty string for the root node. Borrowed from Tree entries or "".
    name_s: []const u8,
    mode: FileMode,
    oid: Hash,
    /// Full path from DiffTree root to this node ("" for root). Arena-owned.
    /// Used as path_cache key when installing loaded subtrees.
    full_path: []const u8 = "",
    /// OID (20) + mode LE (4). Filled on first `hash()`.
    hash_buf: [24]u8 = undefined,
    hash_ready: bool = false,
    /// Memoized child TreeNoders (arena-owned).
    children_memo: ?[]*TreeNoder = null,
    session: *TreeNoderSession,

    pub fn asNoder(self: *TreeNoder) Noder {
        return noder.noderOf(TreeNoder, self);
    }

    pub fn isRoot(self: *const TreeNoder) bool {
        return self.name_s.len == 0;
    }

    pub fn hash(self: *TreeNoder) []const u8 {
        if (!self.hash_ready) {
            @memcpy(self.hash_buf[0..plumbing.Size], self.oid.bytes[0..]);
            const mode_for_hash: FileMode = if (self.mode == filemode.Deprecated)
                filemode.Regular
            else
                self.mode;
            const mb = filemode.bytes(mode_for_hash);
            @memcpy(self.hash_buf[plumbing.Size..][0..4], &mb);
            self.hash_ready = true;
        }
        return self.hash_buf[0..];
    }

    pub fn name(self: *const TreeNoder) []const u8 {
        return self.name_s;
    }

    pub fn isDir(self: *const TreeNoder) bool {
        return self.mode == filemode.Dir;
    }

    pub fn skip(_: *const TreeNoder) bool {
        return false;
    }

    pub fn string(self: *TreeNoder, allocator: Allocator) anyerror![]u8 {
        return try std.fmt.allocPrint(allocator, "treeNoder <{s}>", .{self.name_s});
    }

    pub fn children(self: *TreeNoder, allocator: Allocator) anyerror![]Noder {
        if (self.mode != filemode.Dir) return noder.no_children;

        const kids = try self.ensureChildren();
        if (kids.len == 0) return noder.no_children;

        const out = try allocator.alloc(Noder, kids.len);
        for (kids, 0..) |k, i| {
            out[i] = k.asNoder();
        }
        return out;
    }

    pub fn numChildren(self: *TreeNoder) anyerror!usize {
        if (self.mode != filemode.Dir) return 0;
        const kids = try self.ensureChildren();
        return kids.len;
    }

    fn ensureChildren(self: *TreeNoder) anyerror![]*TreeNoder {
        if (self.children_memo) |m| return m;

        if (self.mode != filemode.Dir) {
            self.children_memo = &.{};
            return self.children_memo.?;
        }

        // Root: walk self.parent (the root tree). Non-root: load sub-tree.
        const parent_tree: ?*Tree = blk: {
            if (self.parent == null) break :blk null;
            if (self.isRoot()) break :blk self.parent;
            break :blk try self.loadSubTree();
        };

        if (parent_tree == null) {
            self.children_memo = &.{};
            return self.children_memo.?;
        }

        self.children_memo = try transformChildren(self.session, self, parent_tree.?);
        return self.children_memo.?;
    }

    fn loadSubTree(self: *TreeNoder) anyerror!*Tree {
        const containing = self.parent orelse return error.ObjectNotFound;
        const root = self.root orelse return error.ObjectNotFound;
        const s = containing.storer orelse return error.ObjectNotFound;

        // Reuse root path_cache (go-git `Tree.t`) so ChangeEntry.tree stays valid
        // after DiffTree returns (session only frees arena noders).
        if (self.full_path.len > 0) {
            if (root.path_cache.get(self.full_path)) |cached| return cached;
        }

        const loaded = try tree_mod.getTree(self.session.gpa, s, self.oid);
        errdefer tree_mod.freeTree(self.session.gpa, loaded);

        if (self.full_path.len > 0) {
            const key = try root.allocator.dupe(u8, self.full_path);
            errdefer root.allocator.free(key);
            if (root.path_cache.getEntry(key)) |existing| {
                // Another path already cached this key — free duplicate load, use cache.
                root.allocator.free(key);
                tree_mod.freeTree(self.session.gpa, loaded);
                return existing.value_ptr.*;
            }
            try root.path_cache.put(root.allocator, key, loaded);
        }
        return loaded;
    }
};

/// go-git `NewTreeRootNode`.
pub fn newTreeRootNode(session: *TreeNoderSession, t: ?*Tree) !*TreeNoder {
    const aa = session.allocator();
    const node = try aa.create(TreeNoder);
    if (t) |tree| {
        node.* = .{
            .parent = tree,
            .root = tree,
            .name_s = "",
            .mode = filemode.Dir,
            .oid = tree.hash,
            .full_path = "",
            .session = session,
        };
    } else {
        node.* = .{
            .parent = null,
            .root = null,
            .name_s = "",
            .mode = filemode.Empty,
            .oid = ZeroHash,
            .full_path = "",
            .session = session,
        };
    }
    return node;
}

/// Build child TreeNoders from a tree's entries (go-git `transformChildren`).
/// Non-recursive: one level only. Empty dirs and submodules are included as
/// entries (submodules are not dirs; empty dirs expand to no file changes).
fn transformChildren(session: *TreeNoderSession, parent_noder: *TreeNoder, t: *Tree) Allocator.Error![]*TreeNoder {
    const aa = session.allocator();
    var list: std.ArrayList(*TreeNoder) = .empty;
    errdefer list.deinit(aa);

    try list.ensureTotalCapacity(aa, t.entries.items.len);
    for (t.entries.items) |e| {
        const child_path = try joinChildPath(aa, parent_noder.full_path, e.name);
        const child = try aa.create(TreeNoder);
        child.* = .{
            .parent = t,
            .root = parent_noder.root,
            .name_s = e.name,
            .mode = e.mode,
            .oid = e.hash,
            .full_path = child_path,
            .session = session,
        };
        try list.append(aa, child);
    }
    return try list.toOwnedSlice(aa);
}

fn joinChildPath(allocator: Allocator, parent_path: []const u8, name: []const u8) Allocator.Error![]u8 {
    if (parent_path.len == 0) return try allocator.dupe(u8, name);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent_path, name });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "TreeNoder hash includes mode bytes" {
    const gpa = std.testing.allocator;
    var session = TreeNoderSession.init(gpa);
    defer session.deinit();

    const aa = session.allocator();
    const node = try aa.create(TreeNoder);
    var oid: Hash = ZeroHash;
    oid.bytes[0] = 0xaa;
    oid.bytes[1] = 0xaa;
    node.* = .{
        .parent = null,
        .root = null,
        .name_s = "f",
        .mode = filemode.Regular,
        .oid = oid,
        .full_path = "f",
        .session = &session,
    };

    const h = node.hash();
    try std.testing.expectEqual(@as(usize, 24), h.len);
    try std.testing.expectEqual(@as(u8, 0xaa), h[0]);
    try std.testing.expectEqual(@as(u8, 0xaa), h[1]);
    const mb = filemode.bytes(filemode.Regular);
    try std.testing.expectEqualSlices(u8, &mb, h[20..24]);
}

test "TreeNoder Deprecated mode uses Regular bytes in hash" {
    const gpa = std.testing.allocator;
    var session = TreeNoderSession.init(gpa);
    defer session.deinit();

    const aa = session.allocator();
    const node = try aa.create(TreeNoder);
    node.* = .{
        .parent = null,
        .root = null,
        .full_path = "",
        .name_s = "f",
        .mode = filemode.Deprecated,
        .oid = ZeroHash,
        .session = &session,
    };
    const h = node.hash();
    const mb = filemode.bytes(filemode.Regular);
    try std.testing.expectEqualSlices(u8, &mb, h[20..24]);
}

test "NewTreeRootNode nil is empty non-dir" {
    const gpa = std.testing.allocator;
    var session = TreeNoderSession.init(gpa);
    defer session.deinit();

    const root = try newTreeRootNode(&session, null);
    try std.testing.expect(root.isRoot());
    try std.testing.expect(!root.isDir());
    try std.testing.expectEqual(@as(usize, 0), try root.numChildren());
    const ch = try root.children(gpa);
    defer if (ch.len > 0) gpa.free(ch);
    try std.testing.expectEqual(@as(usize, 0), ch.len);
}

test "NewTreeRootNode children from flat tree" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");
    const storer = @import("storer");

    var store = memory.Storage.init(gpa);
    defer store.deinit();
    const blob = try store.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write("hi");
    const bh = try store.setEncodedObject(blob);

    var tree = Tree.init(gpa, storer.ObjectGetter.from(memory.Storage, &store));
    defer tree.deinit();
    try tree.appendEntry("a.txt", filemode.Regular, bh);
    try tree.appendEntry("b.txt", filemode.Executable, bh);
    tree.sortEntries();

    var session = TreeNoderSession.init(gpa);
    defer session.deinit();

    const root = try newTreeRootNode(&session, &tree);
    try std.testing.expect(root.isDir());
    try std.testing.expectEqual(@as(usize, 2), try root.numChildren());
    const ch = try root.children(gpa);
    defer gpa.free(ch);
    try std.testing.expectEqual(@as(usize, 2), ch.len);
    try std.testing.expectEqualStrings("a.txt", ch[0].name());
    try std.testing.expectEqualStrings("b.txt", ch[1].name());
    try std.testing.expect(!ch[0].isDir());
}

