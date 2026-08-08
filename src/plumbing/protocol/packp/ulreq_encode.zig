//! Upload-request encoder (go-git `plumbing/protocol/packp/ulreq_encode.go`).
//!
//! Encodes wants (sorted; first want carries capabilities), shallows, deepen
//! variants, filter, then flush-pkt. Pin: go-git v5.19.2.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const plumbing = @import("plumbing");
const pktline = @import("pktline");
const capability = @import("capability");
const filter_mod = @import("filter.zig");

const ulreq = @import("ulreq.zig");
const UploadRequest = ulreq.UploadRequest;
const Hash = ulreq.Hash;

/// go-git `(*UploadRequest).Encode` / `ulReqEncoder.Encode`.
pub fn encode(req: *UploadRequest, w: *Writer) !void {
    if (req.wants.items.len == 0) return ulreq.Error.EmptyWants;

    ulreq.hashesSort(req.wants.items);

    var pe = pktline.Encoder.init(w);

    // first want (+ optional capabilities)
    {
        var hex: [plumbing.MaxHexSize]u8 = undefined;
        const h = req.wants.items[0].string(&hex);
        if (req.capabilities.isEmpty()) {
            try pe.encodef("want {s}\n", .{h});
        } else {
            const caps = try req.capabilities.string(req.allocator);
            defer req.allocator.free(caps);
            try pe.encodef("want {s} {s}\n", .{ h, caps });
        }
    }

    // additional wants (dedupe consecutive after sort)
    {
        var last = req.wants.items[0];
        for (req.wants.items[1..]) |want| {
            if (last.eql(want)) continue;
            var hex: [plumbing.MaxHexSize]u8 = undefined;
            const h = want.string(&hex);
            try pe.encodef("want {s}\n", .{h});
            last = want;
        }
    }

    // shallows
    ulreq.hashesSort(req.shallows.items);
    {
        var last: Hash = plumbing.ZeroHash;
        var have_last = false;
        for (req.shallows.items) |s| {
            if (have_last and last.eql(s)) continue;
            var hex: [plumbing.MaxHexSize]u8 = undefined;
            const h = s.string(&hex);
            try pe.encodef("shallow {s}\n", .{h});
            last = s;
            have_last = true;
        }
    }

    // depth
    switch (req.depth) {
        .commits => |n| {
            if (n != 0) {
                try pe.encodef("deepen {d}\n", .{n});
            }
        },
        .since => |secs| {
            // go-git always encodes DepthSince (UTC Unix seconds).
            try pe.encodef("deepen-since {d}\n", .{secs});
        },
        .reference => |ref| {
            try pe.encodef("deepen-not {s}\n", .{ref});
        },
    }

    // filter
    if (req.filter.len != 0) {
        try pe.encodef("filter {s}\n", .{req.filter});
    }

    try pe.flush();
}

// ---------------------------------------------------------------------------
// Tests — port of ulreq_encode_test.go
// ---------------------------------------------------------------------------

fn encodeToSlice(allocator: Allocator, req: *UploadRequest) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try encode(req, &aw.writer);
    return try allocator.dupe(u8, aw.written());
}

fn pktlinePayloads(allocator: Allocator, payloads: []const []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var pe = pktline.Encoder.init(&aw.writer);
    try pe.encodeString(payloads);
    return try allocator.dupe(u8, aw.written());
}

fn expectEncode(allocator: Allocator, req: *UploadRequest, expected_payloads: []const []const u8) !void {
    const obtained = try encodeToSlice(allocator, req);
    defer allocator.free(obtained);
    const expected = try pktlinePayloads(allocator, expected_payloads);
    defer allocator.free(expected);
    try testing.expectEqualSlices(u8, expected, obtained);
}

test "encode empty wants fails" {
    const gpa = testing.allocator;
    var ur = UploadRequest.init(gpa);
    defer ur.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try testing.expectError(error.EmptyWants, encode(&ur, &aw.writer));
}

test "encode one want" {
    const gpa = testing.allocator;
    var ur = UploadRequest.init(gpa);
    defer ur.deinit();
    try ur.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    try expectEncode(gpa, &ur, &.{
        "want 1111111111111111111111111111111111111111\n",
        pktline.FlushString,
    });
}

test "encode one want with capabilities" {
    const gpa = testing.allocator;
    var ur = UploadRequest.init(gpa);
    defer ur.deinit();
    try ur.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    try ur.capabilities.add(capability.MultiACK, &.{});
    try ur.capabilities.add(capability.OFSDelta, &.{});
    try ur.capabilities.add(capability.Sideband, &.{});
    try ur.capabilities.add(capability.SymRef, &.{"HEAD:/refs/heads/master"});
    try ur.capabilities.add(capability.ThinPack, &.{});

    try expectEncode(gpa, &ur, &.{
        "want 1111111111111111111111111111111111111111 multi_ack ofs-delta side-band symref=HEAD:/refs/heads/master thin-pack\n",
        pktline.FlushString,
    });
}

test "encode wants sorted" {
    const gpa = testing.allocator;
    var ur = UploadRequest.init(gpa);
    defer ur.deinit();
    try ur.wants.append(gpa, plumbing.newHash("4444444444444444444444444444444444444444"));
    try ur.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    try ur.wants.append(gpa, plumbing.newHash("3333333333333333333333333333333333333333"));
    try ur.wants.append(gpa, plumbing.newHash("2222222222222222222222222222222222222222"));
    try ur.wants.append(gpa, plumbing.newHash("5555555555555555555555555555555555555555"));

    try expectEncode(gpa, &ur, &.{
        "want 1111111111111111111111111111111111111111\n",
        "want 2222222222222222222222222222222222222222\n",
        "want 3333333333333333333333333333333333333333\n",
        "want 4444444444444444444444444444444444444444\n",
        "want 5555555555555555555555555555555555555555\n",
        pktline.FlushString,
    });
}

test "encode wants duplicates skipped" {
    const gpa = testing.allocator;
    var ur = UploadRequest.init(gpa);
    defer ur.deinit();
    try ur.wants.append(gpa, plumbing.newHash("4444444444444444444444444444444444444444"));
    try ur.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    try ur.wants.append(gpa, plumbing.newHash("3333333333333333333333333333333333333333"));
    try ur.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    try ur.wants.append(gpa, plumbing.newHash("2222222222222222222222222222222222222222"));
    try ur.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));

    try expectEncode(gpa, &ur, &.{
        "want 1111111111111111111111111111111111111111\n",
        "want 2222222222222222222222222222222222222222\n",
        "want 3333333333333333333333333333333333333333\n",
        "want 4444444444444444444444444444444444444444\n",
        pktline.FlushString,
    });
}

test "encode shallow" {
    const gpa = testing.allocator;
    var ur = UploadRequest.init(gpa);
    defer ur.deinit();
    try ur.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    try ur.capabilities.add(capability.MultiACK, &.{});
    try ur.shallows.append(gpa, plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));

    try expectEncode(gpa, &ur, &.{
        "want 1111111111111111111111111111111111111111 multi_ack\n",
        "shallow aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
        pktline.FlushString,
    });
}

test "encode many shallows sorted" {
    const gpa = testing.allocator;
    var ur = UploadRequest.init(gpa);
    defer ur.deinit();
    try ur.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    try ur.capabilities.add(capability.MultiACK, &.{});
    try ur.shallows.append(gpa, plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"));
    try ur.shallows.append(gpa, plumbing.newHash("dddddddddddddddddddddddddddddddddddddddd"));
    try ur.shallows.append(gpa, plumbing.newHash("cccccccccccccccccccccccccccccccccccccccc"));
    try ur.shallows.append(gpa, plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));

    try expectEncode(gpa, &ur, &.{
        "want 1111111111111111111111111111111111111111 multi_ack\n",
        "shallow aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
        "shallow bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n",
        "shallow cccccccccccccccccccccccccccccccccccccccc\n",
        "shallow dddddddddddddddddddddddddddddddddddddddd\n",
        pktline.FlushString,
    });
}

test "encode shallows duplicates skipped" {
    const gpa = testing.allocator;
    var ur = UploadRequest.init(gpa);
    defer ur.deinit();
    try ur.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    try ur.capabilities.add(capability.MultiACK, &.{});
    try ur.shallows.append(gpa, plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"));
    try ur.shallows.append(gpa, plumbing.newHash("cccccccccccccccccccccccccccccccccccccccc"));
    try ur.shallows.append(gpa, plumbing.newHash("cccccccccccccccccccccccccccccccccccccccc"));
    try ur.shallows.append(gpa, plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));

    try expectEncode(gpa, &ur, &.{
        "want 1111111111111111111111111111111111111111 multi_ack\n",
        "shallow aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
        "shallow bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n",
        "shallow cccccccccccccccccccccccccccccccccccccccc\n",
        pktline.FlushString,
    });
}

test "encode DepthCommits" {
    const gpa = testing.allocator;
    var ur = UploadRequest.init(gpa);
    defer ur.deinit();
    try ur.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    ur.depth = .{ .commits = 1234 };

    try expectEncode(gpa, &ur, &.{
        "want 1111111111111111111111111111111111111111\n",
        "deepen 1234\n",
        pktline.FlushString,
    });
}

test "encode DepthSince UTC" {
    const gpa = testing.allocator;
    var ur = UploadRequest.init(gpa);
    defer ur.deinit();
    try ur.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    // 2015-01-02 03:04:05 UTC
    ur.depth = .{ .since = 1420167845 };

    try expectEncode(gpa, &ur, &.{
        "want 1111111111111111111111111111111111111111\n",
        "deepen-since 1420167845\n",
        pktline.FlushString,
    });
}

test "encode DepthReference" {
    const gpa = testing.allocator;
    var ur = UploadRequest.init(gpa);
    defer ur.deinit();
    try ur.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    ur.depth = .{ .reference = "refs/heads/feature-foo" };

    try expectEncode(gpa, &ur, &.{
        "want 1111111111111111111111111111111111111111\n",
        "deepen-not refs/heads/feature-foo\n",
        pktline.FlushString,
    });
}

test "encode filter" {
    const gpa = testing.allocator;
    var ur = UploadRequest.init(gpa);
    defer ur.deinit();
    try ur.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    ur.filter = try filter_mod.filterTreeDepth(gpa, 0);
    ur.owns_filter = true;

    try expectEncode(gpa, &ur, &.{
        "want 1111111111111111111111111111111111111111\n",
        "filter tree:0\n",
        pktline.FlushString,
    });
}

test "encode all fields" {
    const gpa = testing.allocator;
    var ur = UploadRequest.init(gpa);
    defer ur.deinit();
    try ur.wants.append(gpa, plumbing.newHash("4444444444444444444444444444444444444444"));
    try ur.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    try ur.wants.append(gpa, plumbing.newHash("3333333333333333333333333333333333333333"));
    try ur.wants.append(gpa, plumbing.newHash("2222222222222222222222222222222222222222"));
    try ur.wants.append(gpa, plumbing.newHash("5555555555555555555555555555555555555555"));

    try ur.capabilities.add(capability.MultiACK, &.{});
    try ur.capabilities.add(capability.OFSDelta, &.{});
    try ur.capabilities.add(capability.Sideband, &.{});
    try ur.capabilities.add(capability.SymRef, &.{"HEAD:/refs/heads/master"});
    try ur.capabilities.add(capability.ThinPack, &.{});

    try ur.shallows.append(gpa, plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"));
    try ur.shallows.append(gpa, plumbing.newHash("dddddddddddddddddddddddddddddddddddddddd"));
    try ur.shallows.append(gpa, plumbing.newHash("cccccccccccccccccccccccccccccccccccccccc"));
    try ur.shallows.append(gpa, plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));

    ur.depth = .{ .since = 1420167845 };

    try expectEncode(gpa, &ur, &.{
        "want 1111111111111111111111111111111111111111 multi_ack ofs-delta side-band symref=HEAD:/refs/heads/master thin-pack\n",
        "want 2222222222222222222222222222222222222222\n",
        "want 3333333333333333333333333333333333333333\n",
        "want 4444444444444444444444444444444444444444\n",
        "want 5555555555555555555555555555555555555555\n",
        "shallow aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
        "shallow bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n",
        "shallow cccccccccccccccccccccccccccccccccccccccc\n",
        "shallow dddddddddddddddddddddddddddddddddddddddd\n",
        "deepen-since 1420167845\n",
        pktline.FlushString,
    });
}
