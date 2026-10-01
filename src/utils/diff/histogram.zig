//! Histogram line diff.
//!
//! Clean-room implementation of the published histogram idea: index line
//! counts in the destination region, anchor on the lowest-count match in the
//! source, extend the match over equal neighbours, and recurse on the two
//! sides. Regions past the depth or length bound become a single replace.
//! That replace is a valid diff; it is not claimed to match Git on huge inputs.

const std = @import("std");
const myers = @import("myers.zig");

const Allocator = std.mem.Allocator;

pub const LineEdit = struct {
    op: myers.Operation,
    /// Borrowed from the caller's line slice.
    line: []const u8,
};

const max_depth: usize = 64;
const max_region_lines: usize = 8192;

/// Histogram diff of two texts. Caller frees with `myers.freeDiffs`.
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

    var edits: std.ArrayList(LineEdit) = .empty;
    defer edits.deinit(allocator);
    try diffLines(allocator, a, b, 0, a.len, 0, b.len, 0, &edits);
    return try coalesce(allocator, edits.items);
}

pub fn diffLines(
    allocator: Allocator,
    a: []const []const u8,
    b: []const []const u8,
    a0: usize,
    a1: usize,
    b0: usize,
    b1: usize,
    depth: usize,
    out: *std.ArrayList(LineEdit),
) Allocator.Error!void {
    if (a0 == a1 and b0 == b1) return;
    if (depth > max_depth or a1 - a0 > max_region_lines or b1 - b0 > max_region_lines) {
        try emitReplace(allocator, a, b, a0, a1, b0, b1, out);
        return;
    }
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

    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer counts.deinit(allocator);
    var bi = b0;
    while (bi < b1) : (bi += 1) {
        const gop = try counts.getOrPut(allocator, b[bi]);
        if (gop.found_existing) gop.value_ptr.* += 1 else gop.value_ptr.* = 1;
    }

    var best_count: u32 = std.math.maxInt(u32);
    var best_ai: ?usize = null;
    var ai = a0;
    while (ai < a1) : (ai += 1) {
        const c = counts.get(a[ai]) orelse 0;
        if (c == 0 or c >= best_count) continue;
        best_count = c;
        best_ai = ai;
        if (c == 1) break;
    }

    const anchor = best_ai orelse {
        try emitReplace(allocator, a, b, a0, a1, b0, b1, out);
        return;
    };
    const line = a[anchor];
    var b_anchor = b0;
    while (b_anchor < b1 and !std.mem.eql(u8, b[b_anchor], line)) : (b_anchor += 1) {}
    if (b_anchor == b1) {
        try emitReplace(allocator, a, b, a0, a1, b0, b1, out);
        return;
    }

    var a_lo = anchor;
    var b_lo = b_anchor;
    while (a_lo > a0 and b_lo > b0 and std.mem.eql(u8, a[a_lo - 1], b[b_lo - 1])) {
        a_lo -= 1;
        b_lo -= 1;
    }
    var a_hi = anchor + 1;
    var b_hi = b_anchor + 1;
    while (a_hi < a1 and b_hi < b1 and std.mem.eql(u8, a[a_hi], b[b_hi])) {
        a_hi += 1;
        b_hi += 1;
    }

    try diffLines(allocator, a, b, a0, a_lo, b0, b_lo, depth + 1, out);
    var k = a_lo;
    while (k < a_hi) : (k += 1) try out.append(allocator, .{ .op = .equal, .line = a[k] });
    try diffLines(allocator, a, b, a_hi, a1, b_hi, b1, depth + 1, out);
}

fn emitReplace(
    allocator: Allocator,
    a: []const []const u8,
    b: []const []const u8,
    a0: usize,
    a1: usize,
    b0: usize,
    b1: usize,
    out: *std.ArrayList(LineEdit),
) Allocator.Error!void {
    var i = a0;
    while (i < a1) : (i += 1) try out.append(allocator, .{ .op = .delete, .line = a[i] });
    i = b0;
    while (i < b1) : (i += 1) try out.append(allocator, .{ .op = .insert, .line = b[i] });
}

pub fn coalesce(allocator: Allocator, edits: []const LineEdit) Allocator.Error![]myers.Diff {
    var out: std.ArrayList(myers.Diff) = .empty;
    errdefer {
        for (out.items) |d| d.deinit(allocator);
        out.deinit(allocator);
    }
    var i: usize = 0;
    while (i < edits.len) {
        const op = edits[i].op;
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        while (i < edits.len and edits[i].op == op) : (i += 1) {
            try buf.appendSlice(allocator, edits[i].line);
        }
        try out.append(allocator, .{ .operation = op, .text = try buf.toOwnedSlice(allocator) });
    }
    return try out.toOwnedSlice(allocator);
}

test "histogram anchors a unique changed line" {
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
