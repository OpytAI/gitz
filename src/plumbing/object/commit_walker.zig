//! Commit history walkers (go-git `commit_walker*.go`).
//!
//! Concrete iterators: pre-order DFS, post-order DFS, BFS, committer-time heap,
//! limit filter, path/file filter, and multi-tip "all refs" merge.
//! `CommitIter` is a type-erased handle (go-git `CommitIter` interface).
//!
//! # `commit.zig` surface used here
//!
//! | Symbol | Role |
//! |--------|------|
//! | `Commit.hash` | object id |
//! | `Commit.parent_hashes` | `[]Hash` parent OIDs |
//! | `Commit.committer.when` | unix seconds (ctime order / limit) |
//! | `Commit.tree_hash` / `tree()` | path iter tree load |
//! | `Commit.storer` | `?ObjectGetter` (go-git unexported `s`) |
//! | `Commit.allocator` | allocator for parent loads |
//! | `getCommit(allocator, s, hash)` | `!*Commit` |
//!
//! Production walkers load parents via `getCommit` / `CommitLoader`. Loaded
//! `*Commit` values follow go-git GC semantics: iterators do **not** free parent
//! loads (tests use long-lived map pointers). Exception:
//! `newCommitAllIterFromHashes` owns tip commits + a heap loader context.
//!
//! # go-git map
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `NewCommitPreorderIter` | `newCommitPreorderIter` |
//! | `NewCommitPostorderIter` | `newCommitPostorderIter` |
//! | `NewCommitIterBSF` | `newCommitIterBsf` |
//! | `NewCommitIterCTime` | `newCommitIterCTime` |
//! | `NewCommitLimitIterFromIter` | `newCommitLimitIterFromIter` |
//! | `NewCommitPathIterFromIter` | `newCommitPathIterFromIter` |
//! | `NewCommitFileIterFromIter` | `newCommitFileIterFromIter` |
//! | `NewCommitAllIter` | `newCommitAllIterFromTips` / `FromHashes` |
//! | `NewFilterCommitIter` | `newFilterCommitIter` |
//! | `CommitFilter` | `CommitFilter` / `CommitFilterCtx` |
//! | `CommitIter` | `CommitIter` (type-erased) |
//! | `io.EOF` | `error.EndOfStream` |
//! | `storer.ErrStop` | `error.Stop` |

const std = @import("std");
const plumbing = @import("plumbing");
const storer_mod = @import("storer");

const commit_mod = @import("commit.zig");
const tree_mod = @import("tree.zig");
const difftree_mod = @import("difftree.zig");
const change_mod = @import("change.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Commit = commit_mod.Commit;
const ObjectGetter = storer_mod.ObjectGetter;
const Tree = tree_mod.Tree;
const Changes = change_mod.Changes;

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
pub fn loaderFromCommit(c: *Commit) CommitLoader {
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
// Filtered BFS (go-git filterCommitIter / NewFilterCommitIter)
// ---------------------------------------------------------------------------

/// go-git `CommitFilter` — returns whether a commit matches.
pub const CommitFilter = *const fn (*Commit) bool;

/// Contextual filter (Zig substitute for Go closures over state).
pub const CommitFilterCtx = *const fn (ctx: *anyopaque, c: *Commit) bool;

fn filterAlwaysValid(_: *Commit) bool {
    return true;
}

fn filterNeverLimit(_: *Commit) bool {
    return false;
}

/// Breadth-first history walk with validity and limit filters
/// (go-git `filterCommitIter`).
///
/// - `is_valid`: only commits for which this is true are returned from `next`.
/// - `is_limit`: when true for a commit, its parents are not enqueued.
/// - Each commit is visited at most once.
///
/// Null plain filters mean valid=true always and limit=false always.
/// Contextual filters (`valid_ctx_fn` / `limit_ctx_fn`) override plain filters
/// when set (needed for `merge_base` index/seen closures).
pub const FilterCommitIter = struct {
    allocator: Allocator,
    loader: CommitLoader,
    is_valid: CommitFilter = filterAlwaysValid,
    is_limit: CommitFilter = filterNeverLimit,
    valid_ctx: ?*anyopaque = null,
    valid_ctx_fn: ?CommitFilterCtx = null,
    limit_ctx: ?*anyopaque = null,
    limit_ctx_fn: ?CommitFilterCtx = null,
    visited: HashSet = .empty,
    queue: std.ArrayList(*Commit) = .empty,
    /// FIFO head index (avoids O(n) `orderedRemove(0)`).
    queue_head: usize = 0,
    last_err: ?anyerror = null,
    closed: bool = false,

    pub fn deinit(self: *FilterCommitIter) void {
        self.close();
        self.visited.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        self.* = undefined;
    }

    fn checkValid(self: *const FilterCommitIter, c: *Commit) bool {
        if (self.valid_ctx_fn) |f| return f(self.valid_ctx.?, c);
        return self.is_valid(c);
    }

    fn checkLimit(self: *const FilterCommitIter, c: *Commit) bool {
        if (self.limit_ctx_fn) |f| return f(self.limit_ctx.?, c);
        return self.is_limit(c);
    }

    /// go-git `filterCommitIter.Next`.
    pub fn next(self: *FilterCommitIter) anyerror!*Commit {
        while (true) {
            const commit = self.popNewFromQueue() catch |err| {
                return self.closeWith(err);
            };

            try hashSetPut(&self.visited, self.allocator, commit.hash);

            if (!self.checkLimit(commit)) {
                self.addToQueue(commit.parent_hashes) catch |err| {
                    return self.closeWith(err);
                };
            }

            if (self.checkValid(commit)) {
                return commit;
            }
        }
    }

    pub fn forEach(self: *FilterCommitIter, cb: anytype) !void {
        return forEachCommit(self, cb);
    }

    pub fn close(self: *FilterCommitIter) void {
        self.visited.clearRetainingCapacity();
        self.queue.clearRetainingCapacity();
        self.queue_head = 0;
        self.closed = true;
    }

    fn closeWith(self: *FilterCommitIter, err: anyerror) anyerror {
        self.close();
        self.last_err = err;
        return err;
    }

    /// First unvisited commit from the FIFO queue, or `error.EndOfStream`.
    fn popNewFromQueue(self: *FilterCommitIter) anyerror!*Commit {
        while (true) {
            if (self.queue_head >= self.queue.items.len) {
                if (self.last_err) |e| return e;
                return error.EndOfStream;
            }
            const first = self.queue.items[self.queue_head];
            self.queue_head += 1;
            // Compact occasionally to bound memory.
            if (self.queue_head > 64 and self.queue_head * 2 > self.queue.items.len) {
                const rest = self.queue.items[self.queue_head..];
                std.mem.copyForwards(*Commit, self.queue.items[0..rest.len], rest);
                self.queue.shrinkRetainingCapacity(rest.len);
                self.queue_head = 0;
            }
            if (hashSetContains(&self.visited, first.hash)) continue;
            return first;
        }
    }

    fn addToQueue(self: *FilterCommitIter, hashes: []const Hash) anyerror!void {
        for (hashes) |h| {
            if (hashSetContains(&self.visited, h)) continue;
            const commit = try loadCommit(self.loader, h);
            try self.queue.append(self.allocator, commit);
        }
    }

    pub fn asIter(self: *FilterCommitIter) CommitIter {
        return .{
            .ptr = self,
            .next_fn = nextThunk,
            .close_fn = closeThunk,
        };
    }

    fn nextThunk(ptr: *anyopaque) anyerror!*Commit {
        const self: *FilterCommitIter = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn closeThunk(ptr: *anyopaque) void {
        const self: *FilterCommitIter = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// go-git `NewFilterCommitIter`.
///
/// `is_valid` null → all commits valid. `is_limit` null → never limit.
pub fn newFilterCommitIter(
    allocator: Allocator,
    from: *Commit,
    is_valid: ?CommitFilter,
    is_limit: ?CommitFilter,
) Allocator.Error!FilterCommitIter {
    return newFilterCommitIterWithLoader(
        allocator,
        from,
        loaderFromCommit(from),
        is_valid,
        is_limit,
    );
}

/// Like `newFilterCommitIter` with an explicit parent loader (unit tests).
pub fn newFilterCommitIterWithLoader(
    allocator: Allocator,
    from: *Commit,
    loader: CommitLoader,
    is_valid: ?CommitFilter,
    is_limit: ?CommitFilter,
) Allocator.Error!FilterCommitIter {
    var iter = FilterCommitIter{
        .allocator = allocator,
        .loader = loader,
        .is_valid = is_valid orelse filterAlwaysValid,
        .is_limit = is_limit orelse filterNeverLimit,
    };
    try iter.queue.append(allocator, from);
    return iter;
}

/// Filtered BFS with contextual filters (Zig closures over maps).
pub fn newFilterCommitIterWithCtx(
    allocator: Allocator,
    from: *Commit,
    loader: CommitLoader,
    valid_ctx: ?*anyopaque,
    valid_ctx_fn: ?CommitFilterCtx,
    limit_ctx: ?*anyopaque,
    limit_ctx_fn: ?CommitFilterCtx,
) Allocator.Error!FilterCommitIter {
    var iter = FilterCommitIter{
        .allocator = allocator,
        .loader = loader,
        .valid_ctx = valid_ctx,
        .valid_ctx_fn = valid_ctx_fn,
        .limit_ctx = limit_ctx,
        .limit_ctx_fn = limit_ctx_fn,
    };
    try iter.queue.append(allocator, from);
    return iter;
}

// ---------------------------------------------------------------------------
// CTime (go-git commitIteratorByCTime / NewCommitIterCTime)
// ---------------------------------------------------------------------------

fn ctimeLess(_: void, a: *Commit, b: *Commit) std.math.Order {
    // Newer committer.when first (min-heap with inverted compare).
    if (a.committer.when > b.committer.when) return .lt;
    if (a.committer.when < b.committer.when) return .gt;
    return .eq;
}

const CTimePq = std.PriorityQueue(*Commit, void, ctimeLess);

/// Committer-time history walk (go-git `commitIteratorByCTime`).
/// Closest order to `git log` without topo options.
pub const CTimeIter = struct {
    allocator: Allocator,
    loader: CommitLoader,
    seen_external: ?*const HashSet,
    seen: HashSet = .empty,
    heap: CTimePq,

    pub fn deinit(self: *CTimeIter) void {
        self.close();
        self.seen.deinit(self.allocator);
        self.heap.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn next(self: *CTimeIter) anyerror!*Commit {
        while (true) {
            const c = self.heap.pop() orelse return error.EndOfStream;

            if (hashSetContains(&self.seen, c.hash)) continue;
            if (self.seen_external) |ext| {
                if (hashSetContains(ext, c.hash)) continue;
            }

            try hashSetPut(&self.seen, self.allocator, c.hash);

            for (c.parent_hashes) |h| {
                if (hashSetContains(&self.seen, h)) continue;
                if (self.seen_external) |ext| {
                    if (hashSetContains(ext, h)) continue;
                }
                const pc = try loadCommit(self.loader, h);
                try self.heap.push(self.allocator, pc);
            }
            return c;
        }
    }

    pub fn forEach(self: *CTimeIter, cb: anytype) !void {
        return forEachCommit(self, cb);
    }

    pub fn close(self: *CTimeIter) void {
        while (self.heap.pop()) |_| {}
    }

    pub fn asIter(self: *CTimeIter) CommitIter {
        return .{
            .ptr = self,
            .next_fn = nextThunk,
            .close_fn = closeThunk,
        };
    }

    fn nextThunk(ptr: *anyopaque) anyerror!*Commit {
        const self: *CTimeIter = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn closeThunk(ptr: *anyopaque) void {
        const self: *CTimeIter = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// go-git `NewCommitIterCTime`.
pub fn newCommitIterCTime(
    allocator: Allocator,
    c: *Commit,
    seen_external: ?*const HashSet,
    ignore: []const Hash,
) Allocator.Error!CTimeIter {
    return newCommitIterCTimeWithLoader(allocator, c, loaderFromCommit(c), seen_external, ignore);
}

/// Like `newCommitIterCTime` with an explicit parent loader (unit tests).
pub fn newCommitIterCTimeWithLoader(
    allocator: Allocator,
    c: *Commit,
    loader: CommitLoader,
    seen_external: ?*const HashSet,
    ignore: []const Hash,
) Allocator.Error!CTimeIter {
    var iter = CTimeIter{
        .allocator = allocator,
        .loader = loader,
        .seen_external = seen_external,
        .heap = CTimePq.initContext({}),
    };
    errdefer {
        iter.seen.deinit(allocator);
        iter.heap.deinit(allocator);
    }
    for (ignore) |h| {
        try hashSetPut(&iter.seen, allocator, h);
    }
    try iter.heap.push(allocator, c);
    return iter;
}

// ---------------------------------------------------------------------------
// Limit (go-git commitLimitIter / NewCommitLimitIterFromIter)
// ---------------------------------------------------------------------------

/// go-git `LogLimitOptions` — filter by committer unix time (seconds).
pub const LogLimitOptions = struct {
    /// Inclusive lower bound (go-git `Since`: skip when `when < since`).
    since: ?i64 = null,
    /// Inclusive upper bound (go-git `Until`: skip when `when > until`).
    until: ?i64 = null,
};

/// Filters a source `CommitIter` by committer time (go-git `commitLimitIter`).
pub const LimitIter = struct {
    source: CommitIter,
    options: LogLimitOptions,

    pub fn next(self: *LimitIter) anyerror!*Commit {
        while (true) {
            const c = try self.source.next();
            if (self.options.since) |since| {
                if (c.committer.when < since) continue;
            }
            if (self.options.until) |until| {
                if (c.committer.when > until) continue;
            }
            return c;
        }
    }

    pub fn forEach(self: *LimitIter, cb: anytype) !void {
        return forEachCommit(self, cb);
    }

    pub fn close(self: *LimitIter) void {
        self.source.close();
    }

    pub fn asIter(self: *LimitIter) CommitIter {
        return .{
            .ptr = self,
            .next_fn = nextThunk,
            .close_fn = closeThunk,
        };
    }

    fn nextThunk(ptr: *anyopaque) anyerror!*Commit {
        const self: *LimitIter = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn closeThunk(ptr: *anyopaque) void {
        const self: *LimitIter = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// go-git `NewCommitLimitIterFromIter`.
pub fn newCommitLimitIterFromIter(source: CommitIter, options: LogLimitOptions) LimitIter {
    return .{
        .source = source,
        .options = options,
    };
}

// ---------------------------------------------------------------------------
// Path / file (go-git commitPathIter / NewCommitPathIterFromIter)
// ---------------------------------------------------------------------------

/// Path filter callback (go-git `pathFilter func(string) bool`).
pub const PathFilter = *const fn (path: []const u8) bool;

/// Walks a source commit iter and yields commits that change matching paths
/// (go-git `commitPathIter`).
///
/// Diffs successive trees from the source order. Trees are loaded via
/// `Commit.tree()` and freed after each step.
pub const PathIter = struct {
    allocator: Allocator,
    source: CommitIter,
    path_filter: PathFilter,
    check_parent: bool,
    current_commit: ?*Commit = null,
    /// Tree from previous parent, reused as current on the next step.
    pending_parent_tree: ?*Tree = null,
    /// Owned exact path for file-iter (equality match when set).
    exact_path: ?[]const u8 = null,

    pub fn deinit(self: *PathIter) void {
        self.close();
        if (self.exact_path) |p| {
            self.allocator.free(p);
            self.exact_path = null;
        }
        self.* = undefined;
    }

    fn matchesPath(self: *const PathIter, path: []const u8) bool {
        if (self.exact_path) |ep| return std.mem.eql(u8, path, ep);
        return self.path_filter(path);
    }

    pub fn next(self: *PathIter) anyerror!*Commit {
        if (self.current_commit == null) {
            self.current_commit = try self.source.next();
        }
        return self.getNextFileCommit() catch |err| {
            self.current_commit = null;
            return err;
        };
    }

    fn getNextFileCommit(self: *PathIter) anyerror!*Commit {
        while (true) {
            // Next source commit is the historical parent in walk order.
            const parent_commit: ?*Commit = self.source.next() catch |err| blk: {
                const e: anyerror = err;
                if (e == error.EndOfStream) break :blk null;
                return e;
            };

            const current = self.current_commit orelse return error.EndOfStream;

            const current_tree: *Tree = if (self.pending_parent_tree) |t| blk: {
                self.pending_parent_tree = null;
                break :blk t;
            } else current.tree() catch |err| {
                return err;
            };

            const parent_tree: ?*Tree = if (parent_commit) |pc|
                pc.tree() catch |err| {
                    tree_mod.freeTree(self.allocator, current_tree);
                    return err;
                }
            else
                null;

            // go-git DiffTree(currentTree, parentTree): left=current, right=parent.
            var changes = difftree_mod.diffTree(self.allocator, current_tree, parent_tree) catch |err| {
                tree_mod.freeTree(self.allocator, current_tree);
                if (parent_tree) |pt| tree_mod.freeTree(self.allocator, pt);
                return err;
            };
            defer changes.deinit();

            const found = self.hasFileChange(changes, parent_commit, current);

            tree_mod.freeTree(self.allocator, current_tree);
            self.pending_parent_tree = parent_tree;

            const prev = current;
            self.current_commit = parent_commit;

            if (found) return prev;
            if (parent_commit == null) return error.EndOfStream;
        }
    }

    fn hasFileChange(
        self: *const PathIter,
        changes: Changes,
        parent: ?*Commit,
        current: *Commit,
    ) bool {
        for (changes.items) |ch| {
            if (!self.matchesPath(ch.name())) continue;

            if (self.check_parent) {
                if (parent == null or isParentHash(parent.?.hash, current)) {
                    return true;
                }
                continue;
            }
            return true;
        }
        return false;
    }

    pub fn forEach(self: *PathIter, cb: anytype) !void {
        return forEachCommit(self, cb);
    }

    pub fn close(self: *PathIter) void {
        if (self.pending_parent_tree) |t| {
            tree_mod.freeTree(self.allocator, t);
            self.pending_parent_tree = null;
        }
        self.current_commit = null;
        self.source.close();
    }

    pub fn asIter(self: *PathIter) CommitIter {
        return .{
            .ptr = self,
            .next_fn = nextThunk,
            .close_fn = closeThunk,
        };
    }

    fn nextThunk(ptr: *anyopaque) anyerror!*Commit {
        const self: *PathIter = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn closeThunk(ptr: *anyopaque) void {
        const self: *PathIter = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

fn isParentHash(hash: Hash, commit: *const Commit) bool {
    for (commit.parent_hashes) |h| {
        if (h.eql(hash)) return true;
    }
    return false;
}

fn pathFilterUnused(_: []const u8) bool {
    return false;
}

/// go-git `NewCommitPathIterFromIter`.
pub fn newCommitPathIterFromIter(
    allocator: Allocator,
    path_filter: PathFilter,
    commit_iter: CommitIter,
    check_parent: bool,
) PathIter {
    return .{
        .allocator = allocator,
        .source = commit_iter,
        .path_filter = path_filter,
        .check_parent = check_parent,
    };
}

/// go-git `NewCommitFileIterFromIter` — match a single path string.
///
/// Copies `file_name`; free with `PathIter.deinit`.
pub fn newCommitFileIterFromIter(
    allocator: Allocator,
    file_name: []const u8,
    commit_iter: CommitIter,
    check_parent: bool,
) Allocator.Error!PathIter {
    const owned = try allocator.dupe(u8, file_name);
    return .{
        .allocator = allocator,
        .source = commit_iter,
        .path_filter = pathFilterUnused,
        .check_parent = check_parent,
        .exact_path = owned,
    };
}

// ---------------------------------------------------------------------------
// All tips (go-git commitAllIterator / NewCommitAllIter)
// ---------------------------------------------------------------------------

const AllPathNode = struct {
    commit: *Commit,
    prev: ?*AllPathNode = null,
    next: ?*AllPathNode = null,
};

/// Loader context owned by `AllIter` when built from tip hashes (heap, not stack).
const AllLoaderCtx = struct {
    allocator: Allocator,
    getter: ObjectGetter,
};

/// Merged multi-tip history (go-git `commitAllIterator`).
///
/// Built eagerly from tip commits: each tip is walked with preorder until a
/// commit already on the path is found; the unique prefix is inserted so shared
/// history appears once (go-git `addReference` list merge).
///
/// Full go-git needs `storage.Storer.IterReferences` + `ResolveReference`.
/// This port accepts already-resolved tip commits plus a `CommitLoader`.
pub const AllIter = struct {
    allocator: Allocator,
    lookup: std.AutoHashMapUnmanaged(Hash, *AllPathNode) = .empty,
    list_head: ?*AllPathNode = null,
    list_tail: ?*AllPathNode = null,
    curr: ?*AllPathNode = null,
    nodes: std.ArrayList(*AllPathNode) = .empty,
    /// Heap context for `newCommitAllIterFromHashes` (null for tip-pointer form).
    loader_ctx: ?*AllLoaderCtx = null,
    /// Tip commits loaded by FromHashes (freed on deinit).
    owned_tips: std.ArrayList(*Commit) = .empty,

    pub fn deinit(self: *AllIter) void {
        self.close();
        for (self.nodes.items) |n| self.allocator.destroy(n);
        self.nodes.deinit(self.allocator);
        self.lookup.deinit(self.allocator);
        for (self.owned_tips.items) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
        self.owned_tips.deinit(self.allocator);
        if (self.loader_ctx) |ctx| self.allocator.destroy(ctx);
        self.* = undefined;
    }

    fn pushBack(self: *AllIter, c: *Commit) Allocator.Error!*AllPathNode {
        const n = try self.allocator.create(AllPathNode);
        errdefer self.allocator.destroy(n);
        n.* = .{ .commit = c };
        try self.nodes.append(self.allocator, n);
        if (self.list_tail) |t| {
            t.next = n;
            n.prev = t;
            self.list_tail = n;
        } else {
            self.list_head = n;
            self.list_tail = n;
        }
        try self.lookup.put(self.allocator, c.hash, n);
        return n;
    }

    fn insertBefore(self: *AllIter, c: *Commit, before: *AllPathNode) Allocator.Error!*AllPathNode {
        const n = try self.allocator.create(AllPathNode);
        errdefer self.allocator.destroy(n);
        n.* = .{ .commit = c, .next = before, .prev = before.prev };
        if (before.prev) |p| {
            p.next = n;
        } else {
            self.list_head = n;
        }
        before.prev = n;
        try self.nodes.append(self.allocator, n);
        try self.lookup.put(self.allocator, c.hash, n);
        return n;
    }

    fn addTip(self: *AllIter, tip: *Commit, loader: CommitLoader) !void {
        if (self.lookup.get(tip.hash) != null) return;

        var ref_commits: std.ArrayList(*Commit) = .empty;
        defer ref_commits.deinit(self.allocator);

        var common: ?*AllPathNode = null;

        var walk = try newCommitPreorderIterWithLoader(self.allocator, tip, loader, null, &.{});
        defer walk.deinit();

        while (true) {
            const c = walk.next() catch |err| {
                const e: anyerror = err;
                if (e == error.EndOfStream) break;
                return e;
            };
            if (self.lookup.get(c.hash)) |node| {
                common = node;
                break;
            }
            try ref_commits.append(self.allocator, c);
        }

        if (common) |parent_start| {
            var parent = parent_start;
            var i = ref_commits.items.len;
            while (i > 0) {
                i -= 1;
                parent = try self.insertBefore(ref_commits.items[i], parent);
            }
        } else {
            for (ref_commits.items) |c| {
                _ = try self.pushBack(c);
            }
        }
    }

    pub fn next(self: *AllIter) anyerror!*Commit {
        const n = self.curr orelse return error.EndOfStream;
        self.curr = n.next;
        return n.commit;
    }

    pub fn forEach(self: *AllIter, cb: anytype) !void {
        return forEachCommit(self, cb);
    }

    pub fn close(self: *AllIter) void {
        self.curr = null;
    }

    /// Free commits still on the path (`curr` → tail). Call before `close`/`deinit`
    /// when the caller owns yielded commits and used a heap loader (FromHashes).
    /// Do **not** use with stack-backed tip loaders (FromTips unit tests).
    pub fn freeUnyielded(self: *AllIter) void {
        var n = self.curr;
        while (n) |node| {
            const c = node.commit;
            c.deinit();
            self.allocator.destroy(c);
            n = node.next;
        }
        self.curr = null;
    }

    /// Clear tip ownership so `deinit` does not free tip commits (caller owns them).
    pub fn disownTips(self: *AllIter) void {
        self.owned_tips.clearRetainingCapacity();
    }

    pub fn asIter(self: *AllIter) CommitIter {
        return .{
            .ptr = self,
            .next_fn = nextThunk,
            .close_fn = closeThunk,
        };
    }

    fn nextThunk(ptr: *anyopaque) anyerror!*Commit {
        const self: *AllIter = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn closeThunk(ptr: *anyopaque) void {
        const self: *AllIter = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// go-git `NewCommitAllIter` (tips form).
///
/// go-git walks HEAD then `IterReferences()`. Here the caller supplies tip
/// commits already resolved from those refs. Each tip history is walked with
/// preorder and merged into one path.
///
/// Incomplete vs go-git: no `Storer.IterReferences` / symbolic HEAD resolve
/// inside this function; no `commitIterFunc` (always preorder).
pub fn newCommitAllIterFromTips(
    allocator: Allocator,
    tips: []const *Commit,
    loader: CommitLoader,
) !AllIter {
    var iter = AllIter{
        .allocator = allocator,
    };
    errdefer iter.deinit();

    for (tips) |tip| {
        try iter.addTip(tip, loader);
    }
    iter.curr = iter.list_head;
    return iter;
}

/// Load tip hashes via `ObjectGetter`, skip non-commits, then merge with preorder.
///
/// Owns loaded tip commits and a heap loader context (valid for the iter lifetime).
pub fn newCommitAllIterFromHashes(
    allocator: Allocator,
    getter: ObjectGetter,
    tip_hashes: []const Hash,
) !AllIter {
    var iter = AllIter{ .allocator = allocator };
    errdefer iter.deinit();

    const ctx = try allocator.create(AllLoaderCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{ .allocator = allocator, .getter = getter };
    iter.loader_ctx = ctx;

    const Gen = struct {
        fn get(ptr: *anyopaque, h: Hash) anyerror!*Commit {
            const c: *AllLoaderCtx = @ptrCast(@alignCast(ptr));
            return getCommitFromGetter(c.allocator, c.getter, h);
        }
    };
    const loader = CommitLoader{ .ptr = ctx, .get_fn = Gen.get };

    for (tip_hashes) |h| {
        const c = getCommitFromGetter(allocator, getter, h) catch continue;
        try iter.owned_tips.append(allocator, c);
    }

    if (iter.owned_tips.items.len == 0) {
        return iter;
    }

    for (iter.owned_tips.items) |tip| {
        try iter.addTip(tip, loader);
    }
    iter.curr = iter.list_head;
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

test "ctime order prefers newer committer.when" {
    const gpa = std.testing.allocator;

    //   tip (t=30) → mid (t=10) → old (t=20)
    // With a side parent branch: tip also parents side (t=25)
    //   tip
    //   |  \
    //  mid  side
    //   |
    //  old
    // CTime should emit tip(30), side(25), old(20), mid(10) — heap by when.
    // After tip: push mid and side. Pop side(25), push nothing. Pop old? mid is 10, side parents none.
    // Actually: tip parents mid+side. After tip, heap=[mid@10, side@25]. Pop side@25. Pop mid@10, push old@20.
    // Heap=[old@20]. Pop old. Order: tip, side, mid, old.
    const h_tip = testHash(1);
    const h_mid = testHash(2);
    const h_side = testHash(3);
    const h_old = testHash(4);

    var old = try makeCommit(gpa, h_old, &.{});
    defer old.deinit();
    old.committer.when = 20;

    var mid = try makeCommit(gpa, h_mid, &.{h_old});
    defer mid.deinit();
    mid.committer.when = 10;

    var side = try makeCommit(gpa, h_side, &.{});
    defer side.deinit();
    side.committer.when = 25;

    var tip = try makeCommit(gpa, h_tip, &.{ h_mid, h_side });
    defer tip.deinit();
    tip.committer.when = 30;

    var graph = TestGraph.init(gpa);
    defer graph.deinit();
    try graph.put(&tip);
    try graph.put(&mid);
    try graph.put(&side);
    try graph.put(&old);

    var iter = try newCommitIterCTimeWithLoader(gpa, &tip, graph.loader(), null, &.{});
    defer iter.deinit();

    try std.testing.expect((try iter.next()).hash.eql(h_tip));
    try std.testing.expect((try iter.next()).hash.eql(h_side));
    try std.testing.expect((try iter.next()).hash.eql(h_mid));
    try std.testing.expect((try iter.next()).hash.eql(h_old));
    try std.testing.expectError(error.EndOfStream, iter.next());
}

test "limit filter by committer when" {
    const gpa = std.testing.allocator;

    const h1 = testHash(1);
    const h2 = testHash(2);
    const h3 = testHash(3);

    var c3 = try makeCommit(gpa, h3, &.{});
    defer c3.deinit();
    c3.committer.when = 100;
    var c2 = try makeCommit(gpa, h2, &.{h3});
    defer c2.deinit();
    c2.committer.when = 200;
    var c1 = try makeCommit(gpa, h1, &.{h2});
    defer c1.deinit();
    c1.committer.when = 300;

    var graph = TestGraph.init(gpa);
    defer graph.deinit();
    try graph.put(&c1);
    try graph.put(&c2);
    try graph.put(&c3);

    var src = try newCommitPreorderIterWithLoader(gpa, &c1, graph.loader(), null, &.{});
    defer src.deinit();

    var lim = newCommitLimitIterFromIter(src.asIter(), .{ .since = 150, .until = 250 });
    defer lim.close();

    try std.testing.expect((try lim.next()).hash.eql(h2));
    try std.testing.expectError(error.EndOfStream, lim.next());
}

test "all iter merges two tips with shared base" {
    const gpa = std.testing.allocator;

    // tip_a → base
    // tip_b → base
    const h_base = testHash(1);
    const h_a = testHash(2);
    const h_b = testHash(3);

    var base = try makeCommit(gpa, h_base, &.{});
    defer base.deinit();
    var tip_a = try makeCommit(gpa, h_a, &.{h_base});
    defer tip_a.deinit();
    var tip_b = try makeCommit(gpa, h_b, &.{h_base});
    defer tip_b.deinit();

    var graph = TestGraph.init(gpa);
    defer graph.deinit();
    try graph.put(&base);
    try graph.put(&tip_a);
    try graph.put(&tip_b);

    const tips = [_]*Commit{ &tip_a, &tip_b };
    var iter = try newCommitAllIterFromTips(gpa, &tips, graph.loader());
    defer iter.deinit();

    var count: usize = 0;
    var seen_base = false;
    while (true) {
        const c = iter.next() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        count += 1;
        if (c.hash.eql(h_base)) seen_base = true;
    }
    // tip_a, base, tip_b (base once)
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expect(seen_base);
}

test "path iter yields commits that modify a file" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");
    const filemode = @import("filemode");

    var store = memory.Storage.init(gpa);
    defer store.deinit();

    // blob v1 / v2
    const b1 = try store.newEncodedObject();
    b1.setType(.blob);
    _ = try b1.write("v1");
    const bh1 = try store.setEncodedObject(b1);
    const b2 = try store.newEncodedObject();
    b2.setType(.blob);
    _ = try b2.write("v2");
    const bh2 = try store.setEncodedObject(b2);
    // unrelated blob
    const b3 = try store.newEncodedObject();
    b3.setType(.blob);
    _ = try b3.write("other");
    const bh3 = try store.setEncodedObject(b3);

    // tree0: empty (root commit)
    var t0 = tree_mod.Tree.init(gpa, storer_mod.ObjectGetter.from(memory.Storage, &store));
    defer t0.deinit();
    const t0_obj = try store.newEncodedObject();
    try t0.encode(t0_obj);
    const th0 = try store.setEncodedObject(t0_obj);

    // tree1: file.txt = v1
    var t1 = tree_mod.Tree.init(gpa, storer_mod.ObjectGetter.from(memory.Storage, &store));
    defer t1.deinit();
    try t1.appendEntry("file.txt", filemode.Regular, bh1);
    t1.sortEntries();
    const t1_obj = try store.newEncodedObject();
    try t1.encode(t1_obj);
    const th1 = try store.setEncodedObject(t1_obj);

    // tree2: file.txt = v2 (modify)
    var t2 = tree_mod.Tree.init(gpa, storer_mod.ObjectGetter.from(memory.Storage, &store));
    defer t2.deinit();
    try t2.appendEntry("file.txt", filemode.Regular, bh2);
    t2.sortEntries();
    const t2_obj = try store.newEncodedObject();
    try t2.encode(t2_obj);
    const th2 = try store.setEncodedObject(t2_obj);

    // tree3: file.txt = v2 + other.txt (unrelated change)
    var t3 = tree_mod.Tree.init(gpa, storer_mod.ObjectGetter.from(memory.Storage, &store));
    defer t3.deinit();
    try t3.appendEntry("file.txt", filemode.Regular, bh2);
    try t3.appendEntry("other.txt", filemode.Regular, bh3);
    t3.sortEntries();
    const t3_obj = try store.newEncodedObject();
    try t3.encode(t3_obj);
    const th3 = try store.setEncodedObject(t3_obj);

    // commits: c0 (empty) ← c1 (add file) ← c2 (modify file) ← c3 (add other)
    const getter = storer_mod.ObjectGetter.from(memory.Storage, &store);

    var c0 = Commit.init(gpa);
    defer c0.deinit();
    c0.hash = testHash(0x10);
    c0.tree_hash = th0;
    c0.storer = getter;
    c0.committer.when = 1;
    // Store c0 so getCommit works if needed — walkers use TestGraph loader instead.

    var c1 = Commit.init(gpa);
    defer c1.deinit();
    c1.hash = testHash(0x11);
    c1.tree_hash = th1;
    c1.parent_hashes = try gpa.dupe(Hash, &.{c0.hash});
    c1.storer = getter;
    c1.committer.when = 2;

    var c2 = Commit.init(gpa);
    defer c2.deinit();
    c2.hash = testHash(0x12);
    c2.tree_hash = th2;
    c2.parent_hashes = try gpa.dupe(Hash, &.{c1.hash});
    c2.storer = getter;
    c2.committer.when = 3;

    var c3 = Commit.init(gpa);
    defer c3.deinit();
    c3.hash = testHash(0x13);
    c3.tree_hash = th3;
    c3.parent_hashes = try gpa.dupe(Hash, &.{c2.hash});
    c3.storer = getter;
    c3.committer.when = 4;

    var graph = TestGraph.init(gpa);
    defer graph.deinit();
    try graph.put(&c0);
    try graph.put(&c1);
    try graph.put(&c2);
    try graph.put(&c3);

    // Source: newest first (ctime / preorder from tip).
    var src = try newCommitPreorderIterWithLoader(gpa, &c3, graph.loader(), null, &.{});
    defer src.deinit();

    var path_it = try newCommitFileIterFromIter(gpa, "file.txt", src.asIter(), false);
    defer path_it.deinit();

    // Expect c2 (modify) then c1 (insert); c3 only touches other.txt; c0 no file.
    try std.testing.expect((try path_it.next()).hash.eql(c2.hash));
    try std.testing.expect((try path_it.next()).hash.eql(c1.hash));
    try std.testing.expectError(error.EndOfStream, path_it.next());
}

test "filter commit iter all commits BFS order" {
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

    var iter = try newFilterCommitIterWithLoader(gpa, &c1, graph.loader(), null, null);
    defer iter.deinit();

    try std.testing.expect((try iter.next()).hash.eql(h1));
    try std.testing.expect((try iter.next()).hash.eql(h2));
    try std.testing.expect((try iter.next()).hash.eql(h3));
    try std.testing.expectError(error.EndOfStream, iter.next());
}

test "filter commit iter isValid skips non-matching" {
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

    const only_h2: CommitFilter = struct {
        fn f(c: *Commit) bool {
            return c.hash.bytes[0] == 2;
        }
    }.f;

    var iter = try newFilterCommitIterWithLoader(gpa, &c1, graph.loader(), only_h2, null);
    defer iter.deinit();

    try std.testing.expect((try iter.next()).hash.eql(h2));
    try std.testing.expectError(error.EndOfStream, iter.next());
}

test "filter commit iter isLimit stops parent walk" {
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

    const limit_h2: CommitFilter = struct {
        fn f(c: *Commit) bool {
            return c.hash.bytes[0] == 2;
        }
    }.f;

    var iter = try newFilterCommitIterWithLoader(gpa, &c1, graph.loader(), null, limit_h2);
    defer iter.deinit();

    // h1 yielded; h2 yielded but parents not enqueued; h3 never visited.
    try std.testing.expect((try iter.next()).hash.eql(h1));
    try std.testing.expect((try iter.next()).hash.eql(h2));
    try std.testing.expectError(error.EndOfStream, iter.next());
}
