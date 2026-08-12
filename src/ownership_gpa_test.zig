//! Cross-module ownership GPA suite (ownership program PR12 aggregator).
//!
//! Runs production-loader scenarios under `std.testing.allocator` so leaks and
//! double-frees fail the test. Representative ownership paths: walker early-exit
//! + BFS diamond, isAncestor/merge-base free, remote isFastForward free, memory
//! walker/merge-base plus FS EncodedObject discard, ObjectLru non-owning deinit,
//! hash pad, and `deinitPools`. Dual-backend walker GPA stays in package tests.
//!
//! Per-package GPA tests remain in their modules; this target is the visible
//! acceptance aggregator counted by the README Ownership GPA suites row.

const std = @import("std");
const plumbing = @import("plumbing");
const object = @import("object");
const memory = @import("memory");
const filesystem = @import("filesystem");
const fs_pkg = @import("fs");
const sync = @import("utils/sync");
const remote = @import("remote");
const cache = @import("cache");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const freeCommit = object.freeCommit;
const freeMergeBaseResult = object.freeMergeBaseResult;

/// Empty-tree OID; walkers do not require a tree object in storage.
const empty_tree_hex = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

fn storeCommit(
    gpa: Allocator,
    store: anytype,
    parents: []const Hash,
    when: i64,
) !Hash {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try body.writer.print("tree {s}\n", .{empty_tree_hex});
    for (parents) |p| {
        var hex: [plumbing.MaxHexSize]u8 = undefined;
        try body.writer.print("parent {s}\n", .{p.string(&hex)});
    }
    try body.writer.print(
        \\author W <w@w> {d} +0000
        \\committer W <w@w> {d} +0000
        \\
        \\m
    , .{ when, when });
    const obj = try store.newEncodedObject();
    obj.setType(.commit);
    try obj.setContent(body.written());
    return try store.setEncodedObject(obj);
}

// ---------------------------------------------------------------------------
// Walker: early exit (R3 unyielded free) + BFS diamond (R2 free on second load)
// ---------------------------------------------------------------------------

test "ownership GPA: walker early exit and diamond zero leaks (memory)" {
    const gpa = std.testing.allocator;

    var store = memory.Storage.init(gpa);
    defer store.deinit();

    // linear: tip → mid → root
    const h_root = try storeCommit(gpa, &store, &.{}, 1);
    const h_mid = try storeCommit(gpa, &store, &.{h_root}, 2);
    const h_tip = try storeCommit(gpa, &store, &.{h_mid}, 3);

    {
        const tip = try object.getCommit(gpa, &store, h_tip);
        var iter = try object.newCommitIterBsf(gpa, tip, null, &.{});
        defer iter.deinit();
        const c = try iter.next();
        try std.testing.expect(c.hash.eql(h_tip));
        freeCommit(gpa, c);
        // After yielding tip, only mid is enqueued (R3); root not yet loaded.
    }

    // diamond merge: tip → left/right → base
    // BFS may enqueue base twice (from left and right); second load is freed on
    // seen continue (R2 free-on-skip). R1 free each yield.
    const h_base = try storeCommit(gpa, &store, &.{}, 10);
    const h_left = try storeCommit(gpa, &store, &.{h_base}, 11);
    const h_right = try storeCommit(gpa, &store, &.{h_base}, 12);
    const h_merge = try storeCommit(gpa, &store, &.{ h_left, h_right }, 13);

    {
        const tip = try object.getCommit(gpa, &store, h_merge);
        var iter = try object.newCommitIterBsf(gpa, tip, null, &.{});
        defer iter.deinit();
        var n: usize = 0;
        while (true) {
            const c = iter.next() catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            freeCommit(gpa, c);
            n += 1;
        }
        try std.testing.expectEqual(@as(usize, 4), n);
    }
}

// ---------------------------------------------------------------------------
// isAncestor / merge-base: free every non-retained yield; free results
// ---------------------------------------------------------------------------

test "ownership GPA: isAncestor and mergeBase free results zero leaks (memory)" {
    const gpa = std.testing.allocator;

    var store = memory.Storage.init(gpa);
    defer store.deinit();

    const h_base = try storeCommit(gpa, &store, &.{}, 1);
    const h_left = try storeCommit(gpa, &store, &.{h_base}, 2);
    const h_right = try storeCommit(gpa, &store, &.{h_base}, 3);
    const h_a = try storeCommit(gpa, &store, &.{h_left}, 4);
    const h_b = try storeCommit(gpa, &store, &.{h_right}, 5);

    const a = try object.getCommit(gpa, &store, h_a);
    defer freeCommit(gpa, a);
    const b = try object.getCommit(gpa, &store, h_b);
    defer freeCommit(gpa, b);
    const base = try object.getCommit(gpa, &store, h_base);
    defer freeCommit(gpa, base);

    try std.testing.expect(try object.isAncestor(base, a));
    try std.testing.expect(!(try object.isAncestor(a, base)));

    const bases = try object.mergeBase(a, gpa, b);
    defer freeMergeBaseResult(gpa, bases);
    try std.testing.expectEqual(@as(usize, 1), bases.len);
    try std.testing.expect(bases[0].hash.eql(h_base));
    try std.testing.expect(bases[0].heap_owned);
}

// ---------------------------------------------------------------------------
// Remote FF consumer: isFastForward free-each-yield under production loads
// ---------------------------------------------------------------------------

test "ownership GPA: isFastForward walk free yields zero leaks (memory)" {
    const gpa = std.testing.allocator;

    var store = memory.Storage.init(gpa);
    defer store.deinit();

    const h_root = try storeCommit(gpa, &store, &.{}, 1);
    const h_mid = try storeCommit(gpa, &store, &.{h_root}, 2);
    const h_tip = try storeCommit(gpa, &store, &.{h_mid}, 3);

    try std.testing.expect(try remote.isFastForward(gpa, &store, h_root, h_tip, null));
    try std.testing.expect(try remote.isFastForward(gpa, &store, h_mid, h_tip, null));
    try std.testing.expect(!(try remote.isFastForward(gpa, &store, h_tip, h_root, null)));
}

// ---------------------------------------------------------------------------
// EncodedObject: new + discard (never set) on memory and filesystem
// ---------------------------------------------------------------------------

test "ownership GPA: EncodedObject new+discard both backends" {
    const gpa = std.testing.allocator;

    // Memory: caller owns create until set or discard.
    {
        var store = memory.Storage.init(gpa);
        defer store.deinit();
        const o = try store.newEncodedObject();
        o.setType(.blob);
        _ = try o.write("gpa-discard-mem");
        store.discardEncodedObject(o);
    }

    // Filesystem (Mem FS): same contract; discard must not double-free with deinit.
    {
        var mem = try fs_pkg.Mem.init(gpa);
        defer mem.deinit();
        const store = try filesystem.newStorage(gpa, &mem, null);
        defer {
            store.deinit();
            gpa.destroy(store);
        }
        try store.initLayout();
        const o = try store.newEncodedObject();
        o.setType(.blob);
        _ = try o.write("gpa-discard-fs");
        store.discardEncodedObject(o);
    }
}

// ---------------------------------------------------------------------------
// ObjectLru: non-owning cache; deinit frees entries only, caller frees objects
// ---------------------------------------------------------------------------

test "ownership GPA: ObjectLru put deinit leaves caller ownership" {
    const gpa = std.testing.allocator;

    var lru = cache.ObjectLru.init(gpa, 64 * cache.Byte);
    defer lru.deinit();

    const obj = try gpa.create(plumbing.MemoryObject);
    defer {
        obj.deinit();
        gpa.destroy(obj);
    }
    obj.* = plumbing.MemoryObject.init(gpa);
    obj.setType(.blob);
    try obj.setContent("gpa-lru-owner");

    try lru.put(obj);
    try std.testing.expect(lru.get(obj.hash()) == obj);
    lru.clear();
    try std.testing.expect(lru.get(obj.hash()) == null);
    // obj still valid; caller free via defer after cache clear/deinit.
}

// ---------------------------------------------------------------------------
// Hash pad: fromBytes clears dirty pad beyond active digest width (R7)
// ---------------------------------------------------------------------------

test "ownership GPA: hash fromBytes clears dirty pad" {
    const MaxSize = plumbing.MaxSize;
    var dirty: [MaxSize]u8 = undefined;
    @memset(&dirty, 0xab);
    // SHA-1 empty-blob digest in the active width; pad must not stay 0xab.
    const digest = [_]u8{
        0xe6, 0x9d, 0xe2, 0x9b, 0xb2, 0xd1, 0xd6, 0x43, 0x4b, 0x8b,
        0x29, 0xae, 0x77, 0x5a, 0xd8, 0xc2, 0xe4, 0x8c, 0x53, 0x91,
    };
    @memcpy(dirty[0..20], &digest);

    const from_dirty = plumbing.Hash.fromBytes(&dirty);
    const from_clean = plumbing.Hash.fromBytes(digest[0..]);
    try std.testing.expect(from_dirty.eql(from_clean));
    try std.testing.expect(std.mem.allEqual(u8, from_dirty.bytes[20..], 0));
    try std.testing.expectEqualSlices(u8, digest[0..], from_dirty.bytes[0..20]);
}

// ---------------------------------------------------------------------------
// Process pools: deinitPools after get/put work (R8)
// ---------------------------------------------------------------------------

test "ownership GPA: deinitPools after work zero leaks" {
    const gpa = std.testing.allocator;
    defer sync.deinitPools(gpa);

    const buf = try sync.getBytesBuffer(gpa);
    try buf.appendSlice(gpa, "ownership-gpa");
    sync.putBytesBuffer(buf);

    const reused = try sync.getBytesBuffer(gpa);
    try std.testing.expect(reused == buf);
    try std.testing.expectEqual(@as(usize, 0), reused.items.len);
    sync.putBytesBuffer(reused);
}
