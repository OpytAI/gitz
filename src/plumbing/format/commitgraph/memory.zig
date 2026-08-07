//! In-memory commit-graph index — port of go-git
//! `plumbing/format/commitgraph/v2/memory.go` (v5.19.2).

const std = @import("std");
const plumbing = @import("plumbing");

const commitgraph = @import("commitgraph.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const CommitData = commitgraph.CommitData;
const Error = commitgraph.Error;

const Entry = struct {
    hash: Hash,
    data: CommitData,
};

/// Build a commit-graph in memory for query and later encode (go-git `MemoryIndex`).
pub const MemoryIndex = struct {
    allocator: Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    index_map: std.AutoHashMapUnmanaged(Hash, u32) = .empty,
    has_generation_v2: bool = true,

    /// go-git `NewMemoryIndex`.
    pub fn init(allocator: Allocator) MemoryIndex {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryIndex) void {
        for (self.entries.items) |*e| {
            e.data.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
        self.index_map.deinit(self.allocator);
        self.* = undefined;
    }

    /// go-git `MemoryIndex.Close` — no-op (resources released via `deinit`).
    pub fn close(self: *MemoryIndex) void {
        _ = self;
    }

    /// go-git `GetIndexByHash`.
    pub fn getIndexByHash(self: *const MemoryIndex, h: Hash) Error!u32 {
        return self.index_map.get(h) orelse Error.ObjectNotFound;
    }

    /// go-git `GetHashByIndex`.
    pub fn getHashByIndex(self: *const MemoryIndex, i: u32) Error!Hash {
        if (i >= self.entries.items.len) return Error.ObjectNotFound;
        return self.entries.items[i].hash;
    }

    /// go-git `GetCommitDataByIndex`.
    ///
    /// Lazily fills `parent_indexes` from `parent_hashes`. Returns a pointer
    /// into this index; do not free. Parent index resolution may allocate.
    pub fn getCommitDataByIndex(self: *MemoryIndex, i: u32) Error!*CommitData {
        if (i >= self.entries.items.len) return Error.ObjectNotFound;

        const entry = &self.entries.items[i];
        if (entry.data.parent_indexes.len == 0 and entry.data.parent_hashes.len != 0) {
            const parent_indexes = self.allocator.alloc(u32, entry.data.parent_hashes.len) catch
                return Error.MalformedCommitGraphFile;
            errdefer self.allocator.free(parent_indexes);

            for (entry.data.parent_hashes, 0..) |ph, j| {
                parent_indexes[j] = try self.getIndexByHash(ph);
            }

            // Free previous empty/owned indexes if any.
            if (entry.data.owns_parents and entry.data.parent_indexes.len != 0) {
                self.allocator.free(entry.data.parent_indexes);
            }
            entry.data.parent_indexes = parent_indexes;
            entry.data.owns_parents = true;
        }

        return &entry.data;
    }

    /// go-git `Hashes` — unordered set of hashes present in the index.
    pub fn hashes(self: *const MemoryIndex, allocator: Allocator) Allocator.Error![]Hash {
        var out = try allocator.alloc(Hash, self.index_map.count());
        var it = self.index_map.keyIterator();
        var n: usize = 0;
        while (it.next()) |k| {
            out[n] = k.*;
            n += 1;
        }
        return out;
    }

    /// go-git `Add`.
    ///
    /// Copies parent hashes into owned storage. Parent indexes are cleared
    /// and filled lazily in `getCommitDataByIndex` (allows out-of-order Add).
    pub fn add(self: *MemoryIndex, hash: Hash, data: *const CommitData) Allocator.Error!void {
        var stored: CommitData = .{
            .tree_hash = data.tree_hash,
            .parent_indexes = &.{},
            .parent_hashes = &.{},
            .generation = data.generation,
            .generation_v2 = data.generation_v2,
            .when = data.when,
            .owns_parents = false,
        };

        if (data.parent_hashes.len != 0) {
            stored.parent_hashes = try self.allocator.dupe(Hash, data.parent_hashes);
            stored.owns_parents = true;
        }

        // go-git: if GenerationV2 is MaxUint64, reset to zero.
        if (stored.generation_v2 == std.math.maxInt(u64)) {
            stored.generation_v2 = 0;
        }
        self.has_generation_v2 = self.has_generation_v2 and stored.generation_v2 != 0;

        const idx: u32 = @intCast(self.entries.items.len);
        try self.entries.append(self.allocator, .{ .hash = hash, .data = stored });
        try self.index_map.put(self.allocator, hash, idx);
    }

    /// go-git `HasGenerationV2`.
    pub fn hasGenerationV2(self: *const MemoryIndex) bool {
        return self.has_generation_v2;
    }

    /// go-git `MaximumNumberOfHashes`.
    pub fn maximumNumberOfHashes(self: *const MemoryIndex) u32 {
        return @intCast(self.index_map.count());
    }
};

test "MemoryIndex three commits" {
    const gpa = std.testing.allocator;

    var mi = MemoryIndex.init(gpa);
    defer mi.deinit();

    const h0 = plumbing.newHash("1111111111111111111111111111111111111111");
    const h1 = plumbing.newHash("2222222222222222222222222222222222222222");
    const h2 = plumbing.newHash("3333333333333333333333333333333333333333");
    const t0 = plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const t1 = plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    const t2 = plumbing.newHash("cccccccccccccccccccccccccccccccccccccccc");

    // Root commit, generation 1, with generation v2.
    var d0: CommitData = .{
        .tree_hash = t0,
        .generation = 1,
        .generation_v2 = 1000 + 1,
        .when = 1000,
    };
    try mi.add(h0, &d0);

    var parents1 = [_]Hash{h0};
    var d1: CommitData = .{
        .tree_hash = t1,
        .parent_hashes = &parents1,
        .generation = 2,
        .generation_v2 = 2000 + 2,
        .when = 2000,
    };
    try mi.add(h1, &d1);

    var parents2 = [_]Hash{ h1, h0 };
    var d2: CommitData = .{
        .tree_hash = t2,
        .parent_hashes = &parents2,
        .generation = 3,
        .generation_v2 = 3000 + 3,
        .when = 3000,
    };
    try mi.add(h2, &d2);

    try std.testing.expect(mi.hasGenerationV2());
    try std.testing.expectEqual(@as(u32, 3), mi.maximumNumberOfHashes());

    const idx0 = try mi.getIndexByHash(h0);
    const idx1 = try mi.getIndexByHash(h1);
    const idx2 = try mi.getIndexByHash(h2);
    try std.testing.expectEqual(@as(u32, 0), idx0);
    try std.testing.expectEqual(@as(u32, 1), idx1);
    try std.testing.expectEqual(@as(u32, 2), idx2);

    try std.testing.expect((try mi.getHashByIndex(0)).eql(h0));
    try std.testing.expect((try mi.getHashByIndex(1)).eql(h1));
    try std.testing.expect((try mi.getHashByIndex(2)).eql(h2));

    const cd0 = try mi.getCommitDataByIndex(0);
    try std.testing.expectEqual(@as(usize, 0), cd0.parent_hashes.len);
    try std.testing.expectEqual(@as(u64, 1), cd0.generation);

    const cd1 = try mi.getCommitDataByIndex(1);
    try std.testing.expectEqual(@as(usize, 1), cd1.parent_hashes.len);
    try std.testing.expectEqual(@as(usize, 1), cd1.parent_indexes.len);
    try std.testing.expectEqual(@as(u32, 0), cd1.parent_indexes[0]);
    try std.testing.expect(cd1.parent_hashes[0].eql(h0));

    const cd2 = try mi.getCommitDataByIndex(2);
    try std.testing.expectEqual(@as(usize, 2), cd2.parent_hashes.len);
    try std.testing.expectEqual(@as(u32, 1), cd2.parent_indexes[0]);
    try std.testing.expectEqual(@as(u32, 0), cd2.parent_indexes[1]);

    const all = try mi.hashes(gpa);
    defer gpa.free(all);
    try std.testing.expectEqual(@as(usize, 3), all.len);

    try std.testing.expectError(Error.ObjectNotFound, mi.getIndexByHash(plumbing.ZeroHash));
}
