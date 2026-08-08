//! ASCII armor encode/decode (RFC 4880).

const std = @import("std");
const Allocator = std.mem.Allocator;
const err_mod = @import("error.zig");
const Error = err_mod.Error;

pub fn decodeArmor(allocator: Allocator, armored: []const u8) (Allocator.Error || Error)![]u8 {
    var it = std.mem.splitScalar(u8, armored, '\n');
    var in_body = false;
    var b64: std.ArrayList(u8) = .empty;
    defer b64.deinit(allocator);

    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "-----BEGIN ")) {
            in_body = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "-----END ")) break;
        if (!in_body) continue;
        if (std.mem.indexOfScalar(u8, line, ':') != null) continue; // header
        if (line[0] == '=') continue; // CRC24
        try b64.appendSlice(allocator, line);
    }
    if (b64.items.len == 0) return error.InvalidArmor;

    const dec_len = std.base64.standard.Decoder.calcSizeForSlice(b64.items) catch return error.InvalidArmor;
    const out = try allocator.alloc(u8, dec_len);
    errdefer allocator.free(out);
    std.base64.standard.Decoder.decode(out, b64.items) catch return error.InvalidArmor;
    return out;
}

pub fn crc24(data: []const u8) u32 {
    var crc: u32 = 0xb704ce;
    for (data) |b| {
        crc ^= @as(u32, b) << 16;
        var i: u4 = 0;
        while (i < 8) : (i += 1) {
            crc <<= 1;
            if ((crc & 0x1000000) != 0) crc ^= 0x1864cfb;
        }
    }
    return crc & 0xffffff;
}

/// Encode binary OpenPGP data as an ASCII-armored block (`PGP SIGNATURE`, etc.).
pub fn encodeArmor(allocator: Allocator, block_type: []const u8, binary: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "-----BEGIN ");
    try out.appendSlice(allocator, block_type);
    try out.appendSlice(allocator, "-----\n\n");

    const enc_len = std.base64.standard.Encoder.calcSize(binary.len);
    const b64 = try allocator.alloc(u8, enc_len);
    defer allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, binary);

    // 64-char lines (OpenPGP armor convention).
    var off: usize = 0;
    while (off < b64.len) {
        const n = @min(64, b64.len - off);
        try out.appendSlice(allocator, b64[off .. off + n]);
        try out.append(allocator, '\n');
        off += n;
    }

    const crc = crc24(binary);
    var crc_bytes: [3]u8 = .{
        @intCast((crc >> 16) & 0xff),
        @intCast((crc >> 8) & 0xff),
        @intCast(crc & 0xff),
    };
    var crc_b64: [4]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&crc_b64, &crc_bytes);
    try out.append(allocator, '=');
    try out.appendSlice(allocator, &crc_b64);
    try out.append(allocator, '\n');

    try out.appendSlice(allocator, "-----END ");
    try out.appendSlice(allocator, block_type);
    try out.appendSlice(allocator, "-----\n");

    return try out.toOwnedSlice(allocator);
}
