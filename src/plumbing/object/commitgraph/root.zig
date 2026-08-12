//! plumbing/object/commitgraph — CommitNode over storer + format index.
//!
//! Port of go-git v5.19.2 `plumbing/object/commitgraph`.
//!
//! # Surface
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `CommitNode` | `CommitNode` (type-erased) |
//! | `CommitNodeIndex` | `CommitNodeIndex` |
//! | `CommitNodeIter` | `CommitNodeIter` |
//! | `NewObjectCommitNodeIndex` | `newObjectCommitNodeIndex` |
//! | `NewGraphCommitNodeIndex` | `newGraphCommitNodeIndex` / `newGraphCommitNodeIndexFrom` |
//! | `NewCommitNodeIterCTime` | `newCommitNodeIterCTime` |
//! | `NewCommitNodeIterDateOrder` | `newCommitNodeIterDateOrder` |
//! | `NewCommitNodeIterTopoOrder` | `newCommitNodeIterTopoOrder` |
//! | `NewCommitNodeIterAuthorDateOrder` | `newCommitNodeIterAuthorDateOrder` |

const std = @import("std");
const plumbing = @import("plumbing");
const object = @import("object");
const commitgraph = @import("commitgraph");
const memory = @import("memory");

const commitnode_mod = @import("commitnode.zig");
const object_mod = @import("commitnode_object.zig");
const graph_mod = @import("commitnode_graph.zig");
const walker_mod = @import("commitnode_walker.zig");

pub const CommitNode = commitnode_mod.CommitNode;
pub const CommitNodeIndex = commitnode_mod.CommitNodeIndex;
pub const CommitNodeIter = commitnode_mod.CommitNodeIter;
pub const ParentCommitNodeIter = commitnode_mod.ParentCommitNodeIter;
pub const max_generation = commitnode_mod.max_generation;
pub const whenUnixSeconds = commitnode_mod.whenUnixSeconds;

pub const ObjectCommitNode = object_mod.ObjectCommitNode;
pub const ObjectCommitNodeIndex = object_mod.ObjectCommitNodeIndex;
pub const newObjectCommitNodeIndex = object_mod.newObjectCommitNodeIndex;

pub const GraphCommitNode = graph_mod.GraphCommitNode;
pub const GraphCommitNodeIndex = graph_mod.GraphCommitNodeIndex;
pub const GraphIndex = graph_mod.GraphIndex;
pub const newGraphCommitNodeIndex = graph_mod.newGraphCommitNodeIndex;
pub const newGraphCommitNodeIndexFrom = graph_mod.newGraphCommitNodeIndexFrom;

pub const CommitNodeIterCTime = walker_mod.CommitNodeIterCTime;
pub const CommitNodeIterTopological = walker_mod.CommitNodeIterTopological;
pub const newCommitNodeIterCTime = walker_mod.newCommitNodeIterCTime;
pub const newCommitNodeIterDateOrder = walker_mod.newCommitNodeIterDateOrder;
pub const newCommitNodeIterTopoOrder = walker_mod.newCommitNodeIterTopoOrder;
pub const newCommitNodeIterAuthorDateOrder = walker_mod.newCommitNodeIterAuthorDateOrder;
pub const generationAndDateOrderCompare = walker_mod.generationAndDateOrderCompare;

test {
    _ = commitnode_mod;
    _ = object_mod;
    _ = graph_mod;
    _ = walker_mod;
}

// ---------------------------------------------------------------------------
// Helpers for unit tests (memory storer + commit encode)
// ---------------------------------------------------------------------------

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Storage = memory.Storage;

fn storeCommit(
    allocator: Allocator,
    s: *Storage,
    tree_hash: Hash,
    parents: []const Hash,
    when: i64,
    message: []const u8,
) !Hash {
    var c = object.Commit.init(allocator);
    defer c.deinit();
    c.tree_hash = tree_hash;
    // Signature.deinit frees name/email only when owned=true.
    c.author = .{
        .name = try allocator.dupe(u8, "A"),
        .email = try allocator.dupe(u8, "a@example.com"),
        .when = when,
        .tz_offset_minutes = 0,
        .owned = true,
    };
    c.committer = .{
        .name = try allocator.dupe(u8, "A"),
        .email = try allocator.dupe(u8, "a@example.com"),
        .when = when,
        .tz_offset_minutes = 0,
        .owned = true,
    };
    c.message = try allocator.dupe(u8, message);
    if (parents.len > 0) {
        c.parent_hashes = try allocator.dupe(Hash, parents);
    }

    const obj = try s.newEncodedObject();
    try c.encode(obj);
    return s.setEncodedObject(obj);
}

fn storeEmptyTree(s: *Storage) !Hash {
    // Empty tree object content is empty bytes.
    const obj = try s.newEncodedObject();
    obj.setType(.tree);
    try obj.setContent(&.{});
    return s.setEncodedObject(obj);
}

test "ObjectCommitNodeIndex parents and ctime walk" {
    const gpa = std.testing.allocator;

    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    const tree_h = try storeEmptyTree(s);

    // Linear history: c0 <- c1 <- c2 (c2 newest).
    const h0 = try storeCommit(gpa, s, tree_h, &.{}, 1000, "root\n");
    const h1 = try storeCommit(gpa, s, tree_h, &.{h0}, 2000, "mid\n");
    const h2 = try storeCommit(gpa, s, tree_h, &.{h1}, 3000, "tip\n");

    const index = try newObjectCommitNodeIndex(gpa, Storage, s);
    defer index.deinit();

    const tip = try index.get(h2);
    defer tip.deinit();

    try std.testing.expect(tip.id().eql(h2));
    try std.testing.expectEqual(@as(usize, 1), tip.numParents());
    try std.testing.expectEqual(@as(i64, 3000), tip.commitTimeSec());
    try std.testing.expectEqual(max_generation, tip.generation());
    try std.testing.expectEqual(max_generation, tip.generationV2());

    // ParentNodes
    var parents: std.ArrayList(Hash) = .empty;
    defer parents.deinit(gpa);
    var piter = tip.parentNodes();
    defer piter.close();
    while (true) {
        const p = piter.next() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        try parents.append(gpa, p.id());
        p.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), parents.items.len);
    try std.testing.expect(parents.items[0].eql(h1));

    // Full commit load (always heap-owned)
    const full = try tip.commit();
    defer object.freeCommit(gpa, full);
    try std.testing.expect(full.id().eql(h2));
    try std.testing.expectEqualStrings("tip\n", full.message);

    // Tree
    const tree = try tip.tree();
    defer {
        tree.deinit();
        gpa.destroy(tree);
    }
    try std.testing.expect(tree.hash.eql(tree_h));

    // CTime walk tip → … → root
    const start = try index.get(h2);
    const iter = try newCommitNodeIterCTime(gpa, start, null, &.{});
    defer iter.close();

    var walked: std.ArrayList(Hash) = .empty;
    defer walked.deinit(gpa);
    while (true) {
        const n = iter.next() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        try walked.append(gpa, n.id());
        n.deinit();
    }
    try std.testing.expectEqual(@as(usize, 3), walked.items.len);
    try std.testing.expect(walked.items[0].eql(h2));
    try std.testing.expect(walked.items[1].eql(h1));
    try std.testing.expect(walked.items[2].eql(h0));
}

test "GraphCommitNodeIndex memory graph + object fallback" {
    const gpa = std.testing.allocator;

    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    const tree_h = try storeEmptyTree(s);
    const h0 = try storeCommit(gpa, s, tree_h, &.{}, 1000, "root\n");
    const h1 = try storeCommit(gpa, s, tree_h, &.{h0}, 2000, "child\n");
    // h2 only in object store (not in graph) — tests mixed history fallback.
    const h2 = try storeCommit(gpa, s, tree_h, &.{h1}, 3000, "tip\n");

    var mi = commitgraph.MemoryIndex.init(gpa);
    defer mi.deinit();

    var d0: commitgraph.CommitData = .{
        .tree_hash = tree_h,
        .when = 1000,
        .generation = 1,
        .generation_v2 = 1001,
    };
    try mi.add(h0, &d0);

    var parents0 = [_]Hash{h0};
    var d1: commitgraph.CommitData = .{
        .tree_hash = tree_h,
        .when = 2000,
        .generation = 2,
        .generation_v2 = 2002,
        .parent_hashes = parents0[0..],
    };
    try mi.add(h1, &d1);

    const index = try newGraphCommitNodeIndexFrom(gpa, commitgraph.MemoryIndex, &mi, Storage, s);
    defer index.deinit();

    // Graph-backed node
    const n1 = try index.get(h1);
    defer n1.deinit();
    try std.testing.expect(n1.id().eql(h1));
    try std.testing.expectEqual(@as(u64, 2), n1.generation());
    try std.testing.expectEqual(@as(i64, 2000), n1.commitTimeSec());
    try std.testing.expectEqual(@as(usize, 1), n1.numParents());

    const p0 = try n1.parentNode(0);
    defer p0.deinit();
    try std.testing.expect(p0.id().eql(h0));
    try std.testing.expectEqual(@as(u64, 1), p0.generation());

    // Full Commit() from graph node loads object store (always heap-owned)
    const full = try n1.commit();
    defer object.freeCommit(gpa, full);
    try std.testing.expect(full.id().eql(h1));

    // Object fallback for tip not in graph; ParentNode routes through index
    // so parent lands on graph-backed node.
    const n2 = try index.get(h2);
    defer n2.deinit();
    try std.testing.expectEqual(max_generation, n2.generation());
    try std.testing.expectEqual(@as(usize, 1), n2.numParents());

    const p1 = try n2.parentNode(0);
    defer p1.deinit();
    try std.testing.expect(p1.id().eql(h1));
    // Parent resolved via graph (generation from CommitData, not max).
    try std.testing.expectEqual(@as(u64, 2), p1.generation());
}

test "CommitNodeIterDateOrder linear history" {
    const gpa = std.testing.allocator;

    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    const tree_h = try storeEmptyTree(s);
    const h0 = try storeCommit(gpa, s, tree_h, &.{}, 1000, "root\n");
    const h1 = try storeCommit(gpa, s, tree_h, &.{h0}, 2000, "mid\n");
    const h2 = try storeCommit(gpa, s, tree_h, &.{h1}, 3000, "tip\n");

    const index = try newObjectCommitNodeIndex(gpa, Storage, s);
    defer index.deinit();

    const start = try index.get(h2);
    const iter = try newCommitNodeIterDateOrder(gpa, start, null, &.{});
    defer iter.close();

    var walked: std.ArrayList(Hash) = .empty;
    defer walked.deinit(gpa);
    while (true) {
        const n = iter.next() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        try walked.append(gpa, n.id());
        n.deinit();
    }
    try std.testing.expectEqual(@as(usize, 3), walked.items.len);
    try std.testing.expect(walked.items[0].eql(h2));
    try std.testing.expect(walked.items[1].eql(h1));
    try std.testing.expect(walked.items[2].eql(h0));
}

test "CommitNodeIterAuthorDateOrder linear history" {
    const gpa = std.testing.allocator;

    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    const tree_h = try storeEmptyTree(s);
    // Author and committer times match in storeCommit helper.
    const h0 = try storeCommit(gpa, s, tree_h, &.{}, 1000, "root\n");
    const h1 = try storeCommit(gpa, s, tree_h, &.{h0}, 2000, "mid\n");
    const h2 = try storeCommit(gpa, s, tree_h, &.{h1}, 3000, "tip\n");

    const index = try newObjectCommitNodeIndex(gpa, Storage, s);
    defer index.deinit();

    const start = try index.get(h2);
    const iter = try newCommitNodeIterAuthorDateOrder(gpa, start, null, &.{});
    defer iter.close();

    var walked: std.ArrayList(Hash) = .empty;
    defer walked.deinit(gpa);
    while (true) {
        const n = iter.next() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        try walked.append(gpa, n.id());
        n.deinit();
    }
    try std.testing.expectEqual(@as(usize, 3), walked.items.len);
    try std.testing.expect(walked.items[0].eql(h2));
    try std.testing.expect(walked.items[1].eql(h1));
    try std.testing.expect(walked.items[2].eql(h0));
}

test "CommitNodeIter forEach R4b free-after-cb Stop zero leaks" {
    // R4b: forEach frees each node after cb (including Stop) and closes.
    const gpa = std.testing.allocator;

    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    const tree_h = try storeEmptyTree(s);
    const h0 = try storeCommit(gpa, s, tree_h, &.{}, 1000, "root\n");
    const h1 = try storeCommit(gpa, s, tree_h, &.{h0}, 2000, "mid\n");
    const h2 = try storeCommit(gpa, s, tree_h, &.{h1}, 3000, "tip\n");

    const index = try newObjectCommitNodeIndex(gpa, Storage, s);
    defer index.deinit();

    const start = try index.get(h2);
    const iter = try newCommitNodeIterCTime(gpa, start, null, &.{});
    // forEach closes; do not defer close (close destroys the heap box).

    var count: usize = 0;
    const Gen = struct {
        var n: *usize = undefined;
        fn cb(_: CommitNode) !void {
            n.* += 1;
            if (n.* >= 2) return error.Stop;
        }
    };
    Gen.n = &count;
    try iter.forEach(Gen.cb);
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "CommitNode.commit always heap-owned freeCommit" {
    // Object and graph backends both return freeCommit-able *Commit.
    const gpa = std.testing.allocator;

    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    const tree_h = try storeEmptyTree(s);
    const h0 = try storeCommit(gpa, s, tree_h, &.{}, 1000, "root\n");
    const h1 = try storeCommit(gpa, s, tree_h, &.{h0}, 2000, "child\n");

    // Object-backed node
    {
        const index = try newObjectCommitNodeIndex(gpa, Storage, s);
        defer index.deinit();
        const node = try index.get(h1);
        defer node.deinit();
        const c1 = try node.commit();
        defer object.freeCommit(gpa, c1);
        const c2 = try node.commit();
        defer object.freeCommit(gpa, c2);
        // Distinct heap instances; free both without touching the node cache.
        try std.testing.expect(c1 != c2);
        try std.testing.expect(c1.id().eql(h1));
        try std.testing.expect(c2.id().eql(h1));
    }

    // Graph-backed node
    {
        var mi = commitgraph.MemoryIndex.init(gpa);
        defer mi.deinit();
        var d0: commitgraph.CommitData = .{
            .tree_hash = tree_h,
            .when = 1000,
            .generation = 1,
            .generation_v2 = 1001,
        };
        try mi.add(h0, &d0);
        var parents0 = [_]Hash{h0};
        var d1: commitgraph.CommitData = .{
            .tree_hash = tree_h,
            .when = 2000,
            .generation = 2,
            .generation_v2 = 2002,
            .parent_hashes = parents0[0..],
        };
        try mi.add(h1, &d1);

        const index = try newGraphCommitNodeIndexFrom(gpa, commitgraph.MemoryIndex, &mi, Storage, s);
        defer index.deinit();
        const node = try index.get(h1);
        defer node.deinit();
        const full = try node.commit();
        defer object.freeCommit(gpa, full);
        try std.testing.expect(full.id().eql(h1));
        try std.testing.expect(full.heap_owned);
    }
}

test "ParentCommitNodeIter forEach free-after-cb" {
    const gpa = std.testing.allocator;

    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    const tree_h = try storeEmptyTree(s);
    const h0 = try storeCommit(gpa, s, tree_h, &.{}, 1000, "root\n");
    const h1 = try storeCommit(gpa, s, tree_h, &.{h0}, 2000, "child\n");

    const index = try newObjectCommitNodeIndex(gpa, Storage, s);
    defer index.deinit();
    const tip = try index.get(h1);
    defer tip.deinit();

    var piter = tip.parentNodes();
    var count: usize = 0;
    const Gen = struct {
        var n: *usize = undefined;
        var expect: Hash = undefined;
        fn cb(node: CommitNode) !void {
            try std.testing.expect(node.id().eql(expect));
            n.* += 1;
        }
    };
    Gen.n = &count;
    Gen.expect = h0;
    try piter.forEach(Gen.cb);
    try std.testing.expectEqual(@as(usize, 1), count);
}
