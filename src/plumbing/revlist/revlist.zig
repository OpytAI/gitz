//! go-git `plumbing/revlist` — reachable object hash sets (complement of ignore).
//!
//! Port of go-git v5.19.2 `plumbing/revlist/revlist.go`.
//!
//! # Walk strategy
//!
//! Mirrors go-git `processObject` / `reachableObjects` / `iterateCommitTrees`:
//! commits (preorder parents), trees (recursive, skip submodule mode), blobs,
//! and annotated tags (peel to target).
//!
//! Decoding uses minimal commit/tree/tag text parse over `MemoryObject` content
//! (git wire formats). Prefer `plumbing/object` decode + walkers once that
//! package is complete; behavior must stay identical to go-git.

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const MemoryObject = plumbing.MemoryObject;
const FileMode = filemode.FileMode;

/// Errors from revlist walks (plus allocator failures from the caller path).
pub const Error = error{
    /// Object missing from the storer (go-git `plumbing.ErrObjectNotFound`).
    ObjectNotFound,
    /// Encoded object type is not commit/tree/blob/tag.
    InvalidObjectType,
    /// Commit, tree, or tag payload could not be parsed.
    MalformedObject,
};

const HashSet = std.AutoHashMapUnmanaged(Hash, void);

/// Parent-hash series for the preorder commit walk stack.
const ParentSeries = struct {
    hashes: []const Hash,
    pos: usize = 0,
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Complementary reachable set (go-git `Objects`).
///
/// Returns every object hash reachable from `objs` that is not reachable from
/// `ignore`. Caller owns the returned slice and must free it with `allocator`.
///
/// `store` must provide:
/// `encodedObject(self, t: ObjectType, h: Hash) !*MemoryObject`.
pub fn objects(
    allocator: Allocator,
    store: anytype,
    objs: []const Hash,
    ignore: []const Hash,
) ![]Hash {
    return objectsWithStorageForIgnores(allocator, store, store, objs, ignore);
}

/// Same as `objects`, but expands `ignore` against `ignore_store`
/// (go-git `ObjectsWithStorageForIgnores`).
pub fn objectsWithStorageForIgnores(
    allocator: Allocator,
    store: anytype,
    ignore_store: anytype,
    objs: []const Hash,
    ignore: []const Hash,
) ![]Hash {
    const expanded_ignore = try objectsInternal(allocator, ignore_store, ignore, &.{}, true);
    defer allocator.free(expanded_ignore);
    return objectsInternal(allocator, store, objs, expanded_ignore, false);
}

// ---------------------------------------------------------------------------
// Core walk
// ---------------------------------------------------------------------------

fn objectsInternal(
    allocator: Allocator,
    store: anytype,
    object_hashes: []const Hash,
    ignore: []const Hash,
    allow_missing: bool,
) ![]Hash {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var seen: HashSet = .empty;
    for (ignore) |h| {
        try seen.put(arena, h, {});
    }

    var result: HashSet = .empty;
    var visited: HashSet = .empty;

    const CbCtx = struct {
        seen: *HashSet,
        result: *HashSet,
        arena: Allocator,

        fn call(self: *@This(), h: Hash) Allocator.Error!void {
            if (self.seen.contains(h)) return;
            try self.result.put(self.arena, h, {});
            try self.seen.put(self.arena, h, {});
        }
    };
    var cb = CbCtx{ .seen = &seen, .result = &result, .arena = arena };

    for (object_hashes) |h| {
        processObject(arena, store, h, &seen, &visited, ignore, &cb) catch |err| {
            if (allow_missing and err == error.ObjectNotFound) continue;
            return err;
        };
    }

    var out: std.ArrayList(Hash) = .empty;
    errdefer out.deinit(allocator);
    var it = result.keyIterator();
    while (it.next()) |key| {
        try out.append(allocator, key.*);
    }
    return try out.toOwnedSlice(allocator);
}

fn processObject(
    arena: Allocator,
    store: anytype,
    h: Hash,
    seen: *HashSet,
    visited: *HashSet,
    ignore: []const Hash,
    cb: anytype,
) !void {
    if (seen.contains(h)) return;

    const o = try getObject(store, .any, h);

    switch (o.object_type) {
        .commit => {
            const commit = try parseCommit(arena, o);
            try reachableObjects(arena, store, commit, seen, visited, ignore, cb);
        },
        .tree => {
            const entries = try parseTreeEntries(arena, o.readerBytes());
            try iterateCommitTrees(arena, store, o.hash(), entries, seen, cb);
        },
        .tag => {
            const tag = try parseTag(o);
            try cb.call(tag.hash);
            try processObject(arena, store, tag.target, seen, visited, ignore, cb);
        },
        .blob => try cb.call(o.hash()),
        else => return error.InvalidObjectType,
    }
}

/// go-git `reachableObjects` + `NewCommitPreorderIter` walk.
fn reachableObjects(
    arena: Allocator,
    store: anytype,
    start: ParsedCommit,
    seen: *HashSet,
    visited: *HashSet,
    ignore: []const Hash,
    cb: anytype,
) !void {
    var iter_seen: HashSet = .empty;
    for (ignore) |ih| {
        try iter_seen.put(arena, ih, {});
    }

    var stack: std.ArrayList(ParentSeries) = .empty;
    var start_commit: ?ParsedCommit = start;

    var pending: HashSet = .empty;
    try addPendingParents(&pending, visited, arena, start);

    while (true) {
        const commit = nextPreorder(
            arena,
            store,
            &start_commit,
            &stack,
            &iter_seen,
            seen,
        ) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };

        if (pending.contains(commit.hash)) {
            _ = pending.remove(commit.hash);
        }
        try addPendingParents(&pending, visited, arena, commit);

        if (visited.contains(commit.hash) and pending.count() == 0) {
            break;
        }
        if (seen.contains(commit.hash)) {
            continue;
        }

        try cb.call(commit.hash);

        const tree_obj = try getObject(store, .tree, commit.tree);
        const entries = try parseTreeEntries(arena, tree_obj.readerBytes());
        try iterateCommitTrees(arena, store, tree_obj.hash(), entries, seen, cb);
    }
}

fn nextPreorder(
    arena: Allocator,
    store: anytype,
    start: *?ParsedCommit,
    stack: *std.ArrayList(ParentSeries),
    iter_seen: *HashSet,
    seen_external: *const HashSet,
) !ParsedCommit {
    while (true) {
        var c: ParsedCommit = undefined;
        if (start.*) |s| {
            c = s;
            start.* = null;
        } else {
            while (true) {
                if (stack.items.len == 0) return error.EndOfStream;
                const current = &stack.items[stack.items.len - 1];
                if (current.pos >= current.hashes.len) {
                    _ = stack.pop();
                    continue;
                }
                const ph = current.hashes[current.pos];
                current.pos += 1;
                c = try loadCommit(arena, store, ph);
                break;
            }
        }

        if (iter_seen.contains(c.hash) or seen_external.contains(c.hash)) {
            continue;
        }
        try iter_seen.put(arena, c.hash, {});

        if (c.parents.len > 0) {
            var filtered: std.ArrayList(Hash) = .empty;
            for (c.parents) |p| {
                if (!iter_seen.contains(p)) {
                    try filtered.append(arena, p);
                }
            }
            if (filtered.items.len > 0) {
                try stack.append(arena, .{ .hashes = filtered.items });
            }
        }
        return c;
    }
}

fn addPendingParents(
    pending: *HashSet,
    visited: *const HashSet,
    arena: Allocator,
    commit: ParsedCommit,
) !void {
    for (commit.parents) |p| {
        if (!visited.contains(p)) {
            try pending.put(arena, p, {});
        }
    }
}

/// go-git `iterateCommitTrees` — recursive tree walk; skip submodules.
fn iterateCommitTrees(
    arena: Allocator,
    store: anytype,
    tree_hash: Hash,
    entries: []const TreeEntry,
    seen: *HashSet,
    cb: anytype,
) !void {
    if (seen.contains(tree_hash)) return;

    try cb.call(tree_hash);

    const Frame = struct {
        entries: []const TreeEntry,
        index: usize = 0,
    };
    var stack: std.ArrayList(Frame) = .empty;
    try stack.append(arena, .{ .entries = entries });

    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        if (top.index >= top.entries.len) {
            _ = stack.pop();
            continue;
        }
        const e = top.entries[top.index];
        top.index += 1;

        if (e.mode == filemode.Submodule) continue;
        if (seen.contains(e.hash)) continue;

        try cb.call(e.hash);

        if (e.mode == filemode.Dir) {
            const child = getObject(store, .tree, e.hash) catch |err| {
                // go-git TreeWalker maps load failure to EOF (skip entry).
                if (err == error.ObjectNotFound) continue;
                return err;
            };
            const child_entries = try parseTreeEntries(arena, child.readerBytes());
            try stack.append(arena, .{ .entries = child_entries });
        }
    }
}

// ---------------------------------------------------------------------------
// Minimal decode (commit / tree / tag)
// ---------------------------------------------------------------------------

const ParsedCommit = struct {
    hash: Hash,
    tree: Hash,
    parents: []Hash,
};

const TreeEntry = struct {
    mode: FileMode,
    name: []const u8,
    hash: Hash,
};

const ParsedTag = struct {
    hash: Hash,
    target: Hash,
};

fn getObject(store: anytype, t: plumbing.ObjectType, h: Hash) !*MemoryObject {
    return store.encodedObject(t, h) catch {
        return error.ObjectNotFound;
    };
}

fn loadCommit(arena: Allocator, store: anytype, h: Hash) !ParsedCommit {
    const o = try getObject(store, .commit, h);
    return parseCommit(arena, o);
}

fn parseCommit(arena: Allocator, o: *const MemoryObject) !ParsedCommit {
    if (o.object_type != .commit) return error.InvalidObjectType;
    const data = o.readerBytes();

    var tree: ?Hash = null;
    var parents: std.ArrayList(Hash) = .empty;

    var rest = data;
    while (rest.len > 0) {
        if (rest[0] == '\n') break;
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse break;
        const line = rest[0..nl];
        rest = rest[nl + 1 ..];

        if (std.mem.startsWith(u8, line, "tree ")) {
            if (line.len < 5 + plumbing.HexSize) return error.MalformedObject;
            tree = plumbing.parseHash(line[5 .. 5 + plumbing.HexSize]) catch {
                return error.MalformedObject;
            };
        } else if (std.mem.startsWith(u8, line, "parent ")) {
            if (line.len < 7 + plumbing.HexSize) return error.MalformedObject;
            const ph = plumbing.parseHash(line[7 .. 7 + plumbing.HexSize]) catch {
                return error.MalformedObject;
            };
            try parents.append(arena, ph);
        }
    }

    const tree_hash = tree orelse return error.MalformedObject;
    return .{
        .hash = @constCast(o).hash(),
        .tree = tree_hash,
        .parents = parents.items,
    };
}

fn parseTreeEntries(arena: Allocator, data: []const u8) ![]TreeEntry {
    var entries: std.ArrayList(TreeEntry) = .empty;
    var i: usize = 0;
    while (i < data.len) {
        const sp = std.mem.indexOfScalarPos(u8, data, i, ' ') orelse {
            return error.MalformedObject;
        };
        const mode_str = data[i..sp];
        const mode = filemode.new(mode_str) catch return error.MalformedObject;
        i = sp + 1;

        const nul = std.mem.indexOfScalarPos(u8, data, i, 0) orelse {
            return error.MalformedObject;
        };
        if (nul == i) return error.MalformedObject;
        const name = data[i..nul];
        i = nul + 1;

        if (i + plumbing.Size > data.len) return error.MalformedObject;
        var raw: [plumbing.Size]u8 = undefined;
        @memcpy(&raw, data[i .. i + plumbing.Size]);
        i += plumbing.Size;

        try entries.append(arena, .{
            .mode = canonicalTreeMode(mode),
            .name = name,
            .hash = Hash.fromBytes(raw),
        });
    }
    return entries.items;
}

fn canonicalTreeMode(mode: FileMode) FileMode {
    const kind = mode & 0o170000;
    return switch (kind) {
        0o040000 => filemode.Dir,
        0o100000 => if (mode & 0o111 != 0) filemode.Executable else filemode.Regular,
        0o120000 => filemode.Symlink,
        else => filemode.Submodule,
    };
}

fn parseTag(o: *const MemoryObject) !ParsedTag {
    if (o.object_type != .tag) return error.InvalidObjectType;
    const data = o.readerBytes();
    if (!std.mem.startsWith(u8, data, "object ")) return error.MalformedObject;
    if (data.len < 7 + plumbing.HexSize) return error.MalformedObject;
    const target = plumbing.parseHash(data[7 .. 7 + plumbing.HexSize]) catch {
        return error.MalformedObject;
    };
    return .{
        .hash = @constCast(o).hash(),
        .target = target,
    };
}

// ---------------------------------------------------------------------------
// Unit tests (decode helpers)
// ---------------------------------------------------------------------------

test "parseCommit tree and parents" {
    const allocator = std.testing.allocator;
    var obj = MemoryObject.init(allocator);
    defer obj.deinit();
    obj.setType(.commit);
    const body =
        \\tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904
        \\parent 1234567890abcdef1234567890abcdef12345678
        \\parent abcdef1234567890abcdef1234567890abcdef12
        \\author A <a@b> 1 +0000
        \\committer A <a@b> 1 +0000
        \\
        \\msg
    ;
    _ = try obj.write(body);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const c = try parseCommit(arena.allocator(), &obj);
    var buf: [plumbing.HexSize]u8 = undefined;
    try std.testing.expectEqualStrings(
        "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
        c.tree.string(&buf),
    );
    try std.testing.expectEqual(@as(usize, 2), c.parents.len);
}

test "parseTreeEntries regular and dir" {
    const allocator = std.testing.allocator;
    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(allocator);

    try content.appendSlice(allocator, "100644 file");
    try content.append(allocator, 0);
    try content.appendSlice(allocator, &([_]u8{0} ** 20));
    try content.appendSlice(allocator, "40000 sub");
    try content.append(allocator, 0);
    try content.appendSlice(allocator, &([_]u8{0xff} ** 20));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const entries = try parseTreeEntries(arena.allocator(), content.items);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expect(entries[0].mode == filemode.Regular);
    try std.testing.expectEqualStrings("file", entries[0].name);
    try std.testing.expect(entries[1].mode == filemode.Dir);
    try std.testing.expectEqualStrings("sub", entries[1].name);
}
