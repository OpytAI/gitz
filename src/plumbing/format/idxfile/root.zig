//! plumbing/format/idxfile — packfile idx v2 encode/decode.
//!
//! Port of go-git v5.19.2 `plumbing/format/idxfile`.

const std = @import("std");
const plumbing = @import("plumbing");
const hash_pkg = @import("hash");

const idxfile_mod = @import("idxfile.zig");
const decoder_mod = @import("decoder.zig");
const encoder_mod = @import("encoder.zig");
const writer_mod = @import("writer.zig");

pub const VersionSupported = idxfile_mod.VersionSupported;
pub const idxHeader = idxfile_mod.idxHeader;
pub const fanout = idxfile_mod.fanout;
pub const objectIdLength = idxfile_mod.objectIdLength;
pub const noMapping = idxfile_mod.noMapping;

pub const Error = idxfile_mod.Error;
pub const Entry = idxfile_mod.Entry;
pub const MemoryIndex = idxfile_mod.MemoryIndex;
pub const EntryIterator = idxfile_mod.EntryIterator;
pub const OffsetEntryIterator = idxfile_mod.OffsetEntryIterator;

pub const Decoder = decoder_mod.Decoder;
pub const Encoder = encoder_mod.Encoder;
pub const Writer = writer_mod.Writer;

test {
    _ = @import("idxfile.zig");
    _ = @import("decoder.zig");
    _ = @import("encoder.zig");
    _ = @import("writer.zig");
}

const fixture = @import("fixture.zig");

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------


test "VersionSupported is 2 and idx header magic" {
    try std.testing.expectEqual(@as(u32, 2), VersionSupported);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 't', 'O', 'c' }, idxHeader);
}

test "decode 64-bit offsets fixture" {
    const allocator = std.testing.allocator;
    var idx = try fixture.fixtureIndex(allocator);
    defer idx.deinit();

    const expected = [_]struct { hex: []const u8, offset: u64 }{
        .{ .hex = "303953e5aa461c203a324821bc1717f9b4fff895", .offset = 12 },
        .{ .hex = "5296768e3d9f661387ccbff18c4dea6c997fd78c", .offset = 142 },
        .{ .hex = "03fc8d58d44267274edef4585eaeeb445879d33f", .offset = 1601322837 },
        .{ .hex = "8f3ceb4ea4cb9e4a0f751795eb41c9a4f07be772", .offset = 2646996529 },
        .{ .hex = "e0d1d625010087f79c9e01ad9d8f95e1628dda02", .offset = 3452385606 },
        .{ .hex = "90eba326cdc4d1d61c5ad25224ccbf08731dd041", .offset = 3707047470 },
        .{ .hex = "bab53055add7bc35882758a922c54a874d6b1272", .offset = 5323223332 },
        .{ .hex = "1b8995f51987d8a449ca5ea4356595102dc2fbd4", .offset = 5894072943 },
        .{ .hex = "35858be9c6f5914cbe6768489c41eb6809a2bceb", .offset = 5924278919 },
    };

    try std.testing.expectEqual(@as(i64, expected.len), try idx.count());

    var iter = idx.entries();
    var n: usize = 0;
    while (try iter.next()) |e| {
        var found = false;
        var buf: [plumbing.HexSize]u8 = undefined;
        const hs = e.hash.string(&buf);
        for (expected) |ex| {
            if (std.mem.eql(u8, hs, ex.hex)) {
                try std.testing.expectEqual(ex.offset, e.offset);
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
        n += 1;
    }
    try std.testing.expectEqual(expected.len, n);
}

test "findOffset findCRC32 contains on fixture" {
    const allocator = std.testing.allocator;
    var idx = try fixture.fixtureIndex(allocator);
    defer idx.deinit();

    for (fixture.fixture_hashes, fixture.fixture_offsets) |hex, off| {
        const h = plumbing.newHash(hex);
        try std.testing.expect(idx.contains(h));
        try std.testing.expectEqual(off, try idx.findOffset(h));
        _ = try idx.findCRC32(h);
    }

    const missing = plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    try std.testing.expect(!idx.contains(missing));
    try std.testing.expectError(Error.ObjectNotFound, idx.findOffset(missing));
    try std.testing.expectError(Error.ObjectNotFound, idx.findCRC32(missing));
}

test "findHash reverse lookup" {
    const allocator = std.testing.allocator;
    var idx = try fixture.fixtureIndex(allocator);
    defer idx.deinit();

    for (fixture.fixture_hashes, fixture.fixture_offsets) |hex, off| {
        const want = plumbing.newHash(hex);
        const got = try idx.findHash(off);
        try std.testing.expect(want.eql(got));
    }
    try std.testing.expectError(Error.ObjectNotFound, idx.findHash(999999));
}

test "entriesByOffset sorted" {
    const allocator = std.testing.allocator;
    var idx = try fixture.fixtureIndex(allocator);
    defer idx.deinit();

    var iter = try idx.entriesByOffset();
    defer iter.deinit();

    // fixture.fixture_offsets is not sorted; sorted order by offset value:
    var sorted = fixture.fixture_offsets;
    std.mem.sort(i64, &sorted, {}, std.sort.asc(i64));

    var i: usize = 0;
    while (iter.next()) |e| {
        try std.testing.expectEqual(@as(u64, @intCast(sorted[i])), e.offset);
        i += 1;
    }
    try std.testing.expectEqual(sorted.len, i);
}

test "decode encode round-trip fixture" {
    const allocator = std.testing.allocator;
    const raw = try fixture.decodeFixtureLarge4gb(allocator);
    defer allocator.free(raw);

    var idx = MemoryIndex.init(allocator);
    defer idx.deinit();
    var r = std.Io.Reader.fixed(raw);
    var d = Decoder.init(&r);
    try d.decode(&idx);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var e = Encoder.init(&aw.writer);
    const n = try e.encode(&idx);
    try std.testing.expectEqual(raw.len, n);
    try std.testing.expectEqualSlices(u8, raw, aw.written());
}

test "writer builds large index matching fixture" {
    const allocator = std.testing.allocator;

    const entries = [_]struct { offset: i64, hash: []const u8, crc: u32 }{
        .{ .offset = 12, .hash = "303953e5aa461c203a324821bc1717f9b4fff895", .crc = 0xbc347c4c },
        .{ .offset = 142, .hash = "5296768e3d9f661387ccbff18c4dea6c997fd78c", .crc = 0xcdc22842 },
        .{ .offset = 1601322837, .hash = "03fc8d58d44267274edef4585eaeeb445879d33f", .crc = 0x929dfaaa },
        .{ .offset = 2646996529, .hash = "8f3ceb4ea4cb9e4a0f751795eb41c9a4f07be772", .crc = 0xa61def8a },
        .{ .offset = 3452385606, .hash = "e0d1d625010087f79c9e01ad9d8f95e1628dda02", .crc = 0x06bea180 },
        .{ .offset = 3707047470, .hash = "90eba326cdc4d1d61c5ad25224ccbf08731dd041", .crc = 0x7193f3ba },
        .{ .offset = 5323223332, .hash = "bab53055add7bc35882758a922c54a874d6b1272", .crc = 0xac269b8e },
        .{ .offset = 5894072943, .hash = "1b8995f51987d8a449ca5ea4356595102dc2fbd4", .crc = 0x2187c056 },
        .{ .offset = 5924278919, .hash = "35858be9c6f5914cbe6768489c41eb6809a2bceb", .crc = 0x9c89d9d2 },
    };
    const pack_checksum = plumbing.newHash("afabc2269205cf85da1bf7e2fdff42f73810f29b");

    var w = Writer.init(allocator);
    defer w.deinit();
    try w.onHeader(@intCast(entries.len));
    for (entries) |o| {
        try w.onInflatedObjectContent(plumbing.newHash(o.hash), o.offset, o.crc, &.{});
    }
    try w.onFooter(pack_checksum);

    const idx = try w.getIndex();
    try std.testing.expect(w.isFinished());
    try std.testing.expectEqual(@as(i64, entries.len), try idx.count());

    const expected_raw = try fixture.decodeFixtureLarge4gb(allocator);
    defer allocator.free(expected_raw);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var enc = Encoder.init(&aw.writer);
    const n = try enc.encode(idx);
    try std.testing.expectEqual(expected_raw.len, n);
    try std.testing.expectEqualSlices(u8, expected_raw, aw.written());
}

test "decode errors empty wrong magic truncated unsupported" {
    const allocator = std.testing.allocator;

    // empty
    {
        var idx = MemoryIndex.init(allocator);
        defer idx.deinit();
        var r = std.Io.Reader.fixed(&[_]u8{});
        var d = Decoder.init(&r);
        try std.testing.expectError(error.EndOfStream, d.decode(&idx));
    }

    // wrong magic
    {
        var idx = MemoryIndex.init(allocator);
        defer idx.deinit();
        var r = std.Io.Reader.fixed(&[_]u8{ 0, 0, 0, 0, 0, 0, 0, 2 });
        var d = Decoder.init(&r);
        try std.testing.expectError(Error.MalformedIdxFile, d.decode(&idx));
    }

    // truncated header
    {
        var idx = MemoryIndex.init(allocator);
        defer idx.deinit();
        var r = std.Io.Reader.fixed(&[_]u8{ 255, 't' });
        var d = Decoder.init(&r);
        try std.testing.expectError(error.EndOfStream, d.decode(&idx));
    }

    // unsupported version 1
    {
        var buf: [8]u8 = undefined;
        @memcpy(buf[0..4], idxHeader);
        std.mem.writeInt(u32, buf[4..8], 1, .big);
        var idx = MemoryIndex.init(allocator);
        defer idx.deinit();
        var r = std.Io.Reader.fixed(&buf);
        var d = Decoder.init(&r);
        try std.testing.expectError(Error.UnsupportedVersion, d.decode(&idx));
    }

    // unsupported version 3
    {
        var buf: [8]u8 = undefined;
        @memcpy(buf[0..4], idxHeader);
        std.mem.writeInt(u32, buf[4..8], 3, .big);
        var idx = MemoryIndex.init(allocator);
        defer idx.deinit();
        var r = std.Io.Reader.fixed(&buf);
        var d = Decoder.init(&r);
        try std.testing.expectError(Error.UnsupportedVersion, d.decode(&idx));
    }
}

test "decode non-monotonic fanout" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, idxHeader);
    var ver: [4]u8 = undefined;
    std.mem.writeInt(u32, &ver, 2, .big);
    try buf.appendSlice(allocator, &ver);

    var k: usize = 0;
    while (k < 256) : (k += 1) {
        var n: [4]u8 = undefined;
        const v: u32 = if (k == 0) 5 else if (k == 1) 3 else 5;
        std.mem.writeInt(u32, &n, v, .big);
        try buf.appendSlice(allocator, &n);
    }

    var idx = MemoryIndex.init(allocator);
    defer idx.deinit();
    var r = std.Io.Reader.fixed(buf.items);
    var d = Decoder.init(&r);
    try std.testing.expectError(Error.MalformedIdxFile, d.decode(&idx));
}

test "decode checksum mismatch" {
    const allocator = std.testing.allocator;
    const raw = try fixture.decodeFixtureLarge4gb(allocator);
    defer allocator.free(raw);
    const corrupted = try allocator.dupe(u8, raw);
    defer allocator.free(corrupted);
    corrupted[corrupted.len - 1] ^= 0xff;

    var idx = MemoryIndex.init(allocator);
    defer idx.deinit();
    var r = std.Io.Reader.fixed(corrupted);
    var d = Decoder.init(&r);
    try std.testing.expectError(Error.MalformedIdxFile, d.decode(&idx));
}

test "decode size formula with known_size" {
    const allocator = std.testing.allocator;
    const hashsz: i64 = 20;
    const header_and_fanout: i64 = 8 + 4 * 256;
    const minSize = struct {
        fn call(nr: i64) i64 {
            return header_and_fanout + nr * (hashsz + 8) + 2 * hashsz;
        }
    }.call;
    const maxSize = struct {
        fn call(nr: i64) i64 {
            var m = minSize(nr);
            if (nr > 0) m += (nr - 1) * 8;
            return m;
        }
    }.call;

    // nr=1, one byte below minSize → size error
    {
        const nr: u32 = 1;
        const total = minSize(1) - 1;
        const blob = try buildSparseIdx(allocator, nr, @intCast(total));
        defer allocator.free(blob);
        var idx = MemoryIndex.init(allocator);
        defer idx.deinit();
        var r = std.Io.Reader.fixed(blob);
        var d = Decoder.initWithSize(&r, @intCast(blob.len));
        try std.testing.expectError(Error.MalformedIdxFile, d.decode(&idx));
    }

    // nr=1 at minSize → size ok, then checksum mismatch on zero payload
    {
        const nr: u32 = 1;
        const total = minSize(1);
        const blob = try buildSparseIdx(allocator, nr, @intCast(total));
        defer allocator.free(blob);
        var idx = MemoryIndex.init(allocator);
        defer idx.deinit();
        var r = std.Io.Reader.fixed(blob);
        var d = Decoder.initWithSize(&r, @intCast(blob.len));
        try std.testing.expectError(Error.MalformedIdxFile, d.decode(&idx));
    }

    // nr=2 one byte above maxSize
    {
        const nr: u32 = 2;
        const total = maxSize(2) + 1;
        const blob = try buildSparseIdx(allocator, nr, @intCast(total));
        defer allocator.free(blob);
        var idx = MemoryIndex.init(allocator);
        defer idx.deinit();
        var r = std.Io.Reader.fixed(blob);
        var d = Decoder.initWithSize(&r, @intCast(blob.len));
        try std.testing.expectError(Error.MalformedIdxFile, d.decode(&idx));
    }

    // without known_size, truncated body is EndOfStream
    {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, idxHeader);
        var ver: [4]u8 = undefined;
        std.mem.writeInt(u32, &ver, 2, .big);
        try buf.appendSlice(allocator, &ver);
        var k: usize = 0;
        while (k < 256) : (k += 1) {
            var n: [4]u8 = undefined;
            std.mem.writeInt(u32, &n, 1, .big);
            try buf.appendSlice(allocator, &n);
        }
        var idx = MemoryIndex.init(allocator);
        defer idx.deinit();
        var r = std.Io.Reader.fixed(buf.items);
        var d = Decoder.init(&r);
        try std.testing.expectError(error.EndOfStream, d.decode(&idx));
    }
}

fn buildSparseIdx(allocator: std.mem.Allocator, nr: u32, total: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, idxHeader);
    var ver: [4]u8 = undefined;
    std.mem.writeInt(u32, &ver, 2, .big);
    try buf.appendSlice(allocator, &ver);
    var k: usize = 0;
    while (k < 256) : (k += 1) {
        var n: [4]u8 = undefined;
        std.mem.writeInt(u32, &n, nr, .big);
        try buf.appendSlice(allocator, &n);
    }
    try std.testing.expect(buf.items.len <= total);
    const pad = total - buf.items.len;
    try buf.ensureUnusedCapacity(allocator, pad);
    @memset(buf.unusedCapacitySlice()[0..pad], 0);
    buf.items.len += pad;
    return try buf.toOwnedSlice(allocator);
}

test "offset64 out of range on lookup" {
    const allocator = std.testing.allocator;
    const hash_size = plumbing.Size;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, idxHeader);
    {
        var ver: [4]u8 = undefined;
        std.mem.writeInt(u32, &ver, 2, .big);
        try buf.appendSlice(allocator, &ver);
    }
    // Fanout: one object, first byte 0x00
    {
        var k: usize = 0;
        while (k < 256) : (k += 1) {
            var n: [4]u8 = undefined;
            std.mem.writeInt(u32, &n, 1, .big);
            try buf.appendSlice(allocator, &n);
        }
    }
    var name = [_]u8{0} ** hash_size;
    name[hash_size - 1] = 0x01;
    try buf.appendSlice(allocator, &name);
    try buf.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 }); // CRC32
    // Offset32: MSB set, lower 31 bits = 5 → Offset64[40:48] OOB
    {
        var o: [4]u8 = undefined;
        std.mem.writeInt(u32, &o, 0x80000005, .big);
        try buf.appendSlice(allocator, &o);
    }
    {
        var o64: [8]u8 = undefined;
        std.mem.writeInt(u64, &o64, 0x12345678, .big);
        try buf.appendSlice(allocator, &o64);
    }
    {
        const zeros = [_]u8{0} ** hash_size;
        try buf.appendSlice(allocator, &zeros); // pack checksum
    }

    // idx checksum of content so far
    var h = hash_pkg.new(.sha1);
    h.update(buf.items);
    var sum: [hash_pkg.Size]u8 = undefined;
    h.final(&sum);
    try buf.appendSlice(allocator, &sum);

    var idx = MemoryIndex.init(allocator);
    defer idx.deinit();
    var r = std.Io.Reader.fixed(buf.items);
    var d = Decoder.init(&r);
    try d.decode(&idx);

    const obj = plumbing.Hash.fromBytes(name);
    try std.testing.expectError(Error.MalformedIdxFile, idx.findOffset(obj));
    try std.testing.expectError(Error.MalformedIdxFile, idx.findHash(0));

    var iter = idx.entries();
    try std.testing.expectError(Error.MalformedIdxFile, iter.next());
}

test "writer IndexNotFinished" {
    const allocator = std.testing.allocator;
    var w = Writer.init(allocator);
    defer w.deinit();
    try std.testing.expectError(Error.IndexNotFinished, w.getIndex());
}

test "writer rejects unfinished create via getIndex after partial adds" {
    const allocator = std.testing.allocator;
    var w = Writer.init(allocator);
    defer w.deinit();
    try w.onHeader(1);
    try w.add(plumbing.newHash("303953e5aa461c203a324821bc1717f9b4fff895"), 12, 1);
    try std.testing.expect(!w.isFinished());
    try std.testing.expectError(Error.IndexNotFinished, w.getIndex());
}
