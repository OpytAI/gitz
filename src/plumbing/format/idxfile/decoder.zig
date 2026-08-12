//! Pack idx v2 decoder — port of go-git
//! `plumbing/format/idxfile/decoder.go` (v5.19.2).

const std = @import("std");
const hash_pkg = @import("hash");
const plumbing = @import("plumbing");

const idxfile = @import("idxfile.zig");

const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;

const Error = idxfile.Error;
const MemoryIndex = idxfile.MemoryIndex;
const fanout = idxfile.fanout;
const objectIdLength = idxfile.objectIdLength; // fn() usize
const noMapping = idxfile.noMapping;
const VersionSupported = idxfile.VersionSupported;
const idxHeader = idxfile.idxHeader;

// Byte sizes of the idx v2 layout (go-git decoder.go).
const header_len: i64 = 8;
const fanout_len: i64 = fanout * 4;
const crc32_len: i64 = 4;
const offset32_len: i64 = 4;
const offset64_len: i64 = 8;
const trailer_hashes: i64 = 2;
/// Prevent a forged fanout table from requesting multi-gigabyte allocations
/// before any object table bytes have been received.
const max_object_count: u32 = 16 * 1024 * 1024;

/// Reads and decodes idx files from an input stream (go-git `Decoder`).
pub const Decoder = struct {
    reader: *Reader,
    hasher: hash_pkg.Hasher,
    /// When set, enforces Git load_idx size formula before body reads
    /// (go-git path when input has `Stat()`).
    known_size: ?i64 = null,

    /// go-git `NewDecoder`.
    pub fn init(reader: *Reader) Decoder {
        return .{
            .reader = reader,
            .hasher = hash_pkg.new(.sha1),
            .known_size = null,
        };
    }

    /// Like `init`, but also validates on-disk size against the fanout
    /// (go-git when the reader implements `Stat`).
    pub fn initWithSize(reader: *Reader, size: i64) Decoder {
        return .{
            .reader = reader,
            .hasher = hash_pkg.new(.sha1),
            .known_size = size,
        };
    }

    /// Decode the stream into `idx` (go-git `Decode`).
    pub fn decode(self: *Decoder, idx: *MemoryIndex) (Error || Allocator.Error || Reader.Error)!void {
        try self.validateHeader();
        try self.readVersion(idx);
        try self.readFanout(idx);

        if (self.known_size) |sz| {
            try validateIdxV2Size(idx, sz);
        }

        try self.readObjectNames(idx);
        try self.readCRC32(idx);
        try self.readOffsets(idx);
        try self.readPackChecksum(idx);

        var actual: [hash_pkg.Size]u8 = undefined;
        self.hasher.final(&actual);

        try self.readIdxChecksum(idx);

        if (!std.mem.eql(u8, &actual, idx.idx_checksum.slice())) {
            return Error.MalformedIdxFile;
        }
    }

    fn readHashed(self: *Decoder, buf: []u8) Reader.Error!void {
        try self.reader.readSliceAll(buf);
        self.hasher.update(buf);
    }

    fn readHashedInt(self: *Decoder, comptime T: type) Reader.Error!T {
        var buf: [@sizeOf(T)]u8 = undefined;
        try self.readHashed(&buf);
        return std.mem.readInt(T, &buf, .big);
    }

    fn validateHeader(self: *Decoder) (Error || Reader.Error)!void {
        var h: [4]u8 = undefined;
        try self.readHashed(&h);
        if (!std.mem.eql(u8, &h, idxHeader)) return Error.MalformedIdxFile;
    }

    fn readVersion(self: *Decoder, idx: *MemoryIndex) (Error || Reader.Error)!void {
        const v = try self.readHashedInt(u32);
        if (v != VersionSupported) return Error.UnsupportedVersion;
        idx.version = v;
    }

    fn readFanout(self: *Decoder, idx: *MemoryIndex) (Error || Reader.Error)!void {
        var k: usize = 0;
        while (k < fanout) : (k += 1) {
            const n = try self.readHashedInt(u32);
            if (k > 0 and n < idx.fanout[k - 1]) return Error.MalformedIdxFile;
            idx.fanout[k] = n;
            idx.fanout_mapping[k] = noMapping;
        }
    }

    fn readObjectNames(self: *Decoder, idx: *MemoryIndex) (Error || Allocator.Error || Reader.Error)!void {
        if (idx.fanout[fanout - 1] > max_object_count) return Error.MalformedIdxFile;
        var k: usize = 0;
        while (k < fanout) : (k += 1) {
            const buckets: u32 = if (k == 0)
                idx.fanout[k]
            else
                idx.fanout[k] - idx.fanout[k - 1];

            if (buckets == 0) continue;

            idx.fanout_mapping[k] = @intCast(idx.names.items.len);

            try idx.names.ensureUnusedCapacity(idx.allocator, 1);
            try idx.offset32.ensureUnusedCapacity(idx.allocator, 1);
            try idx.crc32.ensureUnusedCapacity(idx.allocator, 1);

            const name_len: usize = @as(usize, buckets) * objectIdLength();
            const bin = try idx.allocator.alloc(u8, name_len);
            errdefer idx.allocator.free(bin);
            try self.readHashed(bin);

            const o32 = try idx.allocator.alloc(u8, @as(usize, buckets) * 4);
            errdefer idx.allocator.free(o32);
            @memset(o32, 0);

            const c32 = try idx.allocator.alloc(u8, @as(usize, buckets) * 4);
            errdefer idx.allocator.free(c32);
            @memset(c32, 0);

            idx.names.appendAssumeCapacity(bin);
            idx.offset32.appendAssumeCapacity(o32);
            idx.crc32.appendAssumeCapacity(c32);
        }
    }

    fn readCRC32(self: *Decoder, idx: *MemoryIndex) Reader.Error!void {
        var k: usize = 0;
        while (k < fanout) : (k += 1) {
            const pos = idx.fanout_mapping[k];
            if (pos != noMapping) {
                try self.readHashed(idx.crc32.items[@intCast(pos)]);
            }
        }
    }

    fn readOffsets(self: *Decoder, idx: *MemoryIndex) (Allocator.Error || Reader.Error)!void {
        var o64cnt: i64 = 0;
        var k: usize = 0;
        while (k < fanout) : (k += 1) {
            const pos = idx.fanout_mapping[k];
            if (pos != noMapping) {
                const pi: usize = @intCast(pos);
                try self.readHashed(idx.offset32.items[pi]);
                var p: usize = 0;
                while (p < idx.offset32.items[pi].len) : (p += 4) {
                    if (idx.offset32.items[pi][p] & (@as(u8, 1) << 7) != 0) {
                        o64cnt += 1;
                    }
                }
            }
        }

        if (o64cnt > 0) {
            const buf = try idx.allocator.alloc(u8, @intCast(o64cnt * 8));
            errdefer idx.allocator.free(buf);
            try self.readHashed(buf);
            idx.offset64 = buf;
        }
    }

    fn readPackChecksum(self: *Decoder, idx: *MemoryIndex) Reader.Error!void {
        var buf: [hash_pkg.MaxSize]u8 = undefined;
        const n = objectIdLength();
        try self.readHashed(buf[0..n]);
        idx.packfile_checksum = plumbing.Hash.fromBytes(buf[0..n]);
    }

    fn readIdxChecksum(self: *Decoder, idx: *MemoryIndex) Reader.Error!void {
        // Not hashed: go-git takes Sum before reading the trailer checksum.
        var buf: [hash_pkg.MaxSize]u8 = undefined;
        const n = objectIdLength();
        try self.reader.readSliceAll(buf[0..n]);
        idx.idx_checksum = plumbing.Hash.fromBytes(buf[0..n]);
    }
};

fn validateIdxV2Size(idx: *const MemoryIndex, idx_size: i64) Error!void {
    const nr: i64 = idx.fanout[fanout - 1];
    const hashsz: i64 = @intCast(objectIdLength());

    const min_size = minIdxV2Size(nr, hashsz);
    const max_size = maxIdxV2Size(nr, hashsz);
    if (min_size < 0 or max_size < 0) return Error.MalformedIdxFile;
    if (idx_size < min_size or idx_size > max_size) return Error.MalformedIdxFile;
}

fn minIdxV2Size(nr: i64, hashsz: i64) i64 {
    const per_object = hashsz + crc32_len + offset32_len;
    const fixed = header_len + fanout_len + trailer_hashes * hashsz;
    const objects = mulInt64(nr, per_object) orelse return -1;
    return addInt64(fixed, objects) orelse -1;
}

fn maxIdxV2Size(nr: i64, hashsz: i64) i64 {
    const min_size = minIdxV2Size(nr, hashsz);
    if (min_size < 0) return -1;
    if (nr == 0) return min_size;
    const overflow = mulInt64(nr - 1, offset64_len) orelse return -1;
    return addInt64(min_size, overflow) orelse -1;
}

fn mulInt64(a: i64, b: i64) ?i64 {
    if (a < 0 or b < 0) return null;
    if (a == 0 or b == 0) return 0;
    const c = a *% b;
    if (@divTrunc(c, b) != a) return null;
    return c;
}

fn addInt64(a: i64, b: i64) ?i64 {
    if (a < 0 or b < 0) return null;
    const c = a +% b;
    if (c < a) return null;
    return c;
}

test "decoder rejects forged fanout before table allocation" {
    var raw: [8 + fanout * 4]u8 = .{0} ** (8 + fanout * 4);
    @memcpy(raw[0..4], idxHeader);
    std.mem.writeInt(u32, raw[4..8], VersionSupported, .big);
    std.mem.writeInt(u32, raw[raw.len - 4 ..][0..4], std.math.maxInt(u32), .big);

    var reader = Reader.fixed(&raw);
    var decoder = Decoder.init(&reader);
    var idx = MemoryIndex.init(std.testing.allocator);
    defer idx.deinit();
    try std.testing.expectError(Error.MalformedIdxFile, decoder.decode(&idx));
}
