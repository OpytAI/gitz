//! Diff two trees (go-git `DiffTree` / `DiffTreeWithOptions`).
//!
//! Path: NewTreeRootNode → merkletrie.DiffTreeContext → newChanges → optional DetectRenames.

const std = @import("std");
const plumbing = @import("plumbing");
const noder = @import("noder");
const merkletrie = @import("merkletrie");
const tree_mod = @import("tree.zig");
const change_mod = @import("change.zig");
const rename_mod = @import("rename.zig");
const tree_noder_mod = @import("tree_noder.zig");
const change_adaptor_mod = @import("change_adaptor.zig");
const error_mod = @import("error.zig");

const Allocator = std.mem.Allocator;
const Tree = tree_mod.Tree;
const Change = change_mod.Change;
const Changes = change_mod.Changes;
const Error = error_mod.Error;

pub const DiffTreeOptions = change_mod.DiffTreeOptions;
pub const DiffTreeContext = merkletrie.Context;

/// Closed DiffTree error set (no bare `anyerror` at the public boundary).
/// Noder/storer backends may surface other errors; those are mapped to
/// `Error.DiffBackend` so callers can switch exhaustively.
pub const DiffError = Error || Allocator.Error || plumbing.Error || change_adaptor_mod.Error || rename_mod.RenameError;

/// go-git `DiffTree` — no rename detection.
pub fn diffTree(allocator: Allocator, a: ?*Tree, b: ?*Tree) DiffError!Changes {
    return diffTreeWithOptions(allocator, a, b, .{});
}

/// go-git `DiffTreeContext`: the public cancellation-aware tree diff shape.
pub fn diffTreeContext(
    allocator: Allocator,
    ctx: DiffTreeContext,
    a: ?*Tree,
    b: ?*Tree,
) DiffError!Changes {
    return diffTreeContextWithOptions(allocator, ctx, a, b, .{});
}

/// go-git `DiffTreeWithOptions`.
pub fn diffTreeWithOptions(
    allocator: Allocator,
    a: ?*Tree,
    b: ?*Tree,
    opts: DiffTreeOptions,
) DiffError!Changes {
    return diffTreeContextWithOptions(allocator, .{}, a, b, opts);
}

pub fn diffTreeContextWithOptions(
    allocator: Allocator,
    ctx: DiffTreeContext,
    a: ?*Tree,
    b: ?*Tree,
    opts: DiffTreeOptions,
) DiffError!Changes {
    var session = tree_noder_mod.TreeNoderSession.init(allocator);
    defer session.deinit();

    const from = try tree_noder_mod.newTreeRootNode(&session, a);
    const to = try tree_noder_mod.newTreeRootNode(&session, b);

    var mt_changes = merkletrie.diffTreeContext(
        allocator,
        ctx,
        from.asNoder(),
        to.asNoder(),
        hashEqual,
    ) catch |err| return mapDiffBackend(err);

    // Adapt while TreeNoders still live in the session arena. newChanges
    // deinit's mt_changes (Path node slices only). Loaded subtrees stay in
    // each root Tree.path_cache (caller-owned); session deinit frees only the
    // arena of TreeNoder shells. ChangeEntry.tree therefore remains valid for
    // the lifetime of the DiffTree input roots (same idea as go-git Tree.t).
    var changes = try change_adaptor_mod.newChanges(allocator, &mt_changes);

    if (opts.detect_renames) {
        // detectRenames takes ownership of `changes` (including on error).
        changes = try rename_mod.detectRenames(allocator, changes, opts);
    } else {
        changes.sort();
    }
    return changes;
}

/// Map noder/merkletrie open errors into the closed `DiffError` set.
fn mapDiffBackend(err: anyerror) DiffError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        error.ObjectNotFound => error.ObjectNotFound,
        error.UnsupportedObject => error.UnsupportedObject,
        error.MalformedTree => error.MalformedTree,
        error.FileNotFound => error.FileNotFound,
        error.DirectoryNotFound => error.DirectoryNotFound,
        error.EntryNotFound => error.EntryNotFound,
        error.CannotTransformNonTreeNoders => error.CannotTransformNonTreeNoders,
        error.IndexFull => error.IndexFull,
        error.EmptyFileName => error.DiffBackend,
        error.BadDoubleIterStatus => error.DiffBackend,
        error.BothDirsEmptyDifferentHash => error.DiffBackend,
        else => error.DiffBackend,
    };
}

fn hashEqual(a: noder.Noder, b: noder.Noder) bool {
    return std.mem.eql(u8, a.hash(), b.hash());
}

// ---------------------------------------------------------------------------
// Tests (representative DiffTree cases; memory trees, no go-git fixtures)
// ---------------------------------------------------------------------------

const memory = @import("memory");
const Storage = memory.Storage;
const storer = @import("storer");
const filemode = @import("filemode");

fn putBlob(store: *Storage, content: []const u8) !plumbing.Hash {
    const blob = try store.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write(content);
    return try store.setEncodedObject(blob);
}

fn putTree(store: *Storage, tree: *Tree) !plumbing.Hash {
    tree.sortEntries();
    const obj = try store.newEncodedObject();
    try tree.encode(obj);
    return try store.setEncodedObject(obj);
}

const Expect = struct {
    action: change_mod.Action,
    name: []const u8,
};

fn expectChanges(changes: *Changes, expected: []const Expect) !void {
    try std.testing.expectEqual(expected.len, changes.items.len);
    changes.sort();
    for (changes.items, expected) |c, e| {
        try std.testing.expectEqual(e.action, try c.action());
        try std.testing.expectEqualStrings(e.name, c.name());
        switch (e.action) {
            .insert => {
                try std.testing.expect(c.from.tree == null);
                try std.testing.expect(c.to.tree != null);
            },
            .delete => {
                try std.testing.expect(c.from.tree != null);
                try std.testing.expect(c.to.tree == null);
            },
            .modify => {
                try std.testing.expect(c.from.tree != null);
                try std.testing.expect(c.to.tree != null);
            },
        }
    }
}

test "diffTree empty trees" {
    const gpa = std.testing.allocator;
    var changes = try diffTree(gpa, null, null);
    defer changes.deinit();
    try std.testing.expectEqual(@as(usize, 0), changes.items.len);
}

test "diffTreeContext returns Canceled at the public boundary" {
    const gpa = std.testing.allocator;
    var cancelled = true;
    try std.testing.expectError(
        error.Canceled,
        diffTreeContext(gpa, .{ .cancelled = &cancelled }, null, null),
    );
}

// go-git: empty → tree (insert README-style single file)
test "diffTree insert file" {
    const gpa = std.testing.allocator;

    var store = Storage.init(gpa);
    defer store.deinit();
    const bh = try putBlob(&store, "hello");

    var tb = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tb.deinit();
    try tb.appendEntry("hello.txt", filemode.Regular, bh);
    tb.sortEntries();

    var changes = try diffTree(gpa, null, &tb);
    defer changes.deinit();
    try expectChanges(&changes, &[_]Expect{
        .{ .action = .insert, .name = "hello.txt" },
    });
}

// go-git: tree → empty (delete)
test "diffTree delete file" {
    const gpa = std.testing.allocator;

    var store = Storage.init(gpa);
    defer store.deinit();
    const bh = try putBlob(&store, "bye");

    var ta = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer ta.deinit();
    try ta.appendEntry("README", filemode.Regular, bh);
    ta.sortEntries();

    var changes = try diffTree(gpa, &ta, null);
    defer changes.deinit();
    try expectChanges(&changes, &[_]Expect{
        .{ .action = .delete, .name = "README" },
    });
}

// go-git: identical trees → no changes
test "diffTree identical trees empty" {
    const gpa = std.testing.allocator;

    var store = Storage.init(gpa);
    defer store.deinit();
    const bh = try putBlob(&store, "x");

    var ta = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer ta.deinit();
    try ta.appendEntry("f", filemode.Regular, bh);
    ta.sortEntries();

    var tb = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tb.deinit();
    try tb.appendEntry("f", filemode.Regular, bh);
    tb.sortEntries();

    var changes = try diffTree(gpa, &ta, &tb);
    defer changes.deinit();
    try std.testing.expectEqual(@as(usize, 0), changes.items.len);

    // Same tree pointer both sides
    var same = try diffTree(gpa, &ta, &ta);
    defer same.deinit();
    try std.testing.expectEqual(@as(usize, 0), same.items.len);
}

test "diffTree modify content" {
    const gpa = std.testing.allocator;

    var store = Storage.init(gpa);
    defer store.deinit();
    const h1 = try putBlob(&store, "a");
    const h2 = try putBlob(&store, "b");

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
    try expectChanges(&changes, &[_]Expect{
        .{ .action = .modify, .name = "f" },
    });
}

// go-git multi-file insert (gem-builder style flat tree)
test "diffTree multi file insert sorted" {
    const gpa = std.testing.allocator;

    var store = Storage.init(gpa);
    defer store.deinit();
    const h_r = try putBlob(&store, "r");
    const h_b = try putBlob(&store, "b");
    const h_e = try putBlob(&store, "e");

    var tb = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tb.deinit();
    try tb.appendEntry("README", filemode.Regular, h_r);
    try tb.appendEntry("gem_builder.rb", filemode.Regular, h_b);
    try tb.appendEntry("gem_eval.rb", filemode.Regular, h_e);
    tb.sortEntries();

    var changes = try diffTree(gpa, null, &tb);
    defer changes.deinit();
    try expectChanges(&changes, &[_]Expect{
        .{ .action = .insert, .name = "README" },
        .{ .action = .insert, .name = "gem_builder.rb" },
        .{ .action = .insert, .name = "gem_eval.rb" },
    });
}

test "diffTree multi file delete sorted" {
    const gpa = std.testing.allocator;

    var store = Storage.init(gpa);
    defer store.deinit();
    const h_r = try putBlob(&store, "r");
    const h_b = try putBlob(&store, "b");
    const h_e = try putBlob(&store, "e");

    var ta = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer ta.deinit();
    try ta.appendEntry("README", filemode.Regular, h_r);
    try ta.appendEntry("gem_builder.rb", filemode.Regular, h_b);
    try ta.appendEntry("gem_eval.rb", filemode.Regular, h_e);
    ta.sortEntries();

    var changes = try diffTree(gpa, &ta, null);
    defer changes.deinit();
    try expectChanges(&changes, &[_]Expect{
        .{ .action = .delete, .name = "README" },
        .{ .action = .delete, .name = "gem_builder.rb" },
        .{ .action = .delete, .name = "gem_eval.rb" },
    });
}

// go-git nested paths (ts3-style examples/)
test "diffTree nested insert" {
    const gpa = std.testing.allocator;

    var store = Storage.init(gpa);
    defer store.deinit();
    const bh = try putBlob(&store, "x");

    var sub = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer sub.deinit();
    try sub.appendEntry("inner.txt", filemode.Regular, bh);
    const sub_h = try putTree(&store, &sub);

    var root = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer root.deinit();
    try root.appendEntry("dir", filemode.Dir, sub_h);
    root.sortEntries();

    var changes = try diffTree(gpa, null, &root);
    defer changes.deinit();
    try expectChanges(&changes, &[_]Expect{
        .{ .action = .insert, .name = "dir/inner.txt" },
    });
}

test "diffTree nested delete" {
    const gpa = std.testing.allocator;

    var store = Storage.init(gpa);
    defer store.deinit();
    const bh = try putBlob(&store, "x");

    var sub = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer sub.deinit();
    try sub.appendEntry("bot.go", filemode.Regular, bh);
    const sub_h = try putTree(&store, &sub);

    var root = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer root.deinit();
    try root.appendEntry("examples", filemode.Dir, sub_h);
    try root.appendEntry("helpers.go", filemode.Regular, bh);
    root.sortEntries();

    var changes = try diffTree(gpa, &root, null);
    defer changes.deinit();
    try expectChanges(&changes, &[_]Expect{
        .{ .action = .delete, .name = "examples/bot.go" },
        .{ .action = .delete, .name = "helpers.go" },
    });
}

// go-git: modify one file + insert others (gem-builder commit chain style)
test "diffTree modify and insert mix" {
    const gpa = std.testing.allocator;

    var store = Storage.init(gpa);
    defer store.deinit();
    const h_old = try putBlob(&store, "old eval");
    const h_new = try putBlob(&store, "new eval");
    const h_test = try putBlob(&store, "test");
    const h_sec = try putBlob(&store, "sec");

    var ta = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer ta.deinit();
    try ta.appendEntry("gem_eval.rb", filemode.Regular, h_old);
    ta.sortEntries();

    var tb = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tb.deinit();
    try tb.appendEntry("gem_eval.rb", filemode.Regular, h_new);
    try tb.appendEntry("gem_eval_test.rb", filemode.Regular, h_test);
    try tb.appendEntry("security.rb", filemode.Regular, h_sec);
    tb.sortEntries();

    var changes = try diffTree(gpa, &ta, &tb);
    defer changes.deinit();
    try expectChanges(&changes, &[_]Expect{
        .{ .action = .modify, .name = "gem_eval.rb" },
        .{ .action = .insert, .name = "gem_eval_test.rb" },
        .{ .action = .insert, .name = "security.rb" },
    });
}

// File → directory type change: merkletrie recursively expands nested files
// (go-git DiffTree: delete file + insert nested paths, not only top entry).
test "diffTree type change file to dir" {
    const gpa = std.testing.allocator;

    var store = Storage.init(gpa);
    defer store.deinit();
    const file_h = try putBlob(&store, "was-file");
    const inner_h = try putBlob(&store, "now-dir");
    const nested_h = try putBlob(&store, "deep");

    var nested = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer nested.deinit();
    try nested.appendEntry("deep.txt", filemode.Regular, nested_h);
    const nested_tree_h = try putTree(&store, &nested);

    var sub = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer sub.deinit();
    try sub.appendEntry("child", filemode.Regular, inner_h);
    try sub.appendEntry("sub", filemode.Dir, nested_tree_h);
    const sub_h = try putTree(&store, &sub);

    var ta = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer ta.deinit();
    try ta.appendEntry("path", filemode.Regular, file_h);
    ta.sortEntries();

    var tb = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tb.deinit();
    try tb.appendEntry("path", filemode.Dir, sub_h);
    tb.sortEntries();

    var changes = try diffTree(gpa, &ta, &tb);
    defer changes.deinit();
    try expectChanges(&changes, &[_]Expect{
        .{ .action = .delete, .name = "path" },
        .{ .action = .insert, .name = "path/child" },
        .{ .action = .insert, .name = "path/sub/deep.txt" },
    });
    // Delete side was a regular file; inserts are nested file paths.
    for (changes.items) |c| {
        switch (try c.action()) {
            .delete => try std.testing.expect(c.from.tree_entry.mode == filemode.Regular),
            .insert => try std.testing.expect(filemode.isFile(c.to.tree_entry.mode)),
            .modify => try std.testing.expect(false),
        }
    }
}

// Mode-only change (same content hash, different mode) is a modify
test "diffTree mode change is modify" {
    const gpa = std.testing.allocator;

    var store = Storage.init(gpa);
    defer store.deinit();
    const bh = try putBlob(&store, "script");

    var ta = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer ta.deinit();
    try ta.appendEntry("run", filemode.Regular, bh);
    ta.sortEntries();

    var tb = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tb.deinit();
    try tb.appendEntry("run", filemode.Executable, bh);
    tb.sortEntries();

    var changes = try diffTree(gpa, &ta, &tb);
    defer changes.deinit();
    try expectChanges(&changes, &[_]Expect{
        .{ .action = .modify, .name = "run" },
    });
}

// Nested dir equal content-addressed → no walk / no changes
test "diffTree equal nested dirs skipped" {
    const gpa = std.testing.allocator;

    var store = Storage.init(gpa);
    defer store.deinit();
    const bh = try putBlob(&store, "same");

    var sub = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer sub.deinit();
    try sub.appendEntry("f", filemode.Regular, bh);
    const sub_h = try putTree(&store, &sub);

    var ta = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer ta.deinit();
    try ta.appendEntry("d", filemode.Dir, sub_h);
    ta.sortEntries();

    var tb = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tb.deinit();
    try tb.appendEntry("d", filemode.Dir, sub_h);
    tb.sortEntries();

    var changes = try diffTree(gpa, &ta, &tb);
    defer changes.deinit();
    try std.testing.expectEqual(@as(usize, 0), changes.items.len);
}

// Nested dir content change
test "diffTree nested content modify" {
    const gpa = std.testing.allocator;

    var store = Storage.init(gpa);
    defer store.deinit();
    const h1 = try putBlob(&store, "v1");
    const h2 = try putBlob(&store, "v2");

    var sub_a = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer sub_a.deinit();
    try sub_a.appendEntry("f", filemode.Regular, h1);
    const ha = try putTree(&store, &sub_a);

    var sub_b = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer sub_b.deinit();
    try sub_b.appendEntry("f", filemode.Regular, h2);
    const hb = try putTree(&store, &sub_b);

    var ta = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer ta.deinit();
    try ta.appendEntry("d", filemode.Dir, ha);
    ta.sortEntries();

    var tb = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tb.deinit();
    try tb.appendEntry("d", filemode.Dir, hb);
    tb.sortEntries();

    var changes = try diffTree(gpa, &ta, &tb);
    defer changes.deinit();
    try expectChanges(&changes, &[_]Expect{
        .{ .action = .modify, .name = "d/f" },
    });
}

// DiffTreeWithOptions rename detection on exact blob rename
test "diffTreeWithOptions detect exact rename" {
    const gpa = std.testing.allocator;

    var store = Storage.init(gpa);
    defer store.deinit();
    const bh = try putBlob(&store, "shared-body");

    var ta = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer ta.deinit();
    try ta.appendEntry("old.rb", filemode.Regular, bh);
    ta.sortEntries();

    var tb = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tb.deinit();
    try tb.appendEntry("new.rb", filemode.Regular, bh);
    tb.sortEntries();

    var changes = try diffTreeWithOptions(gpa, &ta, &tb, .{
        .detect_renames = true,
        .rename_score = 50,
        .only_exact_renames = true,
    });
    defer changes.deinit();
    try expectChanges(&changes, &[_]Expect{
        .{ .action = .modify, .name = "old.rb" },
    });
    try std.testing.expectEqualStrings("old.rb", changes.items[0].from.name);
    try std.testing.expectEqualStrings("new.rb", changes.items[0].to.name);
}

// Without rename detection: delete + insert
test "diffTree without rename stays delete insert" {
    const gpa = std.testing.allocator;

    var store = Storage.init(gpa);
    defer store.deinit();
    const bh = try putBlob(&store, "shared-body");

    var ta = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer ta.deinit();
    try ta.appendEntry("old.rb", filemode.Regular, bh);
    ta.sortEntries();

    var tb = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tb.deinit();
    try tb.appendEntry("new.rb", filemode.Regular, bh);
    tb.sortEntries();

    var changes = try diffTree(gpa, &ta, &tb);
    defer changes.deinit();
    try expectChanges(&changes, &[_]Expect{
        .{ .action = .insert, .name = "new.rb" },
        .{ .action = .delete, .name = "old.rb" },
    });
}

// Replace one file with another (different names and content)
test "diffTree replace file set" {
    const gpa = std.testing.allocator;

    var store = Storage.init(gpa);
    defer store.deinit();
    const h_a = try putBlob(&store, "aaa");
    const h_b = try putBlob(&store, "bbb");

    var ta = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer ta.deinit();
    try ta.appendEntry("a.txt", filemode.Regular, h_a);
    ta.sortEntries();

    var tb = Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tb.deinit();
    try tb.appendEntry("b.txt", filemode.Regular, h_b);
    tb.sortEntries();

    var changes = try diffTree(gpa, &ta, &tb);
    defer changes.deinit();
    try expectChanges(&changes, &[_]Expect{
        .{ .action = .delete, .name = "a.txt" },
        .{ .action = .insert, .name = "b.txt" },
    });
}
