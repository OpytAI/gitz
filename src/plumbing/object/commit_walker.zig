//! Commit history walkers (go-git `commit_walker.go`, `commit_walker_bfs.go`).
//!
//! Concrete iterators: pre-order DFS, post-order DFS, and BFS.
//! `CommitIter` is a type-erased handle (go-git `CommitIter` interface).
//!
//! # `commit.zig` surface used here
//!
//! | Symbol | Role |
//! |--------|------|
//! | `Commit.hash` | object id |
//! | `Commit.parent_hashes` | `[]Hash` parent OIDs |
//! | `Commit.storer` | `?ObjectGetter` (go-git unexported `s`) |
//! | `Commit.allocator` | allocator for parent loads |
//! | `getCommit(allocator, s, hash)` | `!*Commit` |
//!
//! Production walkers load parents via `getCommit` and `c.storer`.
//! Unit tests inject a `CommitLoader` over an in-memory hash → `*Commit` map.
//!
//! # go-git map
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `NewCommitPreorderIter` | `newCommitPreorderIter` |
//! | `NewCommitPostorderIter` | `newCommitPostorderIter` |
//! | `NewCommitIterBSF` | `newCommitIterBsf` |
//! | `CommitIter` | `CommitIter` (type-erased) |
//! | `io.EOF` | `error.EndOfStream` |
//! | `storer.ErrStop` | `error.Stop` |

const std = @import("std");
const plumbing = @import("plumbing");
const storer_mod = @import("storer");

const commit_mod = @import("commit.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Commit = commit_mod.Commit;
const ObjectGetter = storer_mod.ObjectGetter;

// ---------------------------------------------------------------------------
// Hash set (seen / ignore / seenExternal)
// ---------------------------------------------------------------------------

/// Set of commit hashes (go-git `map[plumbing.Hash]bool`).
pub const HashSet = std.AutoHashMapUnmanaged(Hash, void);

fn hashSetContains(set: *const HashSet, h: Hash) bool {
    return set.get(h) != null;
}

fn hashSetPut(set: *HashSet, allocator: Allocator, h: Hash) Allocator.Error!void {
    try set.put(allocator, h, {});
}

// ---------------------------------------------------------------------------
// CommitLoader — parent resolution (go-git GetCommit / Parents)
// ---------------------------------------------------------------------------

/// Loads a commit by hash (go-git `GetCommit` / storer path).
pub const CommitLoader = struct {
    ptr: *anyopaque,
    get_fn: *const fn (ptr: *anyopaque, h: Hash) anyerror!*Commit,

    pub fn get(self: CommitLoader, h: Hash) anyerror!*Commit {
        return self.get_fn(self.ptr, h);
    }
};

/// Load via ObjectGetter, storing the getter by value on the Commit
/// (same as commit.zig `getCommitWithGetter`; avoids wrapping a stack `*ObjectGetter`).
fn getCommitFromGetter(allocator: Allocator, getter: ObjectGetter, h: Hash) !*Commit {
    const o = try getter.encodedObject(.commit, h);
    const c = try allocator.create(Commit);
    errdefer {
        c.deinit();
        allocator.destroy(c);
    }
    c.* = Commit.init(allocator);
    c.storer = getter;
    try c.decode(o);
    return c;
}

/// Default loader: `GetCommit` through `c.storer` (go-git `GetCommit(c.s, h)`).
fn loaderFromCommit(c: *Commit) CommitLoader {
    const Gen = struct {
        fn get(ptr: *anyopaque, h: Hash) anyerror!*Commit {
            const base: *Commit = @ptrCast(@alignCast(ptr));
            const getter = base.storer orelse return error.ObjectNotFound;
            return getCommitFromGetter(base.allocator, getter, h);
        }
    };
    return .{
        .ptr = c,
        .get_fn = Gen.get,
    };
}

fn loadCommit(loader: CommitLoader, h: Hash) anyerror!*Commit {
    return loader.get(h);
}

// ---------------------------------------------------------------------------
// CommitIter (go-git interface)
// ---------------------------------------------------------------------------

/// Type-erased closable commit iterator (go-git `CommitIter`).
pub const CommitIter = struct {
    ptr: *anyopaque,
    next_fn: *const fn (ptr: *anyopaque) anyerror!*Commit,
    close_fn: *const fn (ptr: *anyopaque) void,

    pub fn next(self: CommitIter) anyerror!*Commit {
        return self.next_fn(self.ptr);
    }

    pub fn close(self: CommitIter) void {
        self.close_fn(self.ptr);
    }

    /// go-git `CommitIter.ForEach`. `error.Stop` ends successfully.
    pub fn forEach(self: CommitIter, cb: anytype) !void {
        defer self.close();
        while (true) {
            const c = self.next() catch |err| {
                const e: anyerror = err;
                if (e == error.EndOfStream) return;
                return e;
            };
            cb(c) catch |err| {
                const e: anyerror = err;
                if (e == error.Stop) return;
                return e;
            };
        }
    }
};

fn forEachCommit(iter: anytype, cb: anytype) !void {
    defer iter.close();
    while (true) {
        const c = iter.next() catch |err| {
            const e: anyerror = err;
            if (e == error.EndOfStream) return;
            return e;
        };
        cb(c) catch |err| {
            const e: anyerror = err;
            if (e == error.Stop) return;
            return e;
        };
    }
}

// ---------------------------------------------------------------------------
// Parent hash iterator (go-git filteredParentIter / NewCommitIter subset)
// ---------------------------------------------------------------------------

/// Iterates parent commits by hash via `CommitLoader`.
const ParentHashIter = struct {
    loader: CommitLoader,
    hashes: []const Hash,
    pos: usize = 0,

    fn next(self: *ParentHashIter) anyerror!*Commit {
        if (self.pos >= self.hashes.len) return error.EndOfStream;
        const h = self.hashes[self.pos];
        self.pos += 1;
        return loadCommit(self.loader, h);
    }

    fn close(self: *ParentHashIter) void {
        self.pos = self.hashes.len;
    }

    fn asIter(self: *ParentHashIter) CommitIter {
        return .{
            .ptr = self,
            .next_fn = nextThunk,
            .close_fn = closeThunk,
        };
    }

    fn nextThunk(ptr: *anyopaque) anyerror!*Commit {
        const self: *ParentHashIter = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn closeThunk(ptr: *anyopaque) void {
        const self: *ParentHashIter = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// Parent hashes of `c` not already in `seen` (go-git `filteredParentIter` filter).
fn filteredParentHashes(
    allocator: Allocator,
    c: *const Commit,
    seen: *const HashSet,
) Allocator.Error![]Hash {
    var list: std.ArrayList(Hash) = .empty;
    errdefer list.deinit(allocator);
    for (c.parent_hashes) |h| {
        if (!hashSetContains(seen, h)) {
            try list.append(allocator, h);
        }
    }
    return try list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Preorder (go-git commitPreIterator / NewCommitPreorderIter)
// ---------------------------------------------------------------------------

/// Pre-order history walk (go-git `commitPreIterator`).
pub const PreorderIter = struct {
    allocator: Allocator,
    loader: CommitLoader,
    seen_external: ?*const HashSet,
    seen: HashSet = .empty,
    /// Stack of parent iterators (go-git `stack []CommitIter`).
    stack: std.ArrayList(StackEntry) = .empty,
    start: ?*Commit,

    const StackEntry = struct {
        iter: ParentHashIter,
        hashes_owned: []Hash,
    };

    pub fn deinit(self: *PreorderIter) void {
        self.close();
        self.seen.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        self.* = undefined;
    }

    /// go-git `commitPreIterator.Next`.
    pub fn next(self: *PreorderIter) anyerror!*Commit {
        while (true) {
            const c = try self.nextCandidate();
            if (hashSetContains(&self.seen, c.hash)) continue;
            if (self.seen_external) |ext| {
                if (hashSetContains(ext, c.hash)) continue;
            }

            try hashSetPut(&self.seen, self.allocator, c.hash);

            if (c.numParents() > 0) {
                try self.pushFilteredParents(c);
            }
            return c;
        }
    }

    fn nextCandidate(self: *PreorderIter) anyerror!*Commit {
        if (self.start) |c| {
            self.start = null;
            return c;
        }
        while (self.stack.items.len > 0) {
            const idx = self.stack.items.len - 1;
            const c = self.stack.items[idx].iter.next() catch |err| {
                const e: anyerror = err;
                if (e == error.EndOfStream) {
                    self.popStack();
                    continue;
                }
                return e;
            };
            return c;
        }
        return error.EndOfStream;
    }

    fn pushFilteredParents(self: *PreorderIter, c: *Commit) !void {
        const hashes = try filteredParentHashes(self.allocator, c, &self.seen);
        errdefer self.allocator.free(hashes);
        try self.stack.append(self.allocator, .{
            .iter = .{
                .loader = self.loader,
                .hashes = hashes,
            },
            .hashes_owned = hashes,
        });
    }

    fn popStack(self: *PreorderIter) void {
        var entry = self.stack.pop().?;
        entry.iter.close(); // mut
        self.allocator.free(entry.hashes_owned);
    }

    pub fn forEach(self: *PreorderIter, cb: anytype) !void {
        return forEachCommit(self, cb);
    }

    pub fn close(self: *PreorderIter) void {
        while (self.stack.items.len > 0) {
            self.popStack();
        }
        self.start = null;
    }

    pub fn asIter(self: *PreorderIter) CommitIter {
        return .{
            .ptr = self,
            .next_fn = nextThunk,
            .close_fn = closeThunk,
        };
    }

    fn nextThunk(ptr: *anyopaque) anyerror!*Commit {
        const self: *PreorderIter = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn closeThunk(ptr: *anyopaque) void {
        const self: *PreorderIter = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// go-git `NewCommitPreorderIter`.
///
/// `allocator` is required in Zig (go-git uses GC for maps/stack).
/// `seen_external` may be null. `ignore` hashes are pre-marked seen.
pub fn newCommitPreorderIter(
    allocator: Allocator,
    c: *Commit,
    seen_external: ?*const HashSet,
    ignore: []const Hash,
) Allocator.Error!PreorderIter {
    return newCommitPreorderIterWithLoader(allocator, c, loaderFromCommit(c), seen_external, ignore);
}

/// Like `newCommitPreorderIter` with an explicit parent loader (unit tests).
pub fn newCommitPreorderIterWithLoader(
    allocator: Allocator,
    c: *Commit,
    loader: CommitLoader,
    seen_external: ?*const HashSet,
    ignore: []const Hash,
) Allocator.Error!PreorderIter {
    var iter = PreorderIter{
        .allocator = allocator,
        .loader = loader,
        .seen_external = seen_external,
        .start = c,
    };
    for (ignore) |h| {
        try hashSetPut(&iter.seen, allocator, h);
    }
    return iter;
}

// ---------------------------------------------------------------------------
// Postorder (go-git commitPostIterator / NewCommitPostorderIter)
// ---------------------------------------------------------------------------

/// Post-order history walk (go-git `commitPostIterator`).
///
/// Matches go-git: pop node, mark seen, push parents, return node (tip-first).
pub const PostorderIter = struct {
    allocator: Allocator,
    loader: CommitLoader,
    stack: std.ArrayList(*Commit) = .empty,
    seen: HashSet = .empty,

    pub fn deinit(self: *PostorderIter) void {
        self.close();
        self.seen.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn next(self: *PostorderIter) anyerror!*Commit {
        while (true) {
            if (self.stack.items.len == 0) return error.EndOfStream;

            const c = self.stack.pop().?;
            if (hashSetContains(&self.seen, c.hash)) continue;

            try hashSetPut(&self.seen, self.allocator, c.hash);

            // go-git: c.Parents().ForEach(append to stack)
            for (c.parent_hashes) |h| {
                const p = try loadCommit(self.loader, h);
                try self.stack.append(self.allocator, p);
            }
            return c;
        }
    }

    pub fn forEach(self: *PostorderIter, cb: anytype) !void {
        return forEachCommit(self, cb);
    }

    pub fn close(self: *PostorderIter) void {
        self.stack.clearRetainingCapacity();
    }

    pub fn asIter(self: *PostorderIter) CommitIter {
        return .{
            .ptr = self,
            .next_fn = nextThunk,
            .close_fn = closeThunk,
        };
    }

    fn nextThunk(ptr: *anyopaque) anyerror!*Commit {
        const self: *PostorderIter = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn closeThunk(ptr: *anyopaque) void {
        const self: *PostorderIter = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// go-git `NewCommitPostorderIter`.
pub fn newCommitPostorderIter(
    allocator: Allocator,
    c: *Commit,
    ignore: []const Hash,
) Allocator.Error!PostorderIter {
    return newCommitPostorderIterWithLoader(allocator, c, loaderFromCommit(c), ignore);
}

/// Like `newCommitPostorderIter` with an explicit parent loader (unit tests).
pub fn newCommitPostorderIterWithLoader(
    allocator: Allocator,
    c: *Commit,
    loader: CommitLoader,
    ignore: []const Hash,
) Allocator.Error!PostorderIter {
    var iter = PostorderIter{
        .allocator = allocator,
        .loader = loader,
    };
    for (ignore) |h| {
        try hashSetPut(&iter.seen, allocator, h);
    }
    try iter.stack.append(allocator, c);
    return iter;
}

// ---------------------------------------------------------------------------
// BFS (go-git bfsCommitIterator / NewCommitIterBSF)
// ---------------------------------------------------------------------------

/// Breadth-first history walk (go-git `bfsCommitIterator`).
pub const BfsIter = struct {
    allocator: Allocator,
    loader: CommitLoader,
    seen_external: ?*const HashSet,
    seen: HashSet = .empty,
    queue: std.ArrayList(*Commit) = .empty,

    pub fn deinit(self: *BfsIter) void {
        self.close();
        self.seen.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.* = undefined;
    }

    fn appendHash(self: *BfsIter, h: Hash) !void {
        if (hashSetContains(&self.seen, h)) return;
        if (self.seen_external) |ext| {
            if (hashSetContains(ext, h)) return;
        }
        const c = try loadCommit(self.loader, h);
        try self.queue.append(self.allocator, c);
    }

    pub fn next(self: *BfsIter) anyerror!*Commit {
        while (true) {
            if (self.queue.items.len == 0) return error.EndOfStream;

            const c = self.queue.orderedRemove(0);
            if (hashSetContains(&self.seen, c.hash)) continue;
            if (self.seen_external) |ext| {
                if (hashSetContains(ext, c.hash)) continue;
            }

            try hashSetPut(&self.seen, self.allocator, c.hash);

            for (c.parent_hashes) |h| {
                try self.appendHash(h);
            }
            return c;
        }
    }

    pub fn forEach(self: *BfsIter, cb: anytype) !void {
        return forEachCommit(self, cb);
    }

    pub fn close(self: *BfsIter) void {
        self.queue.clearRetainingCapacity();
    }

    pub fn asIter(self: *BfsIter) CommitIter {
        return .{
            .ptr = self,
            .next_fn = nextThunk,
            .close_fn = closeThunk,
        };
    }

    fn nextThunk(ptr: *anyopaque) anyerror!*Commit {
        const self: *BfsIter = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn closeThunk(ptr: *anyopaque) void {
        const self: *BfsIter = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// go-git `NewCommitIterBSF`.
pub fn newCommitIterBsf(
    allocator: Allocator,
    c: *Commit,
    seen_external: ?*const HashSet,
    ignore: []const Hash,
) Allocator.Error!BfsIter {
    return newCommitIterBsfWithLoader(allocator, c, loaderFromCommit(c), seen_external, ignore);
}

/// Like `newCommitIterBsf` with an explicit parent loader (unit tests).
pub fn newCommitIterBsfWithLoader(
    allocator: Allocator,
    c: *Commit,
    loader: CommitLoader,
    seen_external: ?*const HashSet,
    ignore: []const Hash,
) Allocator.Error!BfsIter {
    var iter = BfsIter{
        .allocator = allocator,
        .loader = loader,
        .seen_external = seen_external,
    };
    for (ignore) |h| {
        try hashSetPut(&iter.seen, allocator, h);
    }
    try iter.queue.append(allocator, c);
    return iter;
}

// ---------------------------------------------------------------------------
// Unit tests — small in-memory commit chain (no encode/decode)
// ---------------------------------------------------------------------------

const TestGraph = struct {
    map: std.AutoHashMap(Hash, *Commit),

    fn init(allocator: Allocator) TestGraph {
        return .{ .map = std.AutoHashMap(Hash, *Commit).init(allocator) };
    }

    fn deinit(self: *TestGraph) void {
        self.map.deinit();
    }

    fn put(self: *TestGraph, c: *Commit) !void {
        try self.map.put(c.hash, c);
    }

    fn loader(self: *TestGraph) CommitLoader {
        const Gen = struct {
            fn get(ptr: *anyopaque, h: Hash) anyerror!*Commit {
                const g: *TestGraph = @ptrCast(@alignCast(ptr));
                return g.map.get(h) orelse error.ObjectNotFound;
            }
        };
        return .{
            .ptr = self,
            .get_fn = Gen.get,
        };
    }
};

/// Deterministic non-git test OID from a single byte.
fn testHash(b: u8) Hash {
    var bytes: [plumbing.Size]u8 = .{0} ** plumbing.Size;
    bytes[0] = b;
    return Hash.fromBytes(bytes);
}

fn makeCommit(allocator: Allocator, hash: Hash, parents: []const Hash) !Commit {
    var c = Commit.init(allocator);
    errdefer c.deinit();
    c.hash = hash;
    if (parents.len > 0) {
        c.parent_hashes = try allocator.dupe(Hash, parents);
    }
    return c;
}

test "preorder linear chain C1→C2→C3" {
    // Preorder parent loads use shared test graph; skip strict leak gate for walkers.
    const gpa = std.testing.allocator;

    const h1 = testHash(1);
    const h2 = testHash(2);
    const h3 = testHash(3);

    var c3 = try makeCommit(gpa, h3, &.{});
    defer c3.deinit();
    var c2 = try makeCommit(gpa, h2, &.{h3});
    defer c2.deinit();
    var c1 = try makeCommit(gpa, h1, &.{h2});
    defer c1.deinit();

    var graph = TestGraph.init(gpa);
    defer graph.deinit();
    try graph.put(&c1);
    try graph.put(&c2);
    try graph.put(&c3);

    var iter = try newCommitPreorderIterWithLoader(gpa, &c1, graph.loader(), null, &.{});
    defer iter.deinit();

    try std.testing.expect((try iter.next()).hash.eql(h1));
    try std.testing.expect((try iter.next()).hash.eql(h2));
    try std.testing.expect((try iter.next()).hash.eql(h3));
    try std.testing.expectError(error.EndOfStream, iter.next());
}

test "bfs linear chain C1→C2→C3" {
    // Preorder parent loads use shared test graph; skip strict leak gate for walkers.
    const gpa = std.testing.allocator;

    const h1 = testHash(1);
    const h2 = testHash(2);
    const h3 = testHash(3);

    var c3 = try makeCommit(gpa, h3, &.{});
    defer c3.deinit();
    var c2 = try makeCommit(gpa, h2, &.{h3});
    defer c2.deinit();
    var c1 = try makeCommit(gpa, h1, &.{h2});
    defer c1.deinit();

    var graph = TestGraph.init(gpa);
    defer graph.deinit();
    try graph.put(&c1);
    try graph.put(&c2);
    try graph.put(&c3);

    var iter = try newCommitIterBsfWithLoader(gpa, &c1, graph.loader(), null, &.{});
    defer iter.deinit();

    try std.testing.expect((try iter.next()).hash.eql(h1));
    try std.testing.expect((try iter.next()).hash.eql(h2));
    try std.testing.expect((try iter.next()).hash.eql(h3));
    try std.testing.expectError(error.EndOfStream, iter.next());
}

test "postorder linear chain visits all" {
    // Preorder parent loads use shared test graph; skip strict leak gate for walkers.
    const gpa = std.testing.allocator;

    const h1 = testHash(1);
    const h2 = testHash(2);
    const h3 = testHash(3);

    var c3 = try makeCommit(gpa, h3, &.{});
    defer c3.deinit();
    var c2 = try makeCommit(gpa, h2, &.{h3});
    defer c2.deinit();
    var c1 = try makeCommit(gpa, h1, &.{h2});
    defer c1.deinit();

    var graph = TestGraph.init(gpa);
    defer graph.deinit();
    try graph.put(&c1);
    try graph.put(&c2);
    try graph.put(&c3);

    var iter = try newCommitPostorderIterWithLoader(gpa, &c1, graph.loader(), &.{});
    defer iter.deinit();

    var count: usize = 0;
    while (true) {
        _ = iter.next() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "preorder ignore skips commit and its history" {
    // Preorder parent loads use shared test graph; skip strict leak gate for walkers.
    const gpa = std.testing.allocator;

    const h1 = testHash(1);
    const h2 = testHash(2);
    const h3 = testHash(3);

    var c3 = try makeCommit(gpa, h3, &.{});
    defer c3.deinit();
    var c2 = try makeCommit(gpa, h2, &.{h3});
    defer c2.deinit();
    var c1 = try makeCommit(gpa, h1, &.{h2});
    defer c1.deinit();

    var graph = TestGraph.init(gpa);
    defer graph.deinit();
    try graph.put(&c1);
    try graph.put(&c2);
    try graph.put(&c3);

    const ignore = [_]Hash{h2};
    var iter = try newCommitPreorderIterWithLoader(gpa, &c1, graph.loader(), null, &ignore);
    defer iter.deinit();

    try std.testing.expect((try iter.next()).hash.eql(h1));
    try std.testing.expectError(error.EndOfStream, iter.next());
}

test "preorder forEach Stop" {
    // Preorder parent loads use shared test graph; skip strict leak gate for walkers.
    const gpa = std.testing.allocator;

    const h1 = testHash(1);
    const h2 = testHash(2);

    var c2 = try makeCommit(gpa, h2, &.{});
    defer c2.deinit();
    var c1 = try makeCommit(gpa, h1, &.{h2});
    defer c1.deinit();

    var graph = TestGraph.init(gpa);
    defer graph.deinit();
    try graph.put(&c1);
    try graph.put(&c2);

    var iter = try newCommitPreorderIterWithLoader(gpa, &c1, graph.loader(), null, &.{});
    defer iter.deinit();

    var count: usize = 0;
    const Gen = struct {
        var n: *usize = undefined;
        fn cb(_: *Commit) !void {
            n.* += 1;
            return error.Stop;
        }
    };
    Gen.n = &count;
    try iter.forEach(Gen.cb);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "CommitIter type erase preorder" {
    // Preorder parent loads use shared test graph; skip strict leak gate for walkers.
    const gpa = std.testing.allocator;

    const h1 = testHash(1);
    var c1 = try makeCommit(gpa, h1, &.{});
    defer c1.deinit();

    var graph = TestGraph.init(gpa);
    defer graph.deinit();
    try graph.put(&c1);

    var iter = try newCommitPreorderIterWithLoader(gpa, &c1, graph.loader(), null, &.{});
    defer iter.deinit();

    const erased = iter.asIter();
    try std.testing.expect((try erased.next()).hash.eql(h1));
    try std.testing.expectError(error.EndOfStream, erased.next());
}

test "merge commit preorder visits both parents once" {
    // Preorder parent loads use shared test graph; skip strict leak gate for walkers.
    const gpa = std.testing.allocator;

    //   C1 (merge)
    //   |  \
    //   C2  C3
    //    \  /
    //     C4
    const h1 = testHash(1);
    const h2 = testHash(2);
    const h3 = testHash(3);
    const h4 = testHash(4);

    var c4 = try makeCommit(gpa, h4, &.{});
    defer c4.deinit();
    var c3 = try makeCommit(gpa, h3, &.{h4});
    defer c3.deinit();
    var c2 = try makeCommit(gpa, h2, &.{h4});
    defer c2.deinit();
    var c1 = try makeCommit(gpa, h1, &.{ h2, h3 });
    defer c1.deinit();

    var graph = TestGraph.init(gpa);
    defer graph.deinit();
    try graph.put(&c1);
    try graph.put(&c2);
    try graph.put(&c3);
    try graph.put(&c4);

    var iter = try newCommitPreorderIterWithLoader(gpa, &c1, graph.loader(), null, &.{});
    defer iter.deinit();

    var seen_count: usize = 0;
    while (true) {
        _ = iter.next() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        seen_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), seen_count);
}
