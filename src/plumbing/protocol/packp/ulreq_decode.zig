//! Upload-request decoder (go-git `plumbing/protocol/packp/ulreq_decode.go`).
//!
//! State machine: first want → caps → other wants → shallows → deepen → flush.
//! Note: go-git does **not** decode `filter` lines (encode-only on the client).
//! Pin: go-git v5.19.2.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;

const plumbing = @import("plumbing");
const pktline = @import("pktline");
const capability = @import("capability");
const common = @import("common.zig");

const ulreq = @import("ulreq.zig");
const UploadRequest = ulreq.UploadRequest;
const Hash = ulreq.Hash;



/// go-git `(*UploadRequest).Decode` / `ulReqDecoder.Decode`.
pub fn decode(req: *UploadRequest, r: *Reader) !void {
    var d = Decoder{
        .s = pktline.Scanner.init(r),
        .data = req,
    };
    try d.run();
}

const Decoder = struct {
    s: pktline.Scanner,
    /// Working copy of the current line (mutable trim/advance).
    line_buf: [pktline.OversizePayloadMax]u8 = undefined,
    line_len: usize = 0,
    n_line: i32 = 0,
    data: *UploadRequest,

    fn run(self: *Decoder) !void {
        try self.decodeFirstWant();
    }

    fn cur(self: *const Decoder) []const u8 {
        return self.line_buf[0..self.line_len];
    }

    fn setLine(self: *Decoder, src: []const u8) void {
        const n = @min(src.len, self.line_buf.len);
        @memcpy(self.line_buf[0..n], src[0..n]);
        self.line_len = n;
        // Trim trailing EOL like go-git `bytes.TrimSuffix(line, eol)`.
        while (self.line_len > 0 and self.line_buf[self.line_len - 1] == '\n') {
            self.line_len -= 1;
        }
    }

    fn nextLine(self: *Decoder) !void {
        self.n_line += 1;
        if (!self.s.scan()) {
            if (self.s.err()) |e| return e;
            return error.UnexpectedData; // go-git: "pkt-line N: EOF"
        }
        self.setLine(self.s.bytes());
    }

    fn decodeFirstWant(self: *Decoder) !void {
        try self.nextLine();
        if (!std.mem.startsWith(u8, self.cur(), common.want)) {
            return error.UnexpectedData; // missing 'want ' prefix
        }
        self.advance(common.want.len);

        const hash = try self.readHash();
        try self.data.wants.append(self.data.allocator, hash);

        try self.decodeCaps();
    }

    fn advance(self: *Decoder, n: usize) void {
        if (n >= self.line_len) {
            self.line_len = 0;
            return;
        }
        const rest = self.line_buf[n..self.line_len];
        std.mem.copyForwards(u8, self.line_buf[0..rest.len], rest);
        self.line_len = rest.len;
    }

    fn readHash(self: *Decoder) !Hash {
        const hs = common.hashSize();
        if (self.line_len < hs) return error.MalformedHash;
        const hex = self.line_buf[0..hs];
        // Validate hex; invalid → error.InvalidHash (go-git invalid hash text).
        if (!plumbing.isHash(hex)) return error.InvalidHash;
        const hash = plumbing.newHash(hex);
        self.advance(hs);
        return hash;
    }

    fn decodeCaps(self: *Decoder) !void {
        // Expected: optional leading SP then cap list.
        if (self.line_len > 0 and self.line_buf[0] == ' ') {
            self.advance(1);
        }
        try self.data.capabilities.decode(self.cur());
        try self.decodeOtherWants();
    }

    fn decodeOtherWants(self: *Decoder) !void {
        try self.nextLine();

        if (std.mem.startsWith(u8, self.cur(), common.shallow)) {
            return self.decodeShallow();
        }
        if (std.mem.startsWith(u8, self.cur(), common.deepen)) {
            return self.decodeDeepen();
        }
        if (self.line_len == 0) return; // flush

        if (!std.mem.startsWith(u8, self.cur(), common.want)) {
            return error.UnexpectedData;
        }
        self.advance(common.want.len);
        const hash = try self.readHash();
        try self.data.wants.append(self.data.allocator, hash);
        try self.decodeOtherWants();
    }

    fn decodeShallow(self: *Decoder) !void {
        if (std.mem.startsWith(u8, self.cur(), common.deepen)) {
            return self.decodeDeepen();
        }
        if (self.line_len == 0) return;

        if (!std.mem.startsWith(u8, self.cur(), common.shallow)) {
            return error.UnexpectedData;
        }
        self.advance(common.shallow.len);
        const hash = try self.readHash();
        try self.data.shallows.append(self.data.allocator, hash);

        try self.nextLine();
        try self.decodeShallow();
    }

    fn decodeDeepen(self: *Decoder) !void {
        if (std.mem.startsWith(u8, self.cur(), common.deepen_commits)) {
            return self.decodeDeepenCommits();
        }
        if (std.mem.startsWith(u8, self.cur(), common.deepen_since)) {
            return self.decodeDeepenSince();
        }
        if (std.mem.startsWith(u8, self.cur(), common.deepen_reference)) {
            return self.decodeDeepenReference();
        }
        if (self.line_len == 0) return;
        return error.UnexpectedData;
    }

    fn decodeDeepenCommits(self: *Decoder) !void {
        self.advance(common.deepen_commits.len);
        const n = std.fmt.parseInt(i32, self.cur(), 10) catch return error.UnexpectedData;
        if (n < 0) return error.NegativeDepth;
        self.data.depth = .{ .commits = n };
        try self.decodeFlush();
    }

    fn decodeDeepenSince(self: *Decoder) !void {
        self.advance(common.deepen_since.len);
        const secs = std.fmt.parseInt(i64, self.cur(), 10) catch return error.UnexpectedData;
        self.data.depth = .{ .since = secs };
        try self.decodeFlush();
    }

    fn decodeDeepenReference(self: *Decoder) !void {
        self.advance(common.deepen_reference.len);
        const ref = try self.data.allocator.dupe(u8, self.cur());
        self.data.depth = .{ .reference = ref };
        self.data.owns_depth_ref = true;
        try self.decodeFlush();
    }

    fn decodeFlush(self: *Decoder) !void {
        try self.nextLine();
        if (self.line_len != 0) return error.UnexpectedData;
    }
};

// ---------------------------------------------------------------------------
// Tests — port of ulreq_decode_test.go (substantial subset)
// ---------------------------------------------------------------------------

fn encodePayloads(allocator: Allocator, payloads: []const []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var pe = pktline.Encoder.init(&aw.writer);
    try pe.encodeString(payloads);
    return try allocator.dupe(u8, aw.written());
}

fn decodePayloads(allocator: Allocator, payloads: []const []const u8) !UploadRequest {
    const raw = try encodePayloads(allocator, payloads);
    defer allocator.free(raw);
    var r: Reader = .fixed(raw);
    var ur = UploadRequest.init(allocator);
    errdefer ur.deinit();
    try decode(&ur, &r);
    return ur;
}

fn expectDecodeError(allocator: Allocator, payloads: []const []const u8) !void {
    const raw = try encodePayloads(allocator, payloads);
    defer allocator.free(raw);
    var r: Reader = .fixed(raw);
    var ur = UploadRequest.init(allocator);
    defer ur.deinit();
    const result = decode(&ur, &r);
    try testing.expect(std.meta.isError(result));
}

fn sortHashes(hashes: []Hash) void {
    ulreq.hashesSort(hashes);
}

test "decode empty EOF" {
    const gpa = testing.allocator;
    var ur = UploadRequest.init(gpa);
    defer ur.deinit();
    var r: Reader = .fixed(&.{});
    try testing.expectError(error.UnexpectedData, decode(&ur, &r));
}

test "decode no want" {
    const gpa = testing.allocator;
    try expectDecodeError(gpa, &.{ "foobar", pktline.FlushString });
}

test "decode invalid first hash" {
    const gpa = testing.allocator;
    try expectDecodeError(gpa, &.{
        "want 6ecf0ef2c2dffb796alberto2219af86ec6584e5\n",
        pktline.FlushString,
    });
}

test "decode want OK" {
    const gpa = testing.allocator;
    var ur = try decodePayloads(gpa, &.{
        "want 1111111111111111111111111111111111111111",
        pktline.FlushString,
    });
    defer ur.deinit();
    try testing.expectEqual(@as(usize, 1), ur.wants.items.len);
    try testing.expect(ur.wants.items[0].eql(plumbing.newHash("1111111111111111111111111111111111111111")));
}

test "decode want with capabilities" {
    const gpa = testing.allocator;
    var ur = try decodePayloads(gpa, &.{
        "want 1111111111111111111111111111111111111111 ofs-delta multi_ack",
        pktline.FlushString,
    });
    defer ur.deinit();
    try testing.expect(ur.capabilities.supports(capability.OFSDelta));
    try testing.expect(ur.capabilities.supports(capability.MultiACK));
}

test "decode many wants" {
    const gpa = testing.allocator;
    var ur = try decodePayloads(gpa, &.{
        "want 3333333333333333333333333333333333333333",
        "want 4444444444444444444444444444444444444444",
        "want 1111111111111111111111111111111111111111",
        "want 2222222222222222222222222222222222222222",
        pktline.FlushString,
    });
    defer ur.deinit();

    sortHashes(ur.wants.items);
    try testing.expectEqual(@as(usize, 4), ur.wants.items.len);
    try testing.expect(ur.wants.items[0].eql(plumbing.newHash("1111111111111111111111111111111111111111")));
    try testing.expect(ur.wants.items[1].eql(plumbing.newHash("2222222222222222222222222222222222222222")));
    try testing.expect(ur.wants.items[2].eql(plumbing.newHash("3333333333333333333333333333333333333333")));
    try testing.expect(ur.wants.items[3].eql(plumbing.newHash("4444444444444444444444444444444444444444")));
}

test "decode many wants bad want" {
    const gpa = testing.allocator;
    try expectDecodeError(gpa, &.{
        "want 3333333333333333333333333333333333333333",
        "want 4444444444444444444444444444444444444444",
        "foo",
        "want 2222222222222222222222222222222222222222",
        pktline.FlushString,
    });
}

test "decode many wants invalid hash" {
    const gpa = testing.allocator;
    try expectDecodeError(gpa, &.{
        "want 3333333333333333333333333333333333333333",
        "want 4444444444444444444444444444444444444444",
        "want 1234567890abcdef",
        "want 2222222222222222222222222222222222222222",
        pktline.FlushString,
    });
}

test "decode many wants with capabilities" {
    const gpa = testing.allocator;
    var ur = try decodePayloads(gpa, &.{
        "want 3333333333333333333333333333333333333333 ofs-delta multi_ack",
        "want 4444444444444444444444444444444444444444",
        "want 1111111111111111111111111111111111111111",
        "want 2222222222222222222222222222222222222222",
        pktline.FlushString,
    });
    defer ur.deinit();
    try testing.expect(ur.capabilities.supports(capability.OFSDelta));
    try testing.expect(ur.capabilities.supports(capability.MultiACK));
    try testing.expectEqual(@as(usize, 4), ur.wants.items.len);
}

test "decode single shallow single want" {
    const gpa = testing.allocator;
    var ur = try decodePayloads(gpa, &.{
        "want 3333333333333333333333333333333333333333 ofs-delta multi_ack",
        "shallow aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        pktline.FlushString,
    });
    defer ur.deinit();
    try testing.expectEqual(@as(usize, 1), ur.wants.items.len);
    try testing.expectEqual(@as(usize, 1), ur.shallows.items.len);
    try testing.expect(ur.shallows.items[0].eql(plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")));
}

test "decode many shallow many wants" {
    const gpa = testing.allocator;
    var ur = try decodePayloads(gpa, &.{
        "want 3333333333333333333333333333333333333333 ofs-delta multi_ack",
        "want 4444444444444444444444444444444444444444",
        "want 1111111111111111111111111111111111111111",
        "want 2222222222222222222222222222222222222222",
        "shallow aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "shallow bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "shallow cccccccccccccccccccccccccccccccccccccccc",
        "shallow dddddddddddddddddddddddddddddddddddddddd",
        pktline.FlushString,
    });
    defer ur.deinit();
    sortHashes(ur.wants.items);
    sortHashes(ur.shallows.items);
    try testing.expectEqual(@as(usize, 4), ur.wants.items.len);
    try testing.expectEqual(@as(usize, 4), ur.shallows.items.len);
}

test "decode malformed shallow" {
    const gpa = testing.allocator;
    try expectDecodeError(gpa, &.{
        "want 3333333333333333333333333333333333333333 ofs-delta multi_ack",
        "shalow aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        pktline.FlushString,
    });
}

test "decode malformed shallow hash" {
    const gpa = testing.allocator;
    try expectDecodeError(gpa, &.{
        "want 3333333333333333333333333333333333333333 ofs-delta multi_ack",
        "shallow aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        pktline.FlushString,
    });
}

test "decode malformed deepen spec" {
    const gpa = testing.allocator;
    try expectDecodeError(gpa, &.{
        "want 3333333333333333333333333333333333333333 ofs-delta multi_ack",
        "deepen-foo 34",
        pktline.FlushString,
    });
}

test "decode deepen commits" {
    const gpa = testing.allocator;
    var ur = try decodePayloads(gpa, &.{
        "want 3333333333333333333333333333333333333333 ofs-delta multi_ack",
        "deepen 1234",
        pktline.FlushString,
    });
    defer ur.deinit();
    try testing.expect(ur.depth == .commits);
    try testing.expectEqual(@as(i32, 1234), ur.depth.commits);
}

test "decode deepen commits infinite zero" {
    const gpa = testing.allocator;
    var ur = try decodePayloads(gpa, &.{
        "want 3333333333333333333333333333333333333333 ofs-delta multi_ack",
        "deepen 0",
        pktline.FlushString,
    });
    defer ur.deinit();
    try testing.expectEqual(@as(i32, 0), ur.depth.commits);
}

test "decode deepen commits infinite implicit" {
    const gpa = testing.allocator;
    var ur = try decodePayloads(gpa, &.{
        "want 3333333333333333333333333333333333333333 ofs-delta multi_ack",
        pktline.FlushString,
    });
    defer ur.deinit();
    try testing.expectEqual(@as(i32, 0), ur.depth.commits);
}

test "decode negative deepen" {
    const gpa = testing.allocator;
    try expectDecodeError(gpa, &.{
        "want 3333333333333333333333333333333333333333 ofs-delta multi_ack",
        "deepen -32",
        pktline.FlushString,
    });
}

test "decode deepen empty" {
    const gpa = testing.allocator;
    try expectDecodeError(gpa, &.{
        "want 3333333333333333333333333333333333333333 ofs-delta multi_ack",
        "deepen ",
        pktline.FlushString,
    });
}

test "decode deepen-since" {
    const gpa = testing.allocator;
    var ur = try decodePayloads(gpa, &.{
        "want 3333333333333333333333333333333333333333 ofs-delta multi_ack",
        "deepen-since 1420167845",
        pktline.FlushString,
    });
    defer ur.deinit();
    try testing.expect(ur.depth == .since);
    try testing.expectEqual(@as(i64, 1420167845), ur.depth.since);
}

test "decode deepen-not reference" {
    const gpa = testing.allocator;
    var ur = try decodePayloads(gpa, &.{
        "want 3333333333333333333333333333333333333333 ofs-delta multi_ack",
        "deepen-not refs/heads/master",
        pktline.FlushString,
    });
    defer ur.deinit();
    try testing.expect(ur.depth == .reference);
    try testing.expectEqualStrings("refs/heads/master", ur.depth.reference);
}

test "decode all wants shallows deepen" {
    const gpa = testing.allocator;
    var ur = try decodePayloads(gpa, &.{
        "want 3333333333333333333333333333333333333333 ofs-delta multi_ack",
        "want 4444444444444444444444444444444444444444",
        "want 1111111111111111111111111111111111111111",
        "want 2222222222222222222222222222222222222222",
        "shallow aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "shallow bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "shallow cccccccccccccccccccccccccccccccccccccccc",
        "shallow dddddddddddddddddddddddddddddddddddddddd",
        "deepen 1234",
        pktline.FlushString,
    });
    defer ur.deinit();
    sortHashes(ur.wants.items);
    sortHashes(ur.shallows.items);
    try testing.expectEqual(@as(usize, 4), ur.wants.items.len);
    try testing.expectEqual(@as(usize, 4), ur.shallows.items.len);
    try testing.expectEqual(@as(i32, 1234), ur.depth.commits);
}

test "decode extra data after deepen" {
    const gpa = testing.allocator;
    try expectDecodeError(gpa, &.{
        "want 3333333333333333333333333333333333333333 ofs-delta multi_ack",
        "deepen 32",
        "foo",
        pktline.FlushString,
    });
}

test "encode decode round-trip" {
    const gpa = testing.allocator;
    var ur = UploadRequest.init(gpa);
    defer ur.deinit();
    try ur.wants.append(gpa, plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try ur.wants.append(gpa, plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"));
    try ur.capabilities.add(capability.OFSDelta, &.{});
    try ur.shallows.append(gpa, plumbing.newHash("cccccccccccccccccccccccccccccccccccccccc"));
    ur.depth = .{ .commits = 5 };

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try ur.encode(&aw.writer);
    const raw = aw.written();

    var r: Reader = .fixed(raw);
    var ur2 = UploadRequest.init(gpa);
    defer ur2.deinit();
    try ur2.decode(&r);

    try testing.expectEqual(@as(usize, 2), ur2.wants.items.len);
    try testing.expectEqual(@as(usize, 1), ur2.shallows.items.len);
    try testing.expectEqual(@as(i32, 5), ur2.depth.commits);
    try testing.expect(ur2.capabilities.supports(capability.OFSDelta));
}
