//! Line-oriented Myers O(ND) diff (subset of sergi/go-diff DiffMainRunes path).
//!
//! go-git `utils/diff` maps lines to symbols via DiffLinesToRunes, runs Myers on
//! those symbols, then rehydrates with DiffCharsToLines. This module does the
//! equivalent in one step: split lines (keep `\n`), diff lines, coalesce.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Operation kind — same numeric values as `diffmatchpatch.Operation`.
pub const Operation = enum(i8) {
    delete = -1,
    equal = 0,
    insert = 1,
};

/// One diff hunk (go-git / dmp `Diff`).
pub const Diff = struct {
    /// Operation (dmp `Type`).
    operation: Operation,
    /// Owned text for this hunk (concatenated lines, including newlines).
    text: []const u8,

    pub fn deinit(self: Diff, allocator: Allocator) void {
        // Always free: empty toOwnedSlice may still allocate.
        allocator.free(self.text);
    }
};

/// Free a slice of diffs and the slice itself.
/// Always frees every `Diff.text` and the outer slice, including empty
/// allocations (`alloc(0)` / empty `toOwnedSlice`).
pub fn freeDiffs(allocator: Allocator, diffs: []Diff) void {
    for (diffs) |d| d.deinit(allocator);
    allocator.free(diffs);
}

const LineEdit = struct {
    op: Operation,
    line: []const u8,
};

/// Split `text` into lines. Each line includes its trailing `\n` when present.
/// Empty input yields zero lines (matches dmp `diffLinesToStringsMunge`).
pub fn splitLines(allocator: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    if (text.len == 0) return try list.toOwnedSlice(allocator);

    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            try list.append(allocator, text[start .. i + 1]);
            start = i + 1;
        }
    }
    if (start < text.len) try list.append(allocator, text[start..]);
    return try list.toOwnedSlice(allocator);
}

fn vIndex(k: isize, max_d: usize) usize {
    return @intCast(k + @as(isize, @intCast(max_d)));
}

/// Wall-clock nanoseconds (Zig 0.16 has no `std.time.nanoTimestamp`).
fn nowNs() i128 {
    if (@hasDecl(std.time, "nanoTimestamp")) {
        return std.time.nanoTimestamp();
    }
    var ts: std.posix.timespec = undefined;
    const rc = std.posix.system.clock_gettime(.REALTIME, &ts);
    if (rc != 0) return 0;
    return @as(i128, @intCast(ts.sec)) * @as(i128, std.time.ns_per_s) + @as(i128, @intCast(ts.nsec));
}

fn deadlineExceeded(deadline_ns: ?i128) bool {
    const dl = deadline_ns orelse return false;
    return nowNs() >= dl;
}

/// Line-oriented Myers. `timeout_ns` is optional wall-clock budget; null = unlimited.
/// On timeout, uncompared tails become bulk delete + insert (dmp DiffTimeout behaviour).
pub fn lineDiff(
    allocator: Allocator,
    a_text: []const u8,
    b_text: []const u8,
    timeout_ns: ?u64,
) Allocator.Error![]Diff {
    const deadline: ?i128 = if (timeout_ns) |t|
        nowNs() + @as(i128, @intCast(t))
    else
        null;

    const a = try splitLines(allocator, a_text);
    defer allocator.free(a);
    const b = try splitLines(allocator, b_text);
    defer allocator.free(b);

    return lineDiffLines(allocator, a, b, deadline);
}

fn lineDiffLines(
    allocator: Allocator,
    a: []const []const u8,
    b: []const []const u8,
    deadline: ?i128,
) Allocator.Error![]Diff {
    const n: isize = @intCast(a.len);
    const m: isize = @intCast(b.len);

    if (n == 0 and m == 0) {
        return try allocator.alloc(Diff, 0);
    }

    // Fast path: identical sequences → single equal (or empty).
    if (n == m) {
        var same = true;
        var i: usize = 0;
        while (i < a.len) : (i += 1) {
            if (!std.mem.eql(u8, a[i], b[i])) {
                same = false;
                break;
            }
        }
        if (same) {
            return try singleDiff(allocator, .equal, a);
        }
    }

    // Fast path: pure insert / pure delete.
    if (n == 0) return try singleDiff(allocator, .insert, b);
    if (m == 0) return try singleDiff(allocator, .delete, a);

    // Trim common prefix (speedup, matches DiffMainRunes).
    var prefix: usize = 0;
    while (prefix < a.len and prefix < b.len and std.mem.eql(u8, a[prefix], b[prefix])) : (prefix += 1) {}

    // Trim common suffix.
    var suffix: usize = 0;
    while (suffix < a.len - prefix and suffix < b.len - prefix and
        std.mem.eql(u8, a[a.len - 1 - suffix], b[b.len - 1 - suffix])) : (suffix += 1)
    {}

    const a_mid = a[prefix .. a.len - suffix];
    const b_mid = b[prefix .. b.len - suffix];

    var mid_edits = try myersMiddle(allocator, a_mid, b_mid, deadline);
    defer mid_edits.deinit(allocator);

    // LineEdit.line is a view into the original texts; only the ArrayList
    // buffer is owned. Free it on both success and error (not only errdefer).
    var edits: std.ArrayList(LineEdit) = .empty;
    defer edits.deinit(allocator);

    var pi: usize = 0;
    while (pi < prefix) : (pi += 1) {
        try edits.append(allocator, .{ .op = .equal, .line = a[pi] });
    }
    try edits.appendSlice(allocator, mid_edits.items);
    var si: usize = 0;
    while (si < suffix) : (si += 1) {
        try edits.append(allocator, .{ .op = .equal, .line = a[a.len - suffix + si] });
    }

    return try coalesceAndCleanup(allocator, edits.items);
}

fn singleDiff(allocator: Allocator, op: Operation, lines: []const []const u8) Allocator.Error![]Diff {
    if (lines.len == 0) return try allocator.alloc(Diff, 0);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (lines) |line| try buf.appendSlice(allocator, line);
    const text = try buf.toOwnedSlice(allocator);
    errdefer allocator.free(text);
    const out = try allocator.alloc(Diff, 1);
    out[0] = .{ .operation = op, .text = text };
    return out;
}

/// Myers O(ND) over the middle block (no common prefix/suffix).
/// On timeout returns bulk delete+insert of remaining lines.
fn myersMiddle(
    allocator: Allocator,
    a: []const []const u8,
    b: []const []const u8,
    deadline: ?i128,
) Allocator.Error!std.ArrayList(LineEdit) {
    var edits: std.ArrayList(LineEdit) = .empty;
    errdefer edits.deinit(allocator);

    const n: isize = @intCast(a.len);
    const m: isize = @intCast(b.len);

    if (n == 0 and m == 0) return edits;
    if (n == 0) {
        for (b) |line| try edits.append(allocator, .{ .op = .insert, .line = line });
        return edits;
    }
    if (m == 0) {
        for (a) |line| try edits.append(allocator, .{ .op = .delete, .line = line });
        return edits;
    }

    // Shortest-text-inside-longest speedup (dmp diffCompute).
    if (n > m) {
        if (indexOfLines(a, b)) |i| {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                try edits.append(allocator, .{ .op = .delete, .line = a[j] });
            }
            for (b) |line| try edits.append(allocator, .{ .op = .equal, .line = line });
            j = i + b.len;
            while (j < a.len) : (j += 1) {
                try edits.append(allocator, .{ .op = .delete, .line = a[j] });
            }
            return edits;
        }
    } else if (m > n) {
        if (indexOfLines(b, a)) |i| {
            var j: usize = 0;
            while (j < i) : (j += 1) {
                try edits.append(allocator, .{ .op = .insert, .line = b[j] });
            }
            for (a) |line| try edits.append(allocator, .{ .op = .equal, .line = line });
            j = i + a.len;
            while (j < b.len) : (j += 1) {
                try edits.append(allocator, .{ .op = .insert, .line = b[j] });
            }
            return edits;
        }
    }

    // Single-line and not equal → delete + insert.
    if (n == 1 and m == 1) {
        try edits.append(allocator, .{ .op = .delete, .line = a[0] });
        try edits.append(allocator, .{ .op = .insert, .line = b[0] });
        return edits;
    }

    const max_d: usize = @intCast(n + m);
    var v = try allocator.alloc(isize, 2 * max_d + 1);
    defer allocator.free(v);
    @memset(v, 0);

    var trace: std.ArrayList([]isize) = .empty;
    defer {
        for (trace.items) |t| allocator.free(t);
        trace.deinit(allocator);
    }

    var found = false;
    var timed_out = false;
    var d: usize = 0;
    while (d <= max_d) : (d += 1) {
        // Check deadline every iteration (dmp checks every 16 in bisect; small line
        // counts make per-d checks fine and match "best-effort" deadline).
        if (d > 0 and d % 16 == 0 and deadlineExceeded(deadline)) {
            timed_out = true;
            break;
        }

        var k: isize = -@as(isize, @intCast(d));
        while (k <= @as(isize, @intCast(d))) : (k += 2) {
            const down = k == -@as(isize, @intCast(d)) or
                (k != @as(isize, @intCast(d)) and v[vIndex(k - 1, max_d)] < v[vIndex(k + 1, max_d)]);
            var x: isize = if (down) v[vIndex(k + 1, max_d)] else v[vIndex(k - 1, max_d)] + 1;
            var y = x - k;
            while (x < n and y < m and std.mem.eql(u8, a[@intCast(x)], b[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            v[vIndex(k, max_d)] = x;
            if (x >= n and y >= m) {
                found = true;
                break;
            }
        }
        try trace.append(allocator, try allocator.dupe(isize, v));
        if (found) break;
    }

    if (timed_out or !found) {
        // Bulk delete + insert for unfinished middle (dmp DiffTimeout / no path).
        for (a) |line| try edits.append(allocator, .{ .op = .delete, .line = line });
        for (b) |line| try edits.append(allocator, .{ .op = .insert, .line = line });
        return edits;
    }

    // Reconstruct path backwards.
    var rev: std.ArrayList(LineEdit) = .empty;
    defer rev.deinit(allocator);

    var x: isize = n;
    var y: isize = m;
    var di: isize = @intCast(trace.items.len);
    di -= 1;
    while (di >= 0) : (di -= 1) {
        const vv = trace.items[@intCast(di)];
        const dd: usize = @intCast(di);
        const k = x - y;
        const down = k == -@as(isize, @intCast(dd)) or
            (k != @as(isize, @intCast(dd)) and vv[vIndex(k - 1, max_d)] < vv[vIndex(k + 1, max_d)]);
        const prev_k: isize = if (down) k + 1 else k - 1;
        const prev_x = vv[vIndex(prev_k, max_d)];
        const prev_y = prev_x - prev_k;

        while (x > prev_x and y > prev_y) {
            x -= 1;
            y -= 1;
            try rev.append(allocator, .{ .op = .equal, .line = a[@intCast(x)] });
        }
        if (dd == 0) break;
        if (x == prev_x) {
            y -= 1;
            try rev.append(allocator, .{ .op = .insert, .line = b[@intCast(y)] });
        } else {
            x -= 1;
            try rev.append(allocator, .{ .op = .delete, .line = a[@intCast(x)] });
        }
        x = prev_x;
        y = prev_y;
    }

    std.mem.reverse(LineEdit, rev.items);
    try edits.appendSlice(allocator, rev.items);
    return edits;
}

fn indexOfLines(hay: []const []const u8, needle: []const []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > hay.len) return null;
    const last = hay.len - needle.len;
    var i: usize = 0;
    while (i <= last) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (!std.mem.eql(u8, hay[i + j], needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

/// Coalesce consecutive same-ops; force delete-before-insert within edit groups
/// (dmp DiffCleanupMerge first pass without common-prefix factoring of runes).
///
/// Each `Diff.text` is an owned concatenation of the LineEdit line views.
/// Empty results use `toOwnedSlice` so the caller always frees with `freeDiffs`.
fn coalesceAndCleanup(allocator: Allocator, edits: []const LineEdit) Allocator.Error![]Diff {
    // First: reorder insert/delete runs so deletes come before inserts.
    var ordered: std.ArrayList(LineEdit) = .empty;
    defer ordered.deinit(allocator);

    var i: usize = 0;
    while (i < edits.len) {
        if (edits[i].op == .equal) {
            try ordered.append(allocator, edits[i]);
            i += 1;
            continue;
        }
        // Collect a run of non-equal edits.
        var dels: std.ArrayList(LineEdit) = .empty;
        defer dels.deinit(allocator);
        var ins: std.ArrayList(LineEdit) = .empty;
        defer ins.deinit(allocator);
        while (i < edits.len and edits[i].op != .equal) : (i += 1) {
            switch (edits[i].op) {
                .delete => try dels.append(allocator, edits[i]),
                .insert => try ins.append(allocator, edits[i]),
                .equal => unreachable,
            }
        }
        try ordered.appendSlice(allocator, dels.items);
        try ordered.appendSlice(allocator, ins.items);
    }

    // Coalesce consecutive same operations into Diff hunks with owned text.
    var chunks: std.ArrayList(Diff) = .empty;
    errdefer {
        for (chunks.items) |d| d.deinit(allocator);
        chunks.deinit(allocator);
    }
    if (ordered.items.len == 0) return try chunks.toOwnedSlice(allocator);

    var cur_op = ordered.items[0].op;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (ordered.items) |e| {
        if (e.op != cur_op) {
            // Transfer owned text into chunks; free on append failure only.
            const text = try buf.toOwnedSlice(allocator);
            buf = .empty;
            errdefer allocator.free(text);
            try chunks.append(allocator, .{
                .operation = cur_op,
                .text = text,
            });
            cur_op = e.op;
        }
        try buf.appendSlice(allocator, e.line);
    }
    {
        const text = try buf.toOwnedSlice(allocator);
        // buf is emptied by toOwnedSlice; clear so errdefer does not double-free.
        buf = .empty;
        errdefer allocator.free(text);
        try chunks.append(allocator, .{
            .operation = cur_op,
            .text = text,
        });
    }
    return try chunks.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Unit tests (algorithm pieces)
// ---------------------------------------------------------------------------

test "splitLines empty and bare" {
    const gpa = std.testing.allocator;
    {
        const lines = try splitLines(gpa, "");
        defer gpa.free(lines);
        try std.testing.expectEqual(@as(usize, 0), lines.len);
    }
    {
        const lines = try splitLines(gpa, "a");
        defer gpa.free(lines);
        try std.testing.expectEqual(@as(usize, 1), lines.len);
        try std.testing.expectEqualStrings("a", lines[0]);
    }
    {
        const lines = try splitLines(gpa, "a\n");
        defer gpa.free(lines);
        try std.testing.expectEqual(@as(usize, 1), lines.len);
        try std.testing.expectEqualStrings("a\n", lines[0]);
    }
    {
        const lines = try splitLines(gpa, "\n");
        defer gpa.free(lines);
        try std.testing.expectEqual(@as(usize, 1), lines.len);
        try std.testing.expectEqualStrings("\n", lines[0]);
    }
}

test "lineDiff equal short" {
    const gpa = std.testing.allocator;
    const diffs = try lineDiff(gpa, "a\nb\n", "a\nb\n", null);
    defer freeDiffs(gpa, diffs);
    try std.testing.expectEqual(@as(usize, 1), diffs.len);
    try std.testing.expect(diffs[0].operation == .equal);
    try std.testing.expectEqualStrings("a\nb\n", diffs[0].text);
}
