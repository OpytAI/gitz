//! Tree walks and object writes shared by the merge engine.
//! Content-addressed blobs, trees, and temporary commits may be stored and
//! then abandoned. That does not move refs.

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const obj = @import("object");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const FileMode = filemode.FileMode;

pub const Leaf = struct {
    mode: FileMode,
    hash: Hash,
};

pub const LeafMap = struct {
    map: std.StringHashMapUnmanaged(Leaf) = .empty,

    pub fn deinit(self: *LeafMap, allocator: Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        self.map.deinit(allocator);
        self.* = undefined;
    }

    pub fn put(self: *LeafMap, allocator: Allocator, path: []const u8, leaf: Leaf) !void {
        if (self.map.getPtr(path)) |slot| {
            slot.* = leaf;
            return;
        }
        const key = try allocator.dupe(u8, path);
        errdefer allocator.free(key);
        try self.map.put(allocator, key, leaf);
    }

    pub fn get(self: *const LeafMap, path: []const u8) ?Leaf {
        return self.map.get(path);
    }
};

pub fn walkTree(allocator: Allocator, s: anytype, tree_hash: Hash, into: *LeafMap) !void {
    if (tree_hash.isZero()) return;
    try walkPrefix(allocator, s, tree_hash, "", into);
}

fn walkPrefix(allocator: Allocator, s: anytype, tree_hash: Hash, prefix: []const u8, into: *LeafMap) !void {
    const tree = try obj.getTree(allocator, s, tree_hash);
    defer obj.freeTree(allocator, tree);
    for (tree.entries.items) |e| {
        const path = if (prefix.len == 0)
            try allocator.dupe(u8, e.name)
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, e.name });
        if (e.mode == filemode.Dir) {
            defer allocator.free(path);
            const child_prefix = try std.fmt.allocPrint(allocator, "{s}/", .{path});
            defer allocator.free(child_prefix);
            try walkPrefix(allocator, s, e.hash, child_prefix, into);
        } else {
            errdefer allocator.free(path);
            if (into.map.getPtr(path)) |slot| {
                slot.* = .{ .mode = e.mode, .hash = e.hash };
                allocator.free(path);
            } else {
                try into.map.put(allocator, path, .{ .mode = e.mode, .hash = e.hash });
            }
        }
    }
}

pub fn storeBlob(s: anytype, content: []const u8) !Hash {
    const obj_enc = try s.newEncodedObject();
    errdefer s.discardEncodedObject(obj_enc);
    obj_enc.setType(.blob);
    try obj_enc.setContent(content);
    return try s.setEncodedObject(obj_enc);
}

pub fn blobBytes(allocator: Allocator, s: anytype, hash: Hash) ![]u8 {
    const blob = try obj.getBlob(s, hash);
    return try allocator.dupe(u8, blob.readerBytes());
}

pub fn emptyTree(allocator: Allocator, s: anytype) !Hash {
    var tree = obj.Tree.init(allocator, null);
    defer tree.deinit();
    tree.sortEntries();
    return try putTree(s, &tree);
}

pub const TreeItem = struct {
    path: []const u8,
    mode: FileMode,
    hash: Hash,
};

pub fn storeTree(allocator: Allocator, s: anytype, items: []const TreeItem) !Hash {
    return storeDir(allocator, s, items, "");
}

fn storeDir(allocator: Allocator, s: anytype, items: []const TreeItem, prefix: []const u8) !Hash {
    var tree = obj.Tree.init(allocator, null);
    defer tree.deinit();
    var i: usize = 0;
    while (i < items.len) {
        const rel = items[i].path[prefix.len..];
        if (std.mem.indexOfScalar(u8, rel, '/')) |slash| {
            const name = rel[0..slash];
            const next = prefix.len + slash + 1;
            var j = i + 1;
            while (j < items.len and items[j].path.len >= next and std.mem.startsWith(u8, items[j].path, items[i].path[0..next])) : (j += 1) {}
            const sub = try storeDir(allocator, s, items[i..j], items[i].path[0..next]);
            try tree.appendEntry(name, filemode.Dir, sub);
            i = j;
        } else {
            try tree.appendEntry(rel, items[i].mode, items[i].hash);
            i += 1;
        }
    }
    tree.sortEntries();
    return try putTree(s, &tree);
}

fn putTree(s: anytype, tree: *obj.Tree) !Hash {
    const enc = try s.newEncodedObject();
    errdefer s.discardEncodedObject(enc);
    try tree.encode(enc);
    return try s.setEncodedObject(enc);
}

/// Commit object used only so a later `mergeBase` can see a virtual tree.
/// The object is safe to abandon.
pub fn storeTempCommit(allocator: Allocator, s: anytype, tree_hash: Hash, parents: []const Hash) !Hash {
    var c = obj.Commit.init(allocator);
    c.tree_hash = tree_hash;
    c.message = "virtual merge base\n";
    c.author = .{ .name = "gitz", .email = "gitz@local", .when = 0, .tz_offset_minutes = 0 };
    c.committer = c.author;
    const parent_copy = try allocator.dupe(Hash, parents);
    defer allocator.free(parent_copy);
    c.parent_hashes = parent_copy;
    const enc = try s.newEncodedObject();
    errdefer s.discardEncodedObject(enc);
    try c.encode(enc);
    c.parent_hashes = &.{};
    c.message = "";
    c.author = .{};
    c.committer = .{};
    return try s.setEncodedObject(enc);
}

/// Wrap `inner` so it sits at `prefix` (one or more path components).
pub fn shiftTree(allocator: Allocator, s: anytype, inner: Hash, prefix: []const u8) !Hash {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);
    var rest = prefix;
    while (rest.len > 0) {
        if (std.mem.indexOfScalar(u8, rest, '/')) |i| {
            if (i == 0) return error.StrategyOptionNotSupported;
            try parts.append(allocator, rest[0..i]);
            rest = rest[i + 1 ..];
        } else {
            try parts.append(allocator, rest);
            break;
        }
    }
    if (parts.items.len == 0) return error.StrategyOptionNotSupported;
    var current = inner;
    var n = parts.items.len;
    while (n > 0) {
        n -= 1;
        var tree = obj.Tree.init(allocator, null);
        defer tree.deinit();
        try tree.appendEntry(parts.items[n], filemode.Dir, current);
        tree.sortEntries();
        current = try putTree(s, &tree);
    }
    return current;
}
