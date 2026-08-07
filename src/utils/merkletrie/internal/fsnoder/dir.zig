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
