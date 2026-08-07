//! Diff two trees (go-git `DiffTree` / `DiffTreeWithOptions`).
//!
//! Recursive two-pointer walk of sorted tree entries (same observable results
//! as go-git's merkletrie DiffTree for content-addressed git trees). Rename
//! detection is optional via `rename.zig`.

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const tree_mod = @import("tree.zig");
const change_mod = @import("change.zig");
const rename_mod = @import("rename.zig");
const error_mod = @import("error.zig");

const Allocator = std.mem.Allocator;
const Tree = tree_mod.Tree;
const TreeEntry = tree_mod.TreeEntry;
const Change = change_mod.Change;
const Changes = change_mod.Changes;
const Error = error_mod.Error;

pub const DiffTreeOptions = change_mod.DiffTreeOptions;

/// DiffTree error set. Open because nested tree loads flow through the storer,
/// and content-based rename detection reads blob bodies.
pub const DiffError = anyerror;

/// go-git `DiffTree` — no rename detection.
pub fn diffTree(allocator: Allocator, a: ?*Tree, b: ?*Tree) DiffError!Changes {
    return diffTreeWithOptions(allocator, a, b, .{});
}

/// go-git `DiffTreeWithOptions`.
pub fn diffTreeWithOptions(
    allocator: Allocator,
    a: ?*Tree,
    b: ?*Tree,
    opts: DiffTreeOptions,
) DiffError!Changes {
    var list: std.ArrayList(*Change) = .empty;
    errdefer {
        for (list.items) |c| c.destroy(allocator);
        list.deinit(allocator);
    }

    try diffRecursive(allocator, a, b, "", &list);

    var changes: Changes = .{
        .items = try list.toOwnedSlice(allocator),
        .allocator = allocator,
    };

    if (opts.detect_renames) {
        // detectRenames takes ownership of `changes` (including on error).
        changes = try rename_mod.detectRenames(allocator, changes, opts);
    } else {
        changes.sort();
    }
    return changes;
}

fn diffRecursive(
    allocator: Allocator,
    a: ?*Tree,
    b: ?*Tree,
    path_prefix: []const u8,
    out: *std.ArrayList(*Change),
) DiffError!void {
    const a_ents: []const TreeEntry = if (a) |ta| ta.entries.items else &.{};
    const b_ents: []const TreeEntry = if (b) |tb| tb.entries.items else &.{};

    var i: usize = 0;
    var j: usize = 0;
    while (i < a_ents.len or j < b_ents.len) {
        if (i < a_ents.len and (j >= b_ents.len or nameLess(a_ents[i].name, b_ents[j].name))) {
            try handleOnlyLeft(allocator, a.?, a_ents[i], path_prefix, out);
            i += 1;
        } else if (j < b_ents.len and (i >= a_ents.len or nameLess(b_ents[j].name, a_ents[i].name))) {
            try handleOnlyRight(allocator, b.?, b_ents[j], path_prefix, out);
            j += 1;
        } else {
            try handleBoth(allocator, a.?, a_ents[i], b.?, b_ents[j], path_prefix, out);
            i += 1;
            j += 1;
        }
    }
}

fn nameLess(a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn handleBoth(
    allocator: Allocator,
    tree_a: *Tree,
    ea: TreeEntry,
    tree_b: *Tree,
    eb: TreeEntry,
    path_prefix: []const u8,
    out: *std.ArrayList(*Change),
) DiffError!void {
    const full = try joinPath(allocator, path_prefix, ea.name);
    defer allocator.free(full);

    const a_dir = ea.mode == filemode.Dir;
    const b_dir = eb.mode == filemode.Dir;

    if (a_dir and b_dir) {
        // Equal content-addressed dirs need no walk.
        if (ea.hash.eql(eb.hash) and ea.mode == eb.mode) return;
        const sub_a = try openSub(tree_a, ea);
        defer freeSub(allocator, sub_a);
        const sub_b = try openSub(tree_b, eb);
        defer freeSub(allocator, sub_b);
        try diffRecursive(allocator, sub_a, sub_b, full, out);
        return;
    }

    if (ea.hash.eql(eb.hash) and ea.mode == eb.mode) return;

    if (!a_dir and !b_dir) {
        try pushModify(allocator, out, tree_a, ea, tree_b, eb, full);
    } else {
        // Type change: delete old side, insert new side.
        try pushDelete(allocator, out, tree_a, ea, full);
        try pushInsert(allocator, out, tree_b, eb, full);
    }
}

fn handleOnlyLeft(
    allocator: Allocator,
    tree_a: *Tree,
    ea: TreeEntry,
    path_prefix: []const u8,
    out: *std.ArrayList(*Change),
) DiffError!void {
    const full = try joinPath(allocator, path_prefix, ea.name);
    defer allocator.free(full);
    if (ea.mode == filemode.Dir) {
        const sub = try openSub(tree_a, ea);
        defer freeSub(allocator, sub);
        try diffRecursive(allocator, sub, null, full, out);
    } else {
        try pushDelete(allocator, out, tree_a, ea, full);
    }
}

fn handleOnlyRight(
    allocator: Allocator,
    tree_b: *Tree,
    eb: TreeEntry,
    path_prefix: []const u8,
    out: *std.ArrayList(*Change),
) DiffError!void {
    const full = try joinPath(allocator, path_prefix, eb.name);
    defer allocator.free(full);
    if (eb.mode == filemode.Dir) {
        const sub = try openSub(tree_b, eb);
        defer freeSub(allocator, sub);
        try diffRecursive(allocator, null, sub, full, out);
    } else {
        try pushInsert(allocator, out, tree_b, eb, full);
    }
}

fn joinPath(allocator: Allocator, prefix: []const u8, name: []const u8) Allocator.Error![]u8 {
    if (prefix.len == 0) return try allocator.dupe(u8, name);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
}

fn openSub(parent: *Tree, e: TreeEntry) DiffError!*Tree {
    const s = parent.storer orelse return error.ObjectNotFound;
    return tree_mod.getTree(parent.allocator, s, e.hash) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ObjectNotFound => return error.ObjectNotFound,
        error.UnsupportedObject => return error.UnsupportedObject,
        else => return error.MalformedTree,
    };
}

fn freeSub(allocator: Allocator, t: *Tree) void {
    tree_mod.freeTree(allocator, t);
}

fn pushInsert(
    allocator: Allocator,
    out: *std.ArrayList(*Change),
    tree: *Tree,
    e: TreeEntry,
    full: []const u8,
) Allocator.Error!void {
    const c = try allocator.create(Change);
    errdefer allocator.destroy(c);
    const name_owned = try allocator.dupe(u8, full);
    errdefer allocator.free(name_owned);
    c.* = .{
        .from = .{},
        .to = .{
            .name = name_owned,
            .tree = tree,
            .tree_entry = e,
        },
    };
    try out.append(allocator, c);
}

fn pushDelete(
    allocator: Allocator,
    out: *std.ArrayList(*Change),
    tree: *Tree,
    e: TreeEntry,
    full: []const u8,
) Allocator.Error!void {
    const c = try allocator.create(Change);
    errdefer allocator.destroy(c);
    const name_owned = try allocator.dupe(u8, full);
    errdefer allocator.free(name_owned);
    c.* = .{
        .from = .{
            .name = name_owned,
            .tree = tree,
            .tree_entry = e,
        },
        .to = .{},
    };
    try out.append(allocator, c);
}

fn pushModify(
    allocator: Allocator,
    out: *std.ArrayList(*Change),
    tree_a: *Tree,
    ea: TreeEntry,
    tree_b: *Tree,
    eb: TreeEntry,
    full: []const u8,
) Allocator.Error!void {
    const c = try allocator.create(Change);
    errdefer allocator.destroy(c);
    const name_owned = try allocator.dupe(u8, full);
    errdefer allocator.free(name_owned);
    // Single path allocation shared by both sides.
    c.* = .{
        .from = .{
            .name = name_owned,
            .tree = tree_a,
            .tree_entry = ea,
        },
        .to = .{
            .name = name_owned,
            .tree = tree_b,
            .tree_entry = eb,
        },
    };
    try out.append(allocator, c);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "diffTree empty trees" {
    const gpa = std.testing.allocator;
    var changes = try diffTree(gpa, null, null);
    defer changes.deinit();
    try std.testing.expectEqual(@as(usize, 0), changes.items.len);
}

test "diffTree insert file" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");
    const Storage = memory.Storage;
    const storer = @import("storer");

    var store = Storage.init(gpa);
    defer store.deinit();

    const blob = try store.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write("hello");
    const bh = try store.setEncodedObject(blob);

    var tb = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tb.deinit();
    try tb.appendEntry("hello.txt", filemode.Regular, bh);
    tb.sortEntries();

    var changes = try diffTree(gpa, null, &tb);
    defer changes.deinit();
    try std.testing.expectEqual(@as(usize, 1), changes.items.len);
    try std.testing.expect((try changes.items[0].action()) == .insert);
    try std.testing.expectEqualStrings("hello.txt", changes.items[0].name());
}

test "diffTree modify content" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");
    const Storage = memory.Storage;
    const storer = @import("storer");

    var store = Storage.init(gpa);
    defer store.deinit();

    const b1 = try store.newEncodedObject();
    b1.setType(.blob);
    _ = try b1.write("a");
    const h1 = try store.setEncodedObject(b1);
    const b2 = try store.newEncodedObject();
    b2.setType(.blob);
    _ = try b2.write("b");
    const h2 = try store.setEncodedObject(b2);

    var ta = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer ta.deinit();
    try ta.appendEntry("f", filemode.Regular, h1);
    ta.sortEntries();

    var tb = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tb.deinit();
    try tb.appendEntry("f", filemode.Regular, h2);
    tb.sortEntries();

    var changes = try diffTree(gpa, &ta, &tb);
    defer changes.deinit();
    try std.testing.expectEqual(@as(usize, 1), changes.items.len);
    try std.testing.expect((try changes.items[0].action()) == .modify);
}

test "diffTree nested insert" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");
    const Storage = memory.Storage;
    const storer = @import("storer");

    var store = Storage.init(gpa);
    defer store.deinit();

    const blob = try store.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write("x");
    const bh = try store.setEncodedObject(blob);

    var sub = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer sub.deinit();
    try sub.appendEntry("inner.txt", filemode.Regular, bh);
    sub.sortEntries();
    const sub_obj = try store.newEncodedObject();
    try sub.encode(sub_obj);
    const sub_h = try store.setEncodedObject(sub_obj);

    var root = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer root.deinit();
    try root.appendEntry("dir", filemode.Dir, sub_h);
    root.sortEntries();

    var changes = try diffTree(gpa, null, &root);
    defer changes.deinit();
    try std.testing.expectEqual(@as(usize, 1), changes.items.len);
    try std.testing.expectEqualStrings("dir/inner.txt", changes.items[0].name());
    try std.testing.expect((try changes.items[0].action()) == .insert);
}
