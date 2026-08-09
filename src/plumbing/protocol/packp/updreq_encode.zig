//! Encode `ReferenceUpdateRequest` — port of go-git
//! `plumbing/protocol/packp/updreq_encode.go` (v5.19.2).

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const plumbing = @import("plumbing");
const pktline = @import("pktline");
const capability = @import("capability");
const common = @import("common.zig");
const updreq = @import("updreq.zig");

const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const ReferenceName = plumbing.ReferenceName;
const HexSize = plumbing.HexSize;
const MaxHexSize = plumbing.MaxHexSize;
const Command = updreq.Command;
const Option = updreq.Option;
const ReferenceUpdateRequest = updreq.ReferenceUpdateRequest;

/// go-git `(*ReferenceUpdateRequest).Encode`.
pub fn encode(req: *ReferenceUpdateRequest, w: *Writer) updreq.EncodeError!void {
    try req.validate();

    var e = pktline.Encoder.init(w);

    try encodeShallow(&e, req.shallow);
    try encodeCommands(&e, req.commands.items, &req.capabilities, req.allocator);

    if (req.capabilities.supports(capability.PushOptions)) {
        try encodeOptions(&e, req.options.items);
    }

    if (req.packfile) |pf| {
        _ = try pf.streamRemaining(w);
    }
}

fn encodeShallow(e: *pktline.Encoder, h: ?Hash) (pktline.Error || Writer.Error)!void {
    const hash = h orelse return;
    var hex_buf: [MaxHexSize]u8 = undefined;
    const hex = hash.string(&hex_buf);
    try e.encodef("{s}{s}", .{ common.shallow, hex });
}

fn encodeCommands(
    e: *pktline.Encoder,
    cmds: []const Command,
    cap_list: *const capability.List,
    allocator: Allocator,
) (pktline.Error || Writer.Error || Allocator.Error || capability.Error)!void {
    const caps_str = try cap_list.string(allocator);
    defer allocator.free(caps_str);

    var old_hex_buf: [MaxHexSize]u8 = undefined;
    var new_hex_buf: [MaxHexSize]u8 = undefined;
    const old0 = cmds[0].old.string(&old_hex_buf);
    const new0 = cmds[0].new.string(&new_hex_buf);
    try e.encodef("{s} {s} {s}\x00{s}", .{
        old0,
        new0,
        cmds[0].name.string(),
        caps_str,
    });

    for (cmds[1..]) |cmd| {
        const old_h = cmd.old.string(&old_hex_buf);
        const new_h = cmd.new.string(&new_hex_buf);
        try e.encodef("{s} {s} {s}", .{
            old_h,
            new_h,
            cmd.name.string(),
        });
    }

    try e.flush();
}

fn encodeOptions(e: *pktline.Encoder, opts: []const Option) (pktline.Error || Writer.Error)!void {
    for (opts) |opt| {
        try e.encodef("{s}={s}", .{ opt.key, opt.value });
    }
    try e.flush();
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

fn pktlines(allocator: Allocator, payloads: []const []const u8) ![]u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var e = pktline.Encoder.init(&aw.writer);
    try e.encodeString(payloads);
    return try aw.toOwnedSlice();
}

fn expectEncode(allocator: Allocator, input: *ReferenceUpdateRequest, expected: []const u8) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try input.encode(&aw.writer);
    try testing.expectEqualSlices(u8, expected, aw.written());
}

// ---------------------------------------------------------------------------
// Tests — updreq_encode_test.go
// ---------------------------------------------------------------------------

test "updreq_encode_test.TestZeroValue" {
    const allocator = testing.allocator;

    var bare: ReferenceUpdateRequest = .{
        .allocator = allocator,
        .capabilities = capability.List.init(allocator),
    };
    defer bare.deinit();

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try testing.expectError(error.EmptyCommands, bare.encode(&aw.writer));

    var r = try updreq.newReferenceUpdateRequest(allocator);
    defer r.deinit();
    try testing.expectError(error.EmptyCommands, r.encode(&aw.writer));
}

test "updreq_encode_test.TestOneUpdateCommand" {
    const allocator = testing.allocator;
    const hash1 = plumbing.newHash("1ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    const hash2 = plumbing.newHash("2ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    const name = ReferenceName.init("myref");

    var r = try updreq.newReferenceUpdateRequest(allocator);
    defer r.deinit();
    try r.appendCommand(.{ .name = name, .old = hash1, .new = hash2 });

    const expected = try pktlines(allocator, &.{
        "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref\x00",
        pktline.FlushString,
    });
    defer allocator.free(expected);

    try expectEncode(allocator, &r, expected);
}

test "updreq_encode_test.TestMultipleCommands" {
    const allocator = testing.allocator;
    const hash1 = plumbing.newHash("1ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    const hash2 = plumbing.newHash("2ecf0ef2c2dffb796033e5a02219af86ec6584e5");

    var r = try updreq.newReferenceUpdateRequest(allocator);
    defer r.deinit();
    try r.appendCommand(.{ .name = ReferenceName.init("myref1"), .old = hash1, .new = hash2 });
    try r.appendCommand(.{ .name = ReferenceName.init("myref2"), .old = ZeroHash, .new = hash2 });
    try r.appendCommand(.{ .name = ReferenceName.init("myref3"), .old = hash1, .new = ZeroHash });

    const expected = try pktlines(allocator, &.{
        "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref1\x00",
        "0000000000000000000000000000000000000000 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref2",
        "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 0000000000000000000000000000000000000000 myref3",
        pktline.FlushString,
    });
    defer allocator.free(expected);

    try expectEncode(allocator, &r, expected);
}

test "updreq_encode_test.TestMultipleCommandsAndCapabilities" {
    const allocator = testing.allocator;
    const hash1 = plumbing.newHash("1ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    const hash2 = plumbing.newHash("2ecf0ef2c2dffb796033e5a02219af86ec6584e5");

    var r = try updreq.newReferenceUpdateRequest(allocator);
    defer r.deinit();
    try r.appendCommand(.{ .name = ReferenceName.init("myref1"), .old = hash1, .new = hash2 });
    try r.appendCommand(.{ .name = ReferenceName.init("myref2"), .old = ZeroHash, .new = hash2 });
    try r.appendCommand(.{ .name = ReferenceName.init("myref3"), .old = hash1, .new = ZeroHash });
    try r.capabilities.add("shallow", &.{});

    const expected = try pktlines(allocator, &.{
        "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref1\x00shallow",
        "0000000000000000000000000000000000000000 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref2",
        "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 0000000000000000000000000000000000000000 myref3",
        pktline.FlushString,
    });
    defer allocator.free(expected);

    try expectEncode(allocator, &r, expected);
}

test "updreq_encode_test.TestMultipleCommandsAndCapabilitiesShallow" {
    const allocator = testing.allocator;
    const hash1 = plumbing.newHash("1ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    const hash2 = plumbing.newHash("2ecf0ef2c2dffb796033e5a02219af86ec6584e5");

    var r = try updreq.newReferenceUpdateRequest(allocator);
    defer r.deinit();
    try r.appendCommand(.{ .name = ReferenceName.init("myref1"), .old = hash1, .new = hash2 });
    try r.appendCommand(.{ .name = ReferenceName.init("myref2"), .old = ZeroHash, .new = hash2 });
    try r.appendCommand(.{ .name = ReferenceName.init("myref3"), .old = hash1, .new = ZeroHash });
    try r.capabilities.add("shallow", &.{});
    r.shallow = hash1;

    const expected = try pktlines(allocator, &.{
        "shallow 1ecf0ef2c2dffb796033e5a02219af86ec6584e5",
        "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref1\x00shallow",
        "0000000000000000000000000000000000000000 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref2",
        "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 0000000000000000000000000000000000000000 myref3",
        pktline.FlushString,
    });
    defer allocator.free(expected);

    try expectEncode(allocator, &r, expected);
}

test "updreq_encode_test.TestWithPackfile" {
    const allocator = testing.allocator;
    const hash1 = plumbing.newHash("1ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    const hash2 = plumbing.newHash("2ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    const name = ReferenceName.init("myref");
    const packfile_content = "PACKabc";

    var pack_reader: Reader = .fixed(packfile_content);

    var r = try updreq.newReferenceUpdateRequest(allocator);
    defer r.deinit();
    try r.appendCommand(.{ .name = name, .old = hash1, .new = hash2 });
    r.packfile = &pack_reader;

    const header = try pktlines(allocator, &.{
        "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref\x00",
        pktline.FlushString,
    });
    defer allocator.free(header);

    var expected_list: std.ArrayList(u8) = .empty;
    defer expected_list.deinit(allocator);
    try expected_list.appendSlice(allocator, header);
    try expected_list.appendSlice(allocator, packfile_content);

    try expectEncode(allocator, &r, expected_list.items);
}

test "updreq_encode_test.TestPushOptions" {
    const allocator = testing.allocator;
    const hash1 = plumbing.newHash("1ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    const hash2 = plumbing.newHash("2ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    const name = ReferenceName.init("myref");

    var r = try updreq.newReferenceUpdateRequest(allocator);
    defer r.deinit();
    try r.capabilities.set(capability.PushOptions, &.{});
    try r.appendCommand(.{ .name = name, .old = hash1, .new = hash2 });
    try r.appendOption(.{ .key = "SomeKey", .value = "SomeValue" });
    try r.appendOption(.{ .key = "AnotherKey", .value = "AnotherValue" });

    const expected = try pktlines(allocator, &.{
        "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref\x00push-options",
        pktline.FlushString,
        "SomeKey=SomeValue",
        "AnotherKey=AnotherValue",
        pktline.FlushString,
    });
    defer allocator.free(expected);

    try expectEncode(allocator, &r, expected);
}

test "push options reject protocol control bytes" {
    const allocator = testing.allocator;
    var r = try updreq.newReferenceUpdateRequest(allocator);
    defer r.deinit();
    try r.capabilities.set(capability.PushOptions, &.{});
    try r.appendCommand(.{
        .name = ReferenceName.init("refs/heads/main"),
        .old = ZeroHash,
        .new = plumbing.newHash("2ecf0ef2c2dffb796033e5a02219af86ec6584e5"),
    });
    try r.appendOption(.{ .key = "ci", .value = "ok\nsmuggled" });

    var storage: [256]u8 = undefined;
    var w: Writer = .fixed(&storage);
    try testing.expectError(error.InvalidPushOption, r.encode(&w));
}

test "updreq_encode_test.TestPushAtomic" {
    const allocator = testing.allocator;
    const hash1 = plumbing.newHash("1ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    const hash2 = plumbing.newHash("2ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    const name = ReferenceName.init("myref");

    var r = try updreq.newReferenceUpdateRequest(allocator);
    defer r.deinit();
    try r.capabilities.set(capability.Atomic, &.{});
    try r.appendCommand(.{ .name = name, .old = hash1, .new = hash2 });

    const expected = try pktlines(allocator, &.{
        "1ecf0ef2c2dffb796033e5a02219af86ec6584e5 2ecf0ef2c2dffb796033e5a02219af86ec6584e5 myref\x00atomic",
        pktline.FlushString,
    });
    defer allocator.free(expected);

    try expectEncode(allocator, &r, expected);
}
