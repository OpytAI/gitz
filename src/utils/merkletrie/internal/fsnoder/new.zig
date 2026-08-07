//! Parse fsnoder tree descriptions (go-git `internal/fsnoder/new.go`).

const std = @import("std");
const noder = @import("noder");
const dir_mod = @import("dir.zig");
const file_mod = @import("file.zig");

const Allocator = std.mem.Allocator;
const Dir = dir_mod.Dir;
const File = file_mod.File;
const Child = dir_mod.Child;
const Noder = noder.Noder;

const dir_start: u8 = '(';
const dir_end: u8 = ')';
const dir_sep: u8 = ' ';
const file_start: u8 = '<';
const file_end: u8 = '>';

pub const Error = error{
    EmptyInput,
    DirStartNotFound,
    UnnamedInnerDir,
    MalformedDirEnd,
    ElementTooShort,
    NoFileOrDirMark,
    MalformedFile,
    InvalidFileName,
    InvalidFileContents,
    EmptyChildName,
    DuplicatedChildName,
    Unreachable,
};

/// Root wrapper that owns the tree and exposes `noder()` (go-git `New` result).
pub const Tree = struct {
    root: *Dir,
    allocator: Allocator,

    pub fn noder(self: *Tree) Noder {
        return self.root.asNoder();
    }

    pub fn deinit(self: *Tree, _: Allocator) void {
        self.root.deinit();
        // Tree is stack value; root frees itself.
    }

    pub fn string(self: *Tree, allocator: Allocator) anyerror![]u8 {
        return self.root.string(allocator);
    }
};

/// Create a full merkle trie from a string description (go-git `fsnoder.New`).
pub fn New(allocator: Allocator, s: []const u8) anyerror!Tree {
    const root = try decodeDir(allocator, s, true);
    return .{ .root = root, .allocator = allocator };
}

/// Hash equality for fsnoder tests (go-git `fsnoder.HashEqual`).
pub fn hashEqual(a: Noder, b: Noder) bool {
    return std.mem.eql(u8, a.hash(), b.hash());
}

fn decodeDir(allocator: Allocator, data_in: []const u8, is_root: bool) anyerror!*Dir {
    const data0 = std.mem.trim(u8, data_in, " \t\n\r");
    if (data0.len == 0) return Error.EmptyInput;

    const end = std.mem.indexOfScalar(u8, data0, dir_start) orelse return Error.DirStartNotFound;
    const name: []const u8 = if (end == 0) blk: {
        if (!is_root) return Error.UnnamedInnerDir;
        break :blk "";
    } else data0[0..end];

    var data = data0[end..];
    if (data[data.len - 1] != dir_end) return Error.MalformedDirEnd;
    // strip '(' and trailing ')'
    data = data[1 .. data.len - 1];

    const kids = try decodeChildren(allocator, data);
    defer allocator.free(kids);
    // Dir.init always takes ownership of Child values (frees them on error).
    return try Dir.init(allocator, name, kids);
}

fn decodeChildren(allocator: Allocator, data_in: []const u8) anyerror![]Child {
    const data = std.mem.trim(u8, data_in, " \t\n\r");
    if (data.len == 0) {
        return try allocator.alloc(Child, 0);
    }
    const chunks = try split(allocator, data);
    defer {
        // chunks are views into data; only free the slice of slices.
        allocator.free(chunks);
    }

    const ret = try allocator.alloc(Child, chunks.len);
    errdefer {
        // free already-created children
        // (handled by caller on error from New path)
    }
    var made: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < made) : (i += 1) ret[i].deinit();
        allocator.free(ret);
    }
    for (chunks, 0..) |c, i| {
        ret[i] = try decodeChild(allocator, c);
        made = i + 1;
    }
    return ret;
}

fn split(allocator: Allocator, data: []const u8) Allocator.Error![][]const u8 {
    var chunks: std.ArrayList([]const u8) = .empty;
    errdefer chunks.deinit(allocator);
    var start: usize = 0;
    var depth: i32 = 0;
    for (data, 0..) |b, i| {
        switch (b) {
            dir_start => depth += 1,
            dir_end => depth -= 1,
            dir_sep => {
                if (depth == 0) {
                    try chunks.append(allocator, data[start .. i + 1]);
                    start = i + 1;
                }
            },
            else => {},
        }
    }
    try chunks.append(allocator, data[start..]);
    return try chunks.toOwnedSlice(allocator);
}

fn decodeChild(allocator: Allocator, data_in: []const u8) anyerror!Child {
    const clean = std.mem.trim(u8, data_in, " \t\n\r");
    if (clean.len < 3) return Error.ElementTooShort;

    const file_end_i = std.mem.indexOfScalar(u8, clean, file_start);
    const dir_end_i = std.mem.indexOfScalar(u8, clean, dir_start);
    if (file_end_i == null and dir_end_i == null) return Error.NoFileOrDirMark;
    if (file_end_i == null) {
        const d = try decodeDir(allocator, clean, false);
        return .{ .dir = d };
    }
    if (dir_end_i == null) {
        const f = try decodeFile(allocator, clean);
        return .{ .file = f };
    }
    if (dir_end_i.? < file_end_i.?) {
        const d = try decodeDir(allocator, clean, false);
        return .{ .dir = d };
    }
    if (dir_end_i.? > file_end_i.?) {
        const f = try decodeFile(allocator, clean);
        return .{ .file = f };
    }
    return Error.Unreachable;
}

fn decodeFile(allocator: Allocator, data: []const u8) anyerror!*File {
    const name_end = std.mem.indexOfScalar(u8, data, file_start) orelse return Error.MalformedFile;
    const content_start = name_end + 1;
    const content_end = std.mem.indexOfScalar(u8, data, file_end) orelse return Error.MalformedFile;
    if (name_end > content_end) return Error.MalformedFile;

    const name = data[0..name_end];
    if (!validFileName(name)) return Error.InvalidFileName;

    if (content_start == content_end) {
        return try File.init(allocator, name, "");
    }
    const contents = data[content_start..content_end];
    if (!validFileContents(contents)) return Error.InvalidFileContents;
    return try File.init(allocator, name, contents);
}

fn validFileName(s: []const u8) bool {
    for (s) |c| {
        const is_letter = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
        if (!is_letter and c != '.') return false;
    }
    return true;
}

fn validFileContents(s: []const u8) bool {
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests — go-git `internal/fsnoder/new_test.go` (FSNoderSuite)
// ---------------------------------------------------------------------------

fn emptyKids() []Child {
    return @constCast(&[_]Child{});
}

// go-git check helper: New(input) hash equals expected dir hash
fn check(allocator: Allocator, input: []const u8, expected: *Dir) !void {
    var obtained = try New(allocator, input);
    defer obtained.deinit(allocator);
    try std.testing.expectEqualSlices(u8, expected.hash(), obtained.root.hash());
}

// go-git asserts err != nil without caring about the concrete error type
fn expectAnyError(result: anytype) !void {
    if (result) |_| return error.TestExpectedError else |_| {}
}

// go-git FSNoderSuite.TestNoDataFails
test "FSNoder NoDataFails" {
    const a = std.testing.allocator;
    try std.testing.expectError(Error.EmptyInput, New(a, ""));
    try std.testing.expectError(Error.EmptyInput, New(a, " \t")); // SPC + TAB
}

// go-git FSNoderSuite.TestUnnamedRootFailsIfNotRoot
test "FSNoder UnnamedRootFailsIfNotRoot" {
    const a = std.testing.allocator;
    try std.testing.expectError(Error.UnnamedInnerDir, decodeDir(a, "()", false));
}

// go-git FSNoderSuite.TestUnnamedInnerFails
test "FSNoder UnnamedInnerFails" {
    const a = std.testing.allocator;
    // New may wrap UnnamedInnerDir inside a generic anyerror from decodeChild path
    try expectAnyError(New(a, "(())"));
    try expectAnyError(New(a, "((a<>))"));
}

// go-git FSNoderSuite.TestMalformedFile
test "FSNoder MalformedFile" {
    const a = std.testing.allocator;
    try expectAnyError(New(a, "(4<>)"));
    try expectAnyError(New(a, "(4<1>)"));
    try expectAnyError(New(a, "(4?1>)"));
    try expectAnyError(New(a, "(4<a>)"));
    try expectAnyError(New(a, "(4<a?)"));

    try expectAnyError(decodeFile(a, "a?1>"));
    try expectAnyError(decodeFile(a, "a<a>"));
    try expectAnyError(decodeFile(a, "a<1?"));
    try expectAnyError(decodeFile(a, "a?>"));
    try expectAnyError(decodeFile(a, "1<>"));
    try expectAnyError(decodeFile(a, "a<?"));
}

// go-git FSNoderSuite.TestMalformedRootFails
test "FSNoder MalformedRootFails" {
    const a = std.testing.allocator;
    try expectAnyError(New(a, ")"));
    try expectAnyError(New(a, "("));
    try expectAnyError(New(a, "(a<>"));
    try expectAnyError(New(a, "a<>"));
}

// go-git FSNoderSuite.TestUnnamedEmptyRoot
test "FSNoder UnnamedEmptyRoot" {
    const a = std.testing.allocator;
    const expected = try Dir.init(a, "", emptyKids());
    defer expected.deinit();
    try check(a, "()", expected);
}

// go-git FSNoderSuite.TestNamedEmptyRoot
test "FSNoder NamedEmptyRoot" {
    const a = std.testing.allocator;
    const expected = try Dir.init(a, "a", emptyKids());
    defer expected.deinit();
    try check(a, "a()", expected);
}

// go-git FSNoderSuite.TestEmptyFile
test "FSNoder EmptyFile" {
    const a = std.testing.allocator;
    const a1 = try File.init(a, "a", "");
    var kids = [_]Child{.{ .file = a1 }};
    const expected = try Dir.init(a, "", &kids);
    defer expected.deinit();
    try check(a, "(a<>)", expected);
}

// go-git FSNoderSuite.TestNonEmptyFile
test "FSNoder NonEmptyFile" {
    const a = std.testing.allocator;
    const a1 = try File.init(a, "a", "1");
    var kids = [_]Child{.{ .file = a1 }};
    const expected = try Dir.init(a, "", &kids);
    defer expected.deinit();
    try check(a, "(a<1>)", expected);
}

// go-git FSNoderSuite.TestTwoFilesSameContents
test "FSNoder TwoFilesSameContents" {
    const a = std.testing.allocator;
    const a1 = try File.init(a, "a", "1");
    const b1 = try File.init(a, "b", "1");
    var kids = [_]Child{ .{ .file = a1 }, .{ .file = b1 } };
    const expected = try Dir.init(a, "", &kids);
    defer expected.deinit();
    try check(a, "(b<1> a<1>)", expected);
}

// go-git FSNoderSuite.TestTwoFilesDifferentContents
test "FSNoder TwoFilesDifferentContents" {
    const a = std.testing.allocator;
    const a1 = try File.init(a, "a", "1");
    const b2 = try File.init(a, "b", "2");
    var kids = [_]Child{ .{ .file = a1 }, .{ .file = b2 } };
    const expected = try Dir.init(a, "", &kids);
    defer expected.deinit();
    try check(a, "(b<2> a<1>)", expected);
}

// go-git FSNoderSuite.TestManyFiles
test "FSNoder ManyFiles" {
    const a = std.testing.allocator;
    const a1 = try File.init(a, "a", "1");
    const b2 = try File.init(a, "b", "2");
    const c1 = try File.init(a, "c", "1");
    const d3 = try File.init(a, "d", "3");
    const e1 = try File.init(a, "e", "1");
    const f4 = try File.init(a, "f", "4");
    var kids = [_]Child{
        .{ .file = e1 }, .{ .file = b2 }, .{ .file = a1 },
        .{ .file = c1 }, .{ .file = d3 }, .{ .file = f4 },
    };
    const expected = try Dir.init(a, "", &kids);
    defer expected.deinit();
    try check(a, "(e<1> b<2> a<1> c<1> d<3> f<4>)", expected);
}

// go-git FSNoderSuite.TestEmptyDir
test "FSNoder EmptyDir" {
    const a = std.testing.allocator;
    const A = try Dir.init(a, "A", emptyKids());
    var kids = [_]Child{.{ .dir = A }};
    const expected = try Dir.init(a, "", &kids);
    defer expected.deinit();
    try check(a, "(A())", expected);
}

// go-git FSNoderSuite.TestDirWithEmptyFile
test "FSNoder DirWithEmptyFile" {
    const a = std.testing.allocator;
    const f = try File.init(a, "a", "");
    var ak = [_]Child{.{ .file = f }};
    const A = try Dir.init(a, "A", &ak);
    var kids = [_]Child{.{ .dir = A }};
    const expected = try Dir.init(a, "", &kids);
    defer expected.deinit();
    try check(a, "(A(a<>))", expected);
}

// go-git FSNoderSuite.TestDirWithEmptyFileSameName
test "FSNoder DirWithEmptyFileSameName" {
    const a = std.testing.allocator;
    const f = try File.init(a, "A", "");
    var ak = [_]Child{.{ .file = f }};
    const A = try Dir.init(a, "A", &ak);
    var kids = [_]Child{.{ .dir = A }};
    const expected = try Dir.init(a, "", &kids);
    defer expected.deinit();
    try check(a, "(A(A<>))", expected);
}

// go-git FSNoderSuite.TestDirWithFileLongContents
test "FSNoder DirWithFileLongContents" {
    const a = std.testing.allocator;
    const a1 = try File.init(a, "a", "12");
    var ak = [_]Child{.{ .file = a1 }};
    const A = try Dir.init(a, "A", &ak);
    var kids = [_]Child{.{ .dir = A }};
    const expected = try Dir.init(a, "", &kids);
    defer expected.deinit();
    try check(a, "(A(a<12>))", expected);
}

// go-git FSNoderSuite.TestDirWithFileLongName
test "FSNoder DirWithFileLongName" {
    const a = std.testing.allocator;
    const a1 = try File.init(a, "abc", "12");
    var ak = [_]Child{.{ .file = a1 }};
    const A = try Dir.init(a, "A", &ak);
    var kids = [_]Child{.{ .dir = A }};
    const expected = try Dir.init(a, "", &kids);
    defer expected.deinit();
    try check(a, "(A(abc<12>))", expected);
}

// go-git FSNoderSuite.TestDirWithFile
test "FSNoder DirWithFile" {
    const a = std.testing.allocator;
    const a1 = try File.init(a, "a", "1");
    var ak = [_]Child{.{ .file = a1 }};
    const A = try Dir.init(a, "A", &ak);
    var kids = [_]Child{.{ .dir = A }};
    const expected = try Dir.init(a, "", &kids);
    defer expected.deinit();
    try check(a, "(A(a<1>))", expected);
}

// go-git FSNoderSuite.TestDirWithEmptyDirSameName
test "FSNoder DirWithEmptyDirSameName" {
    const a = std.testing.allocator;
    const A2 = try Dir.init(a, "A", emptyKids());
    var ak = [_]Child{.{ .dir = A2 }};
    const A1 = try Dir.init(a, "A", &ak);
    var kids = [_]Child{.{ .dir = A1 }};
    const expected = try Dir.init(a, "", &kids);
    defer expected.deinit();
    try check(a, "(A(A()))", expected);
}

// go-git FSNoderSuite.TestDirWithEmptyDir
test "FSNoder DirWithEmptyDir" {
    const a = std.testing.allocator;
    const B = try Dir.init(a, "B", emptyKids());
    var ak = [_]Child{.{ .dir = B }};
    const A = try Dir.init(a, "A", &ak);
    var kids = [_]Child{.{ .dir = A }};
    const expected = try Dir.init(a, "", &kids);
    defer expected.deinit();
    try check(a, "(A(B()))", expected);
}

// go-git FSNoderSuite.TestDirWithTwoFiles
test "FSNoder DirWithTwoFiles" {
    const a = std.testing.allocator;
    const a1 = try File.init(a, "a", "1");
    const b2 = try File.init(a, "b", "2");
    var ak = [_]Child{ .{ .file = b2 }, .{ .file = a1 } };
    const A = try Dir.init(a, "A", &ak);
    var kids = [_]Child{.{ .dir = A }};
    const expected = try Dir.init(a, "", &kids);
    defer expected.deinit();
    try check(a, "(A(a<1> b<2>))", expected);
}

// go-git FSNoderSuite.TestCrazy
test "FSNoder Crazy" {
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
    const expected = try Dir.init(a, "", &rk);
    defer expected.deinit();

    try check(a, "(d<2> b(c<1> b() a() x(a<1>)) a<1> c<1> e(e(e(e<1>))))", expected);
}

// go-git FSNoderSuite.TestHashEqual
test "FSNoder HashEqual" {
    const a = std.testing.allocator;
    var t1 = try New(a, "(A(a<1> b<2>))");
    defer t1.deinit(a);
    var t2 = try New(a, "(A(a<1> b<2>))");
    defer t2.deinit(a);
    var t3 = try New(a, "(A(a<> b<2>))");
    defer t3.deinit(a);

    try std.testing.expect(hashEqual(t1.noder(), t2.noder()));
    try std.testing.expect(hashEqual(t2.noder(), t1.noder()));

    try std.testing.expect(!hashEqual(t2.noder(), t3.noder()));
    try std.testing.expect(!hashEqual(t3.noder(), t2.noder()));

    try std.testing.expect(!hashEqual(t3.noder(), t1.noder()));
    try std.testing.expect(!hashEqual(t1.noder(), t3.noder()));
}
