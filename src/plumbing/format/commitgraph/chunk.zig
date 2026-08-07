//! Chunk type signatures for the commit-graph file format.
//!
//! Port of go-git v5.19.2 `plumbing/format/commitgraph/v2/chunk.go`.

const std = @import("std");

/// Length of a chunk signature in bytes (go-git `szChunkSig`).
pub const sz_chunk_sig: usize = 4;
/// Offset of each chunk signature in `chunk_signatures` (go-git `chunkSigOffset`).
pub const chunk_sig_offset: usize = 4;

/// Coalesced byte signatures for each chunk type (go-git `chunkSignatures`).
/// Order must match `ChunkType` enum values.
pub const chunk_signatures: []const u8 = "OIDFOIDLCDATGDA2GDO2EDGEBIDXBDATBASE\x00\x00\x00\x00";

/// Chunk type in a commit-graph file (go-git `ChunkType`).
pub const ChunkType = enum(i32) {
    oid_fanout = 0, // "OIDF"
    oid_lookup = 1, // "OIDL"
    commit_data = 2, // "CDAT"
    generation_data = 3, // "GDA2"
    generation_data_overflow = 4, // "GDO2"
    extra_edge_list = 5, // "EDGE"
    bloom_filter_index = 6, // "BIDX"
    bloom_filter_data = 7, // "BDAT"
    base_graphs_list = 8, // "BASE"
    zero = 9, // "\000\000\000\000"

    /// Number of real chunk types (excludes Zero). go-git `lenChunks`.
    pub const len_chunks: usize = @intFromEnum(ChunkType.zero);

    /// go-git `ChunkType.Signature`.
    pub fn signature(self: ChunkType) *const [sz_chunk_sig]u8 {
        const ct = @intFromEnum(self);
        if (ct >= @intFromEnum(ChunkType.base_graphs_list) or ct < 0) {
            const z = @intFromEnum(ChunkType.zero);
            return chunk_signatures[z * chunk_sig_offset ..][0..sz_chunk_sig];
        }
        return chunk_signatures[@as(usize, @intCast(ct)) * chunk_sig_offset ..][0..sz_chunk_sig];
    }

    /// go-git `ChunkTypeFromBytes`.
    pub fn fromBytes(b: []const u8) ?ChunkType {
        if (b.len < sz_chunk_sig) return null;
        const needle = b[0..sz_chunk_sig];
        // Search aligned signatures only.
        var idx: usize = 0;
        while (idx + sz_chunk_sig <= chunk_signatures.len) : (idx += chunk_sig_offset) {
            if (std.mem.eql(u8, chunk_signatures[idx .. idx + sz_chunk_sig], needle)) {
                return @enumFromInt(@as(i32, @intCast(idx / chunk_sig_offset)));
            }
        }
        return null;
    }
};

test "ChunkType signatures" {
    try std.testing.expectEqualStrings("OIDF", ChunkType.oid_fanout.signature());
    try std.testing.expectEqualStrings("OIDL", ChunkType.oid_lookup.signature());
    try std.testing.expectEqualStrings("CDAT", ChunkType.commit_data.signature());
    try std.testing.expectEqualStrings("GDA2", ChunkType.generation_data.signature());
    try std.testing.expectEqualStrings("GDO2", ChunkType.generation_data_overflow.signature());
    try std.testing.expectEqualStrings("EDGE", ChunkType.extra_edge_list.signature());
    try std.testing.expectEqualStrings("\x00\x00\x00\x00", ChunkType.zero.signature());

    try std.testing.expect(ChunkType.fromBytes("OIDF").? == .oid_fanout);
    try std.testing.expect(ChunkType.fromBytes("CDAT").? == .commit_data);
    try std.testing.expect(ChunkType.fromBytes("EDGE").? == .extra_edge_list);
    try std.testing.expect(ChunkType.fromBytes("XXXX") == null);
}
