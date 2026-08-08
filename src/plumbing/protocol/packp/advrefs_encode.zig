//! Encode advertised-refs (go-git `plumbing/protocol/packp/advrefs_encode.go`).
//!
//! Payloads end with a newline. Capabilities, references, and shallows are
//! written in alphabetical order, except peeled refs that follow their tip.

const std = @import("std");
const plumbing = @import("plumbing");
const pktline = @import("pktline");
const capability = @import("capability");
const common = @import("common.zig");
const advrefs_mod = @import("advrefs.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Hash = plumbing.Hash;
const AdvRefs = advrefs_mod.AdvRefs;
const testing = std.testing;

/// go-git `AdvRefs.Encode`.
pub fn encode(a: *const AdvRefs, w: *Writer) !void {
    var e = AdvRefsEncoder{
        .data = a,
        .pe = pktline.Encoder.init(w),
        .allocator = a.allocator,
    };
    try e.encode();
}

const AdvRefsEncoder = struct {
    data: *const AdvRefs,
    pe: pktline.Encoder,
    allocator: Allocator,
    first_ref_name: []const u8 = "",
    first_ref_hash: Hash = plumbing.ZeroHash,
    sorted_refs: [][]const u8 = &.{},
    sorted_refs_owned: ?[][]const u8 = null,

    fn encode(self: *AdvRefsEncoder) !void {
        defer self.freeSorted();
        try self.sortRefs();
        self.setFirstRef();
        try self.encodePrefix();
        try self.encodeFirstLine();
        try self.encodeRefs();
        try self.encodeShallow();
        try self.pe.flush();
    }

    fn freeSorted(self: *AdvRefsEncoder) void {
        if (self.sorted_refs_owned) |owned| {
            self.allocator.free(owned);
            self.sorted_refs_owned = null;
            self.sorted_refs = &.{};
        }
    }

    fn sortRefs(self: *AdvRefsEncoder) !void {
        const n = self.data.references.count();
        if (n == 0) return;

        const refs = try self.allocator.alloc([]const u8, n);
        errdefer self.allocator.free(refs);

        var i: usize = 0;
        var it = self.data.references.keyIterator();
        while (it.next()) |k| {
            refs[i] = k.*;
            i += 1;
        }
        std.mem.sort([]const u8, refs, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);

        self.sorted_refs_owned = refs;
        self.sorted_refs = refs;
    }

    fn setFirstRef(self: *AdvRefsEncoder) void {
        if (self.data.head) |h| {
            self.first_ref_name = common.head;
            self.first_ref_hash = h;
            return;
        }
        if (self.sorted_refs.len > 0) {
            const name = self.sorted_refs[0];
            self.first_ref_name = name;
            self.first_ref_hash = self.data.references.get(name).?;
        }
    }

    fn encodePrefix(self: *AdvRefsEncoder) !void {
        for (self.data.prefix.items) |p| {
            if (p.len == 0) {
                try self.pe.flush();
                continue;
            }
            try self.pe.encodef("{s}\n", .{p});
        }
    }

    fn encodeFirstLine(self: *AdvRefsEncoder) !void {
        const caps = try formatCaps(self.allocator, &self.data.capabilities);
        defer self.allocator.free(caps);

        var hash_buf: [plumbing.MaxHexSize]u8 = undefined;
        if (self.first_ref_name.len == 0) {
            const zh = plumbing.ZeroHash.string(&hash_buf);
            try self.pe.encodef("{s} {s}\x00{s}\n", .{ zh, common.no_head, caps });
        } else {
            const hs = self.first_ref_hash.string(&hash_buf);
            try self.pe.encodef("{s} {s}\x00{s}\n", .{ hs, self.first_ref_name, caps });
        }
    }

    fn encodeRefs(self: *AdvRefsEncoder) !void {
        for (self.sorted_refs) |r| {
            if (std.mem.eql(u8, r, self.first_ref_name)) continue;

            const hash = self.data.references.get(r).?;
            var hash_buf: [plumbing.MaxHexSize]u8 = undefined;
            const hs = hash.string(&hash_buf);
            try self.pe.encodef("{s} {s}\n", .{ hs, r });

            if (self.data.peeled.get(r)) |ph| {
                var pbuf: [plumbing.MaxHexSize]u8 = undefined;
                const ps = ph.string(&pbuf);
                try self.pe.encodef("{s} {s}{s}\n", .{ ps, r, common.peeled });
            }
        }
    }

    fn encodeShallow(self: *AdvRefsEncoder) !void {
        const sorted = try sortShallows(self.allocator, self.data.shallows.items);
        defer self.allocator.free(sorted);

        for (sorted) |hash| {
            var hash_buf: [plumbing.MaxHexSize]u8 = undefined;
            const hs = hash.string(&hash_buf);
            try self.pe.encodef("shallow {s}\n", .{hs});
        }
    }
};

fn formatCaps(allocator: Allocator, c: *const capability.List) ![]u8 {
    return try c.string(allocator);
}

fn sortShallows(allocator: Allocator, shallows: []const Hash) ![]Hash {
    const ret = try allocator.dupe(Hash, shallows);
    std.mem.sort(Hash, ret, {}, struct {
        fn less(_: void, a: Hash, b: Hash) bool {
            return std.mem.order(u8, &a.bytes, &b.bytes) == .lt;
        }
    }.less);
    return ret;
}

// ---------------------------------------------------------------------------
// Tests — go-git advrefs_encode_test.go (key cases)
// ---------------------------------------------------------------------------

fn testEncode(allocator: Allocator, input: *const AdvRefs, expected: []const u8) !void {
    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try encode(input, &aw.writer);
    try testing.expectEqualSlices(u8, expected, aw.written());
}

fn pktlines(allocator: Allocator, payloads: []const []const u8) ![]u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var e = pktline.Encoder.init(&aw.writer);
    try e.encodeString(payloads);
    return try aw.toOwnedSlice();
}

test "advrefs_encode.TestZeroValue" {
    const allocator = testing.allocator;
    var ar = AdvRefs.init(allocator);
    defer ar.deinit();

    const expected = try pktlines(allocator, &.{
        "0000000000000000000000000000000000000000 capabilities^{}\x00\n",
        pktline.FlushString,
    });
    defer allocator.free(expected);
    try testEncode(allocator, &ar, expected);
}

test "advrefs_encode.TestHead" {
    const allocator = testing.allocator;
    var ar = AdvRefs.init(allocator);
    defer ar.deinit();
    ar.head = plumbing.newHash("6ecf0ef2c2dffb796033e5a02219af86ec6584e5");

    const expected = try pktlines(allocator, &.{
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00\n",
        pktline.FlushString,
    });
    defer allocator.free(expected);
    try testEncode(allocator, &ar, expected);
}

test "advrefs_encode.TestCapsNoHead" {
    const allocator = testing.allocator;
    var ar = AdvRefs.init(allocator);
    defer ar.deinit();
    try ar.capabilities.add(capability.MultiACK, &.{});
    try ar.capabilities.add(capability.OFSDelta, &.{});
    try ar.capabilities.add(capability.SymRef, &.{"HEAD:/refs/heads/master"});

    const expected = try pktlines(allocator, &.{
        "0000000000000000000000000000000000000000 capabilities^{}\x00multi_ack ofs-delta symref=HEAD:/refs/heads/master\n",
        pktline.FlushString,
    });
    defer allocator.free(expected);
    try testEncode(allocator, &ar, expected);
}

test "advrefs_encode.TestCapsWithHead" {
    const allocator = testing.allocator;
    var ar = AdvRefs.init(allocator);
    defer ar.deinit();
    ar.head = plumbing.newHash("6ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    try ar.capabilities.add(capability.MultiACK, &.{});
    try ar.capabilities.add(capability.OFSDelta, &.{});
    try ar.capabilities.add(capability.SymRef, &.{"HEAD:/refs/heads/master"});

    const expected = try pktlines(allocator, &.{
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00multi_ack ofs-delta symref=HEAD:/refs/heads/master\n",
        pktline.FlushString,
    });
    defer allocator.free(expected);
    try testEncode(allocator, &ar, expected);
}

test "advrefs_encode.TestRefs" {
    const allocator = testing.allocator;
    var ar = AdvRefs.init(allocator);
    defer ar.deinit();

    try ar.putReference("refs/heads/master", plumbing.newHash("a6930aaee06755d1bdcfd943fbf614e4d92bb0c7"));
    try ar.putReference("refs/tags/v2.6.12-tree", plumbing.newHash("1111111111111111111111111111111111111111"));
    try ar.putReference("refs/tags/v2.7.13-tree", plumbing.newHash("3333333333333333333333333333333333333333"));
    try ar.putReference("refs/tags/v2.6.13-tree", plumbing.newHash("2222222222222222222222222222222222222222"));
    try ar.putReference("refs/tags/v2.6.11-tree", plumbing.newHash("5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c"));

    const expected = try pktlines(allocator, &.{
        "a6930aaee06755d1bdcfd943fbf614e4d92bb0c7 refs/heads/master\x00\n",
        "5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c refs/tags/v2.6.11-tree\n",
        "1111111111111111111111111111111111111111 refs/tags/v2.6.12-tree\n",
        "2222222222222222222222222222222222222222 refs/tags/v2.6.13-tree\n",
        "3333333333333333333333333333333333333333 refs/tags/v2.7.13-tree\n",
        pktline.FlushString,
    });
    defer allocator.free(expected);
    try testEncode(allocator, &ar, expected);
}

test "advrefs_encode.TestPeeled" {
    const allocator = testing.allocator;
    var ar = AdvRefs.init(allocator);
    defer ar.deinit();

    try ar.putReference("refs/heads/master", plumbing.newHash("a6930aaee06755d1bdcfd943fbf614e4d92bb0c7"));
    try ar.putReference("refs/tags/v2.6.12-tree", plumbing.newHash("1111111111111111111111111111111111111111"));
    try ar.putReference("refs/tags/v2.7.13-tree", plumbing.newHash("3333333333333333333333333333333333333333"));
    try ar.putReference("refs/tags/v2.6.13-tree", plumbing.newHash("2222222222222222222222222222222222222222"));
    try ar.putReference("refs/tags/v2.6.11-tree", plumbing.newHash("5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c"));
    try ar.putPeeled("refs/tags/v2.7.13-tree", plumbing.newHash("4444444444444444444444444444444444444444"));
    try ar.putPeeled("refs/tags/v2.6.12-tree", plumbing.newHash("5555555555555555555555555555555555555555"));

    const expected = try pktlines(allocator, &.{
        "a6930aaee06755d1bdcfd943fbf614e4d92bb0c7 refs/heads/master\x00\n",
        "5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c refs/tags/v2.6.11-tree\n",
        "1111111111111111111111111111111111111111 refs/tags/v2.6.12-tree\n",
        "5555555555555555555555555555555555555555 refs/tags/v2.6.12-tree^{}\n",
        "2222222222222222222222222222222222222222 refs/tags/v2.6.13-tree\n",
        "3333333333333333333333333333333333333333 refs/tags/v2.7.13-tree\n",
        "4444444444444444444444444444444444444444 refs/tags/v2.7.13-tree^{}\n",
        pktline.FlushString,
    });
    defer allocator.free(expected);
    try testEncode(allocator, &ar, expected);
}

test "advrefs_encode.TestShallow" {
    const allocator = testing.allocator;
    var ar = AdvRefs.init(allocator);
    defer ar.deinit();

    try ar.appendShallow(plumbing.newHash("1111111111111111111111111111111111111111"));
    try ar.appendShallow(plumbing.newHash("4444444444444444444444444444444444444444"));
    try ar.appendShallow(plumbing.newHash("3333333333333333333333333333333333333333"));
    try ar.appendShallow(plumbing.newHash("2222222222222222222222222222222222222222"));

    const expected = try pktlines(allocator, &.{
        "0000000000000000000000000000000000000000 capabilities^{}\x00\n",
        "shallow 1111111111111111111111111111111111111111\n",
        "shallow 2222222222222222222222222222222222222222\n",
        "shallow 3333333333333333333333333333333333333333\n",
        "shallow 4444444444444444444444444444444444444444\n",
        pktline.FlushString,
    });
    defer allocator.free(expected);
    try testEncode(allocator, &ar, expected);
}

test "advrefs_encode.TestAll" {
    const allocator = testing.allocator;
    var ar = AdvRefs.init(allocator);
    defer ar.deinit();

    ar.head = plumbing.newHash("6ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    try ar.capabilities.add(capability.MultiACK, &.{});
    try ar.capabilities.add(capability.OFSDelta, &.{});
    try ar.capabilities.add(capability.SymRef, &.{"HEAD:/refs/heads/master"});

    try ar.putReference("refs/heads/master", plumbing.newHash("a6930aaee06755d1bdcfd943fbf614e4d92bb0c7"));
    try ar.putReference("refs/tags/v2.6.12-tree", plumbing.newHash("1111111111111111111111111111111111111111"));
    try ar.putReference("refs/tags/v2.7.13-tree", plumbing.newHash("3333333333333333333333333333333333333333"));
    try ar.putReference("refs/tags/v2.6.13-tree", plumbing.newHash("2222222222222222222222222222222222222222"));
    try ar.putReference("refs/tags/v2.6.11-tree", plumbing.newHash("5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c"));
    try ar.putPeeled("refs/tags/v2.7.13-tree", plumbing.newHash("4444444444444444444444444444444444444444"));
    try ar.putPeeled("refs/tags/v2.6.12-tree", plumbing.newHash("5555555555555555555555555555555555555555"));
    try ar.appendShallow(plumbing.newHash("1111111111111111111111111111111111111111"));
    try ar.appendShallow(plumbing.newHash("4444444444444444444444444444444444444444"));
    try ar.appendShallow(plumbing.newHash("3333333333333333333333333333333333333333"));
    try ar.appendShallow(plumbing.newHash("2222222222222222222222222222222222222222"));

    const expected = try pktlines(allocator, &.{
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5 HEAD\x00multi_ack ofs-delta symref=HEAD:/refs/heads/master\n",
        "a6930aaee06755d1bdcfd943fbf614e4d92bb0c7 refs/heads/master\n",
        "5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c refs/tags/v2.6.11-tree\n",
        "1111111111111111111111111111111111111111 refs/tags/v2.6.12-tree\n",
        "5555555555555555555555555555555555555555 refs/tags/v2.6.12-tree^{}\n",
        "2222222222222222222222222222222222222222 refs/tags/v2.6.13-tree\n",
        "3333333333333333333333333333333333333333 refs/tags/v2.7.13-tree\n",
        "4444444444444444444444444444444444444444 refs/tags/v2.7.13-tree^{}\n",
        "shallow 1111111111111111111111111111111111111111\n",
        "shallow 2222222222222222222222222222222222222222\n",
        "shallow 3333333333333333333333333333333333333333\n",
        "shallow 4444444444444444444444444444444444444444\n",
        pktline.FlushString,
    });
    defer allocator.free(expected);
    try testEncode(allocator, &ar, expected);
}

test "advrefs_encode.TestErrorTooLong" {
    const allocator = testing.allocator;
    var ar = AdvRefs.init(allocator);
    defer ar.deinit();

    const long_name = try allocator.alloc(u8, pktline.MaxPayloadSize);
    defer allocator.free(long_name);
    @memset(long_name, 'a');
    try ar.putReference(long_name, plumbing.newHash("a6930aaee06755d1bdcfd943fbf614e4d92bb0c7"));

    var aw: Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try testing.expectError(error.PayloadTooLong, encode(&ar, &aw.writer));
}
