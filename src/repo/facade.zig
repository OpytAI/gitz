//! Repository facades — go-git `repository.go` object/ref methods.
//!
//! Free functions take `*memory.Storage`. `Repository` wraps them as methods.
//!
//! Log matches go-git `Repository.Log` without network/worktree: all
//! `LogOrder` values, `All`, `FileName`, and `Since`/`Until` (unix seconds).

const std = @import("std");
const plumbing = @import("plumbing");
const objpkg = @import("object");
const storer = @import("storer");
const memory = @import("memory");
const revision = @import("revision");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const HexSize = plumbing.HexSize;
const ObjectType = plumbing.ObjectType;
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

/// go-git `LogOptions` (no `PathFilter` closure — use `file_name` for path equality).
pub const LogOptions = struct {
    /// When zero and `all` is false, HEAD is used (go-git `From`).
    from: Hash = ZeroHash,
    /// History walk order (go-git `Order`).
    order: LogOrder = .default,
    /// `git log --all`: walk every ref tip (+ HEAD). Ignores `from` when true.
    all: bool = false,
    /// `git log -- <file>`: only commits that insert/update this path.
    file_name: ?[]const u8 = null,
    /// Inclusive lower bound on committer unix time (`git log --since`).
    since: ?i64 = null,
    /// Inclusive upper bound on committer unix time (`git log --until`).
    until: ?i64 = null,
};

// ---------------------------------------------------------------------------
// Facade free functions
// ---------------------------------------------------------------------------


// --- Object getters ---

/// go-git `CommitObject`. Caller owns `*Commit` (`deinit` + `destroy`).
pub fn commitObject(store: *memory.Storage, h: Hash) !*objpkg.Commit {
    return objpkg.getCommit(store.allocator, store, h);
}

/// go-git `BlobObject`.
pub fn blobObject(store: *memory.Storage, h: Hash) !objpkg.Blob {
    return objpkg.getBlob(store, h);
}

/// go-git `TreeObject`. Caller frees with `objpkg.freeTree`.
pub fn treeObject(store: *memory.Storage, h: Hash) !*objpkg.Tree {
    return objpkg.getTree(store.allocator, store, h);
}

/// go-git `TagObject` — annotated tags only. Caller `deinit`s the Tag.
pub fn tagObject(store: *memory.Storage, h: Hash) !objpkg.Tag {
    return objpkg.getTag(store.allocator, store, h);
}

/// go-git `Object`. Caller `deinit`s the returned value.
pub fn object(store: *memory.Storage, t: ObjectType, h: Hash) !objpkg.Object {
    const enc = try store.encodedObject(t, h);
    return objpkg.decodeObject(store.allocator, store, enc);
}

// --- Object iterators ---

/// go-git `CommitObjects` — unsorted commits in the object store.
pub fn commitObjects(store: *memory.Storage) !EncodedCommitIter {
    const snap = try store.iterEncodedObjects(.commit);
    return EncodedCommitIter{
        .allocator = store.allocator,
        .storer = store,
        .snap = snap,
    };
}

/// go-git `BlobObjects`.
pub fn blobObjects(store: *memory.Storage) !BlobObjectsIter {
    return BlobObjectsIter{
        .snap = try store.iterEncodedObjects(.blob),
    };
}

/// go-git `TreeObjects`.
pub fn treeObjects(store: *memory.Storage) !objpkg.TreeIter {
    return objpkg.newTreeIter(store.allocator, store);
}

/// go-git `TagObjects`.
pub fn tagObjects(store: *memory.Storage) !TagObjectsIter {
    return TagObjectsIter{
        .allocator = store.allocator,
        .storer = store,
        .snap = try store.iterEncodedObjects(.tag),
    };
}

/// go-git `Objects`.
pub fn objects(store: *memory.Storage) !ObjectsIter {
    return ObjectsIter{
        .allocator = store.allocator,
        .storer = store,
        .snap = try store.iterEncodedObjects(.any),
    };
}

// --- Ref filters ---

/// go-git `Branches`.
pub fn branches(store: *memory.Storage) !FilteredRefIter {
    return FilteredRefIter.init(try store.iterReferences(), isBranchRef);
}

/// go-git `Tags` — tag *references* (lightweight or annotated).
pub fn tags(store: *memory.Storage) !FilteredRefIter {
    return FilteredRefIter.init(try store.iterReferences(), isTagRef);
}

/// go-git `Notes`.
pub fn notes(store: *memory.Storage) !FilteredRefIter {
    return FilteredRefIter.init(try store.iterReferences(), isNoteRef);
}

// --- Log ---

/// go-git `Log` — history walk with order / all / file / since / until.
///
/// Ownership:
/// - Caller owns every `*Commit` from `LogResult.next` (`deinit` + `destroy`).
/// - `LogResult.deinit` frees walk state. For single-`from` walks it also frees
///   the tip if `next` never returned it.
/// - For `all=true`, unyielded commits still on the merged path are freed on
///   `deinit`. Commits skipped by `since`/`until` or `file_name` follow walker
///   GC semantics (may leak unless the caller uses an arena).
///
/// Note: `all=true` merges tips with preorder history (go-git `NewCommitAllIter`
/// applies `commitIterFunc` per tip; this port uses `newCommitAllIterFromHashes`).
pub fn log(store: *memory.Storage, opts: LogOptions) !LogResult {
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

    if (opts.file_name) |name| {
        const p = try gpa.create(objpkg.PathIter);
        errdefer gpa.destroy(p);
        // check_parent=true when all (go-git logWithFile).
        p.* = try objpkg.newCommitFileIterFromIter(gpa, name, result.outer, opts.all);
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
    store: *memory.Storage,
    result: *LogResult,
    from_opt: Hash,
    order: LogOrder,
) !void {
    const gpa = store.allocator;
    var from = from_opt;
    if (from.isZero()) {
        const href = try storer.resolveReference(store, plumbing.HEAD);
        from = href.hash;
    }

    const tip = try commitObject(store, from);
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

fn initLogAll(store: *memory.Storage, result: *LogResult) !void {
    const gpa = store.allocator;
    var hashes: std.ArrayList(Hash) = .empty;
    defer hashes.deinit(gpa);

    // go-git NewCommitAllIter: HEAD first (if present), then every reference.
    if (storer.resolveReference(store, plumbing.HEAD)) |href| {
        try appendUniqueHash(&hashes, gpa, href.hash);
    } else |_| {}

    var ref_it = try store.iterReferences();
    defer ref_it.deinit();
    while (true) {
        const ref = ref_it.next() catch |err| switch (err) {
            error.EndOfStream => break,
        };
        const resolved = storer.resolveReferenceFrom(store, ref) catch continue;
        try appendUniqueHash(&hashes, gpa, resolved.hash);
    }

    const getter = storer.ObjectGetter.from(memory.Storage, store);
    const all_ptr = try gpa.create(objpkg.AllIter);
    errdefer gpa.destroy(all_ptr);
    all_ptr.* = try objpkg.newCommitAllIterFromHashes(gpa, getter, hashes.items);
    result.base = .{ .all = all_ptr };
    result.outer = all_ptr.asIter();
}

fn appendUniqueHash(list: *std.ArrayList(Hash), allocator: Allocator, h: Hash) !void {
    if (h.isZero()) return;
    for (list.items) |existing| {
        if (existing.eql(h)) return;
    }
    try list.append(allocator, h);
}

// --- ResolveRevision ---

/// go-git `ResolveRevision` — always resolves to a commit hash.
///
/// Supports: HEAD/branch/tag/ref expansion, full/prefix hash, `~`/`^`
/// parent walks, and `^{/pattern}` message search (literal / simple
/// substring; full RE2 is not required for the thin port).
pub fn resolveRevision(store: *memory.Storage, rev: []const u8) !Hash {
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
                var history = try objpkg.newCommitPreorderIter(gpa, cur, null, &.{});
                defer history.deinit();

                var found: ?*objpkg.Commit = null;
                while (true) {
                    const hc = history.next() catch |err| {
                        const e: anyerror = err;
                        if (e == error.EndOfStream) break;
                        return e;
                    };
                    const matches = messageMatches(hc.message, cr.pattern);
                    const ok = if (cr.negate) !matches else matches;
                    if (ok) {
                        found = hc;
                        break;
                    }
                    if (hc != cur) {
                        hc.deinit();
                        gpa.destroy(hc);
                    }
                }

                if (found) |fc| {
                    if (fc != cur) {
                        cur.deinit();
                        gpa.destroy(cur);
                        commit = fc;
                    }
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

    /// Free walk state. For single-from: frees tip if never yielded.
    /// For `all`: frees unyielded commits remaining on the merged path.
    pub fn deinit(self: *LogResult) void {
        // Free AllIter unyielded commits before close() nulls `curr`.
        if (self.base == .all) {
            const w = self.base.all;
            w.freeUnyielded();
            // Steal tip ownership so AllIter.deinit does not free caller-owned
            // yielded tips or double-free unyielded tips freed above.
            w.disownTips();
        }

        // Close outer chain (limit → path → base).
        if (self.base != .none) self.outer.close();

        if (self.limit) |lim| {
            self.allocator.destroy(lim);
            self.limit = null;
        }
        if (self.path) |p| {
            // close already ran via outer; free exact path + pending tree.
            if (p.exact_path) |ep| {
                self.allocator.free(ep);
                p.exact_path = null;
            }
            if (p.pending_parent_tree) |t| {
                objpkg.freeTree(self.allocator, t);
                p.pending_parent_tree = null;
            }
            // PathIter may hold a not-yet-returned current_commit.
            if (p.current_commit) |cc| {
                if (self.tip) |t| {
                    if (cc != t) {
                        cc.deinit();
                        self.allocator.destroy(cc);
                    }
                    // tip free handled below via yielded_tip
                } else {
                    // all=true: this commit was taken from the source before
                    // unyielded free (curr already advanced); free here.
                    cc.deinit();
                    self.allocator.destroy(cc);
                }
                p.current_commit = null;
            }
            self.allocator.destroy(p);
            self.path = null;
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
// Encoded object iterators
// ---------------------------------------------------------------------------

/// Unsorted commit iterator over the object store (go-git `CommitObjects`).
pub const EncodedCommitIter = struct {
    allocator: Allocator,
    storer: *memory.Storage,
    snap: memory.ObjectSnapshotIter,

    pub fn next(self: *EncodedCommitIter) !*objpkg.Commit {
        while (true) {
            const enc = try self.snap.next();
            if (enc.object_type != .commit) continue;
            return try objpkg.decodeCommit(self.allocator, self.storer, enc);
        }
    }

    pub fn forEach(self: *EncodedCommitIter, cb: anytype) !void {
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

    pub fn close(self: *EncodedCommitIter) void {
        self.snap.close();
    }

    pub fn deinit(self: *EncodedCommitIter) void {
        self.snap.deinit();
        self.* = undefined;
    }
};

/// Blob store iterator (go-git `BlobObjects`).
pub const BlobObjectsIter = struct {
    snap: memory.ObjectSnapshotIter,

    pub fn next(self: *BlobObjectsIter) !objpkg.Blob {
        while (true) {
            const enc = try self.snap.next();
            if (enc.object_type != .blob) continue;
            return try objpkg.decodeBlob(enc);
        }
    }

    pub fn forEach(self: *BlobObjectsIter, cb: anytype) !void {
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

    pub fn close(self: *BlobObjectsIter) void {
        self.snap.close();
    }

    pub fn deinit(self: *BlobObjectsIter) void {
        self.snap.deinit();
        self.* = undefined;
    }
};

/// Tag store iterator (go-git `TagObjects`).
pub const TagObjectsIter = struct {
    allocator: Allocator,
    storer: *memory.Storage,
    snap: memory.ObjectSnapshotIter,

    pub fn next(self: *TagObjectsIter) !objpkg.Tag {
        while (true) {
            const enc = try self.snap.next();
            if (enc.object_type != .tag) continue;
            return try objpkg.decodeTag(self.allocator, self.storer, enc);
        }
    }

    pub fn forEach(self: *TagObjectsIter, cb: anytype) !void {
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

    pub fn close(self: *TagObjectsIter) void {
        self.snap.close();
    }

    pub fn deinit(self: *TagObjectsIter) void {
        self.snap.deinit();
        self.* = undefined;
    }
};

/// Object store iterator (go-git `Objects`).
pub const ObjectsIter = struct {
    allocator: Allocator,
    storer: *memory.Storage,
    snap: memory.ObjectSnapshotIter,

    pub fn next(self: *ObjectsIter) !objpkg.Object {
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

    pub fn forEach(self: *ObjectsIter, cb: anytype) !void {
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

    pub fn close(self: *ObjectsIter) void {
        self.snap.close();
    }

    pub fn deinit(self: *ObjectsIter) void {
        self.snap.deinit();
        self.* = undefined;
    }
};

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

/// Filtered view over `memory.ReferenceSliceIter` (go-git `ReferenceFilteredIter`).
pub const FilteredRefIter = struct {
    inner: memory.ReferenceSliceIter,
    filter: *const fn (Reference) bool,

    pub fn init(inner: memory.ReferenceSliceIter, filter: *const fn (Reference) bool) FilteredRefIter {
        return .{ .inner = inner, .filter = filter };
    }

    pub fn next(self: *FilteredRefIter) !Reference {
        while (true) {
            const r = try self.inner.next();
            if (self.filter(r)) return r;
        }
    }

    pub fn forEach(self: *FilteredRefIter, cb: anytype) !void {
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

    pub fn close(self: *FilteredRefIter) void {
        self.inner.close();
    }

    pub fn deinit(self: *FilteredRefIter) void {
        self.inner.deinit();
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Helpers — expand_ref, expandPartialHash
// ---------------------------------------------------------------------------

/// go-git `expand_ref` — try `RefRevParseRules` until one resolves.
///
/// Rules mirror `plumbing.ref_rev_parse_rules`. Each format is a separate
/// `bufPrint` call so the format string is comptime-known.
fn expandRef(s: *memory.Storage, short: []const u8) ?Reference {
    if (resolveName(s, short)) |r| return r;

    var name_buf: [256]u8 = undefined;
    if (tryResolveFmt(s, &name_buf, "refs/{s}", short)) |r| return r;
    if (tryResolveFmt(s, &name_buf, "refs/tags/{s}", short)) |r| return r;
    if (tryResolveFmt(s, &name_buf, "refs/heads/{s}", short)) |r| return r;
    if (tryResolveFmt(s, &name_buf, "refs/remotes/{s}", short)) |r| return r;
    if (tryResolveFmt(s, &name_buf, "refs/remotes/{s}/HEAD", short)) |r| return r;
    return null;
}

fn resolveName(s: *memory.Storage, name_str: []const u8) ?Reference {
    const name = ReferenceName.init(name_str);
    return storer.resolveReference(s, name) catch null;
}

fn tryResolveFmt(
    s: *memory.Storage,
    buf: []u8,
    comptime fmt: []const u8,
    short: []const u8,
) ?Reference {
    const name_str = std.fmt.bufPrint(buf, fmt, .{short}) catch return null;
    return resolveName(s, name_str);
}

/// go-git `expandPartialHash` slow path over memory storage.
fn expandPartialHash(
    s: *memory.Storage,
    allocator: Allocator,
    prefix: []const u8,
) Allocator.Error![]Hash {
    var list: std.ArrayList(Hash) = .empty;
    errdefer list.deinit(allocator);

    var snap = try s.iterEncodedObjects(.any);
    defer snap.deinit();

    while (true) {
        const enc = snap.next() catch |err| switch (err) {
            error.EndOfStream => break,
        };
        const h = enc.hash();
        if (prefix.len == 0 or std.mem.startsWith(u8, h.bytes[0..], prefix)) {
            try list.append(allocator, h);
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn appendHashPrefix(s: *memory.Storage, hash_str: []const u8, out: *std.ArrayList(Hash)) !void {
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
            var hex: [HexSize]u8 = undefined;
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
        var hex: [HexSize]u8 = undefined;
        const str = h.string(&hex);
        if (std.mem.startsWith(u8, str, hash_str)) {
            try out.append(gpa, h);
        }
    }
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
    try buf.appendSlice(allocator, blob.bytes[0..]);
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
    var tree_hex: [HexSize]u8 = undefined;
    try buf.appendSlice(allocator, "tree ");
    try buf.appendSlice(allocator, tree.string(&tree_hex));
    try buf.append(allocator, '\n');
    for (parents) |p| {
        var ph: [HexSize]u8 = undefined;
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

fn freeCommit(gpa: Allocator, c: *objpkg.Commit) void {
    c.deinit();
    gpa.destroy(c);
}

fn collectLogHashes(gpa: Allocator, walk: *LogResult) ![]Hash {
    // Do not free commits until the walk is finished: preorder/BFS loaders may
    // still hold the tip (or parent chain) as a loader context.
    var commits: std.ArrayList(*objpkg.Commit) = .empty;
    defer {
        for (commits.items) |c| freeCommit(gpa, c);
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

test "log on small commit chain" {
    const gpa = std.testing.allocator;
    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    try s.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
    const r = s;

    const blob_h = try storeBlob(s, "a");
    const tree_h = try storeTree(s, gpa, blob_h, "a.txt");
    const c0 = try storeCommit(s, gpa, tree_h, &.{}, "root\n");
    const c1 = try storeCommit(s, gpa, tree_h, &.{c0}, "child\n");
    const c2 = try storeCommit(s, gpa, tree_h, &.{c1}, "tip\n");
    try s.setReference(Reference.newHashReference(plumbing.master, c2));

    var walk = try log(r, .{});
    defer walk.deinit();

    const a = try walk.next();
    defer freeCommit(gpa, a);
    try std.testing.expect(a.hash.eql(c2));

    const b = try walk.next();
    defer freeCommit(gpa, b);
    try std.testing.expect(b.hash.eql(c1));

    const c = try walk.next();
    defer freeCommit(gpa, c);
    try std.testing.expect(c.hash.eql(c0));

    try std.testing.expectError(error.EndOfStream, walk.next());

    var log2 = try log(r, .{ .from = c1 });
    defer log2.deinit();
    const d = try log2.next();
    defer freeCommit(gpa, d);
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
    // Arena: AllIter merge may leave transient parent loads (GC semantics).
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
    // Arena: path filter skips non-matching commits without free (GC semantics).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    try s.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

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
    try final_buf.appendSlice(gpa, blob_b.bytes[0..]);
    try final_buf.appendSlice(gpa, "100644 tracked.txt");
    try final_buf.append(gpa, 0);
    try final_buf.appendSlice(gpa, blob_a2.bytes[0..]);
    const t_final_obj = try s.newEncodedObject();
    t_final_obj.setType(.tree);
    _ = try t_final_obj.write(final_buf.items);
    const t_final = try s.setEncodedObject(t_final_obj);

    const c0 = try storeCommit(s, gpa, t_root, &.{}, "root other\n");
    const c1 = try storeCommit(s, gpa, t_add, &.{c0}, "add tracked\n");
    const c2 = try storeCommit(s, gpa, t_mod, &.{c1}, "mod tracked\n");
    const c3 = try storeCommit(s, gpa, t_final, &.{c2}, "add other beside tracked\n");
    try s.setReference(Reference.newHashReference(plumbing.master, c3));

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
        if (h.eql(c1)) seen_add = true;
        if (h.eql(c2)) seen_mod = true;
        if (h.eql(c3)) seen_c3 = true;
    }
    try std.testing.expect(seen_add);
    try std.testing.expect(seen_mod);
    try std.testing.expect(!seen_c3);
}

test "log since until by committer time" {
    // Arena: LimitIter skips non-matching commits without free (GC semantics).
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

    var hex: [HexSize]u8 = undefined;
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

    var br = try branches(r, );
    defer br.deinit();
    const bref = try br.next();
    try std.testing.expect(bref.name.isBranch());
    try std.testing.expect(bref.hash.eql(c1));

    var tg = try tags(r, );
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
