//! objectWalker — mark every object reachable from refs (go-git `object_walker.go`).
//!
//! Used by prune instead of revlist so memory stays tight on huge repos: a
//! simple hash set of seen OIDs, with a blob-mode shortcut that avoids decoding
//! plain file objects.

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const object = @import("object");
const memory = @import("memory");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Storage = memory.Storage;
const FileMode = filemode.FileMode;

/// Set of object hashes already visited (go-git `map[plumbing.Hash]struct{}`).
pub const SeenSet = std.AutoHashMapUnmanaged(Hash, void);

/// go-git `objectWalker`.
///
/// Walks hash refs and their object graphs, recording every reachable OID in
/// `seen`. Caller must `deinit`.
pub const ObjectWalker = struct {
    allocator: Allocator,
    storer: *Storage,
    seen: SeenSet = .empty,

    /// go-git `newObjectWalker`.
    pub fn init(allocator: Allocator, storer: *Storage) ObjectWalker {
        return .{
            .allocator = allocator,
            .storer = storer,
        };
    }

    pub fn deinit(self: *ObjectWalker) void {
        self.seen.deinit(self.allocator);
        self.* = undefined;
    }

    /// go-git `objectWalker.isSeen`.
    pub fn isSeen(self: *const ObjectWalker, hash: Hash) bool {
        return self.seen.contains(hash);
    }

    /// go-git `objectWalker.add`.
    pub fn add(self: *ObjectWalker, hash: Hash) Allocator.Error!void {
        try self.seen.put(self.allocator, hash, {});
    }

    /// Walk all hash references in the storer (go-git `walkAllRefs`).
    /// Symbolic refs are skipped (same as go-git).
    pub fn walkAllRefs(self: *ObjectWalker) anyerror!void {
        var it = try self.storer.iterReferences();
        defer it.deinit();
        while (true) {
            const ref = it.next() catch |err| switch (err) {
                error.EndOfStream => return,
            };
            if (ref.type != .hash) continue;
            try self.walkObjectTree(ref.hash);
        }
    }

    /// Walk the object graph rooted at `hash` (go-git `walkObjectTree`).
    ///
    /// - commit → tree + parents
    /// - tree → entries (blob modes shortcut-mark without decode)
    /// - tag → target
    /// - blob / other decoded as object type without a case → `error.UnknownObjectType`
    pub fn walkObjectTree(self: *ObjectWalker, hash: Hash) anyerror!void {
        if (self.isSeen(hash)) return;
        try self.add(hash);

        var obj = object.getObject(self.allocator, self.storer, hash) catch |err| {
            // go-git wraps: "getting object %s failed: %v"
            return err;
        };
        defer obj.deinit(self.allocator);

        switch (obj) {
            .commit => |c| {
                try self.walkObjectTree(c.tree_hash);
                for (c.parent_hashes) |ph| {
                    try self.walkObjectTree(ph);
                }
            },
            .tree => |t| {
                for (t.entries.items) |entry| {
                    // Blob shortcut (go-git): mode|0755 == Executable marks
                    // regular / executable files without decoding the blob.
                    if (isBlobModeShortcut(entry.mode)) {
                        try self.add(entry.hash);
                        continue;
                    }
                    try self.walkObjectTree(entry.hash);
                }
            },
            .tag => |tag| {
                try self.walkObjectTree(tag.target);
            },
            .blob => {
                // go-git default branch: unknown object type for *object.Blob.
                return error.UnknownObjectType;
            },
        }
    }
};

/// go-git `newObjectWalker`.
pub fn newObjectWalker(allocator: Allocator, storer: *Storage) ObjectWalker {
    return ObjectWalker.init(allocator, storer);
}

/// True when tree entry mode is a plain file (regular or executable).
///
/// go-git: `Mode|0755 == filemode.Executable`.
fn isBlobModeShortcut(mode: FileMode) bool {
    return (mode | 0o755) == filemode.Executable;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn storeBlob(s: *Storage, content: []const u8) !Hash {
    const obj = try s.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write(content);
    return s.setEncodedObject(obj);
}

fn appendTreeEntry(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    mode_octal: []const u8,
    name: []const u8,
    hash: Hash,
) !void {
    try buf.appendSlice(allocator, mode_octal);
    try buf.append(allocator, ' ');
    try buf.appendSlice(allocator, name);
    try buf.append(allocator, 0);
    try buf.appendSlice(allocator, hash.slice());
}

fn storeTree(s: *Storage, allocator: Allocator, entries: []const struct {
    mode: []const u8,
    name: []const u8,
    hash: Hash,
}) !Hash {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (entries) |e| {
        try appendTreeEntry(&buf, allocator, e.mode, e.name, e.hash);
    }
    const obj = try s.newEncodedObject();
    obj.setType(.tree);
    _ = try obj.write(buf.items);
    return s.setEncodedObject(obj);
}

fn storeCommit(
    s: *Storage,
    allocator: Allocator,
    tree: Hash,
    parents: []const Hash,
    message: []const u8,
) !Hash {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var tree_hex: [plumbing.MaxHexSize]u8 = undefined;
    try buf.appendSlice(allocator, "tree ");
    try buf.appendSlice(allocator, tree.string(&tree_hex));
    try buf.append(allocator, '\n');

    for (parents) |p| {
        var p_hex: [plumbing.MaxHexSize]u8 = undefined;
        try buf.appendSlice(allocator, "parent ");
        try buf.appendSlice(allocator, p.string(&p_hex));
        try buf.append(allocator, '\n');
    }

    try buf.appendSlice(allocator, "author Test <test@example.com> 1000000000 +0000\n");
    try buf.appendSlice(allocator, "committer Test <test@example.com> 1000000000 +0000\n");
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, message);

    const obj = try s.newEncodedObject();
    obj.setType(.commit);
    _ = try obj.write(buf.items);
    return s.setEncodedObject(obj);
}

fn storeTag(
    s: *Storage,
    allocator: Allocator,
    target: Hash,
    target_type: []const u8,
    name: []const u8,
) !Hash {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var hex: [plumbing.MaxHexSize]u8 = undefined;
    try buf.appendSlice(allocator, "object ");
    try buf.appendSlice(allocator, target.string(&hex));
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, "type ");
    try buf.appendSlice(allocator, target_type);
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, "tag ");
    try buf.appendSlice(allocator, name);
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, "tagger Test <test@example.com> 1000000000 +0000\n");
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, "tag message\n");

    const obj = try s.newEncodedObject();
    obj.setType(.tag);
    _ = try obj.write(buf.items);
    return s.setEncodedObject(obj);
}

test "isBlobModeShortcut regular and executable" {
    try std.testing.expect(isBlobModeShortcut(filemode.Regular));
    try std.testing.expect(isBlobModeShortcut(filemode.Executable));
    try std.testing.expect(!isBlobModeShortcut(filemode.Dir));
    try std.testing.expect(!isBlobModeShortcut(filemode.Symlink));
    try std.testing.expect(!isBlobModeShortcut(filemode.Submodule));
    try std.testing.expect(!isBlobModeShortcut(filemode.Deprecated));
}

test "walker marks reachable commit tree blob from hash ref" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const blob = try storeBlob(s, "hello-prune");
    const tree = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "f.txt", .hash = blob },
    });
    const commit = try storeCommit(s, allocator, tree, &.{}, "msg");

    try s.setReference(plumbing.Reference.newHashReference(plumbing.master, commit));

    var walker = newObjectWalker(allocator, s);
    defer walker.deinit();
    try walker.walkAllRefs();

    try std.testing.expect(walker.isSeen(commit));
    try std.testing.expect(walker.isSeen(tree));
    try std.testing.expect(walker.isSeen(blob));
}

test "walker follows parents and skips symbolic refs" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const blob0 = try storeBlob(s, "v0");
    const blob1 = try storeBlob(s, "v1");
    const tree0 = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "a", .hash = blob0 },
    });
    const tree1 = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "a", .hash = blob1 },
    });
    const c0 = try storeCommit(s, allocator, tree0, &.{}, "first");
    const c1 = try storeCommit(s, allocator, tree1, &.{c0}, "second");

    // HEAD is symbolic → must not start a walk by itself.
    try s.setReference(plumbing.Reference.newSymbolicReference(
        plumbing.HEAD,
        plumbing.master,
    ));
    try s.setReference(plumbing.Reference.newHashReference(plumbing.master, c1));

    var walker = ObjectWalker.init(allocator, s);
    defer walker.deinit();
    try walker.walkAllRefs();

    try std.testing.expect(walker.isSeen(c1));
    try std.testing.expect(walker.isSeen(c0));
    try std.testing.expect(walker.isSeen(tree1));
    try std.testing.expect(walker.isSeen(tree0));
    try std.testing.expect(walker.isSeen(blob1));
    try std.testing.expect(walker.isSeen(blob0));
}

test "walker peels annotated tag to commit" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const blob = try storeBlob(s, "tagged-blob");
    const tree = try storeTree(s, allocator, &.{
        .{ .mode = "100755", .name = "bin", .hash = blob },
    });
    const commit = try storeCommit(s, allocator, tree, &.{}, "tagged");
    const tag = try storeTag(s, allocator, commit, "commit", "v1");

    try s.setReference(plumbing.Reference.newHashReference(
        plumbing.ReferenceName.init("refs/tags/v1"),
        tag,
    ));

    var walker = newObjectWalker(allocator, s);
    defer walker.deinit();
    try walker.walkAllRefs();

    try std.testing.expect(walker.isSeen(tag));
    try std.testing.expect(walker.isSeen(commit));
    try std.testing.expect(walker.isSeen(tree));
    try std.testing.expect(walker.isSeen(blob));
}

test "walker nested tree walks subtree" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const leaf = try storeBlob(s, "nested");
    const sub = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "inner", .hash = leaf },
    });
    const root_tree = try storeTree(s, allocator, &.{
        .{ .mode = "040000", .name = "dir", .hash = sub },
    });
    const commit = try storeCommit(s, allocator, root_tree, &.{}, "nest");

    try s.setReference(plumbing.Reference.newHashReference(plumbing.master, commit));

    var walker = newObjectWalker(allocator, s);
    defer walker.deinit();
    try walker.walkAllRefs();

    try std.testing.expect(walker.isSeen(commit));
    try std.testing.expect(walker.isSeen(root_tree));
    try std.testing.expect(walker.isSeen(sub));
    try std.testing.expect(walker.isSeen(leaf));
}

test "walker does not mark unreachable loose object" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const reachable = try storeBlob(s, "keep");
    const orphan = try storeBlob(s, "drop-me");
    const tree = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "f", .hash = reachable },
    });
    const commit = try storeCommit(s, allocator, tree, &.{}, "keep");

    try s.setReference(plumbing.Reference.newHashReference(plumbing.master, commit));

    var walker = newObjectWalker(allocator, s);
    defer walker.deinit();
    try walker.walkAllRefs();

    try std.testing.expect(walker.isSeen(reachable));
    try std.testing.expect(!walker.isSeen(orphan));
}

test "walkObjectTree on bare blob yields UnknownObjectType" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const blob = try storeBlob(s, "alone");
    var walker = newObjectWalker(allocator, s);
    defer walker.deinit();
    // go-git: default case after GetObject returns *Blob.
    try std.testing.expectError(error.UnknownObjectType, walker.walkObjectTree(blob));
    // Hash is still marked seen before the type switch fails.
    try std.testing.expect(walker.isSeen(blob));
}
