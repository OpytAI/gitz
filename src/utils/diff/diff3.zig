//! Three-way line merge.
//!
//! Clean-room diff3. A change on one side is taken as-is. Changes whose
//! ancestor ranges overlap or abut are one conflict: Git's histogram merge
//! treats adjacent edits as the same region, and one unchanged line between
//! them is enough to keep both. `zdiff3` moves a shared prefix and suffix of
//! the two sides out of the markers, and trims the same edges from the base
//! only when those base lines are the lines that were peeled.

const std = @import("std");
const myers = @import("myers.zig");
const histogram = @import("histogram.zig");
const patience = @import("patience.zig");

const Allocator = std.mem.Allocator;

/// Line diff used to derive each side's edit script.
pub const Algorithm = enum { histogram, myers, minimal, patience };

pub const ConflictStyle = enum { merge, diff3, zdiff3 };

pub const Favor = enum { none, ours, theirs };

pub const Labels = struct {
    ours: []const u8,
    theirs: []const u8,
    base: []const u8,
};

/// Owned merge text. `clean` is false when conflict markers were written.
pub const TextMerge = struct {
    bytes: []u8,
    clean: bool,

    pub fn deinit(self: *TextMerge, allocator: Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

const Change = struct {
    a_lo: usize,
    a_hi: usize,
    side_lo: usize,
    side_hi: usize,
};

const LineRef = struct { text: []const u8 };

/// Merge `ours` and `theirs` against `base`. Caller `deinit`s the result.
pub fn mergeText(
    allocator: Allocator,
    algorithm: Algorithm,
    style: ConflictStyle,
    favor: Favor,
    labels: Labels,
    base_text: []const u8,
    ours_text: []const u8,
    theirs_text: []const u8,
) Allocator.Error!TextMerge {
    const base_lines = try myers.splitLines(allocator, base_text);
    defer allocator.free(base_lines);
    const ours_lines = try myers.splitLines(allocator, ours_text);
    defer allocator.free(ours_lines);
    const theirs_lines = try myers.splitLines(allocator, theirs_text);
    defer allocator.free(theirs_lines);

    const ours_diff = try lineDiff(allocator, algorithm, base_text, ours_text);
    defer myers.freeDiffs(allocator, ours_diff);
    const theirs_diff = try lineDiff(allocator, algorithm, base_text, theirs_text);
    defer myers.freeDiffs(allocator, theirs_diff);

    const ours_changes = try changesFrom(allocator, ours_diff);
    defer allocator.free(ours_changes);
    const theirs_changes = try changesFrom(allocator, theirs_diff);
    defer allocator.free(theirs_changes);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var clean = true;

    var a_pos: usize = 0;
    var oi: usize = 0;
    var ti: usize = 0;
    while (oi < ours_changes.len or ti < theirs_changes.len) {
        const o_lo = if (oi < ours_changes.len) ours_changes[oi].a_lo else base_lines.len;
        const t_lo = if (ti < theirs_changes.len) theirs_changes[ti].a_lo else base_lines.len;
        const next = @min(o_lo, t_lo);
        if (next > a_pos) {
            try appendLines(&out, allocator, base_lines[a_pos..next]);
            a_pos = next;
        }

        const o_here = oi < ours_changes.len and ours_changes[oi].a_lo == a_pos;
        const t_here = ti < theirs_changes.len and theirs_changes[ti].a_lo == a_pos;
        if (o_here and t_here) {
            const conflicted = try emitRegion(
                allocator,
                &out,
                style,
                favor,
                labels,
                base_lines,
                ours_lines,
                theirs_lines,
                ours_changes,
                theirs_changes,
                &oi,
                &ti,
                &a_pos,
            );
            if (conflicted) clean = false;
            continue;
        }
        if (o_here) {
            const end = ours_changes[oi].a_hi;
            if (ti < theirs_changes.len and theirs_changes[ti].a_lo <= end) {
                const conflicted = try emitRegion(
                    allocator,
                    &out,
                    style,
                    favor,
                    labels,
                    base_lines,
                    ours_lines,
                    theirs_lines,
                    ours_changes,
                    theirs_changes,
                    &oi,
                    &ti,
                    &a_pos,
                );
                if (conflicted) clean = false;
            } else {
                try appendLines(&out, allocator, ours_lines[ours_changes[oi].side_lo..ours_changes[oi].side_hi]);
                a_pos = end;
                oi += 1;
            }
            continue;
        }
        if (t_here) {
            const end = theirs_changes[ti].a_hi;
            if (oi < ours_changes.len and ours_changes[oi].a_lo <= end) {
                const conflicted = try emitRegion(
                    allocator,
                    &out,
                    style,
                    favor,
                    labels,
                    base_lines,
                    ours_lines,
                    theirs_lines,
                    ours_changes,
                    theirs_changes,
                    &oi,
                    &ti,
                    &a_pos,
                );
                if (conflicted) clean = false;
            } else {
                try appendLines(&out, allocator, theirs_lines[theirs_changes[ti].side_lo..theirs_changes[ti].side_hi]);
                a_pos = end;
                ti += 1;
            }
            continue;
        }
        // Both remaining changes start past a_pos, or the cursor did not advance
        // through a zero-width hole. Copy one ancestor line if any remain.
        if (a_pos < base_lines.len and a_pos < next) {
            try out.appendSlice(allocator, base_lines[a_pos]);
            a_pos += 1;
            continue;
        }
        break;
    }
    if (a_pos < base_lines.len) try appendLines(&out, allocator, base_lines[a_pos..]);

    return .{
        .bytes = try out.toOwnedSlice(allocator),
        .clean = clean,
    };
}

fn lineDiff(allocator: Allocator, algorithm: Algorithm, src_text: []const u8, dst_text: []const u8) Allocator.Error![]myers.Diff {
    return switch (algorithm) {
        .myers, .minimal => myers.lineDiff(allocator, src_text, dst_text, null),
        .histogram => histogram.lineDiff(allocator, src_text, dst_text),
        .patience => patience.lineDiff(allocator, src_text, dst_text),
    };
}

fn changesFrom(allocator: Allocator, diffs: []const myers.Diff) Allocator.Error![]Change {
    var out: std.ArrayList(Change) = .empty;
    errdefer out.deinit(allocator);
    var a_cursor: usize = 0;
    var side_cursor: usize = 0;
    var i: usize = 0;
    while (i < diffs.len) {
        if (diffs[i].operation == .equal) {
            const n = countLines(diffs[i].text);
            a_cursor += n;
            side_cursor += n;
            i += 1;
            continue;
        }
        const a_lo = a_cursor;
        const side_lo = side_cursor;
        while (i < diffs.len and diffs[i].operation != .equal) : (i += 1) {
            const n = countLines(diffs[i].text);
            if (diffs[i].operation == .delete) a_cursor += n else side_cursor += n;
        }
        try out.append(allocator, .{
            .a_lo = a_lo,
            .a_hi = a_cursor,
            .side_lo = side_lo,
            .side_hi = side_cursor,
        });
    }
    return try out.toOwnedSlice(allocator);
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var n: usize = 0;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    if (text[text.len - 1] != '\n') n += 1;
    return n;
}

/// Returns true when markers were written.
fn emitRegion(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    style: ConflictStyle,
    favor: Favor,
    labels: Labels,
    base_lines: []const []const u8,
    ours_lines: []const []const u8,
    theirs_lines: []const []const u8,
    ours_changes: []const Change,
    theirs_changes: []const Change,
    oi: *usize,
    ti: *usize,
    a_pos: *usize,
) Allocator.Error!bool {
    const lo = a_pos.*;
    var hi = lo;
    var o_end = oi.*;
    var t_end = ti.*;
    var grew = true;
    while (grew) {
        grew = false;
        while (o_end < ours_changes.len and ours_changes[o_end].a_lo <= hi) {
            if (ours_changes[o_end].a_hi > hi) hi = ours_changes[o_end].a_hi;
            o_end += 1;
            grew = true;
        }
        while (t_end < theirs_changes.len and theirs_changes[t_end].a_lo <= hi) {
            if (theirs_changes[t_end].a_hi > hi) hi = theirs_changes[t_end].a_hi;
            t_end += 1;
            grew = true;
        }
    }

    var ours_piece: std.ArrayList(LineRef) = .empty;
    defer ours_piece.deinit(allocator);
    var theirs_piece: std.ArrayList(LineRef) = .empty;
    defer theirs_piece.deinit(allocator);
    var base_piece: std.ArrayList(LineRef) = .empty;
    defer base_piece.deinit(allocator);
    try reconstruct(&ours_piece, allocator, base_lines, ours_lines, ours_changes[oi.*..o_end], lo, hi);
    try reconstruct(&theirs_piece, allocator, base_lines, theirs_lines, theirs_changes[ti.*..t_end], lo, hi);
    var p = lo;
    while (p < hi) : (p += 1) try base_piece.append(allocator, .{ .text = base_lines[p] });

    oi.* = o_end;
    ti.* = t_end;
    a_pos.* = hi;

    if (sameLines(ours_piece.items, theirs_piece.items)) {
        try appendRefs(out, allocator, ours_piece.items);
        return false;
    }
    switch (favor) {
        .ours => {
            try appendRefs(out, allocator, ours_piece.items);
            return false;
        },
        .theirs => {
            try appendRefs(out, allocator, theirs_piece.items);
            return false;
        },
        .none => {},
    }

    var pre: usize = 0;
    var post: usize = 0;
    var bpre: usize = 0;
    var bpost: usize = 0;
    if (style == .zdiff3) {
        while (pre < ours_piece.items.len and pre < theirs_piece.items.len and
            std.mem.eql(u8, ours_piece.items[pre].text, theirs_piece.items[pre].text))
        {
            pre += 1;
        }
        while (post + pre < ours_piece.items.len and post + pre < theirs_piece.items.len and
            std.mem.eql(u8, ours_piece.items[ours_piece.items.len - 1 - post].text, theirs_piece.items[theirs_piece.items.len - 1 - post].text))
        {
            post += 1;
        }
        while (bpre < pre and bpre < base_piece.items.len and
            std.mem.eql(u8, base_piece.items[bpre].text, ours_piece.items[bpre].text))
        {
            bpre += 1;
        }
        while (bpost < post and bpost + bpre < base_piece.items.len and
            std.mem.eql(u8, base_piece.items[base_piece.items.len - 1 - bpost].text, ours_piece.items[ours_piece.items.len - 1 - bpost].text))
        {
            bpost += 1;
        }
        try appendRefs(out, allocator, ours_piece.items[0..pre]);
    }

    try out.appendSlice(allocator, "<<<<<<< ");
    try out.appendSlice(allocator, labels.ours);
    try out.append(allocator, '\n');
    try appendRefs(out, allocator, ours_piece.items[pre .. ours_piece.items.len - post]);
    if (style == .diff3 or style == .zdiff3) {
        try out.appendSlice(allocator, "||||||| ");
        try out.appendSlice(allocator, labels.base);
        try out.append(allocator, '\n');
        const b_lo = bpre;
        const b_hi = base_piece.items.len - bpost;
        try appendRefs(out, allocator, base_piece.items[b_lo..b_hi]);
    }
    try out.appendSlice(allocator, "=======\n");
    try appendRefs(out, allocator, theirs_piece.items[pre .. theirs_piece.items.len - post]);
    try out.appendSlice(allocator, ">>>>>>> ");
    try out.appendSlice(allocator, labels.theirs);
    try out.append(allocator, '\n');
    if (style == .zdiff3) try appendRefs(out, allocator, ours_piece.items[ours_piece.items.len - post ..]);
    return true;
}

fn reconstruct(
    out: *std.ArrayList(LineRef),
    allocator: Allocator,
    base_lines: []const []const u8,
    side_lines: []const []const u8,
    changes: []const Change,
    lo: usize,
    hi: usize,
) Allocator.Error!void {
    var pos = lo;
    var ci: usize = 0;
    while (ci < changes.len or pos < hi) {
        if (ci < changes.len and changes[ci].a_lo == pos) {
            var s = changes[ci].side_lo;
            while (s < changes[ci].side_hi) : (s += 1) {
                try out.append(allocator, .{ .text = side_lines[s] });
            }
            const advance = changes[ci].a_hi > pos;
            pos = changes[ci].a_hi;
            ci += 1;
            if (!advance and pos >= hi and ci >= changes.len) break;
            continue;
        }
        if (pos < hi and (ci >= changes.len or changes[ci].a_lo > pos)) {
            try out.append(allocator, .{ .text = base_lines[pos] });
            pos += 1;
            continue;
        }
        break;
    }
}

fn sameLines(a: []const LineRef, b: []const LineRef) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x.text, y.text)) return false;
    }
    return true;
}

fn appendLines(out: *std.ArrayList(u8), allocator: Allocator, lines: []const []const u8) Allocator.Error!void {
    for (lines) |line| try out.appendSlice(allocator, line);
}

fn appendRefs(out: *std.ArrayList(u8), allocator: Allocator, lines: []const LineRef) Allocator.Error!void {
    for (lines) |line| try out.appendSlice(allocator, line.text);
}

const sample_labels = Labels{ .ours = "HEAD", .theirs = "side", .base = "279b5d2" };

test "diff3 cleanly merges edits separated by one unchanged line" {
    const gpa = std.testing.allocator;
    var merged = try mergeText(
        gpa,
        .histogram,
        .merge,
        .none,
        sample_labels,
        "a\nb\nc\nd\n",
        "a\nX\nc\nd\n",
        "a\nb\nc\nY\n",
    );
    defer merged.deinit(gpa);
    try std.testing.expect(merged.clean);
    try std.testing.expectEqualStrings("a\nX\nc\nY\n", merged.bytes);
}

test "diff3 conflicts adjacent line edits and keeps both lines inside the markers" {
    const gpa = std.testing.allocator;
    var merged = try mergeText(
        gpa,
        .histogram,
        .merge,
        .none,
        sample_labels,
        "a\nb\nc\n",
        "a\nX\nc\n",
        "a\nb\nY\n",
    );
    defer merged.deinit(gpa);
    try std.testing.expect(!merged.clean);
    try std.testing.expectEqualStrings(
        "a\n<<<<<<< HEAD\nX\nc\n=======\nb\nY\n>>>>>>> side\n",
        merged.bytes,
    );
}

test "diff3 same-line conflict matches Git merge and diff3 marker bytes" {
    const gpa = std.testing.allocator;
    var merge_style = try mergeText(
        gpa,
        .histogram,
        .merge,
        .none,
        sample_labels,
        "a\nb\nc\n",
        "a\nX\nc\n",
        "a\nY\nc\n",
    );
    defer merge_style.deinit(gpa);
    try std.testing.expect(!merge_style.clean);
    try std.testing.expectEqualStrings(
        "a\n<<<<<<< HEAD\nX\n=======\nY\n>>>>>>> side\nc\n",
        merge_style.bytes,
    );

    var diff3_style = try mergeText(
        gpa,
        .histogram,
        .diff3,
        .none,
        sample_labels,
        "a\nb\nc\n",
        "a\nX\nc\n",
        "a\nY\nc\n",
    );
    defer diff3_style.deinit(gpa);
    try std.testing.expectEqualStrings(
        "a\n<<<<<<< HEAD\nX\n||||||| 279b5d2\nb\n=======\nY\n>>>>>>> side\nc\n",
        diff3_style.bytes,
    );
}

test "zdiff3 peels a shared edge and leaves a base line that does not match" {
    const gpa = std.testing.allocator;
    var merged = try mergeText(
        gpa,
        .histogram,
        .zdiff3,
        .none,
        .{ .ours = "HEAD", .theirs = "side", .base = "8a5e103" },
        "q\n",
        "P\nM\nS\n",
        "P\nN\nS\n",
    );
    defer merged.deinit(gpa);
    try std.testing.expect(!merged.clean);
    try std.testing.expectEqualStrings(
        "P\n<<<<<<< HEAD\nM\n||||||| 8a5e103\nq\n=======\nN\n>>>>>>> side\nS\n",
        merged.bytes,
    );
}

test "diff3 emits one copy when both sides make the same edit" {
    const gpa = std.testing.allocator;
    var merged = try mergeText(
        gpa,
        .histogram,
        .merge,
        .none,
        sample_labels,
        "a\nb\nc\n",
        "a\nZ\nc\n",
        "a\nZ\nc\n",
    );
    defer merged.deinit(gpa);
    try std.testing.expect(merged.clean);
    try std.testing.expectEqualStrings("a\nZ\nc\n", merged.bytes);
}

test "favor ours replaces only the conflict region" {
    const gpa = std.testing.allocator;
    var adjacent = try mergeText(
        gpa,
        .histogram,
        .merge,
        .ours,
        sample_labels,
        "a\nb\nc\n",
        "a\nX\nc\n",
        "a\nb\nY\n",
    );
    defer adjacent.deinit(gpa);
    try std.testing.expect(adjacent.clean);
    try std.testing.expectEqualStrings("a\nX\nc\n", adjacent.bytes);

    var far = try mergeText(
        gpa,
        .histogram,
        .merge,
        .ours,
        sample_labels,
        "a\nb\nc\nd\ne\nf\ng\nh\ni\n",
        "a\nX\nc\nd\ne\nf\ng\nh\ni\n",
        "a\nY\nc\nd\ne\nf\ng\nh\nZ\n",
    );
    defer far.deinit(gpa);
    try std.testing.expect(far.clean);
    try std.testing.expectEqualStrings("a\nX\nc\nd\ne\nf\ng\nh\nZ\n", far.bytes);
}
