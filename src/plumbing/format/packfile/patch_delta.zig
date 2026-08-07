//! Apply git packfile deltas (go-git `plumbing/format/packfile/patch_delta.go`).
//!
//! Delta format references (same as go-git):
//! - https://github.com/git/git/blob/49fa3dc76179e04b0833542fa52d0f287a4955ac/delta.h
//! - https://github.com/git/git/blob/c2c5f6b1e479f2c38e0e01345350620944e3527f/patch-delta.c

const std = @import("std");
const Allocator = std.mem.Allocator;

const plumbing = @import("plumbing");
const MemoryObject = plumbing.MemoryObject;

const Error = @import("error.zig").Error;

/// 7-bit payload mask for LEB128 (`payload` in go-git).
const payload: u8 = 0x7f;
/// Continuation bit (`continuation` in go-git).
const continuation: u8 = 0x80;

/// Max preemptive grow for patch buffer (go-git `maxPatchPreemptionSize`).
const max_patch_preemption_size: usize = 65536;

/// Smallest valid delta: 1-byte srcSz LEB128 + 1-byte targetSz LEB128
/// (go-git `minDeltaSize`).
const min_delta_size: usize = 2;

/// Max size of a copy-from-src operation when size fields are zero
/// (go-git `maxCopySize` in `diff_delta.go`).
const max_copy_size: usize = 64 * 1024;

/// Bit width of `usize` on this platform (go-git `uintBits`).
const usize_bits: usize = @bitSizeOf(usize);

const OffsetField = struct {
    mask: u8,
    shift: u6,
};

const offsets = [_]OffsetField{
    .{ .mask = 0x01, .shift = 0 },
    .{ .mask = 0x02, .shift = 8 },
    .{ .mask = 0x04, .shift = 16 },
    .{ .mask = 0x08, .shift = 24 },
};

const sizes = [_]OffsetField{
    .{ .mask = 0x10, .shift = 0 },
    .{ .mask = 0x20, .shift = 8 },
    .{ .mask = 0x40, .shift = 16 },
};

/// Apply modification deltas in `delta` to `src` and return a new buffer
/// (go-git `PatchDelta`). Caller owns the result and must free with `allocator`.
///
/// Errors: `error.InvalidDelta` if the stream is corrupt; `error.DeltaCmd` if a
/// command is neither copy-from-src nor copy-from-delta; `error.LengthOverflow`
/// if a LEB128 size does not fit in `usize`.
pub fn patchDelta(allocator: Allocator, src: []const u8, delta: []const u8) (Error || Allocator.Error)![]u8 {
    if (src.len == 0 or delta.len < min_delta_size) {
        return error.InvalidDelta;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try patchDeltaInto(allocator, &out, src, delta);
    return try out.toOwnedSlice(allocator);
}

/// Write to `target` the result of applying `delta` to `base`
/// (go-git `ApplyDelta`).
pub fn applyDelta(
    allocator: Allocator,
    target: *MemoryObject,
    base: *const MemoryObject,
    delta: []const u8,
) (Error || Allocator.Error)!void {
    const src = base.readerBytes();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try patchDeltaInto(allocator, &out, src, delta);
    try target.setContent(out.items);
}

/// Core apply loop (go-git private `patchDelta`).
fn patchDeltaInto(
    allocator: Allocator,
    dst: *std.ArrayList(u8),
    src: []const u8,
    delta_in: []const u8,
) (Error || Allocator.Error)!void {
    var delta = delta_in;

    const src_sz_res = try decodeLEB128(delta);
    // go-git wraps LEB128 errors with ErrInvalidDelta; LengthOverflow is
    // returned as-is from decodeLEB128 and propagates here.
    delta = src_sz_res.rest;
    if (src_sz_res.num != src.len) {
        return error.InvalidDelta;
    }
    const src_sz = src_sz_res.num;

    const target_sz_res = try decodeLEB128(delta);
    delta = target_sz_res.rest;
    const target_sz = target_sz_res.num;
    var remaining_target_sz = target_sz;

    const grow_sz = @min(target_sz, max_patch_preemption_size);
    try dst.ensureTotalCapacity(allocator, grow_sz);

    while (remaining_target_sz > 0) {
        if (delta.len == 0) {
            return error.InvalidDelta;
        }

        const cmd = delta[0];
        delta = delta[1..];

        if (isCopyFromSrc(cmd)) {
            const off_res = try decodeOffset(cmd, delta);
            delta = off_res.rest;
            const offset = off_res.num;

            const sz_res = try decodeSize(cmd, delta);
            delta = sz_res.rest;
            const sz = sz_res.num;

            if (invalidSize(sz, remaining_target_sz) or
                invalidOffsetSize(offset, sz, src_sz))
            {
                return error.InvalidDelta;
            }
            try dst.appendSlice(allocator, src[offset .. offset + sz]);
            remaining_target_sz -= sz;
        } else if (isCopyFromDelta(cmd)) {
            const sz: usize = cmd; // cmd is the size itself
            if (invalidSize(sz, remaining_target_sz)) {
                return error.InvalidDelta;
            }
            if (delta.len < sz) {
                return error.InvalidDelta;
            }
            try dst.appendSlice(allocator, delta[0..sz]);
            remaining_target_sz -= sz;
            delta = delta[sz..];
        } else {
            return error.DeltaCmd;
        }
    }

    // Mirror upstream `data != top` post-loop check: every byte of the
    // delta payload must be consumed.
    if (delta.len != 0) {
        return error.InvalidDelta;
    }
}

/// Decode an unsigned LEB128 at the start of `input`
/// (go-git `decodeLEB128`).
///
/// Returns the number and the remaining slice. Empty input yields `{0, input}`.
fn decodeLEB128(input: []const u8) Error!struct { num: usize, rest: []const u8 } {
    if (input.len == 0) {
        return .{ .num = 0, .rest = input };
    }

    var num: usize = 0;
    var sz: usize = 0;
    while (true) {
        // A continuation byte at shift > usize_bits-7 cannot contribute
        // without overflowing the accumulator.
        if (sz * 7 > usize_bits - 7) {
            return error.LengthOverflow;
        }

        const b = input[sz];
        num |= @as(usize, b & payload) << @intCast(sz * 7);
        sz += 1;

        if ((b & continuation) == 0 or sz == input.len) {
            break;
        }
    }

    return .{ .num = num, .rest = input[sz..] };
}

fn isCopyFromSrc(cmd: u8) bool {
    return (cmd & continuation) != 0;
}

fn isCopyFromDelta(cmd: u8) bool {
    return (cmd & continuation) == 0 and cmd != 0;
}

fn decodeOffset(cmd: u8, delta_in: []const u8) Error!struct { num: usize, rest: []const u8 } {
    var delta = delta_in;
    var offset: usize = 0;
    for (offsets) |o| {
        if ((cmd & o.mask) != 0) {
            if (delta.len == 0) {
                return error.InvalidDelta;
            }
            offset |= @as(usize, delta[0]) << o.shift;
            delta = delta[1..];
        }
    }
    return .{ .num = offset, .rest = delta };
}

fn decodeSize(cmd: u8, delta_in: []const u8) Error!struct { num: usize, rest: []const u8 } {
    var delta = delta_in;
    var sz: usize = 0;
    for (sizes) |s| {
        if ((cmd & s.mask) != 0) {
            if (delta.len == 0) {
                return error.InvalidDelta;
            }
            sz |= @as(usize, delta[0]) << s.shift;
            delta = delta[1..];
        }
    }
    if (sz == 0) {
        sz = max_copy_size;
    }
    return .{ .num = sz, .rest = delta };
}

/// Whether `sz` exceeds the remaining target size (go-git `invalidSize`).
fn invalidSize(sz: usize, remaining: usize) bool {
    return sz > remaining;
}

fn invalidOffsetSize(offset: usize, sz: usize, src_sz: usize) bool {
    return sumOverflows(offset, sz) or offset + sz > src_sz;
}

fn sumOverflows(a: usize, b: usize) bool {
    return a +% b < a;
}

// ---------------------------------------------------------------------------
// Tests (go-git `patch_delta_test.go` + apply vectors from `delta_test.go`)
// ---------------------------------------------------------------------------

/// Encode size as unsigned LEB128 into `buf` (go-git `deltaEncodeSize`).
/// Returns the encoded length. `buf` must hold at least 10 bytes (64-bit usize).
fn deltaEncodeSizeInto(buf: *[10]u8, size: usize) usize {
    var n: usize = 0;
    var s = size;
    var c: u8 = @truncate(s & 0x7f);
    s >>= 7;
    while (s != 0) {
        buf[n] = c | 0x80;
        n += 1;
        c = @truncate(s & 0x7f);
        s >>= 7;
    }
    buf[n] = c;
    n += 1;
    return n;
}

/// Append LEB128 size encoding into `list`.
fn appendDeltaEncodeSize(list: *std.ArrayList(u8), allocator: Allocator, size: usize) !void {
    var tmp: [10]u8 = undefined;
    const n = deltaEncodeSizeInto(&tmp, size);
    try list.appendSlice(allocator, tmp[0..n]);
}

/// Encode a copy-from-src op (go-git `encodeCopyOperation`) — test helper.
fn encodeCopyOperation(allocator: Allocator, offset: usize, length: usize) ![]u8 {
    var code: u8 = 0x80;
    var opcodes: std.ArrayList(u8) = .empty;
    defer opcodes.deinit(allocator);

    var i: u3 = 0;
    while (i < 4) : (i += 1) {
        const shift: u6 = @as(u6, i) * 8;
        const f: usize = @as(usize, 0xff) << shift;
        if (offset & f != 0) {
            try opcodes.append(allocator, @truncate((offset & f) >> shift));
            code |= @as(u8, 0x01) << i;
        }
    }

    i = 0;
    while (i < 3) : (i += 1) {
        const shift: u6 = @as(u6, i) * 8;
        const f: usize = @as(usize, 0xff) << shift;
        if (length & f != 0) {
            try opcodes.append(allocator, @truncate((length & f) >> shift));
            code |= @as(u8, 0x10) << i;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, code);
    try out.appendSlice(allocator, opcodes.items);
    return try out.toOwnedSlice(allocator);
}

/// Build a full delta stream (go-git `buildDelta` test helper).
fn buildDelta(allocator: Allocator, src_sz: usize, target_sz: usize, ops: []const []const u8) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(allocator);
    try appendDeltaEncodeSize(&b, allocator, src_sz);
    try appendDeltaEncodeSize(&b, allocator, target_sz);
    for (ops) |op| {
        try b.appendSlice(allocator, op);
    }
    return try b.toOwnedSlice(allocator);
}

/// Encode a copy-from-delta (insert) op (go-git `insertOp`).
fn insertOp(allocator: Allocator, data: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, @intCast(data.len));
    try out.appendSlice(allocator, data);
    return try out.toOwnedSlice(allocator);
}

/// genBytes from go-git `common_test.go`.
const GenPiece = struct { val: []const u8, times: usize };
fn genBytes(allocator: Allocator, pieces: []const GenPiece) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (pieces) |e| {
        var i: usize = 0;
        while (i < e.times) : (i += 1) {
            try result.appendSlice(allocator, e.val);
        }
    }
    return try result.toOwnedSlice(allocator);
}

test "decodeLEB128 overflow" {
    // Eleven continuation bytes push shift past usize bit width (go-git
    // TestDecodeLEB128Overflow).
    var input: [12]u8 = undefined;
    @memset(input[0..11], 0x80);
    input[11] = 0x01;

    const result = decodeLEB128(&input);
    try std.testing.expectError(error.LengthOverflow, result);
}

test "decodeLEB128 vectors" {
    const Case = struct {
        input: []const u8,
        want: usize,
        want_rest: []const u8,
    };
    const cases = [_]Case{
        .{ .input = &[_]u8{ 0x01, 0xFF }, .want = 1, .want_rest = &[_]u8{0xFF} },
        .{ .input = &[_]u8{ 0x7F, 0xFF }, .want = 127, .want_rest = &[_]u8{0xFF} },
        .{ .input = &[_]u8{ 0x80, 0x01, 0xFF }, .want = 128, .want_rest = &[_]u8{0xFF} },
        .{ .input = &[_]u8{ 0xFF, 0x01, 0xFF }, .want = 255, .want_rest = &[_]u8{0xFF} },
        .{ .input = &[_]u8{ 0x80, 0x80, 0x01, 0xFF }, .want = 16384, .want_rest = &[_]u8{0xFF} },
        .{ .input = &[_]u8{0x01}, .want = 1, .want_rest = &[_]u8{} },
        .{ .input = &[_]u8{}, .want = 0, .want_rest = &[_]u8{} },
    };

    for (cases) |tc| {
        const got = try decodeLEB128(tc.input);
        try std.testing.expectEqual(tc.want, got.num);
        try std.testing.expectEqualSlices(u8, tc.want_rest, got.rest);
    }
}

test "patchDelta rejects oversized copies" {
    const allocator = std.testing.allocator;
    const src = try allocator.alloc(u8, 64);
    defer allocator.free(src);
    @memset(src, 'A');

    // copy-from-src cumulative overflow: two 63-byte copies vs targetSz 64.
    {
        const op1 = try encodeCopyOperation(allocator, 0, 63);
        defer allocator.free(op1);
        const op2 = try encodeCopyOperation(allocator, 0, 63);
        defer allocator.free(op2);
        const delta = try buildDelta(allocator, 64, 64, &[_][]const u8{ op1, op2 });
        defer allocator.free(delta);

        try std.testing.expectError(error.InvalidDelta, patchDelta(allocator, src, delta));

        // Buffer must never grow past targetSz (go-git assertion).
        var b: std.ArrayList(u8) = .empty;
        defer b.deinit(allocator);
        _ = patchDeltaInto(allocator, &b, src, delta) catch {};
        try std.testing.expect(b.items.len <= 64);
    }

    // copy-from-delta cumulative overflow: two 7-byte inserts vs targetSz 10.
    {
        const ins = [_]u8{ 'x', 'x', 'x', 'x', 'x', 'x', 'x' };
        const op1 = try insertOp(allocator, &ins);
        defer allocator.free(op1);
        const op2 = try insertOp(allocator, &ins);
        defer allocator.free(op2);
        const delta = try buildDelta(allocator, 64, 10, &[_][]const u8{ op1, op2 });
        defer allocator.free(delta);

        try std.testing.expectError(error.InvalidDelta, patchDelta(allocator, src, delta));

        var b: std.ArrayList(u8) = .empty;
        defer b.deinit(allocator);
        _ = patchDeltaInto(allocator, &b, src, delta) catch {};
        try std.testing.expect(b.items.len <= 10);
    }
}

test "patchDelta rejects trailing bytes" {
    const allocator = std.testing.allocator;
    const src = try allocator.alloc(u8, 64);
    defer allocator.free(src);
    @memset(src, 'A');

    const copy = try encodeCopyOperation(allocator, 0, 64);
    defer allocator.free(copy);
    const trailing = [_]u8{ 0x00, 0x01, 0x02 };
    const delta = try buildDelta(allocator, 64, 64, &[_][]const u8{ copy, &trailing });
    defer allocator.free(delta);

    try std.testing.expectError(error.InvalidDelta, patchDelta(allocator, src, delta));
}

test "patchDelta accepts empty target" {
    const allocator = std.testing.allocator;
    const src = "hello";
    const delta = try buildDelta(allocator, src.len, 0, &[_][]const u8{});
    defer allocator.free(delta);

    const out = try patchDelta(allocator, src, delta);
    defer allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "patchDelta nil and empty inputs" {
    const allocator = std.testing.allocator;
    // go-git TestIncompleteDelta nil input.
    try std.testing.expectError(error.InvalidDelta, patchDelta(allocator, &[_]u8{}, &[_]u8{}));
    try std.testing.expectError(error.InvalidDelta, patchDelta(allocator, "x", &[_]u8{}));
    try std.testing.expectError(error.InvalidDelta, patchDelta(allocator, "x", &[_]u8{0x01}));
}

test "patchDelta pure insert" {
    // Fuzz corpus vector: src "some value", delta replaces with "somenewvalue".
    const allocator = std.testing.allocator;
    const src = "some value";
    const delta = "\n\x0c\x0csomenewvalue";
    const out = try patchDelta(allocator, src, delta);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("somenewvalue", out);
}

test "patchDelta copy from source" {
    const allocator = std.testing.allocator;
    const src = "ABCDEFGH";
    // srcSz=8, targetSz=4, copy offset 2 size 4 => "CDEF"
    const copy = try encodeCopyOperation(allocator, 2, 4);
    defer allocator.free(copy);
    const delta = try buildDelta(allocator, src.len, 4, &[_][]const u8{copy});
    defer allocator.free(delta);

    const out = try patchDelta(allocator, src, delta);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("CDEF", out);
}

test "patchDelta copy then insert" {
    const allocator = std.testing.allocator;
    const src = "hello";
    const ins = try insertOp(allocator, " world");
    defer allocator.free(ins);
    const copy = try encodeCopyOperation(allocator, 0, 5);
    defer allocator.free(copy);
    const delta = try buildDelta(allocator, src.len, 11, &[_][]const u8{ copy, ins });
    defer allocator.free(delta);

    const out = try patchDelta(allocator, src, delta);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello world", out);
}

test "patchDelta same file identity via full copy" {
    // go-git DeltaSuite "same file" shape without DiffDelta: full src copy.
    const allocator = std.testing.allocator;
    const src = try genBytes(allocator, &[_]GenPiece{
        .{ .val = "1", .times = 3000 },
    });
    defer allocator.free(src);

    const copy = try encodeCopyOperation(allocator, 0, src.len);
    defer allocator.free(copy);
    const delta = try buildDelta(allocator, src.len, src.len, &[_][]const u8{copy});
    defer allocator.free(delta);

    const out = try patchDelta(allocator, src, delta);
    defer allocator.free(out);
    try std.testing.expectEqualSlices(u8, src, out);
}

test "patchDelta distinct file pure insert" {
    // go-git "distinct file" shape: no shared content, all inserts.
    const allocator = std.testing.allocator;
    const base = try genBytes(allocator, &[_]GenPiece{
        .{ .val = "0", .times = 300 },
    });
    defer allocator.free(base);
    const target = try genBytes(allocator, &[_]GenPiece{
        .{ .val = "2", .times = 200 },
    });
    defer allocator.free(target);

    // Insert in chunks of at most 127 (copy-from-delta cmd is 1 byte size).
    var ops: std.ArrayList([]const u8) = .empty;
    defer {
        for (ops.items) |op| allocator.free(op);
        ops.deinit(allocator);
    }
    var off: usize = 0;
    while (off < target.len) {
        const n = @min(@as(usize, 127), target.len - off);
        const op = try insertOp(allocator, target[off .. off + n]);
        try ops.append(allocator, op);
        off += n;
    }
    const delta = try buildDelta(allocator, base.len, target.len, ops.items);
    defer allocator.free(delta);

    const out = try patchDelta(allocator, base, delta);
    defer allocator.free(out);
    try std.testing.expectEqualSlices(u8, target, out);
}

test "patchDelta incomplete delta" {
    // go-git TestIncompleteDelta: truncate a valid delta by 2 bytes.
    const allocator = std.testing.allocator;
    const src = "ABCDEFGH";
    const copy = try encodeCopyOperation(allocator, 0, 8);
    defer allocator.free(copy);
    const full = try buildDelta(allocator, src.len, 8, &[_][]const u8{copy});
    defer allocator.free(full);
    try std.testing.expect(full.len >= 2);
    const truncated = full[0 .. full.len - 2];
    try std.testing.expectError(error.InvalidDelta, patchDelta(allocator, src, truncated));
}

test "patchDelta wrong delta command" {
    const allocator = std.testing.allocator;
    const src = "AB";
    // cmd 0x00 is neither copy-from-src nor copy-from-delta (go-git ErrDeltaCmd).
    const delta = try buildDelta(allocator, src.len, 1, &[_][]const u8{&[_]u8{0x00}});
    defer allocator.free(delta);
    try std.testing.expectError(error.DeltaCmd, patchDelta(allocator, src, delta));
}

test "patchDelta max copy size default" {
    // When size bits are all clear, copy size is max_copy_size (64KiB).
    const allocator = std.testing.allocator;
    const src = try allocator.alloc(u8, max_copy_size);
    defer allocator.free(src);
    @memset(src, 'Z');

    // cmd = 0x80 only: no offset bytes (offset 0), no size bytes => sz = 64KiB.
    const op = [_]u8{0x80};
    const delta = try buildDelta(allocator, max_copy_size, max_copy_size, &[_][]const u8{&op});
    defer allocator.free(delta);

    const out = try patchDelta(allocator, src, delta);
    defer allocator.free(out);
    try std.testing.expectEqualSlices(u8, src, out);
}

test "applyDelta writes target content and size" {
    const allocator = std.testing.allocator;

    var base = MemoryObject.init(allocator);
    defer base.deinit();
    _ = try base.write("hello");

    var target = MemoryObject.init(allocator);
    defer target.deinit();

    const ins = try insertOp(allocator, " world");
    defer allocator.free(ins);
    const copy = try encodeCopyOperation(allocator, 0, 5);
    defer allocator.free(copy);
    const delta = try buildDelta(allocator, 5, 11, &[_][]const u8{ copy, ins });
    defer allocator.free(delta);

    try applyDelta(allocator, &target, &base, delta);
    try std.testing.expectEqual(@as(i64, 11), target.size);
    try std.testing.expectEqualStrings("hello world", target.readerBytes());
}

test "applyDelta invalid base size" {
    const allocator = std.testing.allocator;

    var base = MemoryObject.init(allocator);
    defer base.deinit();
    _ = try base.write("hi"); // len 2

    var target = MemoryObject.init(allocator);
    defer target.deinit();

    // Header claims srcSz=5.
    const delta = try buildDelta(allocator, 5, 0, &[_][]const u8{});
    defer allocator.free(delta);

    try std.testing.expectError(error.InvalidDelta, applyDelta(allocator, &target, &base, delta));
}

test "deltaEncodeSizeInto known values" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), deltaEncodeSizeInto(&buf, 0));
    try std.testing.expectEqual(@as(u8, 0), buf[0]);

    try std.testing.expectEqual(@as(usize, 1), deltaEncodeSizeInto(&buf, 127));
    try std.testing.expectEqual(@as(u8, 0x7f), buf[0]);

    try std.testing.expectEqual(@as(usize, 2), deltaEncodeSizeInto(&buf, 128));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x80, 0x01 }, buf[0..2]);

    try std.testing.expectEqual(@as(usize, 2), deltaEncodeSizeInto(&buf, 255));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0x01 }, buf[0..2]);
}
