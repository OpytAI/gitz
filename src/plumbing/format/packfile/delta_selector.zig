//! Delta window selection for pack encoding (go-git `delta_selector.go`).
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

        // go-git uses plumbing.DeltaObject.BaseHash(). This port has no
        // DeltaObject type on MemoryObject, so break the chain (undeltify).
        // When a future storer returns richer delta metadata, wire BaseHash here.
        _ = objects;
        try self.undeltify(otp);
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
            if (target.isDelta()) {
                if (target.object) |old| {
                    // Previous OFS delta body from an earlier tryToDeltify.
                    old.deinit();
                    self.allocator.destroy(old);
                }
            }
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
/// Frees each `ObjectToPack` node and any delta `MemoryObject` attached when
/// `isDelta()`. Store-owned originals are not freed.
pub fn freeObjectsToPack(allocator: Allocator, otps: []*ObjectToPack) void {
    // Empty literal `&.{}` must not be freed (not allocator-owned).
    if (otps.len == 0) return;
    for (otps) |otp| {
        // Free only OFS/REF delta *bodies* created by getDeltaWithIndex.
        // Store-owned originals stay alive for the storer.
        if (otp.isDelta()) {
            if (otp.object) |obj| {
                const is_store_original = if (otp.original) |orig| obj == orig else false;
                if (!is_store_original) {
                    obj.deinit();
                    allocator.destroy(obj);
                    otp.object = null;
                }
            }
        }
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
        if (std.mem.eql(u8, spec.id, "bigBase")) ids.big_base = h;
    }

    {
        const obj = try newObject(allocator, .tree, "I am a tree!");
        ids.tree_type = try store.put(obj);
    }

    return ids;
}

test "sort by type and size" {
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

test "deltaSizeLimit at maxDepth" {
    // go-git TestMaxDepth
    const dsl = deltaSizeLimit(0, 0, @intCast(max_depth), true);
    try std.testing.expectEqual(@as(i64, 0), dsl);
}

test "ObjectsToPack pack_window 0 preserves order without deltas" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var store: MapStore = .{ .allocator = allocator };
    defer store.deinit();

    const a = try newObject(allocator, .blob, "aaaaaaaaaaaaaaaa"); // 16 bytes
    const b = try newObject(allocator, .blob, "bbbbbbbbbbbbbbbb");
    const ha = try store.put(a);
    const hb = try store.put(b);

    var ds = DeltaSelector.init(allocator, Store.from(MapStore, &store));
    const hashes = [_]Hash{ ha, hb };
    const otp = try ds.objectsToPack(&hashes, 0);
    defer freeObjectsToPack(allocator, otp);
    try std.testing.expectEqual(@as(usize, 2), otp.len);
    try std.testing.expect(!otp[0].isDelta());
    try std.testing.expect(!otp[1].isDelta());
    try std.testing.expect(otp[0].object == a);
    try std.testing.expect(otp[1].object == b);
}

test "ObjectsToPack creates OFS delta within window" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var store: MapStore = .{ .allocator = allocator };
    defer store.deinit();

    // Related content so DiffDelta finds a win under the size budget.
    var base_buf: [2000]u8 = undefined;
    @memset(base_buf[0..1000], 'a');
    @memset(base_buf[1000..2000], 'b');
    var tgt_buf: [3000]u8 = undefined;
    @memcpy(tgt_buf[0..2000], &base_buf);
    @memset(tgt_buf[2000..3000], 'c');

    const base = try newObject(allocator, .blob, &base_buf);
    const target = try newObject(allocator, .blob, &tgt_buf);
    const hb = try store.put(base);
    const ht = try store.put(target);

    var ds = DeltaSelector.init(allocator, Store.from(MapStore, &store));
    const hashes = [_]Hash{ hb, ht };
    const otp = try ds.objectsToPack(&hashes, 10);
    defer freeObjectsToPack(allocator, otp);

    try std.testing.expectEqual(@as(usize, 2), otp.len);
    // Larger object first after sort; smaller becomes a delta of it.
    try std.testing.expect(!otp[0].isDelta());
    try std.testing.expect(otp[1].isDelta());
    try std.testing.expectEqual(@as(i32, 1), otp[1].depth);
}
