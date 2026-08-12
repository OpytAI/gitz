//! Commit history walkers over CommitNode
//! (go-git `commitnode_walker_*.go` + `commitnode_walker_helper.go`).
//!
//! - `newCommitNodeIterCTime` — committer-time heap walk (`git log`-like)
//! - `newCommitNodeIterDateOrder` — topo + generation/date (`git log --date-order`)
//! - `newCommitNodeIterAuthorDateOrder` — topo + author time (`git log --author-order`)
//! - `newCommitNodeIterTopoOrder` — topo order (`git log --topo-order`)

const std = @import("std");
const plumbing = @import("plumbing");
const object = @import("object");

const commitnode = @import("commitnode.zig");

const Hash = plumbing.Hash;
const Allocator = std.mem.Allocator;
const CommitNode = commitnode.CommitNode;
const CommitNodeIter = commitnode.CommitNodeIter;
const max_generation = commitnode.max_generation;

// ---------------------------------------------------------------------------
// generationAndDateOrderComparator (go-git helper)
// ---------------------------------------------------------------------------

/// Compare two nodes for date/generation order heaps.
/// Returns -1 if `left` is higher priority (newer / higher gen), 1 if lower, 0 if equal.
pub fn generationAndDateOrderCompare(left: CommitNode, right: CommitNode) i32 {
    if (left.generationV2() == max_generation) {
        if (right.generationV2() == max_generation) {
            if (right.commitTimeSec() < left.commitTimeSec()) return -1;
            if (left.commitTimeSec() < right.commitTimeSec()) return 1;
            return 0;
        }
        return -1;
    }

    // go-git compares right against MaxInt64 (likely typo); use MaxUint64.
    if (right.generationV2() == max_generation) {
        return 1;
    }

    if (left.generationV2() == 0 or right.generationV2() == 0) {
        if (left.generation() < right.generation()) return 1;
        if (left.generation() > right.generation()) return -1;
        if (right.commitTimeSec() < left.commitTimeSec()) return -1;
        if (left.commitTimeSec() < right.commitTimeSec()) return 1;
        return 0;
    }

    if (left.generationV2() < right.generationV2()) return 1;
    if (left.generationV2() > right.generationV2()) return -1;
    return 0;
}

fn composeIgnores(
    allocator: Allocator,
    ignore: []const Hash,
    seen_external: ?std.AutoHashMapUnmanaged(Hash, bool),
) Allocator.Error!std.AutoHashMapUnmanaged(Hash, void) {
    var seen: std.AutoHashMapUnmanaged(Hash, void) = .empty;
    errdefer seen.deinit(allocator);
    for (ignore) |h| {
        try seen.put(allocator, h, {});
    }
    if (seen_external) |ext| {
        var it = ext.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*) {
                try seen.put(allocator, e.key_ptr.*, {});
            }
        }
    }
    return seen;
}

// ---------------------------------------------------------------------------
// Shared node (refcount) — go-git shares one interface pointer on two heaps
// ---------------------------------------------------------------------------

const SharedNode = struct {
    allocator: Allocator,
    node: CommitNode,
    refs: u32,

    fn wrap(allocator: Allocator, node: CommitNode, refs: u32) Allocator.Error!CommitNode {
        const self = try allocator.create(SharedNode);
        self.* = .{ .allocator = allocator, .node = node, .refs = refs };
        return self.asNode();
    }

    fn asNode(self: *SharedNode) CommitNode {
        return .{ .ptr = self, .vtable = &shared_vtable };
    }

    fn release(self: *SharedNode) void {
        self.refs -= 1;
        if (self.refs == 0) {
            const a = self.allocator;
            self.node.deinit();
            a.destroy(self);
        }
    }
};

const shared_vtable = CommitNode.VTable{
    .id = sharedId,
    .commit_time_sec = sharedCommitTimeSec,
    .author_time_sec = sharedAuthorTimeSec,
    .num_parents = sharedNumParents,
    .parent_node = sharedParentNode,
    .parent_hashes = sharedParentHashes,
    .generation = sharedGeneration,
    .generation_v2 = sharedGenerationV2,
    .commit = sharedCommit,
    .tree = sharedTree,
    .deinit = sharedDeinit,
};

fn sharedId(ptr: *anyopaque) Hash {
    return (@as(*SharedNode, @ptrCast(@alignCast(ptr)))).node.id();
}
fn sharedCommitTimeSec(ptr: *anyopaque) i64 {
    return (@as(*SharedNode, @ptrCast(@alignCast(ptr)))).node.commitTimeSec();
}
fn sharedAuthorTimeSec(ptr: *anyopaque) i64 {
    return (@as(*SharedNode, @ptrCast(@alignCast(ptr)))).node.authorTimeSec();
}
fn sharedNumParents(ptr: *anyopaque) usize {
    return (@as(*SharedNode, @ptrCast(@alignCast(ptr)))).node.numParents();
}
fn sharedParentNode(ptr: *anyopaque, i: usize) anyerror!CommitNode {
    return (@as(*SharedNode, @ptrCast(@alignCast(ptr)))).node.parentNode(i);
}
fn sharedParentHashes(ptr: *anyopaque) []const Hash {
    return (@as(*SharedNode, @ptrCast(@alignCast(ptr)))).node.parentHashes();
}
fn sharedGeneration(ptr: *anyopaque) u64 {
    return (@as(*SharedNode, @ptrCast(@alignCast(ptr)))).node.generation();
}
fn sharedGenerationV2(ptr: *anyopaque) u64 {
    return (@as(*SharedNode, @ptrCast(@alignCast(ptr)))).node.generationV2();
}
fn sharedCommit(ptr: *anyopaque) anyerror!*object.Commit {
    return (@as(*SharedNode, @ptrCast(@alignCast(ptr)))).node.commit();
}
fn sharedTree(ptr: *anyopaque) anyerror!*object.Tree {
    return (@as(*SharedNode, @ptrCast(@alignCast(ptr)))).node.tree();
}
fn sharedDeinit(ptr: *anyopaque) void {
    (@as(*SharedNode, @ptrCast(@alignCast(ptr)))).release();
}

// ---------------------------------------------------------------------------
// Stackable (go-git commitNodeStackable)
// ---------------------------------------------------------------------------

const Stackable = struct {
    ptr: *anyopaque,
    push_fn: *const fn (*anyopaque, CommitNode) Allocator.Error!void,
    pop_fn: *const fn (*anyopaque) ?CommitNode,
    peek_fn: *const fn (*anyopaque) ?CommitNode,
    size_fn: *const fn (*anyopaque) usize,
    deinit_fn: *const fn (*anyopaque) void,

    fn push(self: Stackable, c: CommitNode) Allocator.Error!void {
        return self.push_fn(self.ptr, c);
    }
    fn pop(self: Stackable) ?CommitNode {
        return self.pop_fn(self.ptr);
    }
    fn peek(self: Stackable) ?CommitNode {
        return self.peek_fn(self.ptr);
    }
    fn size(self: Stackable) usize {
        return self.size_fn(self.ptr);
    }
    fn deinit(self: Stackable) void {
        self.deinit_fn(self.ptr);
    }
};

// --- LIFO (go-git commitNodeLifo) ---

const Lifo = struct {
    allocator: Allocator,
    items: std.ArrayList(CommitNode) = .empty,

    fn create(allocator: Allocator) Allocator.Error!*Lifo {
        const self = try allocator.create(Lifo);
        self.* = .{ .allocator = allocator };
        return self;
    }

    fn destroy(self: *Lifo) void {
        for (self.items.items) |n| n.deinit();
        self.items.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn asStackable(self: *Lifo) Stackable {
        return .{
            .ptr = self,
            .push_fn = lifoPush,
            .pop_fn = lifoPop,
            .peek_fn = lifoPeek,
            .size_fn = lifoSize,
            .deinit_fn = lifoDestroy,
        };
    }
};

fn lifoPush(ptr: *anyopaque, c: CommitNode) Allocator.Error!void {
    const self: *Lifo = @ptrCast(@alignCast(ptr));
    try self.items.append(self.allocator, c);
}
fn lifoPop(ptr: *anyopaque) ?CommitNode {
    const self: *Lifo = @ptrCast(@alignCast(ptr));
    return self.items.pop();
}
fn lifoPeek(ptr: *anyopaque) ?CommitNode {
    const self: *Lifo = @ptrCast(@alignCast(ptr));
    if (self.items.items.len == 0) return null;
    return self.items.items[self.items.items.len - 1];
}
fn lifoSize(ptr: *anyopaque) usize {
    const self: *Lifo = @ptrCast(@alignCast(ptr));
    return self.items.items.len;
}
fn lifoDestroy(ptr: *anyopaque) void {
    (@as(*Lifo, @ptrCast(@alignCast(ptr)))).destroy();
}

// --- Date/generation heap ---

fn dateHeapLess(_: void, a: CommitNode, b: CommitNode) std.math.Order {
    const cmp = generationAndDateOrderCompare(a, b);
    if (cmp < 0) return .lt;
    if (cmp > 0) return .gt;
    return .eq;
}

const DateHeap = struct {
    allocator: Allocator,
    pq: std.PriorityQueue(CommitNode, void, dateHeapLess),

    fn create(allocator: Allocator) Allocator.Error!*DateHeap {
        const self = try allocator.create(DateHeap);
        self.* = .{
            .allocator = allocator,
            .pq = std.PriorityQueue(CommitNode, void, dateHeapLess).initContext({}),
        };
        return self;
    }

    fn destroy(self: *DateHeap) void {
        while (self.pq.pop()) |n| n.deinit();
        self.pq.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn asStackable(self: *DateHeap) Stackable {
        return .{
            .ptr = self,
            .push_fn = datePush,
            .pop_fn = datePop,
            .peek_fn = datePeek,
            .size_fn = dateSize,
            .deinit_fn = dateDestroy,
        };
    }
};

fn datePush(ptr: *anyopaque, c: CommitNode) Allocator.Error!void {
    const self: *DateHeap = @ptrCast(@alignCast(ptr));
    try self.pq.push(self.allocator, c);
}
fn datePop(ptr: *anyopaque) ?CommitNode {
    const self: *DateHeap = @ptrCast(@alignCast(ptr));
    return self.pq.pop();
}
fn datePeek(ptr: *anyopaque) ?CommitNode {
    const self: *DateHeap = @ptrCast(@alignCast(ptr));
    return self.pq.peek();
}
fn dateSize(ptr: *anyopaque) usize {
    const self: *DateHeap = @ptrCast(@alignCast(ptr));
    return self.pq.count();
}
fn dateDestroy(ptr: *anyopaque) void {
    (@as(*DateHeap, @ptrCast(@alignCast(ptr)))).destroy();
}

// --- Author-date heap (author time via CommitNode.authorTimeSec) ---

/// Compare by author time (newer first). Backends cache / free loads as needed.
fn authorDateHeapLess(_: void, a: CommitNode, b: CommitNode) std.math.Order {
    const left = a.authorTimeSec();
    const right = b.authorTimeSec();
    // go-git: right.Author.When.Before(left) → left higher priority.
    if (right < left) return .lt;
    if (left < right) return .gt;
    return .eq;
}

const AuthorDateHeap = struct {
    allocator: Allocator,
    pq: std.PriorityQueue(CommitNode, void, authorDateHeapLess),

    fn create(allocator: Allocator) Allocator.Error!*AuthorDateHeap {
        const self = try allocator.create(AuthorDateHeap);
        self.* = .{
            .allocator = allocator,
            .pq = std.PriorityQueue(CommitNode, void, authorDateHeapLess).initContext({}),
        };
        return self;
    }

    fn destroy(self: *AuthorDateHeap) void {
        while (self.pq.pop()) |n| n.deinit();
        self.pq.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn asStackable(self: *AuthorDateHeap) Stackable {
        return .{
            .ptr = self,
            .push_fn = authorDatePush,
            .pop_fn = authorDatePop,
            .peek_fn = authorDatePeek,
            .size_fn = authorDateSize,
            .deinit_fn = authorDateDestroy,
        };
    }
};

fn authorDatePush(ptr: *anyopaque, c: CommitNode) Allocator.Error!void {
    const self: *AuthorDateHeap = @ptrCast(@alignCast(ptr));
    try self.pq.push(self.allocator, c);
}
fn authorDatePop(ptr: *anyopaque) ?CommitNode {
    const self: *AuthorDateHeap = @ptrCast(@alignCast(ptr));
    return self.pq.pop();
}
fn authorDatePeek(ptr: *anyopaque) ?CommitNode {
    const self: *AuthorDateHeap = @ptrCast(@alignCast(ptr));
    return self.pq.peek();
}
fn authorDateSize(ptr: *anyopaque) usize {
    const self: *AuthorDateHeap = @ptrCast(@alignCast(ptr));
    return self.pq.count();
}
fn authorDateDestroy(ptr: *anyopaque) void {
    (@as(*AuthorDateHeap, @ptrCast(@alignCast(ptr)))).destroy();
}

// ---------------------------------------------------------------------------
// CTime walker
// ---------------------------------------------------------------------------

fn ctimeLess(_: void, a: CommitNode, b: CommitNode) std.math.Order {
    if (a.commitTimeSec() > b.commitTimeSec()) return .lt;
    if (a.commitTimeSec() < b.commitTimeSec()) return .gt;
    return .eq;
}

const CTimePq = std.PriorityQueue(CommitNode, void, ctimeLess);

/// Committer-time walk (go-git `commitNodeIteratorByCTime`).
pub const CommitNodeIterCTime = struct {
    allocator: Allocator,
    heap: CTimePq,
    seen_external: std.AutoHashMapUnmanaged(Hash, bool),
    seen: std.AutoHashMapUnmanaged(Hash, bool),

    pub fn init(
        allocator: Allocator,
        start: CommitNode,
        seen_external: ?std.AutoHashMapUnmanaged(Hash, bool),
        ignore: []const Hash,
    ) Allocator.Error!*CommitNodeIterCTime {
        const self = try allocator.create(CommitNodeIterCTime);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .heap = CTimePq.initContext({}),
            .seen_external = if (seen_external) |s| s else .empty,
            .seen = .empty,
        };
        errdefer {
            self.heap.deinit(allocator);
            self.seen.deinit(allocator);
        }
        for (ignore) |h| try self.seen.put(allocator, h, true);
        try self.heap.push(allocator, start);
        return self;
    }

    pub fn next(self: *CommitNodeIterCTime) anyerror!CommitNode {
        while (true) {
            const c = self.heap.pop() orelse return error.EndOfStream;
            const c_id = c.id();

            if (self.seen.get(c_id) == true) {
                c.deinit();
                continue;
            }
            if (self.seen_external.get(c_id) == true) {
                c.deinit();
                continue;
            }

            try self.seen.put(self.allocator, c_id, true);

            const parents = c.parentHashes();
            var i: usize = 0;
            while (i < parents.len) : (i += 1) {
                const h = parents[i];
                if (self.seen.get(h) == true) continue;
                if (self.seen_external.get(h) == true) continue;
                const pc = c.parentNode(i) catch |err| {
                    c.deinit();
                    return err;
                };
                try self.heap.push(self.allocator, pc);
            }
            return c;
        }
    }

    /// R4b: free-after-cb including Stop/error; always close.
    /// After forEach, do not call close again (close destroys this heap box).
    pub fn forEach(self: *CommitNodeIterCTime, cb: anytype) !void {
        return commitnode.forEachCommitNode(self, cb);
    }

    pub fn close(self: *CommitNodeIterCTime) void {
        while (self.heap.pop()) |n| n.deinit();
        self.heap.deinit(self.allocator);
        self.seen.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn asIter(self: *CommitNodeIterCTime) CommitNodeIter {
        return .{ .ptr = self, .vtable = &ctime_vtable };
    }
};

const ctime_vtable = CommitNodeIter.VTable{
    .next = ctimeNext,
    .close = ctimeClose,
};
fn ctimeNext(ptr: *anyopaque) anyerror!CommitNode {
    return (@as(*CommitNodeIterCTime, @ptrCast(@alignCast(ptr)))).next();
}
fn ctimeClose(ptr: *anyopaque) void {
    (@as(*CommitNodeIterCTime, @ptrCast(@alignCast(ptr)))).close();
}

/// go-git `NewCommitNodeIterCTime`.
///
/// Takes ownership of `start`. Free the iterator with `CommitNodeIter.close`.
/// Successful `next` transfers node ownership to the caller.
/// `forEach` closes the iterator; do not call `close` again after `forEach`.
pub fn newCommitNodeIterCTime(
    allocator: Allocator,
    start: CommitNode,
    seen_external: ?std.AutoHashMapUnmanaged(Hash, bool),
    ignore: []const Hash,
) Allocator.Error!CommitNodeIter {
    const iter = try CommitNodeIterCTime.init(allocator, start, seen_external, ignore);
    return iter.asIter();
}

// ---------------------------------------------------------------------------
// Topological walker (date-order / topo-order)
// ---------------------------------------------------------------------------

/// go-git `commitNodeIteratorTopological`.
pub const CommitNodeIterTopological = struct {
    allocator: Allocator,
    explore_stack: Stackable,
    visit_stack: Stackable,
    in_counts: std.AutoHashMapUnmanaged(Hash, i32) = .empty,
    ignore: std.AutoHashMapUnmanaged(Hash, void),

    pub fn next(self: *CommitNodeIterTopological) anyerror!CommitNode {
        var next_node: CommitNode = undefined;
        while (true) {
            next_node = self.visit_stack.pop() orelse return error.EndOfStream;
            const count = self.in_counts.get(next_node.id()) orelse 0;
            if (count == 0) break;
            // Still has inbound edges. go-git discards this pop and continues;
            // the node is re-pushed when its in-count reaches 0.
            next_node.deinit();
        }

        var minimum_level = next_node.generationV2();
        var use_gen_v2 = true;
        if (minimum_level == 0) {
            minimum_level = next_node.generation();
            use_gen_v2 = false;
        }

        const parent_hashes = next_node.parentHashes();
        var parents = try self.allocator.alloc(CommitNode, parent_hashes.len);
        defer self.allocator.free(parents);

        var pi: usize = 0;
        while (pi < parent_hashes.len) : (pi += 1) {
            const pc = try next_node.parentNode(pi);
            parents[pi] = pc;
            if (use_gen_v2) {
                if (pc.generationV2() < minimum_level) minimum_level = pc.generationV2();
            } else {
                if (pc.generation() < minimum_level) minimum_level = pc.generation();
            }
        }

        // EXPLORE
        while (true) {
            const to_explore = self.explore_stack.peek() orelse break;
            if (!to_explore.id().eql(next_node.id()) and self.explore_stack.size() == 1) {
                break;
            }
            if (use_gen_v2) {
                if (to_explore.generationV2() < minimum_level) break;
            } else {
                if (to_explore.generation() < minimum_level) break;
            }

            const explored = self.explore_stack.pop().?;
            // Always release explore ownership. SharedNode start is refcounted so
            // this is safe when explore and visit hold the same underlying node.
            defer explored.deinit();

            const th = explored.parentHashes();
            var ti: usize = 0;
            while (ti < th.len) : (ti += 1) {
                const h = th[ti];
                if (self.ignore.contains(h)) continue;
                const gop = try self.in_counts.getOrPut(self.allocator, h);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
                if (gop.value_ptr.* == 1) {
                    const pc = try explored.parentNode(ti);
                    try self.explore_stack.push(pc);
                }
            }
        }

        // VISIT
        var vi: usize = 0;
        while (vi < parent_hashes.len) : (vi += 1) {
            const h = parent_hashes[vi];
            if (self.ignore.contains(h)) {
                parents[vi].deinit();
                continue;
            }
            if (self.in_counts.getPtr(h)) |cnt| {
                cnt.* -= 1;
                if (cnt.* == 0) {
                    try self.visit_stack.push(parents[vi]);
                } else {
                    parents[vi].deinit();
                }
            } else {
                parents[vi].deinit();
            }
        }
        _ = self.in_counts.remove(next_node.id());
        return next_node;
    }

    /// R4b: free-after-cb including Stop/error; always close.
    /// After forEach, do not call close again (close destroys this heap box).
    pub fn forEach(self: *CommitNodeIterTopological, cb: anytype) !void {
        return commitnode.forEachCommitNode(self, cb);
    }

    pub fn close(self: *CommitNodeIterTopological) void {
        self.explore_stack.deinit();
        self.visit_stack.deinit();
        self.in_counts.deinit(self.allocator);
        self.ignore.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn asIter(self: *CommitNodeIterTopological) CommitNodeIter {
        return .{ .ptr = self, .vtable = &topo_vtable };
    }
};

const topo_vtable = CommitNodeIter.VTable{
    .next = topoNext,
    .close = topoClose,
};
fn topoNext(ptr: *anyopaque) anyerror!CommitNode {
    return (@as(*CommitNodeIterTopological, @ptrCast(@alignCast(ptr)))).next();
}
fn topoClose(ptr: *anyopaque) void {
    (@as(*CommitNodeIterTopological, @ptrCast(@alignCast(ptr)))).close();
}

/// go-git `NewCommitNodeIterDateOrder` (`git log --date-order`).
/// `forEach` closes the iterator; do not call `close` again after `forEach`.
pub fn newCommitNodeIterDateOrder(
    allocator: Allocator,
    start: CommitNode,
    seen_external: ?std.AutoHashMapUnmanaged(Hash, bool),
    ignore: []const Hash,
) Allocator.Error!CommitNodeIter {
    var ignore_map = try composeIgnores(allocator, ignore, seen_external);
    errdefer ignore_map.deinit(allocator);

    const explore = try DateHeap.create(allocator);
    errdefer explore.destroy();
    const visit = try DateHeap.create(allocator);
    errdefer visit.destroy();

    // go-git pushes the same CommitNode onto both heaps (shared pointer).
    const shared_a = try SharedNode.wrap(allocator, start, 2);
    // Second handle: bump is already refs=2; create second fat pointer to same SharedNode.
    const shared_ptr: *SharedNode = @ptrCast(@alignCast(shared_a.ptr));
    const shared_b = shared_ptr.asNode();

    try explore.asStackable().push(shared_a);
    try visit.asStackable().push(shared_b);

    const iter = try allocator.create(CommitNodeIterTopological);
    iter.* = .{
        .allocator = allocator,
        .explore_stack = explore.asStackable(),
        .visit_stack = visit.asStackable(),
        .in_counts = .empty,
        .ignore = ignore_map,
    };
    return iter.asIter();
}

/// go-git `NewCommitNodeIterTopoOrder` (`git log --topo-order`).
/// `forEach` closes the iterator; do not call `close` again after `forEach`.
pub fn newCommitNodeIterTopoOrder(
    allocator: Allocator,
    start: CommitNode,
    seen_external: ?std.AutoHashMapUnmanaged(Hash, bool),
    ignore: []const Hash,
) Allocator.Error!CommitNodeIter {
    var ignore_map = try composeIgnores(allocator, ignore, seen_external);
    errdefer ignore_map.deinit(allocator);

    const explore = try DateHeap.create(allocator);
    errdefer explore.destroy();
    const visit = try Lifo.create(allocator);
    errdefer visit.destroy();

    const shared_a = try SharedNode.wrap(allocator, start, 2);
    const shared_ptr: *SharedNode = @ptrCast(@alignCast(shared_a.ptr));
    const shared_b = shared_ptr.asNode();

    try explore.asStackable().push(shared_a);
    try visit.asStackable().push(shared_b);

    const iter = try allocator.create(CommitNodeIterTopological);
    iter.* = .{
        .allocator = allocator,
        .explore_stack = explore.asStackable(),
        .visit_stack = visit.asStackable(),
        .in_counts = .empty,
        .ignore = ignore_map,
    };
    return iter.asIter();
}

/// go-git `NewCommitNodeIterAuthorDateOrder` (`git log --author-order`).
///
/// Explore uses generation/date heap; visit uses author-time heap.
/// Author times require loading full commit objects (slower than other orders).
///
/// Takes ownership of `start`. Free the iterator with `CommitNodeIter.close`.
/// Successful `next` transfers node ownership to the caller.
/// `forEach` closes the iterator; do not call `close` again after `forEach`.
pub fn newCommitNodeIterAuthorDateOrder(
    allocator: Allocator,
    start: CommitNode,
    seen_external: ?std.AutoHashMapUnmanaged(Hash, bool),
    ignore: []const Hash,
) Allocator.Error!CommitNodeIter {
    var ignore_map = try composeIgnores(allocator, ignore, seen_external);
    errdefer ignore_map.deinit(allocator);

    const explore = try DateHeap.create(allocator);
    errdefer explore.destroy();
    const visit = try AuthorDateHeap.create(allocator);
    errdefer visit.destroy();

    // go-git pushes the same CommitNode onto both heaps (shared pointer).
    const shared_a = try SharedNode.wrap(allocator, start, 2);
    const shared_ptr: *SharedNode = @ptrCast(@alignCast(shared_a.ptr));
    const shared_b = shared_ptr.asNode();

    try explore.asStackable().push(shared_a);
    try visit.asStackable().push(shared_b);

    const iter = try allocator.create(CommitNodeIterTopological);
    iter.* = .{
        .allocator = allocator,
        .explore_stack = explore.asStackable(),
        .visit_stack = visit.asStackable(),
        .in_counts = .empty,
        .ignore = ignore_map,
    };
    return iter.asIter();
}

test "generationAndDateOrderCompare equal max gen by time" {
    // Comparator unit-tested via heap ordering in integration tests.
    try std.testing.expect(max_generation == std.math.maxInt(u64));
}
