//! Merge-base helpers (go-git `merge_base.go`).
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `(*Commit).MergeBase` | `mergeBase` / `mergeBaseWithLoader` |
//! | `(*Commit).IsAncestor` | `isAncestor` / `isAncestorWithLoader` |
//! | `Independents` | `independents` / `independentsWithLoader` |
//! | `errIsReachable` | `error.IsReachable` |
//!
//! # Ownership
//!
//! Walker yields under production loaders (`heap_owned=true`) are owned transfers
//! (R1). Free every non-retained yield with `freeCommit` on continue and break.
//!
//! **mergeBase / mergeBaseWithLoader**
//! - Never freeCommits the `self` / `other` inputs.
//! - During the walk: free every non-retained yield; walk roots are reloaded.
//! - IsReachable: return a **cloned** `*Commit` in a 1-slice (caller
//!   `freeCommit` each element, then free the slice). Prefer `freeMergeBaseResult`.
//! - Normal path: returned elements are walk-derived; caller freeCommits each,
//!   then frees the slice.
//!
//! **isAncestor / isAncestorWithLoader**
//! - Never freeCommits `self` / `other` (walk root reloaded like mergeBase).
//! - Free every walk yield on continue and match/break.
//!
//! **independents / independentsWithLoader**
//! - Never freeCommits original input tips.
//! - Walk yields while testing reachability: freeCommit every yield that is not
//!   pointer-equal to a still-needed candidate.
//! - Returned slice is a subset of input pointers; caller frees the slice only
//!   (elements remain caller-owned tips).

const std = @import("std");
const plumbing = @import("plumbing");

const commit_mod = @import("commit.zig");
const walker = @import("commit_walker.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Commit = commit_mod.Commit;
const freeCommit = commit_mod.freeCommit;
const HashSet = walker.HashSet;
const CommitLoader = walker.CommitLoader;
const CommitFilterCtx = walker.CommitFilterCtx;
const MemoryObject = plumbing.MemoryObject;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// go-git `errIsReachable` — first commit is reachable from the second.
pub const IsReachable = error{IsReachable};

/// Free merge-base results: `freeCommit` each element, then free the slice.
/// Safe for IsReachable clones and walk-derived survivors.
pub fn freeMergeBaseResult(allocator: Allocator, results: []*Commit) void {
    for (results) |c| freeCommit(allocator, c);
    allocator.free(results);
}

/// go-git `(*Commit).MergeBase`.
///
/// Best common ancestors of `self` and `other` that are not reachable from
/// other common ancestors. Caller owns the slice and each walk-derived /
/// cloned element (`freeMergeBaseResult` or freeCommit each + free slice).
pub fn mergeBase(self: *Commit, allocator: Allocator, other: *Commit) ![]*Commit {
    return mergeBaseWithLoader(self, allocator, other, walker.loaderFromCommit(self));
}

/// Like `mergeBase` with an explicit parent loader (unit tests).
pub fn mergeBaseWithLoader(
    self: *Commit,
    allocator: Allocator,
    other: *Commit,
    loader: CommitLoader,
) ![]*Commit {
    const sorted = try sortByCommitDateDesc(allocator, &.{ self, other });
    defer allocator.free(sorted);
    const newer = sorted[0];
    const older = sorted[1];

    var newer_history = ancestorsIndex(allocator, older, newer, loader) catch |err| {
        if (err == error.IsReachable) {
            // Uniform free path: clone so caller always freeCommits results.
            const cloned = try cloneCommit(allocator, older);
            errdefer freeCommit(allocator, cloned);
            const out = try allocator.alloc(*Commit, 1);
            out[0] = cloned;
            return out;
        }
        return err;
    };
    defer newer_history.deinit(allocator);

    var res: std.ArrayList(*Commit) = .empty;
    errdefer {
        for (res.items) |c| freeCommit(allocator, c);
        res.deinit(allocator);
    }

    // Reload walk root so FilterCommitIter invalid free never destroys inputs.
    const walk_from = try loader.get(older.hash);
    const idx_ctx: *anyopaque = @ptrCast(&newer_history);
    var res_iter = walker.newFilterCommitIterWithCtx(
        allocator,
        walk_from,
        loader,
        idx_ctx,
        isInIndexCommitFilter,
        idx_ctx,
        isInIndexCommitFilter,
    ) catch |err| {
        freeCommit(allocator, walk_from);
        return err;
    };
    defer res_iter.deinit();

    while (true) {
        const c = res_iter.next() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        var released = false;
        errdefer if (!released) freeCommit(allocator, c);
        try res.append(allocator, c);
        released = true;
    }

    // Transfer walk-derived candidates into independents (owns elements).
    const items = try res.toOwnedSlice(allocator);
    res = .empty;
    const owned = independentsOwnedWithLoader(allocator, items, loader) catch |err| {
        // On error independentsOwned freeCommits remaining candidates; free buffer only.
        allocator.free(items);
        return err;
    };
    allocator.free(items);
    return owned;
}

/// go-git `(*Commit).IsAncestor` — true if `self` is an ancestor of `other`
/// (including when hashes are equal). Uses `other.allocator` for the walk.
///
/// Never freeCommits `self` / `other`. The walk root is reloaded via `loader`
/// so inputs stay solely caller-owned (same discipline as mergeBase).
pub fn isAncestor(self: *const Commit, other: *Commit) !bool {
    return isAncestorWithLoader(self, other.allocator, other, walker.loaderFromCommit(other));
}

/// Like `isAncestor` with explicit allocator and parent loader.
pub fn isAncestorWithLoader(
    self: *const Commit,
    allocator: Allocator,
    other: *Commit,
    loader: CommitLoader,
) !bool {
    // Reload so free-each-yield never destroys the caller's `other` tip.
    const walk_tip = try loader.get(other.hash);
    var iter = walker.newCommitPreorderIterWithLoader(allocator, walk_tip, loader, null, &.{}) catch |err| {
        freeCommit(allocator, walk_tip);
        return err;
    };
    defer iter.deinit();

    var found = false;
    while (true) {
        const comm = iter.next() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (!comm.hash.eql(self.hash)) {
            freeCommit(allocator, comm);
            continue;
        }
        freeCommit(allocator, comm);
        found = true;
        break;
    }
    return found;
}

/// go-git `Independents` — subset of commits not reachable from the others.
/// Caller frees the returned slice only; elements are borrows of the inputs.
pub fn independents(allocator: Allocator, commits: []*Commit) ![]*Commit {
    if (commits.len == 0) {
        return try allocator.alloc(*Commit, 0);
    }
    return independentsWithLoader(allocator, commits, walker.loaderFromCommit(commits[0]));
}

/// Like `independents` with an explicit parent loader.
pub fn independentsWithLoader(
    allocator: Allocator,
    commits: []*Commit,
    loader: CommitLoader,
) ![]*Commit {
    return independentsImpl(allocator, commits, loader, false);
}

/// Independents over **owned** candidates (mergeBase walk-derived results).
/// Eliminated candidates are freeCommit'd; survivors remain owned by the caller.
fn independentsOwnedWithLoader(
    allocator: Allocator,
    commits: []*Commit,
    loader: CommitLoader,
) ![]*Commit {
    return independentsImpl(allocator, commits, loader, true);
}

fn independentsImpl(
    allocator: Allocator,
    commits: []*Commit,
    loader: CommitLoader,
    free_eliminated: bool,
) ![]*Commit {
    var candidates = sortByCommitDateDesc(allocator, commits) catch |err| {
        if (free_eliminated) {
            for (commits) |c| freeCommit(allocator, c);
        }
        return err;
    };
    errdefer {
        if (free_eliminated) {
            for (candidates) |c| freeCommit(allocator, c);
        }
        allocator.free(candidates);
    }

    {
        const deduped = removeDuplicated(allocator, candidates) catch |err| {
            return err; // errdefer frees candidates when free_eliminated
        };
        if (free_eliminated) {
            // Duplicates dropped from the slice are still owned walk-derived commits.
            for (candidates) |c| {
                if (!containsPtr(deduped, c)) freeCommit(allocator, c);
            }
        }
        allocator.free(candidates);
        candidates = deduped;
    }

    if (candidates.len < 2) {
        return candidates;
    }

    var seen: HashSet = .empty;
    defer seen.deinit(allocator);

    const LimitCtx = struct {
        seen: *HashSet,
    };
    var limit_state = LimitCtx{ .seen = &seen };
    const limit_fn: CommitFilterCtx = struct {
        fn call(ctx: *anyopaque, commit: *Commit) bool {
            const s: *LimitCtx = @ptrCast(@alignCast(ctx));
            return s.seen.get(commit.hash) != null;
        }
    }.call;

    var pos: usize = 0;
    while (true) {
        const from = candidates[pos];
        var others = try remove(allocator, candidates, from);
        defer allocator.free(others);

        // Reload walk root so filter invalid/seen free never destroys candidates.
        const walk_from = try loader.get(from.hash);
        var from_iter = walker.newFilterCommitIterWithCtx(
            allocator,
            walk_from,
            loader,
            null,
            null,
            @ptrCast(&limit_state),
            limit_fn,
        ) catch |err| {
            freeCommit(allocator, walk_from);
            return err;
        };
        defer from_iter.deinit();

        while (true) {
            const from_ancestor = from_iter.next() catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };

            // Yield is owned until freeCommit or intentional retain (candidate tip).
            const yield_hash = from_ancestor.hash;
            var yield_freed = false;
            errdefer if (!yield_freed and !containsPtr(candidates, from_ancestor)) {
                freeCommit(allocator, from_ancestor);
            };

            // Find at most one match (candidates are de-duplicated). Do not
            // free/rebuild `others` while iterating it.
            var matched: ?*Commit = null;
            for (others) |other| {
                if (yield_hash.eql(other.hash)) {
                    matched = other;
                    break;
                }
            }
            if (matched) |other| {
                const next_cand = try remove(allocator, candidates, other);
                if (free_eliminated) {
                    freeCommit(allocator, other);
                    if (from_ancestor == other) yield_freed = true;
                }
                allocator.free(candidates);
                candidates = next_cand;

                const next_others = try remove(allocator, others, other);
                allocator.free(others);
                others = next_others;
            }

            // Free non-retained walk yield. Skip pointer still held as a candidate
            // (identity-map loaders may yield the tip itself). Avoid double-free
            // when the yield is the eliminated candidate under free_eliminated.
            if (!yield_freed and !containsPtr(candidates, from_ancestor)) {
                freeCommit(allocator, from_ancestor);
                yield_freed = true;
            }

            if (candidates.len == 1) break; // go-git: storer.ErrStop

            // Hash already captured; put after free so OOM cannot leak the yield.
            try seen.put(allocator, yield_hash, {});
        }

        const idx = indexOf(candidates, from);
        if (idx < 0) break;
        const next_pos: usize = @intCast(idx + 1);
        if (next_pos >= candidates.len) break;
        pos = next_pos;
    }

    return candidates;
}

// ---------------------------------------------------------------------------
// Helpers (go-git private funcs)
// ---------------------------------------------------------------------------

/// go-git `ancestorsIndex`.
fn ancestorsIndex(
    allocator: Allocator,
    excluded: *Commit,
    starting: *Commit,
    loader: CommitLoader,
) !HashSet {
    if (excluded.hash.eql(starting.hash)) return error.IsReachable;

    var starting_history: HashSet = .empty;
    errdefer starting_history.deinit(allocator);

    // Reload so BFS free never destroys the public `starting` tip.
    const walk_start = try loader.get(starting.hash);
    var iter = walker.newCommitIterBsfWithLoader(allocator, walk_start, loader, null, &.{}) catch |err| {
        freeCommit(allocator, walk_start);
        return err;
    };
    defer iter.deinit();

    while (true) {
        const commit = iter.next() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (commit.hash.eql(excluded.hash)) {
            freeCommit(allocator, commit);
            return error.IsReachable;
        }
        const h = commit.hash;
        freeCommit(allocator, commit);
        try starting_history.put(allocator, h, {});
    }

    return starting_history;
}

/// go-git `isInIndexCommitFilter`.
fn isInIndexCommitFilter(ctx: *anyopaque, c: *Commit) bool {
    const index: *const HashSet = @ptrCast(@alignCast(ctx));
    return index.get(c.hash) != null;
}

/// Clone `src` into a new heap-owned `*Commit` for uniform mergeBase free.
fn cloneCommit(allocator: Allocator, src: *const Commit) !*Commit {
    var tmp = MemoryObject.init(allocator);
    defer tmp.deinit();
    try src.encode(&tmp);

    const c = try allocator.create(Commit);
    errdefer {
        c.deinit();
        allocator.destroy(c);
    }
    c.* = Commit.init(allocator);
    c.heap_owned = true;
    c.storer = src.storer;
    try c.decode(&tmp);
    c.hash = src.hash;
    return c;
}

fn containsPtr(haystack: []const *Commit, needle: *Commit) bool {
    for (haystack) |c| {
        if (c == needle) return true;
    }
    return false;
}

/// go-git `sortByCommitDateDesc` — committer.When descending.
fn sortByCommitDateDesc(allocator: Allocator, commits: []const *Commit) ![]*Commit {
    const sorted = try allocator.dupe(*Commit, commits);
    std.mem.sort(*Commit, sorted, {}, struct {
        fn less(_: void, a: *Commit, b: *Commit) bool {
            return a.committer.when > b.committer.when;
        }
    }.less);
    return sorted;
}

/// go-git `indexOf`.
fn indexOf(commits: []*Commit, target: *Commit) isize {
    for (commits, 0..) |commit, i| {
        if (target.hash.eql(commit.hash)) return @intCast(i);
    }
    return -1;
}

/// go-git `remove`.
fn remove(allocator: Allocator, commits: []*Commit, to_delete: *Commit) ![]*Commit {
    var list: std.ArrayList(*Commit) = .empty;
    errdefer list.deinit(allocator);
    for (commits) |commit| {
        if (commit.hash.eql(to_delete.hash)) continue;
        try list.append(allocator, commit);
    }
    return try list.toOwnedSlice(allocator);
}

/// go-git `removeDuplicated`.
fn removeDuplicated(allocator: Allocator, commits: []*Commit) ![]*Commit {
    var seen: HashSet = .empty;
    defer seen.deinit(allocator);

    var list: std.ArrayList(*Commit) = .empty;
    errdefer list.deinit(allocator);
    for (commits) |commit| {
        if (seen.get(commit.hash) != null) continue;
        try seen.put(allocator, commit.hash, {});
        try list.append(allocator, commit);
    }
    return try list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Unit tests — small in-memory DAGs
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

fn testHash(b: u8) Hash {
    var bytes: [plumbing.Size]u8 = .{0} ** plumbing.Size;
    bytes[0] = b;
    return Hash.fromBytes(bytes[0..]);
}

fn makeCommit(allocator: Allocator, hash: Hash, parents: []const Hash, when: i64) !Commit {
    var c = Commit.init(allocator);
    errdefer c.deinit();
    c.hash = hash;
    c.committer.when = when;
    c.author.when = when;
    if (parents.len > 0) {
        c.parent_hashes = try allocator.dupe(Hash, parents);
    }
    return c;
}

test "isAncestor true and false on linear history" {
    const gpa = std.testing.allocator;

    // C1 (tip, t=3) → C2 (t=2) → C3 (root, t=1)
    const h1 = testHash(1);
    const h2 = testHash(2);
    const h3 = testHash(3);

    var c3 = try makeCommit(gpa, h3, &.{}, 1);
    defer c3.deinit();
    var c2 = try makeCommit(gpa, h2, &.{h3}, 2);
    defer c2.deinit();
    var c1 = try makeCommit(gpa, h1, &.{h2}, 3);
    defer c1.deinit();

    var graph = TestGraph.init(gpa);
    defer graph.deinit();
    try graph.put(&c1);
    try graph.put(&c2);
    try graph.put(&c3);
    const loader = graph.loader();

    // C3 is ancestor of C1
    try std.testing.expect(try isAncestorWithLoader(&c3, gpa, &c1, loader));
    // C2 is ancestor of C1
    try std.testing.expect(try isAncestorWithLoader(&c2, gpa, &c1, loader));
    // C1 is ancestor of itself
    try std.testing.expect(try isAncestorWithLoader(&c1, gpa, &c1, loader));
    // C1 is not ancestor of C3
    try std.testing.expect(!(try isAncestorWithLoader(&c1, gpa, &c3, loader)));
    // C1 is not ancestor of C2
    try std.testing.expect(!(try isAncestorWithLoader(&c1, gpa, &c2, loader)));
}

test "mergeBase linear history returns older ancestor" {
    const gpa = std.testing.allocator;

    // C1 (t=3) → C2 (t=2) → C3 (t=1)
    const h1 = testHash(1);
    const h2 = testHash(2);
    const h3 = testHash(3);

    var c3 = try makeCommit(gpa, h3, &.{}, 1);
    defer c3.deinit();
    var c2 = try makeCommit(gpa, h2, &.{h3}, 2);
    defer c2.deinit();
    var c1 = try makeCommit(gpa, h1, &.{h2}, 3);
    defer c1.deinit();

    var graph = TestGraph.init(gpa);
    defer graph.deinit();
    try graph.put(&c1);
    try graph.put(&c2);
    try graph.put(&c3);
    const loader = graph.loader();

    // merge-base(C1, C2) == C2 (ancestor case → errIsReachable path)
    {
        const bases = try mergeBaseWithLoader(&c1, gpa, &c2, loader);
        defer freeMergeBaseResult(gpa, bases);
        try std.testing.expectEqual(@as(usize, 1), bases.len);
        try std.testing.expect(bases[0].hash.eql(h2));
        try std.testing.expect(bases[0].heap_owned); // clone
        try std.testing.expect(bases[0] != &c2);
    }

    // merge-base(C1, C3) == C3
    {
        const bases = try mergeBaseWithLoader(&c1, gpa, &c3, loader);
        defer freeMergeBaseResult(gpa, bases);
        try std.testing.expectEqual(@as(usize, 1), bases.len);
        try std.testing.expect(bases[0].hash.eql(h3));
        try std.testing.expect(bases[0].heap_owned);
    }

    // merge-base with self
    {
        const bases = try mergeBaseWithLoader(&c1, gpa, &c1, loader);
        defer freeMergeBaseResult(gpa, bases);
        try std.testing.expectEqual(@as(usize, 1), bases.len);
        try std.testing.expect(bases[0].hash.eql(h1));
        try std.testing.expect(bases[0].heap_owned);
    }
}

test "mergeBase divergent branches" {
    const gpa = std.testing.allocator;

    //     C1 (t=4)
    //    /
    //  C3 (t=2)   C2 (t=3)
    //    \       /
    //      C4 (t=1)
    const h1 = testHash(1);
    const h2 = testHash(2);
    const h3 = testHash(3);
    const h4 = testHash(4);

    var c4 = try makeCommit(gpa, h4, &.{}, 1);
    defer c4.deinit();
    var c3 = try makeCommit(gpa, h3, &.{h4}, 2);
    defer c3.deinit();
    var c2 = try makeCommit(gpa, h2, &.{h4}, 3);
    defer c2.deinit();
    var c1 = try makeCommit(gpa, h1, &.{h3}, 4);
    defer c1.deinit();

    var graph = TestGraph.init(gpa);
    defer graph.deinit();
    try graph.put(&c1);
    try graph.put(&c2);
    try graph.put(&c3);
    try graph.put(&c4);
    const loader = graph.loader();

    const bases = try mergeBaseWithLoader(&c1, gpa, &c2, loader);
    defer freeMergeBaseResult(gpa, bases);
    try std.testing.expectEqual(@as(usize, 1), bases.len);
    try std.testing.expect(bases[0].hash.eql(h4));
}

test "independents simple case" {
    const gpa = std.testing.allocator;

    // C1 (t=3) → C2 (t=2) → C3 (t=1)
    const h1 = testHash(1);
    const h2 = testHash(2);
    const h3 = testHash(3);

    var c3 = try makeCommit(gpa, h3, &.{}, 1);
    defer c3.deinit();
    var c2 = try makeCommit(gpa, h2, &.{h3}, 2);
    defer c2.deinit();
    var c1 = try makeCommit(gpa, h1, &.{h2}, 3);
    defer c1.deinit();

    var graph = TestGraph.init(gpa);
    defer graph.deinit();
    try graph.put(&c1);
    try graph.put(&c2);
    try graph.put(&c3);
    const loader = graph.loader();

    // Only C1 is independent among {C1, C2, C3}
    {
        var input = [_]*Commit{ &c1, &c2, &c3 };
        const result = try independentsWithLoader(gpa, input[0..], loader);
        defer gpa.free(result);
        try std.testing.expectEqual(@as(usize, 1), result.len);
        try std.testing.expect(result[0].hash.eql(h1));
        // Input-subset: result aliases an input tip.
        try std.testing.expect(result[0] == &c1);
    }

    // Single commit
    {
        var input = [_]*Commit{&c2};
        const result = try independentsWithLoader(gpa, input[0..], loader);
        defer gpa.free(result);
        try std.testing.expectEqual(@as(usize, 1), result.len);
        try std.testing.expect(result[0].hash.eql(h2));
        try std.testing.expect(result[0] == &c2);
    }

    // Two tips of a fork are both independent
    {
        const h5 = testHash(5);
        var c5 = try makeCommit(gpa, h5, &.{h3}, 4);
        defer c5.deinit();
        try graph.put(&c5);

        var input = [_]*Commit{ &c1, &c5 };
        const result = try independentsWithLoader(gpa, input[0..], loader);
        defer gpa.free(result);
        try std.testing.expectEqual(@as(usize, 2), result.len);
        // Order is by committer date desc: c5 (t=4), c1 (t=3)
        try std.testing.expect(result[0].hash.eql(h5));
        try std.testing.expect(result[1].hash.eql(h1));
    }
}

// ---------------------------------------------------------------------------
// Production-loader GPA tests (heap_owned=true)
// ---------------------------------------------------------------------------

const empty_tree_hex = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
const ObjectGetter = @import("storer").ObjectGetter;

fn storeCommit(
    gpa: Allocator,
    store: anytype,
    parents: []const Hash,
    when: i64,
) !Hash {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try body.writer.print("tree {s}\n", .{empty_tree_hex});
    for (parents) |p| {
        var hex: [plumbing.MaxHexSize]u8 = undefined;
        try body.writer.print("parent {s}\n", .{p.string(&hex)});
    }
    try body.writer.print(
        \\author W <w@w> {d} +0000
        \\committer W <w@w> {d} +0000
        \\
        \\m
    , .{ when, when });
    const obj = try store.newEncodedObject();
    obj.setType(.commit);
    try obj.setContent(body.written());
    return try store.setEncodedObject(obj);
}

fn productionLoader(gpa: Allocator, store: anytype) CommitLoader {
    return walker.loaderFromGetter(gpa, ObjectGetter.from(@TypeOf(store.*), store));
}

test "production isAncestor early match free yields zero leaks" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");

    var store = memory.Storage.init(gpa);
    defer store.deinit();
    const loader = productionLoader(gpa, &store);

    const h_root = try storeCommit(gpa, &store, &.{}, 1);
    const h_mid = try storeCommit(gpa, &store, &.{h_root}, 2);
    const h_tip = try storeCommit(gpa, &store, &.{h_mid}, 3);

    // Inputs stay caller-owned (walk root reloaded inside isAncestor).
    {
        const tip = try loader.get(h_tip);
        defer freeCommit(gpa, tip);
        const root = try loader.get(h_root);
        defer freeCommit(gpa, root);
        try std.testing.expect(try isAncestorWithLoader(root, gpa, tip, loader));
    }
    {
        const tip = try loader.get(h_tip);
        defer freeCommit(gpa, tip);
        const mid = try loader.get(h_mid);
        defer freeCommit(gpa, mid);
        try std.testing.expect(try isAncestorWithLoader(mid, gpa, tip, loader));
    }
    {
        const tip = try loader.get(h_tip);
        defer freeCommit(gpa, tip);
        const root = try loader.get(h_root);
        defer freeCommit(gpa, root);
        try std.testing.expect(!(try isAncestorWithLoader(tip, gpa, root, loader)));
    }
}

test "production isAncestor diamond free yields zero leaks" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");

    var store = memory.Storage.init(gpa);
    defer store.deinit();
    const loader = productionLoader(gpa, &store);

    //   tip (merge)
    //   |  \
    //  left right
    //    \  /
    //    base
    const h_base = try storeCommit(gpa, &store, &.{}, 1);
    const h_left = try storeCommit(gpa, &store, &.{h_base}, 2);
    const h_right = try storeCommit(gpa, &store, &.{h_base}, 3);
    const h_tip = try storeCommit(gpa, &store, &.{ h_left, h_right }, 4);

    const tip = try loader.get(h_tip);
    defer freeCommit(gpa, tip);
    const base = try loader.get(h_base);
    defer freeCommit(gpa, base);
    const left = try loader.get(h_left);
    defer freeCommit(gpa, left);

    try std.testing.expect(try isAncestorWithLoader(base, gpa, tip, loader));
    try std.testing.expect(try isAncestorWithLoader(left, gpa, tip, loader));
    try std.testing.expect(!(try isAncestorWithLoader(tip, gpa, base, loader)));
}

test "production mergeBase diamond free results zero leaks" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");

    var store = memory.Storage.init(gpa);
    defer store.deinit();
    const loader = productionLoader(gpa, &store);

    //   tip_a (t=4)   tip_b (t=3)
    //       \           /
    //        left(t=2) right is tip_b's parent chain via base
    //              \   /
    //              base (t=1)
    const h_base = try storeCommit(gpa, &store, &.{}, 1);
    const h_left = try storeCommit(gpa, &store, &.{h_base}, 2);
    const h_right = try storeCommit(gpa, &store, &.{h_base}, 3);
    const h_a = try storeCommit(gpa, &store, &.{h_left}, 4);
    const h_b = try storeCommit(gpa, &store, &.{h_right}, 5);

    const a = try loader.get(h_a);
    defer freeCommit(gpa, a);
    const b = try loader.get(h_b);
    defer freeCommit(gpa, b);

    const bases = try mergeBaseWithLoader(a, gpa, b, loader);
    defer freeMergeBaseResult(gpa, bases);
    try std.testing.expectEqual(@as(usize, 1), bases.len);
    try std.testing.expect(bases[0].hash.eql(h_base));
    try std.testing.expect(bases[0].heap_owned);
}

test "production mergeBase IsReachable clone does not free tip" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");

    var store = memory.Storage.init(gpa);
    defer store.deinit();
    const loader = productionLoader(gpa, &store);

    const h_root = try storeCommit(gpa, &store, &.{}, 1);
    const h_tip = try storeCommit(gpa, &store, &.{h_root}, 2);

    const tip = try loader.get(h_tip);
    defer freeCommit(gpa, tip);
    const root = try loader.get(h_root);
    defer freeCommit(gpa, root);

    const bases = try mergeBaseWithLoader(tip, gpa, root, loader);
    defer freeMergeBaseResult(gpa, bases);
    try std.testing.expectEqual(@as(usize, 1), bases.len);
    try std.testing.expect(bases[0].hash.eql(h_root));
    try std.testing.expect(bases[0].heap_owned);
    try std.testing.expect(bases[0] != root);
    // Tips still usable after freeMergeBaseResult of the clone.
    try std.testing.expect(tip.hash.eql(h_tip));
    try std.testing.expect(root.hash.eql(h_root));
}

test "production independents input-subset free slice only" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");

    var store = memory.Storage.init(gpa);
    defer store.deinit();
    const loader = productionLoader(gpa, &store);

    const h_root = try storeCommit(gpa, &store, &.{}, 1);
    const h_mid = try storeCommit(gpa, &store, &.{h_root}, 2);
    const h_tip = try storeCommit(gpa, &store, &.{h_mid}, 3);

    const tip = try loader.get(h_tip);
    defer freeCommit(gpa, tip);
    const mid = try loader.get(h_mid);
    defer freeCommit(gpa, mid);
    const root = try loader.get(h_root);
    defer freeCommit(gpa, root);

    var input = [_]*Commit{ tip, mid, root };
    const result = try independentsWithLoader(gpa, input[0..], loader);
    defer gpa.free(result); // slice only
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expect(result[0] == tip);
    try std.testing.expect(tip.hash.eql(h_tip));
}

test "production isAncestor stack-tip loader path zero leaks" {
    // heap_owned=false path: freeCommit is no-op; still correct.
    const gpa = std.testing.allocator;

    const h1 = testHash(0x11);
    const h2 = testHash(0x22);

    var c2 = try makeCommit(gpa, h2, &.{}, 1);
    defer c2.deinit();
    var c1 = try makeCommit(gpa, h1, &.{h2}, 2);
    defer c1.deinit();

    var graph = TestGraph.init(gpa);
    defer graph.deinit();
    try graph.put(&c1);
    try graph.put(&c2);
    const loader = graph.loader();

    try std.testing.expect(try isAncestorWithLoader(&c2, gpa, &c1, loader));
    try std.testing.expect(!(try isAncestorWithLoader(&c1, gpa, &c2, loader)));
}
