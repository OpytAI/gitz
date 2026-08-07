//! Directory-like fsnoder (go-git `internal/fsnoder/dir.go`).

const std = @import("std");
const noder_pkg = @import("noder");

const Allocator = std.mem.Allocator;
const Noder = noder_pkg.Noder;

fn fnv1a64Update(h: *u64, data: []const u8) void {
    for (data) |b| {
        h.* ^= b;
        h.* *%= 0x100000001b3;
    }
}

/// Owned child: either a dir or a file heap pointer.
pub const Child = union(enum) {
    dir: *Dir,
    file: *@import("file.zig").File,

    pub fn asNoder(self: Child) Noder {
        return switch (self) {
            .dir => |d| d.asNoder(),
            .file => |f| f.asNoder(),
        };
    }

    pub fn deinit(self: Child) void {
        switch (self) {
            .dir => |d| d.deinit(),
            .file => |f| f.deinit(),
        }
    }
};

pub const Dir = struct {
    name_s: []u8,
    children_owned: std.ArrayList(Child) = .empty,
    hash_b: ?[8]u8 = null,
    allocator: Allocator,

    /// Takes ownership of every `Child` value in `children` (not the slice array).
    /// On error, all children are freed. On success, they live in the Dir.
    pub fn init(allocator: Allocator, name_in: []const u8, children_in: []Child) anyerror!*Dir {
        var took_ownership = false;
        errdefer if (!took_ownership) {
            for (children_in) |c| c.deinit();
        };

        std.mem.sort(Child, children_in, {}, struct {
            fn less(_: void, a: Child, b: Child) bool {
                return std.mem.order(u8, a.asNoder().name(), b.asNoder().name()) == .lt;
            }
        }.less);

        if (hasEmptyName(children_in)) return error.EmptyChildName;
        if (hasDupNames(children_in)) return error.DuplicatedChildName;

        var list: std.ArrayList(Child) = .empty;
        errdefer {
            // If we fail after took_ownership, free via list.
            if (took_ownership) {
                for (list.items) |c| c.deinit();
            }
            list.deinit(allocator);
        }
        try list.appendSlice(allocator, children_in);
        took_ownership = true;

        const name_s = try allocator.dupe(u8, name_in);
        errdefer allocator.free(name_s);

        const d = try allocator.create(Dir);
        d.* = .{
            .name_s = name_s,
            .children_owned = list,
            .allocator = allocator,
        };
        // list moved into d; neutralize list errdefer deinit of children.
        list = .empty;
        return d;
    }

    pub fn deinit(self: *Dir) void {
        for (self.children_owned.items) |c| c.deinit();
        self.children_owned.deinit(self.allocator);
        self.allocator.free(self.name_s);
        self.allocator.destroy(self);
    }

    fn hasEmptyName(kids: []const Child) bool {
        for (kids) |c| {
            if (c.asNoder().name().len == 0) return true;
        }
        return false;
    }

    fn hasDupNames(kids: []const Child) bool {
        if (kids.len < 2) return false;
        var i: usize = 1;
        while (i < kids.len) : (i += 1) {
            if (std.mem.eql(u8, kids[i].asNoder().name(), kids[i - 1].asNoder().name()))
                return true;
        }
        return false;
    }

    pub fn hash(self: *Dir) []const u8 {
        if (self.hash_b == null) {
            var h: u64 = 0xcbf29ce484222325;
            fnv1a64Update(&h, "dir ");
            for (self.children_owned.items) |c| {
                const n = c.asNoder();
                fnv1a64Update(&h, n.name());
                fnv1a64Update(&h, " ");
                fnv1a64Update(&h, n.hash());
            }
            var out: [8]u8 = undefined;
            std.mem.writeInt(u64, &out, h, .big);
            self.hash_b = out;
        }
        return &self.hash_b.?;
    }

    pub fn name(self: *Dir) []const u8 {
        return self.name_s;
    }

    pub fn isDir(_: *Dir) bool {
        return true;
    }

    pub fn children(self: *Dir, allocator: Allocator) anyerror![]Noder {
        const out = try allocator.alloc(Noder, self.children_owned.items.len);
        for (self.children_owned.items, 0..) |c, i| {
            out[i] = c.asNoder();
        }
        return out;
    }

    pub fn numChildren(self: *Dir) anyerror!usize {
        return self.children_owned.items.len;
    }

    pub fn skip(_: *Dir) bool {
        return false;
    }

    pub fn string(self: *Dir, allocator: Allocator) anyerror![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        try list.appendSlice(allocator, self.name_s);
        try list.append(allocator, '(');
        for (self.children_owned.items, 0..) |c, i| {
            if (i != 0) try list.append(allocator, ' ');
            const cs = try c.asNoder().string(allocator);
            defer allocator.free(cs);
            try list.appendSlice(allocator, cs);
        }
        try list.append(allocator, ')');
        return try list.toOwnedSlice(allocator);
    }

    pub fn asNoder(self: *Dir) Noder {
        return noder_pkg.noderOf(Dir, self);
    }
};

// ---------------------------------------------------------------------------
// Tests — go-git `internal/fsnoder/dir_test.go` (DirSuite)
// ---------------------------------------------------------------------------

const File = @import("file.zig").File;

fn assertChildren(allocator: Allocator, n: Noder, expected: []const Noder) !void {
    try std.testing.expectEqual(expected.len, try n.numChildren());
    const kids = try n.children(allocator);
    defer allocator.free(kids);

    const exp = try allocator.dupe(Noder, expected);
    defer allocator.free(exp);
    std.mem.sort(Noder, exp, {}, struct {
        fn less(_: void, a: Noder, b: Noder) bool {
            return std.mem.order(u8, a.name(), b.name()) == .lt;
        }
    }.less);

    try std.testing.expectEqual(exp.len, kids.len);
    for (kids, exp) |k, e| {
        try std.testing.expect(k.eql(e));
    }
}

fn emptyKids() []Child {
    return @constCast(&[_]Child{});
}

// go-git DirSuite.TestIsDir
test "Dir IsDir" {
    const a = std.testing.allocator;

    const no_name = try Dir.init(a, "", emptyKids());
    defer no_name.deinit();
    try std.testing.expect(no_name.isDir());

    const empty = try Dir.init(a, "empty", emptyKids());
    defer empty.deinit();
    try std.testing.expect(empty.isDir());

    const empty2 = try Dir.init(a, "empty", emptyKids());
    var kids = [_]Child{.{ .dir = empty2 }};
    const root = try Dir.init(a, "foo", &kids);
    defer root.deinit();
    try std.testing.expect(root.isDir());
}

// go-git DirSuite.TestNewDirectoryNoNameAndEmpty
test "Dir NewDirectoryNoNameAndEmpty" {
    const a = std.testing.allocator;
    const root = try Dir.init(a, "", emptyKids());
    defer root.deinit();

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xca, 0x40, 0xf8, 0x67, 0x57, 0x8c, 0x32, 0x1c }, root.hash());
    try std.testing.expectEqualStrings("", root.name());
    try assertChildren(a, root.asNoder(), &.{});
    const s = try root.string(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("()", s);
}

// go-git DirSuite.TestNewDirectoryEmpty
test "Dir NewDirectoryEmpty" {
    const a = std.testing.allocator;
    const root = try Dir.init(a, "root", emptyKids());
    defer root.deinit();

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xca, 0x40, 0xf8, 0x67, 0x57, 0x8c, 0x32, 0x1c }, root.hash());
    try std.testing.expectEqualStrings("root", root.name());
    try assertChildren(a, root.asNoder(), &.{});
    const s = try root.string(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("root()", s);
}

// go-git DirSuite.TestEmptyDirsHaveSameHash
test "Dir EmptyDirsHaveSameHash" {
    const a = std.testing.allocator;
    const d1 = try Dir.init(a, "foo", emptyKids());
    defer d1.deinit();
    const d2 = try Dir.init(a, "bar", emptyKids());
    defer d2.deinit();
    try std.testing.expectEqualSlices(u8, d1.hash(), d2.hash());
}

// go-git DirSuite.TestNewDirWithEmptyDir
test "Dir NewDirWithEmptyDir" {
    const a = std.testing.allocator;
    const empty = try Dir.init(a, "empty", emptyKids());
    var kids = [_]Child{.{ .dir = empty }};
    const root = try Dir.init(a, "", &kids);
    defer root.deinit();

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x39, 0x25, 0xa8, 0x99, 0x16, 0x47, 0x6a, 0x75 }, root.hash());
    try std.testing.expectEqualStrings("", root.name());
    try assertChildren(a, root.asNoder(), &.{empty.asNoder()});
    const s = try root.string(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("(empty())", s);
}

// go-git DirSuite.TestNewDirWithOneEmptyFile
test "Dir NewDirWithOneEmptyFile" {
    const a = std.testing.allocator;
    const empty = try File.init(a, "name", "");
    var kids = [_]Child{.{ .file = empty }};
    const root = try Dir.init(a, "", &kids);
    defer root.deinit();

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xd, 0x4e, 0x23, 0x1d, 0xf5, 0x2e, 0xfa, 0xc2 }, root.hash());
    try std.testing.expectEqualStrings("", root.name());
    try assertChildren(a, root.asNoder(), &.{empty.asNoder()});
    const s = try root.string(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("(name<>)", s);
}

// go-git DirSuite.TestNewDirWithOneFile
test "Dir NewDirWithOneFile" {
    const a = std.testing.allocator;
    const f = try File.init(a, "a", "1");
    var kids = [_]Child{.{ .file = f }};
    const root = try Dir.init(a, "", &kids);
    defer root.deinit();

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x96, 0xab, 0x29, 0x54, 0x2, 0x9e, 0x89, 0x28 }, root.hash());
    try std.testing.expectEqualStrings("", root.name());
    try assertChildren(a, root.asNoder(), &.{f.asNoder()});
    const s = try root.string(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("(a<1>)", s);
}

// go-git DirSuite.TestDirsWithSameFileHaveSameHash
test "Dir DirsWithSameFileHaveSameHash" {
    const a = std.testing.allocator;
    const f1 = try File.init(a, "a", "1");
    var kids1 = [_]Child{.{ .file = f1 }};
    const r1 = try Dir.init(a, "", &kids1);
    defer r1.deinit();

    const f2 = try File.init(a, "a", "1");
    var kids2 = [_]Child{.{ .file = f2 }};
    const r2 = try Dir.init(a, "", &kids2);
    defer r2.deinit();

    try std.testing.expectEqualSlices(u8, r1.hash(), r2.hash());
}

// go-git DirSuite.TestDirsWithDifferentFileContentHaveDifferentHash
test "Dir DirsWithDifferentFileContentHaveDifferentHash" {
    const a = std.testing.allocator;
    const f1 = try File.init(a, "a", "1");
    var kids1 = [_]Child{.{ .file = f1 }};
    const r1 = try Dir.init(a, "", &kids1);
    defer r1.deinit();

    const f2 = try File.init(a, "a", "2");
    var kids2 = [_]Child{.{ .file = f2 }};
    const r2 = try Dir.init(a, "", &kids2);
    defer r2.deinit();

    try std.testing.expect(!std.mem.eql(u8, r1.hash(), r2.hash()));
}

// go-git DirSuite.TestDirsWithDifferentFileNameHaveDifferentHash
test "Dir DirsWithDifferentFileNameHaveDifferentHash" {
    const a = std.testing.allocator;
    const f1 = try File.init(a, "a", "1");
    var kids1 = [_]Child{.{ .file = f1 }};
    const r1 = try Dir.init(a, "", &kids1);
    defer r1.deinit();

    const f2 = try File.init(a, "b", "1");
    var kids2 = [_]Child{.{ .file = f2 }};
    const r2 = try Dir.init(a, "", &kids2);
    defer r2.deinit();

    try std.testing.expect(!std.mem.eql(u8, r1.hash(), r2.hash()));
}

// go-git DirSuite.TestDirsWithDifferentFileHaveDifferentHash
test "Dir DirsWithDifferentFileHaveDifferentHash" {
    const a = std.testing.allocator;
    const f1 = try File.init(a, "a", "1");
    var kids1 = [_]Child{.{ .file = f1 }};
    const r1 = try Dir.init(a, "", &kids1);
    defer r1.deinit();

    const f2 = try File.init(a, "b", "2");
    var kids2 = [_]Child{.{ .file = f2 }};
    const r2 = try Dir.init(a, "", &kids2);
    defer r2.deinit();

    try std.testing.expect(!std.mem.eql(u8, r1.hash(), r2.hash()));
}

// go-git DirSuite.TestDirWithEmptyDirHasDifferentHashThanEmptyDir
test "Dir DirWithEmptyDirHasDifferentHashThanEmptyDir" {
    const a = std.testing.allocator;
    const f = try File.init(a, "a", "");
    var kids1 = [_]Child{.{ .file = f }};
    const r1 = try Dir.init(a, "", &kids1);
    defer r1.deinit();

    const d = try Dir.init(a, "a", emptyKids());
    var kids2 = [_]Child{.{ .dir = d }};
    const r2 = try Dir.init(a, "", &kids2);
    defer r2.deinit();

    try std.testing.expect(!std.mem.eql(u8, r1.hash(), r2.hash()));
}

// go-git DirSuite.TestNewDirWithTwoFilesSameContent
test "Dir NewDirWithTwoFilesSameContent" {
    const a = std.testing.allocator;
    const a1 = try File.init(a, "a", "1");
    const b1 = try File.init(a, "b", "1");
    var kids = [_]Child{ .{ .file = a1 }, .{ .file = b1 } };
    const root = try Dir.init(a, "", &kids);
    defer root.deinit();

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xc7, 0xc4, 0xbf, 0x70, 0x33, 0xb9, 0x57, 0xdb }, root.hash());
    try std.testing.expectEqualStrings("", root.name());
    try assertChildren(a, root.asNoder(), &.{ b1.asNoder(), a1.asNoder() });
    const s = try root.string(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("(a<1> b<1>)", s);
}

// go-git DirSuite.TestNewDirWithTwoFilesDifferentContent
test "Dir NewDirWithTwoFilesDifferentContent" {
    const a = std.testing.allocator;
    const a1 = try File.init(a, "a", "1");
    const b2 = try File.init(a, "b", "2");
    var kids = [_]Child{ .{ .file = a1 }, .{ .file = b2 } };
    const root = try Dir.init(a, "", &kids);
    defer root.deinit();

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x94, 0x8a, 0x9d, 0x8f, 0x6d, 0x98, 0x34, 0x55 }, root.hash());
    try std.testing.expectEqualStrings("", root.name());
    try assertChildren(a, root.asNoder(), &.{ b2.asNoder(), a1.asNoder() });
}

// go-git DirSuite.TestCrazy
test "Dir Crazy" {
    const a = std.testing.allocator;
    //           ""
    //            |
    //   -------------------------
    //   |    |      |      |    |
    //  a1    B     c1     d2    E
    //        |                  |
    //   -------------           E
    //   |   |   |   |           |
    //   A   B   X   c1          E
    //           |               |
    //          a1               e1
    const e1 = try File.init(a, "e", "1");
    var ek1 = [_]Child{.{ .file = e1 }};
    var E = try Dir.init(a, "e", &ek1);
    var ek2 = [_]Child{.{ .dir = E }};
    E = try Dir.init(a, "e", &ek2);
    var ek3 = [_]Child{.{ .dir = E }};
    E = try Dir.init(a, "e", &ek3);

    const A = try Dir.init(a, "a", emptyKids());
    const B_empty = try Dir.init(a, "b", emptyKids());
    const a1_inner = try File.init(a, "a", "1");
    var xk = [_]Child{.{ .file = a1_inner }};
    const X = try Dir.init(a, "x", &xk);
    const c1_inner = try File.init(a, "c", "1");
    var bk = [_]Child{ .{ .file = c1_inner }, .{ .dir = B_empty }, .{ .dir = X }, .{ .dir = A } };
    const B = try Dir.init(a, "b", &bk);

    const a1 = try File.init(a, "a", "1");
    const c1 = try File.init(a, "c", "1");
    const d2 = try File.init(a, "d", "2");

    var rk = [_]Child{ .{ .file = a1 }, .{ .file = d2 }, .{ .dir = E }, .{ .dir = B }, .{ .file = c1 } };
    const root = try Dir.init(a, "", &rk);
    defer root.deinit();

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xc3, 0x72, 0x9d, 0xf1, 0xcc, 0xec, 0x6d, 0xbb }, root.hash());
    try std.testing.expectEqualStrings("", root.name());
    try assertChildren(a, root.asNoder(), &.{ E.asNoder(), c1.asNoder(), B.asNoder(), a1.asNoder(), d2.asNoder() });
    const s = try root.string(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("(a<1> b(a() b() c<1> x(a<1>)) c<1> d<2> e(e(e(e<1>))))", s);
}

// go-git DirSuite.TestDirCannotHaveDirWithNoName
test "Dir DirCannotHaveDirWithNoName" {
    const a = std.testing.allocator;
    const no_name = try Dir.init(a, "", emptyKids());
    var kids = [_]Child{.{ .dir = no_name }};
    try std.testing.expectError(error.EmptyChildName, Dir.init(a, "", &kids));
}

// go-git DirSuite.TestDirCannotHaveDuplicatedFiles
test "Dir DirCannotHaveDuplicatedFiles" {
    const a = std.testing.allocator;
    const f1 = try File.init(a, "a", "1");
    const f2 = try File.init(a, "a", "1");
    var kids = [_]Child{ .{ .file = f1 }, .{ .file = f2 } };
    try std.testing.expectError(error.DuplicatedChildName, Dir.init(a, "", &kids));
}

// go-git DirSuite.TestDirCannotHaveDuplicatedFileNames
test "Dir DirCannotHaveDuplicatedFileNames" {
    const a = std.testing.allocator;
    const a1 = try File.init(a, "a", "1");
    const a2 = try File.init(a, "a", "2");
    var kids = [_]Child{ .{ .file = a1 }, .{ .file = a2 } };
    try std.testing.expectError(error.DuplicatedChildName, Dir.init(a, "", &kids));
}

// go-git DirSuite.TestDirCannotHaveDuplicatedDirNames
test "Dir DirCannotHaveDuplicatedDirNames" {
    const a = std.testing.allocator;
    const d1 = try Dir.init(a, "a", emptyKids());
    const d2 = try Dir.init(a, "a", emptyKids());
    var kids = [_]Child{ .{ .dir = d1 }, .{ .dir = d2 } };
    try std.testing.expectError(error.DuplicatedChildName, Dir.init(a, "", &kids));
}

// go-git DirSuite.TestDirCannotHaveDirAndFileWithSameName
test "Dir DirCannotHaveDirAndFileWithSameName" {
    const a = std.testing.allocator;
    const f = try File.init(a, "a", "");
    const d = try Dir.init(a, "a", emptyKids());
    var kids = [_]Child{ .{ .file = f }, .{ .dir = d } };
    try std.testing.expectError(error.DuplicatedChildName, Dir.init(a, "", &kids));
}

// go-git DirSuite.TestUnsortedString
test "Dir UnsortedString" {
    const a = std.testing.allocator;
    const b = try Dir.init(a, "b", emptyKids());
    const z = try Dir.init(a, "z", emptyKids());
    const a1 = try File.init(a, "a", "1");
    const c2 = try File.init(a, "c", "2");
    const d3 = try File.init(a, "d", "3");

    var kids = [_]Child{ .{ .file = c2 }, .{ .dir = z }, .{ .file = d3 }, .{ .file = a1 }, .{ .dir = b } };
    const d = try Dir.init(a, "d", &kids);
    defer d.deinit();

    const s = try d.string(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("d(a<1> b() c<2> d<3> z())", s);
}
