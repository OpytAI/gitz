//! jgit SimilarityIndex (go-git `plumbing/object/rename.go`).
//!
//! Space-efficient line/block hash multiset used for content rename scoring.
//! Port of go-git v5.19.2 / eclipse jgit SimilarityIndex.java.

const std = @import("std");
const file_mod = @import("file.zig");

const Allocator = std.mem.Allocator;
const File = file_mod.File;

pub const IndexFullError = error{IndexFull};

const key_shift: u6 = 32;
const max_count_value: u64 = (@as(u64, 1) << key_shift) - 1;

const KeyCountPair = u64;

fn pairKey(p: KeyCountPair) u32 {
    return @intCast(p >> key_shift);
}

fn pairCount(p: KeyCountPair) u64 {
    return p & max_count_value;
}

fn newKeyCountPair(key: i32, cnt: u64) IndexFullError!KeyCountPair {
    if (cnt > max_count_value) return error.IndexFull;
    return (@as(u64, @intCast(@as(u32, @bitCast(key)))) << key_shift) | cnt;
}

/// go-git `similarityIndex`.
pub const SimilarityIndex = struct {
    hashed: u64 = 0,
    num_hashes: usize = 0,
    grow_at: usize,
    hashes: []KeyCountPair,
    hash_bits: u5,
    allocator: Allocator,

    pub fn deinit(self: *SimilarityIndex) void {
        self.allocator.free(self.hashes);
        self.* = undefined;
    }

    fn new(allocator: Allocator) Allocator.Error!SimilarityIndex {
        const hash_bits: u5 = 8;
        const hashes = try allocator.alloc(KeyCountPair, @as(usize, 1) << hash_bits);
        @memset(hashes, 0);
        return .{
            .grow_at = shouldGrowAt(hash_bits),
            .hashes = hashes,
            .hash_bits = hash_bits,
            .allocator = allocator,
        };
    }

    /// go-git `fileSimilarityIndex`.
    pub fn fromFile(allocator: Allocator, f: *const File) (Allocator.Error || IndexFullError)!SimilarityIndex {
        var idx = try new(allocator);
        errdefer idx.deinit();
        try idx.hashFile(f);
        idx.sortHashes();
        return idx;
    }

    /// Build an index from in-memory content (go-git test `textIndex` + sort).
    /// `is_bin` false ignores CR before LF (text path).
    pub fn fromContent(
        allocator: Allocator,
        data: []const u8,
        is_bin: bool,
    ) (Allocator.Error || IndexFullError)!SimilarityIndex {
        var idx = try new(allocator);
        errdefer idx.deinit();
        try idx.hashContent(data, is_bin);
        idx.sortHashes();
        return idx;
    }

    fn sortHashes(self: *SimilarityIndex) void {
        // sort.Stable by keyCountPair numeric value (go-git keyCountPairs.Less).
        std.mem.sort(KeyCountPair, self.hashes, {}, struct {
            fn less(_: void, a: KeyCountPair, b: KeyCountPair) bool {
                return a < b;
            }
        }.less);
    }

    fn hashFile(self: *SimilarityIndex, f: *const File) (Allocator.Error || IndexFullError)!void {
        const is_bin = f.isBinary();
        const content = f.blob.readerBytes();
        try self.hashContent(content, is_bin);
    }

    /// go-git `(*similarityIndex).hashContent`.
    pub fn hashContent(self: *SimilarityIndex, data: []const u8, is_bin: bool) (Allocator.Error || IndexFullError)!void {
        var remaining: i64 = @intCast(data.len);
        var ptr: usize = 0;

        while (remaining > 0) {
            var hash: i32 = 5381;
            var block_hashed: u64 = 0;
            var n: i64 = 0;

            while (true) {
                if (ptr >= data.len) break;
                n += 1;
                const c: u8 = data[ptr];
                ptr += 1;

                // Ignore CR in CRLF for text.
                if (!is_bin and c == '\r' and ptr < data.len and data[ptr] == '\n') {
                    continue;
                }
                block_hashed += 1;

                if (c == '\n') break;

                // djb2: hash = hash*33 + c
                hash = (hash << 5) +% hash +% @as(i32, c);

                if (n >= 64 or n >= remaining) break;
            }

            self.hashed += block_hashed;
            try self.add(hash, block_hashed);
            remaining -= n;
        }
    }

    fn add(self: *SimilarityIndex, key_in: i32, cnt: u64) (Allocator.Error || IndexFullError)!void {
        // key = uint32(key) * 0x9e370001 >> 1  (go signed int after mul)
        const key: i32 = @bitCast(@as(u32, @bitCast(key_in)) *% 0x9e370001 >> 1);

        var j = self.slot(key);
        while (true) {
            const v = self.hashes[j];
            if (v == 0) {
                if (self.grow_at <= self.num_hashes) {
                    try self.grow();
                    j = self.slot(key);
                    continue;
                }
                self.hashes[j] = try newKeyCountPair(key, cnt);
                self.num_hashes += 1;
                return;
            } else if (pairKey(v) == @as(u32, @bitCast(key))) {
                self.hashes[j] = try newKeyCountPair(key, pairCount(v) + cnt);
                return;
            } else if (j + 1 >= self.hashes.len) {
                j = 0;
            } else {
                j += 1;
            }
        }
    }

    fn slot(self: *const SimilarityIndex, key: i32) usize {
        // 31 - hashBits: upper bit already 0; use remaining high bits.
        const shift: u5 = @intCast(31 - @as(u6, self.hash_bits));
        return @as(u32, @bitCast(key)) >> shift;
    }

    fn grow(self: *SimilarityIndex) (Allocator.Error || IndexFullError)!void {
        if (self.hash_bits == 30) return error.IndexFull;
        const old = self.hashes;
        defer self.allocator.free(old);

        self.hash_bits += 1;
        self.grow_at = shouldGrowAt(self.hash_bits);
        self.hashes = try self.allocator.alloc(KeyCountPair, @as(usize, 1) << self.hash_bits);
        @memset(self.hashes, 0);

        for (old) |v| {
            if (v == 0) continue;
            var j = self.slot(@bitCast(pairKey(v)));
            while (self.hashes[j] != 0) {
                j += 1;
                if (j >= self.hashes.len) j = 0;
            }
            self.hashes[j] = v;
        }
    }

    /// go-git `(*similarityIndex).score` — result in `[0, max_score]`.
    pub fn score(self: *const SimilarityIndex, other: *const SimilarityIndex, max_score: i32) i32 {
        var max_hashed = self.hashed;
        if (max_hashed < other.hashed) max_hashed = other.hashed;
        if (max_hashed == 0) return max_score;
        return @intCast(self.common(other) * @as(u64, @intCast(max_score)) / max_hashed);
    }

    /// go-git `(*similarityIndex).common` — walk sorted tables from index 0.
    pub fn common(self: *const SimilarityIndex, dst: *const SimilarityIndex) u64 {
        if (self.num_hashes == 0 or dst.num_hashes == 0) return 0;

        var src_idx: usize = 0;
        var dst_idx: usize = 0;
        var common_cnt: u64 = 0;
        var src_key = pairKey(self.hashes[src_idx]);
        var dst_key = pairKey(dst.hashes[dst_idx]);

        while (true) {
            if (src_key == dst_key) {
                const src_cnt = pairCount(self.hashes[src_idx]);
                const dst_cnt = pairCount(dst.hashes[dst_idx]);
                common_cnt += if (src_cnt < dst_cnt) src_cnt else dst_cnt;

                src_idx += 1;
                if (src_idx == self.hashes.len) break;
                src_key = pairKey(self.hashes[src_idx]);

                dst_idx += 1;
                if (dst_idx == dst.hashes.len) break;
                dst_key = pairKey(dst.hashes[dst_idx]);
            } else if (src_key < dst_key) {
                src_idx += 1;
                if (src_idx == self.hashes.len) break;
                src_key = pairKey(self.hashes[src_idx]);
            } else {
                dst_idx += 1;
                if (dst_idx == dst.hashes.len) break;
                dst_key = pairKey(dst.hashes[dst_idx]);
            }
        }
        return common_cnt;
    }
};

fn shouldGrowAt(hash_bits: u5) usize {
    const hb: usize = hash_bits;
    return (@as(usize, 1) << hash_bits) * (hb - 3) / hb;
}

// ---------------------------------------------------------------------------
// Tests (against go-git SimilarityIndexSuite / jgit semantics)
// ---------------------------------------------------------------------------

fn textIndex(allocator: Allocator, content: []const u8) !SimilarityIndex {
    return try SimilarityIndex.fromContent(allocator, content, false);
}

fn keyForLine(allocator: Allocator, line: []const u8) !u32 {
    var idx = try SimilarityIndex.new(allocator);
    defer idx.deinit();
    try idx.hashContent(line, false);
    try std.testing.expectEqual(@as(usize, 1), idx.num_hashes);
    for (idx.hashes) |h| {
        if (h != 0) return pairKey(h);
    }
    return error.TestUnexpectedResult;
}

fn findCount(idx: *const SimilarityIndex, key: u32) u64 {
    for (idx.hashes) |h| {
        if (h != 0 and pairKey(h) == key) return pairCount(h);
    }
    return 0;
}

test "SimilarityIndex identical files score max" {
    const gpa = std.testing.allocator;
    const plumbing = @import("plumbing");
    const blob_mod = @import("blob.zig");
    const filemode = @import("filemode");

    var o = plumbing.MemoryObject.init(gpa);
    defer o.deinit();
    o.setType(.blob);
    _ = try o.write("hello\nworld\n");
    var b: blob_mod.Blob = .{};
    try b.decode(&o);
    const f = file_mod.newFile("f", filemode.Regular, &b);

    var a = try SimilarityIndex.fromFile(gpa, &f);
    defer a.deinit();
    var c = try SimilarityIndex.fromFile(gpa, &f);
    defer c.deinit();
    try std.testing.expectEqual(@as(i32, 10000), a.score(&c, 10000));
}

test "SimilarityIndex empty files score max" {
    const gpa = std.testing.allocator;
    const plumbing = @import("plumbing");
    const blob_mod = @import("blob.zig");
    const filemode = @import("filemode");

    var o = plumbing.MemoryObject.init(gpa);
    defer o.deinit();
    o.setType(.blob);
    _ = try o.write("");
    var b: blob_mod.Blob = .{};
    try b.decode(&o);
    const f = file_mod.newFile("f", filemode.Regular, &b);

    var a = try SimilarityIndex.fromFile(gpa, &f);
    defer a.deinit();
    var c = try SimilarityIndex.fromFile(gpa, &f);
    defer c.deinit();
    try std.testing.expectEqual(@as(i32, 100), a.score(&c, 100));
}

// go-git SimilarityIndexSuite.TestHashContent
test "SimilarityIndex hashContent line keys and counts" {
    const gpa = std.testing.allocator;
    var idx = try textIndex(gpa, "A\nB\nD\nB\n");
    defer idx.deinit();

    const key_a = try keyForLine(gpa, "A\n");
    const key_b = try keyForLine(gpa, "B\n");
    const key_d = try keyForLine(gpa, "D\n");

    try std.testing.expect(key_a != key_b);
    try std.testing.expect(key_a != key_d);
    try std.testing.expect(key_d != key_b);

    try std.testing.expectEqual(@as(usize, 3), idx.num_hashes);
    try std.testing.expectEqual(@as(u64, 2), findCount(&idx, key_a));
    try std.testing.expectEqual(@as(u64, 4), findCount(&idx, key_b));
    try std.testing.expectEqual(@as(u64, 2), findCount(&idx, key_d));
}

// go-git SimilarityIndexSuite.TestCommonSameFiles
test "SimilarityIndex common same files" {
    const gpa = std.testing.allocator;
    const content = "A\nB\nD\nB\n";
    var src = try textIndex(gpa, content);
    defer src.deinit();
    var dst = try textIndex(gpa, content);
    defer dst.deinit();

    try std.testing.expectEqual(@as(u64, 8), src.common(&dst));
    try std.testing.expectEqual(@as(u64, 8), dst.common(&src));
    try std.testing.expectEqual(@as(i32, 100), src.score(&dst, 100));
    try std.testing.expectEqual(@as(i32, 100), dst.score(&src, 100));
}

// go-git SimilarityIndexSuite.TestCommonSameFilesCR
test "SimilarityIndex common same files with CR" {
    const gpa = std.testing.allocator;
    const with_cr = "A\r\nB\r\nD\r\nB\r\n";
    const no_cr = "A\nB\nD\nB\n";
    var src = try textIndex(gpa, with_cr);
    defer src.deinit();
    var dst = try textIndex(gpa, no_cr);
    defer dst.deinit();

    try std.testing.expectEqual(@as(u64, 8), src.common(&dst));
    try std.testing.expectEqual(@as(u64, 8), dst.common(&src));
    try std.testing.expectEqual(@as(i32, 100), src.score(&dst, 100));
    try std.testing.expectEqual(@as(i32, 100), dst.score(&src, 100));
}

// go-git SimilarityIndexSuite.TestCommonEmptyFiles
test "SimilarityIndex common empty files" {
    const gpa = std.testing.allocator;
    var src = try textIndex(gpa, "");
    defer src.deinit();
    var dst = try textIndex(gpa, "");
    defer dst.deinit();

    try std.testing.expectEqual(@as(u64, 0), src.common(&dst));
    try std.testing.expectEqual(@as(u64, 0), dst.common(&src));
}

// go-git SimilarityIndexSuite.TestCommonTotallyDifferentFiles
test "SimilarityIndex common totally different files" {
    const gpa = std.testing.allocator;
    var src = try textIndex(gpa, "A\n");
    defer src.deinit();
    var dst = try textIndex(gpa, "D\n");
    defer dst.deinit();

    try std.testing.expectEqual(@as(u64, 0), src.common(&dst));
    try std.testing.expectEqual(@as(u64, 0), dst.common(&src));
}

// go-git SimilarityIndexSuite.TestSimilarity75
test "SimilarityIndex similarity 75" {
    const gpa = std.testing.allocator;
    var src = try textIndex(gpa, "A\nB\nC\nD\n");
    defer src.deinit();
    var dst = try textIndex(gpa, "A\nB\nC\nQ\n");
    defer dst.deinit();

    try std.testing.expectEqual(@as(u64, 6), src.common(&dst));
    try std.testing.expectEqual(@as(u64, 6), dst.common(&src));
    try std.testing.expectEqual(@as(i32, 75), src.score(&dst, 100));
    try std.testing.expectEqual(@as(i32, 75), dst.score(&src, 100));
}

// ScoreFiles without go-git fixtures: binary vs text content scores.
test "SimilarityIndex score files synthetic" {
    const gpa = std.testing.allocator;

    var same = try textIndex(gpa, "line1\nline2\nline3\n");
    defer same.deinit();
    try std.testing.expectEqual(@as(i32, 10000), same.score(&same, 10000));

    var short = try textIndex(gpa, "{\n  \"a\": 1\n}\n");
    defer short.deinit();
    var long = try textIndex(gpa, "{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3\n}\n");
    defer long.deinit();
    // Slightly similar JSON-ish text; score must be symmetric and in range.
    const s1 = short.score(&long, 10000);
    const s2 = long.score(&short, 10000);
    try std.testing.expectEqual(s1, s2);
    try std.testing.expect(s1 >= 0 and s1 <= 10000);

    var bin = try SimilarityIndex.fromContent(gpa, "\x00\x01\x02\x03\x04\x05", true);
    defer bin.deinit();
    const vs_bin = long.score(&bin, 10000);
    try std.testing.expect(vs_bin >= 0 and vs_bin <= 10000);
}
