//! Binary read helpers — port of go-git `utils/binary/read.go`.
//!
//! Focus: Git offset VLQ (`ReadVariableWidthInt`) and big-endian integers.

const std = @import("std");
const Reader = std.Io.Reader;
const Allocator = std.mem.Allocator;
const plumbing = @import("plumbing");

/// Returned when a Git-format variable-width integer would not fit into an
/// `i64` because the input declares more continuation bytes than the type can
/// hold. Matches go-git `ErrIntegerOverflow`.
pub const Error = error{
    /// variable-width integer overflow
    IntegerOverflow,
};

/// Alias matching go-git `ErrIntegerOverflow` name for inventory/docs.
pub const ErrIntegerOverflow = Error.IntegerOverflow;

const mask_continue: u8 = 128; // 1000 0000
const mask_length: u8 = 127; // 0111 1111
const length_bits: u6 = 7; // subsequent bytes store 7 bits of payload

/// Reads a Git offset VLQ integer from `r`.
///
/// Ordinary VLQ has redundancies (e.g. 358 as 0x8166, 0x808166, …). Git's
/// format removes prepending redundancy by adding an offset so the lowest
/// (N+1)-octet value is one more than the maximum N-octet value.
///
/// Examples: max 1-octet = 127; min 2-octet (0x8000) = 128; max 2-octet
/// (0xff7f) = 16511; min 3-octet (0x808000) = 16512.
pub fn readVariableWidthInt(r: *Reader) (Error || Reader.Error)!i64 {
    var c = try r.takeByte();
    var v: i64 = c & mask_length;

    while (c & mask_continue != 0) {
        // Reject input that, after the v++ and shift below, would not fit in
        // an i64. With v < (MaxInt64-127)>>7, the post-increment v is at most
        // (MaxInt64-127)>>7 and the final (v << 7) + (c & 0x7F) stays in i64.
        // Use `>=` (strict bound) matching go-git after the off-by-one fix.
        if (v >= (std.math.maxInt(i64) - @as(i64, mask_length)) >> length_bits) {
            return error.IntegerOverflow;
        }

        v += 1;
        c = try r.takeByte();
        v = (v << length_bits) + @as(i64, c & mask_length);
    }

    return v;
}

/// Reads 4 bytes as a big-endian `u32`.
pub fn readUint32(r: *Reader) Reader.Error!u32 {
    return r.takeInt(u32, .big);
}

/// Reads 2 bytes as a big-endian `u16` (go-git `ReadUint16`).
pub fn readUint16(r: *Reader) Reader.Error!u16 {
    return r.takeInt(u16, .big);
}

/// Reads 8 bytes as a big-endian `u64`.
pub fn readUint64(r: *Reader) Reader.Error!u64 {
    return r.takeInt(u64, .big);
}

/// Read an object id using the active repository hash width.
pub fn readHash(r: *Reader) Reader.Error!plumbing.Hash {
    var raw: [plumbing.MaxSize]u8 = .{0} ** plumbing.MaxSize;
    const n = plumbing.digestSize();
    @memcpy(raw[0..n], try r.take(n));
    return plumbing.Hash.fromBytes(raw[0..n]);
}

/// Read through `delim`, returning owned bytes without the delimiter.
/// End-of-stream before the delimiter discards the partial value, like
/// go-git `ReadUntil`.
pub fn readUntil(allocator: Allocator, r: *Reader, delim: u8) (Allocator.Error || Reader.Error)![]u8 {
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(allocator);
    while (true) {
        const b = try r.takeByte();
        if (b == delim) return try value.toOwnedSlice(allocator);
        try value.append(allocator, b);
    }
}

/// Detect binary data using Git's 8000-byte NUL sniff.
pub fn isBinary(r: *Reader) Reader.Error!bool {
    var count: usize = 0;
    while (count < 8000) : (count += 1) {
        const b = r.takeByte() catch |err| switch (err) {
            error.EndOfStream => return false,
            else => |e| return e,
        };
        if (b == 0) return true;
    }
    return false;
}

test "readVariableWidthInt short" {
    var r = Reader.fixed(&[_]u8{19});
    try std.testing.expectEqual(@as(i64, 19), try readVariableWidthInt(&r));
}

test "readVariableWidthInt 366" {
    var r = Reader.fixed(&[_]u8{ 129, 110 });
    try std.testing.expectEqual(@as(i64, 366), try readVariableWidthInt(&r));
}

test "readVariableWidthInt single-byte max 127" {
    var r = Reader.fixed(&[_]u8{0x7f});
    try std.testing.expectEqual(@as(i64, 127), try readVariableWidthInt(&r));
}

test "readVariableWidthInt two-byte min 128" {
    var r = Reader.fixed(&[_]u8{ 0x80, 0x00 });
    try std.testing.expectEqual(@as(i64, 128), try readVariableWidthInt(&r));
}

test "readVariableWidthInt two-byte max 16511" {
    var r = Reader.fixed(&[_]u8{ 0xff, 0x7f });
    try std.testing.expectEqual(@as(i64, 16511), try readVariableWidthInt(&r));
}

test "readVariableWidthInt three-byte min 16512" {
    var r = Reader.fixed(&[_]u8{ 0x80, 0x80, 0x00 });
    try std.testing.expectEqual(@as(i64, 16512), try readVariableWidthInt(&r));
}

test "readVariableWidthInt overflow eleven 0xFF" {
    // Eleven continuation-style 0xFF bytes push the running i64 past its bound.
    var r = Reader.fixed(&[_]u8{0xFF} ** 11);
    try std.testing.expectError(error.IntegerOverflow, readVariableWidthInt(&r));
}

test "readVariableWidthInt overflow boundary FE*7 FF 00" {
    // Drives accumulator to exactly (MaxInt64-127)>>7; next continuation overflows.
    var r = Reader.fixed(&[_]u8{ 0xFE, 0xFE, 0xFE, 0xFE, 0xFE, 0xFE, 0xFE, 0xFF, 0x00 });
    try std.testing.expectError(error.IntegerOverflow, readVariableWidthInt(&r));
}

test "readUint32 big-endian" {
    var r = Reader.fixed(&[_]u8{ 0x00, 0x00, 0x00, 0x2a });
    try std.testing.expectEqual(@as(u32, 42), try readUint32(&r));
}

test "readUint64 big-endian" {
    var r = Reader.fixed(&[_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef });
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), try readUint64(&r));
}

test "readUint16, readUntil, readHash, and isBinary" {
    var ints = Reader.fixed(&.{ 0x12, 0x34 });
    try std.testing.expectEqual(@as(u16, 0x1234), try readUint16(&ints));

    var delimited = Reader.fixed("refs/heads/main\x00tail");
    const value = try readUntil(std.testing.allocator, &delimited, 0);
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("refs/heads/main", value);
    try std.testing.expectEqual(@as(u8, 't'), try delimited.takeByte());

    var oid_reader = Reader.fixed(&[_]u8{0xab} ** plumbing.Size);
    const oid = try readHash(&oid_reader);
    try std.testing.expectEqual(@as(u8, 0xab), oid.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xab), oid.bytes[plumbing.Size - 1]);

    var text = Reader.fixed("plain text");
    try std.testing.expect(!try isBinary(&text));
    var binary = Reader.fixed("a\x00b");
    try std.testing.expect(try isBinary(&binary));
}
