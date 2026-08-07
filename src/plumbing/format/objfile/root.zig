//! Package objfile implements encoding and decoding of Git loose object files.
//!
//! Port of go-git v5.19.2 `plumbing/format/objfile`.
//!
//! A loose object is a zlib-compressed stream whose inflated payload is:
//! `type SP size NUL` followed by the object content.

const std = @import("std");

const error_mod = @import("error.zig");
const reader_mod = @import("reader.zig");
const writer_mod = @import("writer.zig");

pub const Error = error_mod.Error;
pub const Reader = reader_mod.Reader;
pub const Writer = writer_mod.Writer;

test {
    _ = reader_mod;
    _ = writer_mod;
}

// ---------------------------------------------------------------------------
// Shared fixtures (go-git common_test.go objfileFixtures)
// ---------------------------------------------------------------------------

const plumbing = @import("plumbing");
const sync = @import("utils/sync");

const Fixture = struct {
    hash_hex: []const u8,
    object_type: plumbing.ObjectType,
    /// Raw object content (not base64).
    content: []const u8,
    /// Base64 of the on-disk zlib objfile bytes.
    data_b64: []const u8,
};

const fixtures = [_]Fixture{
    .{
        .hash_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
        .object_type = .blob,
        .content = "",
        .data_b64 = "eAFLyslPUjBgAAAJsAHw",
    },
    .{
        .hash_hex = "a8a940627d132695a9769df883f85992f0ff4a43",
        .object_type = .blob,
        .content = "this is a test",
        .data_b64 = "eAFLyslPUjA0YSjJyCxWAKJEhZLU4hIAUDYHOg==",
    },
    .{
        .hash_hex = "4dc2174801ac4a3d36886210fd086fbe134cf7b2",
        .object_type = .blob,
        .content = "this\nis\n\n\na\nmultiline\n\ntest.\n",
        .data_b64 = "eAFLyslPUjCyZCjJyCzmAiIurkSu3NKcksyczLxULq6S1OISPS4A1I8LMQ==",
    },
    .{
        .hash_hex = "13e6f47dd57798bfdc728d91f5c6d7f40c5bb5fc",
        .object_type = .blob,
        .content = "this tests\r\nCRLF\r\nencoded files.\r\n",
        .data_b64 = "eAFLyslPUjA2YSjJyCxWKEktLinm5XIO8nHj5UrNS85PSU1RSMvMSS3W4+UCABp3DNE=",
    },
    .{
        .hash_hex = "72a7bc4667ab068e954172437b993d9fbaa137cb",
        .object_type = .blob,
        .content = "test@example.com",
        .data_b64 = "eAFLyslPUjA0YyhJLS5xSK1IzC3ISdVLzs8FAGVtCIA=",
    },
};

fn decodeB64(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    // go-git uses StdEncoding (padded). Pad short fixtures before decode.
    const pad_n = (4 - (s.len % 4)) % 4;
    var padded_buf: [256]u8 = undefined;
    const padded: []const u8 = if (pad_n == 0) s else blk: {
        if (s.len + pad_n > padded_buf.len) return error.OutOfMemory;
        @memcpy(padded_buf[0..s.len], s);
        @memset(padded_buf[s.len..][0..pad_n], '=');
        break :blk padded_buf[0 .. s.len + pad_n];
    };
    const dec = std.base64.standard.Decoder;
    const len = try dec.calcSizeForSlice(padded);
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    try dec.decode(buf, padded);
    return buf;
}

fn expectReadFixture(
    allocator: std.mem.Allocator,
    data: []const u8,
    want_hash: plumbing.Hash,
    want_type: plumbing.ObjectType,
    want_content: []const u8,
) !void {
    var src: std.Io.Reader = .fixed(data);
    var r = try Reader.open(allocator, &src);
    defer r.close();

    const hdr = try r.header();
    try std.testing.expect(hdr.t == want_type);
    try std.testing.expectEqual(@as(i64, @intCast(want_content.len)), hdr.size);

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(allocator);
    var tmp: [512]u8 = undefined;
    while (true) {
        const n = r.read(&tmp) catch |e| switch (e) {
            error.EndOfStream => break,
            else => |err| return err,
        };
        try got.appendSlice(allocator, tmp[0..n]);
    }
    try std.testing.expectEqualSlices(u8, want_content, got.items);
    try std.testing.expect(r.hash().eql(want_hash));
}

fn expectWriteRoundTrip(
    allocator: std.mem.Allocator,
    want_hash: plumbing.Hash,
    want_type: plumbing.ObjectType,
    content: []const u8,
) !void {
    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer aw.deinit();

    var w = try Writer.open(allocator, &aw.writer);
    try w.writeHeader(want_type, @intCast(content.len));
    if (content.len > 0) {
        const n = try w.write(content);
        try std.testing.expectEqual(content.len, n);
    }
    try std.testing.expect(w.hash().eql(want_hash));
    try w.close();

    const encoded = aw.writer.buffered();
    try expectReadFixture(allocator, encoded, want_hash, want_type, content);
}

test "read objfile fixtures" {
    const gpa = std.testing.allocator;
    for (fixtures) |fx| {
        const data = try decodeB64(gpa, fx.data_b64);
        defer gpa.free(data);
        const want_hash = plumbing.newHash(fx.hash_hex);
        try expectReadFixture(gpa, data, want_hash, fx.object_type, fx.content);
    }
}

test "write objfile fixtures round-trip" {
    const gpa = std.testing.allocator;
    defer sync.deinitPools(gpa);
    for (fixtures) |fx| {
        const want_hash = plumbing.newHash(fx.hash_hex);
        try expectWriteRoundTrip(gpa, want_hash, fx.object_type, fx.content);
    }
}

test "read empty objfile fails at NewReader" {
    const gpa = std.testing.allocator;
    var src: std.Io.Reader = .fixed(&[_]u8{});
    try std.testing.expectError(error.ZLib, Reader.open(gpa, &src));
}

test "read garbage fails at NewReader" {
    const gpa = std.testing.allocator;
    var src: std.Io.Reader = .fixed("!@#$RO!@NROSADfinq@o#irn@oirfn");
    try std.testing.expectError(error.ZLib, Reader.open(gpa, &src));
}

test "read corrupt zlib fails at NewReader or Header" {
    const gpa = std.testing.allocator;
    // go-git reader_test.go TestReadCorruptZLib — error before content is usable.
    const data = try decodeB64(gpa, "eAFLysaalPUjBgAAAJsAHw");
    defer gpa.free(data);
    var src: std.Io.Reader = .fixed(data);
    var r = Reader.open(gpa, &src) catch {
        // Eager zlib validation may fail at NewReader (Zig flate).
        return;
    };
    defer r.close();
    try std.testing.expect(std.meta.isError(r.header()));
}

test "read before header returns HeaderNotRead and ZeroHash" {
    const gpa = std.testing.allocator;
    const data = try decodeB64(gpa, fixtures[0].data_b64);
    defer gpa.free(data);
    var src: std.Io.Reader = .fixed(data);
    var r = try Reader.open(gpa, &src);
    defer r.close();

    var buf: [16]u8 = undefined;
    try std.testing.expectError(error.HeaderNotRead, r.read(&buf));
    try std.testing.expect(r.hash().isZero());
}

test "read after header error does not panic" {
    const gpa = std.testing.allocator;
    const data = try decodeB64(gpa, "eAFLysaalPUjBgAAAJsAHw");
    defer gpa.free(data);
    var src: std.Io.Reader = .fixed(data);
    var r = Reader.open(gpa, &src) catch {
        return;
    };
    defer r.close();

    _ = r.header() catch {};
    var buf: [16]u8 = undefined;
    // go-git: Read returns an error rather than accessing uninitialised state.
    const n = r.read(&buf);
    try std.testing.expect(std.meta.isError(n));
}

test "write overflow" {
    const gpa = std.testing.allocator;
    defer sync.deinitPools(gpa);

    var aw = try std.Io.Writer.Allocating.initCapacity(gpa, 4096);
    defer aw.deinit();

    var w = try Writer.open(gpa, &aw.writer);
    try w.writeHeader(.blob, 8);
    try std.testing.expectEqual(@as(usize, 4), try w.write("1234"));
    const pending_before = w.pending;
    try std.testing.expectEqual(@as(i64, 4), pending_before);
    try std.testing.expectError(error.Overflow, w.write("56789"));
    try std.testing.expectEqual(@as(i64, 0), w.pending);
    try w.close();
}

test "write header invalid type" {
    const gpa = std.testing.allocator;
    defer sync.deinitPools(gpa);

    var aw = try std.Io.Writer.Allocating.initCapacity(gpa, 4096);
    defer aw.deinit();

    var w = try Writer.open(gpa, &aw.writer);
    defer w.close() catch {};
    try std.testing.expectError(error.InvalidType, w.writeHeader(.invalid, 8));
}

test "write header negative size" {
    const gpa = std.testing.allocator;
    defer sync.deinitPools(gpa);

    var aw = try std.Io.Writer.Allocating.initCapacity(gpa, 4096);
    defer aw.deinit();

    var w = try Writer.open(gpa, &aw.writer);
    defer w.close() catch {};
    try std.testing.expectError(error.NegativeSize, w.writeHeader(.blob, -1));
    try std.testing.expectError(error.NegativeSize, w.writeHeader(.blob, -1651860));
}

test "write empty blob matches known hash" {
    const gpa = std.testing.allocator;
    defer sync.deinitPools(gpa);
    const want = plumbing.newHash("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    try expectWriteRoundTrip(gpa, want, .blob, "");
}
