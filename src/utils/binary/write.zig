//! Binary write helpers — port of go-git `utils/binary/write.go`.
//!
//! Focus: Git offset VLQ (`WriteVariableWidthInt`) and big-endian integers.

const std = @import("std");
const Writer = std.Io.Writer;

/// Writes `n` as a Git offset VLQ integer to `w`.
///
/// Encoding matches go-git / git C: lowest 7 bits first into a buffer, then
/// while the remaining value is non-zero, decrement (offset), take 7 bits with
/// continuation bit set, and prepend.
pub fn writeVariableWidthInt(w: *Writer, n: i64) Writer.Error!void {
    // Max encoded length for i64 with 7-bit groups and Git offsets is well
    // under 16 bytes; stack buffer avoids allocation (go-git builds a slice).
    var buf: [16]u8 = undefined;
    var i: usize = buf.len;
    var val = n;

    i -= 1;
    buf[i] = @intCast(val & 0x7f);
    val >>= 7;
    while (val != 0) {
        val -= 1;
        i -= 1;
        buf[i] = 0x80 | @as(u8, @intCast(val & 0x7f));
        val >>= 7;
    }

    try w.writeAll(buf[i..]);
}

/// Writes `value` as 4 big-endian bytes.
pub fn writeUint32(w: *Writer, value: u32) Writer.Error!void {
    try w.writeInt(u32, value, .big);
}

/// Writes `value` as 8 big-endian bytes.
pub fn writeUint64(w: *Writer, value: u64) Writer.Error!void {
    try w.writeInt(u64, value, .big);
}

test "writeVariableWidthInt short" {
    var storage: [16]u8 = undefined;
    var w: Writer = .fixed(&storage);
    try writeVariableWidthInt(&w, 19);
    try std.testing.expectEqualSlices(u8, &[_]u8{19}, w.buffered());
}

test "writeVariableWidthInt 366" {
    var storage: [16]u8 = undefined;
    var w: Writer = .fixed(&storage);
    try writeVariableWidthInt(&w, 366);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 129, 110 }, w.buffered());
}

test "writeVariableWidthInt boundaries" {
    var storage: [16]u8 = undefined;

    {
        var w: Writer = .fixed(&storage);
        try writeVariableWidthInt(&w, 127);
        try std.testing.expectEqualSlices(u8, &[_]u8{0x7f}, w.buffered());
    }
    {
        var w: Writer = .fixed(&storage);
        try writeVariableWidthInt(&w, 128);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x00 }, w.buffered());
    }
    {
        var w: Writer = .fixed(&storage);
        try writeVariableWidthInt(&w, 16511);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0x7f }, w.buffered());
    }
    {
        var w: Writer = .fixed(&storage);
        try writeVariableWidthInt(&w, 16512);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x80, 0x00 }, w.buffered());
    }
}

test "writeUint32 big-endian" {
    var storage: [8]u8 = undefined;
    var w: Writer = .fixed(&storage);
    try writeUint32(&w, 42);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x2a }, w.buffered());
}

test "writeUint64 big-endian" {
    var storage: [8]u8 = undefined;
    var w: Writer = .fixed(&storage);
    try writeUint64(&w, 0x0123456789abcdef);
    try std.testing.expectEqualSlices(
        u8,
        &[_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef },
        w.buffered(),
    );
}
