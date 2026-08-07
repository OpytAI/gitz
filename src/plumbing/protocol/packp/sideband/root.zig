//! Package sideband implements a sideband multiplex/demultiplexer.
//!
//! Port of go-git v5.19.2 `plumbing/protocol/packp/sideband`.
//!
//! If `side-band` or `side-band-64k` capabilities have been specified by the
//! client, the server sends packfile data multiplexed into pkt-lines of up to
//! 1000 or 65520 bytes. Each packet has a 1-byte stream code:
//!
//! - 1 — pack data
//! - 2 — progress messages
//! - 3 — fatal error message just before stream aborts
//!
//! # go-git test map
//!
//! | go-git test | Zig test |
//! |---|---|
//! | SidebandSuite.TestDecode | demux_test.TestDecode |
//! | SidebandSuite.TestDecodeMoreThanContain | demux_test.TestDecodeMoreThanContain |
//! | SidebandSuite.TestDecodeWithError | demux_test.TestDecodeWithError |
//! | SidebandSuite.TestDecodeFromFailingReader | demux_test.TestDecodeFromFailingReader |
//! | SidebandSuite.TestDecodeWithProgress | demux_test.TestDecodeWithProgress |
//! | SidebandSuite.TestDecodeFlushEOF | demux_test.TestDecodeFlushEOF |
//! | SidebandSuite.TestDecodeWithUnknownChannel | demux_test.TestDecodeWithUnknownChannel |
//! | SidebandSuite.TestDecodeWithPending | demux_test.TestDecodeWithPending |
//! | SidebandSuite.TestDecodeErrMaxPacked | demux_test.TestDecodeErrMaxPacked |
//! | SidebandSuite.TestMuxerWrite | muxer_test.TestMuxerWrite |
//! | SidebandSuite.TestMuxerWriteChannelMultipleChannels | muxer_test.TestMuxerWriteChannelMultipleChannels |

const std = @import("std");
const testing = std.testing;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const pktline = @import("pktline");

const common = @import("common.zig");
const demux_mod = @import("demux.zig");
const muxer_mod = @import("muxer.zig");

// ---------------------------------------------------------------------------
// Re-exports (go-git package surface)
// ---------------------------------------------------------------------------

pub const Type = common.Type;
pub const MaxPackedSize = common.MaxPackedSize;
pub const MaxPackedSize64k = common.MaxPackedSize64k;
pub const Channel = common.Channel;

pub const Error = demux_mod.Error;
pub const Demuxer = demux_mod.Demuxer;
pub const Muxer = muxer_mod.Muxer;

test {
    _ = common;
    _ = demux_mod;
    _ = muxer_mod;
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

fn encodePack(e: *pktline.Encoder, allocator: std.mem.Allocator, ch: Channel, payload: []const u8) !void {
    const line = try ch.withPayload(allocator, payload);
    defer allocator.free(line);
    try e.encodeLine(line);
}

// ---------------------------------------------------------------------------
// demux_test.go
// ---------------------------------------------------------------------------

test "demux_test.TestDecode" {
    const gpa = testing.allocator;
    const expected = "abcdefghijklmnopqrstuvwxyz";

    var storage: [256]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var e = pktline.Encoder.init(&w);
    try encodePack(&e, gpa, .packData, expected[0..8]);
    try encodePack(&e, gpa, .progressMessage, "FOO\n");
    try encodePack(&e, gpa, .packData, expected[8..16]);
    try encodePack(&e, gpa, .packData, expected[16..26]);

    var r: Reader = .fixed(w.buffered());
    var d = Demuxer.init(.sideband64k, &r);
    var content: [26]u8 = undefined;
    const n = try d.read(&content);
    try testing.expectEqual(@as(usize, 26), n);
    try testing.expectEqualSlices(u8, expected, &content);
}

test "demux_test.TestDecodeMoreThanContain" {
    // go-git: io.ReadFull → (26, ErrUnexpectedEOF); Demuxer.Read returns (26, EOF).
    const gpa = testing.allocator;
    const expected = "abcdefghijklmnopqrstuvwxyz";

    var storage: [128]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var e = pktline.Encoder.init(&w);
    try encodePack(&e, gpa, .packData, expected);

    var r: Reader = .fixed(w.buffered());
    var d = Demuxer.init(.sideband64k, &r);
    var content: [42]u8 = undefined;
    try testing.expectError(error.EndOfStream, d.read(&content));
    try testing.expectEqual(@as(usize, 26), d.last_n);
    try testing.expectEqualSlices(u8, expected, content[0..26]);
}

test "demux_test.TestDecodeWithError" {
    const gpa = testing.allocator;
    const expected = "abcdefghijklmnopqrstuvwxyz";

    var storage: [256]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var e = pktline.Encoder.init(&w);
    try encodePack(&e, gpa, .packData, expected[0..8]);
    try encodePack(&e, gpa, .errorMessage, "FOO\n");
    try encodePack(&e, gpa, .packData, expected[8..16]);
    try encodePack(&e, gpa, .packData, expected[16..26]);

    var r: Reader = .fixed(w.buffered());
    var d = Demuxer.init(.sideband64k, &r);
    var content: [26]u8 = undefined;
    try testing.expectError(error.UnexpectedSidebandError, d.read(&content));
    try testing.expectEqual(@as(usize, 8), d.last_n);
    try testing.expectEqualSlices(u8, expected[0..8], content[0..8]);
    try testing.expectEqualSlices(u8, "unexpected error: FOO\n", d.errDetail());
}

test "demux_test.TestDecodeFromFailingReader" {
    // go-git mockReader returns errors.New("foo"); Zig Reader.failing → ReadFailed.
    var r: Reader = .failing;
    var d = Demuxer.init(.sideband64k, &r);
    var content: [26]u8 = undefined;
    try testing.expectError(error.ReadFailed, d.read(&content));
    try testing.expectEqual(@as(usize, 0), d.last_n);
}

test "demux_test.TestDecodeWithProgress" {
    const gpa = testing.allocator;
    const expected = "abcdefghijklmnopqrstuvwxyz";

    var in_storage: [256]u8 = undefined;
    var in_w: Writer = .fixed(&in_storage);
    var e = pktline.Encoder.init(&in_w);
    try encodePack(&e, gpa, .packData, expected[0..8]);
    try encodePack(&e, gpa, .progressMessage, "FOO\n");
    try encodePack(&e, gpa, .packData, expected[8..16]);
    try encodePack(&e, gpa, .packData, expected[16..26]);

    var progress_storage: [64]u8 = undefined;
    var progress_w: Writer = .fixed(&progress_storage);

    var r: Reader = .fixed(in_w.buffered());
    var d = Demuxer.init(.sideband64k, &r);
    d.progress = &progress_w;

    var content: [26]u8 = undefined;
    try testing.expectEqual(@as(usize, 26), try d.read(&content));
    try testing.expectEqualSlices(u8, expected, &content);
    try testing.expectEqualSlices(u8, "FOO\n", progress_w.buffered());
}

test "demux_test.TestDecodeFlushEOF" {
    // go-git: content.ReadFrom(d) until EOF after flush-pkt; post-flush pack is ignored.
    const gpa = testing.allocator;
    const expected = "abcdefghijklmnopqrstuvwxyz";

    var in_storage: [256]u8 = undefined;
    var in_w: Writer = .fixed(&in_storage);
    var e = pktline.Encoder.init(&in_w);
    try encodePack(&e, gpa, .packData, expected[0..8]);
    try encodePack(&e, gpa, .progressMessage, "FOO\n");
    try encodePack(&e, gpa, .packData, expected[8..16]);
    try encodePack(&e, gpa, .packData, expected[16..26]);
    try e.flush();
    try encodePack(&e, gpa, .packData, "bar\n");

    var progress_storage: [64]u8 = undefined;
    var progress_w: Writer = .fixed(&progress_storage);

    var r: Reader = .fixed(in_w.buffered());
    var d = Demuxer.init(.sideband64k, &r);
    d.progress = &progress_w;

    // Large buffer: Read tries to fill it all, hits flush → EndOfStream with last_n=26.
    var content: [64]u8 = undefined;
    try testing.expectError(error.EndOfStream, d.read(&content));
    try testing.expectEqual(@as(usize, 26), d.last_n);
    try testing.expectEqualSlices(u8, expected, content[0..26]);
    try testing.expectEqualSlices(u8, "FOO\n", progress_w.buffered());
}

test "demux_test.TestDecodeWithUnknownChannel" {
    var storage: [64]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var e = pktline.Encoder.init(&w);
    // go-git: e.Encode([]byte{'4', 'F', 'O', 'O', '\n'})
    try e.encodeLine(&[_]u8{ '4', 'F', 'O', 'O', '\n' });

    var r: Reader = .fixed(w.buffered());
    var d = Demuxer.init(.sideband64k, &r);
    var content: [26]u8 = undefined;
    try testing.expectError(error.UnknownChannel, d.read(&content));
    try testing.expectEqual(@as(usize, 0), d.last_n);
    try testing.expectEqualSlices(u8, "unknown channel 4FOO\n", d.errDetail());
}

test "demux_test.TestDecodeWithPending" {
    const gpa = testing.allocator;
    const expected = "abcdefghijklmnopqrstuvwxyz";

    var storage: [256]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var e = pktline.Encoder.init(&w);
    try encodePack(&e, gpa, .packData, expected[0..8]);
    try encodePack(&e, gpa, .packData, expected[8..16]);
    try encodePack(&e, gpa, .packData, expected[16..26]);

    var r: Reader = .fixed(w.buffered());
    var d = Demuxer.init(.sideband64k, &r);

    var content: [13]u8 = undefined;
    try testing.expectEqual(@as(usize, 13), try d.read(&content));
    try testing.expectEqualSlices(u8, expected[0..13], &content);

    try testing.expectEqual(@as(usize, 13), try d.read(&content));
    try testing.expectEqualSlices(u8, expected[13..26], &content);
}

test "demux_test.TestDecodeErrMaxPacked" {
    const gpa = testing.allocator;

    const payload = try gpa.alloc(u8, MaxPackedSize + 1);
    defer gpa.free(payload);
    @memset(payload, '0');

    const out = try gpa.alloc(u8, 4 + 1 + MaxPackedSize + 1);
    defer gpa.free(out);
    var w: Writer = .fixed(out);
    var e = pktline.Encoder.init(&w);
    try encodePack(&e, gpa, .packData, payload);

    var r: Reader = .fixed(w.buffered());
    var d = Demuxer.init(.sideband, &r);
    var content: [13]u8 = undefined;
    try testing.expectError(error.MaxPackedExceeded, d.read(&content));
    try testing.expectEqual(@as(usize, 0), d.last_n);
}

// ---------------------------------------------------------------------------
// muxer_test.go
// ---------------------------------------------------------------------------

test "muxer_test.TestMuxerWrite" {
    // Two full Sideband chunks: (MaxPackedSize-1)*2 data bytes → 2008 wire bytes.
    const data_len = (MaxPackedSize - 1) * 2;
    var storage: [2048]u8 = undefined;
    var w: Writer = .fixed(&storage);

    var m = Muxer.init(.sideband, &w);
    const data = [_]u8{'F'} ** data_len;
    const n = try m.write(&data);
    try testing.expectEqual(@as(usize, 1998), n);
    try testing.expectEqual(@as(usize, 2008), w.buffered().len);
}

test "muxer_test.TestMuxerWriteChannelMultipleChannels" {
    var storage: [64]u8 = undefined;
    var w: Writer = .fixed(&storage);

    var m = Muxer.init(.sideband, &w);

    try testing.expectEqual(@as(usize, 4), try m.writeChannel(.packData, "DDDD"));
    try testing.expectEqual(@as(usize, 4), try m.writeChannel(.progressMessage, "PPPP"));
    try testing.expectEqual(@as(usize, 4), try m.writeChannel(.packData, "DDDD"));

    const got = w.buffered();
    try testing.expectEqual(@as(usize, 27), got.len);
    try testing.expectEqualSlices(u8, "0009\x01DDDD0009\x02PPPP0009\x01DDDD", got);
}
