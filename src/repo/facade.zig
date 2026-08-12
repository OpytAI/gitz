//! Repository facades — go-git `repository.go` object/ref methods.
//!
//! Free functions accept compatible object/reference storage backends.
//! `RepositoryFor` wraps them as methods.
//!
//! Log lives in `log.zig` (re-exported here for import stability).

const std = @import("std");
const plumbing = @import("plumbing");
const objpkg = @import("object");
const storer = @import("storer");
const memory = @import("memory");
const revision = @import("revision");
const log_mod = @import("log.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const HexSize = plumbing.HexSize;
const MaxHexSize = plumbing.MaxHexSize;
const ObjectType = plumbing.ObjectType;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;

// Re-export log surface (go-git `Log` / `LogOptions` / `LogOrder`).
pub const LogOrder = log_mod.LogOrder;
pub const LogOptions = log_mod.LogOptions;
pub const LogResult = log_mod.LogResult;
pub const log = log_mod.log;

// ---------------------------------------------------------------------------
// Facade free functions
// ---------------------------------------------------------------------------

// --- Object getters ---

/// go-git `CommitObject`. Caller owns `*Commit` (`deinit` + `destroy`).
pub fn commitObject(store: anytype, h: Hash) !*objpkg.Commit {
    return objpkg.getCommit(store.allocator, store, h);
}

/// go-git `BlobObject`.
pub fn blobObject(store: anytype, h: Hash) !objpkg.Blob {
    return objpkg.getBlob(store, h);
}

/// go-git `TreeObject`. Caller frees with `objpkg.freeTree`.
pub fn treeObject(store: anytype, h: Hash) !*objpkg.Tree {
    return objpkg.getTree(store.allocator, store, h);
}

/// go-git `TagObject` — annotated tags only. Caller `deinit`s the Tag.
pub fn tagObject(store: anytype, h: Hash) !objpkg.Tag {
    return objpkg.getTag(store.allocator, store, h);
}

/// go-git `Object`. Caller `deinit`s the returned value.
pub fn object(store: anytype, t: ObjectType, h: Hash) !objpkg.Object {
    const enc = try store.encodedObject(t, h);
    return objpkg.decodeObject(store.allocator, store, enc);
}

// --- Object iterators ---

/// go-git `CommitObjects` — unsorted commits in the object store.
pub fn commitObjects(store: anytype) !EncodedCommitIterFor(@TypeOf(store.*)) {
    const Storage = @TypeOf(store.*);
    const snap = try store.iterEncodedObjects(.commit);
    return EncodedCommitIterFor(Storage){
        .allocator = store.allocator,
        .storer = store,
        .snap = snap,
    };
}

/// go-git `BlobObjects`.
pub fn blobObjects(store: anytype) !BlobObjectsIterFor(@TypeOf(store.*)) {
    const Storage = @TypeOf(store.*);
    return BlobObjectsIterFor(Storage){
        .snap = try store.iterEncodedObjects(.blob),
    };
}

/// go-git `TreeObjects`.
pub fn treeObjects(store: anytype) !objpkg.TreeIter {
    return objpkg.newTreeIter(store.allocator, store);
}

/// go-git `TagObjects`.
pub fn tagObjects(store: anytype) !TagObjectsIterFor(@TypeOf(store.*)) {
    const Storage = @TypeOf(store.*);
    return TagObjectsIterFor(Storage){
        .allocator = store.allocator,
        .storer = store,
        .snap = try store.iterEncodedObjects(.tag),
    };
}

/// go-git `Objects`.
pub fn objects(store: anytype) !ObjectsIterFor(@TypeOf(store.*)) {
    const Storage = @TypeOf(store.*);
    return ObjectsIterFor(Storage){
        .allocator = store.allocator,
        .storer = store,
        .snap = try store.iterEncodedObjects(.any),
    };
}

// --- Ref filters ---

/// go-git `Branches`.
pub fn branches(store: anytype) !FilteredRefIterFor(@TypeOf(store.*).ReferenceIter) {
    const Iter = @TypeOf(store.*).ReferenceIter;
    return FilteredRefIterFor(Iter).init(try store.iterReferences(), isBranchRef);
}

/// go-git `Tags` — tag *references* (lightweight or annotated).
pub fn tags(store: anytype) !FilteredRefIterFor(@TypeOf(store.*).ReferenceIter) {
    const Iter = @TypeOf(store.*).ReferenceIter;
    return FilteredRefIterFor(Iter).init(try store.iterReferences(), isTagRef);
}

/// go-git `Notes`.
pub fn notes(store: anytype) !FilteredRefIterFor(@TypeOf(store.*).ReferenceIter) {
    const Iter = @TypeOf(store.*).ReferenceIter;
    return FilteredRefIterFor(Iter).init(try store.iterReferences(), isNoteRef);
}

// --- ResolveRevision ---

/// go-git `ResolveRevision` — always resolves to a commit hash.
///
/// Supports: HEAD/branch/tag/ref expansion, full/prefix hash, `~`/`^`
/// parent walks, and `^{/pattern}` message search (literal / simple
/// substring; full RE2 is not required for the supported API).
pub fn resolveRevision(store: anytype, rev: []const u8) !Hash {
    const gpa = store.allocator;
    if (rev.len == 0) return error.ReferenceNotFound;

    var parser = revision.newParserFromString(gpa, rev);
    defer parser.deinit();
    const items = parser.parse() catch |err| switch (err) {
        error.InvalidRevision => return error.InvalidRevision,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer revision.freeRevisioners(gpa, items);

    var commit: ?*objpkg.Commit = null;
    defer if (commit) |c| {
        c.deinit();
        gpa.destroy(c);
    };

    for (items) |item| {
        switch (item) {
            .ref => |r| {
                if (commit) |old| {
                    old.deinit();
                    gpa.destroy(old);
                    commit = null;
                }

                var try_hashes: std.ArrayList(Hash) = .empty;
                defer try_hashes.deinit(gpa);

                try appendHashPrefix(store, r.name, &try_hashes);

                if (expandRef(store, r.name)) |ref| {
                    defer store.freeReference(ref);
                    try try_hashes.append(gpa, ref.hash);
                }

                var got_one = false;
                for (try_hashes.items) |h| {
                    if (commitObject(store, h)) |c| {
                        commit = c;
                        got_one = true;
                        break;
                    } else |_| {}

                    if (tagObject(store, h)) |tag| {
                        var t = tag;
                        defer t.deinit();
                        const tc = try t.commit();
                        commit = tc;
                        got_one = true;
                        break;
                    } else |_| {}
                }

                if (!got_one) return error.ReferenceNotFound;
            },
            .caret_path => |cp| {
                const cur = commit orelse return error.ReferenceNotFound;
                if (cp.depth == 0) continue;

                var parents = cur.parents();
                const c1 = parents.next() catch return error.ReferenceNotFound;
                if (cp.depth == 1) {
                    cur.deinit();
                    gpa.destroy(cur);
                    commit = c1;
                    continue;
                }
                const c2 = parents.next() catch {
                    c1.deinit();
                    gpa.destroy(c1);
                    return error.ReferenceNotFound;
                };
                c1.deinit();
                gpa.destroy(c1);
                cur.deinit();
                gpa.destroy(cur);
                commit = c2;
            },
            .tilde_path => |tp| {
                var cur = commit orelse return error.ReferenceNotFound;
                var i: i32 = 0;
                while (i < tp.depth) : (i += 1) {
                    var parents = cur.parents();
                    const next_c = parents.next() catch {
                        cur.deinit();
                        gpa.destroy(cur);
                        commit = null;
                        return error.ReferenceNotFound;
                    };
                    cur.deinit();
                    gpa.destroy(cur);
                    cur = next_c;
                }
                commit = cur;
            },
            .caret_reg => |cr| {
                const cur = commit orelse return error.ReferenceNotFound;
                // Take ownership from outer `commit` while walking.
                commit = null;
                var tip_owned = true;
                errdefer if (tip_owned) objpkg.freeCommit(gpa, cur);

                var history = try objpkg.newCommitPreorderIter(gpa, cur, null, &.{});
                defer history.deinit();

                var found: ?*objpkg.Commit = null;
                while (true) {
                    const hc = history.next() catch |err| {
                        const e: anyerror = err;
                        if (e == error.EndOfStream) break;
                        return e;
                    };
                    if (hc == cur) tip_owned = false;
                    const matches = messageMatches(hc.message, cr.pattern);
                    const ok = if (cr.negate) !matches else matches;
                    if (ok) {
                        found = hc;
                        tip_owned = false; // retained as result (or was tip)
                        break;
                    }
                    // Free every non-retained yield (including tip when it does not match).
                    objpkg.freeCommit(gpa, hc);
                }

                if (found) |fc| {
                    commit = fc;
                } else {
                    return error.NoCommitMessageMatch;
                }
            },
            .caret_type,
            .at_reflog,
            .at_checkout,
            .at_upstream,
            .at_push,
            .at_date,
            .colon_reg,
            .colon_path,
            .colon_stage_path,
            => {},
        }
    }

    const c = commit orelse return error.ReferenceNotFound;
    return c.hash;
}

// ---------------------------------------------------------------------------
// Encoded object iterators
// ---------------------------------------------------------------------------

/// Unsorted commit iterator over the object store (go-git `CommitObjects`).
pub fn EncodedCommitIterFor(comptime Storage: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        storer: *Storage,
        snap: Storage.ObjectHashIter,

        pub fn next(self: *Self) !*objpkg.Commit {
            while (true) {
                const enc = try self.snap.next();
                if (enc.object_type != .commit) continue;
                return try objpkg.decodeCommit(self.allocator, self.storer, enc);
            }
        }

        pub fn forEach(self: *Self, cb: anytype) !void {
            defer self.close();
            while (true) {
                const c = self.next() catch |err| {
                    if (err == error.EndOfStream) return;
                    return err;
                };
                defer {
                    c.deinit();
                    self.allocator.destroy(c);
                }
                @call(.auto, cb, .{c}) catch |err| {
                    const e: anyerror = err;
                    if (e == error.Stop) return;
                    return e;
                };
            }
        }

        pub fn close(self: *Self) void {
            self.snap.close();
        }

        pub fn deinit(self: *Self) void {
            self.snap.deinit();
            self.* = undefined;
        }
    };
}

pub const EncodedCommitIter = EncodedCommitIterFor(memory.Storage);

/// Blob store iterator (go-git `BlobObjects`).
pub fn BlobObjectsIterFor(comptime Storage: type) type {
    return struct {
        const Self = @This();
        snap: Storage.ObjectHashIter,

        pub fn next(self: *Self) !objpkg.Blob {
            while (true) {
                const enc = try self.snap.next();
                if (enc.object_type != .blob) continue;
                return try objpkg.decodeBlob(enc);
            }
        }

        pub fn forEach(self: *Self, cb: anytype) !void {
            defer self.close();
            while (true) {
                const b = self.next() catch |err| {
                    if (err == error.EndOfStream) return;
                    return err;
                };
                @call(.auto, cb, .{&b}) catch |err| {
                    const e: anyerror = err;
                    if (e == error.Stop) return;
                    return e;
                };
            }
        }

        pub fn close(self: *Self) void {
            self.snap.close();
        }

        pub fn deinit(self: *Self) void {
            self.snap.deinit();
            self.* = undefined;
        }
    };
}

pub const BlobObjectsIter = BlobObjectsIterFor(memory.Storage);

/// Tag store iterator (go-git `TagObjects`).
pub fn TagObjectsIterFor(comptime Storage: type) type {
    return struct {
        const Self = @This();
        allocator: Allocator,
        storer: *Storage,
        snap: Storage.ObjectHashIter,

        pub fn next(self: *Self) !objpkg.Tag {
            while (true) {
                const enc = try self.snap.next();
                if (enc.object_type != .tag) continue;
                return try objpkg.decodeTag(self.allocator, self.storer, enc);
            }
        }

        pub fn forEach(self: *Self, cb: anytype) !void {
            defer self.close();
            while (true) {
                var t = self.next() catch |err| {
                    if (err == error.EndOfStream) return;
                    return err;
                };
                defer t.deinit();
                @call(.auto, cb, .{&t}) catch |err| {
                    const e: anyerror = err;
                    if (e == error.Stop) return;
                    return e;
                };
            }
        }

        pub fn close(self: *Self) void {
            self.snap.close();
        }

        pub fn deinit(self: *Self) void {
            self.snap.deinit();
            self.* = undefined;
        }
    };
}

pub const TagObjectsIter = TagObjectsIterFor(memory.Storage);

/// Object store iterator (go-git `Objects`).
pub fn ObjectsIterFor(comptime Storage: type) type {
    return struct {
        const Self = @This();
        allocator: Allocator,
        storer: *Storage,
        snap: Storage.ObjectHashIter,

        pub fn next(self: *Self) !objpkg.Object {
            while (true) {
                const enc = try self.snap.next();
                const obj = objpkg.decodeObject(self.allocator, self.storer, enc) catch |err| {
                    const e: anyerror = err;
                    if (e == error.InvalidType) continue;
                    return e;
                };
                return obj;
            }
        }

        pub fn forEach(self: *Self, cb: anytype) !void {
            defer self.close();
            while (true) {
                var obj = self.next() catch |err| {
                    const e: anyerror = err;
                    if (e == error.EndOfStream) return;
                    return e;
                };
                const cb_result = cb(&obj);
                obj.deinit(self.allocator);
                cb_result catch |err| {
                    const e: anyerror = err;
                    if (e == error.Stop) return;
                    return e;
                };
            }
        }

        pub fn close(self: *Self) void {
            self.snap.close();
        }

        pub fn deinit(self: *Self) void {
            self.snap.deinit();
            self.* = undefined;
        }
    };
}

pub const ObjectsIter = ObjectsIterFor(memory.Storage);

// ---------------------------------------------------------------------------
// Filtered reference iterators (Branches / Tags / Notes)
// ---------------------------------------------------------------------------

fn isBranchRef(r: Reference) bool {
    return r.name.isBranch();
}
fn isTagRef(r: Reference) bool {
    return r.name.isTag();
}
fn isNoteRef(r: Reference) bool {
    return r.name.isNote();
}

/// Filtered view over a backend reference iterator.
pub fn FilteredRefIterFor(comptime Iter: type) type {
    return struct {
        const Self = @This();

        inner: Iter,
        filter: *const fn (Reference) bool,

        pub fn init(inner: Iter, filter: *const fn (Reference) bool) Self {
            return .{ .inner = inner, .filter = filter };
        }

        pub fn next(self: *Self) !Reference {
            while (true) {
                const r = try self.inner.next();
                if (self.filter(r)) return r;
            }
        }

        pub fn forEach(self: *Self, cb: anytype) !void {
            defer self.close();
            while (true) {
                const r = self.next() catch |err| switch (err) {
                    error.EndOfStream => return,
                };
                @call(.auto, cb, .{r}) catch |err| {
                    const e: anyerror = err;
                    if (e == error.Stop) return;
                    return e;
                };
            }
        }

        pub fn close(self: *Self) void {
            if (comptime @hasDecl(Iter, "close")) self.inner.close();
        }

        pub fn deinit(self: *Self) void {
            self.inner.deinit();
            self.* = undefined;
        }
    };
}

pub const FilteredRefIter = FilteredRefIterFor(memory.ReferenceSliceIter);

// ---------------------------------------------------------------------------
// Helpers — expand_ref, expandPartialHash
// ---------------------------------------------------------------------------

/// go-git `expand_ref` — try `RefRevParseRules` until one resolves.
///
/// Rules mirror `plumbing.ref_rev_parse_rules`. Each format is a separate
/// `bufPrint` call so the format string is comptime-known.
fn expandRef(s: anytype, short: []const u8) ?Reference {
    if (resolveName(s, short)) |r| return r;

    var name_buf: [256]u8 = undefined;
    if (tryResolveFmt(s, &name_buf, "refs/{s}", short)) |r| return r;
    if (tryResolveFmt(s, &name_buf, "refs/tags/{s}", short)) |r| return r;
    if (tryResolveFmt(s, &name_buf, "refs/heads/{s}", short)) |r| return r;
    if (tryResolveFmt(s, &name_buf, "refs/remotes/{s}", short)) |r| return r;
    if (tryResolveFmt(s, &name_buf, "refs/remotes/{s}/HEAD", short)) |r| return r;
    return null;
}

fn resolveName(s: anytype, name_str: []const u8) ?Reference {
    const name = ReferenceName.init(name_str);
    return resolveBackendReference(s, name) catch null;
}

fn tryResolveFmt(
    s: anytype,
    buf: []u8,
    comptime fmt: []const u8,
    short: []const u8,
) ?Reference {
    const name_str = std.fmt.bufPrint(buf, fmt, .{short}) catch return null;
    return resolveName(s, name_str);
}

/// go-git `expandPartialHash` slow path over an encoded-object backend.
fn expandPartialHash(
    s: anytype,
    allocator: Allocator,
    prefix: []const u8,
) anyerror![]Hash {
    var list: std.ArrayList(Hash) = .empty;
    errdefer list.deinit(allocator);

    var snap = try s.iterEncodedObjects(.any);
    defer snap.deinit();

    while (true) {
        const enc = snap.next() catch |err| switch (err) {
            error.EndOfStream => break,
        };
        const h = enc.hash();
        if (prefix.len == 0 or std.mem.startsWith(u8, h.slice(), prefix)) {
            try list.append(allocator, h);
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn appendHashPrefix(s: anytype, hash_str: []const u8, out: *std.ArrayList(Hash)) !void {
    const gpa = s.allocator;
    if (hash_str.len == 0) return;

    if (hash_str.len == HexSize) {
        const h = plumbing.parseHash(hash_str) catch return;
        try out.append(gpa, h);
        return;
    }

    const even_len = hash_str.len & ~@as(usize, 1);
    if (even_len == 0) {
        const candidates = try expandPartialHash(s, gpa, &.{});
        defer gpa.free(candidates);
        for (candidates) |h| {
            var hex: [MaxHexSize]u8 = undefined;
            const str = h.string(&hex);
            if (std.mem.startsWith(u8, str, hash_str)) {
                try out.append(gpa, h);
            }
        }
        return;
    }

    var prefix_buf: [HexSize / 2]u8 = undefined;
    const even_hex = hash_str[0..even_len];
    const decoded = std.fmt.hexToBytes(prefix_buf[0 .. even_len / 2], even_hex) catch return;
    const candidates = try expandPartialHash(s, gpa, decoded);
    defer gpa.free(candidates);

    if (even_len == hash_str.len) {
        try out.appendSlice(gpa, candidates);
        return;
    }
    for (candidates) |h| {
        var hex: [MaxHexSize]u8 = undefined;
        const str = h.string(&hex);
        if (std.mem.startsWith(u8, str, hash_str)) {
            try out.append(gpa, h);
        }
    }
}

fn resolveBackendReference(store: anytype, name: ReferenceName) !Reference {
    var current = try store.reference(name);
    var recursion: usize = 0;
    while (current.type == .symbolic) {
        if (recursion > storer.MaxResolveRecursion) {
            store.freeReference(current);
            return error.MaxResolveRecursion;
        }
        const next = store.reference(current.target) catch |err| {
            store.freeReference(current);
            return err;
        };
        store.freeReference(current);
        current = next;
        recursion += 1;
    }
    return current;
}

/// Literal / simple message match for `^{/pattern}` (go-git uses RE2).
fn messageMatches(message: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0) return true;
    if (std.mem.indexOfAny(u8, pattern, ".^$*+?[](){}|\\") == null) {
        return std.mem.indexOf(u8, message, pattern) != null;
    }
    var pat = pattern;
    if (std.mem.startsWith(u8, pat, ".*")) pat = pat[2..];
    if (std.mem.endsWith(u8, pat, ".*")) {
        pat = pat[0 .. pat.len - 2];
        return std.mem.indexOf(u8, message, pat) != null;
    }
    return std.mem.indexOf(u8, message, pat) != null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn storeBlob(s: *memory.Storage, content: []const u8) !Hash {
    const obj = try s.newEncodedObject();
    errdefer s.discardEncodedObject(obj);
    obj.setType(.blob);
    _ = try obj.write(content);
    return s.setEncodedObject(obj);
}

fn storeTree(s: *memory.Storage, allocator: Allocator, blob: Hash, name: []const u8) !Hash {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "100644 ");
    try buf.appendSlice(allocator, name);
    try buf.append(allocator, 0);
    try buf.appendSlice(allocator, blob.slice());
    const obj = try s.newEncodedObject();
    errdefer s.discardEncodedObject(obj);
    obj.setType(.tree);
    _ = try obj.write(buf.items);
    return s.setEncodedObject(obj);
}

fn storeCommit(
    s: *memory.Storage,
    allocator: Allocator,
    tree: Hash,
    parents: []const Hash,
    msg: []const u8,
) !Hash {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var tree_hex: [MaxHexSize]u8 = undefined;
    try buf.appendSlice(allocator, "tree ");
    try buf.appendSlice(allocator, tree.string(&tree_hex));
    try buf.append(allocator, '\n');
    for (parents) |p| {
        var ph: [MaxHexSize]u8 = undefined;
        try buf.appendSlice(allocator, "parent ");
        try buf.appendSlice(allocator, p.string(&ph));
        try buf.append(allocator, '\n');
    }
    try buf.appendSlice(allocator, "author A <a@b> 1 +0000\n");
    try buf.appendSlice(allocator, "committer A <a@b> 1 +0000\n");
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, msg);
    const obj = try s.newEncodedObject();
    errdefer s.discardEncodedObject(obj);
    obj.setType(.commit);
    _ = try obj.write(buf.items);
    return s.setEncodedObject(obj);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "object getters after Init + manual insert" {
    const gpa = std.testing.allocator;
    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    // Manual Init shape: symbolic HEAD + objects (Init agent owns init()).
    try s.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
    const r = s;

    const blob_h = try storeBlob(s, "hello");
    const tree_h = try storeTree(s, gpa, blob_h, "hello.txt");
    const commit_h = try storeCommit(s, gpa, tree_h, &.{}, "init\n");
    try s.setReference(Reference.newHashReference(plumbing.master, commit_h));

    const blob = try blobObject(r, blob_h);
    try std.testing.expectEqualStrings("hello", blob.readerBytes());
    try std.testing.expect(blob.hash.eql(blob_h));

    const tree = try treeObject(r, tree_h);
    defer objpkg.freeTree(gpa, tree);
    try std.testing.expect(tree.hash.eql(tree_h));

    const commit = try commitObject(r, commit_h);
    defer {
        commit.deinit();
        gpa.destroy(commit);
    }
    try std.testing.expect(commit.hash.eql(commit_h));
    try std.testing.expectEqualStrings("init\n", commit.message);

    var obj = try object(r, .commit, commit_h);
    defer obj.deinit(gpa);
    try std.testing.expect(obj.id().eql(commit_h));
    try std.testing.expect(obj.objectType() == .commit);

    var cit = try commitObjects(r);
    defer cit.deinit();
    var found: usize = 0;
    while (true) {
        const c = cit.next() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        defer {
            c.deinit();
            gpa.destroy(c);
        }
        found += 1;
        try std.testing.expect(c.hash.eql(commit_h));
    }
    try std.testing.expectEqual(@as(usize, 1), found);

    var bit = try blobObjects(r);
    defer bit.deinit();
    const b2 = try bit.next();
    try std.testing.expect(b2.hash.eql(blob_h));

    var tit = try treeObjects(r);
    defer tit.deinit();
    const t2 = try tit.next();
    defer objpkg.freeTree(gpa, t2);
    try std.testing.expect(t2.hash.eql(tree_h));
}

test "resolveRevision HEAD and simple refs" {
    const gpa = std.testing.allocator;
    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    try s.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
    const r = s;

    const blob_h = try storeBlob(s, "x");
    const tree_h = try storeTree(s, gpa, blob_h, "x.txt");
    const c0 = try storeCommit(s, gpa, tree_h, &.{}, "root\n");
    const c1 = try storeCommit(s, gpa, tree_h, &.{c0}, "child\n");
    try s.setReference(Reference.newHashReference(plumbing.master, c1));
    try s.setReference(Reference.newHashReference(
        ReferenceName.init("refs/tags/v1"),
        c1,
    ));

    const head_h = try resolveRevision(r, "HEAD");
    try std.testing.expect(head_h.eql(c1));

    const master_h = try resolveRevision(r, "master");
    try std.testing.expect(master_h.eql(c1));

    const full_ref = try resolveRevision(r, "refs/heads/master");
    try std.testing.expect(full_ref.eql(c1));

    const tag_h = try resolveRevision(r, "v1");
    try std.testing.expect(tag_h.eql(c1));

    var hex: [MaxHexSize]u8 = undefined;
    const full = c0.string(&hex);
    const by_hash = try resolveRevision(r, full);
    try std.testing.expect(by_hash.eql(c0));

    const prefix = full[0..7];
    const by_prefix = try resolveRevision(r, prefix);
    try std.testing.expect(by_prefix.eql(c0));

    const parent = try resolveRevision(r, "HEAD~1");
    try std.testing.expect(parent.eql(c0));

    const caret = try resolveRevision(r, "HEAD^");
    try std.testing.expect(caret.eql(c0));

    var br = try branches(
        r,
    );
    defer br.deinit();
    const bref = try br.next();
    try std.testing.expect(bref.name.isBranch());
    try std.testing.expect(bref.hash.eql(c1));

    var tg = try tags(
        r,
    );
    defer tg.deinit();
    const tref = try tg.next();
    try std.testing.expect(tref.name.isTag());
}

test "resolveRevision empty is ReferenceNotFound" {
    const gpa = std.testing.allocator;
    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
    const r = s;
    try std.testing.expectError(error.ReferenceNotFound, resolveRevision(r, ""));
}
