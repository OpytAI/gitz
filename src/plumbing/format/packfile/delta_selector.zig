//! Delta window selection for pack encoding
//! (go-git `plumbing/format/packfile/delta_selector.go`).
//!
//! Builds a list of `ObjectToPack` from object hashes, optionally creating
//! OFS deltas within a sliding `pack_window`.
//!
//! # Threading
//!
//! go-git walks each object-type group in a separate goroutine. This port walks
//! type groups **sequentially** (same algorithm, single-threaded). Window
//! cleanup and try-to-deltify order within a group match go-git.
//!
//! # Store
//!
//! Uses a small vtable (`Store`) with `encodedObject(type, hash) !*MemoryObject`
//! and optional `deltaObject` (go-git `DeltaObjectStorer`). Does not import
//! `storage/memory` (avoids cycles); tests use an in-memory hash map.
//!
//! # Siblings
//!
//! - `object_to_pack.zig` — `ObjectToPack`, `newObjectToPack`
//! - `diff_delta.zig` — `getDeltaWithIndex` (reuses `delta_index.DeltaIndex` per base)
//! - `delta_index.zig` — fingerprint tables for delta creation

const std = @import("std");
const Allocator = std.mem.Allocator;

const plumbing = @import("plumbing");
const sync = @import("utils/sync");
const Hash = plumbing.Hash;
const ObjectType = plumbing.ObjectType;
const MemoryObject = plumbing.MemoryObject;

const object_to_pack = @import("object_to_pack.zig");
const ObjectToPack = object_to_pack.ObjectToPack;
const newObjectToPack = object_to_pack.newObjectToPack;

const delta_index = @import("delta_index.zig");
const DeltaIndex = delta_index.DeltaIndex;

const diff_delta = @import("diff_delta.zig");

/// Max delta-chain depth used when sizing candidate deltas (go-git `maxDepth` = 50, JGit default).
pub const max_depth: i64 = 50;

/// Object types eligible for delta compression (go-git `applyDelta` map).
fn shouldApplyDelta(t: ObjectType) bool {
    return t == .blob or t == .tree;
}

// ---------------------------------------------------------------------------
// Store vtable (ObjectGetter + optional DeltaObjectStorer)
// ---------------------------------------------------------------------------

/// Minimal object store for delta selection (go-git `EncodedObjectStorer` /
/// optional `DeltaObjectStorer` subset).
pub const Store = struct {
    ptr: *anyopaque,
    encoded_object_fn: *const fn (ptr: *anyopaque, t: ObjectType, h: Hash) anyerror!*MemoryObject,
    /// When non-null, used when `pack_window != 0` (go-git `DeltaObject`).
    delta_object_fn: ?*const fn (ptr: *anyopaque, t: ObjectType, h: Hash) anyerror!*MemoryObject = null,

    pub fn encodedObject(self: Store, t: ObjectType, h: Hash) anyerror!*MemoryObject {
        return self.encoded_object_fn(self.ptr, t, h);
    }

    pub fn deltaObject(self: Store, t: ObjectType, h: Hash) anyerror!*MemoryObject {
        if (self.delta_object_fn) |f| return f(self.ptr, t, h);
        return self.encodedObject(t, h);
    }

    /// Build from a type with
    /// `encodedObject(self: *T, t: ObjectType, h: Hash) anyerror!*MemoryObject`.
    /// Optional `deltaObject` with the same signature is used when present.
    pub fn from(comptime T: type, impl: *T) Store {
        const gen = struct {
            fn encoded(ptr: *anyopaque, t: ObjectType, h: Hash) anyerror!*MemoryObject {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.encodedObject(t, h);
            }
            fn delta(ptr: *anyopaque, t: ObjectType, h: Hash) anyerror!*MemoryObject {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.deltaObject(t, h);
            }
        };
        var s: Store = .{
            .ptr = impl,
            .encoded_object_fn = gen.encoded,
        };
        if (@hasDecl(T, "deltaObject")) {
            s.delta_object_fn = gen.delta;
        }
        return s;
    }
};

// ---------------------------------------------------------------------------
// DeltaSelector
// ---------------------------------------------------------------------------

/// Selects objects and optional deltas for pack encoding (go-git `deltaSelector`).
pub const DeltaSelector = struct {
    allocator: Allocator,
    store: Store,

    /// go-git `newDeltaSelector`.
    pub fn init(allocator: Allocator, store: Store) DeltaSelector {
        return .{ .allocator = allocator, .store = store };
    }

    /// Create `ObjectToPack` entries for `hashes`, with deltas when suitable.
    ///
    /// `pack_window` is the sliding window size for delta candidates; **0**
    /// turns delta compression off entirely (go-git `ObjectsToPack`).
    ///
    /// Caller owns the returned slice and each `*ObjectToPack`. Free with
    /// `freeObjectsToPack`. Delta bodies created by `getDeltaWithIndex` are
    /// owned by the corresponding `ObjectToPack.object` when `isDelta()` is true.
    pub fn objectsToPack(
        self: *DeltaSelector,
        hashes: []const Hash,
        pack_window: u32,
    ) ![]*ObjectToPack {
        const otp = try self.objectsToPackBuild(hashes, pack_window);
        errdefer freeObjectsToPack(self.allocator, otp);

        if (pack_window == 0) {
            return otp;
        }

        self.sort(otp);

        // go-git: one goroutine per contiguous type group. Sequential here.
        var i: usize = 0;
        while (i < otp.len) {
            var j = i + 1;
            while (j < otp.len and otp[j].objectType() == otp[i].objectType()) : (j += 1) {}
            try self.walk(otp[i..j], pack_window);
            i = j;
        }

        return otp;
    }

    /// Build ObjectToPack list without sorting or walking (go-git `objectsToPack`).
    /// Used by tests that exercise `walk` without the full pipeline.
    pub fn objectsToPackBuild(
        self: *DeltaSelector,
        hashes: []const Hash,
        pack_window: u32,
    ) ![]*ObjectToPack {
        var list: std.ArrayListUnmanaged(*ObjectToPack) = .empty;
        errdefer {
            for (list.items) |p| self.allocator.destroy(p);
            list.deinit(self.allocator);
        }

        for (hashes) |h| {
            const o: *MemoryObject = if (pack_window == 0)
                try self.encodedObject(h)
            else
                try self.encodedDeltaObject(h);

            const node = try self.allocator.create(ObjectToPack);
            errdefer self.allocator.destroy(node);
            node.* = newObjectToPack(o);
            // go-git: if the storer returned a DeltaObject, drop Original so the
            // chain is fixed later. Without a DeltaObject interface, treat typed
            // delta MemoryObjects the same (CleanOriginal without metadata).
            if (o.object_type.isDelta()) {
                node.cleanOriginal();
            }
            try list.append(self.allocator, node);
        }

        if (list.items.len == 0) {
            list.deinit(self.allocator);
            return &.{};
        }

        if (pack_window == 0) {
            return try list.toOwnedSlice(self.allocator);
        }

        try self.fixAndBreakChains(list.items);
        return try list.toOwnedSlice(self.allocator);
    }

    fn encodedDeltaObject(self: *DeltaSelector, h: Hash) !*MemoryObject {
        return self.store.deltaObject(.any, h);
    }

    fn encodedObject(self: *DeltaSelector, h: Hash) !*MemoryObject {
        return self.store.encodedObject(.any, h);
    }

    fn fixAndBreakChains(self: *DeltaSelector, objects: []*ObjectToPack) !void {
        var m: std.AutoHashMapUnmanaged(Hash, *ObjectToPack) = .empty;
        defer m.deinit(self.allocator);

        for (objects) |otp| {
            try m.put(self.allocator, otp.objectHash(), otp);
        }
        for (objects) |otp| {
            try self.fixAndBreakChainsOne(&m, otp);
        }
    }

    fn fixAndBreakChainsOne(
        self: *DeltaSelector,
        objects: *std.AutoHashMapUnmanaged(Hash, *ObjectToPack),
        otp: *ObjectToPack,
    ) !void {
        const obj = otp.object orelse return;
        if (!obj.object_type.isDelta()) return;

        // Already fixed once Base is assigned (go-git).
        if (otp.base != null) return;

        // go-git: type-assert plumbing.DeltaObject; without BaseHash we cannot
        // re-link the chain and must undeltify.
        const base_hash = obj.baseHash() orelse {
            try self.undeltify(otp);
            return;
        };

        const base = objects.get(base_hash) orelse {
            // Base not in this pack set — break the chain.
            try self.undeltify(otp);
            return;
        };

        try self.fixAndBreakChainsOne(objects, base);
        // Store-owned delta body: do not take ownership.
        otp.setDeltaBorrowed(base, obj);
    }

    fn restoreOriginal(self: *DeltaSelector, otp: *ObjectToPack) !void {
        if (otp.original != null) return;

        const obj = otp.object orelse return;
        if (!obj.object_type.isDelta()) return;

        // Prefer cached hash from SaveOriginalMetadata; else cannot look up.
        const h = if (otp.resolved_original) otp.original_hash else return;
        const full = try self.encodedObject(h);
        otp.setOriginal(full);
    }

    fn undeltify(self: *DeltaSelector, otp: *ObjectToPack) !void {
        try self.restoreOriginal(otp);
        otp.object = otp.original;
        otp.depth = 0;
        otp.base = null;
    }

    /// Sort by type (higher ObjectType enum first) then size descending
    /// (go-git `byTypeAndSize`).
    pub fn sort(_: *DeltaSelector, objects: []*ObjectToPack) void {
        std.mem.sort(*ObjectToPack, objects, {}, struct {
            fn less(_: void, a: *ObjectToPack, b: *ObjectToPack) bool {
                const ta = @intFromEnum(a.objectType());
                const tb = @intFromEnum(b.objectType());
                if (ta < tb) return false;
                if (ta > tb) return true;
                return a.objectSize() > b.objectSize();
            }
        }.less);
    }

    /// Sliding-window delta search within one type group (go-git `walk`).
    pub fn walk(
        self: *DeltaSelector,
        objects: []*ObjectToPack,
        pack_window: u32,
    ) !void {
        var index_map: std.AutoHashMapUnmanaged(Hash, *DeltaIndex) = .empty;
        defer {
            var it = index_map.iterator();
            while (it.next()) |e| {
                e.value_ptr.*.deinit();
                self.allocator.destroy(e.value_ptr.*);
            }
            index_map.deinit(self.allocator);
        }

        const window: usize = pack_window;
        var i: usize = 0;
        while (i < objects.len) : (i += 1) {
            // Drop index entries and originals outside the pack window.
            if (i > window) {
                const old = objects[i - window];
                const old_hash = old.objectHash();
                if (index_map.fetchRemove(old_hash)) |kv| {
                    kv.value.deinit();
                    self.allocator.destroy(kv.value);
                }
                if (old.isDelta()) {
                    old.saveOriginalMetadata();
                    old.cleanOriginal();
                }
            }

            const target = objects[i];

            // Reused deltas are left as-is.
            if (target.isDelta()) continue;
            if (!shouldApplyDelta(target.objectType())) continue;

            // j from i-1 down while still inside the window.
            if (i == 0) continue;
            var j: usize = i;
            while (j > 0) {
                j -= 1;
                if (i - j >= window) break;

                const base = objects[j];
                if (base.objectType() != target.objectType()) break;

                try self.tryToDeltify(&index_map, base, target);
            }
        }
    }

    fn tryToDeltify(
        self: *DeltaSelector,
        index_map: *std.AutoHashMapUnmanaged(Hash, *DeltaIndex),
        base: *ObjectToPack,
        target: *ObjectToPack,
    ) !void {
        try self.restoreOriginal(target);
        try self.restoreOriginal(base);

        // Radically different sizes → skip (go-git: target < base>>4).
        if (target.objectSize() < base.objectSize() >> 4) return;

        const msz = deltaSizeLimit(
            target.object.?.size,
            base.depth,
            target.depth,
            target.isDelta(),
        );

        if (msz <= 8) return;
        if (base.objectSize() - target.objectSize() > msz) return;

        const base_orig = base.original orelse return;
        const target_orig = target.original orelse return;

        const base_hash = base.objectHash();
        const gop = try index_map.getOrPut(self.allocator, base_hash);
        if (!gop.found_existing) {
            errdefer _ = index_map.remove(base_hash);
            const idx = try self.allocator.create(DeltaIndex);
            idx.* = .{ .allocator = self.allocator };
            gop.value_ptr.* = idx;
        }

        // go-git `getDelta(index, base, target)` — reuse fingerprint index per base.
        const delta = try diff_delta.getDeltaWithIndex(
            self.allocator,
            gop.value_ptr.*,
            base_orig,
            target_orig,
        );

        // Keep delta only if strictly better than the size limit / current delta.
        if (delta.size < msz) {
            // Drop previous owned delta body (if any) before claiming the new one.
            target.releaseOwnedObject(self.allocator);
            target.setDelta(base, delta);
        } else {
            delta.deinit();
            self.allocator.destroy(delta);
        }
    }
};

/// go-git `(*deltaSelector).deltaSizeLimit`.
pub fn deltaSizeLimit(
    target_size: i64,
    base_depth: i32,
    target_depth: i32,
    target_delta: bool,
) i64 {
    if (!target_delta) {
        // Any first delta ≤ 50% of original, scaled by remaining depth budget.
        const n = target_size >> 1;
        return @divTrunc(n * (max_depth - @as(i64, base_depth)), max_depth);
    }

    const d: i64 = target_depth;
    const n = target_size;

    if (d >= max_depth) return 0;

    return @divTrunc(n * (max_depth - @as(i64, base_depth)), max_depth - d);
}

/// Free a slice from `objectsToPack` / `objectsToPackBuild`.
///
/// Frees each `ObjectToPack` node and any **owned** delta body (`owns_object`,
/// typically from `getDeltaWithIndex` / `setDelta`). Store-owned originals and
/// borrowed deltas (`setDeltaBorrowed`) are never freed — the storer retains them.
/// Empty literal `&.{}` must not be freed (not allocator-owned).
pub fn freeObjectsToPack(allocator: Allocator, otps: []*ObjectToPack) void {
    if (otps.len == 0) return;
    for (otps) |otp| {
        otp.releaseOwnedObject(allocator);
        allocator.destroy(otp);
    }
    allocator.free(otps);
}

// ---------------------------------------------------------------------------
// Tests (go-git delta_selector_test.go)
// ---------------------------------------------------------------------------

const Piece = struct {
    val: []const u8,
    times: usize,
};

fn genBytes(allocator: Allocator, elements: []const Piece) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);
    for (elements) |e| {
        var t: usize = 0;
        while (t < e.times) : (t += 1) {
            try list.appendSlice(allocator, e.val);
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn newObject(allocator: Allocator, t: ObjectType, content: []const u8) !*MemoryObject {
    const o = try allocator.create(MemoryObject);
    o.* = MemoryObject.init(allocator);
    o.setType(t);
    _ = try o.write(content);
    return o;
}

/// In-memory map store for tests (no storage/memory import).
const MapStore = struct {
    map: std.AutoHashMapUnmanaged(Hash, *MemoryObject) = .empty,
    allocator: Allocator,

    fn deinit(self: *MapStore) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            self.allocator.destroy(e.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    fn put(self: *MapStore, obj: *MemoryObject) !Hash {
        const h = obj.hash();
        // base and o1 share content → same hash; free the displaced object.
        if (self.map.fetchRemove(h)) |kv| {
            if (kv.value != obj) {
                kv.value.deinit();
                self.allocator.destroy(kv.value);
            }
        }
        try self.map.put(self.allocator, h, obj);
        return h;
    }

    fn encodedObject(self: *MapStore, t: ObjectType, h: Hash) anyerror!*MemoryObject {
        const obj = self.map.get(h) orelse return error.ObjectNotFound;
        if (t != .any and obj.object_type != t) return error.ObjectNotFound;
        return obj;
    }
};

const TestIds = struct {
    base: Hash = undefined,
    small_base: Hash = undefined,
    small_target: Hash = undefined,
    target: Hash = undefined,
    o1: Hash = undefined,
    o2: Hash = undefined,
    o3: Hash = undefined,
    big_base: Hash = undefined,
    tree_type: Hash = undefined,
};

fn createTestObjects(allocator: Allocator, store: *MapStore) !TestIds {
    var ids: TestIds = .{};

    const specs = [_]struct { id: []const u8, t: ObjectType, pieces: []const Piece }{
        .{
            .id = "base",
            .t = .blob,
            .pieces = &[_]Piece{
                .{ .val = "a", .times = 1000 },
                .{ .val = "b", .times = 1000 },
            },
        },
        .{
            .id = "smallBase",
            .t = .blob,
            .pieces = &[_]Piece{
                .{ .val = "a", .times = 1 },
                .{ .val = "b", .times = 1 },
                .{ .val = "c", .times = 6 },
            },
        },
        .{
            .id = "smallTarget",
            .t = .blob,
            .pieces = &[_]Piece{
                .{ .val = "a", .times = 1 },
                .{ .val = "c", .times = 1 },
            },
        },
        .{
            .id = "target",
            .t = .blob,
            .pieces = &[_]Piece{
                .{ .val = "a", .times = 1000 },
                .{ .val = "b", .times = 1000 },
                .{ .val = "c", .times = 1000 },
            },
        },
        .{
            .id = "o1",
            .t = .blob,
            .pieces = &[_]Piece{
                .{ .val = "a", .times = 1000 },
                .{ .val = "b", .times = 1000 },
            },
        },
        .{
            .id = "o2",
            .t = .blob,
            .pieces = &[_]Piece{
                .{ .val = "a", .times = 1000 },
                .{ .val = "b", .times = 500 },
            },
        },
        .{
            .id = "o3",
            .t = .blob,
            .pieces = &[_]Piece{
                .{ .val = "a", .times = 1000 },
                .{ .val = "b", .times = 499 },
            },
        },
    };

    for (specs) |spec| {
        const content = try genBytes(allocator, spec.pieces);
        defer allocator.free(content);
        const obj = try newObject(allocator, spec.t, content);
        const h = try store.put(obj);
        if (std.mem.eql(u8, spec.id, "base")) ids.base = h;
        if (std.mem.eql(u8, spec.id, "smallBase")) ids.small_base = h;
        if (std.mem.eql(u8, spec.id, "smallTarget")) ids.small_target = h;
        if (std.mem.eql(u8, spec.id, "target")) ids.target = h;
        if (std.mem.eql(u8, spec.id, "o1")) ids.o1 = h;
        if (std.mem.eql(u8, spec.id, "o2")) ids.o2 = h;
        if (std.mem.eql(u8, spec.id, "o3")) ids.o3 = h;
    }

    // go-git bigBase: 1_000_000 × "a" (radical size vs target).
    {
        const content = try allocator.alloc(u8, 1_000_000);
        defer allocator.free(content);
        @memset(content, 'a');
        const obj = try newObject(allocator, .blob, content);
        ids.big_base = try store.put(obj);
    }

    {
        const obj = try newObject(allocator, .tree, "I am a tree!");
        ids.tree_type = try store.put(obj);
    }

    return ids;
}

fn storeObj(store: *MapStore, h: Hash) *MemoryObject {
    return store.map.get(h).?;
}

test "DeltaSelectorSuite.TestSort" {
    const allocator = std.testing.allocator;
    var store: MapStore = .{ .allocator = allocator };
    defer store.deinit();
    var ds = DeltaSelector.init(allocator, Store.from(MapStore, &store));

    const o1 = try newObject(allocator, .blob, "00000");
    defer {
        o1.deinit();
        allocator.destroy(o1);
    }
    const o4 = try newObject(allocator, .blob, "0000");
    defer {
        o4.deinit();
        allocator.destroy(o4);
    }
    const o6 = try newObject(allocator, .blob, "00");
    defer {
        o6.deinit();
        allocator.destroy(o6);
    }
    const o9 = try newObject(allocator, .blob, "0");
    defer {
        o9.deinit();
        allocator.destroy(o9);
    }
    const o8 = try newObject(allocator, .tree, "000");
    defer {
        o8.deinit();
        allocator.destroy(o8);
    }
    const o2 = try newObject(allocator, .tree, "00");
    defer {
        o2.deinit();
        allocator.destroy(o2);
    }
    const o3 = try newObject(allocator, .tree, "0");
    defer {
        o3.deinit();
        allocator.destroy(o3);
    }
    const o5 = try newObject(allocator, .commit, "0000");
    defer {
        o5.deinit();
        allocator.destroy(o5);
    }
    const o7 = try newObject(allocator, .commit, "00");
    defer {
        o7.deinit();
        allocator.destroy(o7);
    }

    var p1 = newObjectToPack(o1);
    var p4 = newObjectToPack(o4);
    var p6 = newObjectToPack(o6);
    var p9 = newObjectToPack(o9);
    var p8 = newObjectToPack(o8);
    var p2 = newObjectToPack(o2);
    var p3 = newObjectToPack(o3);
    var p5 = newObjectToPack(o5);
    var p7 = newObjectToPack(o7);

    var to_sort = [_]*ObjectToPack{ &p1, &p2, &p3, &p4, &p5, &p6, &p7, &p8, &p9 };
    ds.sort(&to_sort);

    const expected = [_]*ObjectToPack{ &p1, &p4, &p6, &p9, &p8, &p2, &p3, &p5, &p7 };
    for (to_sort, expected) |got, exp| {
        try std.testing.expect(got == exp);
    }
}

test "DeltaSelectorSuite.TestMaxDepth" {
    // go-git TestMaxDepth
    const dsl = deltaSizeLimit(0, 0, @intCast(max_depth), true);
    try std.testing.expectEqual(@as(i64, 0), dsl);
}

// Full go-git `DeltaSelectorSuite.TestObjectsToPack` coverage.
// Leak strategy: `defer sync.deinitPools(allocator)` drains BytesBuffer free
// lists filled by `getDeltaWithIndex`; `freeObjectsToPack` destroys OFS delta
// `MemoryObject`s; walk frees every `DeltaIndex`; store owns originals.
test "DeltaSelectorSuite.TestObjectsToPack" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var store: MapStore = .{ .allocator = allocator };
    defer store.deinit();
    const ids = try createTestObjects(allocator, &store);
    var ds = DeltaSelector.init(allocator, Store.from(MapStore, &store));
    const window: u32 = 10;

    // 1. Different types → no delta (walk groups by type).
    {
        const hashes = [_]Hash{ ids.base, ids.tree_type };
        const otp = try ds.objectsToPack(&hashes, window);
        defer freeObjectsToPack(allocator, otp);
        try std.testing.expectEqual(@as(usize, 2), otp.len);
        try std.testing.expect(otp[0].object == storeObj(&store, ids.base));
        try std.testing.expect(otp[1].object == storeObj(&store, ids.tree_type));
        try std.testing.expect(!otp[0].isDelta());
        try std.testing.expect(!otp[1].isDelta());
    }

    // 2. Radically different sizes → no delta.
    {
        const hashes = [_]Hash{ ids.big_base, ids.target };
        const otp = try ds.objectsToPack(&hashes, window);
        defer freeObjectsToPack(allocator, otp);
        try std.testing.expectEqual(@as(usize, 2), otp.len);
        try std.testing.expect(otp[0].object == storeObj(&store, ids.big_base));
        try std.testing.expect(otp[1].object == storeObj(&store, ids.target));
        try std.testing.expect(!otp[0].isDelta());
        try std.testing.expect(!otp[1].isDelta());
    }

    // 3. Tiny objects → no delta (msz ≤ 8 / size budget).
    {
        const hashes = [_]Hash{ ids.small_base, ids.small_target };
        const otp = try ds.objectsToPack(&hashes, window);
        defer freeObjectsToPack(allocator, otp);
        try std.testing.expectEqual(@as(usize, 2), otp.len);
        try std.testing.expect(otp[0].object == storeObj(&store, ids.small_base));
        try std.testing.expect(otp[1].object == storeObj(&store, ids.small_target));
        try std.testing.expect(!otp[0].isDelta());
        try std.testing.expect(!otp[1].isDelta());
    }

    // 4. base/target → creates depth-1 delta (larger target first after sort).
    {
        const hashes = [_]Hash{ ids.base, ids.target };
        const otp = try ds.objectsToPack(&hashes, window);
        defer freeObjectsToPack(allocator, otp);
        try std.testing.expectEqual(@as(usize, 2), otp.len);
        try std.testing.expect(otp[0].object == storeObj(&store, ids.target));
        try std.testing.expect(!otp[0].isDelta());
        try std.testing.expect(otp[1].original == storeObj(&store, ids.base));
        try std.testing.expect(otp[1].isDelta());
        try std.testing.expectEqual(@as(i32, 1), otp[1].depth);
    }

    // 5. o1/o2/o3 chain: depths 0, 1, 2.
    {
        const hashes = [_]Hash{ ids.o1, ids.o2, ids.o3 };
        const otp = try ds.objectsToPack(&hashes, window);
        defer freeObjectsToPack(allocator, otp);
        try std.testing.expectEqual(@as(usize, 3), otp.len);
        try std.testing.expect(otp[0].object == storeObj(&store, ids.o1));
        try std.testing.expect(!otp[0].isDelta());
        try std.testing.expect(otp[1].original == storeObj(&store, ids.o2));
        try std.testing.expect(otp[1].isDelta());
        try std.testing.expectEqual(@as(i32, 1), otp[1].depth);
        try std.testing.expect(otp[2].original == storeObj(&store, ids.o3));
        try std.testing.expect(otp[2].isDelta());
        try std.testing.expectEqual(@as(i32, 2), otp[2].depth);
    }

    // 6. Sliding window: objects outside window produce no delta on target.
    //    Unsorted path: objectsToPackBuild + walk (go-git objectsToPack + walk).
    {
        var hashes_list: std.ArrayListUnmanaged(Hash) = .empty;
        defer hashes_list.deinit(allocator);
        try hashes_list.append(allocator, ids.base);
        var k: u32 = 0;
        while (k < window) : (k += 1) {
            try hashes_list.append(allocator, ids.small_target);
        }
        try hashes_list.append(allocator, ids.target);

        const otp = try ds.objectsToPackBuild(hashes_list.items, window);
        defer freeObjectsToPack(allocator, otp);
        try ds.walk(otp, window);
        try std.testing.expectEqual(@as(usize, window + 2), otp.len);
        const target_idx = otp.len - 1;
        try std.testing.expect(!otp[target_idx].isDelta());
    }

    // 7. pack_window 0: no deltas, original input order.
    {
        const hashes = [_]Hash{ ids.base, ids.target };
        const otp = try ds.objectsToPack(&hashes, 0);
        defer freeObjectsToPack(allocator, otp);
        try std.testing.expectEqual(@as(usize, 2), otp.len);
        try std.testing.expect(otp[0].object == storeObj(&store, ids.base));
        try std.testing.expect(!otp[0].isDelta());
        try std.testing.expect(otp[1].original == storeObj(&store, ids.target));
        try std.testing.expect(!otp[1].isDelta());
        try std.testing.expectEqual(@as(i32, 0), otp[1].depth);
    }
}

test "MapStore put overwrite deinit destroys previous and same pointer is safe" {
    // Ownership contract for test MapStore (and production ObjectStorage pattern):
    // put of a new object with an existing hash frees the old MemoryObject;
    // put of the same pointer must not double-free.
    const allocator = std.testing.allocator;
    var store: MapStore = .{ .allocator = allocator };
    defer store.deinit();

    const a = try newObject(allocator, .blob, "same-bytes");
    const b = try newObject(allocator, .blob, "same-bytes");
    const h1 = try store.put(a);
    const h2 = try store.put(b);
    try std.testing.expect(h1.eql(h2));
    try std.testing.expect(store.map.get(h1).? == b);

    // Same-pointer re-put: must keep the live object (no double free).
    const h3 = try store.put(b);
    try std.testing.expect(h3.eql(h1));
    try std.testing.expect(store.map.get(h1).? == b);
    try std.testing.expectEqualStrings("same-bytes", b.readerBytes());
}

test "many getDelta and ObjectsToPack then deinitPools has zero leaks" {
    // End-to-end ownership under testing.allocator:
    // 1. getDelta creates owned OFS delta MemoryObjects
    // 2. ObjectsToPack creates more deltas via getDeltaWithIndex
    // 3. freeObjectsToPack frees only delta bodies (not store originals)
    // 4. deinitPools drains BytesBuffer free-list nodes
    // Any missed free fails this test via GPA leak detection.
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var store: MapStore = .{ .allocator = allocator };
    defer store.deinit();

    // Shared prefix so windowed delta search finds profitable matches.
    var shared: [1500]u8 = undefined;
    @memset(shared[0..1000], 'x');
    @memset(shared[1000..1500], 'y');

    var hashes_buf: [24]Hash = undefined;
    var n_hashes: usize = 0;

    var i: usize = 0;
    while (i < 12) : (i += 1) {
        var content: [2000]u8 = undefined;
        @memcpy(content[0..1500], &shared);
        // Distinct suffix so each object has a unique hash.
        @memset(content[1500..2000], @as(u8, '0') +% @as(u8, @intCast(i % 10)));
        content[1999] = @intCast(i);

        const obj = try newObject(allocator, .blob, &content);
        hashes_buf[n_hashes] = try store.put(obj);
        n_hashes += 1;
    }

    // --- getDelta path (owned deltas, freed here) ---
    {
        const base_obj = store.map.get(hashes_buf[0]).?;
        var d: usize = 1;
        while (d < n_hashes) : (d += 1) {
            const tgt_obj = store.map.get(hashes_buf[d]).?;
            const delta = try diff_delta.getDelta(allocator, base_obj, tgt_obj);
            defer {
                delta.deinit();
                allocator.destroy(delta);
            }
            try std.testing.expectEqual(ObjectType.ofs_delta, delta.object_type);
        }
    }

    // --- ObjectsToPack path (deltas freed by freeObjectsToPack) ---
    var ds = DeltaSelector.init(allocator, Store.from(MapStore, &store));
    const otp = try ds.objectsToPack(hashes_buf[0..n_hashes], 10);
    defer freeObjectsToPack(allocator, otp);

    try std.testing.expectEqual(n_hashes, otp.len);

    var n_deltas: usize = 0;
    for (otp) |p| {
        if (p.isDelta()) {
            n_deltas += 1;
            // Delta body must not alias the store original.
            if (p.original) |orig| {
                try std.testing.expect(p.object != orig);
            }
            try std.testing.expect(p.object != null);
            try std.testing.expectEqual(ObjectType.ofs_delta, p.object.?.object_type);
        } else {
            // Non-delta: object is the store original (must survive freeObjectsToPack).
            if (p.object) |obj| {
                if (p.original) |orig| {
                    try std.testing.expect(obj == orig);
                }
            }
        }
    }
    // Related blobs in a window of 10 should yield at least one delta.
    try std.testing.expect(n_deltas > 0);

    // After freeObjectsToPack (via defer), every store object must still be live.
    // Checked implicitly: store.deinit frees them without double-free.
}
