//! Buffered-reader free list.
//!
//! Port of go-git `utils/sync` bufio helpers (`GetBufioReader`, `PutBufioReader`).
//!
//! Zig 0.16 uses `std.Io.Reader` rather than Go `bufio.Reader`. This pool
//! recycles fixed-size intermediate buffers that callers pair with an upstream
//! reader (same role as the buffer inside Go's `bufio.Reader`).
//!
//! Single-threaded. Call `deinitBufioPools` under leak checkers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const FreeList = @import("free_list.zig").FreeList;

/// Default intermediate buffer size for pooled bufio readers (4 KiB).
pub const bufio_buffer_len: usize = 4 * 1024;

/// Pooled buffered-reader workspace (go-git `*bufio.Reader` analogue).
pub const BufioReader = struct {
    buffer: []u8,
    /// Upstream set by the last `reset` / `getBufioReader` (not owned).
    upstream: ?*Reader = null,
    next: ?*BufioReader = null,

    pub fn reset(self: *BufioReader, upstream: *Reader) void {
        self.upstream = upstream;
    }

    pub fn bufferSlice(self: *const BufioReader) []u8 {
        return self.buffer;
    }
};

var free_bufio_readers: FreeList(BufioReader) = .{};

/// Returns a pooled buffered-reader workspace reset against `upstream`.
pub fn getBufioReader(allocator: Allocator, upstream: *Reader) Allocator.Error!*BufioReader {
    const br: *BufioReader = if (free_bufio_readers.get()) |node|
        node
    else blk: {
        const node = try allocator.create(BufioReader);
        errdefer allocator.destroy(node);
        const buf = try allocator.alloc(u8, bufio_buffer_len);
        errdefer allocator.free(buf);
        node.* = .{ .buffer = buf };
        break :blk node;
    };
    br.reset(upstream);
    return br;
}

/// Returns `br` to the free list.
pub fn putBufioReader(br: *BufioReader) void {
    br.upstream = null;
    free_bufio_readers.put(br);
}

/// Frees all pooled bufio readers.
pub fn deinitBufioPools(allocator: Allocator) void {
    free_bufio_readers.drain(allocator, struct {
        fn destroy(a: Allocator, node: *BufioReader) void {
            a.free(node.buffer);
            a.destroy(node);
        }
    }.destroy);
}

test "getBufioReader put reuses buffer" {
    const gpa = std.testing.allocator;
    defer deinitBufioPools(gpa);

    var src_buf: [16]u8 = undefined;
    var src: Reader = .fixed(&src_buf);

    const br = try getBufioReader(gpa, &src);
    try std.testing.expectEqual(bufio_buffer_len, br.buffer.len);
    try std.testing.expect(br.upstream == &src);
    const ptr = br.buffer.ptr;
    putBufioReader(br);

    var src2_buf: [16]u8 = undefined;
    var src2: Reader = .fixed(&src2_buf);
    const again = try getBufioReader(gpa, &src2);
    try std.testing.expect(again == br);
    try std.testing.expect(again.buffer.ptr == ptr);
    try std.testing.expect(again.upstream == &src2);
    putBufioReader(again);
}
