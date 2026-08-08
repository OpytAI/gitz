//! Commit-graph file index — port of go-git
//! `plumbing/format/commitgraph/v2/file.go` (v5.19.2).
//!
//! Opens a serialized commit-graph and serves Index lookups against the held
//! buffer. Optional parent support enables commit-graph chains
//! (`OpenFileIndexWithParent`).

const std = @import("std");
const plumbing = @import("plumbing");

const commitgraph = @import("commitgraph.zig");
const chunk_mod = @import("chunk.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const CommitData = commitgraph.CommitData;
const ChunkType = chunk_mod.ChunkType;
const Error = commitgraph.Error;

/// Random-access commit-graph over an in-memory buffer (go-git `fileIndex`).
///
/// When `parent` is set, this index is layered on top of an older graph in a
/// chain: local hashes occupy indices `[minimum_number_of_hashes, ...)`.
pub const FileIndex = struct {
    allocator: Allocator,
    /// Full file bytes (owned).
    data: []u8,
    fanout: [commitgraph.len_fanout]u32 = .{0} ** commitgraph.len_fanout,
    offsets: [ChunkType.len_chunks]i64 = .{0} ** ChunkType.len_chunks,
    has_generation_v2: bool = false,
    /// Owned parent graph in a chain (go-git `fileIndex.parent`), or null.
    parent: ?*FileIndex = null,
    /// Hash count in parent (go-git `minimumNumberOfHashes`).
    minimum_number_of_hashes: u32 = 0,
    /// Cached last CommitData for pointer-stable `getCommitDataByIndex`.
    cache: ?CommitData = null,

    /// Open from a complete commit-graph byte slice (copies into owned buffer).
    /// go-git `OpenFileIndex` without parent.
    pub fn open(allocator: Allocator, raw: []const u8) Error!FileIndex {
        return openWithParent(allocator, raw, null);
    }

    /// go-git `OpenFileIndexWithParent`.
    ///
    /// Takes ownership of `parent` when non-null; `parent` must be heap-
    /// allocated with `allocator.create(FileIndex)`. On success, `deinit`
    /// closes the parent chain. On failure, `parent` is not freed (caller keeps it).
    pub fn openWithParent(allocator: Allocator, raw: []const u8, parent: ?*FileIndex) Error!FileIndex {
        const data = allocator.dupe(u8, raw) catch return Error.MalformedCommitGraphFile;
        errdefer allocator.free(data);

        var fi: FileIndex = .{
            .allocator = allocator,
            .data = data,
            .parent = parent,
        };
        try fi.verifyFileHeader();
        try fi.readChunkHeaders();
        try fi.readFanout();
        fi.has_generation_v2 = fi.offsets[@intFromEnum(ChunkType.generation_data)] > 0;
        if (parent) |p| {
            fi.has_generation_v2 = fi.has_generation_v2 and p.hasGenerationV2();
            fi.minimum_number_of_hashes = p.maximumNumberOfHashes();
        }
        return fi;
    }

    /// Open from a streaming reader (reads all remaining bytes).
    pub fn openReader(allocator: Allocator, reader: *std.Io.Reader) Error!FileIndex {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        while (true) {
            var tmp: [4096]u8 = undefined;
            const n = reader.readSliceShort(&tmp) catch return Error.MalformedCommitGraphFile;
            if (n == 0) break;
            aw.writer.writeAll(tmp[0..n]) catch return Error.MalformedCommitGraphFile;
        }
        return open(allocator, aw.written());
    }

    /// Coalesce a chain of graph file bodies (oldest first) without billy FS.
    /// Pure-byte alternative to go-git `OpenChainIndex`.
    ///
    /// Empty `graphs` returns `error.MalformedCommitGraphFile` (unlike go-git
    /// which can return a nil Index for an empty chain).
    pub fn openChainIndexFromBytes(allocator: Allocator, graphs: []const []const u8) Error!FileIndex {
        if (graphs.len == 0) return Error.MalformedCommitGraphFile;

        var current: ?FileIndex = null;
        errdefer if (current) |*c| c.deinit();

        for (graphs) |raw| {
            var parent_ptr: ?*FileIndex = null;
            if (current) |prev| {
                const boxed = allocator.create(FileIndex) catch return Error.MalformedCommitGraphFile;
                boxed.* = prev;
                parent_ptr = boxed;
                current = null;
            }
            // On open failure after boxing parent, free the boxed parent.
            current = openWithParent(allocator, raw, parent_ptr) catch |e| {
                if (parent_ptr) |p| {
                    p.deinit();
                    allocator.destroy(p);
                }
                return e;
            };
        }
        return current.?;
    }

    pub fn deinit(self: *FileIndex) void {
        self.clearCache();
        self.allocator.free(self.data);
        if (self.parent) |p| {
            p.deinit();
            self.allocator.destroy(p);
        }
        self.* = undefined;
    }

    /// go-git `Close`.
    pub fn close(self: *FileIndex) void {
        self.deinit();
    }

    fn clearCache(self: *FileIndex) void {
        if (self.cache) |*c| {
            c.deinit(self.allocator);
            self.cache = null;
        }
    }

    fn verifyFileHeader(self: *FileIndex) Error!void {
        if (self.data.len < commitgraph.sz_signature + commitgraph.sz_header) {
            return Error.MalformedCommitGraphFile;
        }
        if (!std.mem.eql(u8, self.data[0..4], commitgraph.commit_file_signature)) {
            return Error.MalformedCommitGraphFile;
        }
        const header = self.data[4..8];
        if (header[0] != 1) return Error.UnsupportedVersion;
        // Hash version 1 = SHA-1, 2 = SHA-256 (go-git verifies against CryptoType).
        const hv = header[1];
        const fmt = plumbing.objectFormat();
        const ok = (fmt == .sha1 and hv == 1) or (fmt == .sha256 and hv == 2);
        if (!ok) return Error.UnsupportedHash;
    }

    fn readChunkHeaders(self: *FileIndex) Error!void {
        var i: usize = 0;
        while (true) : (i += 1) {
            const base = commitgraph.sz_signature + commitgraph.sz_header +
                i * (chunk_mod.sz_chunk_sig + commitgraph.sz_uint64);
            if (base + chunk_mod.sz_chunk_sig + commitgraph.sz_uint64 > self.data.len) {
                return Error.MalformedCommitGraphFile;
            }
            const chunk_id = self.data[base .. base + chunk_mod.sz_chunk_sig];
            const chunk_offset = std.mem.readInt(u64, self.data[base + 4 ..][0..8], .big);

            const ct = ChunkType.fromBytes(chunk_id) orelse continue;
            if (ct == .zero or @intFromEnum(ct) >= ChunkType.len_chunks) break;
            self.offsets[@as(usize, @intCast(@intFromEnum(ct)))] = @intCast(chunk_offset);
        }

        if (self.offsets[@intFromEnum(ChunkType.oid_fanout)] <= 0 or
            self.offsets[@intFromEnum(ChunkType.oid_lookup)] <= 0 or
            self.offsets[@intFromEnum(ChunkType.commit_data)] <= 0)
        {
            return Error.MalformedCommitGraphFile;
        }
    }

    fn readFanout(self: *FileIndex) Error!void {
        const off: usize = @intCast(self.offsets[@intFromEnum(ChunkType.oid_fanout)]);
        if (off + commitgraph.len_fanout * commitgraph.sz_uint32 > self.data.len) {
            return Error.MalformedCommitGraphFile;
        }
        var i: usize = 0;
        while (i < commitgraph.len_fanout) : (i += 1) {
            const v = std.mem.readInt(u32, self.data[off + i * 4 ..][0..4], .big);
            if (v > 0x7fffffff) return Error.MalformedCommitGraphFile;
            self.fanout[i] = v;
        }
    }

    fn readHashAt(self: *const FileIndex, offset: usize) Error!Hash {
        const hs = commitgraph.hashSize();
        if (offset + hs > self.data.len) return Error.MalformedCommitGraphFile;
        var bytes: [plumbing.MaxSize]u8 = .{0} ** plumbing.MaxSize;
        @memcpy(bytes[0..hs], self.data[offset .. offset + hs]);
        return Hash.fromBytes(bytes[0..hs]);
    }

    /// go-git `GetIndexByHash`.
    pub fn getIndexByHash(self: *const FileIndex, h: Hash) Error!u32 {
        var low: u32 = if (h.bytes[0] == 0) 0 else self.fanout[h.bytes[0] - 1];
        var high: u32 = self.fanout[h.bytes[0]];
        const oid_off: usize = @intCast(self.offsets[@intFromEnum(ChunkType.oid_lookup)]);

        while (low < high) {
            const mid = (low + high) >> 1;
            const offset = oid_off + @as(usize, mid) * commitgraph.hashSize();
            const oid = try self.readHashAt(offset);
            const cmp = std.mem.order(u8, &h.bytes, &oid.bytes);
            if (cmp == .lt) {
                high = mid;
            } else if (cmp == .eq) {
                return mid + self.minimum_number_of_hashes;
            } else {
                low = mid + 1;
            }
        }

        if (self.parent) |p| {
            return p.getIndexByHash(h);
        }
        return Error.ObjectNotFound;
    }

    /// go-git `GetHashByIndex`.
    pub fn getHashByIndex(self: *const FileIndex, idx: u32) Error!Hash {
        if (idx < self.minimum_number_of_hashes) {
            if (self.parent) |p| {
                return p.getHashByIndex(idx);
            }
            return Error.MalformedCommitGraphFile;
        }
        const local = idx - self.minimum_number_of_hashes;
        if (local >= self.fanout[0xff]) return Error.MalformedCommitGraphFile;
        const oid_off: usize = @intCast(self.offsets[@intFromEnum(ChunkType.oid_lookup)]);
        return self.readHashAt(oid_off + @as(usize, local) * commitgraph.hashSize());
    }

    /// go-git `GetCommitDataByIndex`.
    ///
    /// Returns a pointer into an internal cache (valid until the next call or
    /// `deinit`). When the index falls in the parent range, delegates to the
    /// parent (parent cache may also change). Matches the Index surface used
    /// by `Encoder`.
    pub fn getCommitDataByIndex(self: *FileIndex, idx: u32) Error!*CommitData {
        if (idx < self.minimum_number_of_hashes) {
            if (self.parent) |p| {
                return p.getCommitDataByIndex(idx);
            }
            return Error.ObjectNotFound;
        }
        const local = idx - self.minimum_number_of_hashes;
        if (local >= self.fanout[0xff]) return Error.ObjectNotFound;

        self.clearCache();

        const cdat_off: usize = @intCast(self.offsets[@intFromEnum(ChunkType.commit_data)]);
        const hs = commitgraph.hashSize();
        const entry_size = hs + commitgraph.sz_commit_data;
        const offset = cdat_off + @as(usize, local) * entry_size;
        if (offset + entry_size > self.data.len) return Error.MalformedCommitGraphFile;

        const tree_hash = try self.readHashAt(offset);
        const parent1 = std.mem.readInt(u32, self.data[offset + hs ..][0..4], .big);
        const parent2 = std.mem.readInt(u32, self.data[offset + hs + 4 ..][0..4], .big);
        const gen_and_time = std.mem.readInt(
            u64,
            self.data[offset + hs + 8 ..][0..8],
            .big,
        );

        var parent_indexes: []u32 = &.{};
        var owns_parents = false;
        if (parent2 & commitgraph.parent_octopus_used == commitgraph.parent_octopus_used) {
            var list: std.ArrayListUnmanaged(u32) = .empty;
            errdefer list.deinit(self.allocator);
            list.append(self.allocator, parent1 & commitgraph.parent_octopus_mask) catch
                return Error.MalformedCommitGraphFile;

            var edge_off: usize = @intCast(self.offsets[@intFromEnum(ChunkType.extra_edge_list)]);
            edge_off += commitgraph.sz_uint32 * @as(usize, parent2 & commitgraph.parent_octopus_mask);
            while (true) {
                if (edge_off + 4 > self.data.len) return Error.MalformedCommitGraphFile;
                const parent = std.mem.readInt(u32, self.data[edge_off..][0..4], .big);
                edge_off += 4;
                list.append(self.allocator, parent & commitgraph.parent_octopus_mask) catch
                    return Error.MalformedCommitGraphFile;
                if (parent & commitgraph.parent_last == commitgraph.parent_last) break;
            }
            parent_indexes = list.toOwnedSlice(self.allocator) catch return Error.MalformedCommitGraphFile;
            owns_parents = true;
        } else if (parent2 != commitgraph.parent_none) {
            parent_indexes = self.allocator.alloc(u32, 2) catch return Error.MalformedCommitGraphFile;
            parent_indexes[0] = parent1 & commitgraph.parent_octopus_mask;
            parent_indexes[1] = parent2 & commitgraph.parent_octopus_mask;
            owns_parents = true;
        } else if (parent1 != commitgraph.parent_none) {
            parent_indexes = self.allocator.alloc(u32, 1) catch return Error.MalformedCommitGraphFile;
            parent_indexes[0] = parent1 & commitgraph.parent_octopus_mask;
            owns_parents = true;
        }

        const parent_hashes = self.getHashesFromIndexes(parent_indexes) catch |e| {
            if (owns_parents) self.allocator.free(parent_indexes);
            return e;
        };
        if (parent_hashes.len != 0) owns_parents = true;

        var generation_v2: u64 = 0;
        if (self.has_generation_v2) {
            generation_v2 = gen_and_time & 0x3_ffffffff;
            const gda_off: usize = @intCast(self.offsets[@intFromEnum(ChunkType.generation_data)]);
            const g_off = gda_off + @as(usize, local) * commitgraph.sz_uint32;
            if (g_off + 4 > self.data.len) {
                freeParents(self.allocator, parent_indexes, parent_hashes, owns_parents);
                return Error.MalformedCommitGraphFile;
            }
            const gen_v2_data = std.mem.readInt(u32, self.data[g_off..][0..4], .big);
            if (gen_v2_data & 0x80000000 != 0) {
                const gdo_off: usize = @intCast(self.offsets[@intFromEnum(ChunkType.generation_data_overflow)]);
                const o_off = gdo_off + @as(usize, gen_v2_data & 0x7fffffff) * commitgraph.sz_uint64;
                if (o_off + 8 > self.data.len) {
                    freeParents(self.allocator, parent_indexes, parent_hashes, owns_parents);
                    return Error.MalformedCommitGraphFile;
                }
                generation_v2 += std.mem.readInt(u64, self.data[o_off..][0..8], .big);
            } else {
                generation_v2 += gen_v2_data;
            }
        }

        self.cache = .{
            .tree_hash = tree_hash,
            .parent_indexes = parent_indexes,
            .parent_hashes = parent_hashes,
            .generation = gen_and_time >> 34,
            .generation_v2 = generation_v2,
            .when = @intCast(gen_and_time & 0x3_ffffffff),
            .owns_parents = owns_parents,
        };
        return &self.cache.?;
    }

    fn freeParents(allocator: Allocator, indexes: []u32, hash_list: []Hash, owns: bool) void {
        if (!owns) return;
        if (indexes.len != 0) allocator.free(indexes);
        if (hash_list.len != 0) allocator.free(hash_list);
    }

    fn getHashesFromIndexes(self: *const FileIndex, indexes: []const u32) Error![]Hash {
        if (indexes.len == 0) return &.{};
        const parent_hashes = self.allocator.alloc(Hash, indexes.len) catch return Error.MalformedCommitGraphFile;
        errdefer self.allocator.free(parent_hashes);
        const oid_off: usize = @intCast(self.offsets[@intFromEnum(ChunkType.oid_lookup)]);
        for (indexes, 0..) |pi, i| {
            if (pi < self.minimum_number_of_hashes) {
                if (self.parent) |p| {
                    parent_hashes[i] = try p.getHashByIndex(pi);
                    continue;
                }
                return Error.MalformedCommitGraphFile;
            }
            const local = pi - self.minimum_number_of_hashes;
            if (local >= self.fanout[0xff]) return Error.MalformedCommitGraphFile;
            parent_hashes[i] = try self.readHashAt(oid_off + @as(usize, local) * commitgraph.hashSize());
        }
        return parent_hashes;
    }

    /// go-git `Hashes` — parent hashes then local OID lookup order.
    pub fn hashes(self: *const FileIndex, allocator: Allocator) (Error || Allocator.Error)![]Hash {
        const n = self.maximumNumberOfHashes();
        var out = try allocator.alloc(Hash, n);
        errdefer allocator.free(out);

        var i: u32 = 0;
        while (i < self.minimum_number_of_hashes) : (i += 1) {
            out[i] = try self.parent.?.getHashByIndex(i);
        }

        const oid_off: usize = @intCast(self.offsets[@intFromEnum(ChunkType.oid_lookup)]);
        const local_n = self.fanout[0xff];
        const hs = commitgraph.hashSize();
        var j: u32 = 0;
        while (j < local_n) : (j += 1) {
            out[self.minimum_number_of_hashes + j] =
                try self.readHashAt(oid_off + @as(usize, j) * hs);
        }
        return out;
    }

    /// go-git `HasGenerationV2`.
    pub fn hasGenerationV2(self: *const FileIndex) bool {
        return self.has_generation_v2;
    }

    /// go-git `MaximumNumberOfHashes`.
    pub fn maximumNumberOfHashes(self: *const FileIndex) u32 {
        return self.minimum_number_of_hashes + self.fanout[0xff];
    }
};

test "FileIndex rejects bad signature" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        Error.MalformedCommitGraphFile,
        FileIndex.open(gpa, "not a commit graph file!!!!"),
    );
}

test "openChainIndexFromBytes empty rejected" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        Error.MalformedCommitGraphFile,
        FileIndex.openChainIndexFromBytes(gpa, &.{}),
    );
}
