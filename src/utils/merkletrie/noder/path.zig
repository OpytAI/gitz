//! Path: a noder and its ancestors (go-git `utils/merkletrie/noder/path.go`).

const std = @import("std");
const noder_mod = @import("noder.zig");

const Allocator = std.mem.Allocator;
const Noder = noder_mod.Noder;

/// Path from root (first) to final noder (last). Implements the Noder surface
/// by redirecting to the last element (go-git `Path`).
///
/// Empty paths are invalid for most operations; `string` returns `""`.
pub const Path = struct {
    /// Root first, leaf last. When `owned`, `deinit` frees this slice.
    nodes: []const Noder = &.{},
    owned: bool = false,

    pub fn deinit(self: *Path, allocator: Allocator) void {
        if (self.owned and self.nodes.len > 0) {
            allocator.free(@constCast(self.nodes));
        }
        self.nodes = &.{};
        self.owned = false;
    }

    /// go-git `Path.Skip`.
    pub fn skip(self: Path) bool {
        if (self.nodes.len > 0) return self.last().skip();
        return false;
    }

    /// Full path using `/` as separator (go-git `Path.String`).
    /// Caller frees the returned slice.
    pub fn string(self: Path, allocator: Allocator) Allocator.Error![]u8 {
        if (self.nodes.len == 0) return try allocator.dupe(u8, "");
        var total: usize = 0;
        for (self.nodes, 0..) |e, i| {
            if (i > 0) total += 1;
            total += e.name().len;
        }
        var buf = try allocator.alloc(u8, total);
        var pos: usize = 0;
        for (self.nodes, 0..) |e, i| {
            if (i > 0) {
                buf[pos] = '/';
                pos += 1;
            }
            const nm = e.name();
            @memcpy(buf[pos..][0..nm.len], nm);
            pos += nm.len;
        }
        return buf;
    }

    /// Final noder (go-git `Path.Last`). Panics if empty.
    pub fn last(self: Path) Noder {
        return self.nodes[self.nodes.len - 1];
    }

    /// Hash of the final noder (go-git `Path.Hash`).
    pub fn hash(self: Path) []const u8 {
        return self.last().hash();
    }

    /// Name of the final noder (go-git `Path.Name`).
    pub fn name(self: Path) []const u8 {
        return self.last().name();
    }

    /// Whether the final noder is a directory (go-git `Path.IsDir`).
    pub fn isDir(self: Path) bool {
        return self.last().isDir();
    }

    /// Children of the final noder (go-git `Path.Children`).
    pub fn children(self: Path, allocator: Allocator) anyerror![]Noder {
        return self.last().children(allocator);
    }

    /// NumChildren of the final noder (go-git `Path.NumChildren`).
    pub fn numChildren(self: Path) anyerror!usize {
        return self.last().numChildren();
    }

    /// Directory-order compare: -1, 0, or 1 (go-git `Path.Compare`).
    ///
    /// Unicode is **not** normalized (matches CGit / go-git).
    pub fn compare(self: Path, other: Path) i32 {
        var i: usize = 0;
        while (true) {
            if (other.nodes.len == self.nodes.len and i == self.nodes.len) return 0;
            if (i == other.nodes.len) return 1;
            if (i == self.nodes.len) return -1;
            const ord = std.mem.order(u8, self.nodes[i].name(), other.nodes[i].name());
            switch (ord) {
                .lt => return -1,
                .gt => return 1,
                .eq => {},
            }
            i += 1;
        }
    }

    /// Shallow-copy node pointers into an owned path.
    pub fn clone(self: Path, allocator: Allocator) Allocator.Error!Path {
        if (self.nodes.len == 0) return .{ .nodes = &.{}, .owned = false };
        const nodes = try allocator.dupe(Noder, self.nodes);
        return .{ .nodes = nodes, .owned = true };
    }

    /// Build an owned path from a slice of noders (copies the slice).
    pub fn fromNodes(allocator: Allocator, nodes: []const Noder) Allocator.Error!Path {
        if (nodes.len == 0) return .{ .nodes = &.{}, .owned = false };
        const owned = try allocator.dupe(Noder, nodes);
        return .{ .nodes = owned, .owned = true };
    }

    /// View over an existing slice (not freed by deinit).
    pub fn view(nodes: []const Noder) Path {
        return .{ .nodes = nodes, .owned = false };
    }
};

// ---------------------------------------------------------------------------
// Tests (go-git path_test.go + noder_test path fixtures)
// ---------------------------------------------------------------------------

const NoderMock = struct {
    name_s: []const u8,
    hash_b: []const u8 = &.{},
    is_dir: bool = false,
    kids: []const Noder = &.{},

    pub fn hash(self: *NoderMock) []const u8 {
        return self.hash_b;
    }
    pub fn name(self: *NoderMock) []const u8 {
        return self.name_s;
    }
    pub fn isDir(self: *NoderMock) bool {
        return self.is_dir;
    }
    pub fn children(self: *NoderMock, allocator: Allocator) anyerror![]Noder {
        return try allocator.dupe(Noder, self.kids);
    }
    pub fn numChildren(self: *NoderMock) anyerror!usize {
        return self.kids.len;
    }
    pub fn skip(_: *NoderMock) bool {
        return false;
    }
    pub fn string(self: *NoderMock, allocator: Allocator) anyerror![]u8 {
        return try allocator.dupe(u8, self.name_s);
    }
};

fn mock(n: *NoderMock) Noder {
    return noder_mod.noderOf(NoderMock, n);
}

test "Path String short file" {
    const a = std.testing.allocator;
    var f = NoderMock{ .name_s = "1", .is_dir = false };
    var nodes = [_]Noder{mock(&f)};
    const p = Path.view(&nodes);
    const s = try p.string(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("1", s);
}

test "Path String long" {
    const a = std.testing.allocator;
    var n3 = NoderMock{ .name_s = "3", .is_dir = false };
    var n2 = NoderMock{ .name_s = "2", .is_dir = true };
    var n1 = NoderMock{ .name_s = "1", .is_dir = true };
    var nodes = [_]Noder{ mock(&n1), mock(&n2), mock(&n3) };
    const p = Path.view(&nodes);
    const s = try p.string(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("1/2/3", s);
}

test "Path Last Hash IsDir Children" {
    const a = std.testing.allocator;
    var c1 = NoderMock{ .name_s = "c1" };
    var c2 = NoderMock{ .name_s = "c2" };
    const kids = [_]Noder{ mock(&c1), mock(&c2) };
    var n1 = NoderMock{
        .name_s = "1",
        .hash_b = &[_]u8{ 0x00, 0x01, 0x02 },
        .is_dir = true,
        .kids = &kids,
    };
    var n2 = NoderMock{ .name_s = "2" };
    var n3 = NoderMock{ .name_s = "3" };
    var nodes = [_]Noder{ mock(&n3), mock(&n2), mock(&n1) };
    const p = Path.view(&nodes);
    try std.testing.expectEqualStrings("1", p.last().name());
    try std.testing.expectEqualStrings("1", p.name());
    try std.testing.expect(p.isDir());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x02 }, p.hash());
    const ch = try p.children(a);
    defer a.free(ch);
    try std.testing.expectEqual(@as(usize, 2), ch.len);
    try std.testing.expectEqual(@as(usize, 2), try p.numChildren());
    const s = try p.string(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("3/2/1", s);
}

test "Path Compare depth1" {
    var a_m = NoderMock{ .name_s = "a" };
    var b_m = NoderMock{ .name_s = "b" };
    var ago = NoderMock{ .name_s = "a.go" };
    var pa = [_]Noder{mock(&a_m)};
    var pb = [_]Noder{mock(&b_m)};
    var pago = [_]Noder{mock(&ago)};
    try std.testing.expectEqual(@as(i32, -1), Path.view(&pa).compare(Path.view(&pb)));
    try std.testing.expectEqual(@as(i32, 1), Path.view(&pb).compare(Path.view(&pa)));
    try std.testing.expectEqual(@as(i32, 0), Path.view(&pa).compare(Path.view(&pa)));
    try std.testing.expectEqual(@as(i32, 1), Path.view(&pago).compare(Path.view(&pa)));
    try std.testing.expectEqual(@as(i32, -1), Path.view(&pa).compare(Path.view(&pago)));
}

test "Path Compare depth2" {
    var a1 = NoderMock{ .name_s = "a" };
    var b1 = NoderMock{ .name_s = "b" };
    var a2 = NoderMock{ .name_s = "a" };
    var b2 = NoderMock{ .name_s = "b" };
    var p1 = [_]Noder{ mock(&a1), mock(&b1) };
    var p2 = [_]Noder{ mock(&b2), mock(&a2) };
    try std.testing.expectEqual(@as(i32, -1), Path.view(&p1).compare(Path.view(&p2)));
    try std.testing.expectEqual(@as(i32, 1), Path.view(&p2).compare(Path.view(&p1)));

    var a3 = NoderMock{ .name_s = "a" };
    var b3 = NoderMock{ .name_s = "b" };
    var a4 = NoderMock{ .name_s = "a" };
    var a5 = NoderMock{ .name_s = "a" };
    var p3 = [_]Noder{ mock(&a3), mock(&b3) };
    var p4 = [_]Noder{ mock(&a4), mock(&a5) };
    try std.testing.expectEqual(@as(i32, 1), Path.view(&p3).compare(Path.view(&p4)));
}

test "Path Compare mixed depths" {
    var a1 = NoderMock{ .name_s = "a" };
    var b1 = NoderMock{ .name_s = "b" };
    var b2 = NoderMock{ .name_s = "b" };
    var p1 = [_]Noder{ mock(&a1), mock(&b1) };
    var p2 = [_]Noder{mock(&b2)};
    try std.testing.expectEqual(@as(i32, -1), Path.view(&p1).compare(Path.view(&p2)));
    try std.testing.expectEqual(@as(i32, 1), Path.view(&p2).compare(Path.view(&p1)));

    var b3 = NoderMock{ .name_s = "b" };
    var b4 = NoderMock{ .name_s = "b" };
    var b5 = NoderMock{ .name_s = "b" };
    var p3 = [_]Noder{ mock(&b3), mock(&b4) };
    var p4 = [_]Noder{mock(&b5)};
    try std.testing.expectEqual(@as(i32, 1), Path.view(&p3).compare(Path.view(&p4)));
}

test "Path Compare no unicode normalization" {
    // "페" NFKC vs NFKD differ as UTF-8; go-git does not normalize.
    // Precomposed vs decomposed accents (issue 1057 style).
    const p1_name = "TestAppWithUnicode\u{0301}Path"; // u + combining acute
    const p2_name = "TestAppWithUnicod\u{00e9}Path"; // é precomposed
    var m1 = NoderMock{ .name_s = p1_name };
    var m2 = NoderMock{ .name_s = p2_name };
    var n1 = [_]Noder{mock(&m1)};
    var n2 = [_]Noder{mock(&m2)};
    const cmp = Path.view(&n1).compare(Path.view(&n2));
    try std.testing.expect(cmp != 0);
    try std.testing.expectEqual(cmp, -Path.view(&n2).compare(Path.view(&n1)));
}
