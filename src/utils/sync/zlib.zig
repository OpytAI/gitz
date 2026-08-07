//! Zlib writer free list.
//!
//! Port of go-git `utils/sync` zlib helpers (`GetZlibWriter`, `PutZlibWriter`).
//!
//! Zig 0.16 has no `std.compress.zlib` module. Zlib container framing is
//! provided by `std.compress.flate` with `.zlib`. Pooled state is the flate
//! window buffer; each `getZlibWriter` re-inits a `flate.Compress`.
//!
//! Single-threaded. Call `deinitZlibPools` under leak checkers.

const std = @import("std");
const flate = std.compress.flate;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const FreeList = @import("free_list.zig").FreeList;

/// Pooled zlib compressor (go-git `*zlib.Writer` analogue).
/// Write uncompressed bytes via `writer()`, then `finish()`, then `putZlibWriter`.
pub const ZlibWriter = struct {
    window: []u8,
    compress: flate.Compress,
    next: ?*ZlibWriter = null,

    pub fn writer(self: *ZlibWriter) *Writer {
        return &self.compress.writer;
    }

    /// Complete the zlib stream (footer).
    pub fn finish(self: *ZlibWriter) Writer.Error!void {
        try self.compress.finish();
    }
};

var free_zlib_writers: FreeList(ZlibWriter) = .{};

/// Returns a zlib compressor that writes a zlib-framed deflate stream to `output`.
/// `output` must remain valid until `finish` / `putZlibWriter` and have buffer
/// capacity greater than 8 bytes (flate requirement).
pub fn getZlibWriter(allocator: Allocator, output: *Writer) (Allocator.Error || Writer.Error)!*ZlibWriter {
    const zw: *ZlibWriter = if (free_zlib_writers.get()) |node|
        node
    else blk: {
        const node = try allocator.create(ZlibWriter);
        errdefer allocator.destroy(node);
        const window = try allocator.alloc(u8, flate.max_window_len);
        errdefer allocator.free(window);
        node.* = .{ .window = window, .compress = undefined };
        break :blk node;
    };

    zw.compress = try flate.Compress.init(
        output,
        zw.window,
        .zlib,
        flate.Compress.Options.default,
    );
    return zw;
}

/// Returns `zw` to the free list. Window memory is retained for reuse.
pub fn putZlibWriter(zw: *ZlibWriter) void {
    zw.compress = undefined;
    free_zlib_writers.put(zw);
}

/// Frees all pooled zlib writers and their windows.
pub fn deinitZlibPools(allocator: Allocator) void {
    free_zlib_writers.drain(allocator, struct {
        fn destroy(a: Allocator, node: *ZlibWriter) void {
            a.free(node.window);
            a.destroy(node);
        }
    }.destroy);
}

test "getZlibWriter put reuses window" {
    const gpa = std.testing.allocator;
    defer deinitZlibPools(gpa);

    var out_buf: [4096]u8 = undefined;
    var out: Writer = .fixed(&out_buf);

    const zw = try getZlibWriter(gpa, &out);
    const window_ptr = zw.window.ptr;
    try zw.writer().writeAll("abc");
    try zw.finish();
    putZlibWriter(zw);

    var out2_buf: [4096]u8 = undefined;
    var out2: Writer = .fixed(&out2_buf);
    const again = try getZlibWriter(gpa, &out2);
    try std.testing.expect(again == zw);
    try std.testing.expect(again.window.ptr == window_ptr);
    putZlibWriter(again);
}

test "getZlibWriter produces zlib header bytes" {
    const gpa = std.testing.allocator;
    defer deinitZlibPools(gpa);

    var out_buf: [4096]u8 = undefined;
    var out: Writer = .fixed(&out_buf);

    const zw = try getZlibWriter(gpa, &out);
    defer putZlibWriter(zw);
    try zw.writer().writeAll("hi");
    try zw.finish();

    const produced = out.buffered();
    try std.testing.expect(produced.len >= 2);
    // Default zlib CINFO=7 CM=8 → first byte 0x78
    try std.testing.expectEqual(@as(u8, 0x78), produced[0]);
}
