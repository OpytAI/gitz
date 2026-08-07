//! plumbing/revlist — reachable object hash sets (go-git `plumbing/revlist`).
//!
//! # go-git surface
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `Objects` | `objects` |
//! | `ObjectsWithStorageForIgnores` | `objectsWithStorageForIgnores` |
//!
//! # go-git test map
//!
//! Fixture-based tests in go-git (`revlist_test.go`) need real repos. This
//! package covers the same semantics with in-memory objects:
//!
//! | go-git idea | Zig test |
//! |-------------|----------|
//! | Two commits sharing blob; ignore first | `two commits sharing blob ignore first reachable set` |
//! | Reverse ignore empties set | `ignore superset yields empty` |
//! | Same tip vs itself | `same commit ignore yields empty` |
//! | Tag object walk | `tag reaches target commit tree blob` |
//! | ObjectsWithStorageForIgnores | `objectsWithStorageForIgnores dual store` |
//! | Submodule skipped | `submodule entry not listed` |

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");

const revlist = @import("revlist.zig");

pub const Error = revlist.Error;
pub const objects = revlist.objects;
pub const objectsWithStorageForIgnores = revlist.objectsWithStorageForIgnores;

test {
    _ = revlist;
}

// ---------------------------------------------------------------------------
// Test fixture builders
// ---------------------------------------------------------------------------

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Storage = memory.Storage;

fn storeBlob(s: *Storage, content: []const u8) !Hash {
    const obj = try s.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write(content);
    return s.setEncodedObject(obj);
}

fn appendTreeEntry(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    mode_octal: []const u8,
    name: []const u8,
    hash: Hash,
) !void {
    try buf.appendSlice(allocator, mode_octal);
    try buf.append(allocator, ' ');
    try buf.appendSlice(allocator, name);
    try buf.append(allocator, 0);
    try buf.appendSlice(allocator, hash.bytes[0..]);
}

fn storeTree(s: *Storage, allocator: Allocator, entries: []const struct {
    mode: []const u8,
    name: []const u8,
    hash: Hash,
}) !Hash {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (entries) |e| {
        try appendTreeEntry(&buf, allocator, e.mode, e.name, e.hash);
    }
    const obj = try s.newEncodedObject();
    obj.setType(.tree);
    _ = try obj.write(buf.items);
    return s.setEncodedObject(obj);
}

fn storeCommit(
    s: *Storage,
    allocator: Allocator,
    tree: Hash,
    parents: []const Hash,
    message: []const u8,
) !Hash {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var tree_hex: [plumbing.HexSize]u8 = undefined;
    try buf.appendSlice(allocator, "tree ");
    try buf.appendSlice(allocator, tree.string(&tree_hex));
    try buf.append(allocator, '\n');

    for (parents) |p| {
        var p_hex: [plumbing.HexSize]u8 = undefined;
        try buf.appendSlice(allocator, "parent ");
        try buf.appendSlice(allocator, p.string(&p_hex));
        try buf.append(allocator, '\n');
    }

    try buf.appendSlice(allocator, "author Test <test@example.com> 1000000000 +0000\n");
    try buf.appendSlice(allocator, "committer Test <test@example.com> 1000000000 +0000\n");
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, message);

    const obj = try s.newEncodedObject();
    obj.setType(.commit);
    _ = try obj.write(buf.items);
    return s.setEncodedObject(obj);
}

fn storeTag(
    s: *Storage,
    allocator: Allocator,
    target: Hash,
    target_type: []const u8,
    name: []const u8,
) !Hash {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var hex: [plumbing.HexSize]u8 = undefined;
    try buf.appendSlice(allocator, "object ");
    try buf.appendSlice(allocator, target.string(&hex));
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, "type ");
    try buf.appendSlice(allocator, target_type);
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, "tag ");
    try buf.appendSlice(allocator, name);
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, "tagger Test <test@example.com> 1000000000 +0000\n");
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, "tag message\n");

    const obj = try s.newEncodedObject();
    obj.setType(.tag);
    _ = try obj.write(buf.items);
    return s.setEncodedObject(obj);
}

fn containsHash(list: []const Hash, h: Hash) bool {
    for (list) |x| {
        if (x.eql(h)) return true;
    }
    return false;
}

fn expectSetEqual(got: []const Hash, want: []const Hash) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want) |w| {
        try std.testing.expect(containsHash(got, w));
    }
}

// ---------------------------------------------------------------------------
// Integration tests
// ---------------------------------------------------------------------------

//  Two commits share one blob. Ignore the first commit's reachable set → only
//  second-commit-unique objects remain (go-git `TestRevListObjects` idea).
test "two commits sharing blob ignore first reachable set" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const shared = try storeBlob(s, "shared-content");
    const only1 = try storeBlob(s, "only-in-commit-1");
    const only2 = try storeBlob(s, "only-in-commit-2");

    const tree1 = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "a.txt", .hash = only1 },
        .{ .mode = "100644", .name = "shared.txt", .hash = shared },
    });
    const tree2 = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "b.txt", .hash = only2 },
        .{ .mode = "100644", .name = "shared.txt", .hash = shared },
    });

    const commit1 = try storeCommit(s, allocator, tree1, &.{}, "first");
    const commit2 = try storeCommit(s, allocator, tree2, &.{commit1}, "second");

    const local = try objects(allocator, s, &.{commit1}, &.{});
    defer allocator.free(local);

    // commit1 reachable: commit1, tree1, only1, shared
    try expectSetEqual(local, &.{ commit1, tree1, only1, shared });

    const remote = try objects(allocator, s, &.{commit2}, local);
    defer allocator.free(remote);

    // Complement: commit2, tree2, only2 (shared already in ignore expansion)
    try expectSetEqual(remote, &.{ commit2, tree2, only2 });
}

test "ignore superset yields empty" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const blob = try storeBlob(s, "x");
    const tree = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "f", .hash = blob },
    });
    const c1 = try storeCommit(s, allocator, tree, &.{}, "one");
    const c2 = try storeCommit(s, allocator, tree, &.{c1}, "two");

    const all = try objects(allocator, s, &.{c2}, &.{});
    defer allocator.free(all);

    const empty = try objects(allocator, s, &.{c1}, all);
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "same commit ignore yields empty" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const blob = try storeBlob(s, "y");
    const tree = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "f", .hash = blob },
    });
    const c = try storeCommit(s, allocator, tree, &.{}, "solo");

    const hist = try objects(allocator, s, &.{c}, &.{});
    defer allocator.free(hist);

    const empty = try objects(allocator, s, &.{c}, hist);
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "tag reaches target commit tree blob" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const blob = try storeBlob(s, "tagged");
    const tree = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "f", .hash = blob },
    });
    const commit = try storeCommit(s, allocator, tree, &.{}, "tagged commit");
    const tag = try storeTag(s, allocator, commit, "commit", "v1");

    const hist = try objects(allocator, s, &.{tag}, &.{});
    defer allocator.free(hist);

    try expectSetEqual(hist, &.{ tag, commit, tree, blob });
}

test "objectsWithStorageForIgnores dual store" {
    const allocator = std.testing.allocator;
    const main_s = try memory.newStorage(allocator);
    defer {
        main_s.deinit();
        allocator.destroy(main_s);
    }
    const ignore_s = try memory.newStorage(allocator);
    defer {
        ignore_s.deinit();
        allocator.destroy(ignore_s);
    }

    // Shared blob present in both stores (same content → same hash).
    const shared_main = try storeBlob(main_s, "common");
    const shared_ignore = try storeBlob(ignore_s, "common");
    try std.testing.expect(shared_main.eql(shared_ignore));

    const only_main = try storeBlob(main_s, "only-main");
    const only_ignore = try storeBlob(ignore_s, "only-ignore");

    const tree_main = try storeTree(main_s, allocator, &.{
        .{ .mode = "100644", .name = "common", .hash = shared_main },
        .{ .mode = "100644", .name = "local", .hash = only_main },
    });
    const tree_ignore = try storeTree(ignore_s, allocator, &.{
        .{ .mode = "100644", .name = "common", .hash = shared_ignore },
        .{ .mode = "100644", .name = "other", .hash = only_ignore },
    });

    const commit_main = try storeCommit(main_s, allocator, tree_main, &.{}, "main");
    const commit_ignore = try storeCommit(ignore_s, allocator, tree_ignore, &.{}, "ignore");

    // Expand ignore from ignore_s; walk objs on main_s.
    const hist = try objectsWithStorageForIgnores(
        allocator,
        main_s,
        ignore_s,
        &.{commit_main},
        &.{commit_ignore},
    );
    defer allocator.free(hist);

    // shared is in ignore expansion → excluded. only_main / tree_main / commit_main remain.
    try expectSetEqual(hist, &.{ commit_main, tree_main, only_main });
    try std.testing.expect(!containsHash(hist, shared_main));
    try std.testing.expect(!containsHash(hist, only_ignore));
}

test "submodule entry not listed" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const blob = try storeBlob(s, "file");
    // Fake submodule hash (no object stored).
    const sub_hash = plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

    const tree = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "f", .hash = blob },
        .{ .mode = "160000", .name = "sub", .hash = sub_hash },
    });
    const commit = try storeCommit(s, allocator, tree, &.{}, "with submodule");

    const hist = try objects(allocator, s, &.{commit}, &.{});
    defer allocator.free(hist);

    try expectSetEqual(hist, &.{ commit, tree, blob });
    try std.testing.expect(!containsHash(hist, sub_hash));
}

test "start from tree and blob directly" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const blob = try storeBlob(s, "direct");
    const tree = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "f", .hash = blob },
    });

    const from_tree = try objects(allocator, s, &.{tree}, &.{});
    defer allocator.free(from_tree);
    try expectSetEqual(from_tree, &.{ tree, blob });

    const from_blob = try objects(allocator, s, &.{blob}, &.{});
    defer allocator.free(from_blob);
    try expectSetEqual(from_blob, &.{blob});
}

test "missing ignore object allowed" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const blob = try storeBlob(s, "z");
    const tree = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "f", .hash = blob },
    });
    const c = try storeCommit(s, allocator, tree, &.{}, "ok");
    const missing = plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");

    // Ignore list may contain missing hashes (expanded with allowMissing).
    const hist = try objects(allocator, s, &.{c}, &.{missing});
    defer allocator.free(hist);
    try expectSetEqual(hist, &.{ c, tree, blob });
}
