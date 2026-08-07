//! Merkletrie depth-first iterator (go-git `utils/merkletrie/iter.go`).

const std = @import("std");
const noder = @import("noder");
const frame_mod = @import("frame");

const Allocator = std.mem.Allocator;
const Noder = noder.Noder;
const Path = noder.Path;
const Frame = frame_mod.Frame;

/// Depth-first pre-order iterator with optional directory skip (go-git `Iter`).
pub const Iter = struct {
    has_started: bool = false,
    frame_stack: std.ArrayList(*Frame) = .empty,
    /// Base path prefix for absolute iterators (owned noders slice when set).
    base: Path = .{},
    allocator: Allocator,

    /// Relative iterator from unnamed root (go-git `NewIter`).
    pub fn init(allocator: Allocator, root: ?Noder) anyerror!Iter {
        return initWithBase(allocator, root, .{});
    }

    /// Absolute iterator from path end (go-git `NewIterFromPath`).
    pub fn initFromPath(allocator: Allocator, p: Path) anyerror!Iter {
        if (p.nodes.len == 0) return initWithBase(allocator, null, .{});
        // Path implements Noder via last element; base is the full path.
        const base = try p.clone(allocator);
        errdefer {
            var b = base;
            b.deinit(allocator);
        }
        return initWithBase(allocator, p.last(), base);
    }

    fn initWithBase(allocator: Allocator, root: ?Noder, base: Path) anyerror!Iter {
        var ret: Iter = .{
            .base = base,
            .allocator = allocator,
        };
        if (root == null) return ret;

        const f = try allocator.create(Frame);
        errdefer allocator.destroy(f);
        f.* = try Frame.init(allocator, root.?);
        errdefer f.deinit();
        try ret.frame_stack.append(allocator, f);
        return ret;
    }

    pub fn deinit(self: *Iter) void {
        for (self.frame_stack.items) |f| {
            f.deinit();
            self.allocator.destroy(f);
        }
        self.frame_stack.deinit(self.allocator);
        self.base.deinit(self.allocator);
        self.* = undefined;
    }

    fn top(self: *const Iter) ?*Frame {
        if (self.frame_stack.items.len == 0) return null;
        return self.frame_stack.items[self.frame_stack.items.len - 1];
    }

    fn push(self: *Iter, f: *Frame) Allocator.Error!void {
        try self.frame_stack.append(self.allocator, f);
    }

    /// Next without descending (go-git `Next`). Owned path; free with Path.deinit.
    pub fn next(self: *Iter) anyerror!Path {
        return self.advance(false);
    }

    /// Step descending into dirs (go-git `Step`). Owned path; free with Path.deinit.
    pub fn step(self: *Iter) anyerror!Path {
        return self.advance(true);
    }

    fn advance(self: *Iter, want_descend: bool) anyerror!Path {
        const cur = try self.current();

        if (!self.has_started) {
            self.has_started = true;
            return cur;
        }
        // current() returned owned path; free after inspecting for descend.
        defer {
            var tmp = cur;
            tmp.deinit(self.allocator);
        }

        const num = try cur.numChildren();
        const must_descend = num != 0 and want_descend;
        if (must_descend) {
            const f = try self.allocator.create(Frame);
            errdefer self.allocator.destroy(f);
            f.* = try Frame.init(self.allocator, cur.last());
            errdefer f.deinit();
            try self.push(f);
        } else {
            self.drop();
        }

        return self.current();
    }

    fn current(self: *Iter) anyerror!Path {
        const top_f = self.top() orelse return error.EndOfStream;
        _ = top_f.first() orelse return error.EndOfStream;

        var list: std.ArrayList(Noder) = .empty;
        errdefer list.deinit(self.allocator);

        try list.appendSlice(self.allocator, self.base.nodes);
        for (self.frame_stack.items) |f| {
            const t = f.first() orelse return error.EmptyFrame;
            try list.append(self.allocator, t);
        }

        const nodes = try list.toOwnedSlice(self.allocator);
        return .{ .nodes = nodes, .owned = true };
    }

    fn drop(self: *Iter) void {
        const f = self.top() orelse return;
        f.drop();
        if (f.len() == 0) {
            const top_i = self.frame_stack.items.len - 1;
            const removed = self.frame_stack.orderedRemove(top_i);
            removed.deinit();
            self.allocator.destroy(removed);
            self.drop();
        }
    }
};

// ---------------------------------------------------------------------------
// Tests (go-git iter_test.go — representative cases)
// ---------------------------------------------------------------------------

const fsnoder = @import("fsnoder");

const IterTest = struct {
    operations: []const u8,
    expected: []const u8,
};

fn runIterTest(allocator: Allocator, tree_s: []const u8, t: IterTest) !void {
    var root = try fsnoder.New(allocator, tree_s);
    defer root.deinit(allocator);

    var it = try Iter.init(allocator, root.noder());
    defer it.deinit();

    var expected_chunks: std.ArrayList([]const u8) = .empty;
    defer expected_chunks.deinit(allocator);
    if (t.expected.len > 0) {
        var iter = std.mem.splitScalar(u8, t.expected, ' ');
        while (iter.next()) |chunk| {
            try expected_chunks.append(allocator, chunk);
        }
    }

    var ei: usize = 0;
    for (t.operations, 0..) |op, i| {
        _ = i;
        const obtained = switch (op) {
            'n' => it.next(),
            's' => it.step(),
            else => return error.UnknownOperation,
        };
        if (ei >= expected_chunks.items.len) {
            try std.testing.expectError(error.EndOfStream, obtained);
            continue;
        }
        var path = try obtained;
        defer path.deinit(allocator);
        const s = try path.string(allocator);
        defer allocator.free(s);
        try std.testing.expectEqualStrings(expected_chunks.items[ei], s);
        ei += 1;
    }
}

// go-git IterSuite.TestEmptyNamedDir
test "Iter empty named" {
    const a = std.testing.allocator;
    try runIterTest(a, "A()", .{ .operations = "n", .expected = "" });
    try runIterTest(a, "A()", .{ .operations = "s", .expected = "" });
    try runIterTest(a, "A()", .{ .operations = "nnnssnsnns", .expected = "" });
    try runIterTest(a, "A()", .{ .operations = "sssnnsnssn", .expected = "" });
}

// go-git IterSuite.TestEmptyUnnamedDir
test "Iter empty unnamed" {
    const a = std.testing.allocator;
    try runIterTest(a, "()", .{ .operations = "n", .expected = "" });
    try runIterTest(a, "()", .{ .operations = "s", .expected = "" });
    try runIterTest(a, "()", .{ .operations = "nnnssnsnns", .expected = "" });
    try runIterTest(a, "()", .{ .operations = "sssnnsnssn", .expected = "" });
}

// go-git IterSuite.TestOneFile
test "Iter one file" {
    const a = std.testing.allocator;
    try runIterTest(a, "(a<>)", .{ .operations = "n", .expected = "a" });
    try runIterTest(a, "(a<>)", .{ .operations = "nn", .expected = "a" });
    try runIterTest(a, "(a<>)", .{ .operations = "nnnssnsnns", .expected = "a" });
    try runIterTest(a, "(a<>)", .{ .operations = "s", .expected = "a" });
    try runIterTest(a, "(a<>)", .{ .operations = "sssnnsnssn", .expected = "a" });
}

// go-git IterSuite.TestTwoFiles
test "Iter two files" {
    const a = std.testing.allocator;
    try runIterTest(a, "(a<> b<>)", .{ .operations = "nnn", .expected = "a b" });
    try runIterTest(a, "(a<> b<>)", .{ .operations = "nns", .expected = "a b" });
    try runIterTest(a, "(a<> b<>)", .{ .operations = "nsn", .expected = "a b" });
    try runIterTest(a, "(a<> b<>)", .{ .operations = "nss", .expected = "a b" });
    try runIterTest(a, "(a<> b<>)", .{ .operations = "snn", .expected = "a b" });
    try runIterTest(a, "(a<> b<>)", .{ .operations = "sns", .expected = "a b" });
    try runIterTest(a, "(a<> b<>)", .{ .operations = "ssn", .expected = "a b" });
    try runIterTest(a, "(a<> b<>)", .{ .operations = "sss", .expected = "a b" });
}

// go-git IterSuite.TestDirWithFile
test "Iter dir with file" {
    const a = std.testing.allocator;
    try runIterTest(a, "(a(b<>))", .{ .operations = "nnn", .expected = "a" });
    try runIterTest(a, "(a(b<>))", .{ .operations = "nns", .expected = "a" });
    try runIterTest(a, "(a(b<>))", .{ .operations = "nsn", .expected = "a a/b" });
    try runIterTest(a, "(a(b<>))", .{ .operations = "nss", .expected = "a a/b" });
    try runIterTest(a, "(a(b<>))", .{ .operations = "snn", .expected = "a" });
    try runIterTest(a, "(a(b<>))", .{ .operations = "sns", .expected = "a" });
    try runIterTest(a, "(a(b<>))", .{ .operations = "ssn", .expected = "a a/b" });
    try runIterTest(a, "(a(b<>))", .{ .operations = "sss", .expected = "a a/b" });
}

// go-git IterSuite.TestThreeSiblings
test "Iter three siblings" {
    const a = std.testing.allocator;
    try runIterTest(a, "(c<> a<> b<>)", .{ .operations = "nnnn", .expected = "a b c" });
    try runIterTest(a, "(c<> a<> b<>)", .{ .operations = "nsns", .expected = "a b c" });
    try runIterTest(a, "(c<> a<> b<>)", .{ .operations = "snss", .expected = "a b c" });
    try runIterTest(a, "(c<> a<> b<>)", .{ .operations = "ssss", .expected = "a b c" });
}

// go-git IterSuite.TestThreeVertical
test "Iter three vertical" {
    const a = std.testing.allocator;
    try runIterTest(a, "(b(c(a())))", .{ .operations = "nnnn", .expected = "b" });
    try runIterTest(a, "(b(c(a())))", .{ .operations = "nsnn", .expected = "b b/c" });
    try runIterTest(a, "(b(c(a())))", .{ .operations = "nssn", .expected = "b b/c b/c/a" });
    try runIterTest(a, "(b(c(a())))", .{ .operations = "sssn", .expected = "b b/c b/c/a" });
    try runIterTest(a, "(b(c(a())))", .{ .operations = "ssss", .expected = "b b/c b/c/a" });
}

// go-git IterSuite.TestThreeMix1 / TestThreeMix2
test "Iter three mix" {
    const a = std.testing.allocator;
    try runIterTest(a, "(c(b<>) a<>)", .{ .operations = "nnnn", .expected = "a c" });
    try runIterTest(a, "(c(b<>) a<>)", .{ .operations = "nnsn", .expected = "a c c/b" });
    try runIterTest(a, "(c(b<>) a<>)", .{ .operations = "nsnn", .expected = "a c" });
    try runIterTest(a, "(c(b<>) a<>)", .{ .operations = "ssss", .expected = "a c c/b" });
    try runIterTest(a, "(b() a(c<>))", .{ .operations = "nnnn", .expected = "a b" });
    try runIterTest(a, "(b() a(c<>))", .{ .operations = "nsnn", .expected = "a a/c b" });
    try runIterTest(a, "(b() a(c<>))", .{ .operations = "ssnn", .expected = "a a/c b" });
    try runIterTest(a, "(b() a(c<>))", .{ .operations = "ssss", .expected = "a a/c b" });
}

test "Iter NewIterFromPath" {
    const a = std.testing.allocator;
    var tree = try fsnoder.New(a, "(a(b(z(d<> e(f<>)) h<>)))");
    defer tree.deinit(a);

    const z = try find(a, tree.noder(), "z");
    defer {
        var p = z;
        p.deinit(a);
    }

    var it = try Iter.initFromPath(a, z);
    defer it.deinit();

    {
        var n = try it.next();
        defer n.deinit(a);
        const s = try n.string(a);
        defer a.free(s);
        try std.testing.expectEqualStrings("a/b/z/d", s);
    }
    {
        var n = try it.next();
        defer n.deinit(a);
        const s = try n.string(a);
        defer a.free(s);
        try std.testing.expectEqualStrings("a/b/z/e", s);
    }
    {
        var n = try it.step();
        defer n.deinit(a);
        const s = try n.string(a);
        defer a.free(s);
        try std.testing.expectEqualStrings("a/b/z/e/f", s);
    }
    try std.testing.expectError(error.EndOfStream, it.step());
}

test "Iter nil root" {
    const a = std.testing.allocator;
    var it = try Iter.init(a, null);
    defer it.deinit();
    try std.testing.expectError(error.EndOfStream, it.next());
}

// go-git IterSuite.TestNewIterFailsOnChildrenErrors.
test "Iter NewIter fails on children errors" {
    const a = std.testing.allocator;
    var err_n = ErrorNoder{};
    const n = noder.noderOf(ErrorNoder, &err_n);
    try std.testing.expectError(error.MockError, Iter.init(a, n));
}

// go-git IterSuite.TestCrazy
test "Iter crazy tree" {
    const a = std.testing.allocator;
    const crazy = "(f(e(l<>) a(n(o(p())) k<>)) d<> h(j(i<> c<> m<>) b() g<>))";
    try runIterTest(a, crazy, .{ .operations = "nnnnn", .expected = "d f h" });
    try runIterTest(a, crazy, .{ .operations = "nnnns", .expected = "d f h" });
    try runIterTest(a, crazy, .{ .operations = "nnnsn", .expected = "d f h h/b h/g" });
    try runIterTest(a, crazy, .{ .operations = "nnnss", .expected = "d f h h/b h/g" });
    try runIterTest(a, crazy, .{ .operations = "nnsnn", .expected = "d f f/a f/e h" });
    try runIterTest(a, crazy, .{ .operations = "nnsns", .expected = "d f f/a f/e f/e/l" });
    try runIterTest(a, crazy, .{ .operations = "nnssn", .expected = "d f f/a f/a/k f/a/n" });
    try runIterTest(a, crazy, .{ .operations = "nnsss", .expected = "d f f/a f/a/k f/a/n" });
    try runIterTest(a, crazy, .{ .operations = "nsnnn", .expected = "d f h" });
    try runIterTest(a, crazy, .{ .operations = "nsnns", .expected = "d f h" });
    try runIterTest(a, crazy, .{ .operations = "nsnsn", .expected = "d f h h/b h/g" });
    try runIterTest(a, crazy, .{ .operations = "nsnss", .expected = "d f h h/b h/g" });
    try runIterTest(a, crazy, .{ .operations = "nssnn", .expected = "d f f/a f/e h" });
}

const ErrorNoder = struct {
    pub fn hash(_: *ErrorNoder) []const u8 {
        return &.{};
    }
    pub fn name(_: *ErrorNoder) []const u8 {
        return "";
    }
    pub fn isDir(_: *ErrorNoder) bool {
        return true;
    }
    pub fn children(_: *ErrorNoder, _: Allocator) anyerror![]Noder {
        return error.MockError;
    }
    pub fn numChildren(_: *ErrorNoder) anyerror!usize {
        return error.MockError;
    }
    pub fn skip(_: *ErrorNoder) bool {
        return false;
    }
    pub fn string(_: *ErrorNoder, allocator: Allocator) anyerror![]u8 {
        return try allocator.dupe(u8, "");
    }
};

fn find(allocator: Allocator, tree: Noder, name: []const u8) !Path {
    var it = try Iter.init(allocator, tree);
    defer it.deinit();
    while (true) {
        const current = it.step() catch |err| {
            if (err == error.EndOfStream) return error.NotFound;
            return err;
        };
        if (std.mem.eql(u8, current.name(), name)) return current;
        var tmp = current;
        tmp.deinit(allocator);
    }
}
