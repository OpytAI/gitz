//! Thin-pack / ObjectStore resolution tests.
//!
//! Covers go-git `ParserSuite.TestThinPack` behaviour:
//! - missing external bases → ReferenceDeltaNotFound or ObjectNotFound
//! - REF delta resolved against an ObjectStore base → success
//!
//! Wire into the package test root with:
//!   test { _ = @import("thin_pack_tests.zig"); }
//! and add this file + `thinpack_pack.zig` to packfile library/test `srcs`.

const std = @import("std");
const flate = std.compress.flate;
const Sha1 = std.crypto.hash.Sha1;

const plumbing = @import("plumbing");

const common = @import("common.zig");
const parser_mod = @import("parser.zig");
const scanner_mod = @import("scanner.zig");
const thinpack_pack = @import("thinpack_pack.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ObjectType = plumbing.ObjectType;
const Parser = parser_mod.Parser;
const ObjectStore = parser_mod.ObjectStore;
const Scanner = scanner_mod.Scanner;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a one-object thin pack: REF_DELTA → `base_hash` with zlib body `delta`.
fn buildThinRefDeltaPack(
    allocator: Allocator,
    base_hash: Hash,
    delta: []const u8,
) ![]u8 {
    // Compress the delta payload (zlib container).
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(allocator);
    {
        var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
        defer out.deinit();
        var window: [flate.max_window_len]u8 = undefined;
        var comp = try flate.Compress.init(&out.writer, &window, .zlib, .default);
        try comp.writer.writeAll(delta);
        try comp.finish();
        try compressed.appendSlice(allocator, out.writer.buffered());
    }

    const declared_size: i64 = @intCast(delta.len);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var hasher = Sha1.init(.{});
    const writeBoth = struct {
        fn go(b: *std.ArrayList(u8), h: *Sha1, a: Allocator, bytes: []const u8) !void {
            try b.appendSlice(a, bytes);
            h.update(bytes);
        }
    }.go;

    // PACK header: signature + version 2 + object count 1
    try writeBoth(&buf, &hasher, allocator, &common.signature);
    var u32buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &u32buf, common.VersionSupported, .big);
    try writeBoth(&buf, &hasher, allocator, &u32buf);
    std.mem.writeInt(u32, &u32buf, 1, .big);
    try writeBoth(&buf, &hasher, allocator, &u32buf);

    // Object header VLQ: type = REF_DELTA (7), size = delta.len
    const t: u8 = @intCast(@intFromEnum(ObjectType.ref_delta));
    var first: u8 = (t << common.first_length_bits) | @as(u8, @intCast(declared_size & common.mask_first_length));
    var sz = declared_size >> common.first_length_bits;
    var hdr_bytes: std.ArrayList(u8) = .empty;
    defer hdr_bytes.deinit(allocator);
    while (sz != 0) {
        try hdr_bytes.append(allocator, first | common.mask_continue);
        first = @intCast(sz & common.mask_length);
        sz >>= common.length_bits;
    }
    try hdr_bytes.append(allocator, first);
    try writeBoth(&buf, &hasher, allocator, hdr_bytes.items);

    // REF_DELTA base hash (20 bytes)
    try writeBoth(&buf, &hasher, allocator, base_hash.slice());

    // zlib body
    try writeBoth(&buf, &hasher, allocator, compressed.items);

    // Trailer SHA-1 of pack contents
    var trailer: [Sha1.digest_length]u8 = undefined;
    hasher.final(&trailer);
    try buf.appendSlice(allocator, &trailer);

    return try buf.toOwnedSlice(allocator);
}

/// Encode a minimal git delta: copy all of `base`, then insert `suffix`.
/// Target content = base ++ suffix. Returns encoded slice into `buf`.
fn encodeCopyThenInsertDelta(buf: *[64]u8, base: []const u8, suffix: []const u8) []const u8 {
    // LEB128 for sizes < 128 is a single byte.
    std.debug.assert(base.len < 128);
    std.debug.assert(suffix.len < 128);
    std.debug.assert(base.len + suffix.len < 128);

    var i: usize = 0;
    buf[i] = @intCast(base.len); // src size
    i += 1;
    buf[i] = @intCast(base.len + suffix.len); // target size
    i += 1;

    // Copy-from-src: size present (0x10), no offset bytes (offset 0).
    if (base.len > 0) {
        buf[i] = 0x80 | 0x10;
        i += 1;
        buf[i] = @intCast(base.len);
        i += 1;
    }

    // Insert suffix (copy-from-delta); cmd byte is the insert length.
    if (suffix.len > 0) {
        buf[i] = @intCast(suffix.len);
        i += 1;
        @memcpy(buf[i .. i + suffix.len], suffix);
        i += suffix.len;
    }

    return buf[0..i];
}

fn expectMissingBaseError(err: anyerror) !void {
    // go-git TestThinPack expects plumbing.ErrObjectNotFound from empty storage.
    // This port maps external-ref miss to ReferenceDeltaNotFound when storage
    // is set (see Parser.get); without storage it is also ReferenceDeltaNotFound.
    // Accept either name for cross-port parity.
    switch (err) {
        error.ReferenceDeltaNotFound, error.ObjectNotFound => {},
        else => return err,
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// go-git ParserSuite.TestThinPack first half: thin pack + empty storage fails.
test "thinpack fixture with empty ObjectStore fails missing base" {
    const allocator = std.testing.allocator;
    const pack = thinpack_pack.data();

    var store = ObjectStore.init(allocator);
    defer store.deinit();

    var sc = Scanner.initSeekable(pack);
    var parser = try Parser.initWithStorage(allocator, &sc, &store, &.{});
    defer parser.deinit();

    // go-git surfaces plumbing.ErrObjectNotFound from empty storage;
    // this port returns ReferenceDeltaNotFound for unresolved external refs.
    if (parser.parse()) |_| {
        try std.testing.expect(false);
    } else |err| {
        try expectMissingBaseError(err);
    }
}

// Seekable thin pack without storage cannot resolve external REF bases.
test "thinpack fixture without storage fails ReferenceDeltaNotFound" {
    const allocator = std.testing.allocator;
    const pack = thinpack_pack.data();

    var sc = Scanner.initSeekable(pack);
    var parser = try Parser.init(allocator, &sc, &.{});
    defer parser.deinit();

    try std.testing.expectError(error.ReferenceDeltaNotFound, parser.parse());
}

// Self-contained thin pack: base blob lives only in ObjectStore; pack is one REF delta.
test "synthetic thin pack REF delta resolves via ObjectStore" {
    const allocator = std.testing.allocator;

    const base_content = "hello";
    const suffix = "!";
    const target_content = "hello!";

    // 1. Seed ObjectStore with the external base blob.
    var store = ObjectStore.init(allocator);
    defer store.deinit();
    const base_hash = try store.putContent(.blob, base_content);

    // Sanity: base is present and hashes match plumbing.computeHash.
    const expected_base = plumbing.computeHash(.blob, base_content);
    try std.testing.expect(base_hash.eql(expected_base));
    const base_obj = try store.get(base_hash);
    try std.testing.expectEqualStrings(base_content, base_obj.readerBytes());

    // 2. Build a one-object thin pack (REF_DELTA → base_hash).
    var delta_storage: [64]u8 = undefined;
    const delta = encodeCopyThenInsertDelta(&delta_storage, base_content, suffix);
    const pack = try buildThinRefDeltaPack(allocator, base_hash, delta);
    defer allocator.free(pack);

    // 3. Parse with storage → success; resolved object lands in store.
    var sc = Scanner.initSeekable(pack);
    var parser = try Parser.initWithStorage(allocator, &sc, &store, &.{});
    defer parser.deinit();

    const checksum = try parser.parse();
    try std.testing.expect(!checksum.isZero());

    const expected_target = plumbing.computeHash(.blob, target_content);
    const target_obj = try store.get(expected_target);
    try std.testing.expect(target_obj.object_type == .blob);
    try std.testing.expectEqualStrings(target_content, target_obj.readerBytes());

    // Base remains available.
    const base_again = try store.get(base_hash);
    try std.testing.expectEqualStrings(base_content, base_again.readerBytes());
}

// Same synthetic pack with empty store must fail (mirror fixture empty-store case).
test "synthetic thin pack empty ObjectStore fails missing base" {
    const allocator = std.testing.allocator;

    const base_content = "hello";
    const suffix = "!";
    const base_hash = plumbing.computeHash(.blob, base_content);

    var delta_storage: [64]u8 = undefined;
    const delta = encodeCopyThenInsertDelta(&delta_storage, base_content, suffix);
    const pack = try buildThinRefDeltaPack(allocator, base_hash, delta);
    defer allocator.free(pack);

    var store = ObjectStore.init(allocator);
    defer store.deinit();

    var sc = Scanner.initSeekable(pack);
    var parser = try Parser.initWithStorage(allocator, &sc, &store, &.{});
    defer parser.deinit();

    if (parser.parse()) |_| {
        try std.testing.expect(false); // expected error
    } else |err| {
        try expectMissingBaseError(err);
    }
}
