//! Byte buffer and byte-slice free lists.
//!
//! Port of go-git `utils/sync` bytes helpers (`GetBytesBuffer`, `PutBytesBuffer`,
//! `GetByteSlice`, `PutByteSlice`).
//!
//! Single-threaded free lists (not a mutex-backed `sync.Pool`). Call
//! `deinitBytesPools` under leak-checking allocators.

const std = @import("std");
const Allocator = std.mem.Allocator;
const FreeList = @import("free_list.zig").FreeList;

/// Initial length of pooled byte slices (16 KiB), matching go-git.
pub const byte_slice_len: usize = 16 * 1024;

/// Growable byte buffer (Zig `ArrayList(u8)`), analogous to Go `bytes.Buffer`.
pub const BytesBuffer = std.ArrayList(u8);

const BytesBufferNode = struct {
    list: BytesBuffer = .empty,
    next: ?*BytesBufferNode = null,
};

const ByteSliceNode = struct {
    slice: []u8,
    next: ?*ByteSliceNode = null,
};

var free_bytes_buffers: FreeList(BytesBufferNode) = .{};
var free_byte_slices: FreeList(ByteSliceNode) = .{};

/// Returns a cleared growable buffer from the free list (or a new one).
/// After use, return it with `putBytesBuffer`. Do not `destroy` the pointer.
pub fn getBytesBuffer(allocator: Allocator) Allocator.Error!*BytesBuffer {
    if (free_bytes_buffers.get()) |node| {
        node.list.clearRetainingCapacity();
        return &node.list;
    }
    const node = try allocator.create(BytesBufferNode);
    node.* = .{};
    return &node.list;
}

/// Returns `buf` to the free list. Capacity is retained (like go-git).
pub fn putBytesBuffer(buf: *BytesBuffer) void {
    const node: *BytesBufferNode = @fieldParentPtr("list", buf);
    free_bytes_buffers.put(node);
}

/// Returns a `*[]u8` workspace of length `byte_slice_len` (or larger if a
/// previously put larger slice is reused).
pub fn getByteSlice(allocator: Allocator) Allocator.Error!*[]u8 {
    if (free_byte_slices.get()) |node| {
        return &node.slice;
    }
    const node = try allocator.create(ByteSliceNode);
    errdefer allocator.destroy(node);
    const mem = try allocator.alloc(u8, byte_slice_len);
    node.* = .{ .slice = mem };
    return &node.slice;
}

/// Returns `slice_ptr` to the free list.
pub fn putByteSlice(slice_ptr: *[]u8) void {
    const node: *ByteSliceNode = @fieldParentPtr("slice", slice_ptr);
    free_byte_slices.put(node);
}

/// Frees all entries retained by the byte free lists.
pub fn deinitBytesPools(allocator: Allocator) void {
    free_bytes_buffers.drain(allocator, struct {
        fn destroy(a: Allocator, node: *BytesBufferNode) void {
            node.list.deinit(a);
            a.destroy(node);
        }
    }.destroy);
    free_byte_slices.drain(allocator, struct {
        fn destroy(a: Allocator, node: *ByteSliceNode) void {
            a.free(node.slice);
            a.destroy(node);
        }
    }.destroy);
}

test "getBytesBuffer put reuses buffer capacity" {
    const gpa = std.testing.allocator;
    defer deinitBytesPools(gpa);

    const buf = try getBytesBuffer(gpa);
    try buf.appendSlice(gpa, "hello");
    try std.testing.expectEqual(@as(usize, 5), buf.items.len);
    const cap_after_grow = blk: {
        try buf.ensureTotalCapacity(gpa, 64);
        break :blk buf.capacity;
    };
    try std.testing.expect(cap_after_grow >= 64);
    putBytesBuffer(buf);

    const again = try getBytesBuffer(gpa);
    try std.testing.expect(again == buf);
    try std.testing.expectEqual(@as(usize, 0), again.items.len);
    try std.testing.expectEqual(cap_after_grow, again.capacity);
    putBytesBuffer(again);
}

test "getByteSlice initial length and reuse" {
    const gpa = std.testing.allocator;
    defer deinitBytesPools(gpa);

    const slice = try getByteSlice(gpa);
    try std.testing.expectEqual(byte_slice_len, slice.len);
    putByteSlice(slice);

    const again = try getByteSlice(gpa);
    try std.testing.expect(again == slice);
    try std.testing.expectEqual(byte_slice_len, again.len);
    putByteSlice(again);
}
