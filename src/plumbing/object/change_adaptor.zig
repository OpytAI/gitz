//! Adapt merkletrie changes to object.Changes (go-git `change_adaptor.go`).
//!
//! Path last-noder must be a TreeNoder. Full path strings are owned by the
//! resulting Change; tree_entry.name is a subslice of that path (basename).

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const noder = @import("noder");
const merkletrie = @import("merkletrie");
const change_mod = @import("change.zig");
const tree_noder_mod = @import("tree_noder.zig");
const tree_mod = @import("tree.zig");

const Allocator = std.mem.Allocator;
const Path = noder.Path;
const Noder = noder.Noder;
const Change = change_mod.Change;
const ChangeEntry = change_mod.ChangeEntry;
const Changes = change_mod.Changes;
const TreeNoder = tree_noder_mod.TreeNoder;
const TreeEntry = tree_mod.TreeEntry;

pub const Error = error{
    /// Path last element is not a TreeNoder (go-git adaptor error).
    CannotTransformNonTreeNoders,
};

/// go-git `newChange` — heap-allocate an object.Change from a merkletrie.Change.
pub fn newChange(allocator: Allocator, c: merkletrie.Change) (Error || Allocator.Error)!*Change {
    const ret = try allocator.create(Change);
    errdefer allocator.destroy(ret);
    ret.* = .{};

    ret.from = try newChangeEntry(allocator, c.from);
    errdefer freeEntryName(allocator, &ret.from);

    ret.to = try newChangeEntry(allocator, c.to);
    errdefer freeEntryName(allocator, &ret.to);

    return ret;
}

/// go-git `newChangeEntry`.
///
/// `path == null` or empty path → empty ChangeEntry.
/// `tree_entry.name` is a subslice of the owned full path (basename).
pub fn newChangeEntry(allocator: Allocator, path: ?Path) (Error || Allocator.Error)!ChangeEntry {
    const p = path orelse return .{};
    if (p.nodes.len == 0) return .{};

    const tn = try treeNoderFrom(p.last());
    const full = try p.string(allocator);
    errdefer allocator.free(full);

    // Basename as subslice of full path (same pattern as rename fixtures).
    const base = pathBaseName(full);
    // Prefer TreeNoder basename when it matches the last path component.
    const te_name = if (std.mem.eql(u8, base, tn.name_s)) base else pathBaseName(full);

    return .{
        .name = full,
        .tree = tn.parent,
        .tree_entry = TreeEntry{
            .name = te_name,
            .mode = tn.mode,
            .hash = tn.oid,
        },
    };
}

/// go-git `newChanges`.
///
/// Converts `src` into object.Changes, then deinit's the merkletrie list
/// (frees Path node slices). TreeNoder bodies must still be alive (session
/// arena) until this returns.
pub fn newChanges(allocator: Allocator, src: *merkletrie.Changes) (Error || Allocator.Error)!Changes {
    var list: std.ArrayList(*Change) = .empty;
    errdefer {
        for (list.items) |c| c.destroy(allocator);
        list.deinit(allocator);
    }

    try list.ensureTotalCapacity(allocator, src.items.items.len);
    for (src.items.items) |ch| {
        const c = try newChange(allocator, ch);
        try list.append(allocator, c);
    }

    // Free Path node slices; TreeNoders live in the DiffTree session arena.
    src.deinit();

    return .{
        .items = try list.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn freeEntryName(allocator: Allocator, e: *ChangeEntry) void {
    if (e.name.len > 0) {
        allocator.free(e.name);
        e.name = "";
        e.tree_entry.name = "";
    }
}

fn pathBaseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

/// Extract `*TreeNoder` from a type-erased Noder (vtable identity check).
pub fn treeNoderFrom(n: Noder) Error!*TreeNoder {
    // noderOf(TreeNoder, _) monomorphizes one static vtable for TreeNoder.
    var probe: TreeNoder = .{
        .parent = null,
        .root = null,
        .name_s = "",
        .mode = filemode.Empty,
        .oid = plumbing.ZeroHash,
        .full_path = "",
        .session = undefined,
    };
    const expected = noder.noderOf(TreeNoder, &probe).vtable;
    if (n.vtable != expected) return Error.CannotTransformNonTreeNoders;
    return @ptrCast(@alignCast(n.ptr));
}

// ---------------------------------------------------------------------------
// Tests (go-git change_adaptor_test.go — insert/delete/modify shape)
// ---------------------------------------------------------------------------

fn makePath(session: *tree_noder_mod.TreeNoderSession, parent: ?*tree_mod.Tree, entry_name: []const u8, mode: filemode.FileMode, oid: plumbing.Hash) !Path {
    const aa = session.allocator();
    const tn = try aa.create(TreeNoder);
    tn.* = .{
        .parent = parent,
        .root = parent,
        .name_s = entry_name,
        .mode = mode,
        .oid = oid,
        .full_path = entry_name,
        .session = session,
    };
    const nodes = try aa.alloc(Noder, 1);
    nodes[0] = tn.asNoder();
    // View: nodes live in arena; Path.deinit must not free them via gpa.
    return Path.view(nodes);
}

test "newChangeEntry nil path is empty" {
    const gpa = std.testing.allocator;
    const e = try newChangeEntry(gpa, null);
    try std.testing.expect(e.isEmpty());
}

test "newChange insert delete modify shape" {
    const gpa = std.testing.allocator;
    var session = tree_noder_mod.TreeNoderSession.init(gpa);
    defer session.deinit();

    var tree_a: tree_mod.Tree = tree_mod.Tree.init(gpa, null);
    defer tree_a.deinit();
    var tree_b: tree_mod.Tree = tree_mod.Tree.init(gpa, null);
    defer tree_b.deinit();

    var oid_a = plumbing.ZeroHash;
    oid_a.bytes[0] = 0xaa;
    var oid_b = plumbing.ZeroHash;
    oid_b.bytes[0] = 0xbb;

    // Insert
    {
        const path = try makePath(&session, &tree_a, "name", filemode.Regular, oid_a);
        const mt: merkletrie.Change = .{ .from = null, .to = path };
        const c = try newChange(gpa, mt);
        defer c.destroy(gpa);
        try std.testing.expect((try c.action()) == .insert);
        try std.testing.expect(c.from.isEmpty());
        try std.testing.expectEqualStrings("name", c.to.name);
        try std.testing.expect(c.to.tree == &tree_a);
        try std.testing.expectEqualStrings("name", c.to.tree_entry.name);
        try std.testing.expect(c.to.tree_entry.hash.eql(oid_a));
        try std.testing.expect(c.to.tree_entry.mode == filemode.Regular);
    }

    // Delete
    {
        const path = try makePath(&session, &tree_a, "gone", filemode.Executable, oid_a);
        const mt: merkletrie.Change = .{ .from = path, .to = null };
        const c = try newChange(gpa, mt);
        defer c.destroy(gpa);
        try std.testing.expect((try c.action()) == .delete);
        try std.testing.expect(c.to.isEmpty());
        try std.testing.expectEqualStrings("gone", c.from.name);
        try std.testing.expect(c.from.tree == &tree_a);
    }

    // Modify
    {
        const path_from = try makePath(&session, &tree_a, "name", filemode.Regular, oid_a);
        const path_to = try makePath(&session, &tree_b, "name", filemode.Regular, oid_b);
        const mt: merkletrie.Change = .{ .from = path_from, .to = path_to };
        const c = try newChange(gpa, mt);
        defer c.destroy(gpa);
        try std.testing.expect((try c.action()) == .modify);
        try std.testing.expectEqualStrings("name", c.from.name);
        try std.testing.expectEqualStrings("name", c.to.name);
        try std.testing.expect(c.from.tree == &tree_a);
        try std.testing.expect(c.to.tree == &tree_b);
        try std.testing.expect(c.from.tree_entry.hash.eql(oid_a));
        try std.testing.expect(c.to.tree_entry.hash.eql(oid_b));
    }
}

test "newChangeEntry long path joins with slash" {
    const gpa = std.testing.allocator;
    var session = tree_noder_mod.TreeNoderSession.init(gpa);
    defer session.deinit();

    var tree_a: tree_mod.Tree = tree_mod.Tree.init(gpa, null);
    defer tree_a.deinit();
    var tree_b: tree_mod.Tree = tree_mod.Tree.init(gpa, null);
    defer tree_b.deinit();

    const aa = session.allocator();
    const n0 = try aa.create(TreeNoder);
    n0.* = .{
        .parent = &tree_a,
        .root = &tree_a,
        .name_s = "nameA",
        .mode = filemode.Dir,
        .oid = plumbing.ZeroHash,
        .full_path = "nameA",
        .session = &session,
    };
    const n1 = try aa.create(TreeNoder);
    n1.* = .{
        .parent = &tree_b,
        .root = &tree_a,
        .name_s = "nameB",
        .mode = filemode.Regular,
        .oid = plumbing.ZeroHash,
        .full_path = "nameA/nameB",
        .session = &session,
    };
    const nodes = try aa.alloc(Noder, 2);
    nodes[0] = n0.asNoder();
    nodes[1] = n1.asNoder();
    const path = Path.view(nodes);

    const e = try newChangeEntry(gpa, path);
    defer gpa.free(e.name);

    try std.testing.expectEqualStrings("nameA/nameB", e.name);
    try std.testing.expect(e.tree == &tree_b);
    try std.testing.expectEqualStrings("nameB", e.tree_entry.name);
}

test "newChange rejects non-TreeNoder" {
    const gpa = std.testing.allocator;
    const Mock = struct {
        pub fn hash(_: *@This()) []const u8 {
            return &.{};
        }
        pub fn name(_: *@This()) []const u8 {
            return "x";
        }
        pub fn isDir(_: *@This()) bool {
            return false;
        }
        pub fn children(_: *@This(), _: Allocator) anyerror![]Noder {
            return noder.no_children;
        }
        pub fn numChildren(_: *@This()) anyerror!usize {
            return 0;
        }
        pub fn skip(_: *@This()) bool {
            return false;
        }
        pub fn string(_: *@This(), a: Allocator) anyerror![]u8 {
            return try a.dupe(u8, "x");
        }
    };
    var m = Mock{};
    var nodes = [_]Noder{noder.noderOf(Mock, &m)};
    const path = Path.view(&nodes);
    try std.testing.expectError(Error.CannotTransformNonTreeNoders, newChangeEntry(gpa, path));
}

test "newChanges empty" {
    const gpa = std.testing.allocator;
    var src = merkletrie.Changes.init(gpa);
    var changes = try newChanges(gpa, &src);
    defer changes.deinit();
    try std.testing.expectEqual(@as(usize, 0), changes.items.len);
}
