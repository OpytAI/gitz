//! Decode `ReferenceUpdateRequest` — port of go-git
//! `plumbing/protocol/packp/updreq_decode.go` (v5.19.2).
//!
//! Note: go-git does not decode push-options; options after the command flush
//! remain part of the residual packfile stream (matched here).

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const plumbing = @import("plumbing");
const pktline = @import("pktline");
const common = @import("common.zig");
const updreq = @import("updreq.zig");

const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const HexSize = plumbing.HexSize;
const Command = updreq.Command;
const ReferenceUpdateRequest = updreq.ReferenceUpdateRequest;

fn shallowLineLength() usize {
    return common.shallow.len + common.hashSize();
}
fn minCommandLength() usize {
    return common.hashSize() * 2 + 2 + 1;
}
fn minCommandAndCapsLength() usize {
    return minCommandLength() + 1;
}

/// go-git `(*ReferenceUpdateRequest).Decode`.
pub fn decode(req: *ReferenceUpdateRequest, r: *Reader) updreq.DecodeError!void {
    var d = UpdReqDecoder{
        .r = r,
        .s = pktline.Scanner.init(r),
        .req = req,
    };
    try d.decodeAll();
}

const UpdReqDecoder = struct {
    r: *Reader,
    s: pktline.Scanner,
    req: *ReferenceUpdateRequest,

    fn decodeAll(self: *UpdReqDecoder) updreq.DecodeError!void {
        try self.scanLine();
        try self.decodeShallow();
        try self.decodeCommandAndCapabilities();
        try self.decodeCommands();
        try self.setPackfile();
        try self.req.validate();
    }

    fn scanLine(self: *UpdReqDecoder) updreq.DecodeError!void {
        if (!self.s.scan()) {
            return self.scanErrorOr(error.Empty);
        }
    }

    fn decodeShallow(self: *UpdReqDecoder) updreq.DecodeError!void {
        const b = self.s.bytes();
        if (!std.mem.startsWith(u8, b, common.shallow_no_sp)) {
            return;
        }

        if (b.len != shallowLineLength()) {
            return error.InvalidShallowLineLength;
        }

        const h = parseHash(b[common.shallow.len..]) catch |err| switch (err) {
            error.InvalidHashSize => return error.InvalidShallowObjId,
            error.InvalidHash => return error.InvalidShallowObjId,
            else => |e| return e,
        };

        if (!self.s.scan()) {
            return self.scanErrorOr(error.NoCommands);
        }

        self.req.shallow = h;
    }

    fn decodeCommandAndCapabilities(self: *UpdReqDecoder) updreq.DecodeError!void {
        const b = self.s.bytes();
        const i = std.mem.indexOfScalar(u8, b, 0) orelse return error.MissingCapabilitiesDelimiter;

        if (b.len < minCommandAndCapsLength()) {
            return error.InvalidCommandCapabilitiesLineLength;
        }

        const cmd = try parseCommand(b[0..i]);
        try self.req.appendCommandOwnedName(cmd.name.string(), cmd.old, cmd.new);

        try self.req.capabilities.decode(b[i + 1 ..]);

        try self.scanLine();
    }

    fn decodeCommands(self: *UpdReqDecoder) updreq.DecodeError!void {
        while (true) {
            const b = self.s.bytes();
            if (common.isFlush(b)) return;

            const cmd = try parseCommand(b);
            try self.req.appendCommandOwnedName(cmd.name.string(), cmd.old, cmd.new);

            if (!self.s.scan()) {
                if (self.s.err()) |e| return e;
                return;
            }
        }
    }

    fn setPackfile(self: *UpdReqDecoder) updreq.DecodeError!void {
        self.req.packfile = self.r;
    }

    fn scanErrorOr(self: *UpdReqDecoder, orig: updreq.Error) updreq.DecodeError!void {
        if (self.s.err()) |e| return e;
        return orig;
    }
};

fn parseCommand(b: []const u8) updreq.Error!Command {
    if (b.len < minCommandLength()) return error.InvalidCommandLineLength;

    // go-git: fmt.Sscanf("%s %s %s") — three whitespace-separated tokens.
    var it = std.mem.tokenizeAny(u8, b, " \t");
    const os = it.next() orelse return error.MalformedCommand;
    const ns = it.next() orelse return error.MalformedCommand;
    const n = it.next() orelse return error.MalformedCommand;

    // Require that the three tokens come from a space-separated form: reject
    // the single-token case that Sscanf reports as EOF (no spaces at all).
    // When Sscanf fails it returns ErrMalformedCommand with EOF; when tokens
    // parse but hashes are wrong, more specific errors apply.
    //
    // If the line has no space separators, tokenizeAny yields one field only
    // and we already returned MalformedCommand above.

    const oh = parseHash(os) catch |err| switch (err) {
        error.InvalidHashSize => return error.InvalidOldObjId,
        error.InvalidHash => return error.InvalidOldObjId,
        else => |e| return e,
    };
    const nh = parseHash(ns) catch |err| switch (err) {
        error.InvalidHashSize => return error.InvalidNewObjId,
        error.InvalidHash => return error.InvalidNewObjId,
        else => |e| return e,
    };

    return .{
        .name = plumbing.ReferenceName.init(n),
        .old = oh,
        .new = nh,
    };
}

/// Strict hash parse (go-git `parseHash` in updreq_decode.go).
fn parseHash(s: []const u8) updreq.Error!Hash {
    if (s.len != common.hashSize()) return error.InvalidHashSize;
    return plumbing.parseHash(s) catch return error.InvalidHash;
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

fn toPktLines(allocator: Allocator, payloads: []const []const u8) ![]u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var e = pktline.Encoder.init(&aw.writer);
    try e.encodeString(payloads);
    return try aw.toOwnedSlice();
}

fn testDecoderError(allocator: Allocator, input: []const u8, expected: anyerror) !void {
    var r = try updreq.newReferenceUpdateRequest(allocator);
    defer r.deinit();
    var reader: Reader = .fixed(input);
    try testing.expectError(expected, r.decode(&reader));
}

fn compareReaders(a: *Reader, b: *Reader) !void {
    var abuf: Writer.Allocating = .init(testing.allocator);
    defer abuf.deinit();
    var bbuf: Writer.Allocating = .init(testing.allocator);
    defer bbuf.deinit();
    _ = try a.streamRemaining(&abuf.writer);
    _ = try b.streamRemaining(&bbuf.writer);
    try testing.expectEqualSlices(u8, abuf.written(), bbuf.written());
}

fn expectDecode(
    allocator: Allocator,
    expected_cmds: []const Command,
    expected_caps: []const u8,
    expected_shallow: ?Hash,
    expected_pack: []const u8,
    payloads: []const []const u8,
    pack_suffix: []const u8,
) !void {
    var raw_list: std.ArrayList(u8) = .empty;
    defer raw_list.deinit(allocator);
    const header = try toPktLines(allocator, payloads);
    defer allocator.free(header);
    try raw_list.appendSlice(allocator, header);
    try raw_list.appendSlice(allocator, pack_suffix);

    var req = try updreq.newReferenceUpdateRequest(allocator);
    defer req.deinit();
    var reader: Reader = .fixed(raw_list.items);
    try req.decode(&reader);

    try testing.expect(req.packfile != null);
    var pack_reader: Reader = .fixed(expected_pack);
    try compareReaders(req.packfile.?, &pack_reader);

    try testing.expectEqual(expected_cmds.len, req.commands.items.len);
    for (expected_cmds, req.commands.items) |exp, got| {
        try testing.expectEqualStrings(exp.name.string(), got.name.string());
        try testing.expect(exp.old.eql(got.old));
        try testing.expect(exp.new.eql(got.new));
    }

    const caps = try req.capabilities.string(allocator);
    defer allocator.free(caps);
    try testing.expectEqualStrings(expected_caps, caps);

    if (expected_shallow) |es| {
        try testing.expect(req.shallow != null);
        try testing.expect(es.eql(req.shallow.?));
    } else {
        try testing.expect(req.shallow == null);
    }
}

// ---------------------------------------------------------------------------
// Tests — updreq_decode_test.go
// ---------------------------------------------------------------------------

test "updreq_decode_test.TestEmpty" {
    const allocator = testing.allocator;
    var r = try updreq.newReferenceUpdateRequest(allocator);
    defer r.deinit();
    var reader: Reader = .fixed(&.{});
    try testing.expectError(error.Empty, r.decode(&reader));
    try testing.expectEqual(@as(usize, 0), r.commands.items.len);
}

test "updreq_decode_test.TestInvalidPktlines" {
    const allocator = testing.allocator;
    var r = try updreq.newReferenceUpdateRequest(allocator);
    defer r.deinit();
    var reader: Reader = .fixed("xxxxxxxxxx");
    try testing.expectError(error.InvalidPktLen, r.decode(&reader));
}

test "updreq_decode_test.TestInvalidShadow" {
    const allocator = testing.allocator;

    {
        const raw = try toPktLines(allocator, &.{
            "shallow",
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref\x00",
            pktline.FlushString,
        });
        defer allocator.free(raw);
        try testDecoderError(allocator, raw, error.InvalidShallowLineLength);
    }
    {
        const raw = try toPktLines(allocator, &.{
            "shallow ",
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref\x00",
            pktline.FlushString,
        });
        defer allocator.free(raw);
        try testDecoderError(allocator, raw, error.InvalidShallowLineLength);
    }
    {
        const raw = try toPktLines(allocator, &.{
            "shallow 1ecf0ef2c2dffb796033e5a02219af86ec65",
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref\x00",
            pktline.FlushString,
        });
        defer allocator.free(raw);
        try testDecoderError(allocator, raw, error.InvalidShallowLineLength);
    }
    {
        const raw = try toPktLines(allocator, &.{
            "shallow 1ecf0ef2c2dffb796033e5a02219af86ec6584e54",
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref\x00",
            pktline.FlushString,
        });
        defer allocator.free(raw);
        try testDecoderError(allocator, raw, error.InvalidShallowLineLength);
    }
    {
        const raw = try toPktLines(allocator, &.{
            "shallow 1ecf0ef2c2dffb796033e5a02219af86ec6584eu",
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref\x00",
            pktline.FlushString,
        });
        defer allocator.free(raw);
        try testDecoderError(allocator, raw, error.InvalidShallowObjId);
    }
}

test "updreq_decode_test.TestMalformedCommand" {
    const allocator = testing.allocator;
    {
        const raw = try toPktLines(allocator, &.{
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5x2ecf0ef2c2dffb796033e5a02219af86ec6584e5xmyref\x00",
            pktline.FlushString,
        });
        defer allocator.free(raw);
        try testDecoderError(allocator, raw, error.MalformedCommand);
    }
    {
        const raw = try toPktLines(allocator, &.{
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref\x00",
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5x2ecf0ef2c2dffb796033e5a02219af86ec6584e5xmyref",
            pktline.FlushString,
        });
        defer allocator.free(raw);
        try testDecoderError(allocator, raw, error.MalformedCommand);
    }
}

test "updreq_decode_test.TestInvalidCommandInvalidHash" {
    const allocator = testing.allocator;
    {
        const raw = try toPktLines(allocator, &.{
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref\x00",
            pktline.FlushString,
        });
        defer allocator.free(raw);
        try testDecoderError(allocator, raw, error.InvalidOldObjId);
    }
    {
        const raw = try toPktLines(allocator, &.{
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e myref\x00",
            pktline.FlushString,
        });
        defer allocator.free(raw);
        try testDecoderError(allocator, raw, error.InvalidNewObjId);
    }
    {
        const raw = try toPktLines(allocator, &.{
            "1ecf0ef2c2dffb796033e5a02219af86e 2ecf0ef2c2dffb796033e5a02219af86ec6 m\x00",
            pktline.FlushString,
        });
        defer allocator.free(raw);
        try testDecoderError(allocator, raw, error.InvalidCommandCapabilitiesLineLength);
    }
    {
        const raw = try toPktLines(allocator, &.{
            "1ecf0ef2c2dffb796033e5a02219af86ec6584eu 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref\x00",
            pktline.FlushString,
        });
        defer allocator.free(raw);
        try testDecoderError(allocator, raw, error.InvalidOldObjId);
    }
    {
        const raw = try toPktLines(allocator, &.{
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584eu myref\x00",
            pktline.FlushString,
        });
        defer allocator.free(raw);
        try testDecoderError(allocator, raw, error.InvalidNewObjId);
    }
}

test "updreq_decode_test.TestInvalidCommandMissingNullDelimiter" {
    const allocator = testing.allocator;
    const raw = try toPktLines(allocator, &.{
        "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref",
        pktline.FlushString,
    });
    defer allocator.free(raw);
    try testDecoderError(allocator, raw, error.MissingCapabilitiesDelimiter);
}

test "updreq_decode_test.TestInvalidCommandMissingName" {
    const allocator = testing.allocator;
    {
        const raw = try toPktLines(allocator, &.{
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5\x00",
            pktline.FlushString,
        });
        defer allocator.free(raw);
        try testDecoderError(allocator, raw, error.InvalidCommandCapabilitiesLineLength);
    }
    {
        const raw = try toPktLines(allocator, &.{
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 \x00",
            pktline.FlushString,
        });
        defer allocator.free(raw);
        try testDecoderError(allocator, raw, error.InvalidCommandCapabilitiesLineLength);
    }
    {
        const raw = try toPktLines(allocator, &.{
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref\x00",
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5",
            pktline.FlushString,
        });
        defer allocator.free(raw);
        try testDecoderError(allocator, raw, error.InvalidCommandLineLength);
    }
    {
        const raw = try toPktLines(allocator, &.{
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref\x00",
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 ",
            pktline.FlushString,
        });
        defer allocator.free(raw);
        try testDecoderError(allocator, raw, error.InvalidCommandLineLength);
    }
}

test "updreq_decode_test.TestOneUpdateCommand" {
    const allocator = testing.allocator;
    const hash1 = plumbing.newHash("1ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    const hash2 = plumbing.newHash("2ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    try expectDecode(
        allocator,
        &.{
            .{ .name = plumbing.ReferenceName.init("myref"), .old = hash1, .new = hash2 },
        },
        "",
        null,
        "",
        &.{
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref\x00",
            pktline.FlushString,
        },
        "",
    );
}

test "updreq_decode_test.TestMultipleCommands" {
    const allocator = testing.allocator;
    const hash1 = plumbing.newHash("1ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    const hash2 = plumbing.newHash("2ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    try expectDecode(
        allocator,
        &.{
            .{ .name = plumbing.ReferenceName.init("myref1"), .old = hash1, .new = hash2 },
            .{ .name = plumbing.ReferenceName.init("myref2"), .old = ZeroHash, .new = hash2 },
            .{ .name = plumbing.ReferenceName.init("myref3"), .old = hash1, .new = ZeroHash },
        },
        "",
        null,
        "",
        &.{
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref1\x00",
            "0000000000000000000000000000000000000000 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref2",
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 0000000000000000000000000000000000000000 myref3",
            pktline.FlushString,
        },
        "",
    );
}

test "updreq_decode_test.TestMultipleCommandsAndCapabilities" {
    const allocator = testing.allocator;
    const hash1 = plumbing.newHash("1ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    const hash2 = plumbing.newHash("2ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    try expectDecode(
        allocator,
        &.{
            .{ .name = plumbing.ReferenceName.init("myref1"), .old = hash1, .new = hash2 },
            .{ .name = plumbing.ReferenceName.init("myref2"), .old = ZeroHash, .new = hash2 },
            .{ .name = plumbing.ReferenceName.init("myref3"), .old = hash1, .new = ZeroHash },
        },
        "shallow",
        null,
        "",
        &.{
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref1\x00shallow",
            "0000000000000000000000000000000000000000 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref2",
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 0000000000000000000000000000000000000000 myref3",
            pktline.FlushString,
        },
        "",
    );
}

test "updreq_decode_test.TestMultipleCommandsAndCapabilitiesShallow" {
    const allocator = testing.allocator;
    const hash1 = plumbing.newHash("1ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    const hash2 = plumbing.newHash("2ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    try expectDecode(
        allocator,
        &.{
            .{ .name = plumbing.ReferenceName.init("myref1"), .old = hash1, .new = hash2 },
            .{ .name = plumbing.ReferenceName.init("myref2"), .old = ZeroHash, .new = hash2 },
            .{ .name = plumbing.ReferenceName.init("myref3"), .old = hash1, .new = ZeroHash },
        },
        "shallow",
        hash1,
        "",
        &.{
            "shallow 1ecf0ef2c2dffb796033e5a02219af86ec6584e5",
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref1\x00shallow",
            "0000000000000000000000000000000000000000 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref2",
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 0000000000000000000000000000000000000000 myref3",
            pktline.FlushString,
        },
        "",
    );
}

test "updreq_decode_test.TestWithPackfile" {
    const allocator = testing.allocator;
    const hash1 = plumbing.newHash("1ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    const hash2 = plumbing.newHash("2ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    const packfile_content = "PACKabc";
    try expectDecode(
        allocator,
        &.{
            .{ .name = plumbing.ReferenceName.init("myref"), .old = hash1, .new = hash2 },
        },
        "",
        null,
        packfile_content,
        &.{
            "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref\x00",
            pktline.FlushString,
        },
        packfile_content,
    );
}

// Keep HexSize referenced for documentation parity with go-git hashSize usage.
test {
    _ = HexSize;
}
