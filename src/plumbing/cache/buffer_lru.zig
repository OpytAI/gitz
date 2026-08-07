//! Buffer LRU cache — port of go-git `plumbing/cache/buffer_lru.go`.
//!
//! Keys are `i64` (pack offsets). Values are owned `[]u8` copies allocated on
//! `put`. `get` returns a borrowed view of that owned buffer; do not free it.
//!
//! # Threading
//!
//! Single-threaded by design (same model as `utils/sync` free lists). go-git
//! guards `BufferLRU` with `sync.Mutex`. Concurrent `put` / `get` / `clear` from
//! multiple threads is not supported.
//!
//! Size units come from `common.zig` (`FileSize`, `Byte`, `DefaultMaxSize`, …).

const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;
const FileSize = common.FileSize;
const Byte = common.Byte;
const DefaultMaxSize = common.DefaultMaxSize;

// ---------------------------------------------------------------------------
// Entry (intrusive list node + owned buffer)
// ---------------------------------------------------------------------------

const Entry = struct {
    node: std.DoublyLinkedList.Node = .{},
    key: i64,
    /// Owned copy of the cached buffer.
    slice: []u8,
};

// ---------------------------------------------------------------------------
// BufferLru
// ---------------------------------------------------------------------------

/// Buffer cache with LRU eviction and a maximum size measured in bytes
/// (go-git `BufferLRU`).
pub const BufferLru = struct {
    allocator: Allocator,
    /// Maximum total size of cached buffers (go-git `MaxSize`).
    max_size: FileSize,
    /// Sum of lengths of currently cached buffers (go-git `actualSize`).
    actual_size: FileSize = 0,
    /// Front = most recently used; back = least recently used.
    list: std.DoublyLinkedList = .{},
    map: std.AutoHashMapUnmanaged(i64, *Entry) = .empty,

    /// Create a cache with the given maximum size (go-git `NewBufferLRU`).
    pub fn init(allocator: Allocator, max_size: FileSize) BufferLru {
        return .{
            .allocator = allocator,
            .max_size = max_size,
        };
    }

    /// Create a cache with `DefaultMaxSize` (go-git `NewBufferLRUDefault`).
    pub fn initDefault(allocator: Allocator) BufferLru {
        return init(allocator, DefaultMaxSize);
    }

    /// Insert or refresh a buffer (go-git `Put`).
    ///
    /// Duplicates `slice` with the cache allocator (Zig ownership). If `key` is
    /// new and `slice.len > max_size`, the put is a no-op. Existing keys are
    /// always updated; eviction may then remove LRU entries (and possibly the
    /// entry itself if it alone exceeds `max_size`).
    pub fn put(self: *BufferLru, key: i64, slice: []const u8) Allocator.Error!void {
        if (self.map.get(key)) |entry| {
            const old_len = entry.slice.len;
            const new_copy = try self.allocator.dupe(u8, slice);
            self.allocator.free(entry.slice);
            entry.slice = new_copy;
            const delta: FileSize =
                @as(FileSize, @intCast(new_copy.len)) - @as(FileSize, @intCast(old_len));
            self.moveToFront(entry);
            self.actual_size += delta;
        } else {
            const buf_size: FileSize = @intCast(slice.len);
            if (buf_size > self.max_size) return;

            const entry = try self.allocator.create(Entry);
            errdefer self.allocator.destroy(entry);
            const new_copy = try self.allocator.dupe(u8, slice);
            errdefer self.allocator.free(new_copy);
            entry.* = .{
                .key = key,
                .slice = new_copy,
            };
            self.list.prepend(&entry.node);
            errdefer self.list.remove(&entry.node);
            try self.map.put(self.allocator, key, entry);
            self.actual_size += buf_size;
        }

        while (self.actual_size > self.max_size) {
            self.evictLast();
        }
    }

    /// Return the buffer for `key` and mark it as recently used (go-git `Get`).
    /// Returns `null` if the key is not cached. The slice is borrowed; free only
    /// via `clear` / `deinit` / later `put` / eviction.
    pub fn get(self: *BufferLru, key: i64) ?[]const u8 {
        const entry = self.map.get(key) orelse return null;
        self.moveToFront(entry);
        return entry.slice;
    }

    /// Drop every cached buffer (go-git `Clear`). Keeps `max_size` and allocator.
    pub fn clear(self: *BufferLru) void {
        var it = self.map.iterator();
        while (it.next()) |kv| {
            self.freeEntry(kv.value_ptr.*);
        }
        self.map.clearAndFree(self.allocator);
        self.list = .{};
        self.actual_size = 0;
    }

    /// Free all entries and the map. Invalidates `self`.
    pub fn deinit(self: *BufferLru) void {
        self.clear();
        self.* = undefined;
    }

    fn moveToFront(self: *BufferLru, entry: *Entry) void {
        self.list.remove(&entry.node);
        entry.node = .{};
        self.list.prepend(&entry.node);
    }

    fn evictLast(self: *BufferLru) void {
        const node = self.list.pop() orelse {
            // go-git BufferLRU assumes a non-empty list when actualSize > MaxSize;
            // ObjectLRU nil-guards and zeroes actualSize — match ObjectLRU safety.
            self.actual_size = 0;
            return;
        };
        const entry: *Entry = @fieldParentPtr("node", node);
        _ = self.map.remove(entry.key);
        self.actual_size -= @intCast(entry.slice.len);
        self.freeEntry(entry);
    }

    fn freeEntry(self: *BufferLru, entry: *Entry) void {
        self.allocator.free(entry.slice);
        self.allocator.destroy(entry);
    }
};

// ---------------------------------------------------------------------------
// Tests — port of go-git `buffer_test.go` (names match go-git suite methods)
// ---------------------------------------------------------------------------

const a_buffer = "a";
const b_buffer = "bbb";
const c_buffer = "c";
const d_buffer = "d";
const e_buffer = "ee";

test "BufferSuite.TestPutSameBuffer" {
    // go-git BufferSuite.TestPutSameBuffer — two_bytes + default_lru.
    const cases = [_]FileSize{ 2 * Byte, DefaultMaxSize };
    for (cases) |max| {
        var o = BufferLru.init(testing.allocator, max);
        defer o.deinit();
        try o.put(1, a_buffer);
        try o.put(1, a_buffer);
        try testing.expect(o.get(1) != null);
    }
}

test "BufferSuite.TestPutSameBufferWithDifferentSize" {
    // go-git TestPutSameBufferWithDifferentSize (attached to ObjectSuite by mistake).
    var cache = BufferLru.init(testing.allocator, 7 * Byte);
    defer cache.deinit();

    try cache.put(1, "a");
    try cache.put(1, "bbb");
    try cache.put(1, "ccccc");
    try cache.put(1, "ddddddd");

    try testing.expectEqual(@as(FileSize, 7 * Byte), cache.max_size);
    try testing.expectEqual(@as(FileSize, 7 * Byte), cache.actual_size);
    try testing.expectEqual(@as(usize, 1), cache.list.len());

    const buf = cache.get(1).?;
    try testing.expectEqualStrings("ddddddd", buf);
    try testing.expectEqual(@as(FileSize, 7 * Byte), @as(FileSize, @intCast(buf.len)));
}

test "BufferSuite.TestPutBigBuffer" {
    // go-git BufferSuite.TestPutBigBuffer — oversized for two_bytes; fine for default.
    const cases = [_]FileSize{ 2 * Byte, DefaultMaxSize };
    for (cases) |max| {
        var o = BufferLru.init(testing.allocator, max);
        defer o.deinit();
        try o.put(1, b_buffer);
        try testing.expect(o.get(2) == null);
    }
}

test "BufferSuite.TestPutCacheOverflow" {
    // go-git BufferSuite.TestPutCacheOverflow — only valid for max size 2 bytes.
    var o = BufferLru.init(testing.allocator, 2 * Byte);
    defer o.deinit();

    try o.put(1, a_buffer);
    try o.put(2, c_buffer);
    try o.put(3, d_buffer);

    try testing.expect(o.get(1) == null);
    try testing.expect(o.get(2) != null);
    try testing.expect(o.get(3) != null);
}

test "BufferSuite.TestEvictMultipleBuffers" {
    // go-git BufferSuite.TestEvictMultipleBuffers.
    var o = BufferLru.init(testing.allocator, 2 * Byte);
    defer o.deinit();

    try o.put(1, c_buffer);
    try o.put(2, d_buffer); // cache full (2 bytes)
    try o.put(3, e_buffer); // size 2 — must evict both previous entries

    try testing.expect(o.get(1) == null);
    try testing.expect(o.get(2) == null);
    const got = o.get(3).?;
    try testing.expectEqualStrings(e_buffer, got);
}

test "BufferSuite.TestClear" {
    // go-git BufferSuite.TestClear — two_bytes + default_lru.
    const cases = [_]FileSize{ 2 * Byte, DefaultMaxSize };
    for (cases) |max| {
        var o = BufferLru.init(testing.allocator, max);
        defer o.deinit();
        try o.put(1, a_buffer);
        o.clear();
        try testing.expect(o.get(1) == null);
        try testing.expectEqual(@as(FileSize, 0), o.actual_size);
    }
}

test "BufferSuite.TestConcurrentAccess" {
    // go-git BufferSuite.TestConcurrentAccess uses goroutines + mutex.
    // This Zig cache is single-threaded by design (utils/sync model). Port as
    // sequential stress: interleave put / get / clear for both cache sizes.
    const cases = [_]FileSize{ 2 * Byte, DefaultMaxSize };
    for (cases) |max| {
        var o = BufferLru.init(testing.allocator, max);
        defer o.deinit();
        var i: i64 = 0;
        while (i < 1000) : (i += 1) {
            try o.put(i, &[_]u8{0});
            if (@rem(i, 30) == 0) o.clear();
            _ = o.get(i);
        }
    }
}

test "BufferSuite.TestDefaultLRU" {
    // go-git BufferSuite.TestDefaultLRU.
    var default_lru = BufferLru.initDefault(testing.allocator);
    defer default_lru.deinit();
    try testing.expectEqual(DefaultMaxSize, default_lru.max_size);
}

// Extra coverage (not in go-git buffer_test.go; keep for MRU / content edge cases).

test "BufferSuite.GetMovesToFront" {
    var c = BufferLru.init(testing.allocator, 3 * Byte);
    defer c.deinit();
    try c.put(1, "a");
    try c.put(2, "b");
    try c.put(3, "c");
    // Order MRU→LRU: 3, 2, 1. Touch 1 → MRU is 1, LRU is 2.
    _ = c.get(1);
    try c.put(4, "d"); // need 1 byte free; evict key 2
    try testing.expect(c.get(2) == null);
    try testing.expect(c.get(1) != null);
    try testing.expect(c.get(3) != null);
    try testing.expect(c.get(4) != null);
}

test "BufferSuite.PutUpdatesContent" {
    var c = BufferLru.init(testing.allocator, 16 * Byte);
    defer c.deinit();
    try c.put(42, "hello");
    try c.put(42, "world!");
    try testing.expectEqualStrings("world!", c.get(42).?);
    try testing.expectEqual(@as(FileSize, 6), c.actual_size);
}

test "BufferSuite.EmptyPutAndGetMiss" {
    var c = BufferLru.init(testing.allocator, 8 * Byte);
    defer c.deinit();
    try testing.expect(c.get(0) == null);
    try c.put(0, "");
    try testing.expectEqualStrings("", c.get(0).?);
    try testing.expectEqual(@as(FileSize, 0), c.actual_size);
}
