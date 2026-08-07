//! Shallow-update message (shallow / unshallow lines).
//! Port of go-git `plumbing/protocol/packp/shallowupd.go` (v5.19.2).

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

const shallow_line_len: usize = 48;
const unshallow_line_len: usize = 50;

/// Shallow-update message (go-git `ShallowUpdate`).
///
/// Zero-value is allowed (`={}`); call `init` before encode/decode that
/// allocate into the lists.
pub const ShallowUpdate = struct {
    allocator: Allocator = undefined,
    shallows: std.ArrayListUnmanaged(Hash) = .empty,
    unshallows: std.ArrayListUnmanaged(Hash) = .empty,

    pub fn init(allocator: Allocator) ShallowUpdate {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ShallowUpdate) void {
        self.shallows.deinit(self.allocator);
        self.unshallows.deinit(self.allocator);
        self.* = undefined;
    }

    /// Decodes shallow/unshallow pkt-lines until flush (go-git `Decode`).
    pub fn decode(self: *ShallowUpdate, r: *Reader) (common.Error || pktline.Error || Reader.Error || Allocator.Error)!void {
        var sc = pktline.Scanner.init(r);
        while (sc.scan()) {
            const raw = sc.bytes();
            const line = std.mem.trim(u8, raw, " \t\r\n\x0b\x0c");

            if (std.mem.startsWith(u8, line, common.shallow)) {
                const h = try self.decodeLine(line, common.shallow, shallow_line_len);
                try self.shallows.append(self.allocator, h);
            } else if (std.mem.startsWith(u8, line, common.unshallow)) {
                const h = try self.decodeLine(line, common.unshallow, unshallow_line_len);
                try self.unshallows.append(self.allocator, h);
            } else if (std.mem.eql(u8, line, pktline.Flush) or line.len == 0) {
                // Flush payload is empty; also treat trimmed empty as flush.
                return;
            }
        }
        if (sc.err()) |e| return e;
    }

    fn decodeLine(_: *const ShallowUpdate, line: []const u8, prefix: []const u8, exp_len: usize) common.Error!Hash {
        _ = prefix;
        if (line.len != exp_len) return error.MalformedShallowLine;
        const raw = line[exp_len - 40 .. exp_len];
        return plumbing.newHash(raw);
    }

    /// Encodes shallow then unshallow lines and a flush (go-git `Encode`).
    pub fn encode(self: *const ShallowUpdate, w: *Writer) (pktline.Error || Writer.Error)!void {
        var enc = pktline.Encoder.init(w);
        var hex: [HexSize]u8 = undefined;
        for (self.shallows.items) |h| {
            try enc.encodef("{s}{s}\n", .{ common.shallow, h.string(&hex) });
        }
        for (self.unshallows.items) |h| {
            try enc.encodef("{s}{s}\n", .{ common.unshallow, h.string(&hex) });
        }
        try enc.flush();
    }
};

// ---------------------------------------------------------------------------
// Tests — shallowupd_test.go
// ---------------------------------------------------------------------------

test "decode with LF" {
    const wire = "0035shallow aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++
        "0035shallow bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" ++
        "0000";
    var r: Reader = .fixed(wire);
    var su = ShallowUpdate.init(testing.allocator);
    defer su.deinit();
    try su.decode(&r);
    try testing.expectEqual(@as(usize, 0), su.unshallows.items.len);
    try testing.expectEqual(@as(usize, 2), su.shallows.items.len);
    try testing.expect(su.shallows.items[0].eql(plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")));
    try testing.expect(su.shallows.items[1].eql(plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")));
}

test "decode without LF" {
    const wire = "0034shallow aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "0034shallow bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "0000";
    var r: Reader = .fixed(wire);
    var su = ShallowUpdate.init(testing.allocator);
    defer su.deinit();
    try su.decode(&r);
    try testing.expectEqual(@as(usize, 0), su.unshallows.items.len);
    try testing.expectEqual(@as(usize, 2), su.shallows.items.len);
    try testing.expect(su.shallows.items[0].eql(plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")));
    try testing.expect(su.shallows.items[1].eql(plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")));
}

test "decode unshallow" {
    const wire = "0036unshallow aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "0036unshallow bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "0000";
    var r: Reader = .fixed(wire);
    var su = ShallowUpdate.init(testing.allocator);
    defer su.deinit();
    try su.decode(&r);
    try testing.expectEqual(@as(usize, 0), su.shallows.items.len);
    try testing.expectEqual(@as(usize, 2), su.unshallows.items.len);
    try testing.expect(su.unshallows.items[0].eql(plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")));
    try testing.expect(su.unshallows.items[1].eql(plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")));
}

test "decode malformed" {
    const wire = "0035unshallow aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "0000";
    var r: Reader = .fixed(wire);
    var su = ShallowUpdate.init(testing.allocator);
    defer su.deinit();
    try testing.expectError(error.MalformedShallowLine, su.decode(&r));
}

test "encode empty" {
    var storage: [8]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var su = ShallowUpdate.init(testing.allocator);
    defer su.deinit();
    try su.encode(&w);
    try testing.expectEqualStrings("0000", w.buffered());
}

test "encode shallow and unshallow" {
    var storage: [256]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var su = ShallowUpdate.init(testing.allocator);
    defer su.deinit();
    try su.shallows.append(testing.allocator, plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try su.shallows.append(testing.allocator, plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"));
    try su.unshallows.append(testing.allocator, plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try su.unshallows.append(testing.allocator, plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"));
    try su.encode(&w);
    const expected = "0035shallow aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++
        "0035shallow bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" ++
        "0037unshallow aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++
        "0037unshallow bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" ++
        "0000";
    try testing.expectEqualStrings(expected, w.buffered());
}

test "encode shallow only" {
    var storage: [128]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var su = ShallowUpdate.init(testing.allocator);
    defer su.deinit();
    try su.shallows.append(testing.allocator, plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try su.shallows.append(testing.allocator, plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"));
    try su.encode(&w);
    const expected = "0035shallow aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++
        "0035shallow bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" ++
        "0000";
    try testing.expectEqualStrings(expected, w.buffered());
}

test "encode unshallow only" {
    var storage: [128]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var su = ShallowUpdate.init(testing.allocator);
    defer su.deinit();
    try su.unshallows.append(testing.allocator, plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try su.unshallows.append(testing.allocator, plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"));
    try su.encode(&w);
    const expected = "0037unshallow aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++
        "0037unshallow bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" ++
        "0000";
    try testing.expectEqualStrings(expected, w.buffered());
}
