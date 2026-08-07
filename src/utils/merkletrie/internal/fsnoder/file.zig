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

    pub fn init(allocator: Allocator, name_in: []const u8, contents: []const u8) Allocator.Error!*File {
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
