//! Change and Changes (go-git `utils/merkletrie/change.go`).

const std = @import("std");
const noder = @import("noder");
const iter_mod = @import("iter.zig");

const Allocator = std.mem.Allocator;
const Path = noder.Path;

pub const Error = error{
    EmptyFileName,
    MalformedChange,
    UnsupportedAction,
};

/// Kind of change (go-git `Action`).
pub const Action = enum(u8) {
    insert = 1,
    delete = 2,
    modify = 3,

    pub fn string(self: Action) []const u8 {
        return switch (self) {
            .insert => "Insert",
            .delete => "Delete",
            .modify => "Modify",
        };
    }
};

/// How a noder changed between two merkletries (go-git `Change`).
pub const Change = struct {
    /// Before the change; null if inserted (go-git `From`).
    from: ?Path = null,
    /// After the change; null if deleted (go-git `To`).
    to: ?Path = null,

    pub fn deinit(self: *Change, allocator: Allocator) void {
        if (self.from) |*p| p.deinit(allocator);
        if (self.to) |*p| p.deinit(allocator);
        self.from = null;
        self.to = null;
    }

    /// Action this change represents (go-git `Change.Action`).
    pub fn action(self: *const Change) Error!Action {
        if (self.from == null and self.to == null) return Error.MalformedChange;
        if (self.from == null) return .insert;
        if (self.to == null) return .delete;
        return .modify;
    }

    /// Human-readable form `<Action path>` (go-git `Change.String`).
    /// Caller frees. Panics on malformed change (matches go-git).
    pub fn string(self: *const Change, allocator: Allocator) Allocator.Error![]u8 {
        const act = self.action() catch unreachable;
        const path_s = blk: {
            if (act == .delete) {
                break :blk try self.from.?.string(allocator);
            } else {
                break :blk try self.to.?.string(allocator);
            }
        };
        defer allocator.free(path_s);
        return std.fmt.allocPrint(allocator, "<{s} {s}>", .{ act.string(), path_s });
    }
};

/// Insert of path `n` (go-git `NewInsert`).
pub fn newInsert(n: Path) Change {
    return .{ .to = n };
}

/// Delete of path `n` (go-git `NewDelete`).
pub fn newDelete(n: Path) Change {
    return .{ .from = n };
}

/// Modify from `a` to `b` (go-git `NewModify`).
pub fn newModify(a: Path, b: Path) Change {
    return .{ .from = a, .to = b };
}

/// List of changes (go-git `Changes`).
pub const Changes = struct {
    items: std.ArrayList(Change) = .empty,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Changes {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Changes) void {
        for (self.items.items) |*c| c.deinit(self.allocator);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Changes, c: Change) Allocator.Error!void {
        try self.items.append(self.allocator, c);
    }

    /// Recursively insert all file-like noders under root (go-git `AddRecursiveInsert`).
    pub fn addRecursiveInsert(self: *Changes, root: Path) anyerror!void {
        return self.addRecursive(root, .insert);
    }

    /// Recursively delete all file-like noders under root (go-git `AddRecursiveDelete`).
    pub fn addRecursiveDelete(self: *Changes, root: Path) anyerror!void {
        return self.addRecursive(root, .delete);
    }

    fn addRecursive(self: *Changes, root: Path, kind: enum { insert, delete }) anyerror!void {
        const root_s = try root.string(self.allocator);
        defer self.allocator.free(root_s);
        if (root_s.len == 0) return Error.EmptyFileName;

        if (!root.isDir()) {
            if (!root.skip()) {
                var owned = try root.clone(self.allocator);
                errdefer owned.deinit(self.allocator);
                const c = switch (kind) {
                    .insert => newInsert(owned),
                    .delete => newDelete(owned),
                };
                try self.add(c);
                // Path value copied into Change; clear so errdefer no-ops.
                owned = .{};
            }
            return;
        }

        var it = try iter_mod.Iter.initFromPath(self.allocator, root);
        defer it.deinit();

        while (true) {
            // step returns an owned path; free unless transferred into a Change.
            const current = it.step() catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            if (current.isDir() or current.skip()) {
                var tmp = current;
                tmp.deinit(self.allocator);
                continue;
            }
            var owned = current;
            errdefer owned.deinit(self.allocator);
            const c = switch (kind) {
                .insert => newInsert(owned),
                .delete => newDelete(owned),
            };
            try self.add(c);
            // Transferred into Change; clear so errdefer no-ops.
            owned = .{};
        }
    }
};

// ---------------------------------------------------------------------------
// Tests (go-git change_test.go)
// ---------------------------------------------------------------------------

const fsnoder = @import("fsnoder");

test "Action string" {
    try std.testing.expectEqualStrings("Insert", Action.insert.string());
    try std.testing.expectEqualStrings("Delete", Action.delete.string());
    try std.testing.expectEqualStrings("Modify", Action.modify.string());
}

test "EmptyChanges AddRecursive empty path" {
    const a = std.testing.allocator;
    var ret = Changes.init(a);
    defer ret.deinit();
    const p = Path{};
    try std.testing.expectError(Error.EmptyFileName, ret.addRecursiveInsert(p));
    try std.testing.expectError(Error.EmptyFileName, ret.addRecursiveDelete(p));
}

// go-git ChangeSuite.TestNewInsert / TestNewDelete / TestNewModify.
test "NewInsert NewDelete NewModify strings" {
    const a = std.testing.allocator;
    var tree = try fsnoder.New(a, "(a(b(z<>)))");
    defer tree.deinit(a);
    const path = try find(a, tree.noder(), "z");
    defer {
        var p = path;
        p.deinit(a);
    }

    {
        const ch = newInsert(try path.clone(a));
        var c = ch;
        defer c.deinit(a);
        const s = try c.string(a);
        defer a.free(s);
        try std.testing.expectEqualStrings("<Insert a/b/z>", s);
    }
    {
        const short = try Path.fromNodes(a, path.nodes[path.nodes.len - 1 ..]);
        var ch = newInsert(short);
        defer ch.deinit(a);
        const s = try ch.string(a);
        defer a.free(s);
        try std.testing.expectEqualStrings("<Insert z>", s);
    }
    {
        var ch = newDelete(try path.clone(a));
        defer ch.deinit(a);
        const s = try ch.string(a);
        defer a.free(s);
        try std.testing.expectEqualStrings("<Delete a/b/z>", s);
    }
    {
        const short = try Path.fromNodes(a, path.nodes[path.nodes.len - 1 ..]);
        var ch = newDelete(short);
        defer ch.deinit(a);
        const s = try ch.string(a);
        defer a.free(s);
        try std.testing.expectEqualStrings("<Delete z>", s);
    }

    var tree2 = try fsnoder.New(a, "(a(b(z<1>)))");
    defer tree2.deinit(a);
    const path2 = try find(a, tree2.noder(), "z");
    defer {
        var p = path2;
        p.deinit(a);
    }
    {
        var ch = newModify(try path.clone(a), try path2.clone(a));
        defer ch.deinit(a);
        const s = try ch.string(a);
        defer a.free(s);
        try std.testing.expectEqualStrings("<Modify a/b/z>", s);
    }
    {
        const short1 = try Path.fromNodes(a, path.nodes[path.nodes.len - 1 ..]);
        const short2 = try Path.fromNodes(a, path2.nodes[path2.nodes.len - 1 ..]);
        var ch = newModify(short1, short2);
        defer ch.deinit(a);
        const s = try ch.string(a);
        defer a.free(s);
        try std.testing.expectEqualStrings("<Modify z>", s);
    }
}

// go-git MalformedChange panics on String; Zig returns MalformedChange from action.
test "Malformed change action" {
    const c = Change{};
    try std.testing.expectError(Error.MalformedChange, c.action());
}

// Successful recursive insert/delete (empty-path errors covered above).
// go-git AddRecursiveInsert / AddRecursiveDelete walk file-like noders only.
// Tree: root → a/{b/z, x, y}
test "AddRecursiveInsert nested files" {
    const a = std.testing.allocator;
    var tree = try fsnoder.New(a, "(a(b(z<>) x<> y<>))");
    defer tree.deinit(a);

    // Single file: insert just that path.
    {
        const path_z = try find(a, tree.noder(), "z");
        defer {
            var p = path_z;
            p.deinit(a);
        }
        var ret = Changes.init(a);
        defer ret.deinit();
        try ret.addRecursiveInsert(path_z);
        try std.testing.expectEqual(@as(usize, 1), ret.items.items.len);
        const act = try ret.items.items[0].action();
        try std.testing.expectEqual(Action.insert, act);
        const s = try ret.items.items[0].string(a);
        defer a.free(s);
        try std.testing.expectEqualStrings("<Insert a/b/z>", s);
    }

    // Directory "a": files a/b/z, a/x, a/y (iter Step, skip dirs).
    {
        const path_a = try find(a, tree.noder(), "a");
        defer {
            var p = path_a;
            p.deinit(a);
        }
        var ret = Changes.init(a);
        defer ret.deinit();
        try ret.addRecursiveInsert(path_a);
        try std.testing.expectEqual(@as(usize, 3), ret.items.items.len);

        var paths: [3][]u8 = undefined;
        defer for (paths) |p| a.free(p);
        for (ret.items.items, 0..) |c, i| {
            try std.testing.expectEqual(Action.insert, try c.action());
            paths[i] = try c.to.?.string(a);
        }
        // Depth-first: a/b, a/b/z, a/x, a/y → files a/b/z, a/x, a/y
        try std.testing.expectEqualStrings("a/b/z", paths[0]);
        try std.testing.expectEqualStrings("a/x", paths[1]);
        try std.testing.expectEqualStrings("a/y", paths[2]);
    }
}

test "AddRecursiveDelete nested files" {
    const a = std.testing.allocator;
    var tree = try fsnoder.New(a, "(a(b(z<>) y<>))");
    defer tree.deinit(a);

    const path_a = try find(a, tree.noder(), "a");
    defer {
        var p = path_a;
        p.deinit(a);
    }
    var ret = Changes.init(a);
    defer ret.deinit();
    try ret.addRecursiveDelete(path_a);
    try std.testing.expectEqual(@as(usize, 2), ret.items.items.len);
    for (ret.items.items) |c| {
        try std.testing.expectEqual(Action.delete, try c.action());
    }
    const s0 = try ret.items.items[0].string(a);
    defer a.free(s0);
    const s1 = try ret.items.items[1].string(a);
    defer a.free(s1);
    try std.testing.expectEqualStrings("<Delete a/b/z>", s0);
    try std.testing.expectEqualStrings("<Delete a/y>", s1);
}

fn find(allocator: Allocator, tree: noder.Noder, name: []const u8) !Path {
    var it = try iter_mod.Iter.init(allocator, tree);
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
