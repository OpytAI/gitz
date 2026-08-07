//! Packfile Scanner — port of go-git v5.19.2 `plumbing/format/packfile/scanner.go`.
//!
//! Walks a packfile stream: header, per-object headers, zlib inflate of object
//! bodies, per-object CRC-32 (IEEE), and pack trailer SHA-1 verification.
//!
//! I/O uses Zig 0.16 `std.Io.Reader` / `std.Io.Writer`. Zlib inflate uses
//! `std.compress.flate.Decompress` with container `.zlib` (no C).

const std = @import("std");
const flate = std.compress.flate;
const IoReader = std.Io.Reader;
const IoWriter = std.Io.Writer;
const Limit = std.Io.Limit;
const Sha1 = std.crypto.hash.Sha1;

const plumbing = @import("plumbing");
const binary = @import("binary");

const common = @import("common.zig");
const Error = @import("error.zig").Error;

const ObjectType = plumbing.ObjectType;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;

/// Object header collected from the bytes before zlib content.
/// go-git `ObjectHeader`.
pub const ObjectHeader = struct {
    object_type: ObjectType = .invalid,
    offset: i64 = 0,
    length: i64 = 0,
    reference: Hash = ZeroHash,
    offset_reference: i64 = 0,
};

/// Seekable memory source (position + slice) with `std.Io.Reader` access.
/// go-git seekable path when the underlying reader is an `io.ReadSeeker`.
pub const MemSeekReader = struct {
    data: []const u8,
    reader: IoReader,

    pub fn init(data: []const u8) MemSeekReader {
        return .{
            .data = data,
            .reader = .fixed(data),
        };
    }

    pub fn seekTo(self: *MemSeekReader, offset: i64) Error!void {
        if (offset < 0 or offset > @as(i64, @intCast(self.data.len))) {
            return error.SeekNotSupported;
        }
        self.reader.seek = @intCast(offset);
        self.reader.end = self.data.len;
    }

    pub fn position(self: *const MemSeekReader) i64 {
        return @intCast(self.reader.seek);
    }
};

/// Packfile scanner (go-git `Scanner`).
///
/// | Constructor | Mode |
/// |-------------|------|
/// | `init` | Streaming, non-seekable. Pack SHA-1/CRC via tee while reading. |
/// | `initSeekable` | Full pack image in memory. Seek + accurate hashes. |
///
/// Prefer `initSeekable` for any in-memory pack. Use `init` only for true
/// streams. Do not mutate `is_seekable` after construction.
pub const Scanner = struct {
    /// True only when constructed with `initSeekable`.
    is_seekable: bool,

    /// Seekable memory backend when constructed with `initSeekable`.
    mem: ?[]const u8 = null,
    /// Streaming upstream when constructed with `init`.
    upstream: ?*IoReader = null,

    /// Consumer-facing reader (`fixed(mem)` or hashing tee).
    reader: IoReader,
    /// Buffer for the streaming tee (rebound via `bind` after moves).
    stream_buf: [4096]u8 = undefined,

    /// Bytes delivered through the streaming tee (includes unread buffer).
    stream_offset: i64 = 0,
    /// Bytes already fed to pack SHA-1 / object CRC (mem mode).
    hashed_upto: usize = 0,

    crc: std.hash.Crc32 = .init(),
    pack_hasher: Sha1 = Sha1.init(.{}),

    pending_object: ?ObjectHeader = null,
    version: u32 = 0,
    objects: u32 = 0,

    /// Non-seekable streaming scanner (go-git `NewScanner`).
    pub fn init(r: *IoReader) Scanner {
        var s: Scanner = .{
            .is_seekable = false,
            .upstream = r,
            .reader = .{
                .vtable = &stream_vtable,
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
            .pack_hasher = Sha1.init(.{}),
        };
        s.bind();
        return s;
    }

    /// Seekable scanner over a full pack image in memory.
    /// Use this for pack+idx random access and any offline fixture work.
    pub fn initSeekable(data: []const u8) Scanner {
        return .{
            .is_seekable = true,
            .mem = data,
            .reader = .fixed(data),
            .pack_hasher = Sha1.init(.{}),
            .stream_offset = 0,
            .hashed_upto = 0,
        };
    }

    fn bind(self: *Scanner) void {
        if (self.mem == null) {
            self.reader.buffer = &self.stream_buf;
        }
    }

    fn io(self: *Scanner) *IoReader {
        self.bind();
        return &self.reader;
    }

    /// Current logical offset in the pack (go-git `Seek(0, SeekCurrent)`).
    pub fn position(self: *const Scanner) i64 {
        if (self.mem != null) {
            return @intCast(self.reader.seek);
        }
        // Streaming tee: stream_offset counts bytes filled into the tee
        // (including unread buffer). Subtract unread buffered bytes.
        return self.stream_offset - @as(i64, @intCast(self.reader.bufferedLen()));
    }

    /// Catch pack SHA-1 / CRC up to the current consume position (mem mode).
    fn catchUpHashes(self: *Scanner) void {
        const data = self.mem orelse return;
        const pos: usize = @intCast(self.reader.seek);
        if (pos > self.hashed_upto) {
            const slice = data[self.hashed_upto..pos];
            self.pack_hasher.update(slice);
            self.crc.update(slice);
            self.hashed_upto = pos;
        }
    }

    fn resetObjectCrc(self: *Scanner) void {
        self.crc = .init();
        if (self.mem != null) {
            self.hashed_upto = @intCast(self.reader.seek);
        }
    }

    // -------------------------------------------------------------------------
    // Header
    // -------------------------------------------------------------------------

    /// Read pack signature, version, and object count (go-git `Header`).
    /// Cached after the first successful call.
    pub fn header(self: *Scanner) (Error || IoReader.Error)!struct { u32, u32 } {
        if (self.version != 0) {
            return .{ self.version, self.objects };
        }

        const sig = self.readSignature() catch |e| switch (e) {
            error.EndOfStream => return error.EmptyPackfile,
            else => |err| return err,
        };
        if (!isValidSignature(sig)) return error.BadSignature;

        const ver = try self.readVersion();
        self.version = ver;
        if (ver != common.VersionSupported) return error.UnsupportedVersion;

        const count = try self.readCount();
        self.objects = count;
        return .{ ver, count };
    }

    fn readSignature(self: *Scanner) IoReader.Error![4]u8 {
        var sig: [4]u8 = undefined;
        try self.io().readSliceAll(&sig);
        if (self.mem != null) self.catchUpHashes();
        return sig;
    }

    fn isValidSignature(sig: [4]u8) bool {
        return std.mem.eql(u8, &sig, &common.signature);
    }

    fn readVersion(self: *Scanner) IoReader.Error!u32 {
        const v = try binary.readUint32(self.io());
        if (self.mem != null) self.catchUpHashes();
        return v;
    }

    fn readCount(self: *Scanner) IoReader.Error!u32 {
        const n = try binary.readUint32(self.io());
        if (self.mem != null) self.catchUpHashes();
        return n;
    }

    // -------------------------------------------------------------------------
    // Object headers
    // -------------------------------------------------------------------------

    /// Seek to `offset` and return the object header there (go-git `SeekObjectHeader`).
    pub fn seekObjectHeader(self: *Scanner, offset: i64) (Error || IoReader.Error || IoWriter.Error || binary.Error)!ObjectHeader {
        if (self.version == 0) {
            self.version = common.VersionSupported;
        }
        try self.seekTo(offset);
        var h = try self.nextObjectHeaderInner();
        h.offset = offset;
        return h;
    }

    /// Return the next object header (go-git `NextObjectHeader`).
    pub fn nextObjectHeader(self: *Scanner) (Error || IoReader.Error || IoWriter.Error || binary.Error)!ObjectHeader {
        try self.doPending();
        const off = self.position();
        var h = try self.nextObjectHeaderInner();
        h.offset = off;
        return h;
    }

    fn nextObjectHeaderInner(self: *Scanner) (Error || IoReader.Error || binary.Error)!ObjectHeader {
        // go-git: Flush then crc.Reset
        self.flush();
        self.resetObjectCrc();

        var h: ObjectHeader = .{};
        h.offset = self.position();

        const t, const first = try self.readType();
        h.object_type = t;
        h.length = try self.readLength(first);

        switch (h.object_type) {
            .ofs_delta => {
                const no = binary.readVariableWidthInt(self.io()) catch |e| switch (e) {
                    error.IntegerOverflow => return error.LengthOverflow,
                    else => |err| return err,
                };
                if (self.mem != null) self.catchUpHashes();
                if (no <= 0 or no > h.offset) {
                    return error.MalformedPackFile;
                }
                h.offset_reference = h.offset - no;
            },
            .ref_delta => {
                h.reference = try self.readHash();
            },
            else => {},
        }

        self.pending_object = h;
        return h;
    }

    fn doPending(self: *Scanner) (Error || IoReader.Error || binary.Error || IoWriter.Error)!void {
        if (self.version == 0) {
            _ = try self.header();
        }
        try self.discardObjectIfNeeded();
    }

    fn discardObjectIfNeeded(self: *Scanner) (Error || IoReader.Error || binary.Error || IoWriter.Error)!void {
        const h = self.pending_object orelse return;
        var discard_buf: [1024]u8 = undefined;
        var discarding: IoWriter.Discarding = .init(&discard_buf);
        const n, _ = try self.nextObject(&discarding.writer);
        if (n != h.length) {
            return error.MalformedPackFile;
        }
    }

    fn readType(self: *Scanner) IoReader.Error!struct { ObjectType, u8 } {
        const c = try self.io().takeByte();
        if (self.mem != null) self.catchUpHashes();
        return .{ parseType(c), c };
    }

    fn parseType(b: u8) ObjectType {
        const raw = (b & common.mask_type) >> common.first_length_bits;
        return @enumFromInt(@as(i8, @intCast(raw)));
    }

    /// Length VLQ (go-git `readLength`). Not the OFS-delta offset VLQ.
    fn readLength(self: *Scanner, first: u8) (Error || IoReader.Error)!i64 {
        var length: i64 = first & common.mask_first_length;
        var c: u8 = first;
        // Use u8 so the overflow guard (`shift > 64-7`) can fire before a
        // shift amount wraps (go-git uses a plain int for `shift`).
        var shift: u8 = common.first_length_bits;
        while (c & common.mask_continue != 0) {
            // go-git: shift > 64-7 → LengthOverflow
            if (shift > 64 - @as(u8, common.length_bits)) {
                return error.LengthOverflow;
            }
            c = try self.io().takeByte();
            if (self.mem != null) self.catchUpHashes();
            length += @as(i64, c & common.mask_length) << @intCast(shift);
            shift += common.length_bits;
        }
        return length;
    }

    fn readHash(self: *Scanner) IoReader.Error!Hash {
        var buf: [plumbing.Size]u8 = undefined;
        try self.io().readSliceAll(&buf);
        if (self.mem != null) self.catchUpHashes();
        return Hash.fromBytes(buf);
    }

    // -------------------------------------------------------------------------
    // Object content
    // -------------------------------------------------------------------------

    /// Inflate the next object into `w`. Returns `{written, crc32}`.
    /// go-git `NextObject`.
    pub fn nextObject(self: *Scanner, w: *IoWriter) (Error || IoReader.Error || IoWriter.Error)!struct { i64, u32 } {
        const declared: i64 = if (self.pending_object) |h| h.length else -1;
        self.pending_object = null;

        const written = try self.copyObject(w, declared);

        self.flush();
        if (self.mem != null) self.catchUpHashes();
        const crc_val = self.crc.final();
        self.crc = .init();

        return .{ written, crc_val };
    }

    /// Inflate zlib object body into `w`, optionally bounding by `declared_size`.
    fn copyObject(self: *Scanner, w: *IoWriter, declared_size: i64) (Error || IoReader.Error || IoWriter.Error)!i64 {
        var window: [flate.max_window_len]u8 = undefined;
        var decompress: flate.Decompress = .init(self.io(), .zlib, &window);

        var written: i64 = 0;
        var tmp: [8192]u8 = undefined;

        while (true) {
            const n = decompress.reader.readSliceShort(&tmp) catch {
                // Inflate protocol/data errors surface as ReadFailed.
                return error.ZLib;
            };
            if (n == 0) break;

            if (declared_size >= 0) {
                const remain = declared_size - written;
                if (remain <= 0) {
                    _ = decompress.reader.discardRemaining() catch {};
                    if (self.mem != null) self.catchUpHashes();
                    return error.InflatedSizeMismatch;
                }
                if (n > remain) {
                    // Write legal prefix then error (go-git boundedWriter).
                    try w.writeAll(tmp[0..@intCast(remain)]);
                    written += remain;
                    _ = decompress.reader.discardRemaining() catch {};
                    if (self.mem != null) self.catchUpHashes();
                    return error.InflatedSizeMismatch;
                }
            }

            try w.writeAll(tmp[0..n]);
            written += @intCast(n);
        }

        // Ensure zlib footer / residual state is fully consumed from the input.
        _ = decompress.reader.discardRemaining() catch {};
        if (self.mem != null) self.catchUpHashes();

        return written;
    }

    // -------------------------------------------------------------------------
    // Checksum / seek / reset
    // -------------------------------------------------------------------------

    /// Pack trailer SHA-1, verified against the running pack hasher.
    /// go-git `Checksum`.
    pub fn checksum(self: *Scanner) (Error || IoReader.Error || IoWriter.Error || binary.Error)!Hash {
        try self.discardObjectIfNeeded();
        self.flush();
        if (self.mem != null) self.catchUpHashes();

        var actual: [Sha1.digest_length]u8 = undefined;
        var ph = self.pack_hasher;
        ph.final(&actual);

        // Read trailer without folding it into the already-finalised digest.
        // (Streaming tee still updates pack_hasher after this — harmless.)
        const pack_checksum = try self.readHash();

        if (!std.mem.eql(u8, &actual, pack_checksum.slice())) {
            return error.MalformedPackFile;
        }
        return pack_checksum;
    }

    fn seekTo(self: *Scanner, offset: i64) Error!void {
        // Only `initSeekable` sets is_seekable; mem is always present then.
        if (!self.is_seekable) return error.SeekNotSupported;
        if (offset < 0) return error.SeekNotSupported;

        const data = self.mem orelse return error.SeekNotSupported;
        if (offset > @as(i64, @intCast(data.len))) return error.SeekNotSupported;
        self.reader.seek = @intCast(offset);
        self.reader.end = data.len;
        // After an absolute seek, subsequent catch-up hashes from the new
        // position only (go-git resets the buffered reader; CRC restarts per
        // object via resetObjectCrc).
        self.hashed_upto = @intCast(offset);
        self.pending_object = null;
    }

    /// go-git `Reset`.
    pub fn reset(self: *Scanner, r: *IoReader) void {
        self.is_seekable = false;
        self.mem = null;
        self.upstream = r;
        self.reader = .{
            .vtable = &stream_vtable,
            .buffer = &.{},
            .seek = 0,
            .end = 0,
        };
        self.bind();
        self.stream_offset = 0;
        self.hashed_upto = 0;
        self.crc = .init();
        self.pack_hasher = Sha1.init(.{});
        self.pending_object = null;
        self.version = 0;
        self.objects = 0;
    }

    /// go-git `Flush` (no-op: tee hashes immediately; mem mode is direct).
    pub fn flush(self: *Scanner) void {
        _ = self;
    }

    // -------------------------------------------------------------------------
    // Streaming tee reader (non-seekable / init path)
    // -------------------------------------------------------------------------

    const stream_vtable: IoReader.VTable = .{
        .stream = streamStream,
        .discard = streamDiscard,
    };

    fn streamStream(r: *IoReader, w: *IoWriter, limit: Limit) IoReader.StreamError!usize {
        const s: *Scanner = @alignCast(@fieldParentPtr("reader", r));
        const up = s.upstream orelse return error.EndOfStream;

        const want = limit.minInt(4096);
        if (want == 0) return 0;

        var tmp: [4096]u8 = undefined;
        const n = up.readSliceShort(tmp[0..want]) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;

        const chunk = tmp[0..n];
        // Full write required so hash and stream_offset stay aligned with
        // bytes taken from upstream (defaultReadVec sizes the limit to fit).
        w.writeAll(chunk) catch return error.WriteFailed;
        s.crc.update(chunk);
        s.pack_hasher.update(chunk);
        s.stream_offset += @intCast(n);
        return n;
    }

    fn streamDiscard(r: *IoReader, limit: Limit) IoReader.Error!usize {
        const s: *Scanner = @alignCast(@fieldParentPtr("reader", r));
        const up = s.upstream orelse return error.EndOfStream;
        const want = limit.minInt(4096);
        if (want == 0) return 0;
        var tmp: [4096]u8 = undefined;
        const n = up.readSliceShort(tmp[0..want]) catch return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        s.crc.update(tmp[0..n]);
        s.pack_hasher.update(tmp[0..n]);
        s.stream_offset += @intCast(n);
        return n;
    }
};

// =============================================================================
// Tests (go-git scanner_test.go / scanner_bounded_test.go)
// =============================================================================

const basic_pack = @import("basic_pack.zig").data;
const basic_pack_checksum_hex = "a3fed42da1e8189a077c0e6846c040dcf73fc9dd";

const expected_headers_ofs = [_]ObjectHeader{
    .{ .object_type = .commit, .offset = 12, .length = 254 },
    .{ .object_type = .ofs_delta, .offset = 186, .length = 93, .offset_reference = 12 },
    .{ .object_type = .commit, .offset = 286, .length = 242 },
    .{ .object_type = .commit, .offset = 449, .length = 242 },
    .{ .object_type = .commit, .offset = 615, .length = 333 },
    .{ .object_type = .commit, .offset = 838, .length = 332 },
    .{ .object_type = .commit, .offset = 1063, .length = 244 },
    .{ .object_type = .commit, .offset = 1230, .length = 243 },
    .{ .object_type = .commit, .offset = 1392, .length = 187 },
    .{ .object_type = .blob, .offset = 1524, .length = 189 },
    .{ .object_type = .blob, .offset = 1685, .length = 18 },
    .{ .object_type = .blob, .offset = 1713, .length = 1072 },
    .{ .object_type = .blob, .offset = 2351, .length = 76110 },
    .{ .object_type = .blob, .offset = 78050, .length = 2780 },
    .{ .object_type = .blob, .offset = 78882, .length = 217848 },
    .{ .object_type = .blob, .offset = 80725, .length = 706 },
    .{ .object_type = .blob, .offset = 80998, .length = 11488 },
    .{ .object_type = .blob, .offset = 84032, .length = 78 },
    .{ .object_type = .tree, .offset = 84115, .length = 272 },
    .{ .object_type = .ofs_delta, .offset = 84375, .length = 43, .offset_reference = 84115 },
    .{ .object_type = .tree, .offset = 84430, .length = 38 },
    .{ .object_type = .tree, .offset = 84479, .length = 75 },
    .{ .object_type = .tree, .offset = 84559, .length = 38 },
    .{ .object_type = .tree, .offset = 84608, .length = 34 },
    .{ .object_type = .blob, .offset = 84653, .length = 9 },
    .{ .object_type = .ofs_delta, .offset = 84671, .length = 6, .offset_reference = 84375 },
    .{ .object_type = .ofs_delta, .offset = 84688, .length = 9, .offset_reference = 84375 },
    .{ .object_type = .ofs_delta, .offset = 84708, .length = 6, .offset_reference = 84375 },
    .{ .object_type = .ofs_delta, .offset = 84725, .length = 5, .offset_reference = 84115 },
    .{ .object_type = .ofs_delta, .offset = 84741, .length = 8, .offset_reference = 84375 },
    .{ .object_type = .ofs_delta, .offset = 84760, .length = 4, .offset_reference = 84741 },
};

const expected_crc_ofs = [_]u32{
    0xaa07ba4b,
    0xf706df58,
    0x12438846,
    0x2905a38c,
    0xd9429436,
    0xbecfde4e,
    0x780e4b3e,
    0xdc18344f,
    0xcf4e4280,
    0x1f08118a,
    0xafded7b8,
    0xcc1428ed,
    0x1631d22f,
    0xbfff5850,
    0xd108e1d8,
    0x8e97ba25,
    0x7316ff70,
    0xdb4fce56,
    0x901cce2c,
    0xec4552b0,
    0x847905bf,
    0x3689459a,
    0xe67af94a,
    0xc2314a2e,
    0xcd987848,
    0x8a853a6d,
    0x70c6518,
    0x4f4108e2,
    0xd6fe09e9,
    0xf07a2804,
    0x1d75d6be,
};

fn expectHeaderEql(got: ObjectHeader, want: ObjectHeader) !void {
    try std.testing.expectEqual(want.object_type, got.object_type);
    try std.testing.expectEqual(want.offset, got.offset);
    try std.testing.expectEqual(want.length, got.length);
    try std.testing.expectEqual(want.offset_reference, got.offset_reference);
    try std.testing.expect(got.reference.eql(want.reference));
}

// go-git ScannerSuite.TestHeader
test "TestHeader" {
    var sc = Scanner.initSeekable(basic_pack);
    const version, const objects = try sc.header();
    try std.testing.expectEqual(common.VersionSupported, version);
    try std.testing.expectEqual(@as(u32, 31), objects);
}

// go-git: Header via non-seekable init (root.zig / Packfile style)
test "TestHeader non-seekable init" {
    var r: IoReader = .fixed(basic_pack);
    var sc = Scanner.init(&r);
    const version, const objects = try sc.header();
    try std.testing.expectEqual(common.VersionSupported, version);
    try std.testing.expectEqual(@as(u32, 31), objects);
}

// go-git ScannerSuite.TestNextObjectHeaderWithoutHeader
test "TestNextObjectHeaderWithoutHeader" {
    var sc = Scanner.initSeekable(basic_pack);
    const h = try sc.nextObjectHeader();
    try expectHeaderEql(h, expected_headers_ofs[0]);

    const version, const objects = try sc.header();
    try std.testing.expectEqual(common.VersionSupported, version);
    try std.testing.expectEqual(@as(u32, 31), objects);
}

// go-git ScannerSuite.TestNextObjectHeaderOFSDelta + CRC + Checksum
test "TestNextObjectHeaderOFSDelta" {
    var sc = Scanner.initSeekable(basic_pack);
    _, const objects = try sc.header();
    try std.testing.expectEqual(@as(u32, 31), objects);

    var i: usize = 0;
    while (i < objects) : (i += 1) {
        const h = try sc.nextObjectHeader();
        try expectHeaderEql(h, expected_headers_ofs[i]);

        var discard_buf: [1024]u8 = undefined;
        var discarding: IoWriter.Discarding = .init(&discard_buf);
        const n, const crc = try sc.nextObject(&discarding.writer);
        try std.testing.expectEqual(h.length, n);
        try std.testing.expectEqual(expected_crc_ofs[i], crc);
    }

    const sum = try sc.checksum();
    const want = plumbing.newHash(basic_pack_checksum_hex);
    try std.testing.expect(sum.eql(want));
}

// go-git: NextObjectHeader without reading objects, then Checksum
test "TestNextObjectHeaderWithOutReadObject" {
    var sc = Scanner.initSeekable(basic_pack);
    _, const objects = try sc.header();

    var i: usize = 0;
    while (i < objects) : (i += 1) {
        const h = try sc.nextObjectHeader();
        try expectHeaderEql(h, expected_headers_ofs[i]);
    }

    const sum = try sc.checksum();
    const want = plumbing.newHash(basic_pack_checksum_hex);
    try std.testing.expect(sum.eql(want));
}

// go-git ScannerSuite.TestSeekObjectHeader
test "TestSeekObjectHeader" {
    var sc = Scanner.initSeekable(basic_pack);
    const h = try sc.seekObjectHeader(expected_headers_ofs[4].offset);
    try expectHeaderEql(h, expected_headers_ofs[4]);
}

// go-git ScannerSuite.TestSeekObjectHeaderNonSeekable
test "TestSeekObjectHeaderNonSeekable" {
    var r: IoReader = .fixed(basic_pack);
    var sc = Scanner.init(&r);
    try std.testing.expect(!sc.is_seekable);
    try std.testing.expectError(
        error.SeekNotSupported,
        sc.seekObjectHeader(expected_headers_ofs[4].offset),
    );
}

// go-git: empty pack → EmptyPackfile
test "TestEmptyPackfile" {
    var sc = Scanner.initSeekable(&[_]u8{});
    try std.testing.expectError(error.EmptyPackfile, sc.header());
}

// go-git: bad signature → BadSignature
test "TestBadSignature" {
    const junk = [_]u8{ 'X', 'X', 'X', 'X', 0, 0, 0, 2, 0, 0, 0, 0 };
    var sc = Scanner.initSeekable(&junk);
    try std.testing.expectError(error.BadSignature, sc.header());
}

// go-git scanner_bounded_test.go TestNextObjectRejectsOversizedInflate
test "TestNextObjectRejectsOversizedInflate" {
    const real_size: usize = 1 << 16; // 64 KiB (still > declared)
    const declared_size: i64 = 4096;

    var raw_buf: std.ArrayList(u8) = .empty;
    defer raw_buf.deinit(std.testing.allocator);

    {
        var out: IoWriter.Allocating = try .initCapacity(std.testing.allocator, 8192);
        defer out.deinit();
        var window: [flate.max_window_len]u8 = undefined;
        var comp = try flate.Compress.init(&out.writer, &window, .zlib, .default);
        const zeros = try std.testing.allocator.alloc(u8, real_size);
        defer std.testing.allocator.free(zeros);
        @memset(zeros, 0);
        try comp.writer.writeAll(zeros);
        try comp.finish();
        try raw_buf.appendSlice(std.testing.allocator, out.writer.buffered());
    }

    const pack = try buildMinimalPack(std.testing.allocator, .blob, declared_size, raw_buf.items);
    defer std.testing.allocator.free(pack);

    var sc = Scanner.initSeekable(pack);
    _, _ = try sc.header();
    const oh = try sc.nextObjectHeader();
    try std.testing.expectEqual(ObjectType.blob, oh.object_type);
    try std.testing.expectEqual(declared_size, oh.length);

    var sink: IoWriter.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try std.testing.expectError(error.InflatedSizeMismatch, sc.nextObject(&sink.writer));
    try std.testing.expect(sink.writer.buffered().len <= @as(usize, @intCast(declared_size)));
}

// go-git scanner_bounded_test.go boundedWriter / declared size 0
test "TestBoundedWriter zero declared size" {
    var raw_buf: std.ArrayList(u8) = .empty;
    defer raw_buf.deinit(std.testing.allocator);
    {
        var out: IoWriter.Allocating = try .initCapacity(std.testing.allocator, 256);
        defer out.deinit();
        var window: [flate.max_window_len]u8 = undefined;
        var comp = try flate.Compress.init(&out.writer, &window, .zlib, .default);
        try comp.writer.writeAll("x");
        try comp.finish();
        try raw_buf.appendSlice(std.testing.allocator, out.writer.buffered());
    }
    const pack = try buildMinimalPack(std.testing.allocator, .blob, 0, raw_buf.items);
    defer std.testing.allocator.free(pack);

    var sc = Scanner.initSeekable(pack);
    _, _ = try sc.header();
    _ = try sc.nextObjectHeader();
    var sink: IoWriter.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    try std.testing.expectError(error.InflatedSizeMismatch, sc.nextObject(&sink.writer));
    try std.testing.expectEqual(@as(usize, 0), sink.writer.buffered().len);
}

/// buildMinimalPack — go-git scanner_bounded_test.go helper.
fn buildMinimalPack(
    allocator: std.mem.Allocator,
    typ: ObjectType,
    declared_size: i64,
    compressed_body: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var hasher = Sha1.init(.{});

    const writeBoth = struct {
        fn go(b: *std.ArrayList(u8), h: *Sha1, a: std.mem.Allocator, bytes: []const u8) !void {
            try b.appendSlice(a, bytes);
            h.update(bytes);
        }
    }.go;

    try writeBoth(&buf, &hasher, allocator, &common.signature);

    var u32buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &u32buf, 2, .big);
    try writeBoth(&buf, &hasher, allocator, &u32buf);
    std.mem.writeInt(u32, &u32buf, 1, .big);
    try writeBoth(&buf, &hasher, allocator, &u32buf);

    // Object header VLQ (type + declared size).
    const t: u8 = @intCast(@intFromEnum(typ));
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

    try writeBoth(&buf, &hasher, allocator, compressed_body);

    var trailer: [Sha1.digest_length]u8 = undefined;
    hasher.final(&trailer);
    try buf.appendSlice(allocator, &trailer);

    return try buf.toOwnedSlice(allocator);
}

test "MemSeekReader seek and position" {
    var m = MemSeekReader.init(basic_pack);
    try std.testing.expectEqual(@as(i64, 0), m.position());
    try m.seekTo(12);
    try std.testing.expectEqual(@as(i64, 12), m.position());
    _ = try m.reader.takeByte();
    try std.testing.expectEqual(@as(i64, 13), m.position());
}

test "parseType extracts pack object type nibble" {
    try std.testing.expectEqual(ObjectType.commit, Scanner.parseType(0x10));
    try std.testing.expectEqual(ObjectType.tree, Scanner.parseType(0x20));
    try std.testing.expectEqual(ObjectType.blob, Scanner.parseType(0x30));
    try std.testing.expectEqual(ObjectType.tag, Scanner.parseType(0x40));
    try std.testing.expectEqual(ObjectType.ofs_delta, Scanner.parseType(0x60));
    try std.testing.expectEqual(ObjectType.ref_delta, Scanner.parseType(0x70));
}
