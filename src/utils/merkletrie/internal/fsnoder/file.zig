//! File-like fsnoder (go-git `internal/fsnoder/file.go`).

const std = @import("std");
const noder_pkg = @import("noder");

const Allocator = std.mem.Allocator;
const Noder = noder_pkg.Noder;

/// FNV-1a 64-bit (matches Go `hash/fnv`.New64a).
fn fnv1a64(data: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (data) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

fn hashBytes(data: []const u8) [8]u8 {
    var out: [8]u8 = undefined;
    std.mem.writeInt(u64, &out, fnv1a64(data), .big);
    return out;
}

pub const File = struct {
    name_s: []u8,
    contents: []u8,
    hash_b: ?[8]u8 = null,
    allocator: Allocator,

    /// Create a file noder (go-git `newFile`). Empty names are rejected.
    pub fn init(allocator: Allocator, name_in: []const u8, contents: []const u8) (Allocator.Error || error{EmptyFileName})!*File {
        // go-git: files cannot have empty names
        if (name_in.len == 0) return error.EmptyFileName;

        const f = try allocator.create(File);
        errdefer allocator.destroy(f);
        const name_s = try allocator.dupe(u8, name_in);
        errdefer allocator.free(name_s);
        const cont = try allocator.dupe(u8, contents);
        errdefer allocator.free(cont);
        f.* = .{
            .name_s = name_s,
            .contents = cont,
            .allocator = allocator,
        };
        return f;
    }

    pub fn deinit(self: *File) void {
        self.allocator.free(self.name_s);
        self.allocator.free(self.contents);
        self.allocator.destroy(self);
    }

    pub fn hash(self: *File) []const u8 {
        if (self.hash_b == null) {
            self.hash_b = hashBytes(self.contents);
        }
        return &self.hash_b.?;
    }

    pub fn name(self: *File) []const u8 {
        return self.name_s;
    }

    pub fn isDir(_: *File) bool {
        return false;
    }

    pub fn children(_: *File, _: Allocator) anyerror![]Noder {
        return noder_pkg.no_children;
    }

    pub fn numChildren(_: *File) anyerror!usize {
        return 0;
    }

    pub fn skip(_: *File) bool {
        return false;
    }

    pub fn string(self: *File, allocator: Allocator) anyerror![]u8 {
        return std.fmt.allocPrint(allocator, "{s}<{s}>", .{ self.name_s, self.contents });
    }

    pub fn asNoder(self: *File) Noder {
        return noder_pkg.noderOf(File, self);
    }
};

// ---------------------------------------------------------------------------
// Tests — go-git `internal/fsnoder/file_test.go` (FileSuite)
// ---------------------------------------------------------------------------

// FNV-1a 64-bit big-endian hashes (go-git HashOfEmptyFile / HashOfContents)
const hash_of_empty_file = [_]u8{ 0xcb, 0xf2, 0x9c, 0xe4, 0x84, 0x22, 0x23, 0x25 };
const hash_of_contents = [_]u8{ 0xee, 0x7e, 0xf3, 0xd0, 0xc2, 0xb5, 0xef, 0x83 };

// go-git FileSuite.TestNewFileEmpty
test "File NewFileEmpty" {
    const a = std.testing.allocator;
    const f = try File.init(a, "name", "");
    defer f.deinit();

    try std.testing.expectEqualSlices(u8, &hash_of_empty_file, f.hash());
    try std.testing.expectEqualStrings("name", f.name());
    try std.testing.expect(!f.isDir());
    try std.testing.expectEqual(@as(usize, 0), try f.numChildren());
    const kids = try f.children(a);
    try std.testing.expectEqual(@as(usize, 0), kids.len);
    const s = try f.string(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("name<>", s);
}

// go-git FileSuite.TestNewFileWithContents
test "File NewFileWithContents" {
    const a = std.testing.allocator;
    const f = try File.init(a, "name", "contents");
    defer f.deinit();

    try std.testing.expectEqualSlices(u8, &hash_of_contents, f.hash());
    try std.testing.expectEqualStrings("name", f.name());
    try std.testing.expect(!f.isDir());
    try std.testing.expectEqual(@as(usize, 0), try f.numChildren());
    const kids = try f.children(a);
    try std.testing.expectEqual(@as(usize, 0), kids.len);
    const s = try f.string(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("name<contents>", s);
}

// go-git FileSuite.TestNewfileErrorEmptyName
test "File NewfileErrorEmptyName" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.EmptyFileName, File.init(a, "", "contents"));
}

// go-git FileSuite.TestDifferentContentsHaveDifferentHash
test "File DifferentContentsHaveDifferentHash" {
    const a = std.testing.allocator;
    const f1 = try File.init(a, "name", "contents");
    defer f1.deinit();
    const f2 = try File.init(a, "name", "foo");
    defer f2.deinit();
    try std.testing.expect(!std.mem.eql(u8, f1.hash(), f2.hash()));
}

// go-git FileSuite.TestSameContentsHaveSameHash
test "File SameContentsHaveSameHash" {
    const a = std.testing.allocator;
    const f1 = try File.init(a, "name1", "contents");
    defer f1.deinit();
    const f2 = try File.init(a, "name2", "contents");
    defer f2.deinit();
    try std.testing.expectEqualSlices(u8, f1.hash(), f2.hash());
}
