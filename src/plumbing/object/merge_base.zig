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
//! `mergeBase` / `independents` return a caller-owned slice of `*Commit`
//! (`allocator.free`). Pointers are borrowed from the walk / input set; the
//! caller does not free the commits through this slice.

const std = @import("std");
const plumbing = @import("plumbing");

const commit_mod = @import("commit.zig");
const walker = @import("commit_walker.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Commit = commit_mod.Commit;
const HashSet = walker.HashSet;
const CommitLoader = walker.CommitLoader;
const CommitFilterCtx = walker.CommitFilterCtx;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// go-git `errIsReachable` — first commit is reachable from the second.
pub const IsReachable = error{IsReachable};

/// go-git `(*Commit).MergeBase`.
///
/// Best common ancestors of `self` and `other` that are not reachable from
/// other common ancestors. Caller frees the returned slice.
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
            const out = try allocator.alloc(*Commit, 1);
            out[0] = older;
            return out;
        }
        return err;
    };
    defer newer_history.deinit(allocator);

    var res: std.ArrayList(*Commit) = .empty;
    defer res.deinit(allocator);

    const idx_ctx: *anyopaque = @ptrCast(&newer_history);
    var res_iter = try walker.newFilterCommitIterWithCtx(
        allocator,
        older,
        loader,
        idx_ctx,
        isInIndexCommitFilter,
        idx_ctx,
        isInIndexCommitFilter,
    );
    defer res_iter.deinit();

    while (true) {
        const c = res_iter.next() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        try res.append(allocator, c);
    }

    return independentsWithLoader(allocator, res.items, loader);
}

/// go-git `(*Commit).IsAncestor` — true if `self` is an ancestor of `other`
/// (including when hashes are equal). Uses `other.allocator` for the walk.
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
    var found = false;
    var iter = try walker.newCommitPreorderIterWithLoader(allocator, other, loader, null, &.{});
    defer iter.deinit();

    while (true) {
        const comm = iter.next() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (!comm.hash.eql(self.hash)) continue;
        found = true;
        break; // go-git: return storer.ErrStop from ForEach
    }
    return found;
}

/// go-git `Independents` — subset of commits not reachable from the others.
/// Caller frees the returned slice.
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
    var candidates = try sortByCommitDateDesc(allocator, commits);
    errdefer allocator.free(candidates);

    {
        const deduped = try removeDuplicated(allocator, candidates);
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

        var from_iter = try walker.newFilterCommitIterWithCtx(
            allocator,
            from,
            loader,
            null,
            null,
            @ptrCast(&limit_state),
            limit_fn,
        );
        defer from_iter.deinit();

        while (true) {
            const from_ancestor = from_iter.next() catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };

            // Find at most one match (candidates are de-duplicated). Do not
            // free/rebuild `others` while iterating it.
            var matched: ?*Commit = null;
            for (others) |other| {
                if (from_ancestor.hash.eql(other.hash)) {
                    matched = other;
                    break;
                }
            }
            if (matched) |other| {
                const next_cand = try remove(allocator, candidates, other);
                allocator.free(candidates);
                candidates = next_cand;

                const next_others = try remove(allocator, others, other);
                allocator.free(others);
                others = next_others;
            }

            if (candidates.len == 1) break; // go-git: storer.ErrStop

            try seen.put(allocator, from_ancestor.hash, {});
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

    var iter = try walker.newCommitIterBsfWithLoader(allocator, starting, loader, null, &.{});
    defer iter.deinit();

    while (true) {
        const commit = iter.next() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (commit.hash.eql(excluded.hash)) return error.IsReachable;
        try starting_history.put(allocator, commit.hash, {});
    }

    return starting_history;
}

/// go-git `isInIndexCommitFilter`.
fn isInIndexCommitFilter(ctx: *anyopaque, c: *Commit) bool {
    const index: *const HashSet = @ptrCast(@alignCast(ctx));
    return index.get(c.hash) != null;
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
        defer gpa.free(bases);
        try std.testing.expectEqual(@as(usize, 1), bases.len);
        try std.testing.expect(bases[0].hash.eql(h2));
    }

    // merge-base(C1, C3) == C3
    {
        const bases = try mergeBaseWithLoader(&c1, gpa, &c3, loader);
        defer gpa.free(bases);
        try std.testing.expectEqual(@as(usize, 1), bases.len);
        try std.testing.expect(bases[0].hash.eql(h3));
    }

    // merge-base with self
    {
        const bases = try mergeBaseWithLoader(&c1, gpa, &c1, loader);
        defer gpa.free(bases);
        try std.testing.expectEqual(@as(usize, 1), bases.len);
        try std.testing.expect(bases[0].hash.eql(h1));
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
    defer gpa.free(bases);
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
    }

    // Single commit
    {
        var input = [_]*Commit{&c2};
        const result = try independentsWithLoader(gpa, input[0..], loader);
        defer gpa.free(result);
        try std.testing.expectEqual(@as(usize, 1), result.len);
        try std.testing.expect(result[0].hash.eql(h2));
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
