//! plumbing/serverinfo — dumb HTTP `info/refs` + `objects/info/packs`
//! (go-git `plumbing/serverinfo`).
//!
//! # go-git surface
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `UpdateServerInfo` | `updateServerInfo` |
//! | `git.ErrPackedObjectsNotSupported` | `error.PackedObjectsNotSupported` |
//!
//! # go-git test map
//!
//! Fixture-clone tests in go-git (`serverinfo_test.go`) are mirrored with
//! in-memory seeded refs/objects:
//!
//! | go-git | Zig |
//! |--------|-----|
//! | TestUpdateServerInfoInit | `empty storage writes empty packs and empty refs` |
//! | TestUpdateServerInfoBasic | `branches and HEAD produce sorted info/refs` |
//! | TestUpdateServerInfoTags | `annotated tag peels with ^{}` |
//! | TestUpdateServerInfoBasicChange | `re-run after new branch and tag` |
//! | assertObjectPacks | `packs file lists seeded pack hashes` |
//! | ErrPackedObjectsNotSupported | `storer without objectPacks fails` |

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");
const fs_pkg = @import("fs");
const object = @import("object");

const serverinfo = @import("serverinfo.zig");

pub const Error = serverinfo.Error;
pub const updateServerInfo = serverinfo.updateServerInfo;

test {
    _ = serverinfo;
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Storage = memory.Storage;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;

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
    try buf.appendSlice(allocator, hash.slice());
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

    var tree_hex: [plumbing.MaxHexSize]u8 = undefined;
    try buf.appendSlice(allocator, "tree ");
    try buf.appendSlice(allocator, tree.string(&tree_hex));
    try buf.append(allocator, '\n');

    for (parents) |p| {
        var p_hex: [plumbing.MaxHexSize]u8 = undefined;
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

    var hex: [plumbing.MaxHexSize]u8 = undefined;
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

/// Seed a tiny repo: blob → tree → commit, HEAD → master, optional branch/tag.
const Seed = struct {
    commit: Hash,
    tree: Hash,
    blob: Hash,
};

fn seedBasic(s: *Storage, allocator: Allocator) !Seed {
    const blob = try storeBlob(s, "hello serverinfo\n");
    const tree = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "README", .hash = blob },
    });
    const commit = try storeCommit(s, allocator, tree, &.{}, "initial\n");

    try s.setReference(Reference.newHashReference(
        plumbing.master,
        commit,
    ));
    try s.setReference(Reference.newSymbolicReference(
        plumbing.HEAD,
        plumbing.master,
    ));

    return .{ .commit = commit, .tree = tree, .blob = blob };
}

fn readFileAll(allocator: Allocator, fs: *fs_pkg.Mem, path: []const u8) ![]u8 {
    var f = try fs.open(path);
    defer f.close() catch {};

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [256]u8 = undefined;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
    }
    return try out.toOwnedSlice(allocator);
}

/// Parse `info/refs` into name → hash (go-git assertInfoRefs shape).
fn parseInfoRefs(allocator: Allocator, content: []const u8) !std.StringHashMapUnmanaged(Hash) {
    var map: std.StringHashMapUnmanaged(Hash) = .empty;
    errdefer {
        var it = map.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        map.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parts = std.mem.splitScalar(u8, line, '\t');
        const hash_s = parts.next() orelse return error.MalformedInfoRefs;
        const name_s = parts.next() orelse return error.MalformedInfoRefs;
        if (parts.next() != null) return error.MalformedInfoRefs;

        const h = try plumbing.parseHash(hash_s);
        const key = try allocator.dupe(u8, name_s);
        errdefer allocator.free(key);
        try map.put(allocator, key, h);
    }
    return map;
}

fn freeInfoRefsMap(allocator: Allocator, map: *std.StringHashMapUnmanaged(Hash)) void {
    var it = map.keyIterator();
    while (it.next()) |k| allocator.free(k.*);
    map.deinit(allocator);
    map.* = .empty;
}

/// Assert every non-HEAD hash/symbolic ref appears in info/refs with correct hash;
/// annotated tags also have a peeled `name^{}` entry (go-git assertInfoRefs).
fn assertInfoRefs(allocator: Allocator, s: *Storage, fs: *fs_pkg.Mem) !void {
    const raw = try readFileAll(allocator, fs, "info/refs");
    defer allocator.free(raw);

    var local = try parseInfoRefs(allocator, raw);
    defer freeInfoRefsMap(allocator, &local);

    var iter = try s.iterReferences();
    defer iter.deinit();

    while (true) {
        const ref = iter.next() catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        const name = ref.name;
        var hash = ref.hash;

        switch (ref.type) {
            .symbolic => {
                if (name.eql(plumbing.HEAD)) continue;
                const target = try s.reference(ref.target);
                hash = target.hash;
                const got = local.get(name.raw) orelse return error.MissingRefInInfoRefs;
                try std.testing.expect(got.eql(hash));
                if (name.isTag()) {
                    var tag = object.getTag(allocator, s, hash) catch continue;
                    defer tag.deinit();
                    const peeled_name = try std.fmt.allocPrint(allocator, "{s}^{{}}", .{name.raw});
                    defer allocator.free(peeled_name);
                    const peeled = local.get(peeled_name) orelse return error.MissingPeeledTag;
                    try std.testing.expect(peeled.eql(tag.target));
                }
            },
            .hash => {
                const got = local.get(name.raw) orelse return error.MissingRefInInfoRefs;
                try std.testing.expect(got.eql(hash));
                if (name.isTag()) {
                    var tag = object.getTag(allocator, s, hash) catch continue;
                    defer tag.deinit();
                    const peeled_name = try std.fmt.allocPrint(allocator, "{s}^{{}}", .{name.raw});
                    defer allocator.free(peeled_name);
                    const peeled = local.get(peeled_name) orelse return error.MissingPeeledTag;
                    try std.testing.expect(peeled.eql(tag.target));
                }
            },
            .invalid => {},
        }
    }
}

fn assertEmptyPacks(allocator: Allocator, fs: *fs_pkg.Mem) !void {
    const raw = try readFileAll(allocator, fs, "objects/info/packs");
    defer allocator.free(raw);
    // go-git always writes a trailing newline via Fprintln.
    try std.testing.expectEqualStrings("\n", raw);
}

// ---------------------------------------------------------------------------
// Mock storers for capability / packs-with-content tests
// ---------------------------------------------------------------------------

/// Storer that implements refs + objects but **not** `objectPacks`.
const NoPacksStorer = struct {
    base: *Storage,

    pub fn iterReferences(self: *const NoPacksStorer) !memory.ReferenceSliceIter {
        return self.base.iterReferences();
    }
    pub fn reference(self: *const NoPacksStorer, n: ReferenceName) plumbing.Error!Reference {
        return self.base.reference(n);
    }
    pub fn encodedObject(self: *const NoPacksStorer, t: plumbing.ObjectType, h: Hash) error{ObjectNotFound}!*plumbing.MemoryObject {
        return self.base.encodedObject(t, h);
    }
};

/// Memory storer with synthetic pack hashes (transfers ownership of a dupe).
const PackSeedStorer = struct {
    base: *Storage,
    packs: []const Hash,

    pub fn iterReferences(self: *const PackSeedStorer) !memory.ReferenceSliceIter {
        return self.base.iterReferences();
    }
    pub fn reference(self: *const PackSeedStorer, n: ReferenceName) plumbing.Error!Reference {
        return self.base.reference(n);
    }
    pub fn encodedObject(self: *const PackSeedStorer, t: plumbing.ObjectType, h: Hash) error{ObjectNotFound}!*plumbing.MemoryObject {
        return self.base.encodedObject(t, h);
    }
    /// Heap-dup so updateServerInfo may free non-empty packs via `allocator`.
    pub fn objectPacks(self: *const PackSeedStorer) Allocator.Error![]Hash {
        return try self.base.allocator.dupe(Hash, self.packs);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "empty storage writes empty packs and empty refs" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }
    var fs = try fs_pkg.Mem.init(allocator);
    defer fs.deinit();

    try updateServerInfo(allocator, s, &fs);

    const refs = try readFileAll(allocator, &fs, "info/refs");
    defer allocator.free(refs);
    try std.testing.expectEqualStrings("", refs);
    try assertEmptyPacks(allocator, &fs);
}

test "branches and HEAD produce sorted info/refs" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }
    var fs = try fs_pkg.Mem.init(allocator);
    defer fs.deinit();

    const seed = try seedBasic(s, allocator);

    // Second branch, out of name order until sort.
    try s.setReference(Reference.newHashReference(
        ReferenceName.init("refs/heads/feature"),
        seed.commit,
    ));

    try updateServerInfo(allocator, s, &fs);
    try assertInfoRefs(allocator, s, &fs);
    try assertEmptyPacks(allocator, &fs);

    const raw = try readFileAll(allocator, &fs, "info/refs");
    defer allocator.free(raw);

    // Sorted by name: feature before master; HEAD skipped.
    var hex: [plumbing.MaxHexSize]u8 = undefined;
    const h = seed.commit.string(&hex);
    const expected = try std.fmt.allocPrint(allocator, "{s}\trefs/heads/feature\n{s}\trefs/heads/master\n", .{ h, h });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, raw);
}

test "annotated tag peels with ^{}" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }
    var fs = try fs_pkg.Mem.init(allocator);
    defer fs.deinit();

    const seed = try seedBasic(s, allocator);
    const tag_hash = try storeTag(s, allocator, seed.commit, "commit", "v1.0");
    try s.setReference(Reference.newHashReference(
        ReferenceName.init("refs/tags/v1.0"),
        tag_hash,
    ));

    try updateServerInfo(allocator, s, &fs);
    try assertInfoRefs(allocator, s, &fs);

    const raw = try readFileAll(allocator, &fs, "info/refs");
    defer allocator.free(raw);

    var commit_hex: [plumbing.MaxHexSize]u8 = undefined;
    var tag_hex: [plumbing.MaxHexSize]u8 = undefined;
    const ch = seed.commit.string(&commit_hex);
    const th = tag_hash.string(&tag_hex);

    // Sorted: master, then v1.0, then v1.0^{}
    const expected = try std.fmt.allocPrint(
        allocator,
        "{s}\trefs/heads/master\n{s}\trefs/tags/v1.0\n{s}\trefs/tags/v1.0^{{}}\n",
        .{ ch, th, ch },
    );
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, raw);
}

test "lightweight tag has no peeled line" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }
    var fs = try fs_pkg.Mem.init(allocator);
    defer fs.deinit();

    const seed = try seedBasic(s, allocator);
    // Lightweight tag: ref points at commit, not a tag object.
    try s.setReference(Reference.newHashReference(
        ReferenceName.init("refs/tags/light"),
        seed.commit,
    ));

    try updateServerInfo(allocator, s, &fs);
    try assertInfoRefs(allocator, s, &fs);

    const raw = try readFileAll(allocator, &fs, "info/refs");
    defer allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "^{}") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "refs/tags/light") != null);
}

test "re-run after new branch and tag" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }
    var fs = try fs_pkg.Mem.init(allocator);
    defer fs.deinit();

    const seed = try seedBasic(s, allocator);
    try updateServerInfo(allocator, s, &fs);
    try assertInfoRefs(allocator, s, &fs);

    try s.setReference(Reference.newHashReference(
        ReferenceName.init("refs/heads/my-branch"),
        seed.commit,
    ));
    const tag_hash = try storeTag(s, allocator, seed.commit, "commit", "test-tag");
    try s.setReference(Reference.newHashReference(
        ReferenceName.init("refs/tags/test-tag"),
        tag_hash,
    ));

    try updateServerInfo(allocator, s, &fs);
    try assertInfoRefs(allocator, s, &fs);
    try assertEmptyPacks(allocator, &fs);

    const raw = try readFileAll(allocator, &fs, "info/refs");
    defer allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "refs/heads/my-branch") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "refs/tags/test-tag") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "refs/tags/test-tag^{}") != null);
}

test "packs file lists seeded pack hashes" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }
    var fs = try fs_pkg.Mem.init(allocator);
    defer fs.deinit();

    _ = try seedBasic(s, allocator);

    const p1 = plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const p2 = plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    const packs = [_]Hash{ p1, p2 };

    var seeded = PackSeedStorer{ .base = s, .packs = &packs };
    try updateServerInfo(allocator, &seeded, &fs);

    const raw = try readFileAll(allocator, &fs, "objects/info/packs");
    defer allocator.free(raw);

    const expected =
        "P pack-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pack\n" ++
        "P pack-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.pack\n" ++
        "\n";
    try std.testing.expectEqualStrings(expected, raw);

    try assertInfoRefs(allocator, s, &fs);
}

test "storer without objectPacks fails" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }
    var fs = try fs_pkg.Mem.init(allocator);
    defer fs.deinit();

    var bare = NoPacksStorer{ .base = s };
    try std.testing.expectError(
        error.PackedObjectsNotSupported,
        updateServerInfo(allocator, &bare, &fs),
    );
}

test "symbolic non-HEAD resolves to target hash" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }
    var fs = try fs_pkg.Mem.init(allocator);
    defer fs.deinit();

    const seed = try seedBasic(s, allocator);
    try s.setReference(Reference.newSymbolicReference(
        ReferenceName.init("refs/remotes/origin/HEAD"),
        plumbing.master,
    ));

    try updateServerInfo(allocator, s, &fs);
    try assertInfoRefs(allocator, s, &fs);

    const raw = try readFileAll(allocator, &fs, "info/refs");
    defer allocator.free(raw);

    var hex: [plumbing.MaxHexSize]u8 = undefined;
    const h = seed.commit.string(&hex);
    const line = try std.fmt.allocPrint(allocator, "{s}\trefs/remotes/origin/HEAD\n", .{h});
    defer allocator.free(line);
    try std.testing.expect(std.mem.indexOf(u8, raw, line) != null);
}

test "info/refs line format is hash TAB name NEWLINE" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }
    var fs = try fs_pkg.Mem.init(allocator);
    defer fs.deinit();

    const seed = try seedBasic(s, allocator);
    try updateServerInfo(allocator, s, &fs);

    const raw = try readFileAll(allocator, &fs, "info/refs");
    defer allocator.free(raw);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    const line = lines.next().?;
    try std.testing.expect(line.len > 0);

    // Exactly one tab; hash is 40 hex chars; no space separator.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\t"));
    try std.testing.expect(std.mem.indexOfScalar(u8, line, ' ') == null);

    const tab = std.mem.indexOfScalar(u8, line, '\t').?;
    try std.testing.expectEqual(@as(usize, 40), tab);
    try std.testing.expect(plumbing.isHash(line[0..40]));
    try std.testing.expectEqualStrings("refs/heads/master", line[41..]);

    var hex: [plumbing.MaxHexSize]u8 = undefined;
    try std.testing.expectEqualStrings(seed.commit.string(&hex), line[0..40]);
}

test "create truncates previous info files on re-run" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }
    var fs = try fs_pkg.Mem.init(allocator);
    defer fs.deinit();

    const seed = try seedBasic(s, allocator);
    try s.setReference(Reference.newHashReference(
        ReferenceName.init("refs/heads/old"),
        seed.commit,
    ));
    try updateServerInfo(allocator, s, &fs);

    // Remove branch and re-run — old line must not linger (Create uses O_TRUNC).
    s.removeReference(ReferenceName.init("refs/heads/old"));
    try updateServerInfo(allocator, s, &fs);

    const raw = try readFileAll(allocator, &fs, "info/refs");
    defer allocator.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "refs/heads/old") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "refs/heads/master") != null);
}
