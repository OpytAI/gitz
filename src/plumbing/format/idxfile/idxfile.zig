//! Pack index (idx) v2 in-memory model — port of go-git
//! `plumbing/format/idxfile/idxfile.go` (v5.19.2).

const std = @import("std");
const plumbing = @import("plumbing");

const Allocator = std.mem.Allocator;

/// Only idx version supported (go-git `VersionSupported`).
pub const VersionSupported: u32 = 2;

/// Magic header for pack idx v2: `\377tOc` (go-git `idxHeader`).
pub const idxHeader: *const [4]u8 = &[_]u8{ 255, 't', 'O', 'c' };

pub const fanout: usize = 256;
/// OID wire length for pack indexes — follows active object format (SHA-1/SHA-256).
pub fn objectIdLength() usize {
    return plumbing.digestSize();
}
/// Sparse bucket sentinel (internal layout; exported for decoder/encoder/writer).
pub const noMapping: i32 = -1;

const is_o64_mask: u64 = @as(u64, 1) << 31;

pub const Error = error{
    /// go-git `ErrUnsupportedVersion`.
    UnsupportedVersion,
    /// go-git `ErrMalformedIdxFile`.
    MalformedIdxFile,
    /// go-git `plumbing.ErrObjectNotFound`.
    ObjectNotFound,
    /// Writer.Index before OnFooter / finished.
    IndexNotFinished,
};

/// One object entry in a pack index (go-git `Entry`).
pub const Entry = struct {
    hash: plumbing.Hash,
    crc32: u32,
    offset: u64,
};

/// In-memory pack idx v2 (go-git `MemoryIndex`).
///
/// Names / Offset32 / CRC32 use sparse buckets: only fanout slots that hold
/// objects get a mapping into these lists (`fanout_mapping`).
pub const MemoryIndex = struct {
    allocator: Allocator,
    version: u32 = 0,
    fanout: [fanout]u32 = .{0} ** fanout,
    /// Maps fanout bucket → index in names/offset32/crc32, or `noMapping`.
    fanout_mapping: [fanout]i32 = .{noMapping} ** fanout,
    names: std.ArrayListUnmanaged([]u8) = .empty,
    offset32: std.ArrayListUnmanaged([]u8) = .empty,
    crc32: std.ArrayListUnmanaged([]u8) = .empty,
    offset64: []u8 = &.{},
    packfile_checksum: plumbing.Hash = plumbing.ZeroHash,
    idx_checksum: plumbing.Hash = plumbing.ZeroHash,

    offset_hash: ?std.AutoHashMap(i64, plumbing.Hash) = null,
    offset_hash_built: bool = false,

    /// go-git `NewMemoryIndex`.
    pub fn init(allocator: Allocator) MemoryIndex {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryIndex) void {
        // Free only non-empty slices (empty may be static `&.{}` from Writer).
        for (self.names.items) |n| {
            if (n.len != 0) self.allocator.free(n);
        }
        self.names.deinit(self.allocator);
        for (self.offset32.items) |o| {
            if (o.len != 0) self.allocator.free(o);
        }
        self.offset32.deinit(self.allocator);
        for (self.crc32.items) |c| {
            if (c.len != 0) self.allocator.free(c);
        }
        self.crc32.deinit(self.allocator);
        if (self.offset64.len != 0) self.allocator.free(self.offset64);
        if (self.offset_hash) |*m| m.deinit();
        self.* = undefined;
    }

    fn findHashIndex(self: *const MemoryIndex, h: plumbing.Hash) ?usize {
        const k = self.fanout_mapping[h.bytes[0]];
        if (k == noMapping) return null;
        const ki: usize = @intCast(k);
        if (ki >= self.names.items.len) return null;

        const data = self.names.items[ki];
        var high: u64 = self.offset32.items[ki].len >> 2;
        if (high == 0) return null;

        var low: u64 = 0;
        while (true) {
            const mid = (low + high) >> 1;
            const oid_len = objectIdLength();
            const offset = mid * oid_len;
            const cmp = std.mem.order(u8, h.slice(), data[offset .. offset + oid_len]);
            if (cmp == .lt) {
                high = mid;
            } else if (cmp == .eq) {
                return @intCast(mid);
            } else {
                low = mid + 1;
            }
            if (low >= high) break;
        }
        return null;
    }

    /// go-git `Contains`.
    pub fn contains(self: *const MemoryIndex, h: plumbing.Hash) bool {
        return self.findHashIndex(h) != null;
    }

    /// go-git `FindOffset`.
    ///
    /// Incrementally seeds `offset_hash` for reverse lookup. Put failures
    /// (OOM) are swallowed: reverse map is best-effort until `genOffsetHash`
    /// rebuilds it fully for `findHash`.
    pub fn findOffset(self: *MemoryIndex, h: plumbing.Hash) Error!i64 {
        const k = self.fanout_mapping[h.bytes[0]];
        const i = self.findHashIndex(h) orelse return Error.ObjectNotFound;
        const offset = try self.getOffset(@intCast(k), i);

        if (self.offset_hash == null) {
            self.offset_hash = std.AutoHashMap(i64, plumbing.Hash).init(self.allocator);
        }
        // Store canonical form so dirty pad on caller Hash cannot poison the map.
        self.offset_hash.?.put(@intCast(offset), plumbing.Hash.fromBytes(h.slice())) catch {};
        return @intCast(offset);
    }

    fn getOffset(self: *const MemoryIndex, first_level: usize, second_level: usize) Error!u64 {
        const byte_off = second_level << 2;
        const ofs = std.mem.readInt(u32, self.offset32.items[first_level][byte_off ..][0..4], .big);

        if ((@as(u64, ofs) & is_o64_mask) != 0) {
            const o64_off = 8 * (@as(u64, ofs) & ~is_o64_mask);
            const l: u64 = self.offset64.len;
            if (l < 8 or o64_off > l - 8) return Error.MalformedIdxFile;
            return std.mem.readInt(u64, self.offset64[@intCast(o64_off)..][0..8], .big);
        }
        return ofs;
    }

    /// go-git `FindCRC32`.
    pub fn findCRC32(self: *const MemoryIndex, h: plumbing.Hash) Error!u32 {
        const k = self.fanout_mapping[h.bytes[0]];
        const i = self.findHashIndex(h) orelse return Error.ObjectNotFound;
        return self.getCRC32(@intCast(k), i);
    }

    fn getCRC32(self: *const MemoryIndex, first_level: usize, second_level: usize) u32 {
        const byte_off = second_level << 2;
        return std.mem.readInt(u32, self.crc32.items[first_level][byte_off ..][0..4], .big);
    }

    /// go-git `FindHash` (reverse offset lookup).
    pub fn findHash(self: *MemoryIndex, o: i64) (Error || Allocator.Error)!plumbing.Hash {
        if (!self.offset_hash_built) {
            try self.genOffsetHash();
            self.offset_hash_built = true;
        }
        const map = self.offset_hash orelse return Error.ObjectNotFound;
        return map.get(o) orelse Error.ObjectNotFound;
    }

    fn genOffsetHash(self: *MemoryIndex) (Error || Allocator.Error)!void {
        const n = try self.count();
        var map = std.AutoHashMap(i64, plumbing.Hash).init(self.allocator);
        errdefer map.deinit();
        try map.ensureTotalCapacity(@intCast(n));

        var i: u32 = 0;
        var first_level: usize = 0;
        while (first_level < fanout) : (first_level += 1) {
            const fanout_value = self.fanout[first_level];
            const mapped = self.fanout_mapping[first_level];
            var second_level: u32 = 0;
            while (i < fanout_value) {
                const mi: usize = @intCast(mapped);
                const oid_len = objectIdLength();
                const name_off = @as(usize, second_level) * oid_len;
                const hash = plumbing.Hash.fromBytes(self.names.items[mi][name_off .. name_off + oid_len]);
                const off = try self.getOffset(mi, second_level);
                try map.put(@intCast(off), hash);
                i += 1;
                second_level += 1;
            }
        }

        if (self.offset_hash) |*old| old.deinit();
        self.offset_hash = map;
    }

    /// go-git `Count`.
    pub fn count(self: *const MemoryIndex) Error!i64 {
        return self.fanout[fanout - 1];
    }

    /// go-git `Entries` — hash-order iterator.
    pub fn entries(self: *const MemoryIndex) EntryIterator {
        return .{ .idx = self };
    }

    /// go-git `EntriesByOffset` — allocates a sorted entry list.
    pub fn entriesByOffset(self: *const MemoryIndex) (Error || Allocator.Error)!OffsetEntryIterator {
        const n: usize = @intCast(try self.count());
        const list = try self.allocator.alloc(Entry, n);
        errdefer self.allocator.free(list);

        var iter = self.entries();
        var pos: usize = 0;
        while (pos < n) : (pos += 1) {
            list[pos] = (try iter.next()) orelse return Error.MalformedIdxFile;
        }

        std.mem.sort(Entry, list, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return a.offset < b.offset;
            }
        }.less);

        return .{
            .entries = list,
            .pos = 0,
            .allocator = self.allocator,
        };
    }
};

/// Hash-order entry iterator (go-git `idxfileEntryIter`).
pub const EntryIterator = struct {
    idx: *const MemoryIndex,
    total: u32 = 0,
    first_level: usize = 0,
    second_level: usize = 0,

    /// Next entry, or `null` at end (go-git returns `io.EOF`).
    pub fn next(self: *EntryIterator) Error!?Entry {
        while (true) {
            if (self.first_level >= fanout) return null;

            if (self.total >= self.idx.fanout[self.first_level]) {
                self.first_level += 1;
                self.second_level = 0;
                continue;
            }

            const mapped: usize = @intCast(self.idx.fanout_mapping[self.first_level]);
            const oid_len = objectIdLength();
            const name_off = self.second_level * oid_len;
            var entry: Entry = .{
                .hash = plumbing.Hash.fromBytes(self.idx.names.items[mapped][name_off .. name_off + oid_len]),
                .crc32 = 0,
                .offset = 0,
            };
            entry.offset = try self.idx.getOffset(mapped, self.second_level);
            entry.crc32 = self.idx.getCRC32(mapped, self.second_level);

            self.second_level += 1;
            self.total += 1;
            return entry;
        }
    }

    pub fn close(self: *EntryIterator) void {
        self.first_level = fanout;
    }
};

/// Offset-order entry iterator (go-git `idxfileEntryOffsetIter`).
pub const OffsetEntryIterator = struct {
    entries: []Entry,
    pos: usize,
    allocator: Allocator,

    pub fn next(self: *OffsetEntryIterator) ?Entry {
        if (self.pos >= self.entries.len) return null;
        const e = self.entries[self.pos];
        self.pos += 1;
        return e;
    }

    pub fn close(self: *OffsetEntryIterator) void {
        self.pos = self.entries.len + 1;
    }

    pub fn deinit(self: *OffsetEntryIterator) void {
        self.allocator.free(self.entries);
        self.* = undefined;
    }
};
