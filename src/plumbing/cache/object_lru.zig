//! Object LRU cache (go-git `plumbing/cache/object_lru.go`).
//!
//! # Threading model
//!
//! go-git guards `ObjectLRU` with `sync.Mutex`. This Zig port is
//! **single-threaded** (same model as `utils/sync` free lists). Concurrent
//! put/get/clear from multiple threads is not supported.
//!
//! # Ownership
//!
//! The cache stores `*plumbing.MemoryObject` pointers. It does **not** own the
//! objects: callers keep ownership and free them. Cache entries (list nodes)
//! are owned by the cache and freed on eviction, `clear`, and `deinit`.
//!
//! Size units come from `common.zig` (`FileSize`, `Byte`, `DefaultMaxSize`, …).

const std = @import("std");
const plumbing = @import("plumbing");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const MemoryObject = plumbing.MemoryObject;
const FileSize = common.FileSize;
const Byte = common.Byte;
const DefaultMaxSize = common.DefaultMaxSize;

/// One cached object in the LRU list (intrusive node).
const Entry = struct {
    node: std.DoublyLinkedList.Node = .{},
    key: Hash,
    obj: *MemoryObject,
};

/// Object cache with LRU eviction by total object size (go-git `ObjectLRU`).
///
/// Construct with `init` / `initDefault`. Call `deinit` when done.
pub const ObjectLru = struct {
    allocator: Allocator,
    /// Maximum total cached object size (go-git `MaxSize`). Never exceeded after put.
    max_size: FileSize,
    actual_size: FileSize = 0,
    ll: std.DoublyLinkedList = .{},
    /// Hash → heap `Entry` still linked in `ll`.
    cache: std.AutoHashMapUnmanaged(Hash, *Entry) = .empty,

    /// go-git `NewObjectLRU` — empty cache with the given maximum size.
    pub fn init(allocator: Allocator, max_size: FileSize) ObjectLru {
        return .{
            .allocator = allocator,
            .max_size = max_size,
        };
    }

    /// go-git `NewObjectLRUDefault` — empty cache with `DefaultMaxSize`.
    pub fn initDefault(allocator: Allocator) ObjectLru {
        return init(allocator, DefaultMaxSize);
    }

    /// Free all cache entries. Does not free the stored `*MemoryObject` values.
    pub fn deinit(self: *ObjectLru) void {
        self.clear();
        self.* = undefined;
    }

    /// go-git `Put` — insert or refresh `obj`. Evicts least-recently-used
    /// objects until `actual_size <= max_size`. Skips insert when a **new**
    /// object's size alone is greater than `max_size`.
    pub fn put(self: *ObjectLru, obj: *MemoryObject) Allocator.Error!void {
        var obj_size: FileSize = obj.size;
        const key = obj.hash();

        if (self.cache.get(key)) |entry| {
            // Size delta: new size − old size (go-git).
            obj_size -= entry.obj.size;
            self.moveToFront(entry);
            entry.obj = obj;
        } else {
            if (obj_size > self.max_size) return;
            const entry = try self.allocator.create(Entry);
            errdefer self.allocator.destroy(entry);
            entry.* = .{
                .key = key,
                .obj = obj,
            };
            try self.cache.put(self.allocator, key, entry);
            self.ll.prepend(&entry.node);
        }

        self.actual_size += obj_size;
        while (self.actual_size > self.max_size) {
            const last_node = self.ll.last orelse {
                self.actual_size = 0;
                break;
            };
            const last: *Entry = @fieldParentPtr("node", last_node);
            const last_size: FileSize = last.obj.size;
            self.ll.remove(last_node);
            _ = self.cache.remove(last.key);
            self.allocator.destroy(last);
            self.actual_size -= last_size;
        }
    }

    /// go-git `Get` — return the object and mark it most-recently-used.
    /// `null` when missing.
    pub fn get(self: *ObjectLru, k: Hash) ?*MemoryObject {
        const entry = self.cache.get(k) orelse return null;
        self.moveToFront(entry);
        return entry.obj;
    }

    /// Drop one key if present. Does not free the `*MemoryObject` (caller owns it).
    pub fn remove(self: *ObjectLru, k: Hash) void {
        const entry = self.cache.fetchRemove(k) orelse return;
        self.ll.remove(&entry.value.node);
        const size: FileSize = entry.value.obj.size;
        if (self.actual_size >= size) self.actual_size -= size else self.actual_size = 0;
        self.allocator.destroy(entry.value);
    }

    /// go-git `Clear` — drop every entry. Stored objects are not freed.
    pub fn clear(self: *ObjectLru) void {
        var it = self.cache.iterator();
        while (it.next()) |kv| {
            self.allocator.destroy(kv.value_ptr.*);
        }
        self.cache.clearAndFree(self.allocator);
        self.ll = .{};
        self.actual_size = 0;
    }

    fn moveToFront(self: *ObjectLru, entry: *Entry) void {
        // DoublyLinkedList.Node must be detached before re-prepend (Zig list invariant).
        self.ll.remove(&entry.node);
        entry.node = .{};
        self.ll.prepend(&entry.node);
    }
};

// ---------------------------------------------------------------------------
// Tests (go-git `object_test.go` — names match suite methods)
// ---------------------------------------------------------------------------

/// Test double: fixed hash + declared size (go-git `dummyObject` / `newObject`).
fn newObject(allocator: Allocator, hash_hex: []const u8, size: FileSize) !*MemoryObject {
    const obj = try allocator.create(MemoryObject);
    obj.* = MemoryObject.init(allocator);
    obj.cached_hash = plumbing.newHash(hash_hex);
    obj.size = size;
    return obj;
}

fn freeObject(allocator: Allocator, obj: *MemoryObject) void {
    obj.deinit();
    allocator.destroy(obj);
}

const hash_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const hash_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const hash_c = "cccccccccccccccccccccccccccccccccccccccc";
const hash_d = "dddddddddddddddddddddddddddddddddddddddd";
const hash_e = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";

test "ObjectSuite.TestPutSameObject" {
    // go-git ObjectSuite.TestPutSameObject — two_bytes + default_lru.
    const gpa = std.testing.allocator;
    var two = ObjectLru.init(gpa, 2 * Byte);
    defer two.deinit();
    var def = ObjectLru.initDefault(gpa);
    defer def.deinit();

    const a = try newObject(gpa, hash_a, 1 * Byte);
    defer freeObject(gpa, a);

    for ([_]*ObjectLru{ &two, &def }) |o| {
        try o.put(a);
        try o.put(a);
        try std.testing.expect(o.get(a.hash()) != null);
    }
}

test "ObjectSuite.TestPutSameObjectWithDifferentSize" {
    // go-git ObjectSuite.TestPutSameObjectWithDifferentSize.
    const gpa = std.testing.allocator;
    var cache = ObjectLru.init(gpa, 7 * Byte);
    defer cache.deinit();

    const o1 = try newObject(gpa, hash_a, 1 * Byte);
    defer freeObject(gpa, o1);
    const o3 = try newObject(gpa, hash_a, 3 * Byte);
    defer freeObject(gpa, o3);
    const o5 = try newObject(gpa, hash_a, 5 * Byte);
    defer freeObject(gpa, o5);
    const o7 = try newObject(gpa, hash_a, 7 * Byte);
    defer freeObject(gpa, o7);

    try cache.put(o1);
    try cache.put(o3);
    try cache.put(o5);
    try cache.put(o7);

    try std.testing.expectEqual(@as(FileSize, 7 * Byte), cache.max_size);
    try std.testing.expectEqual(@as(FileSize, 7 * Byte), cache.actual_size);
    try std.testing.expectEqual(@as(usize, 1), cache.ll.len());

    const got = cache.get(plumbing.newHash(hash_a));
    try std.testing.expect(got != null);
    try std.testing.expect(got.?.hash().eql(plumbing.newHash(hash_a)));
    try std.testing.expectEqual(@as(FileSize, 7 * Byte), got.?.size);
}

test "ObjectSuite.TestPutBigObject" {
    // go-git ObjectSuite.TestPutBigObject — 3-byte object vs max 2 / default.
    const gpa = std.testing.allocator;
    var two = ObjectLru.init(gpa, 2 * Byte);
    defer two.deinit();
    var def = ObjectLru.initDefault(gpa);
    defer def.deinit();

    const a = try newObject(gpa, hash_a, 1 * Byte);
    defer freeObject(gpa, a);
    const b = try newObject(gpa, hash_b, 3 * Byte);
    defer freeObject(gpa, b);

    for ([_]*ObjectLru{ &two, &def }) |o| {
        try o.put(b);
        try std.testing.expect(o.get(a.hash()) == null);
    }
}

test "ObjectSuite.TestPutCacheOverflow" {
    // go-git ObjectSuite.TestPutCacheOverflow — only for MaxSize = 2 bytes.
    const gpa = std.testing.allocator;
    var o = ObjectLru.init(gpa, 2 * Byte);
    defer o.deinit();

    const a = try newObject(gpa, hash_a, 1 * Byte);
    defer freeObject(gpa, a);
    const c = try newObject(gpa, hash_c, 1 * Byte);
    defer freeObject(gpa, c);
    const d = try newObject(gpa, hash_d, 1 * Byte);
    defer freeObject(gpa, d);

    try o.put(a);
    try o.put(c);
    try o.put(d);

    try std.testing.expect(o.get(a.hash()) == null);
    try std.testing.expect(o.get(c.hash()) != null);
    try std.testing.expect(o.get(d.hash()) != null);
}

test "ObjectSuite.TestEvictMultipleObjects" {
    // go-git ObjectSuite.TestEvictMultipleObjects.
    const gpa = std.testing.allocator;
    var o = ObjectLru.init(gpa, 2 * Byte);
    defer o.deinit();

    const c = try newObject(gpa, hash_c, 1 * Byte);
    defer freeObject(gpa, c);
    const d = try newObject(gpa, hash_d, 1 * Byte);
    defer freeObject(gpa, d);
    const e = try newObject(gpa, hash_e, 2 * Byte);
    defer freeObject(gpa, e);

    try o.put(c);
    try o.put(d); // full with two 1-byte objects
    try o.put(e); // evicts both previous objects

    try std.testing.expect(o.get(c.hash()) == null);
    try std.testing.expect(o.get(d.hash()) == null);
    try std.testing.expect(o.get(e.hash()) != null);
}

test "ObjectSuite.TestClear" {
    // go-git ObjectSuite.TestClear — two_bytes + default_lru.
    const gpa = std.testing.allocator;
    var two = ObjectLru.init(gpa, 2 * Byte);
    defer two.deinit();
    var def = ObjectLru.initDefault(gpa);
    defer def.deinit();

    const a = try newObject(gpa, hash_a, 1 * Byte);
    defer freeObject(gpa, a);

    for ([_]*ObjectLru{ &two, &def }) |o| {
        try o.put(a);
        o.clear();
        try std.testing.expect(o.get(a.hash()) == null);
    }
}

test "ObjectSuite.TestConcurrentAccess" {
    // go-git ObjectSuite.TestConcurrentAccess uses goroutines + mutex.
    // This Zig cache is single-threaded by design (utils/sync model). Port as
    // sequential stress: interleave put / get / clear for both cache sizes.
    //
    // go-git `newObject(fmt.Sprint(i), FileSize(i))` builds a hash from the
    // decimal string of i (not a full 40-hex digest). MemoryObject.hash() only
    // uses `cached_hash` when set; we set a synthetic 20-byte key from i so
    // each iteration has a distinct map key without needing valid hex.
    const gpa = std.testing.allocator;
    var two = ObjectLru.init(gpa, 2 * Byte);
    defer two.deinit();
    var def = ObjectLru.initDefault(gpa);
    defer def.deinit();

    var objs: [1000]*MemoryObject = undefined;
    defer {
        for (objs) |obj| freeObject(gpa, obj);
    }

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const obj = try gpa.create(MemoryObject);
        obj.* = MemoryObject.init(gpa);
        // Non-zero first byte so MemoryObject.hash() returns cached_hash (not recompute).
        var key_bytes: [20]u8 = .{0} ** 20;
        key_bytes[0] = 0xff;
        const n: u64 = @intCast(i);
        std.mem.writeInt(u64, key_bytes[1..9], n, .little);
        obj.cached_hash = Hash.fromBytes(key_bytes[0..]);
        // Cap declared size so default_lru does not grow without bound in this stress loop.
        obj.size = @intCast(@min(i, 64));
        objs[i] = obj;
    }

    for ([_]*ObjectLru{ &two, &def }) |o| {
        i = 0;
        while (i < 1000) : (i += 1) {
            try o.put(objs[i]);
            if (@rem(i, 30) == 0) o.clear();
            _ = o.get(objs[i].hash());
        }
        o.clear();
    }
}

test "ObjectSuite.TestDefaultLRU" {
    // go-git ObjectSuite.TestDefaultLRU.
    const gpa = std.testing.allocator;
    var def = ObjectLru.initDefault(gpa);
    defer def.deinit();
    try std.testing.expectEqual(DefaultMaxSize, def.max_size);
}

test "ObjectSuite.TestObjectUpdateOverflow" {
    // go-git ObjectSuite.TestObjectUpdateOverflow — mutates size after put.
    const gpa = std.testing.allocator;
    var o = ObjectLru.init(gpa, 9 * Byte);
    defer o.deinit();

    const a1 = try newObject(gpa, hash_a, 9 * Byte);
    defer freeObject(gpa, a1);
    const a2 = try newObject(gpa, hash_a, 1 * Byte);
    defer freeObject(gpa, a2);
    const b = try newObject(gpa, hash_b, 1 * Byte);
    defer freeObject(gpa, b);

    try o.put(a1);
    a1.setSize(-5);
    try o.put(a2);
    try o.put(b);
}
