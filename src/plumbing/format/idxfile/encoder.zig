//! Pack idx v2 encoder — port of go-git
//! `plumbing/format/idxfile/encoder.go` (v5.19.2).

const std = @import("std");
const hash_pkg = @import("hash");
const plumbing = @import("plumbing");

const idxfile = @import("idxfile.zig");

const Writer = std.Io.Writer;
const MemoryIndex = idxfile.MemoryIndex;
const fanout = idxfile.fanout;
const noMapping = idxfile.noMapping;
const idxHeader = idxfile.idxHeader;
const objectIdLength = idxfile.objectIdLength;

/// Writes `MemoryIndex` structs to an output stream (go-git `Encoder`).
pub const Encoder = struct {
    writer: *Writer,
    hasher: hash_pkg.Hasher,

    /// go-git `NewEncoder`.
    pub fn init(writer: *Writer) Encoder {
        return .{
            .writer = writer,
            .hasher = hash_pkg.new(.sha1),
        };
    }

    /// Encode `idx` to the writer. Returns bytes written (go-git `Encode`).
    /// Updates `idx.idx_checksum` to the trailer checksum.
    pub fn encode(self: *Encoder, idx: *MemoryIndex) (Writer.Error)!usize {
        var sz: usize = 0;
        sz += try self.encodeHeader(idx);
        sz += try self.encodeFanout(idx);
        sz += try self.encodeHashes(idx);
        sz += try self.encodeCRC32(idx);
        sz += try self.encodeOffsets(idx);
        sz += try self.encodeChecksums(idx);
        return sz;
    }

    fn writeAll(self: *Encoder, data: []const u8) Writer.Error!usize {
        try self.writer.writeAll(data);
        self.hasher.update(data);
        return data.len;
    }

    fn writeUint32(self: *Encoder, value: u32) Writer.Error!void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .big);
        _ = try self.writeAll(&buf);
    }

    fn encodeHeader(self: *Encoder, idx: *MemoryIndex) Writer.Error!usize {
        var n = try self.writeAll(idxHeader);
        try self.writeUint32(idx.version);
        n += 4;
        return n;
    }

    fn encodeFanout(self: *Encoder, idx: *const MemoryIndex) Writer.Error!usize {
        for (idx.fanout) |c| {
            try self.writeUint32(c);
        }
        return fanout * 4;
    }

    fn encodeHashes(self: *Encoder, idx: *const MemoryIndex) Writer.Error!usize {
        var size: usize = 0;
        var k: usize = 0;
        while (k < fanout) : (k += 1) {
            const pos = idx.fanout_mapping[k];
            if (pos == noMapping) continue;
            size += try self.writeAll(idx.names.items[@intCast(pos)]);
        }
        return size;
    }

    fn encodeCRC32(self: *Encoder, idx: *const MemoryIndex) Writer.Error!usize {
        var size: usize = 0;
        var k: usize = 0;
        while (k < fanout) : (k += 1) {
            const pos = idx.fanout_mapping[k];
            if (pos == noMapping) continue;
            size += try self.writeAll(idx.crc32.items[@intCast(pos)]);
        }
        return size;
    }

    fn encodeOffsets(self: *Encoder, idx: *const MemoryIndex) Writer.Error!usize {
        var size: usize = 0;
        var k: usize = 0;
        while (k < fanout) : (k += 1) {
            const pos = idx.fanout_mapping[k];
            if (pos == noMapping) continue;
            size += try self.writeAll(idx.offset32.items[@intCast(pos)]);
        }
        if (idx.offset64.len > 0) {
            size += try self.writeAll(idx.offset64);
        }
        return size;
    }

    fn encodeChecksums(self: *Encoder, idx: *MemoryIndex) Writer.Error!usize {
        const oid_len = objectIdLength();
        _ = try self.writeAll(idx.packfile_checksum.bytes[0..oid_len]);

        var sum: [hash_pkg.MaxSize]u8 = undefined;
        self.hasher.final(&sum);
        idx.idx_checksum = plumbing.Hash.fromBytes(sum[0..oid_len]);
        // Trailer checksum is not hashed (already finalized).
        try self.writer.writeAll(idx.idx_checksum.bytes[0..oid_len]);
        return oid_len * 2;
    }
};
