//! Index-backed merkletrie noders (go-git `utils/merkletrie/index/node.go`).

const std = @import("std");
const noder = @import("noder");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const index_fmt = @import("index");

const Allocator = std.mem.Allocator;
const Noder = noder.Noder;
const Index = index_fmt.Index;
const Entry = index_fmt.Entry;

/// Root node owning the whole tree built from an index (go-git `NewRootNode`).
pub const Root = struct {
    root: *Node,
    /// All nodes including root; freed on deinit.
    all: std.ArrayList(*Node),
    allocator: Allocator,

    pub fn deinit(self: *Root) void {
        for (self.all.items) |n| {
            n.deinit(self.allocator);
        }
        self.all.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn noder(self: *Root) Noder {
        return self.root.asNoder();
    }
};

pub const Node = struct {
    path: []u8,
    /// When non-null, this is a file entry (not a computed directory).
    entry: ?*const Entry = null,
    children_list: std.ArrayList(*Node) = .empty,
    is_dir: bool = false,
    skip_worktree: bool = false,
    /// Memoized 24-byte hash (oid + mode LE).
    hash_buf: [24]u8 = .{0} ** 24,
    hash_ready: bool = false,
    allocator: Allocator,

    fn deinit(self: *Node, allocator: Allocator) void {
        // children pointers are owned by Root.all; only free the list shell.
        self.children_list.deinit(allocator);
        allocator.free(self.path);
        allocator.destroy(self);
    }

    pub fn asNoder(self: *Node) Noder {
        return noder.noderOf(Node, self);
    }

    pub fn hash(self: *Node) []const u8 {
        if (!self.hash_ready) {
            if (self.entry == null) {
                @memset(&self.hash_buf, 0);
            } else {
                const e = self.entry.?;
                @memcpy(self.hash_buf[0..plumbing.Size], e.hash.bytes[0..]);
                const mb = filemode.bytes(e.mode);
                @memcpy(self.hash_buf[plumbing.Size..][0..4], &mb);
            }
            self.hash_ready = true;
        }
        return self.hash_buf[0..];
    }

    pub fn name(self: *Node) []const u8 {
        return pathBase(self.path);
    }

    pub fn isDir(self: *Node) bool {
        return self.is_dir;
    }

    pub fn children(self: *Node, allocator: Allocator) anyerror![]Noder {
        const out = try allocator.alloc(Noder, self.children_list.items.len);
        for (self.children_list.items, 0..) |c, i| {
            out[i] = c.asNoder();
        }
        return out;
    }

    pub fn numChildren(self: *Node) anyerror!usize {
        return self.children_list.items.len;
    }

    pub fn skip(self: *Node) bool {
        return self.skip_worktree;
    }

    pub fn string(self: *Node, allocator: Allocator) anyerror![]u8 {
        return try allocator.dupe(u8, self.path);
    }
};

/// Build root node from index (go-git `NewRootNode`).
pub fn newRootNode(allocator: Allocator, idx: *const Index) Allocator.Error!Root {
    var all: std.ArrayList(*Node) = .empty;
    errdefer {
        for (all.items) |n| n.deinit(allocator);
        all.deinit(allocator);
    }

    var map: std.StringHashMapUnmanaged(*Node) = .empty;
    defer {
        // keys are node.path (owned by nodes) or ""; map does not own keys.
        map.deinit(allocator);
    }

    const root_node = try createNode(allocator, "", true, null, false);
    try all.append(allocator, root_node);
    try map.put(allocator, "", root_node);

    for (idx.entries.items) |*e| {
        var parent_path: []const u8 = "";
        var fullpath_buf: std.ArrayList(u8) = .empty;
        defer fullpath_buf.deinit(allocator);

        var parts = std.mem.splitScalar(u8, e.name, '/');
        while (parts.next()) |part| {
            if (part.len == 0) continue;
            // fullpath = join(parent, part)
            fullpath_buf.clearRetainingCapacity();
            if (parent_path.len > 0) {
                try fullpath_buf.appendSlice(allocator, parent_path);
                try fullpath_buf.append(allocator, '/');
            }
            try fullpath_buf.appendSlice(allocator, part);
            const fullpath = fullpath_buf.items;

            if (map.get(fullpath)) |existing| {
                // If any child is not skip-worktree, clear skip up the lineage.
                if (!e.skip_worktree) {
                    existing.skip_worktree = false;
                }
                parent_path = existing.path;
                continue;
            }

            const is_file = std.mem.eql(u8, fullpath, e.name);
            const n = try createNode(
                allocator,
                fullpath,
                !is_file,
                if (is_file) e else null,
                e.skip_worktree,
            );
            try all.append(allocator, n);
            try map.put(allocator, n.path, n);

            const parent = map.get(parent_path).?;
            try parent.children_list.append(allocator, n);

            parent_path = n.path;
        }
    }

    return .{
        .root = root_node,
        .all = all,
        .allocator = allocator,
    };
}

fn createNode(
    allocator: Allocator,
    path: []const u8,
    is_dir: bool,
    entry: ?*const Entry,
    skip: bool,
) Allocator.Error!*Node {
    const n = try allocator.create(Node);
    errdefer allocator.destroy(n);
    n.* = .{
        .path = try allocator.dupe(u8, path),
        .entry = entry,
        .is_dir = is_dir,
        .skip_worktree = skip,
        .allocator = allocator,
    };
    return n;
}

fn pathBase(p: []const u8) []const u8 {
    if (p.len == 0) return ".";
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| {
        return p[i + 1 ..];
    }
    return p;
}

// ---------------------------------------------------------------------------
// Tests (go-git index/node_test.go)
// ---------------------------------------------------------------------------

const merkletrie = @import("merkletrie");

const empty_hash = [_]u8{0} ** 24;

fn isEquals(a: Noder, b: Noder) bool {
    const ah = a.hash();
    const bh = b.hash();
    if (ah.len == 24 and std.mem.eql(u8, ah, &empty_hash)) return false;
    if (bh.len == 24 and std.mem.eql(u8, bh, &empty_hash)) return false;
    return std.mem.eql(u8, ah, bh);
}

fn sampleHash() plumbing.Hash {
    return plumbing.newHash("8ab686eafeb1f44702738c8b0f24f2567c36da6d");
}

fn addEntry(idx: *Index, name: []const u8, hash: plumbing.Hash, skip: bool) !void {
    const e = try idx.add(name);
    e.hash = hash;
    e.mode = filemode.Regular;
    e.skip_worktree = skip;
}

test "index Diff identical" {
    const a = std.testing.allocator;
    var index_a = Index.init(a);
    defer index_a.deinit();
    var index_b = Index.init(a);
    defer index_b.deinit();
    const h = sampleHash();
    try addEntry(&index_a, "foo", h, false);
    try addEntry(&index_a, "bar/foo", h, false);
    try addEntry(&index_a, "bar/qux", h, false);
    try addEntry(&index_a, "bar/baz/foo", h, false);
    try addEntry(&index_b, "foo", h, false);
    try addEntry(&index_b, "bar/foo", h, false);
    try addEntry(&index_b, "bar/qux", h, false);
    try addEntry(&index_b, "bar/baz/foo", h, false);

    var ra = try newRootNode(a, &index_a);
    defer ra.deinit();
    var rb = try newRootNode(a, &index_b);
    defer rb.deinit();

    var ch = try merkletrie.diffTree(a, ra.noder(), rb.noder(), isEquals);
    defer ch.deinit();
    try std.testing.expectEqual(@as(usize, 0), ch.items.items.len);
}

test "index Diff change path" {
    const a = std.testing.allocator;
    var index_a = Index.init(a);
    defer index_a.deinit();
    var index_b = Index.init(a);
    defer index_b.deinit();
    const h = sampleHash();
    try addEntry(&index_a, "bar/baz/bar", h, false);
    try addEntry(&index_b, "bar/baz/foo", h, false);

    var ra = try newRootNode(a, &index_a);
    defer ra.deinit();
    var rb = try newRootNode(a, &index_b);
    defer rb.deinit();

    var ch = try merkletrie.diffTree(a, ra.noder(), rb.noder(), isEquals);
    defer ch.deinit();
    try std.testing.expectEqual(@as(usize, 2), ch.items.items.len);
}

test "index Diff skip worktree issue 1455" {
    const a = std.testing.allocator;
    var index_a = Index.init(a);
    defer index_a.deinit();
    var index_b = Index.init(a);
    defer index_b.deinit();
    const h = sampleHash();
    try addEntry(&index_a, "bar/baz/bar", h, true);
    try addEntry(&index_a, "bar/biz/bat", h, false);

    var ra = try newRootNode(a, &index_a);
    defer ra.deinit();
    var rb = try newRootNode(a, &index_b);
    defer rb.deinit();

    // Diff empty → index_a: only non-skip insert
    var ch = try merkletrie.diffTree(a, rb.noder(), ra.noder(), isEquals);
    defer ch.deinit();
    try std.testing.expectEqual(@as(usize, 1), ch.items.items.len);
    try std.testing.expectEqual(merkletrie.Action.insert, try ch.items.items[0].action());
}

test "index Diff file vs dir" {
    const a = std.testing.allocator;
    var index_a = Index.init(a);
    defer index_a.deinit();
    var index_b = Index.init(a);
    defer index_b.deinit();
    const h = sampleHash();
    try addEntry(&index_a, "foo", h, false);
    try addEntry(&index_b, "foo/bar", h, false);

    var ra = try newRootNode(a, &index_a);
    defer ra.deinit();
    var rb = try newRootNode(a, &index_b);
    defer rb.deinit();

    var ch = try merkletrie.diffTree(a, ra.noder(), rb.noder(), isEquals);
    defer ch.deinit();
    try std.testing.expectEqual(@as(usize, 2), ch.items.items.len);
}

test "index Diff same root hash change" {
    const a = std.testing.allocator;
    var index_a = Index.init(a);
    defer index_a.deinit();
    var index_b = Index.init(a);
    defer index_b.deinit();
    try addEntry(&index_a, "foo.go", plumbing.newHash("aab686eafeb1f44702738c8b0f24f2567c36da6d"), false);
    try addEntry(&index_a, "foo/bar", sampleHash(), false);
    try addEntry(&index_b, "foo/bar", sampleHash(), false);
    try addEntry(&index_b, "foo.go", sampleHash(), false);

    var ra = try newRootNode(a, &index_a);
    defer ra.deinit();
    var rb = try newRootNode(a, &index_b);
    defer rb.deinit();

    var ch = try merkletrie.diffTree(a, ra.noder(), rb.noder(), isEquals);
    defer ch.deinit();
    try std.testing.expectEqual(@as(usize, 1), ch.items.items.len);
}
