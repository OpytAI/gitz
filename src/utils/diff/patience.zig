//! Patience line diff.
//!
//! Clean-room implementation of Bram Cohen's patience diff: lines that occur
//! once on each side are anchors, the longest increasing subsequence of those
//! anchors is kept, and the gaps are solved the same way. A gap with no
//! unique line falls back to the histogram diff.

const std = @import("std");
const myers = @import("myers.zig");
const histogram = @import("histogram.zig");

const Allocator = std.mem.Allocator;

const max_depth: usize = 64;

const Match = struct {
    a: usize,
    b: usize,
    prev: isize = -1,
};

/// Patience diff of two texts. Caller frees with `myers.freeDiffs`.
pub fn lineDiff(allocator: Allocator, src_text: []const u8, dst_text: []const u8) Allocator.Error![]myers.Diff {
    if (std.mem.eql(u8, src_text, dst_text)) {
        if (src_text.len == 0) return try allocator.alloc(myers.Diff, 0);
        const text = try allocator.dupe(u8, src_text);
        errdefer allocator.free(text);
        const out = try allocator.alloc(myers.Diff, 1);
        out[0] = .{ .operation = .equal, .text = text };
        return out;
    }

    const a = try myers.splitLines(allocator, src_text);
    defer allocator.free(a);
    const b = try myers.splitLines(allocator, dst_text);
    defer allocator.free(b);

    var edits: std.ArrayList(histogram.LineEdit) = .empty;
    defer edits.deinit(allocator);
    try diffRegion(allocator, a, b, 0, a.len, 0, b.len, 0, &edits);
    return try histogram.coalesce(allocator, edits.items);
}

fn diffRegion(
    allocator: Allocator,
    a: []const []const u8,
    b: []const []const u8,
    a0: usize,
    a1: usize,
    b0: usize,
    b1: usize,
    depth: usize,
    out: *std.ArrayList(histogram.LineEdit),
) Allocator.Error!void {
    if (a0 == a1 and b0 == b1) return;
    if (a0 == a1) {
        var i = b0;
        while (i < b1) : (i += 1) try out.append(allocator, .{ .op = .insert, .line = b[i] });
        return;
    }
    if (b0 == b1) {
        var i = a0;
        while (i < a1) : (i += 1) try out.append(allocator, .{ .op = .delete, .line = a[i] });
        return;
    }
    if (depth > max_depth) {
        try histogram.diffLines(allocator, a, b, a0, a1, b0, b1, 0, out);
        return;
    }

    const anchors = try uniqueLis(allocator, a, b, a0, a1, b0, b1);
    defer allocator.free(anchors);
    if (anchors.len == 0) {
        try histogram.diffLines(allocator, a, b, a0, a1, b0, b1, 0, out);
        return;
    }

    var prev_a = a0;
    var prev_b = b0;
    for (anchors) |m| {
        try diffRegion(allocator, a, b, prev_a, m.a, prev_b, m.b, depth + 1, out);
        try out.append(allocator, .{ .op = .equal, .line = a[m.a] });
        prev_a = m.a + 1;
        prev_b = m.b + 1;
    }
    try diffRegion(allocator, a, b, prev_a, a1, prev_b, b1, depth + 1, out);
}

/// Unique common lines, in A order, reduced to the LIS of their B positions.
/// Caller frees the slice. Match fields borrow no heap beyond the slice.
fn uniqueLis(
    allocator: Allocator,
    a: []const []const u8,
    b: []const []const u8,
    a0: usize,
    a1: usize,
    b0: usize,
    b1: usize,
) Allocator.Error![]Match {
    var count_a: std.StringHashMapUnmanaged(u32) = .empty;
    defer count_a.deinit(allocator);
    var count_b: std.StringHashMapUnmanaged(u32) = .empty;
    defer count_b.deinit(allocator);
    var pos_b: std.StringHashMapUnmanaged(usize) = .empty;
    defer pos_b.deinit(allocator);

    var i = a0;
    while (i < a1) : (i += 1) {
        const gop = try count_a.getOrPut(allocator, a[i]);
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
    }
    i = b0;
    while (i < b1) : (i += 1) {
        const gop = try count_b.getOrPut(allocator, b[i]);
        if (gop.found_existing) gop.value_ptr.* += 1 else {
            gop.value_ptr.* = 1;
            try pos_b.put(allocator, b[i], i);
        }
    }

    var matches: std.ArrayList(Match) = .empty;
    errdefer matches.deinit(allocator);
    i = a0;
    while (i < a1) : (i += 1) {
        if ((count_a.get(a[i]) orelse 0) != 1) continue;
        if ((count_b.get(a[i]) orelse 0) != 1) continue;
        const bp = pos_b.get(a[i]) orelse continue;
        try matches.append(allocator, .{ .a = i, .b = bp });
    }
    if (matches.items.len == 0) return try matches.toOwnedSlice(allocator);

    const keep = try lisIndices(allocator, matches.items);
    defer allocator.free(keep);
    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(allocator);
    for (keep) |idx| try out.append(allocator, matches.items[idx]);
    matches.deinit(allocator);
    return try out.toOwnedSlice(allocator);
}

/// Indices of an LIS by `Match.b`, stable for equal tails (leftmost pile).
fn lisIndices(allocator: Allocator, matches: []Match) Allocator.Error![]usize {
    var piles: std.ArrayList(usize) = .empty;
    defer piles.deinit(allocator);
    for (matches, 0..) |*m, idx| {
        var lo: usize = 0;
        var hi: usize = piles.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (matches[piles.items[mid]].b < m.b) lo = mid + 1 else hi = mid;
        }
        if (lo > 0) m.prev = @intCast(piles.items[lo - 1]);
        if (lo == piles.items.len) try piles.append(allocator, idx) else piles.items[lo] = idx;
    }
    if (piles.items.len == 0) return try allocator.alloc(usize, 0);

    const out = try allocator.alloc(usize, piles.items.len);
    var n = piles.items.len;
    var cur: isize = @intCast(piles.items[n - 1]);
    while (cur >= 0) {
        n -= 1;
        out[n] = @intCast(cur);
        cur = matches[@intCast(cur)].prev;
    }
    return out;
}

test "patience anchors a unique changed line" {
    const gpa = std.testing.allocator;
    const diffs = try lineDiff(gpa, "a\nb\nc\n", "a\nX\nc\n");
    defer myers.freeDiffs(gpa, diffs);
    try std.testing.expectEqual(@as(usize, 4), diffs.len);
    try std.testing.expectEqual(myers.Operation.equal, diffs[0].operation);
    try std.testing.expectEqualStrings("a\n", diffs[0].text);
    try std.testing.expectEqual(myers.Operation.delete, diffs[1].operation);
    try std.testing.expectEqualStrings("b\n", diffs[1].text);
    try std.testing.expectEqual(myers.Operation.insert, diffs[2].operation);
    try std.testing.expectEqualStrings("X\n", diffs[2].text);
    try std.testing.expectEqual(myers.Operation.equal, diffs[3].operation);
    try std.testing.expectEqualStrings("c\n", diffs[3].text);
}

test "patience falls back when every line is repeated" {
    const gpa = std.testing.allocator;
    const diffs = try lineDiff(gpa, "a\na\n", "a\nb\n");
    defer myers.freeDiffs(gpa, diffs);
    var src_buf: std.ArrayList(u8) = .empty;
    defer src_buf.deinit(gpa);
    var dst_buf: std.ArrayList(u8) = .empty;
    defer dst_buf.deinit(gpa);
    for (diffs) |d| {
        if (d.operation != .insert) try src_buf.appendSlice(gpa, d.text);
        if (d.operation != .delete) try dst_buf.appendSlice(gpa, d.text);
    }
    try std.testing.expectEqualStrings("a\na\n", src_buf.items);
    try std.testing.expectEqualStrings("a\nb\n", dst_buf.items);
}
