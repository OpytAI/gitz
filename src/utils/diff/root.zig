//! Package diff implements line oriented diffs, similar to the ancient
//! Unix diff command.
//!
//! Port of go-git v5.19.2 `utils/diff`. go-git wraps sergi/go-diff
//! (DiffLinesToRunes + DiffMainRunes + DiffCharsToLines). This package
//! implements the same line-oriented Myers behaviour in pure Zig.

const std = @import("std");
const myers = @import("myers.zig");

const Allocator = std.mem.Allocator;

pub const Operation = myers.Operation;
pub const Diff = myers.Diff;
pub const freeDiffs = myers.freeDiffs;

/// Default timeout for `do` — go-git uses `time.Hour` (large under load).
/// Nanoseconds: 3600 seconds.
pub const default_timeout_ns: u64 = 3600 * std.time.ns_per_s;

/// Do computes the (line oriented) modifications needed to turn `src_text`
/// into `dst_text`. Underlying algorithm is Myers O(N*d).
///
/// Caller owns the returned slice; free with `freeDiffs`.
/// go-git: `func Do(src, dst string) []diffmatchpatch.Diff`
pub fn do(allocator: Allocator, src_text: []const u8, dst_text: []const u8) Allocator.Error![]Diff {
    return doWithTimeout(allocator, src_text, dst_text, default_timeout_ns);
}

/// DoWithTimeout is like `do` but stops after `timeout_ns` wall time.
/// If the deadline is exceeded, unfinished tails become bulk delete+insert.
///
/// Pass `0` for unlimited time (no deadline), matching dmp `DiffTimeout <= 0`.
/// go-git: `func DoWithTimeout(src, dst string, timeout time.Duration) []Diff`
pub fn doWithTimeout(
    allocator: Allocator,
    src_text: []const u8,
    dst_text: []const u8,
    timeout_ns: u64,
) Allocator.Error![]Diff {
    const budget: ?u64 = if (timeout_ns == 0) null else timeout_ns;
    return myers.lineDiff(allocator, src_text, dst_text, budget);
}

/// Dst rebuilds the destination text from diffs (equalities + inserts).
/// Caller frees the returned slice with `allocator`.
/// go-git: `func Dst(diffs []Diff) string`
pub fn dst(allocator: Allocator, diffs: []const Diff) Allocator.Error![]u8 {
    return joinFiltered(allocator, diffs, .delete);
}

/// Src rebuilds the source text from diffs (equalities + deletes).
/// Caller frees the returned slice with `allocator`.
/// go-git: `func Src(diffs []Diff) string`
pub fn src(allocator: Allocator, diffs: []const Diff) Allocator.Error![]u8 {
    return joinFiltered(allocator, diffs, .insert);
}

/// Append hunks that are not `skip` into one owned string.
fn joinFiltered(allocator: Allocator, diffs: []const Diff, skip: Operation) Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (diffs) |d| {
        if (d.operation == skip) continue;
        try buf.appendSlice(allocator, d.text);
    }
    return try buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests — port of go-git utils/diff/diff_ext_test.go
// ---------------------------------------------------------------------------

test {
    _ = @import("myers.zig");
}

test "diff.Do Src/Dst round-trip (suiteCommon.TestAll)" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { src: []const u8, dst: []const u8 }{
        // equal inputs
        .{ .src = "", .dst = "" },
        .{ .src = "a", .dst = "a" },
        .{ .src = "a\n", .dst = "a\n" },
        .{ .src = "a\nb", .dst = "a\nb" },
        .{ .src = "a\nb\n", .dst = "a\nb\n" },
        .{ .src = "a\nb\nc", .dst = "a\nb\nc" },
        .{ .src = "a\nb\nc\n", .dst = "a\nb\nc\n" },
        // missing '\n'
        .{ .src = "", .dst = "\n" },
        .{ .src = "\n", .dst = "" },
        .{ .src = "a", .dst = "a\n" },
        .{ .src = "a\n", .dst = "a" },
        .{ .src = "a\nb", .dst = "a\nb" },
        .{ .src = "a\nb\n", .dst = "a\nb\n" },
        .{ .src = "a\nb\nc", .dst = "a\nb\nc" },
        .{ .src = "a\nb\nc\n", .dst = "a\nb\nc\n" },
        // generic
        .{
            .src = "a\nbbbbb\n\tccc\ndd\n\tfffffffff\n",
            .dst = "bbbbb\n\tccc\n\tDD\n\tffff\n",
        },
    };

    for (cases, 0..) |t, i| {
        const diffs = try do(gpa, t.src, t.dst);
        defer freeDiffs(gpa, diffs);
        const got_src = try src(gpa, diffs);
        defer gpa.free(got_src);
        const got_dst = try dst(gpa, diffs);
        defer gpa.free(got_dst);
        try std.testing.expectEqualStrings(t.src, got_src);
        try std.testing.expectEqualStrings(t.dst, got_dst);
        _ = i;
    }
}

test "diff.Do exact hunks (suiteCommon.TestDo)" {
    const gpa = std.testing.allocator;

    const Hunk = struct { op: Operation, text: []const u8 };
    const Case = struct {
        src: []const u8,
        dst: []const u8,
        exp: []const Hunk,
    };

    const cases = [_]Case{
        .{
            .src = "",
            .dst = "",
            .exp = &[_]Hunk{},
        },
        .{
            .src = "a",
            .dst = "a",
            .exp = &[_]Hunk{
                .{ .op = .equal, .text = "a" },
            },
        },
        .{
            .src = "",
            .dst = "abc\ncba",
            .exp = &[_]Hunk{
                .{ .op = .insert, .text = "abc\ncba" },
            },
        },
        .{
            .src = "abc\ncba",
            .dst = "",
            .exp = &[_]Hunk{
                .{ .op = .delete, .text = "abc\ncba" },
            },
        },
        .{
            .src = "abc\nbcd\ncde",
            .dst = "000\nabc\n111\nBCD\n",
            .exp = &[_]Hunk{
                .{ .op = .insert, .text = "000\n" },
                .{ .op = .equal, .text = "abc\n" },
                .{ .op = .delete, .text = "bcd\ncde" },
                .{ .op = .insert, .text = "111\nBCD\n" },
            },
        },
        .{
            .src = "A\nB\nC\nD\nE\nF\nG\nH\nI\nJ\nK\nL\nM\nN\nÑ\nO\nP\nQ\nR\nS\nT\nU\nV\nW\nX\nY\nZ",
            .dst = "B\nC\nD\nE\nF\nG\nI\nJ\nK\nL\nM\nN\nO\nP\nQ\nR\nS\nT\nV\nW\nX\nY\nZ",
            .exp = &[_]Hunk{
                .{ .op = .delete, .text = "A\n" },
                .{ .op = .equal, .text = "B\nC\nD\nE\nF\nG\n" },
                .{ .op = .delete, .text = "H\n" },
                .{ .op = .equal, .text = "I\nJ\nK\nL\nM\nN\n" },
                .{ .op = .delete, .text = "Ñ\n" },
                .{ .op = .equal, .text = "O\nP\nQ\nR\nS\nT\n" },
                .{ .op = .delete, .text = "U\n" },
                .{ .op = .equal, .text = "V\nW\nX\nY\nZ" },
            },
        },
        .{
            .src = "B\nC\nD\nE\nF\nG\nI\nJ\nK\nL\nM\nN\nO\nP\nQ\nR\nS\nT\nV\nW\nX\nY\nZ",
            .dst = "B\nC\nD\nE\nF\nG\nI\nJ\nK\nL\nM\nN\nO\nP\nQ\nR\nS\nT\nV\nW\nX\nY\n",
            .exp = &[_]Hunk{
                .{ .op = .equal, .text = "B\nC\nD\nE\nF\nG\nI\nJ\nK\nL\nM\nN\nO\nP\nQ\nR\nS\nT\nV\nW\nX\nY\n" },
                .{ .op = .delete, .text = "Z" },
            },
        },
        .{
            .src = "B\nC\nD\nE\nF\nG\nI\nJ\nK\nL\nM\nN\nO\nP\nQ\nR\nS\nT\nV\nW\nX\nY\nZ",
            .dst = "B\nC\nD\nE\nF\nG\nI\nJ\nK\nL\nM\nN\nO\nP\nQ\nR\nS\nT\nV\nW\nX\nY",
            .exp = &[_]Hunk{
                .{ .op = .equal, .text = "B\nC\nD\nE\nF\nG\nI\nJ\nK\nL\nM\nN\nO\nP\nQ\nR\nS\nT\nV\nW\nX\n" },
                .{ .op = .delete, .text = "Y\nZ" },
                .{ .op = .insert, .text = "Y" },
            },
        },
    };

    for (cases, 0..) |t, ci| {
        const diffs = try do(gpa, t.src, t.dst);
        defer freeDiffs(gpa, diffs);
        try std.testing.expectEqual(t.exp.len, diffs.len);
        for (t.exp, diffs, 0..) |want, got, hi| {
            try std.testing.expectEqual(want.op, got.operation);
            try std.testing.expectEqualStrings(want.text, got.text);
            _ = hi;
        }
        _ = ci;
    }
}

test "diff.DoWithTimeout zero means unlimited" {
    const gpa = std.testing.allocator;
    const diffs = try doWithTimeout(gpa, "a\nb\n", "a\nc\n", 0);
    defer freeDiffs(gpa, diffs);
    try std.testing.expect(diffs.len >= 1);
    const got_src = try src(gpa, diffs);
    defer gpa.free(got_src);
    try std.testing.expectEqualStrings("a\nb\n", got_src);
}

test "diff.DoWithTimeout short deadline bulk remainder" {
    // Extremely short timeout may force bulk path on non-trivial input.
    // Behaviour is best-effort: Src/Dst must still round-trip.
    const gpa = std.testing.allocator;
    const a_text =
        \\line0
        \\line1
        \\line2
        \\line3
        \\line4
        \\line5
        \\line6
        \\line7
        \\line8
        \\line9
        \\lineA
        \\lineB
        \\lineC
        \\lineD
        \\lineE
        \\lineF
        \\
    ;
    const b_text =
        \\line0
        \\X1
        \\line2
        \\X3
        \\line4
        \\X5
        \\line6
        \\X7
        \\line8
        \\X9
        \\lineA
        \\XB
        \\lineC
        \\XD
        \\lineE
        \\XF
        \\
    ;
    const diffs = try doWithTimeout(gpa, a_text, b_text, 1); // 1 ns
    defer freeDiffs(gpa, diffs);
    const got_src = try src(gpa, diffs);
    defer gpa.free(got_src);
    const got_dst = try dst(gpa, diffs);
    defer gpa.free(got_dst);
    try std.testing.expectEqualStrings(a_text, got_src);
    try std.testing.expectEqualStrings(b_text, got_dst);
}
