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

test "fsnoder New basic" {
    const a = std.testing.allocator;
    var t = try New(a, "(a<1> b<2>)");
    defer t.deinit(a);
    try std.testing.expect(t.noder().isDir());
    try std.testing.expectEqual(@as(usize, 2), try t.noder().numChildren());
    const s = try t.string(a);
    defer a.free(s);
    // children sorted: a then b
    try std.testing.expectEqualStrings("(a<1> b<2>)", s);
}

test "fsnoder HashEqual" {
    const a = std.testing.allocator;
    var t1 = try New(a, "(a<1>)");
    defer t1.deinit(a);
    var t2 = try New(a, "(a<1>)");
    defer t2.deinit(a);
    var t3 = try New(a, "(a<2>)");
    defer t3.deinit(a);
    try std.testing.expect(hashEqual(t1.noder(), t2.noder()));
    try std.testing.expect(!hashEqual(t1.noder(), t3.noder()));
}
