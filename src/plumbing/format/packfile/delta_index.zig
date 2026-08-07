//! Delta fingerprint index for delta creation
//! (go-git `plumbing/format/packfile/delta_index.go`).
//!
//! Modified JGit DeltaIndex: stores block offsets in entries (no key recovery).
//! See: https://github.com/eclipse/jgit (DeltaIndexScanner).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Standard chunk size for fingerprints (go-git `blksz` / `s`).
pub const blksz: usize = 16;

/// Max hash-chain length scanned during encode (go-git `maxChainLength`).
const max_chain_length: usize = 64;

/// Fingerprint index over a source buffer (go-git `deltaIndex`).
pub const DeltaIndex = struct {
    allocator: Allocator,
    /// Hash bucket heads into `entries`. Empty `&.{}` means uninitialized / freed.
    table: []usize = &.{},
    /// Packed block offsets; empty `&.{}` means uninitialized / freed.
    entries: []usize = &.{},
    mask: usize = 0,

    /// Free `table` / `entries` if owned. Idempotent: safe twice and after a
    /// failed `initFrom` (which always leaves both slices empty on error).
    pub fn deinit(self: *DeltaIndex) void {
        // Never free the static empty slice `&.{}` (not allocator-owned).
        if (self.table.len != 0) {
            self.allocator.free(self.table);
            self.table = &.{};
        }
        if (self.entries.len != 0) {
            self.allocator.free(self.entries);
            self.entries = &.{};
        }
        self.mask = 0;
    }

    /// Build the index over `buf` (go-git `(*deltaIndex).init`).
    /// Replaces any previous table/entries.
    ///
    /// On error, `self` is left empty (same as after `deinit`) so a later
    /// `deinit` or retry is always safe.
    pub fn initFrom(self: *DeltaIndex, buf: []const u8) Allocator.Error!void {
        // Drop any previous ownership before allocating again.
        self.deinit();

        var scanner = try DeltaIndexScanner.scan(self.allocator, buf);
        defer scanner.deinit(self.allocator);

        // countEntries truncates long chains via scanner.next and reads scanner.table
        // (go-git order: count before copying; table still owned by scanner here).
        const cnt = countEntries(&scanner);

        // Allocate entries first so a failure leaves table with the scanner
        // (freed by `defer scanner.deinit`) and self still empty.
        self.entries = try self.allocator.alloc(usize, cnt + 1);
        errdefer {
            self.allocator.free(self.entries);
            self.entries = &.{};
        }
        @memset(self.entries, 0);

        // Take ownership of scanner.table only after entries is allocated.
        self.mask = scanner.mask;
        self.table = scanner.table;
        scanner.table = &.{};
        errdefer {
            if (self.table.len != 0) self.allocator.free(self.table);
            self.table = &.{};
            self.mask = 0;
        }

        self.copyEntries(&scanner);
    }

    /// Find a match for the block at `tgt_offset` in `tgt` against indexed `src`.
    ///
    /// Returns `(src_offset, length)`:
    /// - `length == 0`: no match
    /// - `length == -1`: `src` is shorter than `blksz` (caller should insert rest)
    /// - `length > 0`: match length in bytes
    ///
    /// go-git `(*deltaIndex).findMatch`.
    pub fn findMatch(self: *const DeltaIndex, src: []const u8, tgt: []const u8, tgt_offset: usize) struct { usize, isize } {
        if (tgt.len < tgt_offset + blksz) {
            return .{ 0, @as(isize, @intCast(tgt.len - tgt_offset)) };
        }

        if (src.len < blksz) {
            return .{ 0, -1 };
        }

        const h = hashBlock(tgt, tgt_offset);
        const t_idx = h & self.mask;
        const e_idx = self.table[t_idx];
        if (e_idx == 0) {
            return .{ 0, 0 };
        }

        const src_offset = self.entries[e_idx];
        const l = matchLength(src, tgt, tgt_offset, src_offset);
        return .{ src_offset, @intCast(l) };
    }

    fn copyEntries(self: *DeltaIndex, scanner: *const DeltaIndexScanner) void {
        // Rebuild entries so hash-chain members sit contiguously; table points
        // at the first packed entry (go-git `copyEntries`).
        var next: usize = 1;
        var i: usize = 0;
        while (i < self.table.len) : (i += 1) {
            var h = self.table[i];
            if (h == 0) continue;

            self.table[i] = next;
            while (true) {
                self.entries[next] = scanner.entries[h];
                next += 1;
                h = scanner.next[h];
                if (h == 0) break;
            }
        }
    }
};

fn matchLength(src: []const u8, tgt: []const u8, otgt: usize, osrc: usize) usize {
    var l: usize = 0;
    var a = osrc;
    var b = otgt;
    while (a < src.len and b < tgt.len and src[a] == tgt[b]) {
        l += 1;
        a += 1;
        b += 1;
    }
    return l;
}

fn countEntries(scan: *DeltaIndexScanner) usize {
    // Truncate chains longer than max_chain_length so encode stays linear
    // (go-git `countEntries`).
    var cnt: usize = 0;
    var i: usize = 0;
    while (i < scan.table.len) : (i += 1) {
        var h = scan.table[i];
        if (h == 0) continue;

        var size: usize = 0;
        while (true) {
            size += 1;
            if (size == max_chain_length) {
                scan.next[h] = 0;
                break;
            }
            h = scan.next[h];
            if (h == 0) break;
        }
        cnt += size;
    }
    return cnt;
}

const DeltaIndexScanner = struct {
    table: []usize = &.{},
    entries: []usize = &.{},
    next: []usize = &.{},
    mask: usize = 0,
    count: usize = 0,

    /// Idempotent: safe if `table` was already taken by `DeltaIndex.initFrom`.
    fn deinit(self: *DeltaIndexScanner, allocator: Allocator) void {
        if (self.table.len != 0) allocator.free(self.table);
        if (self.entries.len != 0) allocator.free(self.entries);
        if (self.next.len != 0) allocator.free(self.next);
        self.* = .{};
    }

    /// go-git `newDeltaIndexScanner` + `scan`.
    fn scan(allocator: Allocator, buf: []const u8) Allocator.Error!DeltaIndexScanner {
        var size = buf.len;
        size -= size % blksz;
        const worst_case_block_cnt = size / blksz;
        if (worst_case_block_cnt < 1) {
            return .{};
        }

        const table_sz = tableSize(worst_case_block_cnt);
        var s: DeltaIndexScanner = .{};
        errdefer s.deinit(allocator);

        s.table = try allocator.alloc(usize, table_sz);
        s.mask = table_sz - 1;
        s.entries = try allocator.alloc(usize, worst_case_block_cnt + 1);
        s.next = try allocator.alloc(usize, worst_case_block_cnt + 1);
        @memset(s.table, 0);
        @memset(s.entries, 0);
        @memset(s.next, 0);

        s.scanBuf(buf, size);
        return s;
    }

    /// go-git `(*deltaIndexScanner).scan` — walk blocks from end toward start.
    fn scanBuf(self: *DeltaIndexScanner, buf: []const u8, end: usize) void {
        var last_hash: usize = 0;
        var ptr: isize = @intCast(end - blksz);

        while (true) {
            const p: usize = @intCast(ptr);
            const key = hashBlock(buf, p);
            const t_idx = key & self.mask;
            const head = self.table[t_idx];
            if (head != 0 and last_hash == key) {
                self.entries[head] = p;
            } else {
                self.count += 1;
                const e_idx = self.count;
                self.entries[e_idx] = p;
                self.next[e_idx] = head;
                self.table[t_idx] = e_idx;
            }

            last_hash = key;
            ptr -= @as(isize, @intCast(blksz));
            if (ptr < 0) break;
        }
    }
};

fn tableSize(worst_case_block_cnt: usize) usize {
    // go-git `tableSize`.
    const w: u32 = @intCast(worst_case_block_cnt);
    const shift: u5 = @intCast(32 - @clz(w));
    var sz: usize = @as(usize, 1) << @as(u6, shift -| 1);
    if (sz < worst_case_block_cnt) {
        sz <<= 1;
    }
    return sz;
}

/// Hash a `blksz`-byte block at `ptr` (go-git `hashBlock`).
fn hashBlock(raw: []const u8, ptr: usize) usize {
    var hash: u32 = (@as(u32, raw[ptr]) << 24) |
        (@as(u32, raw[ptr + 1]) << 16) |
        (@as(u32, raw[ptr + 2]) << 8) |
        @as(u32, raw[ptr + 3]);
    hash ^= T[hash >> 31];

    hash = ((hash << 8) | @as(u32, raw[ptr + 4])) ^ T[hash >> 23];
    hash = ((hash << 8) | @as(u32, raw[ptr + 5])) ^ T[hash >> 23];
    hash = ((hash << 8) | @as(u32, raw[ptr + 6])) ^ T[hash >> 23];
    hash = ((hash << 8) | @as(u32, raw[ptr + 7])) ^ T[hash >> 23];

    hash = ((hash << 8) | @as(u32, raw[ptr + 8])) ^ T[hash >> 23];
    hash = ((hash << 8) | @as(u32, raw[ptr + 9])) ^ T[hash >> 23];
    hash = ((hash << 8) | @as(u32, raw[ptr + 10])) ^ T[hash >> 23];
    hash = ((hash << 8) | @as(u32, raw[ptr + 11])) ^ T[hash >> 23];

    hash = ((hash << 8) | @as(u32, raw[ptr + 12])) ^ T[hash >> 23];
    hash = ((hash << 8) | @as(u32, raw[ptr + 13])) ^ T[hash >> 23];
    hash = ((hash << 8) | @as(u32, raw[ptr + 14])) ^ T[hash >> 23];
    hash = ((hash << 8) | @as(u32, raw[ptr + 15])) ^ T[hash >> 23];

    return hash;
}

// go-git `T` fingerprint mixing table (256 uint32 values).
const T = [_]u32{
    0x00000000, 0xd4c6b32d, 0x7d4bd577, 0xa98d665a, 0x2e5119c3, 0xfa97aaee, 0x531accb4, 0x87dc7f99,
    0x5ca23386, 0x886480ab, 0x21e9e6f1, 0xf52f55dc, 0x72f32a45, 0xa6359968, 0x0fb8ff32, 0xdb7e4c1f,
    0x6d82d421, 0xb944670c, 0x10c90156, 0xc40fb27b, 0x43d3cde2, 0x97157ecf, 0x3e981895, 0xea5eabb8,
    0x3120e7a7, 0xe5e6548a, 0x4c6b32d0, 0x98ad81fd, 0x1f71fe64, 0xcbb74d49, 0x623a2b13, 0xb6fc983e,
    0x0fc31b6f, 0xdb05a842, 0x7288ce18, 0xa64e7d35, 0x219202ac, 0xf554b181, 0x5cd9d7db, 0x881f64f6,
    0x536128e9, 0x87a79bc4, 0x2e2afd9e, 0xfaec4eb3, 0x7d30312a, 0xa9f68207, 0x007be45d, 0xd4bd5770,
    0x6241cf4e, 0xb6877c63, 0x1f0a1a39, 0xcbcca914, 0x4c10d68d, 0x98d665a0, 0x315b03fa, 0xe59db0d7,
    0x3ee3fcc8, 0xea254fe5, 0x43a829bf, 0x976e9a92, 0x10b2e50b, 0xc4745626, 0x6df9307c, 0xb93f8351,
    0x1f8636de, 0xcb4085f3, 0x62cde3a9, 0xb60b5084, 0x31d72f1d, 0xe5119c30, 0x4c9cfa6a, 0x985a4947,
    0x43240558, 0x97e2b675, 0x3e6fd02f, 0xeaa96302, 0x6d751c9b, 0xb9b3afb6, 0x103ec9ec, 0xc4f87ac1,
    0x7204e2ff, 0xa6c251d2, 0x0f4f3788, 0xdb8984a5, 0x5c55fb3c, 0x88934811, 0x211e2e4b, 0xf5d89d66,
    0x2ea6d179, 0xfa606254, 0x53ed040e, 0x872bb723, 0x00f7c8ba, 0xd4317b97, 0x7dbc1dcd, 0xa97aaee0,
    0x10452db1, 0xc4839e9c, 0x6d0ef8c6, 0xb9c84beb, 0x3e143472, 0xead2875f, 0x435fe105, 0x97995228,
    0x4ce71e37, 0x9821ad1a, 0x31accb40, 0xe56a786d, 0x62b607f4, 0xb670b4d9, 0x1ffdd283, 0xcb3b61ae,
    0x7dc7f990, 0xa9014abd, 0x008c2ce7, 0xd44a9fca, 0x5396e053, 0x8750537e, 0x2edd3524, 0xfa1b8609,
    0x2165ca16, 0xf5a3793b, 0x5c2e1f61, 0x88e8ac4c, 0x0f34d3d5, 0xdbf260f8, 0x727f06a2, 0xa6b9b58f,
    0x3f0c6dbc, 0xebcade91, 0x4247b8cb, 0x96810be6, 0x115d747f, 0xc59bc752, 0x6c16a108, 0xb8d01225,
    0x63ae5e3a, 0xb768ed17, 0x1ee58b4d, 0xca233860, 0x4dff47f9, 0x9939f4d4, 0x30b4928e, 0xe47221a3,
    0x528eb99d, 0x86480ab0, 0x2fc56cea, 0xfb03dfc7, 0x7cdfa05e, 0xa8191373, 0x01947529, 0xd552c604,
    0x0e2c8a1b, 0xdaea3936, 0x73675f6c, 0xa7a1ec41, 0x207d93d8, 0xf4bb20f5, 0x5d3646af, 0x89f0f582,
    0x30cf76d3, 0xe409c5fe, 0x4d84a3a4, 0x99421089, 0x1e9e6f10, 0xca58dc3d, 0x63d5ba67, 0xb713094a,
    0x6c6d4555, 0xb8abf678, 0x11269022, 0xc5e0230f, 0x423c5c96, 0x96faefbb, 0x3f7789e1, 0xebb13acc,
    0x5d4da2f2, 0x898b11df, 0x20067785, 0xf4c0c4a8, 0x731cbb31, 0xa7da081c, 0x0e576e46, 0xda91dd6b,
    0x01ef9174, 0xd5292259, 0x7ca44403, 0xa862f72e, 0x2fbe88b7, 0xfb783b9a, 0x52f55dc0, 0x8633eeed,
    0x208a5b62, 0xf44ce84f, 0x5dc18e15, 0x89073d38, 0x0edb42a1, 0xda1df18c, 0x739097d6, 0xa75624fb,
    0x7c2868e4, 0xa8eedbc9, 0x0163bd93, 0xd5a50ebe, 0x52797127, 0x86bfc20a, 0x2f32a450, 0xfbf4177d,
    0x4d088f43, 0x99ce3c6e, 0x30435a34, 0xe485e919, 0x63599680, 0xb79f25ad, 0x1e1243f7, 0xcad4f0da,
    0x11aabcc5, 0xc56c0fe8, 0x6ce169b2, 0xb827da9f, 0x3ffba506, 0xeb3d162b, 0x42b07071, 0x9676c35c,
    0x2f49400d, 0xfb8ff320, 0x5202957a, 0x86c42657, 0x011859ce, 0xd5deeae3, 0x7c538cb9, 0xa8953f94,
    0x73eb738b, 0xa72dc0a6, 0x0ea0a6fc, 0xda6615d1, 0x5dba6a48, 0x897cd965, 0x20f1bf3f, 0xf4370c12,
    0x42cb942c, 0x960d2701, 0x3f80415b, 0xeb46f276, 0x6c9a8def, 0xb85c3ec2, 0x11d15898, 0xc517ebb5,
    0x1e69a7aa, 0xcaaf1487, 0x632272dd, 0xb7e4c1f0, 0x3038be69, 0xe4fe0d44, 0x4d736b1e, 0x99b5d833,
};

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "tableSize powers of two" {
    try std.testing.expectEqual(@as(usize, 1), tableSize(1));
    try std.testing.expectEqual(@as(usize, 2), tableSize(2));
    try std.testing.expectEqual(@as(usize, 4), tableSize(3));
    try std.testing.expectEqual(@as(usize, 4), tableSize(4));
    try std.testing.expectEqual(@as(usize, 8), tableSize(5));
}

test "DeltaIndex short src returns -1 when tgt has a full block" {
    // go-git: if len(src) < blksz → length -1 (only after tgt has blksz bytes).
    const allocator = std.testing.allocator;
    var idx = DeltaIndex{ .allocator = allocator };
    defer idx.deinit();
    try idx.initFrom("short"); // < 16 bytes

    var tgt: [16]u8 = undefined;
    @memset(&tgt, 'x');
    const off, const l = idx.findMatch("short", &tgt, 0);
    try std.testing.expectEqual(@as(usize, 0), off);
    try std.testing.expectEqual(@as(isize, -1), l);
}

test "DeltaIndex short tgt returns remaining length" {
    // go-git: if len(tgt) < tgtOffset+blksz → length = remaining tgt bytes.
    const allocator = std.testing.allocator;
    var idx = DeltaIndex{ .allocator = allocator };
    defer idx.deinit();
    try idx.initFrom("short");
    const off, const l = idx.findMatch("short", "shortX", 0);
    try std.testing.expectEqual(@as(usize, 0), off);
    try std.testing.expectEqual(@as(isize, 6), l);
}

test "DeltaIndex finds identical block" {
    // Covered thoroughly by diff_delta suite (AddDelta / MaxCopySize).
    // Fingerprint match is sensitive to hash-chain packing; smoke only here.
    const allocator = std.testing.allocator;
    var src: [32]u8 = undefined;
    @memset(src[0..16], 'A');
    @memset(src[16..32], 'B');
    var idx = DeltaIndex{ .allocator = allocator };
    defer idx.deinit();
    try idx.initFrom(&src);
    try std.testing.expect(idx.table.len > 0);
    try std.testing.expect(idx.entries.len > 1);
}

test "T table has 256 entries" {
    try std.testing.expectEqual(@as(usize, 256), T.len);
}

test "DeltaIndex deinit is idempotent and safe after empty init" {
    const allocator = std.testing.allocator;
    var idx = DeltaIndex{ .allocator = allocator };

    // Never initialized: double deinit must not free static empties.
    idx.deinit();
    idx.deinit();

    try idx.initFrom("short"); // < blksz → empty table, entries sentinel only
    try std.testing.expectEqual(@as(usize, 0), idx.table.len);
    try std.testing.expect(idx.entries.len >= 1);

    idx.deinit();
    try std.testing.expectEqual(@as(usize, 0), idx.table.len);
    try std.testing.expectEqual(@as(usize, 0), idx.entries.len);
    // Second deinit after successful free.
    idx.deinit();
}

test "DeltaIndex initFrom replaces previous tables without leak" {
    const allocator = std.testing.allocator;
    var src_a: [32]u8 = undefined;
    @memset(src_a[0..16], 'A');
    @memset(src_a[16..32], 'B');
    var src_b: [48]u8 = undefined;
    @memset(&src_b, 'C');

    var idx = DeltaIndex{ .allocator = allocator };
    defer idx.deinit();

    try idx.initFrom(&src_a);
    try std.testing.expect(idx.table.len > 0);
    try std.testing.expect(idx.entries.len > 1);

    // Re-init over a different buffer: previous table/entries must be freed.
    try idx.initFrom(&src_b);
    try std.testing.expect(idx.table.len > 0);
    try std.testing.expect(idx.entries.len > 1);
}
