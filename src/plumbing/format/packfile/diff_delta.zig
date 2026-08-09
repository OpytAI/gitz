//! Create git packfile deltas (go-git `plumbing/format/packfile/diff_delta.go`).
//!
//! Pair with `patch_delta.zig` (apply path). This module is the create path:
//! `DiffDelta` / `GetDelta` produce OFS-delta bytes that `patchDelta` can apply.
//!
//! References (same as go-git):
//! - https://github.com/jelmer/dulwich/blob/master/dulwich/pack.py
//! - https://github.com/tarruda/node-git-core/blob/master/src/js/delta.js

const std = @import("std");
const UsizeShift = std.math.Log2Int(usize);
const Allocator = std.mem.Allocator;

const plumbing = @import("plumbing");
const MemoryObject = plumbing.MemoryObject;
const sync = @import("utils/sync");

const delta_index = @import("delta_index.zig");
const DeltaIndex = delta_index.DeltaIndex;
const blksz = delta_index.blksz;
const patch_delta = @import("patch_delta.zig");

/// Standard chunk size used to generate fingerprints (go-git `s`).
const s: usize = blksz;

/// Max size of a copy operation (64KB) (go-git `maxCopySize`).
pub const max_copy_size: usize = 64 * 1024;

/// Return an owned `MemoryObject` of type `ofs_delta` with delta bytes that
/// transform `base` into `target` (go-git `GetDelta`).
///
/// Caller owns the returned object and must `deinit` then `destroy` it.
pub fn getDelta(
    allocator: Allocator,
    base: *const MemoryObject,
    target: *const MemoryObject,
) Allocator.Error!*MemoryObject {
    var index = DeltaIndex{ .allocator = allocator };
    defer index.deinit();
    return getDeltaWithIndex(allocator, &index, base, target);
}

/// go-git `getDelta` — same as `getDelta` but reuses `index` across calls.
///
/// On every error path: temporary delta bytes are freed (`defer`), and a
/// partially constructed `MemoryObject` is `deinit`+`destroy`ed (`errdefer`).
/// Pooled buffers used by `diffDeltaWithIndex` are always returned via
/// `putBytesBuffer`.
pub fn getDeltaWithIndex(
    allocator: Allocator,
    index: *DeltaIndex,
    base: *const MemoryObject,
    target: *const MemoryObject,
) Allocator.Error!*MemoryObject {
    // Owned encode buffer: free on success (after write copies it) and on error.
    const db = try diffDeltaWithIndex(allocator, index, base.readerBytes(), target.readerBytes());
    defer allocator.free(db);

    const delta = try allocator.create(MemoryObject);
    errdefer allocator.destroy(delta);
    delta.* = MemoryObject.init(allocator);
    errdefer delta.deinit();

    _ = try delta.write(db);
    delta.setSize(@intCast(db.len));
    delta.setType(.ofs_delta);
    return delta;
}

/// Return the delta that transforms `src` into `tgt` (go-git `DiffDelta`).
/// Caller owns the result and must free with `allocator`.
pub fn diffDelta(allocator: Allocator, src: []const u8, tgt: []const u8) Allocator.Error![]u8 {
    var index = DeltaIndex{ .allocator = allocator };
    defer index.deinit();
    return diffDeltaWithIndex(allocator, &index, src, tgt);
}

/// go-git `diffDelta` — core encode using (and populating) `index`.
///
/// Always pairs `getBytesBuffer` with `putBytesBuffer` (via `defer`), including
/// on error. Callers under a leak-checking allocator must still call
/// `sync.deinitPools` so free-list nodes are released.
pub fn diffDeltaWithIndex(
    allocator: Allocator,
    index: *DeltaIndex,
    src: []const u8,
    tgt: []const u8,
) Allocator.Error![]u8 {
    const buf = try sync.getBytesBuffer(allocator);
    defer sync.putBytesBuffer(buf);

    try appendDeltaEncodeSize(buf, allocator, src.len);
    try appendDeltaEncodeSize(buf, allocator, tgt.len);

    if (index.entries.len == 0) {
        try index.initFrom(src);
    }

    const ibuf = try sync.getBytesBuffer(allocator);
    defer sync.putBytesBuffer(ibuf);

    var i: usize = 0;
    while (i < tgt.len) {
        const src_offset, const l = index.findMatch(src, tgt, i);

        if (l == 0) {
            // No match: insert current byte.
            try ibuf.append(allocator, tgt[i]);
            i += 1;
        } else if (l < 0) {
            // src shorter than blksz: insert the rest of tgt.
            try ibuf.appendSlice(allocator, tgt[i..]);
            break;
        } else if (l < @as(isize, @intCast(s))) {
            // Short match: insert matched bytes as data (not worth a copy).
            const n: usize = @intCast(l);
            try ibuf.appendSlice(allocator, tgt[i .. i + n]);
            i += n;
        } else {
            try encodeInsertOperation(ibuf, buf, allocator);

            var rl: usize = @intCast(l);
            var a_offset = src_offset;
            while (rl > 0) {
                if (rl < max_copy_size) {
                    try appendEncodeCopyOperation(buf, allocator, a_offset, rl);
                    break;
                }
                try appendEncodeCopyOperation(buf, allocator, a_offset, max_copy_size);
                rl -= max_copy_size;
                a_offset += max_copy_size;
            }

            i += @intCast(l);
        }
    }

    try encodeInsertOperation(ibuf, buf, allocator);

    // Buffer contents only valid until next mutate; copy out (go-git append copy).
    return try allocator.dupe(u8, buf.items);
}

/// Flush pending insert buffer into `buf` as copy-from-delta ops
/// (go-git `encodeInsertOperation`).
fn encodeInsertOperation(
    ibuf: *sync.BytesBuffer,
    buf: *sync.BytesBuffer,
    allocator: Allocator,
) Allocator.Error!void {
    if (ibuf.items.len == 0) return;

    const b = ibuf.items;
    var remaining = ibuf.items.len;
    var o: usize = 0;
    while (remaining > 127) {
        try buf.append(allocator, 127);
        try buf.appendSlice(allocator, b[o .. o + 127]);
        remaining -= 127;
        o += 127;
    }
    try buf.append(allocator, @intCast(remaining));
    try buf.appendSlice(allocator, b[o .. o + remaining]);

    ibuf.clearRetainingCapacity();
}

/// Encode a size as git delta LEB128 (go-git `deltaEncodeSize`).
/// Caller owns the result.
pub fn deltaEncodeSize(allocator: Allocator, size: usize) Allocator.Error![]u8 {
    var ret: std.ArrayList(u8) = .empty;
    errdefer ret.deinit(allocator);

    var s_rem = size;
    var c: u8 = @truncate(s_rem & 0x7f);
    s_rem >>= 7;
    while (s_rem != 0) {
        try ret.append(allocator, c | 0x80);
        c = @truncate(s_rem & 0x7f);
        s_rem >>= 7;
    }
    try ret.append(allocator, c);
    return try ret.toOwnedSlice(allocator);
}

fn appendDeltaEncodeSize(list: *std.ArrayList(u8), allocator: Allocator, size: usize) Allocator.Error!void {
    var s_rem = size;
    var c: u8 = @truncate(s_rem & 0x7f);
    s_rem >>= 7;
    while (s_rem != 0) {
        try list.append(allocator, c | 0x80);
        c = @truncate(s_rem & 0x7f);
        s_rem >>= 7;
    }
    try list.append(allocator, c);
}

/// Encode a copy-from-src op (go-git `encodeCopyOperation`).
fn appendEncodeCopyOperation(
    list: *std.ArrayList(u8),
    allocator: Allocator,
    offset: usize,
    length: usize,
) Allocator.Error!void {
    var code: u8 = 0x80;
    var opcodes: [7]u8 = undefined;
    var n_op: usize = 0;

    var i: u3 = 0;
    while (i < 4) : (i += 1) {
        const shift: UsizeShift = @intCast(@as(u6, i) * 8);
        const f: usize = @as(usize, 0xff) << shift;
        if (offset & f != 0) {
            opcodes[n_op] = @truncate((offset & f) >> shift);
            n_op += 1;
            code |= @as(u8, 0x01) << i;
        }
    }

    i = 0;
    while (i < 3) : (i += 1) {
        const shift: UsizeShift = @intCast(@as(u6, i) * 8);
        const f: usize = @as(usize, 0xff) << shift;
        if (length & f != 0) {
            opcodes[n_op] = @truncate((length & f) >> shift);
            n_op += 1;
            code |= @as(u8, 0x10) << i;
        }
    }

    try list.append(allocator, code);
    try list.appendSlice(allocator, opcodes[0..n_op]);
}

// ---------------------------------------------------------------------------
// Tests (go-git `delta_test.go`)
// ---------------------------------------------------------------------------

const GenPiece = struct { val: []const u8, times: usize };

fn genBytes(allocator: Allocator, pieces: []const GenPiece) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (pieces) |e| {
        var n: usize = 0;
        while (n < e.times) : (n += 1) {
            try result.appendSlice(allocator, e.val);
        }
    }
    return try result.toOwnedSlice(allocator);
}

const letter_bytes = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

fn randBytes(allocator: Allocator, n: usize, seed: u64) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const b = try allocator.alloc(u8, n);
    for (b) |*c| {
        c.* = letter_bytes[random.intRangeLessThan(usize, 0, letter_bytes.len)];
    }
    return b;
}

const DeltaCase = struct {
    description: []const u8,
    base: []const GenPiece,
    target: []const GenPiece,
};

fn deltaTestCases() []const DeltaCase {
    // bigRandStr: fixed-seed 100KiB random (go-git `bigRandStr`).
    // Generated once per process in go-git; we rebuild per test with seed 1.
    return &[_]DeltaCase{
        .{
            .description = "distinct file",
            .base = &[_]GenPiece{.{ .val = "0", .times = 300 }},
            .target = &[_]GenPiece{.{ .val = "2", .times = 200 }},
        },
        .{
            .description = "same file",
            .base = &[_]GenPiece{.{ .val = "1", .times = 3000 }},
            .target = &[_]GenPiece{.{ .val = "1", .times = 3000 }},
        },
        .{
            .description = "small file",
            .base = &[_]GenPiece{.{ .val = "1", .times = 3 }},
            .target = &[_]GenPiece{ .{ .val = "1", .times = 3 }, .{ .val = "0", .times = 1 } },
        },
        .{
            .description = "big file",
            .base = &[_]GenPiece{.{ .val = "1", .times = 300000 }},
            .target = &[_]GenPiece{ .{ .val = "1", .times = 30000 }, .{ .val = "0", .times = 1000000 } },
        },
        .{
            .description = "add elements before",
            .base = &[_]GenPiece{.{ .val = "0", .times = 200 }},
            .target = &[_]GenPiece{ .{ .val = "1", .times = 300 }, .{ .val = "0", .times = 200 } },
        },
        .{
            .description = "add 10 times more elements at the end",
            .base = &[_]GenPiece{ .{ .val = "1", .times = 300 }, .{ .val = "0", .times = 200 } },
            .target = &[_]GenPiece{.{ .val = "0", .times = 2000 }},
        },
        .{
            .description = "add elements between",
            .base = &[_]GenPiece{.{ .val = "0", .times = 400 }},
            .target = &[_]GenPiece{ .{ .val = "0", .times = 200 }, .{ .val = "1", .times = 200 }, .{ .val = "0", .times = 200 } },
        },
        .{
            .description = "add elements after",
            .base = &[_]GenPiece{.{ .val = "0", .times = 200 }},
            .target = &[_]GenPiece{ .{ .val = "0", .times = 200 }, .{ .val = "1", .times = 200 } },
        },
        .{
            .description = "modify elements at the end",
            .base = &[_]GenPiece{ .{ .val = "1", .times = 300 }, .{ .val = "0", .times = 200 } },
            .target = &[_]GenPiece{.{ .val = "0", .times = 100 }},
        },
        .{
            .description = "complex modification",
            .base = &[_]GenPiece{
                .{ .val = "0", .times = 3 }, .{ .val = "1", .times = 40 },  .{ .val = "2", .times = 30 },
                .{ .val = "3", .times = 2 }, .{ .val = "4", .times = 400 }, .{ .val = "5", .times = 23 },
            },
            .target = &[_]GenPiece{
                .{ .val = "1", .times = 30 },  .{ .val = "2", .times = 20 }, .{ .val = "7", .times = 40 },
                .{ .val = "4", .times = 400 }, .{ .val = "5", .times = 10 },
            },
        },
    };
}

test "DeltaSuite.TestAddDelta" {
    // go-git `TestAddDelta` (all cases except the 100KiB random copy; see separate test).
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    for (deltaTestCases()) |tc| {
        const base_buf = try genBytes(allocator, tc.base);
        defer allocator.free(base_buf);
        const target_buf = try genBytes(allocator, tc.target);
        defer allocator.free(target_buf);

        const delta = try diffDelta(allocator, base_buf, target_buf);
        defer allocator.free(delta);

        const result = try patch_delta.patchDelta(allocator, base_buf, delta);
        defer allocator.free(result);

        try std.testing.expectEqualSlices(u8, target_buf, result);
    }
}

test "DeltaSuite.TestAddDelta big copy" {
    // go-git case "A copy operation bigger than 64kb".
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    const big = try randBytes(allocator, 100 * 1024, 1);
    defer allocator.free(big);

    const base_buf = try genBytes(allocator, &[_]GenPiece{
        .{ .val = big, .times = 1 },
        .{ .val = "1", .times = 200 },
    });
    defer allocator.free(base_buf);
    const target_buf = try genBytes(allocator, &[_]GenPiece{
        .{ .val = big, .times = 1 },
    });
    defer allocator.free(target_buf);

    const delta = try diffDelta(allocator, base_buf, target_buf);
    defer allocator.free(delta);

    const result = try patch_delta.patchDelta(allocator, base_buf, delta);
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u8, target_buf, result);
}

test "DeltaSuite.TestAddDeltaReader" {
    // go-git `TestAddDeltaReader` — DiffDelta + readerFromDelta.
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    for (deltaTestCases()) |tc| {
        const base_buf = try genBytes(allocator, tc.base);
        defer allocator.free(base_buf);
        const target_buf = try genBytes(allocator, tc.target);
        defer allocator.free(target_buf);

        const delta = try diffDelta(allocator, base_buf, target_buf);
        defer allocator.free(delta);

        const result = try patch_delta.readerFromDelta(allocator, base_buf, delta);
        defer allocator.free(result);
        try std.testing.expectEqualSlices(u8, target_buf, result);
    }
}

test "DeltaSuite.TestIncompleteDelta" {
    // go-git `TestIncompleteDelta`.
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    for (deltaTestCases()) |tc| {
        const base_buf = try genBytes(allocator, tc.base);
        defer allocator.free(base_buf);
        const target_buf = try genBytes(allocator, tc.target);
        defer allocator.free(target_buf);

        const delta = try diffDelta(allocator, base_buf, target_buf);
        defer allocator.free(delta);

        if (delta.len < 2) continue;
        const truncated = delta[0 .. delta.len - 2];
        try std.testing.expectError(
            error.InvalidDelta,
            patch_delta.patchDelta(allocator, base_buf, truncated),
        );
    }

    // Nil / empty input.
    try std.testing.expectError(
        error.InvalidDelta,
        patch_delta.patchDelta(allocator, &[_]u8{}, &[_]u8{}),
    );
}

test "DeltaSuite.TestMaxCopySizeDelta" {
    // go-git `TestMaxCopySizeDelta`.
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    const base_buf = try randBytes(allocator, max_copy_size, 42);
    defer allocator.free(base_buf);

    var target_list: std.ArrayList(u8) = .empty;
    defer target_list.deinit(allocator);
    try target_list.appendSlice(allocator, base_buf);
    try target_list.append(allocator, 1);
    const target_buf = target_list.items;

    const delta = try diffDelta(allocator, base_buf, target_buf);
    defer allocator.free(delta);

    const result = try patch_delta.patchDelta(allocator, base_buf, delta);
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u8, target_buf, result);
}

test "DeltaSuite.TestMaxCopySizeDeltaReader" {
    // go-git `TestMaxCopySizeDeltaReader`.
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    const base_buf = try randBytes(allocator, max_copy_size, 42);
    defer allocator.free(base_buf);

    var target_list: std.ArrayList(u8) = .empty;
    defer target_list.deinit(allocator);
    try target_list.appendSlice(allocator, base_buf);
    try target_list.append(allocator, 1);
    const target_buf = target_list.items;

    const delta = try diffDelta(allocator, base_buf, target_buf);
    defer allocator.free(delta);

    const result = try patch_delta.readerFromDelta(allocator, base_buf, delta);
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u8, target_buf, result);
}

test "DeltaSuite.GetDelta OFSDelta MemoryObject" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var base = MemoryObject.init(allocator);
    defer base.deinit();
    base.setType(.blob);
    _ = try base.write("AAAAAAAAAAAAAAAA"); // 16 bytes = one block

    var target = MemoryObject.init(allocator);
    defer target.deinit();
    target.setType(.blob);
    _ = try target.write("AAAAAAAAAAAAAAAAB"); // same + one byte

    const delta_obj = try getDelta(allocator, &base, &target);
    defer {
        delta_obj.deinit();
        allocator.destroy(delta_obj);
    }

    try std.testing.expectEqual(plumbing.ObjectType.ofs_delta, delta_obj.object_type);
    try std.testing.expect(delta_obj.size > 0);
    try std.testing.expectEqual(@as(i64, @intCast(delta_obj.readerBytes().len)), delta_obj.size);

    const restored = try patch_delta.patchDelta(allocator, base.readerBytes(), delta_obj.readerBytes());
    defer allocator.free(restored);
    try std.testing.expectEqualSlices(u8, target.readerBytes(), restored);
}

test "deltaEncodeSize known values" {
    const allocator = std.testing.allocator;

    {
        const enc = try deltaEncodeSize(allocator, 0);
        defer allocator.free(enc);
        try std.testing.expectEqualSlices(u8, &[_]u8{0}, enc);
    }
    {
        const enc = try deltaEncodeSize(allocator, 127);
        defer allocator.free(enc);
        try std.testing.expectEqualSlices(u8, &[_]u8{0x7f}, enc);
    }
    {
        const enc = try deltaEncodeSize(allocator, 128);
        defer allocator.free(enc);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x01 }, enc);
    }
    {
        const enc = try deltaEncodeSize(allocator, 255);
        defer allocator.free(enc);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0x01 }, enc);
    }
}

test "DeltaSuite.DiffDelta identical buffers" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    const data = "0123456789abcdef0123456789abcdef"; // 32 bytes
    const delta = try diffDelta(allocator, data, data);
    defer allocator.free(delta);

    const out = try patch_delta.patchDelta(allocator, data, delta);
    defer allocator.free(out);
    try std.testing.expectEqualSlices(u8, data, out);
}

test "many getDelta then deinitPools has zero leaks" {
    // Stress encode path: pooled BytesBuffers + DeltaIndex tables must not
    // leak under testing.allocator when deinitPools runs at the end.
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var base_buf: [256]u8 = undefined;
    @memset(base_buf[0..128], 'a');
    @memset(base_buf[128..256], 'b');

    var base = MemoryObject.init(allocator);
    defer base.deinit();
    base.setType(.blob);
    _ = try base.write(&base_buf);

    // Shared fingerprint index across targets (go-git getDelta reuse).
    var index = DeltaIndex{ .allocator = allocator };
    defer index.deinit();

    var n: usize = 0;
    while (n < 32) : (n += 1) {
        var tgt_buf: [320]u8 = undefined;
        @memcpy(tgt_buf[0..256], &base_buf);
        @memset(tgt_buf[256..320], @as(u8, 'c') +% @as(u8, @intCast(n % 10)));

        var target = MemoryObject.init(allocator);
        defer target.deinit();
        target.setType(.blob);
        _ = try target.write(&tgt_buf);

        // Alternate fresh getDelta and reused-index getDeltaWithIndex.
        const delta_obj = if (n % 2 == 0)
            try getDelta(allocator, &base, &target)
        else
            try getDeltaWithIndex(allocator, &index, &base, &target);
        defer {
            delta_obj.deinit();
            allocator.destroy(delta_obj);
        }

        try std.testing.expectEqual(plumbing.ObjectType.ofs_delta, delta_obj.object_type);
        const restored = try patch_delta.patchDelta(allocator, base.readerBytes(), delta_obj.readerBytes());
        defer allocator.free(restored);
        try std.testing.expectEqualSlices(u8, target.readerBytes(), restored);
    }
}
