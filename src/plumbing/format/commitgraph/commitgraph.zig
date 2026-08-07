//! Commit-graph types and wire constants (go-git v2 API).
//!
//! Port of go-git v5.19.2 `plumbing/format/commitgraph/v2/commitgraph.go`
//! and shared constants from `file.go`. Prefer v2 types (`uint32` indexes,
//! `uint64` generation, `GenerationV2`).

const std = @import("std");
const plumbing = @import("plumbing");

const err_mod = @import("error.zig");

pub const Error = err_mod.Error;
pub const Hash = plumbing.Hash;
pub const hash_size: usize = plumbing.Size;

// ---------------------------------------------------------------------------
// Wire constants (go-git file.go)
// ---------------------------------------------------------------------------

/// File magic `CGPH` (go-git `commitFileSignature`).
pub const commit_file_signature: *const [4]u8 = "CGPH";

/// Parent slot empty (go-git `parentNone`).
pub const parent_none: u32 = 0x70000000;
/// Second parent has more edges in EDGE chunk (go-git `parentOctopusUsed`).
pub const parent_octopus_used: u32 = 0x80000000;
/// Mask parent index bits (go-git `parentOctopusMask`).
pub const parent_octopus_mask: u32 = 0x7fffffff;
/// Last extra-edge entry flag (go-git `parentLast`).
pub const parent_last: u32 = 0x80000000;

pub const sz_uint32: usize = 4;
pub const sz_uint64: usize = 8;
pub const sz_signature: usize = 4;
pub const sz_header: usize = 4;
/// Parent1 + parent2 + genAndTime (go-git `szCommitData`).
pub const sz_commit_data: usize = 2 * sz_uint32 + sz_uint64;
pub const len_fanout: usize = 256;

// ---------------------------------------------------------------------------
// CommitData
// ---------------------------------------------------------------------------

/// Reduced commit node as stored in the commit-graph (go-git v2 `CommitData`).
///
/// `when` is Unix seconds (go-git `time.Time` via `Unix()`).
/// Owned parent slices are freed with `deinit` when `owns_parents` is true.
pub const CommitData = struct {
    tree_hash: Hash = plumbing.ZeroHash,
    parent_indexes: []u32 = &.{},
    parent_hashes: []Hash = &.{},
    generation: u64 = 0,
    generation_v2: u64 = 0,
    /// Commit timestamp (seconds since Unix epoch).
    when: i64 = 0,
    /// When true, `deinit` frees parent slices.
    owns_parents: bool = false,

    /// go-git `CommitData.GenerationV2Data` — corrected commit date delta.
    pub fn generationV2Data(self: *const CommitData) u64 {
        if (self.generation_v2 == 0 or self.generation_v2 == std.math.maxInt(u64)) {
            return 0;
        }
        if (self.when < 0) return self.generation_v2;
        return self.generation_v2 - @as(u64, @intCast(self.when));
    }

    /// Free owned parent slices.
    pub fn deinit(self: *CommitData, allocator: std.mem.Allocator) void {
        if (self.owns_parents) {
            if (self.parent_indexes.len != 0) allocator.free(self.parent_indexes);
            if (self.parent_hashes.len != 0) allocator.free(self.parent_hashes);
        }
        self.parent_indexes = &.{};
        self.parent_hashes = &.{};
        self.owns_parents = false;
    }

    /// Deep-copy parent slices into `allocator`-owned storage.
    pub fn cloneParents(self: *CommitData, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        const pi = try allocator.dupe(u32, self.parent_indexes);
        errdefer allocator.free(pi);
        const ph = try allocator.dupe(Hash, self.parent_hashes);
        self.parent_indexes = pi;
        self.parent_hashes = ph;
        self.owns_parents = true;
    }
};

// ---------------------------------------------------------------------------
// Index surface (documented; concrete types in memory.zig / file.zig)
// ---------------------------------------------------------------------------

/// Documented Index API (go-git v2 `Index`):
/// - `getIndexByHash`
/// - `getHashByIndex`
/// - `getCommitDataByIndex`
/// - `hashes`
/// - `hasGenerationV2`
/// - `maximumNumberOfHashes`
/// - `close`
pub const Index = struct {
    // Zig has no Go-style interface; MemoryIndex and FileIndex implement these
    // methods. Encoder accepts `anytype` with that surface.
};
