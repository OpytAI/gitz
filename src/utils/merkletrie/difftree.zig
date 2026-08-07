//! Diff two merkletries (go-git `utils/merkletrie/difftree.go`).

const std = @import("std");
const noder = @import("noder");
const change_mod = @import("change.zig");
const doubleiter_mod = @import("doubleiter.zig");

const Allocator = std.mem.Allocator;
const Noder = noder.Noder;
const Equal = noder.Equal;
const Changes = change_mod.Changes;
const DoubleIter = doubleiter_mod.DoubleIter;

pub const Error = error{
    Canceled,
    BadDoubleIterStatus,
    BothDirsEmptyDifferentHash,
};

/// Optional cancellation flag (go-git `context.Context`).
pub const Context = struct {
    /// When non-null and `true`, DiffTreeContext returns `error.Canceled`.
    cancelled: ?*const bool = null,

    pub fn isCancelled(self: Context) bool {
        return if (self.cancelled) |c| c.* else false;
    }
};

/// DiffTree with no cancellation (go-git `DiffTree`).
pub fn diffTree(
    allocator: Allocator,
    from_tree: Noder,
    to_tree: Noder,
    hash_equal: Equal,
) anyerror!Changes {
    return diffTreeContext(allocator, .{}, from_tree, to_tree, hash_equal);
}

/// DiffTree with optional cancel (go-git `DiffTreeContext`).
pub fn diffTreeContext(
    allocator: Allocator,
    ctx: Context,
    from_tree: Noder,
    to_tree: Noder,
    hash_equal: Equal,
) anyerror!Changes {
    var ret = Changes.init(allocator);
    errdefer ret.deinit();

    var ii = try DoubleIter.init(allocator, from_tree, to_tree, hash_equal);
    defer ii.deinit();

    while (true) {
        if (ctx.isCancelled()) return Error.Canceled;

        const from = ii.from.current;
        const to = ii.to.current;

        switch (ii.remaining()) {
            .no_more_noders => return ret,
            .only_from_remains => {
                if (!from.?.skip()) {
                    try ret.addRecursiveDelete(from.?);
                }
                try ii.nextFrom();
            },
            .only_to_remains => {
                if (!to.?.skip()) {
                    try ret.addRecursiveInsert(to.?);
                }
                try ii.nextTo();
            },
            .both_have_nodes => {
                if (from.?.skip()) {
                    if (std.mem.eql(u8, from.?.name(), to.?.name())) {
                        try ii.nextBoth();
                    } else {
                        try ii.nextFrom();
                    }
                } else if (to.?.skip()) {
                    if (std.mem.eql(u8, from.?.name(), to.?.name())) {
                        try ii.nextBoth();
                    } else {
                        try ii.nextTo();
                    }
                } else {
                    try diffNodes(&ret, &ii);
                }
            },
        }
    }
}

fn diffNodes(changes: *Changes, ii: *DoubleIter) anyerror!void {
    const from = ii.from.current.?;
    const to = ii.to.current.?;

    switch (from.compare(to)) {
        -1 => {
            try changes.addRecursiveDelete(from);
            try ii.nextFrom();
        },
        1 => {
            try changes.addRecursiveInsert(to);
            try ii.nextTo();
        },
        else => try diffNodesSameName(changes, ii),
    }
}

fn diffNodesSameName(changes: *Changes, ii: *DoubleIter) anyerror!void {
    const from = ii.from.current.?;
    const to = ii.to.current.?;
    const status = try ii.compare();

    if (status.same_hash) {
        try ii.nextBoth();
    } else if (status.both_are_files) {
        var a = try from.clone(changes.allocator);
        errdefer a.deinit(changes.allocator);
        var b = try to.clone(changes.allocator);
        errdefer b.deinit(changes.allocator);
        try changes.add(change_mod.newModify(a, b));
        // Ownership transferred into Changes; clear so errdefer no-ops.
        a = .{};
        b = .{};
        try ii.nextBoth();
    } else if (status.file_and_dir) {
        try changes.addRecursiveDelete(from);
        try changes.addRecursiveInsert(to);
        try ii.nextBoth();
    } else if (status.both_are_dirs) {
        try diffDirs(changes, ii);
    } else {
        return Error.BadDoubleIterStatus;
    }
}

fn diffDirs(changes: *Changes, ii: *DoubleIter) anyerror!void {
    const from = ii.from.current.?;
    const to = ii.to.current.?;
    const status = try ii.compare();

    if (status.from_is_empty_dir) {
        try changes.addRecursiveInsert(to);
        try ii.nextBoth();
    } else if (status.to_is_empty_dir) {
        try changes.addRecursiveDelete(from);
        try ii.nextBoth();
    } else if (!status.from_is_empty_dir and !status.to_is_empty_dir) {
        try ii.stepBoth();
    } else {
        return Error.BothDirsEmptyDifferentHash;
    }
}

// ---------------------------------------------------------------------------
// Tests (go-git difftree_test.go — key cases)
// ---------------------------------------------------------------------------

const fsnoder = @import("fsnoder");

const SimpleChange = struct {
    action: change_mod.Action,
    path: []const u8,
};

fn parseExpected(allocator: Allocator, s: []const u8) ![]SimpleChange {
    var list: std.ArrayList(SimpleChange) = .empty;
    errdefer list.deinit(allocator);
    const trimmed = std.mem.trim(u8, s, " \t\n\r");
    if (trimmed.len == 0) return try list.toOwnedSlice(allocator);

    var it = std.mem.tokenizeAny(u8, trimmed, " \t\n\r");
    while (it.next()) |chunk| {
        if (chunk.len == 0) continue;
        const act: change_mod.Action = switch (chunk[0]) {
            '+' => .insert,
            '-' => .delete,
            '*' => .modify,
            else => return error.BadExpected,
        };
        try list.append(allocator, .{ .action = act, .path = chunk[1..] });
    }
    return try list.toOwnedSlice(allocator);
}

fn changesToSimple(allocator: Allocator, ch: *const Changes) ![]SimpleChange {
    var list: std.ArrayList(SimpleChange) = .empty;
    errdefer {
        for (list.items) |c| allocator.free(c.path);
        list.deinit(allocator);
    }
    for (ch.items.items) |c| {
        const act = try c.action();
        const path_owned = blk: {
            switch (act) {
                .insert => break :blk try c.to.?.string(allocator),
                .delete => break :blk try c.from.?.string(allocator),
                .modify => break :blk try c.from.?.string(allocator),
            }
        };
        try list.append(allocator, .{ .action = act, .path = path_owned });
    }
    return try list.toOwnedSlice(allocator);
}

fn freeSimple(allocator: Allocator, s: []SimpleChange) void {
    for (s) |c| {
        // parseExpected paths are views; changesToSimple paths are owned.
        // Caller distinguishes.
        _ = c;
    }
    allocator.free(s);
}

fn freeSimpleOwned(allocator: Allocator, s: []SimpleChange) void {
    for (s) |c| allocator.free(@constCast(c.path));
    allocator.free(s);
}

fn lessSimple(_: void, a: SimpleChange, b: SimpleChange) bool {
    // Sort by string form "<Action path>"
    if (a.action != b.action) return @intFromEnum(a.action) < @intFromEnum(b.action);
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn expectDiff(allocator: Allocator, from_s: []const u8, to_s: []const u8, expected_s: []const u8) !void {
    var from = try fsnoder.New(allocator, from_s);
    defer from.deinit(allocator);
    var to = try fsnoder.New(allocator, to_s);
    defer to.deinit(allocator);

    var results = try diffTree(allocator, from.noder(), to.noder(), fsnoder.hashEqual);
    defer results.deinit();

    const obtained = try changesToSimple(allocator, &results);
    defer freeSimpleOwned(allocator, obtained);

    const expected = try parseExpected(allocator, expected_s);
    defer allocator.free(expected);

    std.mem.sort(SimpleChange, obtained, {}, lessSimple);
    // expected paths are not owned; sort a mutable copy
    const exp_mut = try allocator.dupe(SimpleChange, expected);
    defer allocator.free(exp_mut);
    std.mem.sort(SimpleChange, exp_mut, {}, lessSimple);

    try std.testing.expectEqual(exp_mut.len, obtained.len);
    for (exp_mut, obtained) |e, o| {
        try std.testing.expectEqual(e.action, o.action);
        try std.testing.expectEqualStrings(e.path, o.path);
    }
}

fn reverseExpected(allocator: Allocator, s: []const u8) ![]u8 {
    const parsed = try parseExpected(allocator, s);
    defer allocator.free(parsed);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    for (parsed, 0..) |c, i| {
        if (i > 0) try list.append(allocator, ' ');
        const ch: u8 = switch (c.action) {
            .insert => '-',
            .delete => '+',
            .modify => '*',
        };
        try list.append(allocator, ch);
        try list.appendSlice(allocator, c.path);
    }
    return try list.toOwnedSlice(allocator);
}

fn expectDiffBothWays(allocator: Allocator, from_s: []const u8, to_s: []const u8, expected_s: []const u8) !void {
    try expectDiff(allocator, from_s, to_s, expected_s);
    const rev = try reverseExpected(allocator, expected_s);
    defer allocator.free(rev);
    try expectDiff(allocator, to_s, from_s, rev);
}

// go-git DiffTreeSuite.TestEmptyVsEmpty
test "DiffTree empty vs empty" {
    const a = std.testing.allocator;
    try expectDiffBothWays(a, "()", "()", "");
    try expectDiffBothWays(a, "A()", "A()", "");
    try expectDiffBothWays(a, "A()", "()", "");
    try expectDiffBothWays(a, "A()", "B()", "");
}

// go-git DiffTreeSuite.TestBasicCases (full table)
test "DiffTree basic cases" {
    const a = std.testing.allocator;
    try expectDiffBothWays(a, "()", "()", "");
    try expectDiffBothWays(a, "()", "(a<>)", "+a");
    try expectDiffBothWays(a, "()", "(a<1>)", "+a");
    try expectDiffBothWays(a, "()", "(a())", "");
    try expectDiffBothWays(a, "()", "(a(b()))", "");
    try expectDiffBothWays(a, "()", "(a(b<>))", "+a/b");
    try expectDiffBothWays(a, "()", "(a(b<1>))", "+a/b");
    try expectDiffBothWays(a, "(a<>)", "(a<>)", "");
    try expectDiffBothWays(a, "(a<>)", "(a<1>)", "*a");
    try expectDiffBothWays(a, "(a<>)", "(a())", "-a");
    try expectDiffBothWays(a, "(a<>)", "(a(b()))", "-a");
    try expectDiffBothWays(a, "(a<>)", "(a(b<>))", "-a +a/b");
    try expectDiffBothWays(a, "(a<>)", "(a(b<1>))", "-a +a/b");
    try expectDiffBothWays(a, "(a<>)", "(c())", "-a");
    try expectDiffBothWays(a, "(a<>)", "(c(b()))", "-a");
    try expectDiffBothWays(a, "(a<>)", "(c(b<>))", "-a +c/b");
    try expectDiffBothWays(a, "(a<>)", "(c(b<1>))", "-a +c/b");
    try expectDiffBothWays(a, "(a<>)", "(c(a()))", "-a");
    try expectDiffBothWays(a, "(a<>)", "(c(a<>))", "-a +c/a");
    try expectDiffBothWays(a, "(a<>)", "(c(a<1>))", "-a +c/a");
    try expectDiffBothWays(a, "(a<1>)", "(a<1>)", "");
    try expectDiffBothWays(a, "(a<1>)", "(a<2>)", "*a");
    try expectDiffBothWays(a, "(a<1>)", "(b<1>)", "-a +b");
    try expectDiffBothWays(a, "(a<1>)", "(b<2>)", "-a +b");
    try expectDiffBothWays(a, "(a<1>)", "(a())", "-a");
    try expectDiffBothWays(a, "(a<1>)", "(a(b()))", "-a");
    try expectDiffBothWays(a, "(a<1>)", "(a(b<>))", "-a +a/b");
    try expectDiffBothWays(a, "(a<1>)", "(a(b<1>))", "-a +a/b");
    try expectDiffBothWays(a, "(a<1>)", "(a(b<2>))", "-a +a/b");
    try expectDiffBothWays(a, "(a<1>)", "(c())", "-a");
    try expectDiffBothWays(a, "(a<1>)", "(c(b()))", "-a");
    try expectDiffBothWays(a, "(a<1>)", "(c(b<>))", "-a +c/b");
    try expectDiffBothWays(a, "(a<1>)", "(c(b<1>))", "-a +c/b");
    try expectDiffBothWays(a, "(a<1>)", "(c(b<2>))", "-a +c/b");
    try expectDiffBothWays(a, "(a<1>)", "(c(a()))", "-a");
    try expectDiffBothWays(a, "(a<1>)", "(c(a<>))", "-a +c/a");
    try expectDiffBothWays(a, "(a<1>)", "(c(a<1>))", "-a +c/a");
    try expectDiffBothWays(a, "(a<1>)", "(c(a<2>))", "-a +c/a");
    try expectDiffBothWays(a, "(a())", "(a())", "");
    try expectDiffBothWays(a, "(a())", "(b())", "");
    try expectDiffBothWays(a, "(a())", "(a(b()))", "");
    try expectDiffBothWays(a, "(a())", "(b(a()))", "");
    try expectDiffBothWays(a, "(a())", "(a(b<>))", "+a/b");
    try expectDiffBothWays(a, "(a())", "(a(b<1>))", "+a/b");
    try expectDiffBothWays(a, "(a())", "(b(a<>))", "+b/a");
    try expectDiffBothWays(a, "(a())", "(b(a<1>))", "+b/a");
}

// go-git DiffTreeSuite.TestHorizontals
test "DiffTree horizontals" {
    const a = std.testing.allocator;
    try expectDiffBothWays(a, "()", "(a<> b<>)", "+a +b");
    try expectDiffBothWays(a, "()", "(a<> b<1>)", "+a +b");
    try expectDiffBothWays(a, "()", "(a<> b())", "+a");
    try expectDiffBothWays(a, "()", "(a() b<>)", "+b");
    try expectDiffBothWays(a, "()", "(a<1> b<>)", "+a +b");
    try expectDiffBothWays(a, "()", "(a<1> b<1>)", "+a +b");
    try expectDiffBothWays(a, "()", "(a<1> b<2>)", "+a +b");
    try expectDiffBothWays(a, "()", "(a<1> b())", "+a");
    try expectDiffBothWays(a, "()", "(a() b<1>)", "+b");
    try expectDiffBothWays(a, "()", "(a() b())", "");
    try expectDiffBothWays(a, "()", "(a<> b<> c<> d<>)", "+a +b +c +d");
    try expectDiffBothWays(a, "()", "(a<> b<1> c() d<> e<2> f())", "+a +b +d +e");
}

// go-git DiffTreeSuite.TestVerticals
test "DiffTree verticals" {
    const a = std.testing.allocator;
    try expectDiffBothWays(a, "()", "(z<>)", "+z");
    try expectDiffBothWays(a, "()", "(a(z<>))", "+a/z");
    try expectDiffBothWays(a, "()", "(a(b(z<>)))", "+a/b/z");
    try expectDiffBothWays(a, "()", "(a(b(c(z<>))))", "+a/b/c/z");
    try expectDiffBothWays(a, "()", "(a(b(c(d(z<>)))))", "+a/b/c/d/z");
    try expectDiffBothWays(a, "()", "(a(b(c(d(z<1>)))))", "+a/b/c/d/z");
}

// go-git DiffTreeSuite.TestSingleInserts (+ TestDebug)
test "DiffTree single inserts" {
    const a = std.testing.allocator;
    try expectDiffBothWays(a, "()", "(z<>)", "+z");
    try expectDiffBothWays(a, "(a())", "(a(z<>))", "+a/z");
    try expectDiffBothWays(a, "(a())", "(a(b(z<>)))", "+a/b/z");
    try expectDiffBothWays(a, "(a(b(c())))", "(a(b(c(z<>))))", "+a/b/c/z");
    try expectDiffBothWays(a, "(a<> b<> c<>)", "(a<> b<> c<> z<>)", "+z");
    try expectDiffBothWays(a, "(a(b<> c<> d<>))", "(a(b<> c<> d<> z<>))", "+a/z");
    try expectDiffBothWays(a, "(a(b(c<> d<> e<>)))", "(a(b(c<> d<> e<> z<>)))", "+a/b/z");
    try expectDiffBothWays(a, "(a(b<>) f<>)", "(a(b<>) f<> z<>)", "+z");
    try expectDiffBothWays(a, "(a(b<>) f<>)", "(a(b<> z<>) f<>)", "+a/z");
}

// go-git DiffTreeSuite.TestSameNames
test "DiffTree same names" {
    const a = std.testing.allocator;
    try expectDiffBothWays(a, "(a(a(a<>)))", "(a(a(a<1>)))", "*a/a/a");
    try expectDiffBothWays(a, "(a(b(a<>)))", "(a(b(a<>)) b(a<>))", "+b/a");
    try expectDiffBothWays(a, "(a(b(a<>)))", "(a(b()) b(a<>))", "-a/b/a +b/a");
}

// go-git DiffTreeSuite.TestIssue275
test "DiffTree issue 275" {
    const a = std.testing.allocator;
    try expectDiffBothWays(
        a,
        "(a(b(c.go<1>) b.go<2>))",
        "(a(b(c.go<1> d.go<3>) b.go<2>))",
        "+a/b/d.go",
    );
}

// go-git DiffTreeSuite.TestCrazy
test "DiffTree crazy tree" {
    const a = std.testing.allocator;
    const crazy = "(f(e(l<1>) a(n(o(p())) k<1>)) d<1> h(j(i<1> c<2> m<>) b() g<>))";
    try expectDiffBothWays(a, crazy, crazy, "");
    try expectDiffBothWays(a, crazy, "()", "-d -f/e/l -f/a/k -h/j/i -h/j/c -h/j/m -h/g");
    try expectDiffBothWays(a, crazy, "(d<1>)", "-f/e/l -f/a/k -h/j/i -h/j/c -h/j/m -h/g");
    try expectDiffBothWays(a, crazy, "(d<1> h(b() g<>))", "-f/e/l -f/a/k -h/j/i -h/j/c -h/j/m");
    try expectDiffBothWays(a, crazy, "(d<1> f(e(l()) a()) h(b() g<>))", "-f/e/l -f/a/k -h/j/i -h/j/c -h/j/m");
    try expectDiffBothWays(a, crazy, "(d<1> f(e(l<1>) a()) h(b() g<>))", "-f/a/k -h/j/i -h/j/c -h/j/m");
    try expectDiffBothWays(
        a,
        crazy,
        "(f(e(l<1>) a(n(o(p(r<1>))) k<1>)) d<1> h(j(i<1> c<2> b() m<>) g<1>))",
        "+f/a/n/o/p/r *h/g",
    );
}

// go-git DiffTreeSuite.TestCancel
test "DiffTree cancel" {
    const a = std.testing.allocator;
    var from = try fsnoder.New(a, "()");
    defer from.deinit(a);
    var to = try fsnoder.New(a, "(a<> b<1> c() d<> e<2> f())");
    defer to.deinit(a);
    const cancelled = true;
    try std.testing.expectError(
        Error.Canceled,
        diffTreeContext(a, .{ .cancelled = &cancelled }, from.noder(), to.noder(), fsnoder.hashEqual),
    );
}

// go-git DiffTreeSuite.TestIssue1057 — precomposed vs combining accents.
// go-git does not NFC/NFD-normalize path names; byte-different names are
// distinct tree nodes (same as Path.Compare).
test "DiffTree issue 1057 unicode path names no normalization" {
    const a = std.testing.allocator;
    // p1: ...e + combining acute (U+0301); p2: ... precomposed é (U+00E9)
    const p1 = "TestAppWithUnicode\u{0301}Path";
    const p2 = "TestAppWithUnicod\u{00e9}Path";
    try std.testing.expect(!std.mem.eql(u8, p1, p2));

    const from1 = try std.fmt.allocPrint(a, "({s}(x.go<1>))", .{p1});
    defer a.free(from1);
    const to_both = try std.fmt.allocPrint(a, "({s}(x.go<1>) {s}(x.go<1>))", .{ p1, p2 });
    defer a.free(to_both);
    const exp_p2 = try std.fmt.allocPrint(a, "+{s}/x.go", .{p2});
    defer a.free(exp_p2);
    try expectDiffBothWays(a, from1, to_both, exp_p2);

    const from2 = try std.fmt.allocPrint(a, "({s}(x.go<1>))", .{p2});
    defer a.free(from2);
    const exp_p1 = try std.fmt.allocPrint(a, "+{s}/x.go", .{p1});
    defer a.free(exp_p1);
    try expectDiffBothWays(a, from2, to_both, exp_p1);
}

// Modify + delete cases from difftree_test.go basic/same-names/crazy.
test "DiffTree modify and delete cases" {
    const a = std.testing.allocator;
    // Modify content hash
    try expectDiffBothWays(a, "(a<>)", "(a<1>)", "*a");
    try expectDiffBothWays(a, "(a<1>)", "(a<2>)", "*a");
    // Delete file / replace with empty dir
    try expectDiffBothWays(a, "(a<>)", "(a())", "-a");
    try expectDiffBothWays(a, "(a<1>)", "(a())", "-a");
    // Delete + insert (file → dir with child)
    try expectDiffBothWays(a, "(a<>)", "(a(b<>))", "-a +a/b");
    try expectDiffBothWays(a, "(a<1>)", "(b<1>)", "-a +b");
    // Nested modify
    try expectDiffBothWays(a, "(a(a(a<>)))", "(a(a(a<1>)))", "*a/a/a");
    // Crazy tree: modify + insert + delete mix
    const crazy = "(f(e(l<1>) a(n(o(p())) k<1>)) d<1> h(j(i<1> c<2> m<>) b() g<>))";
    try expectDiffBothWays(
        a,
        crazy,
        "(d<2> f(e(l<2>) a(s(t<1>))) h(b() g<> r<> j(i<> c<3> m<>)))",
        "+f/a/s/t +h/r -f/a/k *d *f/e/l *h/j/c *h/j/i",
    );
    try expectDiffBothWays(
        a,
        crazy,
        "(f(e(l<2>) a(n(o(p<1>)) k<>)) h(j(i<1> c<2> m<>) b() g<>))",
        "*f/e/l +f/a/n/o/p *f/a/k -d",
    );
}
