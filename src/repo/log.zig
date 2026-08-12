//! Repository log — go-git `Repository.Log` / `LogOptions`.
//!
//! Compatible storage backends support history walk with order / all / file /
//! path filter / since / until (unix seconds). No network.

const std = @import("std");
const plumbing = @import("plumbing");
const objpkg = @import("object");
const storer = @import("storer");
const memory = @import("memory");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const HexSize = plumbing.HexSize;
const MaxHexSize = plumbing.MaxHexSize;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;

// ---------------------------------------------------------------------------
// Log options (go-git `LogOrder` / `LogOptions`)
// ---------------------------------------------------------------------------

/// go-git `LogOrder`.
pub const LogOrder = enum(i8) {
    /// go-git `LogOrderDefault` — preorder DFS.
    default = 0,
    /// go-git `LogOrderDFS` — same as default (preorder).
    dfs = 1,
    /// go-git `LogOrderDFSPost` — post-order DFS.
    dfs_post = 2,
    /// go-git `LogOrderBSF` — breadth-first.
    bsf = 3,
    /// go-git `LogOrderCommitterTime` — committer-date priority.
    committer_time = 4,
};

/// go-git `LogOptions` (PathFilter as plain fn and optional context form).
pub const LogOptions = struct {
    /// When zero and `all` is false, HEAD is used (go-git `From`).
    from: Hash = ZeroHash,
    /// History walk order (go-git `Order`).
    order: LogOrder = .default,
    /// `git log --all`: walk every ref tip (+ HEAD). Ignores `from` when true.
    all: bool = false,
    /// `git log -- <file>`: only commits that insert/update this path.
    /// Compatibility field; ignored when a path filter callback is set.
    file_name: ?[]const u8 = null,
    /// go-git `PathFilter` — true when the changed path should match.
    path_filter: ?*const fn (path: []const u8) bool = null,
    /// Optional context pointer for `path_filter_ctx_fn`.
    path_filter_ctx: ?*anyopaque = null,
    /// Contextual path filter (Zig substitute for Go closures over state).
    /// When set, takes priority over `path_filter` and `file_name`.
    path_filter_ctx_fn: ?*const fn (ctx: *anyopaque, path: []const u8) bool = null,
    /// Inclusive lower bound on committer unix time (`git log --since`).
    since: ?i64 = null,
    /// Inclusive upper bound on committer unix time (`git log --until`).
    until: ?i64 = null,
};

/// Dummy context when `path_filter_ctx_fn` is set without `path_filter_ctx`.
var path_filter_dummy_ctx: u8 = 0;

// ---------------------------------------------------------------------------
// Log API
// ---------------------------------------------------------------------------

/// go-git `Log` — history walk with order / all / file / path / since / until.
///
/// Ownership:
/// - Caller owns every `*Commit` from `LogResult.next` (`freeCommit` when
///   `heap_owned`, or deinit+destroy for the single-from tip).
/// - `LogResult.deinit` frees walk state and an unyielded single-from tip.
/// - Limit/path filters free skipped heap-owned commits; the single-from tip
///   is marked `heap_owned=false` so only `LogResult` manages its lifetime.
/// - `all=true` uses `newCommitAllIterFromHashes` (path-list owns tips + walk
///   loads; `AllIter.close`/`deinit` frees unyielded path commits).
///
/// Path filter priority (one PathIter): `path_filter_ctx_fn` → `path_filter`
/// → `file_name` exact equality.
pub fn log(store: anytype, opts: LogOptions) !LogResult {
    const gpa = store.allocator;
    var result = LogResult{
        .allocator = gpa,
        .base = .none,
        .outer = undefined,
    };
    errdefer result.deinit();

    if (opts.all) {
        try initLogAll(store, &result);
    } else {
        try initLogFrom(store, &result, opts.from, opts.order);
    }

    // Path filter: ctx_fn > path_filter > file_name (exact_path).
    // Plain `path_filter` is wrapped as a ctx_fn so PathIter has one matching path.
    const check_parent = opts.all;
    if (opts.path_filter_ctx_fn) |ctx_fn| {
        const p = try gpa.create(objpkg.PathIter);
        errdefer gpa.destroy(p);
        const ctx: *anyopaque = opts.path_filter_ctx orelse @ptrCast(&path_filter_dummy_ctx);
        p.* = objpkg.newCommitPathIterFromIterCtx(gpa, ctx, ctx_fn, result.outer, check_parent);
        result.path = p;
        result.outer = p.asIter();
    } else if (opts.path_filter) |pf| {
        const p = try gpa.create(objpkg.PathIter);
        errdefer gpa.destroy(p);
        // Hold the function pointer in heap context (fn-as-anyopaque is not portable).
        const Holder = struct {
            f: *const fn (path: []const u8) bool,
            fn call(ctx: *anyopaque, path: []const u8) bool {
                const h: *@This() = @ptrCast(@alignCast(ctx));
                return h.f(path);
            }
        };
        const holder = try gpa.create(Holder);
        errdefer gpa.destroy(holder);
        holder.* = .{ .f = pf };
        p.* = objpkg.newCommitPathIterFromIterCtx(
            gpa,
            holder,
            Holder.call,
            result.outer,
            check_parent,
        );
        // PathIter does not own holder; free with path shell in LogResult.deinit.
        result.path_filter_holder = holder;
        result.path = p;
        result.outer = p.asIter();
    } else if (opts.file_name) |name| {
        const p = try gpa.create(objpkg.PathIter);
        errdefer gpa.destroy(p);
        // check_parent=true when all (go-git logWithFile).
        p.* = try objpkg.newCommitFileIterFromIter(gpa, name, result.outer, check_parent);
        result.path = p;
        result.outer = p.asIter();
    }

    if (opts.since != null or opts.until != null) {
        const lim = try gpa.create(objpkg.LimitIter);
        errdefer gpa.destroy(lim);
        lim.* = objpkg.newCommitLimitIterFromIter(result.outer, .{
            .since = opts.since,
            .until = opts.until,
        });
        result.limit = lim;
        result.outer = lim.asIter();
    }

    return result;
}

fn initLogFrom(
    store: anytype,
    result: *LogResult,
    from_opt: Hash,
    order: LogOrder,
) !void {
    const gpa = store.allocator;
    var from = from_opt;
    if (from.isZero()) {
        const href = try resolveBackendReference(store, plumbing.HEAD);
        defer store.freeReference(href);
        from = href.hash;
    }

    const tip = try objpkg.getCommit(gpa, store, from);
    // LogResult owns tip until yielded. Filters use freeCommit which only
    // destroys heap_owned commits — clear the flag so skips leave tip alone.
    tip.heap_owned = false;
    var tip_owned = true;
    errdefer if (tip_owned) {
        tip.deinit();
        gpa.destroy(tip);
    };

    try attachOrderWalk(result, tip, order);
    result.tip = tip;
    tip_owned = false;
}

fn attachOrderWalk(result: *LogResult, tip: *objpkg.Commit, order: LogOrder) !void {
    const gpa = result.allocator;
    switch (order) {
        .default, .dfs => {
            const w = try gpa.create(objpkg.PreorderIter);
            errdefer gpa.destroy(w);
            w.* = try objpkg.newCommitPreorderIter(gpa, tip, null, &.{});
            result.base = .{ .preorder = w };
            result.outer = w.asIter();
        },
        .dfs_post => {
            const w = try gpa.create(objpkg.PostorderIter);
            errdefer gpa.destroy(w);
            w.* = try objpkg.newCommitPostorderIter(gpa, tip, &.{});
            result.base = .{ .postorder = w };
            result.outer = w.asIter();
        },
        .bsf => {
            const w = try gpa.create(objpkg.BfsIter);
            errdefer gpa.destroy(w);
            w.* = try objpkg.newCommitIterBsf(gpa, tip, null, &.{});
            result.base = .{ .bfs = w };
            result.outer = w.asIter();
        },
        .committer_time => {
            const w = try gpa.create(objpkg.CTimeIter);
            errdefer gpa.destroy(w);
            w.* = try objpkg.newCommitIterCTime(gpa, tip, null, &.{});
            result.base = .{ .ctime = w };
            result.outer = w.asIter();
        },
    }
}

fn initLogAll(store: anytype, result: *LogResult) !void {
    const gpa = store.allocator;
    var hashes: std.ArrayList(Hash) = .empty;
    defer hashes.deinit(gpa);

    // go-git NewCommitAllIter: HEAD first (if present), then every reference.
    if (resolveBackendReference(store, plumbing.HEAD)) |href| {
        defer store.freeReference(href);
        try appendUniqueHash(&hashes, gpa, href.hash);
    } else |_| {}

    var ref_it = try store.iterReferences();
    defer ref_it.deinit();
    while (true) {
        const ref = ref_it.next() catch |err| switch (err) {
            error.EndOfStream => break,
        };
        if (ref.type == .hash) {
            try appendUniqueHash(&hashes, gpa, ref.hash);
        } else {
            const resolved = resolveBackendReference(store, ref.name) catch continue;
            defer store.freeReference(resolved);
            try appendUniqueHash(&hashes, gpa, resolved.hash);
        }
    }

    const getter = storer.ObjectGetter.from(@TypeOf(store.*), store);
    const all_ptr = try gpa.create(objpkg.AllIter);
    errdefer gpa.destroy(all_ptr);
    all_ptr.* = try objpkg.newCommitAllIterFromHashes(gpa, getter, hashes.items);
    result.base = .{ .all = all_ptr };
    result.outer = all_ptr.asIter();
}

fn resolveBackendReference(store: anytype, name: plumbing.ReferenceName) !plumbing.Reference {
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

fn appendUniqueHash(list: *std.ArrayList(Hash), allocator: Allocator, h: Hash) !void {
    if (h.isZero()) return;
    for (list.items) |existing| {
        if (existing.eql(h)) return;
    }
    try list.append(allocator, h);
}

// ---------------------------------------------------------------------------
// Log result
// ---------------------------------------------------------------------------

/// Owned log walk (go-git `Log` → `object.CommitIter`).
///
/// Prefer `next` / `deinit` on this type. `asIter` exposes a type-erased
/// `objpkg.CommitIter` for the outer filter chain (limit → path → base).
pub const LogResult = struct {
    allocator: Allocator,
    base: Base = .none,
    path: ?*objpkg.PathIter = null,
    /// Heap holder for plain `path_filter` fn when wrapped as ctx (freed on deinit).
    path_filter_holder: ?*anyopaque = null,
    limit: ?*objpkg.LimitIter = null,
    /// Single-`from` tip; null when `all=true`.
    tip: ?*objpkg.Commit = null,
    yielded_tip: bool = false,
    /// Outermost type-erased iterator.
    outer: objpkg.CommitIter,

    const Base = union(enum) {
        none,
        preorder: *objpkg.PreorderIter,
        postorder: *objpkg.PostorderIter,
        bfs: *objpkg.BfsIter,
        ctime: *objpkg.CTimeIter,
        all: *objpkg.AllIter,
    };

    /// Next commit in history. Caller owns the returned `*Commit`.
    pub fn next(self: *LogResult) anyerror!*objpkg.Commit {
        const c = try self.outer.next();
        if (self.tip) |t| {
            if (c == t) self.yielded_tip = true;
        }
        return c;
    }

    pub fn close(self: *LogResult) void {
        self.outer.close();
    }

    /// Free walk state. Single-from: frees tip if never yielded.
    /// `all`: `AllIter.deinit` frees unyielded path commits (R3).
    pub fn deinit(self: *LogResult) void {
        // Tear down outer filters without cascading into base, then free base.
        if (self.limit) |lim| {
            self.allocator.destroy(lim);
            self.limit = null;
        }
        if (self.path) |p| {
            // Free path-owned state. Do not close path.source (the base walker);
            // base is freed in the switch below. Tip is heap_owned=false so only
            // free heap-owned current (loaded parents still held by path).
            if (p.current_commit) |cc| {
                objpkg.freeCommit(self.allocator, cc);
                p.current_commit = null;
            }
            if (p.pending_parent_tree) |t| {
                objpkg.freeTree(self.allocator, t);
                p.pending_parent_tree = null;
            }
            if (p.exact_path) |ep| {
                self.allocator.free(ep);
                p.exact_path = null;
            }
            self.allocator.destroy(p);
            self.path = null;
        }
        if (self.path_filter_holder) |h| {
            // Holder is `{ f: *const fn... }` — one pointer wide.
            const Holder = struct { f: *const fn (path: []const u8) bool };
            self.allocator.destroy(@as(*Holder, @ptrCast(@alignCast(h))));
            self.path_filter_holder = null;
        }

        switch (self.base) {
            .none => {},
            .preorder => |w| {
                w.deinit();
                self.allocator.destroy(w);
            },
            .postorder => |w| {
                w.deinit();
                self.allocator.destroy(w);
            },
            .bfs => |w| {
                w.deinit();
                self.allocator.destroy(w);
            },
            .ctime => |w| {
                w.deinit();
                self.allocator.destroy(w);
            },
            .all => |w| {
                w.deinit();
                self.allocator.destroy(w);
            },
        }
        self.base = .none;

        if (self.tip) |t| {
            if (!self.yielded_tip) {
                // Tip is heap_owned=false so freeCommit would no-op; destroy fully.
                t.deinit();
                self.allocator.destroy(t);
            }
            self.tip = null;
        }
        self.* = undefined;
    }

    pub fn asIter(self: *LogResult) objpkg.CommitIter {
        return self.outer;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn storeBlob(s: *memory.Storage, content: []const u8) !Hash {
    const obj = try s.newEncodedObject();
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
    return storeCommitWhen(s, allocator, tree, parents, msg, 1);
}

fn storeCommitWhen(
    s: *memory.Storage,
    allocator: Allocator,
    tree: Hash,
    parents: []const Hash,
    msg: []const u8,
    when: i64,
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
    var when_buf: [32]u8 = undefined;
    const when_str = try std.fmt.bufPrint(&when_buf, "{d}", .{when});
    try buf.appendSlice(allocator, "author A <a@b> ");
    try buf.appendSlice(allocator, when_str);
    try buf.appendSlice(allocator, " +0000\n");
    try buf.appendSlice(allocator, "committer A <a@b> ");
    try buf.appendSlice(allocator, when_str);
    try buf.appendSlice(allocator, " +0000\n");
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, msg);
    const obj = try s.newEncodedObject();
    obj.setType(.commit);
    _ = try obj.write(buf.items);
    return s.setEncodedObject(obj);
}

/// Test helper: free a log yield. Single-from tip has `heap_owned=false` so
/// public `freeCommit` no-ops; always deinit+destroy for test-owned yields.
fn destroyLogCommit(gpa: Allocator, c: *objpkg.Commit) void {
    c.deinit();
    gpa.destroy(c);
}

fn collectLogHashes(gpa: Allocator, walk: *LogResult) ![]Hash {
    // Free after full walk: single-from tip is heap_owned=false; all-path yields
    // are heap_owned=true. destroyLogCommit handles both.
    var commits: std.ArrayList(*objpkg.Commit) = .empty;
    defer {
        for (commits.items) |c| destroyLogCommit(gpa, c);
        commits.deinit(gpa);
    }
    while (true) {
        const c = walk.next() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        try commits.append(gpa, c);
    }
    var list: std.ArrayList(Hash) = .empty;
    errdefer list.deinit(gpa);
    for (commits.items) |c| {
        try list.append(gpa, c.hash);
    }
    return try list.toOwnedSlice(gpa);
}

/// Fixture: root has other.txt; c1 adds tracked.txt; c2 mods it; c3 adds other beside.
const PathFixture = struct {
    c0: Hash,
    c1: Hash,
    c2: Hash,
    c3: Hash,
};

fn buildPathFixture(s: *memory.Storage, gpa: Allocator) !PathFixture {
    const blob_a1 = try storeBlob(s, "a1");
    const blob_a2 = try storeBlob(s, "a2");
    const blob_b = try storeBlob(s, "b");

    const t_root = try storeTree(s, gpa, blob_b, "other.txt");
    const t_add = try storeTree(s, gpa, blob_a1, "tracked.txt");
    const t_mod = try storeTree(s, gpa, blob_a2, "tracked.txt");
    // Final tree: other.txt + tracked.txt (sorted by name).
    var final_buf: std.ArrayList(u8) = .empty;
    defer final_buf.deinit(gpa);
    try final_buf.appendSlice(gpa, "100644 other.txt");
    try final_buf.append(gpa, 0);
    try final_buf.appendSlice(gpa, blob_b.slice());
    try final_buf.appendSlice(gpa, "100644 tracked.txt");
    try final_buf.append(gpa, 0);
    try final_buf.appendSlice(gpa, blob_a2.slice());
    const t_final_obj = try s.newEncodedObject();
    t_final_obj.setType(.tree);
    _ = try t_final_obj.write(final_buf.items);
    const t_final = try s.setEncodedObject(t_final_obj);

    const c0 = try storeCommit(s, gpa, t_root, &.{}, "root other\n");
    const c1 = try storeCommit(s, gpa, t_add, &.{c0}, "add tracked\n");
    const c2 = try storeCommit(s, gpa, t_mod, &.{c1}, "mod tracked\n");
    const c3 = try storeCommit(s, gpa, t_final, &.{c2}, "add other beside tracked\n");
    try s.setReference(Reference.newHashReference(plumbing.master, c3));
    return .{ .c0 = c0, .c1 = c1, .c2 = c2, .c3 = c3 };
}

test "log on small commit chain" {
    const gpa = std.testing.allocator;
    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    try s.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

    const blob_h = try storeBlob(s, "a");
    const tree_h = try storeTree(s, gpa, blob_h, "a.txt");
    const c0 = try storeCommit(s, gpa, tree_h, &.{}, "root\n");
    const c1 = try storeCommit(s, gpa, tree_h, &.{c0}, "child\n");
    const c2 = try storeCommit(s, gpa, tree_h, &.{c1}, "tip\n");
    try s.setReference(Reference.newHashReference(plumbing.master, c2));

    var walk = try log(s, .{});
    defer walk.deinit();

    const a = try walk.next();
    defer destroyLogCommit(gpa, a);
    try std.testing.expect(a.hash.eql(c2));

    const b = try walk.next();
    defer destroyLogCommit(gpa, b);
    try std.testing.expect(b.hash.eql(c1));

    const c = try walk.next();
    defer destroyLogCommit(gpa, c);
    try std.testing.expect(c.hash.eql(c0));

    try std.testing.expectError(error.EndOfStream, walk.next());

    var log2 = try log(s, .{ .from = c1 });
    defer log2.deinit();
    const d = try log2.next();
    defer destroyLogCommit(gpa, d);
    try std.testing.expect(d.hash.eql(c1));
}

test "log each LogOrder on linear chain" {
    const gpa = std.testing.allocator;
    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    try s.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
    const blob_h = try storeBlob(s, "a");
    const tree_h = try storeTree(s, gpa, blob_h, "a.txt");
    // Distinct committer times so committer_time order is well-defined.
    const c0 = try storeCommitWhen(s, gpa, tree_h, &.{}, "root\n", 100);
    const c1 = try storeCommitWhen(s, gpa, tree_h, &.{c0}, "child\n", 200);
    const c2 = try storeCommitWhen(s, gpa, tree_h, &.{c1}, "tip\n", 300);
    try s.setReference(Reference.newHashReference(plumbing.master, c2));

    const orders = [_]LogOrder{ .default, .dfs, .dfs_post, .bsf, .committer_time };
    for (orders) |order| {
        var walk = try log(s, .{ .order = order });
        defer walk.deinit();
        const hashes = try collectLogHashes(gpa, &walk);
        defer gpa.free(hashes);
        try std.testing.expectEqual(@as(usize, 3), hashes.len);
        // Linear history: all orders yield tip → … → root (postorder also tip-first).
        try std.testing.expect(hashes[0].eql(c2));
        try std.testing.expect(hashes[hashes.len - 1].eql(c0));
        var seen_c1 = false;
        for (hashes) |h| {
            if (h.eql(c1)) seen_c1 = true;
        }
        try std.testing.expect(seen_c1);
    }
}

test "log all walks multiple branch tips" {
    // GPA: AllIter path-list frees unyielded on deinit; yielded commits freed
    // by collectLogHashes.
    const gpa = std.testing.allocator;
    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    try s.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
    const blob_h = try storeBlob(s, "a");
    const tree_h = try storeTree(s, gpa, blob_h, "a.txt");
    const base = try storeCommit(s, gpa, tree_h, &.{}, "base\n");
    const master_tip = try storeCommit(s, gpa, tree_h, &.{base}, "master tip\n");
    const feature_tip = try storeCommit(s, gpa, tree_h, &.{base}, "feature tip\n");
    try s.setReference(Reference.newHashReference(plumbing.master, master_tip));
    try s.setReference(Reference.newHashReference(
        ReferenceName.init("refs/heads/feature"),
        feature_tip,
    ));

    var walk = try log(s, .{ .all = true });
    defer walk.deinit();
    const hashes = try collectLogHashes(gpa, &walk);
    defer gpa.free(hashes);

    try std.testing.expect(hashes.len >= 3);
    var seen_master = false;
    var seen_feature = false;
    var seen_base = false;
    for (hashes) |h| {
        if (h.eql(master_tip)) seen_master = true;
        if (h.eql(feature_tip)) seen_feature = true;
        if (h.eql(base)) seen_base = true;
    }
    try std.testing.expect(seen_master);
    try std.testing.expect(seen_feature);
    try std.testing.expect(seen_base);
}

test "log file_name filters path changes" {
    // Arena keeps storage + commits for multi-tree fixture construction.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    try s.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
    const fx = try buildPathFixture(s, gpa);

    var walk = try log(s, .{ .file_name = "tracked.txt" });
    defer walk.deinit();
    const hashes = try collectLogHashes(gpa, &walk);
    defer gpa.free(hashes);

    // c1 inserts tracked.txt, c2 modifies it; c3 only adds other.txt; c0 has other only.
    try std.testing.expect(hashes.len >= 1);
    var seen_add = false;
    var seen_mod = false;
    var seen_c3 = false;
    for (hashes) |h| {
        if (h.eql(fx.c1)) seen_add = true;
        if (h.eql(fx.c2)) seen_mod = true;
        if (h.eql(fx.c3)) seen_c3 = true;
    }
    try std.testing.expect(seen_add);
    try std.testing.expect(seen_mod);
    try std.testing.expect(!seen_c3);
}

test "log path_filter callback includes and excludes paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    try s.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
    const fx = try buildPathFixture(s, gpa);

    // Plain path_filter (go-git PathFilter) — equality via ctx_fn is the
    // portable Zig pattern; path_filter is also exercised below via holder wrap.
    var wanted: []const u8 = "tracked.txt";
    const eq_fn: *const fn (ctx: *anyopaque, path: []const u8) bool = struct {
        fn f(ctx: *anyopaque, path: []const u8) bool {
            const w: *const []const u8 = @ptrCast(@alignCast(ctx));
            return std.mem.eql(u8, path, w.*);
        }
    }.f;

    var walk = try log(s, .{
        .path_filter_ctx = @ptrCast(&wanted),
        .path_filter_ctx_fn = eq_fn,
    });
    defer walk.deinit();
    const hashes = try collectLogHashes(gpa, &walk);
    defer gpa.free(hashes);

    var seen_add = false;
    var seen_mod = false;
    var seen_c3 = false;
    for (hashes) |h| {
        if (h.eql(fx.c1)) seen_add = true;
        if (h.eql(fx.c2)) seen_mod = true;
        if (h.eql(fx.c3)) seen_c3 = true;
    }
    try std.testing.expect(seen_add);
    try std.testing.expect(seen_mod);
    try std.testing.expect(!seen_c3);

    wanted = "other.txt";
    var walk2 = try log(s, .{
        .path_filter_ctx = @ptrCast(&wanted),
        .path_filter_ctx_fn = eq_fn,
    });
    defer walk2.deinit();
    const hashes2 = try collectLogHashes(gpa, &walk2);
    defer gpa.free(hashes2);

    // c0 inserts other.txt; c1 replaces other with tracked (other deleted);
    // c3 re-adds other beside tracked. c2 only retouches tracked.
    var seen_other_root = false;
    var seen_other_c3 = false;
    var seen_c1_other_delete = false;
    var seen_c2 = false;
    for (hashes2) |h| {
        if (h.eql(fx.c0)) seen_other_root = true;
        if (h.eql(fx.c3)) seen_other_c3 = true;
        if (h.eql(fx.c1)) seen_c1_other_delete = true;
        if (h.eql(fx.c2)) seen_c2 = true;
    }
    try std.testing.expect(seen_other_root);
    try std.testing.expect(seen_other_c3);
    try std.testing.expect(seen_c1_other_delete);
    try std.testing.expect(!seen_c2);
}

test "log path_filter_ctx_fn with state excludes suffix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    try s.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
    const fx = try buildPathFixture(s, gpa);

    var wanted: []const u8 = "tracked.txt";
    const ctx_fn: *const fn (ctx: *anyopaque, path: []const u8) bool = struct {
        fn f(ctx: *anyopaque, path: []const u8) bool {
            const want: *[]const u8 = @ptrCast(@alignCast(ctx));
            return std.mem.eql(u8, path, want.*);
        }
    }.f;

    var walk = try log(s, .{
        .path_filter_ctx = @ptrCast(&wanted),
        .path_filter_ctx_fn = ctx_fn,
        // file_name must be ignored when ctx_fn is set
        .file_name = "other.txt",
    });
    defer walk.deinit();
    const hashes = try collectLogHashes(gpa, &walk);
    defer gpa.free(hashes);

    var seen_add = false;
    var seen_mod = false;
    var seen_c3 = false;
    for (hashes) |h| {
        if (h.eql(fx.c1)) seen_add = true;
        if (h.eql(fx.c2)) seen_mod = true;
        if (h.eql(fx.c3)) seen_c3 = true;
    }
    try std.testing.expect(seen_add);
    try std.testing.expect(seen_mod);
    try std.testing.expect(!seen_c3);
}

test "log since until by committer time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    try s.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
    const blob_h = try storeBlob(s, "a");
    const tree_h = try storeTree(s, gpa, blob_h, "a.txt");
    const c0 = try storeCommitWhen(s, gpa, tree_h, &.{}, "old\n", 100);
    const c1 = try storeCommitWhen(s, gpa, tree_h, &.{c0}, "mid\n", 200);
    const c2 = try storeCommitWhen(s, gpa, tree_h, &.{c1}, "new\n", 300);
    try s.setReference(Reference.newHashReference(plumbing.master, c2));

    var walk = try log(s, .{ .since = 150, .until = 250 });
    defer walk.deinit();
    const hashes = try collectLogHashes(gpa, &walk);
    defer gpa.free(hashes);

    try std.testing.expectEqual(@as(usize, 1), hashes.len);
    try std.testing.expect(hashes[0].eql(c1));
}
