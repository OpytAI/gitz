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
    pub fn freeNames(self: *Change, allocator: Allocator) void {
        const from_name = self.from.name;
        const to_name = self.to.name;
        self.from.name = "";
        self.to.name = "";

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
