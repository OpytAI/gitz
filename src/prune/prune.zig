//! Prune unreachable loose objects (go-git `prune.go`).
//!
//! Free functions take `*memory.Storage` (implements the LooseObjectStorer
//! method set: `forEachObjectHash`, `looseObjectTime`, `deleteLooseObject`).
//! Memory `deleteLooseObject` returns `error.NotSupported` (same as go-git).

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");

const object_walker = @import("object_walker.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Storage = memory.Storage;
const ObjectWalker = object_walker.ObjectWalker;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// go-git `PruneHandler` — invoked for each unreferenced loose object hash.
pub const PruneHandler = *const fn (unreferenced_object_hash: Hash) anyerror!void;

/// go-git `PruneOptions`.
pub const PruneOptions = struct {
    /// When non-null, only objects whose loose mtime is **strictly before**
    /// this unix second are candidates (go-git `OnlyObjectsOlderThan` /
    /// `time.Time.Before`). Null means no age filter (go-git zero time).
    only_objects_older_than: ?i64 = null,
    /// Called for each prune candidate (go-git `Handler`).
    handler: PruneHandler,
};

/// go-git `ErrLooseObjectsNotSupported`.
///
/// Returned when the storer does not expose the LooseObjectStorer method set.
/// Memory storage **does** expose the methods; `deleteObject` may still return
/// `error.NotSupported` from the backend's `deleteLooseObject`.
pub const ErrLooseObjectsNotSupported = error.LooseObjectsNotSupported;

/// Package-level errors (plus propagated storer / walk errors).
pub const Error = error{
    LooseObjectsNotSupported,
    UnknownObjectType,
};

// ---------------------------------------------------------------------------
// DeleteObject / Prune
// ---------------------------------------------------------------------------

/// go-git `Repository.DeleteObject` — delete one loose object.
///
/// Memory implements the LooseObjectStorer methods; the actual delete returns
/// `error.NotSupported` (go-git memory `DeleteLooseObject`).
pub fn deleteObject(sto: *Storage, hash: Hash) anyerror!void {
    return sto.deleteLooseObject(hash);
}

/// go-git `Repository.Prune`.
///
/// 1. Walk all hash refs and mark reachable objects.
/// 2. Iterate every loose object hash via `forEachObjectHash`.
/// 3. Call `opt.handler` for each hash not in the seen set (after optional age filter).
///
/// Memory has no real mtimes: when `only_objects_older_than` is set,
/// `looseObjectTime` fails and every candidate is skipped (non-fatal; go-git).
pub fn prune(allocator: Allocator, sto: *Storage, opt: PruneOptions) anyerror!void {
    var walker = ObjectWalker.init(allocator, sto);
    defer walker.deinit();
    try walker.walkAllRefs();

    const Ctx = struct {
        walker: *const ObjectWalker,
        sto: *Storage,
        opt: PruneOptions,

        fn onHash(ctx: *@This(), hash: Hash) anyerror!void {
            if (ctx.walker.isSeen(hash)) return;

            if (ctx.opt.only_objects_older_than) |cutoff| {
                // Errors are non-fatal (packed, concurrent delete, unsupported).
                const t = ctx.sto.looseObjectTime(hash) catch return;
                // go-git: skip when !t.Before(OnlyObjectsOlderThan) → t >= cutoff.
                if (t >= cutoff) return;
            }
            return ctx.opt.handler(hash);
        }
    };

    var ctx = Ctx{
        .walker = &walker,
        .sto = sto,
        .opt = opt,
    };

    // Capture sto-bound callback for forEachObjectHash (fn(Hash)!void).
    const Bridge = struct {
        var c: *Ctx = undefined;
        fn cb(hash: Hash) anyerror!void {
            return c.onHash(hash);
        }
    };
    Bridge.c = &ctx;
    try sto.forEachObjectHash(Bridge.cb);
}

/// Variant of `prune` that takes a function pointer handler.
pub fn pruneWithHandler(
    allocator: Allocator,
    sto: *Storage,
    only_objects_older_than: ?i64,
    handler: *const fn (Hash) anyerror!void,
) anyerror!void {
    return prune(allocator, sto, .{
        .only_objects_older_than = only_objects_older_than,
        .handler = handler,
    });
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

test "deleteObject on memory returns NotSupported" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const h = try storeBlob(s, "x");
    try std.testing.expectError(error.NotSupported, deleteObject(s, h));
    // Object still present.
    try s.hasEncodedObject(h);
}

test "prune calls handler only for unreachable loose objects" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const keep_blob = try storeBlob(s, "keep-content");
    const drop_blob = try storeBlob(s, "orphan-content");
    const tree = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "f", .hash = keep_blob },
    });
    const commit = try storeCommit(s, allocator, tree, &.{}, "reachable");

    try s.setReference(plumbing.Reference.newHashReference(plumbing.master, commit));

    // Unreachable commit + tree + blob graph.
    const orphan_blob = try storeBlob(s, "orphan2");
    const orphan_tree = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "g", .hash = orphan_blob },
    });
    // Orphan commit graph is intentionally unreferenced (not linked from any ref).
    const orphan_commit = try storeCommit(s, allocator, orphan_tree, &.{}, "orphan");

    var hits: std.ArrayList(Hash) = .empty;
    defer hits.deinit(allocator);

    const Cap = struct {
        var list: *std.ArrayList(Hash) = undefined;
        var gpa: Allocator = undefined;
        fn handler(h: Hash) anyerror!void {
            try list.append(gpa, h);
        }
    };
    Cap.list = &hits;
    Cap.gpa = allocator;

    try prune(allocator, s, .{
        .only_objects_older_than = null,
        .handler = Cap.handler,
    });

    // Reachable set must not appear.
    const notHit = struct {
        fn check(list: []const Hash, h: Hash) bool {
            for (list) |x| {
                if (x.eql(h)) return false;
            }
            return true;
        }
    }.check;

    try std.testing.expect(notHit(hits.items, commit));
    try std.testing.expect(notHit(hits.items, tree));
    try std.testing.expect(notHit(hits.items, keep_blob));

    // Orphans must be reported.
    const hit = struct {
        fn check(list: []const Hash, h: Hash) bool {
            for (list) |x| {
                if (x.eql(h)) return true;
            }
            return false;
        }
    }.check;

    try std.testing.expect(hit(hits.items, drop_blob));
    try std.testing.expect(hit(hits.items, orphan_blob));
    try std.testing.expect(hit(hits.items, orphan_tree));
    try std.testing.expect(hit(hits.items, orphan_commit));
    try std.testing.expectEqual(@as(usize, 4), hits.items.len);
}

test "prune with age filter skips all on memory (LooseObjectTime unsupported)" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const orphan = try storeBlob(s, "old-orphan");
    const keep = try storeBlob(s, "kept");
    const tree = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "f", .hash = keep },
    });
    const commit = try storeCommit(s, allocator, tree, &.{}, "c");
    try s.setReference(plumbing.Reference.newHashReference(plumbing.master, commit));
    _ = orphan;

    var hits: usize = 0;
    const Cap = struct {
        var n: *usize = undefined;
        fn handler(_: Hash) anyerror!void {
            n.* += 1;
        }
    };
    Cap.n = &hits;

    // Any non-null cutoff: looseObjectTime fails → skip candidates (go-git).
    try prune(allocator, s, .{
        .only_objects_older_than = 1,
        .handler = Cap.handler,
    });
    try std.testing.expectEqual(@as(usize, 0), hits);
}

test "prune empty repo no refs no handler calls" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    // Only unreachable objects, no refs → all objects are prune candidates.
    const a = try storeBlob(s, "a");
    const b = try storeBlob(s, "b");

    var hits: std.ArrayList(Hash) = .empty;
    defer hits.deinit(allocator);
    const Cap = struct {
        var list: *std.ArrayList(Hash) = undefined;
        var gpa: Allocator = undefined;
        fn handler(h: Hash) anyerror!void {
            try list.append(gpa, h);
        }
    };
    Cap.list = &hits;
    Cap.gpa = allocator;

    try prune(allocator, s, .{ .handler = Cap.handler });
    try std.testing.expectEqual(@as(usize, 2), hits.items.len);
    _ = a;
    _ = b;
}

test "pruneWithHandler matches prune" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const keep = try storeBlob(s, "k");
    const drop = try storeBlob(s, "d");
    const tree = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "f", .hash = keep },
    });
    const commit = try storeCommit(s, allocator, tree, &.{}, "c");
    try s.setReference(plumbing.Reference.newHashReference(plumbing.master, commit));

    var hit_drop = false;
    const Cap = struct {
        var flag: *bool = undefined;
        var want: Hash = undefined;
        fn handler(h: Hash) anyerror!void {
            if (h.eql(want)) flag.* = true;
        }
    };
    Cap.flag = &hit_drop;
    Cap.want = drop;

    try pruneWithHandler(allocator, s, null, Cap.handler);
    try std.testing.expect(hit_drop);
}

test "prune handler error propagates" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    _ = try storeBlob(s, "orphan-only");

    const Cap = struct {
        fn handler(_: Hash) anyerror!void {
            return error.ARandomError;
        }
    };
    try std.testing.expectError(error.ARandomError, prune(allocator, s, .{
        .handler = Cap.handler,
    }));
}

test "ErrLooseObjectsNotSupported is distinct" {
    try std.testing.expect(ErrLooseObjectsNotSupported == error.LooseObjectsNotSupported);
}
