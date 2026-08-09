//! OpenPGP packet header parse/write, MPI helpers, v4 fingerprint.

const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const err_mod = @import("error.zig");
const Error = err_mod.Error;

pub const Packet = struct {
    tag: u8,
    body: []const u8,
};

pub fn nextPacket(data: []const u8, pos: *usize) Error!Packet {
    if (pos.* >= data.len) return error.InvalidPacket;
    const b0 = data[pos.*];
    pos.* += 1;
    if ((b0 & 0x80) == 0) return error.InvalidPacket;

    var tag: u8 = undefined;
    var body_len: usize = undefined;

    if ((b0 & 0x40) != 0) {
        // New-format header
        tag = b0 & 0x3f;
        if (pos.* >= data.len) return error.InvalidPacket;
        const l0 = data[pos.*];
        pos.* += 1;
        if (l0 < 192) {
            body_len = l0;
        } else if (l0 < 224) {
            if (pos.* >= data.len) return error.InvalidPacket;
            const l1 = data[pos.*];
            pos.* += 1;
            body_len = @as(usize, (@as(u16, l0) - 192) << 8) + l1 + 192;
        } else if (l0 == 255) {
            if (data.len - pos.* < 4) return error.InvalidPacket;
            body_len = std.mem.readInt(u32, data[pos.*..][0..4], .big);
            pos.* += 4;
        } else {
            return error.UnsupportedAlgorithm; // partial body lengths
        }
    } else {
        // Old-format header
        tag = (b0 >> 2) & 0x0f;
        switch (b0 & 0x03) {
            0 => {
                if (pos.* >= data.len) return error.InvalidPacket;
                body_len = data[pos.*];
                pos.* += 1;
            },
            1 => {
                if (data.len - pos.* < 2) return error.InvalidPacket;
                body_len = std.mem.readInt(u16, data[pos.*..][0..2], .big);
                pos.* += 2;
            },
            2 => {
                if (data.len - pos.* < 4) return error.InvalidPacket;
                body_len = std.mem.readInt(u32, data[pos.*..][0..4], .big);
                pos.* += 4;
            },
            else => body_len = data.len - pos.*,
        }
    }
    if (body_len > data.len - pos.*) return error.InvalidPacket;
    const body = data[pos.* .. pos.* + body_len];
    pos.* += body_len;
    return .{ .tag = tag, .body = body };
}

pub fn readMpi(data: []const u8, pos: *usize) Error![]const u8 {
    if (pos.* > data.len or data.len - pos.* < 2) return error.InvalidPacket;
    const bitlen = std.mem.readInt(u16, data[pos.*..][0..2], .big);
    pos.* += 2;
    const bytelen = (@as(usize, bitlen) + 7) / 8;
    if (bytelen > data.len - pos.*) return error.InvalidPacket;
    const mpi = data[pos.* .. pos.* + bytelen];
    pos.* += bytelen;
    return mpi;
}

pub fn fingerprintV4(packet_body: []const u8) [20]u8 {
    var h = crypto.hash.Sha1.init(.{});
    var hdr: [3]u8 = .{
        0x99,
        @intCast((packet_body.len >> 8) & 0xff),
        @intCast(packet_body.len & 0xff),
    };
    h.update(&hdr);
    h.update(packet_body);
    var out: [20]u8 = undefined;
    h.final(&out);
    return out;
}

pub fn appendPacket(list: *std.ArrayList(u8), allocator: Allocator, tag: u8, body: []const u8) Allocator.Error!void {
    try list.append(allocator, 0xc0 | (tag & 0x3f));
    if (body.len < 192) {
        try list.append(allocator, @intCast(body.len));
    } else if (body.len < 8384) {
        const adj = body.len - 192;
        try list.append(allocator, @intCast((adj >> 8) + 192));
        try list.append(allocator, @intCast(adj & 0xff));
    } else {
        try list.append(allocator, 255);
        var lenb: [4]u8 = undefined;
        std.mem.writeInt(u32, &lenb, @intCast(body.len), .big);
        try list.appendSlice(allocator, &lenb);
    }
    try list.appendSlice(allocator, body);
}

pub fn appendMpi(list: *std.ArrayList(u8), allocator: Allocator, bytes: []const u8) Allocator.Error!void {
    var start: usize = 0;
    while (start < bytes.len and bytes[start] == 0) : (start += 1) {}
    if (start == bytes.len) {
        // Zero MPI: bit length 0, no body.
        try list.appendSlice(allocator, &[_]u8{ 0, 0 });
        return;
    }
    const sig = bytes[start..];
    const high_zeros: u16 = @clz(sig[0]);
    const bitlen: u16 = @intCast(sig.len * 8 - high_zeros);
    var hdr: [2]u8 = undefined;
    std.mem.writeInt(u16, &hdr, bitlen, .big);
    try list.appendSlice(allocator, &hdr);
    try list.appendSlice(allocator, sig);
}

pub fn appendSubpacket(list: *std.ArrayList(u8), allocator: Allocator, typ: u8, data: []const u8, critical: bool) Allocator.Error!void {
    const body_len = 1 + data.len; // type + data
    if (body_len < 192) {
        try list.append(allocator, @intCast(body_len));
    } else if (body_len < 8384) {
        const adj = body_len - 192;
        try list.append(allocator, @intCast((adj >> 8) + 192));
        try list.append(allocator, @intCast(adj & 0xff));
    } else {
        try list.append(allocator, 255);
        var lenb: [4]u8 = undefined;
        std.mem.writeInt(u32, &lenb, @intCast(body_len), .big);
        try list.appendSlice(allocator, &lenb);
    }
    const t: u8 = if (critical) typ | 0x80 else typ;
    try list.append(allocator, t);
    try list.appendSlice(allocator, data);
}
