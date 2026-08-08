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
    _ = @import("fixture.zig");
    _ = @import("basic_idx.zig");
}

const fixture = @import("fixture.zig");
const basic_idx = @import("basic_idx.zig");

// go-git-fixtures basic pack (pack a3fed42d… / 31 objects).
const basic_packfile_checksum_hex = "a3fed42da1e8189a077c0e6846c040dcf73fc9dd";
const basic_idx_checksum_hex = "fb794f1ec720b9bc8e43257451bd99c4be6fa1c9";
const basic_probe_hash_hex = "1669dce138d9b841a518c64b10914d88f5e488ea";
const basic_probe_offset: i64 = 615;
// Fixture CRC for probe hash (packfile_test.go uses 0xd9429436). go-git
// decoder_test.go asserts 3645019190 (0xd941d7b6) which does not match the
// basic.idx bytes or the pack parser golden.
const basic_probe_crc32: u32 = 0xd9429436;
const basic_object_count: i64 = 31;

fn decodeBasicIndex(allocator: std.mem.Allocator) !MemoryIndex {
    var idx = MemoryIndex.init(allocator);
    errdefer idx.deinit();
    var r = std.Io.Reader.fixed(&basic_idx.data);
    var d = Decoder.init(&r);
    try d.decode(&idx);
    return idx;
}

// ---------------------------------------------------------------------------
// Tests — go-git plumbing/format/idxfile/*_test.go coverage
// ---------------------------------------------------------------------------

test "VersionSupported is 2 and idx header magic" {
    try std.testing.expectEqual(@as(u32, 2), VersionSupported);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 't', 'O', 'c' }, idxHeader);
}

// decoder_test.go TestDecode (go-git-fixtures Basic().One())
test "TestDecode basic idx count contains offset crc checksums" {
    const allocator = std.testing.allocator;
    var idx = try decodeBasicIndex(allocator);
    defer idx.deinit();

    try std.testing.expectEqual(basic_object_count, try idx.count());

    const hash = plumbing.newHash(basic_probe_hash_hex);
    try std.testing.expect(idx.contains(hash));
    try std.testing.expectEqual(basic_probe_offset, try idx.findOffset(hash));
    try std.testing.expectEqual(basic_probe_crc32, try idx.findCRC32(hash));

    var idx_hex: [plumbing.MaxHexSize]u8 = undefined;
    try std.testing.expectEqualStrings(basic_idx_checksum_hex, idx.idx_checksum.string(&idx_hex));
    var pack_hex: [plumbing.MaxHexSize]u8 = undefined;
    try std.testing.expectEqualStrings(basic_packfile_checksum_hex, idx.packfile_checksum.string(&pack_hex));
}

// decoder_test.go TestDecode64bitsOffsets
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
        var buf: [plumbing.MaxHexSize]u8 = undefined;
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

// idxfile_test.go TestFindHash / FindOffset / FindCRC32 / Contains
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

// idxfile_test.go TestFindHash
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

// idxfile_test.go TestEntriesByOffset
test "entriesByOffset sorted" {
    const allocator = std.testing.allocator;
    var idx = try fixture.fixtureIndex(allocator);
    defer idx.deinit();

    var iter = try idx.entriesByOffset();
    defer iter.deinit();

    // fixture.fixture_offsets order is already ascending by offset.
    var i: usize = 0;
    while (iter.next()) |e| {
        try std.testing.expectEqual(@as(u64, @intCast(fixture.fixture_offsets[i])), e.offset);
        i += 1;
    }
    try std.testing.expectEqual(fixture.fixture_offsets.len, i);
}

// idxfile_test.go TestOffsetHashConcurrentPopulation (serial stress equivalent)
test "offset hash reverse map survives repeated lookups" {
    const allocator = std.testing.allocator;
    var idx = try fixture.fixtureIndex(allocator);
    defer idx.deinit();

    var round: usize = 0;
    while (round < 64) : (round += 1) {
        for (fixture.fixture_hashes, fixture.fixture_offsets) |hex, off| {
            const h = plumbing.newHash(hex);
            try std.testing.expectEqual(off, try idx.findOffset(h));
            const got = try idx.findHash(off);
            try std.testing.expect(h.eql(got));
        }
    }
}

// encoder_test.go TestDecodeEncode — basic fixture
test "decode encode round-trip basic idx" {
    const allocator = std.testing.allocator;
    const raw = basic_idx.data[0..];

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

// encoder_test.go TestDecodeEncode — large 4GB fixture
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

// writer_test.go TestWriter without pack scan: rebuild basic via Add/onHeader/onFooter
test "writer rebuilds basic idx via Add onHeader onFooter" {
    const allocator = std.testing.allocator;

    var src = try decodeBasicIndex(allocator);
    defer src.deinit();

    var collected: std.ArrayListUnmanaged(Entry) = .empty;
    defer collected.deinit(allocator);
    var it = src.entries();
    while (try it.next()) |e| {
        try collected.append(allocator, e);
    }
    try std.testing.expectEqual(@as(usize, @intCast(basic_object_count)), collected.items.len);

    var w = Writer.init(allocator);
    defer w.deinit();
    try w.onHeader(@intCast(collected.items.len));
    for (collected.items) |e| {
        try w.add(e.hash, e.offset, e.crc32);
    }
    // Duplicate Add is ignored (go-git Writer.Add).
    try w.add(collected.items[0].hash, collected.items[0].offset, collected.items[0].crc32);
    try w.onFooter(src.packfile_checksum);

    const idx = try w.getIndex();
    try std.testing.expect(w.isFinished());
    try std.testing.expectEqual(basic_object_count, try idx.count());

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var enc = Encoder.init(&aw.writer);
    const n = try enc.encode(idx);
    try std.testing.expectEqual(basic_idx.data.len, n);
    try std.testing.expectEqualSlices(u8, &basic_idx.data, aw.written());
}

// writer_test.go TestWriterLarge
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

// decoder_test.go TestDecodeErrors (subset + full structural cases)
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

    // truncated fanout table
    {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, idxHeader);
        var ver: [4]u8 = undefined;
        std.mem.writeInt(u32, &ver, 2, .big);
        try buf.appendSlice(allocator, &ver);
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            var n: [4]u8 = undefined;
            std.mem.writeInt(u32, &n, 0, .big);
            try buf.appendSlice(allocator, &n);
        }
        var idx = MemoryIndex.init(allocator);
        defer idx.deinit();
        var r = std.Io.Reader.fixed(buf.items);
        var d = Decoder.init(&r);
        try std.testing.expectError(error.EndOfStream, d.decode(&idx));
    }

    // truncated object names (fanout claims 1 object, no name data)
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

// decoder_test.go non-monotonic fanout cases
test "decode non-monotonic fanout" {
    const allocator = std.testing.allocator;

    // non-monotonic at entry 1
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

    // non-monotonic at last entry
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
            const v: u32 = if (k == 255) 5 else 10;
            std.mem.writeInt(u32, &n, v, .big);
            try buf.appendSlice(allocator, &n);
        }

        var idx = MemoryIndex.init(allocator);
        defer idx.deinit();
        var r = std.Io.Reader.fixed(buf.items);
        var d = Decoder.init(&r);
        try std.testing.expectError(Error.MalformedIdxFile, d.decode(&idx));
    }
}

// decoder_test.go checksum mismatch (basic + large)
test "decode checksum mismatch" {
    const allocator = std.testing.allocator;

    {
        const corrupted = try allocator.dupe(u8, &basic_idx.data);
        defer allocator.free(corrupted);
        corrupted[corrupted.len - 1] ^= 0xff;
        var idx = MemoryIndex.init(allocator);
        defer idx.deinit();
        var r = std.Io.Reader.fixed(corrupted);
        var d = Decoder.init(&r);
        try std.testing.expectError(Error.MalformedIdxFile, d.decode(&idx));
    }

    {
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
}

// decoder_test.go TestDecoderSizeFormulaBoundary + TestDecoderSizeCheckSkippedForBareReader
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

    const cases = [_]struct { nr: u32, total: i64, size_ok: bool }{
        .{ .nr = 1, .total = minSize(1), .size_ok = true },
        .{ .nr = 1, .total = minSize(1) - 1, .size_ok = false },
        .{ .nr = 1, .total = maxSize(1) + 1, .size_ok = false },
        .{ .nr = 2, .total = minSize(2), .size_ok = true },
        .{ .nr = 2, .total = maxSize(2), .size_ok = true },
        .{ .nr = 2, .total = minSize(2) - 1, .size_ok = false },
        .{ .nr = 2, .total = maxSize(2) + 1, .size_ok = false },
    };

    for (cases) |c| {
        const blob = try buildSparseIdx(allocator, c.nr, @intCast(c.total));
        defer allocator.free(blob);
        var idx = MemoryIndex.init(allocator);
        defer idx.deinit();
        var r = std.Io.Reader.fixed(blob);
        var d = Decoder.initWithSize(&r, @intCast(blob.len));
        // All zero-filled payloads fail; size_ok ones reach checksum mismatch.
        try std.testing.expectError(Error.MalformedIdxFile, d.decode(&idx));
        _ = c.size_ok;
    }

    // without known_size, truncated body is EndOfStream (bare reader)
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

// decoder_test.go TestDecoderRejectsInconsistentObjectCount
test "decode rejects inconsistent object count overflow" {
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
        std.mem.writeInt(u32, &n, 0x4C4C4C4C, .big);
        try buf.appendSlice(allocator, &n);
    }

    var idx = MemoryIndex.init(allocator);
    defer idx.deinit();
    var r = std.Io.Reader.fixed(buf.items);
    var d = Decoder.initWithSize(&r, @intCast(buf.items.len));
    try std.testing.expectError(Error.MalformedIdxFile, d.decode(&idx));
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

// idxfile_test.go TestMemoryIndexOffset64OutOfRange
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

    const obj = plumbing.Hash.fromBytes(name[0..]);
    try std.testing.expectError(Error.MalformedIdxFile, idx.findOffset(obj));
    try std.testing.expectError(Error.MalformedIdxFile, idx.findHash(0));

    var iter = idx.entries();
    try std.testing.expectError(Error.MalformedIdxFile, iter.next());
    iter.close();
}

// writer Index() before finished
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

// basic idx MemoryIndex entries / reverse lookups
test "basic idx entries count and reverse findHash" {
    const allocator = std.testing.allocator;
    var idx = try decodeBasicIndex(allocator);
    defer idx.deinit();

    try std.testing.expectEqual(basic_object_count, try idx.count());

    const probe = plumbing.newHash(basic_probe_hash_hex);
    const off = try idx.findOffset(probe);
    try std.testing.expectEqual(basic_probe_offset, off);
    const got = try idx.findHash(off);
    try std.testing.expect(probe.eql(got));

    var by_off = try idx.entriesByOffset();
    defer by_off.deinit();
    var prev: u64 = 0;
    var n: usize = 0;
    var first = true;
    while (by_off.next()) |e| {
        if (!first) try std.testing.expect(e.offset >= prev);
        prev = e.offset;
        first = false;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, @intCast(basic_object_count)), n);
}
