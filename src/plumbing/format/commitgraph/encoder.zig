//! Commit-graph encoder — port of go-git
//! `plumbing/format/commitgraph/v2/encoder.go` (v5.19.2).
//!
//! Writes an Index (MemoryIndex or any type with the Index surface) to the
//! commit-graph file format with OIDF/OIDL/CDAT and optional EDGE/GDA2/GDO2.

const std = @import("std");
const plumbing = @import("plumbing");
const hash_pkg = @import("hash");

const commitgraph = @import("commitgraph.zig");
const chunk_mod = @import("chunk.zig");
const memory_mod = @import("memory.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Hash = plumbing.Hash;
const CommitData = commitgraph.CommitData;
const ChunkType = chunk_mod.ChunkType;
const Error = commitgraph.Error;
const MemoryIndex = memory_mod.MemoryIndex;

const EncodeError = Error || Writer.Error || Allocator.Error;

/// Writes MemoryIndex / Index structs to an output stream (go-git `Encoder`).
///
/// Trailer checksum and OID width follow the active object format
/// (`hash.objectFormat` / go-git `hash.CryptoType`).
pub const Encoder = struct {
    writer: *Writer,
    hasher: hash_pkg.Hasher,
    allocator: Allocator,

    /// go-git `NewEncoder`. `allocator` is used for temporary sort maps.
    pub fn init(allocator: Allocator, writer: *Writer) Encoder {
        return .{
            .writer = writer,
            .hasher = hash_pkg.new(hash_pkg.objectFormat()),
            .allocator = allocator,
        };
    }

    /// Encode `idx` (MemoryIndex or compatible) to the commit-graph stream.
    pub fn encode(self: *Encoder, idx: anytype) EncodeError!void {
        const hashes_owned = try idx.hashes(self.allocator);
        defer self.allocator.free(hashes_owned);

        // Work on a mutable copy we can sort.
        const hashes = try self.allocator.dupe(Hash, hashes_owned);
        defer self.allocator.free(hashes);

        var prep = try self.prepare(idx, hashes);
        defer {
            var hmap = prep.hash_to_index; hmap.deinit(self.allocator); prep.hash_to_index = hmap;
            self.allocator.free(prep.fanout);
        }

        var chunk_sigs: std.ArrayListUnmanaged([]const u8) = .empty;
        defer chunk_sigs.deinit(self.allocator);
        var chunk_sizes: std.ArrayListUnmanaged(u64) = .empty;
        defer chunk_sizes.deinit(self.allocator);

        try chunk_sigs.append(self.allocator, ChunkType.oid_fanout.signature());
        try chunk_sizes.append(self.allocator, commitgraph.sz_uint32 * commitgraph.len_fanout);

        try chunk_sigs.append(self.allocator, ChunkType.oid_lookup.signature());
        try chunk_sizes.append(self.allocator, @as(u64, @intCast(hashes.len)) * commitgraph.hashSize());

        try chunk_sigs.append(self.allocator, ChunkType.commit_data.signature());
        try chunk_sizes.append(
            self.allocator,
            @as(u64, @intCast(hashes.len)) * (commitgraph.hashSize() + commitgraph.sz_commit_data),
        );

        if (prep.extra_edges_count > 0) {
            try chunk_sigs.append(self.allocator, ChunkType.extra_edge_list.signature());
            try chunk_sizes.append(self.allocator, @as(u64, prep.extra_edges_count) * commitgraph.sz_uint32);
        }
        if (idx.hasGenerationV2()) {
            try chunk_sigs.append(self.allocator, ChunkType.generation_data.signature());
            try chunk_sizes.append(self.allocator, @as(u64, @intCast(hashes.len)) * commitgraph.sz_uint32);
            if (prep.generation_v2_overflow_count > 0) {
                try chunk_sigs.append(self.allocator, ChunkType.generation_data_overflow.signature());
                try chunk_sizes.append(
                    self.allocator,
                    @as(u64, prep.generation_v2_overflow_count) * commitgraph.sz_uint64,
                );
            }
        }

        try self.encodeFileHeader(@intCast(chunk_sigs.items.len));
        try self.encodeChunkHeaders(chunk_sigs.items, chunk_sizes.items);
        try self.encodeFanout(prep.fanout);

        try self.encodeOidLookup(hashes);

        var extra_edges: std.ArrayListUnmanaged(u32) = .empty;
        defer extra_edges.deinit(self.allocator);
        var generation_v2_data: std.ArrayListUnmanaged(u64) = .empty;
        defer generation_v2_data.deinit(self.allocator);

        try self.encodeCommitData(hashes, prep.hash_to_index, idx, &extra_edges, &generation_v2_data);
        try self.encodeExtraEdges(extra_edges.items);

        if (idx.hasGenerationV2()) {
            const overflows = try self.encodeGenerationV2Data(generation_v2_data.items);
            defer if (overflows.len != 0) self.allocator.free(overflows);
            try self.encodeGenerationV2Overflow(overflows);
        }

        try self.encodeChecksum();
    }

    const Prepare = struct {
        hash_to_index: std.AutoHashMapUnmanaged(Hash, u32),
        fanout: []u32,
        extra_edges_count: u32,
        generation_v2_overflow_count: u32,
    };

    fn prepare(self: *Encoder, idx: anytype, hashes: []Hash) EncodeError!Prepare {
        sortHashes(hashes);

        var hash_to_index: std.AutoHashMapUnmanaged(Hash, u32) = .empty;
        errdefer hash_to_index.deinit(self.allocator);

        const fanout = try self.allocator.alloc(u32, commitgraph.len_fanout);
        errdefer self.allocator.free(fanout);
        @memset(fanout, 0);

        for (hashes, 0..) |h, i| {
            try hash_to_index.put(self.allocator, h, @intCast(i));
            fanout[h.bytes[0]] += 1;
        }
        var fi: usize = 1;
        while (fi < commitgraph.len_fanout) : (fi += 1) {
            fanout[fi] += fanout[fi - 1];
        }

        var extra_edges_count: u32 = 0;
        var generation_v2_overflow_count: u32 = 0;
        const has_g2 = idx.hasGenerationV2();

        // Count edges over insertion / file indexes 0..n-1 (same cardinality).
        var i: u32 = 0;
        while (i < hashes.len) : (i += 1) {
            const v = try getCommitData(idx, i);
            defer releaseCommitData(idx, v);
            if (v.parent_hashes.len > 2) {
                extra_edges_count += @intCast(v.parent_hashes.len - 1);
            }
            // Match encodeGenerationV2Data threshold (go-git uses 0x80000000 there;
            // prepare in go-git uses MaxUint32 — that under-sizes GDO2 for mid-range
            // values. Use the encode threshold so chunk sizes stay consistent).
            if (has_g2 and v.generationV2Data() >= 0x80000000) {
                generation_v2_overflow_count += 1;
            }
        }

        return .{
            .hash_to_index = hash_to_index,
            .fanout = fanout,
            .extra_edges_count = extra_edges_count,
            .generation_v2_overflow_count = generation_v2_overflow_count,
        };
    }

    fn encodeFileHeader(self: *Encoder, chunk_count: u8) EncodeError!void {
        try self.writeAll(commitgraph.commit_file_signature);
        // version 1; hash version 1 = SHA-1, 2 = SHA-256 (go-git / git)
        const hash_ver: u8 = if (hash_pkg.objectFormat() == .sha256) 2 else 1;
        try self.writeAll(&[_]u8{ 1, hash_ver, chunk_count, 0 });
    }

    fn encodeChunkHeaders(self: *Encoder, sigs: []const []const u8, sizes: []const u64) EncodeError!void {
        var offset: u64 = commitgraph.sz_signature + commitgraph.sz_header +
            @as(u64, @intCast(sigs.len + 1)) * (chunk_mod.sz_chunk_sig + commitgraph.sz_uint64);
        for (sigs, sizes) |sig, size| {
            try self.writeAll(sig);
            try self.writeUint64(offset);
            offset += size;
        }
        try self.writeAll(ChunkType.zero.signature());
        try self.writeUint64(offset);
    }

    fn encodeFanout(self: *Encoder, fanout: []const u32) EncodeError!void {
        for (fanout) |v| {
            try self.writeUint32(v);
        }
    }

    fn encodeOidLookup(self: *Encoder, hashes: []const Hash) EncodeError!void {
        for (hashes) |h| {
            try self.writeAll(h.slice());
        }
    }

    fn encodeCommitData(
        self: *Encoder,
        hashes: []const Hash,
        hash_to_index: std.AutoHashMapUnmanaged(Hash, u32),
        idx: anytype,
        extra_edges: *std.ArrayListUnmanaged(u32),
        generation_v2_data: *std.ArrayListUnmanaged(u64),
    ) EncodeError!void {
        const has_g2 = idx.hasGenerationV2();
        for (hashes) |h| {
            const orig_index = try idx.getIndexByHash(h);
            const cd = try getCommitData(idx, orig_index);
            defer releaseCommitData(idx, cd);

            try self.writeAll(cd.tree_hash.slice());

            var parent1: u32 = undefined;
            var parent2: u32 = undefined;
            if (cd.parent_hashes.len == 0) {
                parent1 = commitgraph.parent_none;
                parent2 = commitgraph.parent_none;
            } else if (cd.parent_hashes.len == 1) {
                parent1 = hash_to_index.get(cd.parent_hashes[0]) orelse return Error.ObjectNotFound;
                parent2 = commitgraph.parent_none;
            } else if (cd.parent_hashes.len == 2) {
                parent1 = hash_to_index.get(cd.parent_hashes[0]) orelse return Error.ObjectNotFound;
                parent2 = hash_to_index.get(cd.parent_hashes[1]) orelse return Error.ObjectNotFound;
            } else {
                parent1 = hash_to_index.get(cd.parent_hashes[0]) orelse return Error.ObjectNotFound;
                parent2 = @as(u32, @intCast(extra_edges.items.len)) | commitgraph.parent_octopus_used;
                for (cd.parent_hashes[1..]) |ph| {
                    const pi = hash_to_index.get(ph) orelse return Error.ObjectNotFound;
                    try extra_edges.append(self.allocator, pi);
                }
                // Mark last edge.
                extra_edges.items[extra_edges.items.len - 1] |= commitgraph.parent_last;
            }

            try self.writeUint32(parent1);
            try self.writeUint32(parent2);

            const when_u: u64 = if (cd.when >= 0) @intCast(cd.when) else 0;
            var unix_time: u64 = when_u;
            unix_time |= cd.generation << 34;
            try self.writeUint64(unix_time);

            if (has_g2) {
                try generation_v2_data.append(self.allocator, cd.generationV2Data());
            }
        }
    }

    fn encodeExtraEdges(self: *Encoder, edges: []const u32) EncodeError!void {
        for (edges) |p| {
            try self.writeUint32(p);
        }
    }

    /// Returns owned overflow values (caller frees).
    fn encodeGenerationV2Data(self: *Encoder, data: []u64) EncodeError![]u64 {
        var list: std.ArrayListUnmanaged(u64) = .empty;
        errdefer list.deinit(self.allocator);

        for (data) |d| {
            if (d >= 0x80000000) {
                try self.writeUint32(@as(u32, @intCast(list.items.len)) | 0x80000000);
                try list.append(self.allocator, d);
                continue;
            }
            try self.writeUint32(@intCast(d));
        }
        return try list.toOwnedSlice(self.allocator);
    }

    fn encodeGenerationV2Overflow(self: *Encoder, overflows: []const u64) EncodeError!void {
        for (overflows) |o| {
            try self.writeUint64(o);
        }
    }

    fn encodeChecksum(self: *Encoder) EncodeError!void {
        var sum: [hash_pkg.MaxSize]u8 = undefined;
        self.hasher.final(&sum);
        const n = hash_pkg.digestSize();
        // Trailer is the hash of all preceding bytes (not including the trailer).
        try self.writer.writeAll(sum[0..n]);
    }

    fn writeAll(self: *Encoder, data: []const u8) EncodeError!void {
        try self.writer.writeAll(data);
        self.hasher.update(data);
    }

    fn writeUint32(self: *Encoder, value: u32) EncodeError!void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .big);
        try self.writeAll(&buf);
    }

    fn writeUint64(self: *Encoder, value: u64) EncodeError!void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, value, .big);
        try self.writeAll(&buf);
    }
};

fn sortHashes(hashes: []Hash) void {
    std.mem.sort(Hash, hashes, {}, struct {
        fn less(_: void, a: Hash, b: Hash) bool {
            return std.mem.order(u8, &a.bytes, &b.bytes) == .lt;
        }
    }.less);
}

/// Both MemoryIndex and FileIndex return `*CommitData` (owned by the index).
fn getCommitData(idx: anytype, i: u32) EncodeError!*const CommitData {
    return try idx.getCommitDataByIndex(i);
}

fn releaseCommitData(idx: anytype, cd: *const CommitData) void {
    _ = idx;
    _ = cd;
    // MemoryIndex / FileIndex own the data for the call duration.
}

test "Encoder MemoryIndex round-trip via FileIndex" {
    const gpa = std.testing.allocator;
    const file_mod = @import("file.zig");

    var mi = MemoryIndex.init(gpa);
    defer mi.deinit();

    const h0 = plumbing.newHash("1111111111111111111111111111111111111111");
    const h1 = plumbing.newHash("2222222222222222222222222222222222222222");
    const h2 = plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const t0 = plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    const t1 = plumbing.newHash("cccccccccccccccccccccccccccccccccccccccc");
    const t2 = plumbing.newHash("dddddddddddddddddddddddddddddddddddddddd");

    var d0: CommitData = .{
        .tree_hash = t0,
        .generation = 1,
        .generation_v2 = 1000 + 5,
        .when = 1000,
    };
    try mi.add(h0, &d0);

    var p1 = [_]Hash{h0};
    var d1: CommitData = .{
        .tree_hash = t1,
        .parent_hashes = &p1,
        .generation = 2,
        .generation_v2 = 2000 + 6,
        .when = 2000,
    };
    try mi.add(h1, &d1);

    var p2 = [_]Hash{h1};
    var d2: CommitData = .{
        .tree_hash = t2,
        .parent_hashes = &p2,
        .generation = 3,
        .generation_v2 = 3000 + 7,
        .when = 3000,
    };
    try mi.add(h2, &d2);

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = Encoder.init(gpa, &aw.writer);
    try enc.encode(&mi);

    var fi = try file_mod.FileIndex.open(gpa, aw.written());
    defer fi.deinit();

    try std.testing.expectEqual(@as(u32, 3), fi.maximumNumberOfHashes());
    try std.testing.expect(fi.hasGenerationV2());

    // Sorted OID order: 1111…, 2222…, aaaa…
    const idx0 = try fi.getIndexByHash(h0);
    const idx1 = try fi.getIndexByHash(h1);
    const idx2 = try fi.getIndexByHash(h2);
    try std.testing.expectEqual(@as(u32, 0), idx0);
    try std.testing.expectEqual(@as(u32, 1), idx1);
    try std.testing.expectEqual(@as(u32, 2), idx2);

    const cd0 = try fi.getCommitDataByIndex(0);
    try std.testing.expect(cd0.tree_hash.eql(t0));
    try std.testing.expectEqual(@as(usize, 0), cd0.parent_hashes.len);
    try std.testing.expectEqual(@as(u64, 1), cd0.generation);
    try std.testing.expectEqual(@as(i64, 1000), cd0.when);
    try std.testing.expectEqual(@as(u64, 1000 + 5), cd0.generation_v2);

    const cd1 = try fi.getCommitDataByIndex(1);
    try std.testing.expectEqual(@as(usize, 1), cd1.parent_hashes.len);
    try std.testing.expect(cd1.parent_hashes[0].eql(h0));
    try std.testing.expectEqual(@as(u64, 2), cd1.generation);

    const cd2 = try fi.getCommitDataByIndex(2);
    try std.testing.expect(cd2.tree_hash.eql(t2));
    try std.testing.expect(cd2.parent_hashes[0].eql(h1));

    const all = try fi.hashes(gpa);
    defer gpa.free(all);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expect(all[0].eql(h0));
    try std.testing.expect(all[1].eql(h1));
    try std.testing.expect(all[2].eql(h2));
}

test "Encoder octopus merge three parents" {
    const gpa = std.testing.allocator;
    const file_mod = @import("file.zig");

    var mi = MemoryIndex.init(gpa);
    defer mi.deinit();

    const ha = plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const hb = plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    const hc = plumbing.newHash("cccccccccccccccccccccccccccccccccccccccc");
    const hm = plumbing.newHash("dddddddddddddddddddddddddddddddddddddddd");
    const tree = plumbing.newHash("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee");

    // Three roots + octopus merge of all three.
    inline for (.{ ha, hb, hc }, .{ @as(i64, 10), 20, 30 }) |h, when| {
        var d: CommitData = .{
            .tree_hash = tree,
            .generation = 1,
            .generation_v2 = @as(u64, @intCast(when)) + 1,
            .when = when,
        };
        try mi.add(h, &d);
    }
    var parents = [_]Hash{ ha, hb, hc };
    var dm: CommitData = .{
        .tree_hash = tree,
        .parent_hashes = &parents,
        .generation = 2,
        .generation_v2 = 40 + 2,
        .when = 40,
    };
    try mi.add(hm, &dm);

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = Encoder.init(gpa, &aw.writer);
    try enc.encode(&mi);

    var fi = try file_mod.FileIndex.open(gpa, aw.written());
    defer fi.deinit();

    const mi_idx = try fi.getIndexByHash(hm);
    const cd = try fi.getCommitDataByIndex(mi_idx);
    try std.testing.expectEqual(@as(usize, 3), cd.parent_hashes.len);
    try std.testing.expect(cd.parent_hashes[0].eql(ha));
    try std.testing.expect(cd.parent_hashes[1].eql(hb));
    try std.testing.expect(cd.parent_hashes[2].eql(hc));
}

test "Encoder SHA-256 object format round-trip" {
    const gpa = std.testing.allocator;
    const file_mod = @import("file.zig");
    defer plumbing.setObjectFormat(.sha1);
    plumbing.setObjectFormat(.sha256);

    var mi = MemoryIndex.init(gpa);
    defer mi.deinit();

    // 64-char hex OIDs for SHA-256.
    const h0 = plumbing.parseHash("1111111111111111111111111111111111111111111111111111111111111111") catch unreachable;
    const h1 = plumbing.parseHash("2222222222222222222222222222222222222222222222222222222222222222") catch unreachable;
    const t0 = plumbing.parseHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") catch unreachable;
    const t1 = plumbing.parseHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") catch unreachable;

    var d0: CommitData = .{
        .tree_hash = t0,
        .generation = 1,
        .generation_v2 = 100 + 1,
        .when = 100,
    };
    try mi.add(h0, &d0);

    var p1 = [_]Hash{h0};
    var d1: CommitData = .{
        .tree_hash = t1,
        .parent_hashes = &p1,
        .generation = 2,
        .generation_v2 = 200 + 2,
        .when = 200,
    };
    try mi.add(h1, &d1);

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = Encoder.init(gpa, &aw.writer);
    try enc.encode(&mi);

    const written = aw.written();
    try std.testing.expectEqual(@as(u8, 2), written[5]); // hash version 2
    try std.testing.expectEqual(@as(usize, 32), hash_pkg.digestSize());
    // Trailer is 32-byte SHA-256 of body.
    try std.testing.expect(written.len >= 32);

    var fi = try file_mod.FileIndex.open(gpa, written);
    defer fi.deinit();

    try std.testing.expectEqual(@as(u32, 2), fi.maximumNumberOfHashes());
    const idx0 = try fi.getIndexByHash(h0);
    const idx1 = try fi.getIndexByHash(h1);
    try std.testing.expectEqual(@as(u32, 0), idx0);
    try std.testing.expectEqual(@as(u32, 1), idx1);

    const cd1 = try fi.getCommitDataByIndex(1);
    try std.testing.expect(cd1.tree_hash.eql(t1));
    try std.testing.expectEqual(@as(usize, 1), cd1.parent_hashes.len);
    try std.testing.expect(cd1.parent_hashes[0].eql(h0));
    try std.testing.expectEqual(@as(usize, 32), cd1.tree_hash.slice().len);
}
