//! Decode advertised-refs (go-git `plumbing/protocol/packp/advrefs_decode.go`).
//!
//! Handles HTTP smart service prefix, optional flush, zero-id no-refs line,
//! capability list, tip/peeled refs, and shallow lines.

const std = @import("std");
const plumbing = @import("plumbing");
const pktline = @import("pktline");
const capability = @import("capability");
const common = @import("common.zig");
const advrefs_mod = @import("advrefs.zig");

const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Hash = plumbing.Hash;
const AdvRefs = advrefs_mod.AdvRefs;
const testing = std.testing;

/// go-git `ErrEmptyAdvRefs`.
pub const ErrEmptyAdvRefs = error.EmptyAdvRefs;
/// go-git `ErrEmptyInput`.
pub const ErrEmptyInput = error.EmptyInput;

pub const DecodeError = error{
    EmptyAdvRefs,
    EmptyInput,
    UnexpectedData,
} || pktline.Error || Reader.Error || Allocator.Error;

/// go-git `AdvRefs.Decode`.
pub fn decode(a: *AdvRefs, r: *Reader) DecodeError!void {
    var d = AdvRefsDecoder{
        .s = pktline.Scanner.init(r),
        .data = a,
    };
    try d.decode();
}

const AdvRefsDecoder = struct {
    s: pktline.Scanner,
    line: []const u8 = "",
    /// Owned buffer for the current line (trimmed).
    line_buf: []u8 = &.{},
    n_line: usize = 0,
    hash: Hash = plumbing.ZeroHash,
    err: ?DecodeError = null,
    data: *AdvRefs,
    err_msg: [256]u8 = undefined,
    err_msg_len: usize = 0,

    /// Opaque next-state pointer (Zig disallows direct recursive fn-pointer types).
    const StateFn = *const fn (*AdvRefsDecoder) ?*const anyopaque;

    fn decode(self: *AdvRefsDecoder) DecodeError!void {
        defer if (self.line_buf.len > 0) self.data.allocator.free(self.line_buf);

        var state: ?*const anyopaque = @ptrCast(&decodePrefix);
        while (state) |fn_ptr| {
            const f: StateFn = @ptrCast(@alignCast(fn_ptr));
            state = f(self);
        }
        if (self.err) |e| return e;
    }

    fn setError(self: *AdvRefsDecoder, comptime fmt: []const u8, args: anytype) void {
        const prefix = std.fmt.bufPrint(&self.err_msg, "pkt-line {d}: ", .{self.n_line}) catch {
            self.err = error.UnexpectedData;
            return;
        };
        const rest = std.fmt.bufPrint(self.err_msg[prefix.len..], fmt, args) catch {
            self.err_msg_len = prefix.len;
            self.err = error.UnexpectedData;
            return;
        };
        self.err_msg_len = prefix.len + rest.len;
        self.err = error.UnexpectedData;
    }

    fn nextLine(self: *AdvRefsDecoder) bool {
        self.n_line += 1;

        if (!self.s.scan()) {
            if (self.s.err()) |e| {
                self.err = e;
                return false;
            }
            if (self.n_line == 1) {
                self.err = error.EmptyInput;
                return false;
            }
            self.setError("EOF", .{});
            return false;
        }

        var payload = self.s.bytes();
        // Trim trailing EOL (go-git `bytes.TrimSuffix(d.line, eol)`).
        if (payload.len > 0 and payload[payload.len - 1] == '\n') {
            payload = payload[0 .. payload.len - 1];
        }

        if (payload.len > self.line_buf.len) {
            if (self.line_buf.len == 0) {
                self.line_buf = self.data.allocator.alloc(u8, payload.len) catch {
                    self.err = error.OutOfMemory;
                    return false;
                };
            } else {
                self.line_buf = self.data.allocator.realloc(self.line_buf, payload.len) catch {
                    self.err = error.OutOfMemory;
                    return false;
                };
            }
        }
        if (payload.len > 0) {
            @memcpy(self.line_buf[0..payload.len], payload);
        }
        self.line = self.line_buf[0..payload.len];
        return true;
    }
};

fn decodePrefix(d: *AdvRefsDecoder) ?*const anyopaque {
    if (!d.nextLine()) return null;

    if (!isPrefix(d.line)) {
        return @ptrCast(&decodeFirstHash);
    }

    d.data.appendPrefix(d.line) catch {
        d.err = error.OutOfMemory;
        return null;
    };

    if (!d.nextLine()) return null;

    if (!common.isFlush(d.line)) {
        return @ptrCast(&decodeFirstHash);
    }

    d.data.appendPrefix(&.{}) catch {
        d.err = error.OutOfMemory;
        return null;
    };

    if (!d.nextLine()) return null;
    return @ptrCast(&decodeFirstHash);
}

fn isPrefix(payload: []const u8) bool {
    return payload.len > 0 and payload[0] == '#';
}

fn decodeFirstHash(p: *AdvRefsDecoder) ?*const anyopaque {
    if (common.isFlush(p.line)) {
        p.err = error.EmptyAdvRefs;
        return null;
    }

    const hs = common.hashSize();
    if (p.line.len < hs) {
        p.setError("cannot read hash, pkt-line too short", .{});
        return null;
    }

    var hash_bytes: [plumbing.MaxSize]u8 = .{0} ** plumbing.MaxSize;
    const n = hs / 2;
    _ = std.fmt.hexToBytes(hash_bytes[0..n], p.line[0..hs]) catch {
        p.setError("invalid hash text", .{});
        return null;
    };
    p.hash = Hash.fromBytes(hash_bytes[0..n]);
    p.line = p.line[hs..];

    if (p.hash.isZero()) {
        return @ptrCast(&decodeSkipNoRefs);
    }
    return @ptrCast(&decodeFirstRef);
}

fn decodeSkipNoRefs(p: *AdvRefsDecoder) ?*const anyopaque {
    if (p.line.len < common.no_head_mark.len) {
        p.setError("too short zero-id ref", .{});
        return null;
    }
    if (!std.mem.startsWith(u8, p.line, common.no_head_mark)) {
        p.setError("malformed zero-id ref", .{});
        return null;
    }
    p.line = p.line[common.no_head_mark.len..];
    return @ptrCast(&decodeCaps);
}

fn decodeFirstRef(l: *AdvRefsDecoder) ?*const anyopaque {
    if (l.line.len < 3) {
        l.setError("line too short after hash", .{});
        return null;
    }
    if (l.line[0] != ' ') {
        l.setError("no space after hash", .{});
        return null;
    }
    l.line = l.line[1..];

    const nul_pos = std.mem.indexOfScalar(u8, l.line, 0) orelse {
        l.setError("NULL not found", .{});
        return null;
    };
    const ref = l.line[0..nul_pos];
    l.line = l.line[nul_pos + 1 ..];

    if (std.mem.eql(u8, ref, common.head)) {
        l.data.head = l.hash;
    } else {
        l.data.putReference(ref, l.hash) catch {
            l.err = error.OutOfMemory;
            return null;
        };
    }
    return @ptrCast(&decodeCaps);
}

fn decodeCaps(p: *AdvRefsDecoder) ?*const anyopaque {
    p.data.capabilities.decode(p.line) catch {
        p.setError("invalid capabilities", .{});
        return null;
    };
    return @ptrCast(&decodeOtherRefs);
}

fn decodeOtherRefs(p: *AdvRefsDecoder) ?*const anyopaque {
    if (!p.nextLine()) return null;

    if (std.mem.startsWith(u8, p.line, common.shallow)) {
        return @ptrCast(&decodeShallow);
    }

    if (p.line.len == 0) {
        return null; // flush — success
    }

    var line = p.line;
    var to_peeled = false;
    if (std.mem.endsWith(u8, line, common.peeled)) {
        line = line[0 .. line.len - common.peeled.len];
        to_peeled = true;
    }

    const ref_hash = readRef(line) catch {
        p.setError("malformed ref data", .{});
        return null;
    };

    if (to_peeled) {
        p.data.putPeeled(ref_hash.name, ref_hash.hash) catch {
            p.err = error.OutOfMemory;
            return null;
        };
    } else {
        p.data.putReference(ref_hash.name, ref_hash.hash) catch {
            p.err = error.OutOfMemory;
            return null;
        };
    }
    return @ptrCast(&decodeOtherRefs);
}

const RefParts = struct {
    name: []const u8,
    hash: Hash,
};

fn readRef(data: []const u8) error{MalformedRef}!RefParts {
    var it = std.mem.splitScalar(u8, data, ' ');
    const first = it.next() orelse return error.MalformedRef;
    const second = it.next() orelse return error.MalformedRef;
    if (it.next() != null) return error.MalformedRef;
    // go-git uses NewHash (lenient) for other refs.
    return .{
        .name = second,
        .hash = plumbing.newHash(first),
    };
}

fn decodeShallow(p: *AdvRefsDecoder) ?*const anyopaque {
    if (!std.mem.startsWith(u8, p.line, common.shallow)) {
        p.setError("malformed shallow prefix", .{});
        return null;
    }
    const rest = p.line[common.shallow.len..];

    const hs = common.hashSize();
    if (rest.len != hs) {
        p.setError("malformed shallow hash: wrong length", .{});
        return null;
    }

    var hash_bytes: [plumbing.MaxSize]u8 = .{0} ** plumbing.MaxSize;
    const n = hs / 2;
    _ = std.fmt.hexToBytes(hash_bytes[0..n], rest[0..hs]) catch {
        p.setError("invalid hash text", .{});
        return null;
    };
    p.data.appendShallow(Hash.fromBytes(hash_bytes[0..n])) catch {
        p.err = error.OutOfMemory;
        return null;
    };

    if (!p.nextLine()) return null;

    if (p.line.len == 0) {
        return null; // success
    }
    return @ptrCast(&decodeShallow);
}

// ---------------------------------------------------------------------------
// Tests — go-git advrefs_decode_test.go + decode/encode round-trips
// ---------------------------------------------------------------------------

fn encodePayloads(allocator: Allocator, payloads: []const []const u8) ![]u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var e = pktline.Encoder.init(&aw.writer);
    try e.encodeString(payloads);
    return try aw.toOwnedSlice();
}

fn testDecodeOK(allocator: Allocator, payloads: []const []const u8) !AdvRefs {
    const buf = try encodePayloads(allocator, payloads);
    defer allocator.free(buf);

    var ar = AdvRefs.init(allocator);
    errdefer ar.deinit();

    var r: Reader = .fixed(buf);
    try ar.decode(&r);
    return ar;
}

fn testDecoderError(allocator: Allocator, payloads: []const []const u8, expected: anyerror) !void {
    const buf = try encodePayloads(allocator, payloads);
    defer allocator.free(buf);

    var ar = AdvRefs.init(allocator);
    defer ar.deinit();

    var r: Reader = .fixed(buf);
    try testing.expectError(expected, ar.decode(&r));
}

test "advrefs_decode.TestEmpty" {
    const allocator = testing.allocator;
    var ar = AdvRefs.init(allocator);
    defer ar.deinit();
    var r: Reader = .fixed(&.{});
    try testing.expectError(error.EmptyInput, ar.decode(&r));
}

test "advrefs_decode.TestEmptyFlush" {
    const allocator = testing.allocator;
    var storage: [8]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var e = pktline.Encoder.init(&w);
    try e.flush();

    var ar = AdvRefs.init(allocator);
    defer ar.deinit();
    var r: Reader = .fixed(w.buffered());
    try testing.expectError(error.EmptyAdvRefs, ar.decode(&r));
}

test "advrefs_decode.TestEmptyPrefixFlush" {
    const allocator = testing.allocator;
    const buf = try encodePayloads(allocator, &.{
        "# service=git-upload-pack",
        pktline.FlushString,
        pktline.FlushString,
    });
    defer allocator.free(buf);

    var ar = AdvRefs.init(allocator);
    defer ar.deinit();
    var r: Reader = .fixed(buf);
    try testing.expectError(error.EmptyAdvRefs, ar.decode(&r));
}

test "advrefs_decode.TestShortForHash" {
    const allocator = testing.allocator;
    try testDecoderError(allocator, &.{
        "6ecf0ef2c2dffb796",
        pktline.FlushString,
    }, error.UnexpectedData);
}

test "advrefs_decode.TestInvalidFirstHash" {
    const allocator = testing.allocator;
    try testDecoderError(allocator, &.{
        "6ecf0ef2c2dffb796alberto2219af86ec6584e5 HEAD\x00multi_ack thin-pack\n",
        pktline.FlushString,
    }, error.UnexpectedData);
}

test "advrefs_decode.TestZeroId" {
    const allocator = testing.allocator;
    var ar = try testDecodeOK(allocator, &.{
        "0000000000000000000000000000000000000000 capabilities^{}\x00multi_ack thin-pack\n",
        pktline.FlushString,
    });
    defer ar.deinit();
    try testing.expect(ar.head == null);
}

test "advrefs_decode.TestMalformedZeroId" {
    const allocator = testing.allocator;
    try testDecoderError(allocator, &.{
        "0000000000000000000000000000000000000000 wrong\x00multi_ack thin-pack\n",
        pktline.FlushString,
    }, error.UnexpectedData);
}

test "advrefs_decode.TestShortZeroId" {
    const allocator = testing.allocator;
    try testDecoderError(allocator, &.{
        "0000000000000000000000000000000000000000 capabi",
        pktline.FlushString,
    }, error.UnexpectedData);
}

test "advrefs_decode.TestHead" {
    const allocator = testing.allocator;
    var ar = try testDecodeOK(allocator, &.{
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00",
        pktline.FlushString,
    });
    defer ar.deinit();
    const h = ar.head.?;
    const expect = plumbing.newHash("6ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    try testing.expect(h.eql(expect));
}

test "advrefs_decode.TestFirstIsNotHead" {
    const allocator = testing.allocator;
    var ar = try testDecodeOK(allocator, &.{
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 refs/heads/master\x00",
        pktline.FlushString,
    });
    defer ar.deinit();
    try testing.expect(ar.head == null);
    const got = ar.references.get("refs/heads/master").?;
    try testing.expect(got.eql(plumbing.newHash("6ecf0ef2c2dffb796033e5a02219af86ec6584e5")));
}

test "advrefs_decode.TestShortRef" {
    const allocator = testing.allocator;
    try testDecoderError(allocator, &.{
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 H",
        pktline.FlushString,
    }, error.UnexpectedData);
}

test "advrefs_decode.TestNoNULL" {
    const allocator = testing.allocator;
    try testDecoderError(allocator, &.{
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEADofs-delta multi_ack",
        pktline.FlushString,
    }, error.UnexpectedData);
}

test "advrefs_decode.TestNoSpaceAfterHash" {
    const allocator = testing.allocator;
    try testDecoderError(allocator, &.{
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5-HEAD\x00",
        pktline.FlushString,
    }, error.UnexpectedData);
}

test "advrefs_decode.TestNoCaps" {
    const allocator = testing.allocator;
    var ar = try testDecodeOK(allocator, &.{
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00",
        pktline.FlushString,
    });
    defer ar.deinit();
    try testing.expect(ar.capabilities.isEmpty());
}

test "advrefs_decode.TestCaps" {
    const allocator = testing.allocator;
    {
        var ar = try testDecodeOK(allocator, &.{
            "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00ofs-delta multi_ack",
            pktline.FlushString,
        });
        defer ar.deinit();
        try testing.expect(ar.capabilities.supports(capability.OFSDelta));
        try testing.expect(ar.capabilities.supports(capability.MultiACK));
    }
    {
        var ar = try testDecodeOK(allocator, &.{
            "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00symref=HEAD:refs/heads/master agent=foo=bar\n",
            pktline.FlushString,
        });
        defer ar.deinit();
        try testing.expect(ar.capabilities.supports(capability.SymRef));
        const vals = ar.capabilities.get(capability.SymRef);
        try testing.expectEqual(@as(usize, 1), vals.len);
        try testing.expectEqualStrings("HEAD:refs/heads/master", vals[0]);
        const agent = ar.capabilities.get(capability.Agent);
        try testing.expectEqual(@as(usize, 1), agent.len);
        try testing.expectEqualStrings("foo=bar", agent[0]);
    }
}

test "advrefs_decode.TestWithPrefix" {
    const allocator = testing.allocator;
    var ar = try testDecodeOK(allocator, &.{
        "# this is a prefix\n",
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00ofs-delta\n",
        pktline.FlushString,
    });
    defer ar.deinit();
    try testing.expectEqual(@as(usize, 1), ar.prefix.items.len);
    try testing.expectEqualStrings("# this is a prefix", ar.prefix.items[0]);
}

test "advrefs_decode.TestWithPrefixAndFlush" {
    const allocator = testing.allocator;
    var ar = try testDecodeOK(allocator, &.{
        "# this is a prefix\n",
        pktline.FlushString,
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00ofs-delta\n",
        pktline.FlushString,
    });
    defer ar.deinit();
    try testing.expectEqual(@as(usize, 2), ar.prefix.items.len);
    try testing.expectEqualStrings("# this is a prefix", ar.prefix.items[0]);
    try testing.expectEqual(@as(usize, 0), ar.prefix.items[1].len);
}

test "advrefs_decode.TestOtherRefs" {
    const allocator = testing.allocator;
    var ar = try testDecodeOK(allocator, &.{
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00ofs-delta symref=HEAD:/refs/heads/master\n",
        "1111111111111111111111111111111111111111 ref/foo\n",
        "2222222222222222222222222222222222222222 ref/bar^{}",
        pktline.FlushString,
    });
    defer ar.deinit();
    try testing.expect(ar.references.get("ref/foo").?.eql(plumbing.newHash("1111111111111111111111111111111111111111")));
    try testing.expect(ar.peeled.get("ref/bar").?.eql(plumbing.newHash("2222222222222222222222222222222222222222")));
}

test "advrefs_decode.TestShallow" {
    const allocator = testing.allocator;
    var ar = try testDecodeOK(allocator, &.{
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00ofs-delta\n",
        "a6930aaee06755d1bdcfd943fbf614e4d92bb0c7 refs/heads/master\n",
        "shallow 1111111111111111111111111111111111111111\n",
        "shallow 2222222222222222222222222222222222222222\n",
        pktline.FlushString,
    });
    defer ar.deinit();
    try testing.expectEqual(@as(usize, 2), ar.shallows.items.len);
    try testing.expect(ar.shallows.items[0].eql(plumbing.newHash("1111111111111111111111111111111111111111")));
    try testing.expect(ar.shallows.items[1].eql(plumbing.newHash("2222222222222222222222222222222222222222")));
}

test "advrefs_decode.TestInvalidShallowHash" {
    const allocator = testing.allocator;
    try testDecoderError(allocator, &.{
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00ofs-delta\n",
        "shallow 11111111alcortes111111111111111111111111\n",
        pktline.FlushString,
    }, error.UnexpectedData);
}

test "advrefs_decode.TestGarbageAfterShallow" {
    const allocator = testing.allocator;
    try testDecoderError(allocator, &.{
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00ofs-delta\n",
        "shallow 1111111111111111111111111111111111111111\n",
        "b5be40b90dbaa6bd337f3b77de361bfc0723468b refs/tags/v4.4",
        pktline.FlushString,
    }, error.UnexpectedData);
}

test "advrefs_decode.TestMalformedShallowHash" {
    const allocator = testing.allocator;
    try testDecoderError(allocator, &.{
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00ofs-delta\n",
        "shallow 2222222222222222222222222222222222222222 malformed\n",
        pktline.FlushString,
    }, error.UnexpectedData);
}

test "advrefs_decode.TestMalformedOtherRefsNoSpace" {
    const allocator = testing.allocator;
    try testDecoderError(allocator, &.{
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00multi_ack thin-pack\n",
        "5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8crefs/tags/v2.6.11\n",
        pktline.FlushString,
    }, error.UnexpectedData);
}

test "advrefs_decode.TestMalformedOtherRefsMultipleSpaces" {
    const allocator = testing.allocator;
    try testDecoderError(allocator, &.{
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00multi_ack thin-pack\n",
        "5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c refs/tags v2.6.11\n",
        pktline.FlushString,
    }, error.UnexpectedData);
}

// --- decode/encode round-trips (advrefs_test.go AdvRefsDecodeEncodeSuite) ---

fn testDecodeEncode(
    allocator: Allocator,
    input: []const []const u8,
    expected: []const []const u8,
    is_empty: bool,
) !void {
    const in_buf = try encodePayloads(allocator, input);
    defer allocator.free(in_buf);
    const exp_buf = try encodePayloads(allocator, expected);
    defer allocator.free(exp_buf);

    var ar = AdvRefs.init(allocator);
    defer ar.deinit();

    var r: Reader = .fixed(in_buf);
    try ar.decode(&r);
    try testing.expectEqual(is_empty, ar.isEmpty());

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try ar.encode(&aw.writer);
    try testing.expectEqualSlices(u8, exp_buf, aw.written());
}

test "advrefs_decode_encode.TestNoHead" {
    const allocator = testing.allocator;
    try testDecodeEncode(
        allocator,
        &.{
            "0000000000000000000000000000000000000000 capabilities^{}\x00",
            pktline.FlushString,
        },
        &.{
            "0000000000000000000000000000000000000000 capabilities^{}\x00\n",
            pktline.FlushString,
        },
        true,
    );
}

test "advrefs_decode_encode.TestNoHeadSmart" {
    const allocator = testing.allocator;
    try testDecodeEncode(
        allocator,
        &.{
            "# service=git-upload-pack\n",
            "0000000000000000000000000000000000000000 capabilities^{}\x00",
            pktline.FlushString,
        },
        &.{
            "# service=git-upload-pack\n",
            "0000000000000000000000000000000000000000 capabilities^{}\x00\n",
            pktline.FlushString,
        },
        true,
    );
}

test "advrefs_decode_encode.TestNoHeadSmartBug" {
    const allocator = testing.allocator;
    try testDecodeEncode(
        allocator,
        &.{
            "# service=git-upload-pack\n",
            pktline.FlushString,
            "0000000000000000000000000000000000000000 capabilities^{}\x00\n",
            pktline.FlushString,
        },
        &.{
            "# service=git-upload-pack\n",
            pktline.FlushString,
            "0000000000000000000000000000000000000000 capabilities^{}\x00\n",
            pktline.FlushString,
        },
        true,
    );
}

test "advrefs_decode_encode.TestRefs" {
    const allocator = testing.allocator;
    try testDecodeEncode(
        allocator,
        &.{
            "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00symref=HEAD:/refs/heads/master ofs-delta multi_ack",
            "a6930aaee06755d1bdcfd943fbf614e4d92bb0c7 refs/heads/master",
            "5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c refs/tags/v2.6.11-tree\n",
            "7777777777777777777777777777777777777777 refs/tags/v2.6.12-tree",
            pktline.FlushString,
        },
        &.{
            "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00symref=HEAD:/refs/heads/master ofs-delta multi_ack\n",
            "a6930aaee06755d1bdcfd943fbf614e4d92bb0c7 refs/heads/master\n",
            "5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c refs/tags/v2.6.11-tree\n",
            "7777777777777777777777777777777777777777 refs/tags/v2.6.12-tree\n",
            pktline.FlushString,
        },
        false,
    );
}

test "advrefs_decode_encode.TestPeeled" {
    const allocator = testing.allocator;
    try testDecodeEncode(
        allocator,
        &.{
            "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00symref=HEAD:/refs/heads/master ofs-delta multi_ack",
            "7777777777777777777777777777777777777777 refs/tags/v2.6.12-tree\n",
            "8888888888888888888888888888888888888888 refs/tags/v2.6.12-tree^{}",
            "a6930aaee06755d1bdcfd943fbf614e4d92bb0c7 refs/heads/master\n",
            "5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c refs/tags/v2.6.11-tree",
            "c39ae07f393806ccf406ef966e9a15afc43cc36a refs/tags/v2.6.11-tree^{}\n",
            pktline.FlushString,
        },
        &.{
            "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00symref=HEAD:/refs/heads/master ofs-delta multi_ack\n",
            "a6930aaee06755d1bdcfd943fbf614e4d92bb0c7 refs/heads/master\n",
            "5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c refs/tags/v2.6.11-tree\n",
            "c39ae07f393806ccf406ef966e9a15afc43cc36a refs/tags/v2.6.11-tree^{}\n",
            "7777777777777777777777777777777777777777 refs/tags/v2.6.12-tree\n",
            "8888888888888888888888888888888888888888 refs/tags/v2.6.12-tree^{}\n",
            pktline.FlushString,
        },
        false,
    );
}

test "advrefs_decode_encode.TestAll" {
    const allocator = testing.allocator;
    try testDecodeEncode(
        allocator,
        &.{
            "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00symref=HEAD:/refs/heads/master ofs-delta multi_ack\n",
            "a6930aaee06755d1bdcfd943fbf614e4d92bb0c7 refs/heads/master\n",
            "5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c refs/tags/v2.6.11-tree",
            "c39ae07f393806ccf406ef966e9a15afc43cc36a refs/tags/v2.6.11-tree^{}\n",
            "7777777777777777777777777777777777777777 refs/tags/v2.6.12-tree\n",
            "8888888888888888888888888888888888888888 refs/tags/v2.6.12-tree^{}",
            "shallow 1111111111111111111111111111111111111111",
            "shallow 2222222222222222222222222222222222222222\n",
            pktline.FlushString,
        },
        &.{
            "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00symref=HEAD:/refs/heads/master ofs-delta multi_ack\n",
            "a6930aaee06755d1bdcfd943fbf614e4d92bb0c7 refs/heads/master\n",
            "5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c refs/tags/v2.6.11-tree\n",
            "c39ae07f393806ccf406ef966e9a15afc43cc36a refs/tags/v2.6.11-tree^{}\n",
            "7777777777777777777777777777777777777777 refs/tags/v2.6.12-tree\n",
            "8888888888888888888888888888888888888888 refs/tags/v2.6.12-tree^{}\n",
            "shallow 1111111111111111111111111111111111111111\n",
            "shallow 2222222222222222222222222222222222222222\n",
            pktline.FlushString,
        },
        false,
    );
}

test "advrefs_decode_encode.TestAllSmart" {
    const allocator = testing.allocator;
    try testDecodeEncode(
        allocator,
        &.{
            "# service=git-upload-pack\n",
            pktline.FlushString,
            "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00symref=HEAD:/refs/heads/master ofs-delta multi_ack\n",
            "a6930aaee06755d1bdcfd943fbf614e4d92bb0c7 refs/heads/master\n",
            "5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c refs/tags/v2.6.11-tree\n",
            "c39ae07f393806ccf406ef966e9a15afc43cc36a refs/tags/v2.6.11-tree^{}\n",
            "7777777777777777777777777777777777777777 refs/tags/v2.6.12-tree\n",
            "8888888888888888888888888888888888888888 refs/tags/v2.6.12-tree^{}\n",
            "shallow 1111111111111111111111111111111111111111\n",
            "shallow 2222222222222222222222222222222222222222\n",
            pktline.FlushString,
        },
        &.{
            "# service=git-upload-pack\n",
            pktline.FlushString,
            "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00symref=HEAD:/refs/heads/master ofs-delta multi_ack\n",
            "a6930aaee06755d1bdcfd943fbf614e4d92bb0c7 refs/heads/master\n",
            "5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c refs/tags/v2.6.11-tree\n",
            "c39ae07f393806ccf406ef966e9a15afc43cc36a refs/tags/v2.6.11-tree^{}\n",
            "7777777777777777777777777777777777777777 refs/tags/v2.6.12-tree\n",
            "8888888888888888888888888888888888888888 refs/tags/v2.6.12-tree^{}\n",
            "shallow 1111111111111111111111111111111111111111\n",
            "shallow 2222222222222222222222222222222222222222\n",
            pktline.FlushString,
        },
        false,
    );
}
