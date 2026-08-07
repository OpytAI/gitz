//! Tree change types (go-git `plumbing/object/change.go`).
//!
//! Ownership:
//! - `ChangeEntry.name` is owned by the `Change` when produced by DiffTree.
//! - `ChangeEntry.tree` is borrowed; the `Tree` must outlive the `Change`.
//! - `ChangeEntry.tree_entry.name` is borrowed from that tree's entry storage.
//! - Modify changes store one path allocation shared by `from.name` and `to.name`.

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const tree_mod = @import("tree.zig");
const file_mod = @import("file.zig");
const error_mod = @import("error.zig");

const Allocator = std.mem.Allocator;
const Tree = tree_mod.Tree;
const TreeEntry = tree_mod.TreeEntry;
const File = file_mod.File;
const Error = error_mod.Error;

/// go-git merkletrie.Action values used by `Change.action`.
pub const Action = enum {
    insert,
    delete,
    modify,

    /// go-git `Action.String`.
    pub fn string(self: Action) []const u8 {
        return switch (self) {
            .insert => "Insert",
            .delete => "Delete",
            .modify => "Modify",
        };
    }
};

/// go-git `DiffTreeOptions` (shared by difftree + rename to avoid import cycles).
pub const DiffTreeOptions = struct {
    detect_renames: bool = false,
    rename_score: u32 = 60,
    rename_limit: u32 = 0,
    only_exact_renames: bool = false,

    /// go-git `DefaultDiffTreeOptions`.
    pub const default: DiffTreeOptions = .{
        .detect_renames = true,
        .rename_score = 60,
        .rename_limit = 0,
        .only_exact_renames = false,
    };
};

/// go-git `ChangeEntry`.
pub const ChangeEntry = struct {
    /// Full path using `/` as separator.
    name: []const u8 = "",
    /// Parent tree of the node (null for empty side). Borrowed.
    tree: ?*Tree = null,
    tree_entry: TreeEntry = .{
        .name = "",
        .mode = filemode.Empty,
        .hash = plumbing.ZeroHash,
    },

    pub fn isEmpty(self: ChangeEntry) bool {
        return self.name.len == 0 and
            self.tree == null and
            self.tree_entry.hash.isZero() and
            self.tree_entry.mode == filemode.Empty;
    }
};

/// go-git `Change`.
pub const Change = struct {
    from: ChangeEntry = .{},
    to: ChangeEntry = .{},

    /// go-git `(*Change).Action`.
    pub fn action(self: *const Change) Error!Action {
        const fe = self.from.isEmpty();
        const te = self.to.isEmpty();
        if (fe and te) return error.MalformedChange;
        if (fe) return .insert;
        if (te) return .delete;
        return .modify;
    }

    /// Path used for sorting / display (prefer `from` when present).
    pub fn name(self: *const Change) []const u8 {
        if (!self.from.isEmpty()) return self.from.name;
        return self.to.name;
    }

    /// go-git `(*Change).String`. Caller frees with `allocator`.
    pub fn string(self: *const Change, allocator: Allocator) Allocator.Error![]u8 {
        const act = self.action() catch {
            return try allocator.dupe(u8, "malformed change");
        };
        return try std.fmt.allocPrint(allocator, "<Action: {s}, Path: {s}>", .{ act.string(), self.name() });
    }

    /// go-git `(*Change).Files` — from/to files for patch.
    /// Returns null sides when the entry is not a file (dir / empty).
    /// Error set is open because blob loads flow through the storer.
    pub fn files(self: *const Change) anyerror!struct { from: ?File, to: ?File } {
        const act = try self.action();
        var from_f: ?File = null;
        var to_f: ?File = null;

        if (act == .insert or act == .modify) {
            if (self.to.tree) |tr| {
                if (!filemode.isFile(self.to.tree_entry.mode)) {
                    return .{ .from = null, .to = null };
                }
                to_f = try loadFile(tr, &self.to);
            }
        }
        if (act == .delete or act == .modify) {
            if (self.from.tree) |tr| {
                if (!filemode.isFile(self.from.tree_entry.mode)) {
                    return .{ .from = null, .to = null };
                }
                from_f = try loadFile(tr, &self.from);
            }
        }
        return .{ .from = from_f, .to = to_f };
    }

    /// Free owned path strings. Handles shared from/to name pointer (modify).
    ///
    /// Invariant: empty name is never heap-owned (`""` only); `tree_entry.name`
    /// is a subslice of the full path when adapted from merkletrie (do not free
    /// it separately).
    pub fn freeNames(self: *Change, allocator: Allocator) void {
        const from_name = self.from.name;
        const to_name = self.to.name;
        self.from.name = "";
        self.to.name = "";
        self.from.tree_entry.name = "";
        self.to.tree_entry.name = "";

        if (from_name.len > 0) {
            if (to_name.len > 0 and to_name.ptr == from_name.ptr) {
                allocator.free(from_name);
            } else {
                allocator.free(from_name);
                if (to_name.len > 0) allocator.free(to_name);
            }
        } else if (to_name.len > 0) {
            allocator.free(to_name);
        }
    }

    /// Destroy a heap `Change` including owned names.
    pub fn destroy(self: *Change, allocator: Allocator) void {
        self.freeNames(allocator);
        allocator.destroy(self);
    }
};

fn loadFile(tr: *Tree, entry: *const ChangeEntry) anyerror!File {
    var f = try tr.treeEntryFile(&entry.tree_entry);
    f.name = entry.name;
    return f;
}

/// go-git `Changes` — heap `*Change` list owned by the caller.
pub const Changes = struct {
    items: []*Change = &.{},
    allocator: Allocator,

    pub fn deinit(self: *Changes) void {
        for (self.items) |c| c.destroy(self.allocator);
        if (self.items.len > 0) self.allocator.free(self.items);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn sort(self: *Changes) void {
        std.mem.sort(*Change, self.items, {}, struct {
            fn less(_: void, a: *Change, b: *Change) bool {
                return std.mem.order(u8, a.name(), b.name()) == .lt;
            }
        }.less);
    }

    /// go-git `Changes.String`. Caller frees with `allocator`.
    pub fn string(self: *const Changes, allocator: Allocator) Allocator.Error![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        try list.append(allocator, '[');
        for (self.items, 0..) |c, i| {
            if (i > 0) try list.appendSlice(allocator, ", ");
            const part = try c.string(allocator);
            defer allocator.free(part);
            try list.appendSlice(allocator, part);
        }
        try list.append(allocator, ']');
        return try list.toOwnedSlice(allocator);
    }
};

test "Change action insert delete modify" {
    var c: Change = .{};
    try std.testing.expectError(error.MalformedChange, c.action());
    c.to = .{ .name = "a" };
    try std.testing.expect((try c.action()) == .insert);
    c.from = .{ .name = "a" };
    c.to = .{};
    try std.testing.expect((try c.action()) == .delete);
    c.to = .{ .name = "b" };
    try std.testing.expect((try c.action()) == .modify);
}

test "Change freeNames shared modify pointer" {
    const gpa = std.testing.allocator;
    const shared = try gpa.dupe(u8, "path");
    var c: Change = .{
        .from = .{ .name = shared },
        .to = .{ .name = shared },
    };
    c.freeNames(gpa);
    try std.testing.expectEqual(@as(usize, 0), c.from.name.len);
    try std.testing.expectEqual(@as(usize, 0), c.to.name.len);
}

// go-git ChangeSuite.TestEmptyChangeFails
test "Change empty fails action files string" {
    const gpa = std.testing.allocator;
    var c: Change = .{};
    try std.testing.expectError(error.MalformedChange, c.action());
    try std.testing.expectError(error.MalformedChange, c.files());
    const s = try c.string(gpa);
    defer gpa.free(s);
    try std.testing.expectEqualStrings("malformed change", s);
}

// go-git ChangeSuite.TestInsert / Delete / Modify string form (memory trees)
test "Change string insert delete modify" {
    const gpa = std.testing.allocator;

    var ins: Change = .{ .to = .{ .name = "examples/clone/main.go" } };
    const si = try ins.string(gpa);
    defer gpa.free(si);
    try std.testing.expectEqualStrings("<Action: Insert, Path: examples/clone/main.go>", si);

    var del: Change = .{ .from = .{ .name = "utils/difftree/difftree.go" } };
    const sd = try del.string(gpa);
    defer gpa.free(sd);
    try std.testing.expectEqualStrings("<Action: Delete, Path: utils/difftree/difftree.go>", sd);

    var mod: Change = .{
        .from = .{ .name = "utils/difftree/difftree.go" },
        .to = .{ .name = "utils/difftree/difftree.go" },
    };
    const sm = try mod.string(gpa);
    defer gpa.free(sm);
    try std.testing.expectEqualStrings("<Action: Modify, Path: utils/difftree/difftree.go>", sm);
}

// go-git ChangeSuite.TestChangesString
test "Changes string empty and multi" {
    const gpa = std.testing.allocator;

    var empty: Changes = .{ .allocator = gpa };
    const se = try empty.string(gpa);
    defer gpa.free(se);
    try std.testing.expectEqualStrings("[]", se);

    var c0: Change = .{
        .from = .{ .name = "bla" },
        .to = .{ .name = "bla" },
    };
    var one_items = [_]*Change{&c0};
    var one: Changes = .{
        .items = one_items[0..],
        .allocator = gpa,
    };
    const s1 = try one.string(gpa);
    defer gpa.free(s1);
    try std.testing.expectEqualStrings("[<Action: Modify, Path: bla>]", s1);

    var c1: Change = .{
        .from = .{ .name = "bla" },
        .to = .{ .name = "bla" },
    };
    var c2: Change = .{ .from = .{ .name = "foo/bar" } };
    var two_items = [_]*Change{ &c1, &c2 };
    var two: Changes = .{
        .items = two_items[0..],
        .allocator = gpa,
    };
    const s2 = try two.string(gpa);
    defer gpa.free(s2);
    try std.testing.expectEqualStrings(
        "[<Action: Modify, Path: bla>, <Action: Delete, Path: foo/bar>]",
        s2,
    );
}

// go-git ChangeSuite.TestChangesSort
test "Changes sort lexicographic by path" {
    const gpa = std.testing.allocator;

    var cz: Change = .{
        .from = .{ .name = "z" },
        .to = .{ .name = "z" },
    };
    var cbb: Change = .{ .from = .{ .name = "b/b" } };
    var cba: Change = .{ .to = .{ .name = "b/a" } };
    var items = [_]*Change{ &cz, &cbb, &cba };
    var changes: Changes = .{ .items = items[0..], .allocator = gpa };
    changes.sort();

    const s = try changes.string(gpa);
    defer gpa.free(s);
    try std.testing.expectEqualStrings(
        "[<Action: Insert, Path: b/a>, <Action: Delete, Path: b/b>, <Action: Modify, Path: z>]",
        s,
    );
}

// go-git ChangeSuite Files insert/delete/modify with memory storage
test "Change files insert delete modify and missing blob" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");
    const Storage = memory.Storage;
    const storer = @import("storer");

    var store = Storage.init(gpa);
    defer store.deinit();

    const blob = try store.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write("hello\n");
    const bh = try store.setEncodedObject(blob);

    var tree = tree_mod.Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tree.deinit();

    // Insert
    var ins: Change = .{
        .to = .{
            .name = "hello.txt",
            .tree = &tree,
            .tree_entry = .{
                .name = "hello.txt",
                .mode = filemode.Regular,
                .hash = bh,
            },
        },
    };
    try std.testing.expect((try ins.action()) == .insert);
    {
        const sides = try ins.files();
        try std.testing.expect(sides.from == null);
        try std.testing.expect(sides.to != null);
        try std.testing.expectEqualStrings("hello.txt", sides.to.?.name);
        try std.testing.expect(sides.to.?.blob.hash.eql(bh));
    }

    // Delete
    var del: Change = .{
        .from = .{
            .name = "hello.txt",
            .tree = &tree,
            .tree_entry = .{
                .name = "hello.txt",
                .mode = filemode.Regular,
                .hash = bh,
            },
        },
    };
    try std.testing.expect((try del.action()) == .delete);
    {
        const sides = try del.files();
        try std.testing.expect(sides.to == null);
        try std.testing.expect(sides.from != null);
        try std.testing.expectEqualStrings("hello.txt", sides.from.?.name);
    }

    // Modify (same blob both sides is fine for Files API)
    var mod: Change = .{
        .from = .{
            .name = "hello.txt",
            .tree = &tree,
            .tree_entry = .{
                .name = "hello.txt",
                .mode = filemode.Regular,
                .hash = bh,
            },
        },
        .to = .{
            .name = "hello.txt",
            .tree = &tree,
            .tree_entry = .{
                .name = "hello.txt",
                .mode = filemode.Regular,
                .hash = bh,
            },
        },
    };
    try std.testing.expect((try mod.action()) == .modify);
    {
        const sides = try mod.files();
        try std.testing.expect(sides.from != null);
        try std.testing.expect(sides.to != null);
    }

    // Missing blob → object not found (go-git TestErrorsFindingChildsAreDetected)
    var missing: Change = .{
        .to = .{
            .name = "nope.txt",
            .tree = &tree,
            .tree_entry = .{
                .name = "nope.txt",
                .mode = filemode.Regular,
                .hash = plumbing.ZeroHash,
            },
        },
    };
    // Zero hash may or may not be stored; use a random non-present hash.
    missing.to.tree_entry.hash = plumbing.computeHash(.blob, "definitely-missing");
    try std.testing.expectError(error.ObjectNotFound, missing.files());
}

test "Change files non-file mode returns null sides" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");
    const Storage = memory.Storage;
    const storer = @import("storer");

    var store = Storage.init(gpa);
    defer store.deinit();
    var tree = tree_mod.Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tree.deinit();

    var c: Change = .{
        .to = .{
            .name = "sub",
            .tree = &tree,
            .tree_entry = .{
                .name = "sub",
                .mode = filemode.Dir,
                .hash = plumbing.ZeroHash,
            },
        },
    };
    const sides = try c.files();
    try std.testing.expect(sides.from == null);
    try std.testing.expect(sides.to == null);
}
