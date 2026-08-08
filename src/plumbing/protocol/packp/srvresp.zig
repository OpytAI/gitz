//! Server response (ACK/NAK) from upload-pack.
//! Port of go-git `plumbing/protocol/packp/srvresp.go` (v5.19.2).
//!
//! multi_ack and multi_ack_detailed are not fully supported — match go-git errors.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const plumbing = @import("plumbing");
const pktline = @import("pktline");
const common = @import("common.zig");

const Hash = plumbing.Hash;
const HexSize = plumbing.HexSize;
const MaxHexSize = plumbing.MaxHexSize;

const ack_line_len: usize = 44;

/// Object acknowledgement from upload-pack (go-git `ServerResponse`).
///
/// Zero-value is allowed (`={}`); call `init` before encode/decode that
/// allocate into `acks`.
pub const ServerResponse = struct {
    allocator: Allocator = undefined,
    acks: std.ArrayListUnmanaged(Hash) = .empty,

    pub fn init(allocator: Allocator) ServerResponse {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ServerResponse) void {
        self.acks.deinit(self.allocator);
        self.* = undefined;
    }

    /// Decodes ACK/NAK pkt-lines until the packfile (or EOS) begins.
    ///
    /// `is_multi_ack` should be true when multi_ack or multi_ack_detailed was
    /// negotiated. go-git does not fully implement multi_ack; decode errors are
    /// wrapped with `error.MultiAckNotSupported` when this flag is set.
    pub fn decode(
        self: *ServerResponse,
        r: *Reader,
        is_multi_ack: bool,
    ) (common.Error || pktline.Error || Reader.Error || Allocator.Error)!void {
        var sc = pktline.Scanner.init(r);

        while (sc.scan()) {
            try self.decodeLine(sc.bytes());

            const stop = try self.stopReading(r);
            if (stop) break;
        }

        if (sc.err()) |e| {
            if (is_multi_ack) return error.MultiAckNotSupported;
            return e;
        }
    }

    /// Peek without consuming: stop when the next bytes are not another ACK/NAK.
    fn stopReading(self: *const ServerResponse, r: *Reader) (Reader.Error)!bool {
        _ = self;
        const ahead = r.peek(7) catch |e| {
            if (e == error.EndOfStream) return true;
            return e;
        };

        if (ahead.len > 4 and isValidCommand(ahead[0..3])) {
            return false;
        }
        if (ahead.len == 7 and isValidCommand(ahead[4..7])) {
            return false;
        }
        return true;
    }

    fn isValidCommand(b: []const u8) bool {
        return std.mem.eql(u8, b, common.ack) or std.mem.eql(u8, b, common.nak);
    }

    fn decodeLine(self: *ServerResponse, line: []const u8) (common.Error || Allocator.Error)!void {
        if (line.len == 0) return error.UnexpectedFlush;

        if (line.len >= 3) {
            if (std.mem.eql(u8, line[0..3], common.ack)) {
                return self.decodeAckLine(line);
            }
            if (std.mem.eql(u8, line[0..3], common.nak)) {
                return;
            }
        }
        return error.UnexpectedContent;
    }

    fn decodeAckLine(self: *ServerResponse, line: []const u8) (common.Error || Allocator.Error)!void {
        if (line.len < ack_line_len) return error.MalformedAck;

        const sp_idx = std.mem.indexOfScalar(u8, line, ' ') orelse return error.MalformedAck;
        if (sp_idx + 41 > line.len) return error.MalformedAck;

        const h = plumbing.newHash(line[sp_idx + 1 .. sp_idx + 41]);
        try self.acks.append(self.allocator, h);
    }

    /// Encodes NAK or a single ACK (go-git `Encode`).
    ///
    /// Multiple ACKs without multi_ack return `error.MultiAckNotSupported`.
    pub fn encode(
        self: *const ServerResponse,
        w: *Writer,
        is_multi_ack: bool,
    ) (common.Error || pktline.Error || Writer.Error)!void {
        if (self.acks.items.len > 1 and !is_multi_ack) {
            return error.MultiAckNotSupported;
        }

        var enc = pktline.Encoder.init(w);
        if (self.acks.items.len == 0) {
            return enc.encodef("{s}\n", .{common.nak});
        }

        var hex: [MaxHexSize]u8 = undefined;
        return enc.encodef("{s} {s}\n", .{ common.ack, self.acks.items[0].string(&hex) });
    }
};

// ---------------------------------------------------------------------------
// Tests — srvresp_test.go
// ---------------------------------------------------------------------------

test "decode NAK" {
    const raw = "0008NAK\n";
    var r: Reader = .fixed(raw);
    var sr = ServerResponse.init(testing.allocator);
    defer sr.deinit();
    try sr.decode(&r, false);
    try testing.expectEqual(@as(usize, 0), sr.acks.items.len);
}

test "decode new line invalid pkt-len" {
    const raw = "\n";
    var r: Reader = .fixed(raw);
    var sr = ServerResponse.init(testing.allocator);
    defer sr.deinit();
    try testing.expectError(error.InvalidPktLen, sr.decode(&r, false));
}

test "decode empty" {
    const raw = "";
    var r: Reader = .fixed(raw);
    var sr = ServerResponse.init(testing.allocator);
    defer sr.deinit();
    try sr.decode(&r, false);
    try testing.expectEqual(@as(usize, 0), sr.acks.items.len);
}

test "decode partial unexpected content" {
    const raw = "000600\n";
    var r: Reader = .fixed(raw);
    var sr = ServerResponse.init(testing.allocator);
    defer sr.deinit();
    try testing.expectError(error.UnexpectedContent, sr.decode(&r, false));
}

test "decode ACK" {
    const raw = "0031ACK 6ecf0ef2c2dffb796033e5a02219af86ec6584e5\n";
    var r: Reader = .fixed(raw);
    var sr = ServerResponse.init(testing.allocator);
    defer sr.deinit();
    try sr.decode(&r, false);
    try testing.expectEqual(@as(usize, 1), sr.acks.items.len);
    try testing.expect(sr.acks.items[0].eql(plumbing.newHash("6ecf0ef2c2dffb796033e5a02219af86ec6584e5")));
}

test "decode multiple ACK then pack" {
    const raw = "0031ACK 1111111111111111111111111111111111111111\n" ++
        "0031ACK 6ecf0ef2c2dffb796033e5a02219af86ec6584e5\n" ++
        "00080PACK\n";
    var r: Reader = .fixed(raw);
    var sr = ServerResponse.init(testing.allocator);
    defer sr.deinit();
    try sr.decode(&r, false);
    try testing.expectEqual(@as(usize, 2), sr.acks.items.len);
    try testing.expect(sr.acks.items[0].eql(plumbing.newHash("1111111111111111111111111111111111111111")));
    try testing.expect(sr.acks.items[1].eql(plumbing.newHash("6ecf0ef2c2dffb796033e5a02219af86ec6584e5")));
}

test "decode multiple ACK with sideband" {
    const raw = "0031ACK 1111111111111111111111111111111111111111\n" ++
        "0031ACK 6ecf0ef2c2dffb796033e5a02219af86ec6584e5\n" ++
        "00080aaaa\n";
    var r: Reader = .fixed(raw);
    var sr = ServerResponse.init(testing.allocator);
    defer sr.deinit();
    try sr.decode(&r, false);
    try testing.expectEqual(@as(usize, 2), sr.acks.items.len);
}

test "decode malformed ACK" {
    const raw = "0029ACK 6ecf0ef2c2dffb796033e5a02219af86ec6584e\n";
    var r: Reader = .fixed(raw);
    var sr = ServerResponse.init(testing.allocator);
    defer sr.deinit();
    try testing.expectError(error.MalformedAck, sr.decode(&r, false));
}

test "decode multi_ack flag still works for plain ACKs" {
    const raw = "0031ACK 1111111111111111111111111111111111111111\n" ++
        "0031ACK 6ecf0ef2c2dffb796033e5a02219af86ec6584e5\n" ++
        "00080PACK\n";
    var r: Reader = .fixed(raw);
    var sr = ServerResponse.init(testing.allocator);
    defer sr.deinit();
    try sr.decode(&r, true);
    try testing.expectEqual(@as(usize, 2), sr.acks.items.len);
}

test "encode NAK" {
    var storage: [16]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var sr = ServerResponse.init(testing.allocator);
    defer sr.deinit();
    try sr.encode(&w, false);
    try testing.expectEqualStrings("0008NAK\n", w.buffered());
}

test "encode single ACK" {
    var storage: [64]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var sr = ServerResponse.init(testing.allocator);
    defer sr.deinit();
    try sr.acks.append(testing.allocator, plumbing.newHash("6ecf0ef2c2dffb796033e5a02219af86ec6584e5"));
    try sr.encode(&w, false);
    try testing.expectEqualStrings(
        "0031ACK 6ecf0ef2c2dffb796033e5a02219af86ec6584e5\n",
        w.buffered(),
    );
}

test "encode multiple ACKs without multi_ack fails" {
    var storage: [64]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var sr = ServerResponse.init(testing.allocator);
    defer sr.deinit();
    try sr.acks.append(testing.allocator, plumbing.newHash("1111111111111111111111111111111111111111"));
    try sr.acks.append(testing.allocator, plumbing.newHash("6ecf0ef2c2dffb796033e5a02219af86ec6584e5"));
    try testing.expectError(error.MultiAckNotSupported, sr.encode(&w, false));
}
