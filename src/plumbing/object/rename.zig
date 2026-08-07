//! Rename detection on Changes (go-git `plumbing/object/rename.go`).
//!
//! Exact renames (identical blob hash + mode) first, then content similarity
//! via jgit `SimilarityIndex` when `only_exact_renames` is false.
//!
//! # Ownership
//!
//! `detectRenames` takes ownership of the input `Changes` (outer slice + every
//! `*Change`). On success the returned `Changes` owns the survivors. On error
//! every change is freed — including those already merged into renames.

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const change_mod = @import("change.zig");
const similarity_mod = @import("similarity.zig");
const error_mod = @import("error.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Change = change_mod.Change;
const Changes = change_mod.Changes;
const DiffTreeOptions = change_mod.DiffTreeOptions;
const SimilarityIndex = similarity_mod.SimilarityIndex;

const max_matrix_size: usize = 10_000;

/// Closed rename error set. Blob loads go through the storer; unknown backend
/// errors map to `error.DiffBackend` at the public `detectRenames` boundary.
pub const RenameError = error_mod.Error || Allocator.Error || plumbing.Error || similarity_mod.IndexFullError;

/// go-git `DetectRenames`.
///
/// Takes ownership of `changes`. On error every input change is freed.
pub fn detectRenames(
    allocator: Allocator,
    changes: Changes,
    opts: DiffTreeOptions,
) RenameError!Changes {
    return detectRenamesInner(allocator, changes, opts) catch |err| mapRenameErr(err);
}

fn mapRenameErr(err: anyerror) RenameError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.IndexFull => error.IndexFull,
        error.ObjectNotFound => error.ObjectNotFound,
        error.UnsupportedObject => error.UnsupportedObject,
        error.MalformedChange => error.MalformedChange,
        error.FileNotFound => error.FileNotFound,
        error.Canceled => error.Canceled,
        error.DiffBackend => error.DiffBackend,
        else => error.DiffBackend,
    };
}

fn detectRenamesInner(
    allocator: Allocator,
    changes: Changes,
    opts: DiffTreeOptions,
) anyerror!Changes {
    var detector = RenameDetector{
        .allocator = allocator,
        .rename_score = @intCast(opts.rename_score),
        .rename_limit = @intCast(opts.rename_limit),
        .only_exact = opts.only_exact_renames,
    };
    // On success detect() empties lists; on error frees all remaining nodes.
    defer detector.deinit();

    var items = changes.items;
    var taken: usize = 0;
    var slice_owned = items.len > 0;
    errdefer {
        // Destroy changes not yet moved into the detector.
        if (taken < items.len) {
            for (items[taken..]) |c| c.destroy(allocator);
        }
        if (slice_owned) allocator.free(items);
    }

    for (items) |c| {
        const act = try c.action();
        switch (act) {
            .insert => try detector.added.append(allocator, c),
            .delete => try detector.deleted.append(allocator, c),
            .modify => try detector.modified.append(allocator, c),
        }
        taken += 1;
    }
    // All *Change nodes live in detector; free only the outer slice.
    if (slice_owned) {
        allocator.free(items);
        slice_owned = false;
    }

    return try detector.detect();
}

const RenameDetector = struct {
    allocator: Allocator,
    added: std.ArrayList(*Change) = .empty,
    deleted: std.ArrayList(*Change) = .empty,
    modified: std.ArrayList(*Change) = .empty,
    rename_score: i32,
    rename_limit: i32,
    only_exact: bool,

    fn deinit(self: *RenameDetector) void {
        for (self.added.items) |c| c.destroy(self.allocator);
        for (self.deleted.items) |c| c.destroy(self.allocator);
        for (self.modified.items) |c| c.destroy(self.allocator);
        self.added.deinit(self.allocator);
        self.deleted.deinit(self.allocator);
        self.modified.deinit(self.allocator);
    }

    fn detect(self: *RenameDetector) RenameError!Changes {
        if (self.added.items.len > 0 and self.deleted.items.len > 0) {
            try self.detectExactRenames();
            if (!self.only_exact) try self.detectContentRenames();
        }

        var result: std.ArrayList(*Change) = .empty;
        errdefer {
            for (result.items) |c| c.destroy(self.allocator);
            result.deinit(self.allocator);
        }
        try result.appendSlice(self.allocator, self.added.items);
        try result.appendSlice(self.allocator, self.deleted.items);
        try result.appendSlice(self.allocator, self.modified.items);

        // Ownership moved; clear without destroy.
        self.added.clearRetainingCapacity();
        self.deleted.clearRetainingCapacity();
        self.modified.clearRetainingCapacity();

        var out: Changes = .{
            .items = try result.toOwnedSlice(self.allocator),
            .allocator = self.allocator,
        };
        out.sort();
        return out;
    }

    fn detectExactRenames(self: *RenameDetector) Allocator.Error!void {
        // Snapshot lists, clear detector so deinit never double-frees paired shells.
        var added_src = self.added;
        var deleted_src = self.deleted;
        self.added = .empty;
        self.deleted = .empty;

        var paired: std.AutoHashMap(*Change, void) = .init(self.allocator);
        defer paired.deinit();

        errdefer {
            // Free unpaired source items; paired shells already destroyed.
            for (added_src.items) |c| {
                if (!paired.contains(c)) c.destroy(self.allocator);
            }
            for (deleted_src.items) |c| {
                if (!paired.contains(c)) c.destroy(self.allocator);
            }
            added_src.deinit(self.allocator);
            deleted_src.deinit(self.allocator);
        }

        var added_by = try groupByHash(self.allocator, added_src.items);
        defer freeHashGroups(self.allocator, &added_by);
        var deletes_by = try groupByHash(self.allocator, deleted_src.items);
        defer freeHashGroups(self.allocator, &deletes_by);

        var added_left: std.ArrayList(*Change) = .empty;
        errdefer added_left.deinit(self.allocator);

        var it = added_by.iterator();
        while (it.next()) |e| {
            const hash = e.key_ptr.*;
            const adds = e.value_ptr.*;
            const dels_opt = deletes_by.get(hash);

            if (adds.len == 1) {
                const c = adds[0];
                if (dels_opt) |dels| {
                    if (try self.tryExactPair(c, dels, hash, &deletes_by, &paired)) continue;
                }
                try added_left.append(self.allocator, c);
            } else if (dels_opt) |dels| {
                if (dels.len == 1) {
                    const del = dels[0];
                    if (bestNameMatch(del, adds)) |best| {
                        if (sameMode(del, best)) {
                            try self.pairRename(del, best, &paired);
                            removeHashGroup(&deletes_by, hash, self.allocator);
                            for (adds) |a| {
                                if (a != best) try added_left.append(self.allocator, a);
                            }
                            continue;
                        }
                    }
                    try added_left.appendSlice(self.allocator, adds);
                } else {
                    try self.matchMultiExact(adds, dels, hash, &deletes_by, &added_left, &paired);
                }
            } else {
                try added_left.appendSlice(self.allocator, adds);
            }
        }

        // Rebuild deleted from remaining hash groups.
        var deleted_left: std.ArrayList(*Change) = .empty;
        errdefer deleted_left.deinit(self.allocator);
        var dit = deletes_by.iterator();
        while (dit.next()) |e| {
            try deleted_left.appendSlice(self.allocator, e.value_ptr.*);
        }

        // Success: source list buffers only (items live in left lists or were paired).
        added_src.deinit(self.allocator);
        deleted_src.deinit(self.allocator);
        // Prevent errdefer from running on success — mark by emptying.
        added_src = .empty;
        deleted_src = .empty;

        self.added = added_left;
        self.deleted = deleted_left;
    }

    fn tryExactPair(
        self: *RenameDetector,
        add: *Change,
        dels: []*Change,
        hash: Hash,
        deletes_by: *std.AutoHashMap(Hash, []*Change),
        paired: *std.AutoHashMap(*Change, void),
    ) Allocator.Error!bool {
        if (dels.len == 1) {
            if (sameMode(add, dels[0])) {
                try self.pairRename(dels[0], add, paired);
                removeHashGroup(deletes_by, hash, self.allocator);
                return true;
            }
            return false;
        }
        if (bestNameMatch(add, dels)) |best| {
            if (sameMode(add, best)) {
                try self.pairRename(best, add, paired);
                try removeFromGroup(deletes_by, hash, best, self.allocator);
                return true;
            }
        }
        return false;
    }

    fn matchMultiExact(
        self: *RenameDetector,
        adds: []*Change,
        dels: []*Change,
        hash: Hash,
        deletes_by: *std.AutoHashMap(Hash, []*Change),
        added_left: *std.ArrayList(*Change),
        paired: *std.AutoHashMap(*Change, void),
    ) Allocator.Error!void {
        // Use the precomputed content `hash` — never call changeHash on a shell
        // after pairRename (shells are zeroed/destroyed; that would yield ZeroHash
        // and leave the real group dangling → double-free on deinit).
        var matrix: std.ArrayList(SimilarityPair) = .empty;
        defer matrix.deinit(self.allocator);

        var max_size: usize = dels.len * adds.len;
        if (self.rename_limit > 0 and @as(usize, @intCast(self.rename_limit)) < max_size) {
            max_size = @intCast(self.rename_limit);
        }

        outer: for (dels, 0..) |del, di| {
            const dname = del.name();
            for (adds, 0..) |add, ai| {
                const score = nameSimilarityScore(add.name(), dname);
                try matrix.append(self.allocator, .{ .added = ai, .deleted = di, .score = score });
                if (matrix.items.len >= max_size) break :outer;
            }
        }
        sortPairsAscending(matrix.items);

        var used_add = try self.allocator.alloc(bool, adds.len);
        defer self.allocator.free(used_add);
        @memset(used_add, false);
        var used_del = try self.allocator.alloc(bool, dels.len);
        defer self.allocator.free(used_del);
        @memset(used_del, false);

        var i: isize = @intCast(matrix.items.len);
        i -= 1;
        while (i >= 0) : (i -= 1) {
            const pair = matrix.items[@intCast(i)];
            if (used_add[pair.added] or used_del[pair.deleted]) continue;
            if (!sameMode(adds[pair.added], dels[pair.deleted])) continue;
            used_add[pair.added] = true;
            used_del[pair.deleted] = true;
            try self.pairRename(dels[pair.deleted], adds[pair.added], paired);
        }
        for (adds, 0..) |a, ai| {
            if (!used_add[ai]) try added_left.append(self.allocator, a);
        }

        var remain: std.ArrayList(*Change) = .empty;
        defer remain.deinit(self.allocator);
        for (dels, 0..) |d, di| {
            if (!used_del[di]) try remain.append(self.allocator, d);
        }
        if (remain.items.len == 0) {
            removeHashGroup(deletes_by, hash, self.allocator);
        } else {
            const slice = try self.allocator.dupe(*Change, remain.items);
            if (deletes_by.fetchRemove(hash)) |old| self.allocator.free(old.value);
            try deletes_by.put(hash, slice);
        }
    }

    /// Merge delete+insert into a modify. Steals name ownership; destroys shells.
    ///
    /// On success `del`/`add` are destroyed and recorded in `paired` so parent
    /// errdefers skip them. `mod` is owned by `self.modified`.
    fn pairRename(
        self: *RenameDetector,
        del: *Change,
        add: *Change,
        paired: *std.AutoHashMap(*Change, void),
    ) Allocator.Error!void {
        // Mark in `paired` first so parent errdefers never free these pointers once
        // we steal names. If put fails, del/add are still intact and not taken.
        var shells_taken = false;
        try paired.put(del, {});
        errdefer {
            if (!shells_taken) _ = paired.remove(del);
        }
        try paired.put(add, {});
        errdefer {
            if (!shells_taken) _ = paired.remove(add);
        }

        const mod = try self.allocator.create(Change);
        mod.* = .{
            .from = del.from,
            .to = add.to,
        };
        // Sever name ownership so shell destroy is a pure free of the node.
        del.* = .{};
        add.* = .{};
        shells_taken = true;

        self.modified.append(self.allocator, mod) catch |err| {
            // Names live in mod; free mod + shells once. Stay in `paired` so
            // parent errdefers skip the destroyed shells (no silent put).
            mod.destroy(self.allocator);
            self.allocator.destroy(del);
            self.allocator.destroy(add);
            return err;
        };
        // `mod` is owned by `modified` now.
        self.allocator.destroy(del);
        self.allocator.destroy(add);
    }

    /// Content path without a paired set: uses nulling arrays (go-git style).
    fn detectContentRenames(self: *RenameDetector) RenameError!void {
        const cnt = @max(self.added.items.len, self.deleted.items.len);
        if (self.rename_limit > 0 and cnt > @as(usize, @intCast(self.rename_limit))) return;

        const n_src = self.deleted.items.len;
        const n_dst = self.added.items.len;

        var srcs = try self.allocator.alloc(?*Change, n_src);
        defer self.allocator.free(srcs);
        for (self.deleted.items, 0..) |c, i| srcs[i] = c;

        var dsts = try self.allocator.alloc(?*Change, n_dst);
        defer self.allocator.free(dsts);
        for (self.added.items, 0..) |c, i| dsts[i] = c;

        // Snapshot pointer slices for matrix build (stable for duration).
        const src_slice = self.deleted.items;
        const dst_slice = self.added.items;
        const matrix = try buildSimilarityMatrix(self.allocator, src_slice, dst_slice, self.rename_score);
        defer self.allocator.free(matrix);

        // Clear lists before pairing so deinit never sees destroyed shells.
        var old_added = self.added;
        var old_deleted = self.deleted;
        self.added = .empty;
        self.deleted = .empty;

        var paired: std.AutoHashMap(*Change, void) = .init(self.allocator);
        defer paired.deinit();

        errdefer {
            for (old_added.items) |c| {
                if (!paired.contains(c)) c.destroy(self.allocator);
            }
            for (old_deleted.items) |c| {
                if (!paired.contains(c)) c.destroy(self.allocator);
            }
            old_added.deinit(self.allocator);
            old_deleted.deinit(self.allocator);
        }

        var i: isize = @intCast(matrix.len);
        i -= 1;
        while (i >= 0) : (i -= 1) {
            const pair = matrix[@intCast(i)];
            const src = srcs[pair.deleted] orelse continue;
            const dst = dsts[pair.added] orelse continue;
            try self.pairRename(src, dst, &paired);
            srcs[pair.deleted] = null;
            dsts[pair.added] = null;
        }

        var new_added: std.ArrayList(*Change) = .empty;
        errdefer new_added.deinit(self.allocator);
        for (dsts) |d| {
            if (d) |c| try new_added.append(self.allocator, c);
        }
        var new_deleted: std.ArrayList(*Change) = .empty;
        errdefer new_deleted.deinit(self.allocator);
        for (srcs) |s| {
            if (s) |c| try new_deleted.append(self.allocator, c);
        }

        old_added.deinit(self.allocator);
        old_deleted.deinit(self.allocator);
        old_added = .empty;
        old_deleted = .empty;

        self.added = new_added;
        self.deleted = new_deleted;
    }
};

const SimilarityPair = struct {
    added: usize,
    deleted: usize,
    score: i32,
};

fn sortPairsAscending(items: []SimilarityPair) void {
    std.mem.sort(SimilarityPair, items, {}, struct {
        fn less(_: void, a: SimilarityPair, b: SimilarityPair) bool {
            if (a.score == b.score) {
                if (a.added == b.added) return a.deleted < b.deleted;
                return a.added < b.added;
            }
            return a.score < b.score;
        }
    }.less);
}

/// go-git `buildSimilarityMatrix` with jgit SimilarityIndex scoring.
fn buildSimilarityMatrix(
    allocator: Allocator,
    srcs: []*Change,
    dsts: []*Change,
    rename_score: i32,
) RenameError![]SimilarityPair {
    var matrix: std.ArrayList(SimilarityPair) = .empty;
    errdefer matrix.deinit(allocator);

    var src_sizes = try allocator.alloc(i64, srcs.len);
    defer allocator.free(src_sizes);
    @memset(src_sizes, 0);
    var dst_sizes = try allocator.alloc(i64, dsts.len);
    defer allocator.free(dst_sizes);
    @memset(dst_sizes, 0);
    const dst_too_large = try allocator.alloc(bool, dsts.len);
    defer allocator.free(dst_too_large);
    @memset(dst_too_large, false);

    var src_indexes = try allocator.alloc(?SimilarityIndex, srcs.len);
    defer {
        for (src_indexes) |*opt| {
            if (opt.*) |*idx| idx.deinit();
        }
        allocator.free(src_indexes);
    }
    @memset(src_indexes, null);

    outer: for (srcs, 0..) |src, src_idx| {
        // go-git: Regular only.
        if (changeMode(src) != filemode.Regular) continue;

        for (dsts, 0..) |dst, dst_idx| {
            if (changeMode(dst) != filemode.Regular) continue;
            if (dst_too_large[dst_idx]) continue;

            if (src_sizes[src_idx] == 0) {
                const sides = try src.files();
                const from = sides.from orelse continue;
                src_sizes[src_idx] = from.blob.size + 1;
            }
            if (dst_sizes[dst_idx] == 0) {
                const sides = try dst.files();
                const to = sides.to orelse continue;
                dst_sizes[dst_idx] = to.blob.size + 1;
            }

            const src_size = src_sizes[src_idx];
            const dst_size = dst_sizes[dst_idx];
            const min_sz = @min(src_size, dst_size);
            const max_sz = @max(src_size, dst_size);
            if (@divTrunc(min_sz * 100, max_sz) < rename_score) continue;

            if (src_indexes[src_idx] == null) {
                const sides = try src.files();
                const from = sides.from orelse continue;
                src_indexes[src_idx] = SimilarityIndex.fromFile(allocator, &from) catch |err| {
                    if (err == error.IndexFull) continue :outer;
                    return err;
                };
            }

            const sides_to = try dst.files();
            const to = sides_to.to orelse continue;
            // Intentionally diverge from go-git: go-git marks dstTooLarge then
            // still `return err` (aborts the whole matrix). Skip this destination
            // and keep scoring other pairs — same as the source-side IndexFull
            // path (`continue outerLoop`) and jgit's "too large" intent.
            var di = SimilarityIndex.fromFile(allocator, &to) catch |err| {
                if (err == error.IndexFull) {
                    noteDstIndexFull(dst_too_large, dst_idx);
                    continue;
                }
                return err;
            };
            defer di.deinit();

            const content_score = src_indexes[src_idx].?.score(&di, 10000);
            const name_score = nameSimilarityScore(src.from.name, dst.to.name) * 100;
            const score: i32 = @divTrunc(content_score * 99 + name_score, 10000);
            if (score < rename_score) continue;

            try matrix.append(allocator, .{ .added = dst_idx, .deleted = src_idx, .score = score });
            if (matrix.items.len >= max_matrix_size) break :outer;
        }
    }

    sortPairsAscending(matrix.items);
    return try matrix.toOwnedSlice(allocator);
}

fn groupByHash(allocator: Allocator, items: []*Change) Allocator.Error!std.AutoHashMap(Hash, []*Change) {
    var lists: std.AutoHashMap(Hash, std.ArrayList(*Change)) = .init(allocator);
    errdefer {
        var it = lists.iterator();
        while (it.next()) |e| e.value_ptr.deinit(allocator);
        lists.deinit();
    }
    for (items) |c| {
        const h = changeHash(c);
        const gop = try lists.getOrPut(h);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, c);
    }

    var out: std.AutoHashMap(Hash, []*Change) = .init(allocator);
    errdefer freeHashGroups(allocator, &out);
    var it = lists.iterator();
    while (it.next()) |e| {
        const slice = try e.value_ptr.toOwnedSlice(allocator);
        e.value_ptr.* = .empty;
        try out.put(e.key_ptr.*, slice);
    }
    lists.deinit();
    return out;
}

fn freeHashGroups(allocator: Allocator, map: *std.AutoHashMap(Hash, []*Change)) void {
    var it = map.iterator();
    while (it.next()) |e| allocator.free(e.value_ptr.*);
    map.deinit();
}

fn removeHashGroup(map: *std.AutoHashMap(Hash, []*Change), hash: Hash, allocator: Allocator) void {
    if (map.fetchRemove(hash)) |old| allocator.free(old.value);
}

fn removeFromGroup(
    map: *std.AutoHashMap(Hash, []*Change),
    hash: Hash,
    victim: *Change,
    allocator: Allocator,
) Allocator.Error!void {
    const gop = map.getEntry(hash) orelse return;
    const old = gop.value_ptr.*;
    var list: std.ArrayList(*Change) = .empty;
    defer list.deinit(allocator);
    for (old) |c| {
        if (c != victim) try list.append(allocator, c);
    }
    allocator.free(old);
    if (list.items.len == 0) {
        _ = map.remove(hash);
    } else {
        gop.value_ptr.* = try allocator.dupe(*Change, list.items);
    }
}

fn bestNameMatch(change: *Change, changes: []*Change) ?*Change {
    var best: ?*Change = null;
    var best_score: i32 = -1;
    const cname = change.name();
    for (changes) |c| {
        const score = nameSimilarityScore(cname, c.name());
        if (score > best_score) {
            best_score = score;
            best = c;
        }
    }
    return best;
}

fn nameSimilarityScore(a: []const u8, b: []const u8) i32 {
    const a_dir_len: usize = if (std.mem.lastIndexOfScalar(u8, a, '/')) |i| i + 1 else 0;
    const b_dir_len: usize = if (std.mem.lastIndexOfScalar(u8, b, '/')) |i| i + 1 else 0;
    const dir_min = @min(a_dir_len, b_dir_len);
    const dir_max = @max(a_dir_len, b_dir_len);

    var dir_score_ltr: i32 = 100;
    var dir_score_rtl: i32 = 100;
    if (dir_max != 0) {
        var dir_sim: usize = 0;
        while (dir_sim < dir_min and a[dir_sim] == b[dir_sim]) : (dir_sim += 1) {}
        dir_score_ltr = @intCast(dir_sim * 100 / dir_max);
        if (dir_score_ltr != 100) {
            dir_sim = 0;
            while (dir_sim < dir_min and a[a_dir_len - 1 - dir_sim] == b[b_dir_len - 1 - dir_sim]) : (dir_sim += 1) {}
            dir_score_rtl = @intCast(dir_sim * 100 / dir_max);
        }
    }

    const file_min = @min(a.len - a_dir_len, b.len - b_dir_len);
    const file_max = @max(a.len - a_dir_len, b.len - b_dir_len);
    var file_sim: usize = 0;
    if (file_max > 0) {
        while (file_sim < file_min and a[a.len - 1 - file_sim] == b[b.len - 1 - file_sim]) : (file_sim += 1) {}
    }
    const file_score: i32 = if (file_max == 0) 100 else @intCast(file_sim * 100 / file_max);

    return @divTrunc(((dir_score_ltr + dir_score_rtl) * 25) + (file_score * 50), 100);
}

fn changeHash(c: *const Change) Hash {
    if (!c.to.isEmpty()) return c.to.tree_entry.hash;
    return c.from.tree_entry.hash;
}

fn changeMode(c: *const Change) filemode.FileMode {
    if (!c.to.isEmpty()) return c.to.tree_entry.mode;
    return c.from.tree_entry.mode;
}

fn sameMode(a: *const Change, b: *const Change) bool {
    return changeMode(a) == changeMode(b);
}

// ---------------------------------------------------------------------------
// Tests (go-git RenameSuite + Similarity path via DetectRenames)
// ---------------------------------------------------------------------------

const memory = @import("memory");
const Storage = memory.Storage;
const storer = @import("storer");
const tree_mod = @import("tree.zig");
const difftree = @import("difftree.zig");

const path_a = "src/A";
const path_b = "src/B";
const path_h = "src/H";
const path_q = "src/Q";

const RenameFixture = struct {
    gpa: Allocator,
    store: Storage,
    tree: tree_mod.Tree,

    /// Initialize in place so `tree` storer points at stable `store` storage.
    fn init(self: *RenameFixture, gpa: Allocator) void {
        self.* = .{
            .gpa = gpa,
            .store = Storage.init(gpa),
            .tree = undefined,
        };
        self.tree = tree_mod.Tree.init(gpa, storer.ObjectGetter.from(Storage, &self.store));
    }

    fn deinit(self: *RenameFixture) void {
        self.tree.deinit();
        self.store.deinit();
    }

    fn putBlob(self: *RenameFixture, content: []const u8) !Hash {
        const blob = try self.store.newEncodedObject();
        blob.setType(.blob);
        _ = try blob.write(content);
        return try self.store.setEncodedObject(blob);
    }

    fn pathBaseName(path: []const u8) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
        return path;
    }

    fn makeAdd(self: *RenameFixture, path: []const u8, mode: filemode.FileMode, content: []const u8) !*Change {
        const h = try self.putBlob(content);
        const c = try self.gpa.create(Change);
        errdefer self.gpa.destroy(c);
        const name_owned = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(name_owned);
        c.* = .{
            .from = .{},
            .to = .{
                .name = name_owned,
                .tree = &self.tree,
                .tree_entry = .{
                    .name = pathBaseName(name_owned),
                    .mode = mode,
                    .hash = h,
                },
            },
        };
        return c;
    }

    fn makeDelete(self: *RenameFixture, path: []const u8, mode: filemode.FileMode, content: []const u8) !*Change {
        const h = try self.putBlob(content);
        const c = try self.gpa.create(Change);
        errdefer self.gpa.destroy(c);
        const name_owned = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(name_owned);
        c.* = .{
            .from = .{
                .name = name_owned,
                .tree = &self.tree,
                .tree_entry = .{
                    .name = pathBaseName(name_owned),
                    .mode = mode,
                    .hash = h,
                },
            },
            .to = .{},
        };
        return c;
    }

    fn makeModify(
        self: *RenameFixture,
        path: []const u8,
        mode: filemode.FileMode,
        from_content: []const u8,
        to_content: []const u8,
    ) !*Change {
        const fh = try self.putBlob(from_content);
        const th = try self.putBlob(to_content);
        const c = try self.gpa.create(Change);
        errdefer self.gpa.destroy(c);
        const name_owned = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(name_owned);
        c.* = .{
            .from = .{
                .name = name_owned,
                .tree = &self.tree,
                .tree_entry = .{
                    .name = pathBaseName(name_owned),
                    .mode = mode,
                    .hash = fh,
                },
            },
            .to = .{
                .name = name_owned,
                .tree = &self.tree,
                .tree_entry = .{
                    .name = pathBaseName(name_owned),
                    .mode = mode,
                    .hash = th,
                },
            },
        };
        return c;
    }
};

fn runDetect(
    gpa: Allocator,
    items: []const *Change,
    opts: DiffTreeOptions,
) !Changes {
    const slice = try gpa.dupe(*Change, items);
    // detectRenames always takes ownership of slice + *Change nodes.
    return try detectRenames(gpa, .{ .items = slice, .allocator = gpa }, opts);
}

// go-git RenameSuite.TestNameSimilarityScore
test "nameSimilarityScore table" {
    const cases = [_]struct { a: []const u8, b: []const u8, score: i32 }{
        .{ .a = "foo/bar.c", .b = "foo/baz.c", .score = 70 },
        .{ .a = "src/utils/Foo.java", .b = "tests/utils/Foo.java", .score = 64 },
        .{ .a = "foo/bar/baz.py", .b = "README.md", .score = 0 },
        .{ .a = "src/utils/something/foo.py", .b = "src/utils/something/other/foo.py", .score = 69 },
        .{ .a = "src/utils/something/foo.py", .b = "src/utils/yada/foo.py", .score = 63 },
        .{ .a = "src/utils/something/foo.py", .b = "src/utils/something/other/bar.py", .score = 44 },
        .{ .a = "src/utils/something/foo.py", .b = "src/utils/something/foo.py", .score = 100 },
        .{ .a = "a/b.txt", .b = "a/b.txt", .score = 100 },
    };
    for (cases) |tc| {
        try std.testing.expectEqual(tc.score, nameSimilarityScore(tc.a, tc.b));
    }
}

test "detectExact rename same hash via DiffTree" {
    const gpa = std.testing.allocator;

    var store = Storage.init(gpa);
    defer store.deinit();
    const blob = try store.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write("same");
    const bh = try store.setEncodedObject(blob);

    var ta = tree_mod.Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer ta.deinit();
    try ta.appendEntry("old.txt", filemode.Regular, bh);
    ta.sortEntries();

    var tb = tree_mod.Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tb.deinit();
    try tb.appendEntry("new.txt", filemode.Regular, bh);
    tb.sortEntries();

    var changes = try difftree.diffTreeWithOptions(gpa, &ta, &tb, .{
        .detect_renames = true,
        .rename_score = 50,
        .only_exact_renames = true,
    });
    defer changes.deinit();
    try std.testing.expectEqual(@as(usize, 1), changes.items.len);
    try std.testing.expect((try changes.items[0].action()) == .modify);
    try std.testing.expectEqualStrings("old.txt", changes.items[0].from.name);
    try std.testing.expectEqualStrings("new.txt", changes.items[0].to.name);
}

// go-git TestExactRename_OneRename
test "detectRenames exact one rename" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    const a = try fx.makeAdd(path_a, filemode.Regular, "foo");
    const b = try fx.makeDelete(path_q, filemode.Regular, "foo");
    // Snapshots for assertRename before ownership transfer.
    const a_name = try gpa.dupe(u8, a.to.name);
    defer gpa.free(a_name);
    const b_name = try gpa.dupe(u8, b.from.name);
    defer gpa.free(b_name);
    const a_hash = a.to.tree_entry.hash;
    const b_hash = b.from.tree_entry.hash;

    var result = try runDetect(gpa, &[_]*Change{ a, b }, DiffTreeOptions.default);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expect((try result.items[0].action()) == .modify);
    try std.testing.expectEqualStrings(b_name, result.items[0].from.name);
    try std.testing.expectEqualStrings(a_name, result.items[0].to.name);
    try std.testing.expect(result.items[0].from.tree_entry.hash.eql(b_hash));
    try std.testing.expect(result.items[0].to.tree_entry.hash.eql(a_hash));
}

// go-git TestExactRename_DifferentObjects
test "detectRenames exact different objects no rename" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    const a = try fx.makeAdd(path_a, filemode.Regular, "foo");
    const h = try fx.makeAdd(path_h, filemode.Regular, "foo");
    const q = try fx.makeDelete(path_q, filemode.Regular, "bar");

    var result = try runDetect(gpa, &[_]*Change{ a, h, q }, DiffTreeOptions.default);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.items.len);
    // Sorted by path name: src/A, src/H, src/Q
    try std.testing.expect((try result.items[0].action()) == .insert);
    try std.testing.expectEqualStrings(path_a, result.items[0].name());
    try std.testing.expect((try result.items[1].action()) == .insert);
    try std.testing.expectEqualStrings(path_h, result.items[1].name());
    try std.testing.expect((try result.items[2].action()) == .delete);
    try std.testing.expectEqualStrings(path_q, result.items[2].name());
}

// go-git TestExactRename_OneRenameOneModify
test "detectRenames exact one rename one modify" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    const c1 = try fx.makeAdd(path_a, filemode.Regular, "foo");
    const c2 = try fx.makeDelete(path_q, filemode.Regular, "foo");
    const c3 = try fx.makeModify(path_h, filemode.Regular, "bar", "bar");

    var result = try runDetect(gpa, &[_]*Change{ c1, c2, c3 }, DiffTreeOptions.default);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    // sorted: src/A rename, src/H modify — rename from is Q→A so name() prefers from → path_q
    // Change.name() prefers from when present → rename sorts as path_q, modify as path_h
    // Actually name() for rename uses from.name = path_q; modify uses path_h
    // sort: path_h < path_q? "src/H" vs "src/Q" → H first
    try std.testing.expect((try result.items[0].action()) == .modify);
    try std.testing.expectEqualStrings(path_h, result.items[0].name());
    try std.testing.expect((try result.items[1].action()) == .modify);
    try std.testing.expectEqualStrings(path_q, result.items[1].from.name);
    try std.testing.expectEqualStrings(path_a, result.items[1].to.name);
}

// go-git TestExactRename_ManyRenames
test "detectRenames exact many renames" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    const c1 = try fx.makeAdd(path_a, filemode.Regular, "foo");
    const c2 = try fx.makeDelete(path_q, filemode.Regular, "foo");
    const c3 = try fx.makeAdd(path_h, filemode.Regular, "bar");
    const c4 = try fx.makeDelete(path_b, filemode.Regular, "bar");

    var result = try runDetect(gpa, &[_]*Change{ c1, c2, c3, c4 }, DiffTreeOptions.default);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    // Both renames; sorted by from name: path_b, path_q
    try std.testing.expectEqualStrings(path_b, result.items[0].from.name);
    try std.testing.expectEqualStrings(path_h, result.items[0].to.name);
    try std.testing.expectEqualStrings(path_q, result.items[1].from.name);
    try std.testing.expectEqualStrings(path_a, result.items[1].to.name);
}

// go-git TestExactRename_MultipleIdenticalDeletes
test "detectRenames exact multiple identical deletes" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    const d0 = try fx.makeDelete(path_a, filemode.Regular, "foo");
    const d1 = try fx.makeDelete(path_b, filemode.Regular, "foo");
    const d2 = try fx.makeDelete(path_h, filemode.Regular, "foo");
    const a3 = try fx.makeAdd(path_q, filemode.Regular, "foo");

    var result = try runDetect(gpa, &[_]*Change{ d0, d1, d2, a3 }, DiffTreeOptions.default);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.items.len);
    // One rename (best name match among deletes for the single add) + two deletes.
    var renames: usize = 0;
    var deletes: usize = 0;
    for (result.items) |c| {
        switch (try c.action()) {
            .modify => {
                renames += 1;
                try std.testing.expectEqualStrings(path_q, c.to.name);
            },
            .delete => deletes += 1,
            .insert => try std.testing.expect(false),
        }
    }
    try std.testing.expectEqual(@as(usize, 1), renames);
    try std.testing.expectEqual(@as(usize, 2), deletes);
}

// go-git TestRenameExact_PathBreaksTie
test "detectRenames exact path breaks tie" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    const c0 = try fx.makeAdd("src/com/foo/a.java", filemode.Regular, "foo");
    const c1 = try fx.makeDelete("src/com/foo/b.java", filemode.Regular, "foo");
    const c2 = try fx.makeAdd("c.txt", filemode.Regular, "foo");
    const c3 = try fx.makeDelete("d.txt", filemode.Regular, "foo");
    const c4 = try fx.makeAdd("the_e_file.txt", filemode.Regular, "foo");

    // Out of order like go-git
    var result = try runDetect(gpa, &[_]*Change{ c0, c3, c4, c1, c2 }, DiffTreeOptions.default);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.items.len);

    var rename_count: usize = 0;
    var leftover_add = false;
    for (result.items) |c| {
        switch (try c.action()) {
            .modify => {
                rename_count += 1;
                // Either d.txt→c.txt or b.java→a.java
                const from_n = c.from.name;
                const to_n = c.to.name;
                const pair_ok =
                    (std.mem.eql(u8, from_n, "d.txt") and std.mem.eql(u8, to_n, "c.txt")) or
                    (std.mem.eql(u8, from_n, "src/com/foo/b.java") and std.mem.eql(u8, to_n, "src/com/foo/a.java"));
                try std.testing.expect(pair_ok);
            },
            .insert => {
                try std.testing.expectEqualStrings("the_e_file.txt", c.to.name);
                leftover_add = true;
            },
            .delete => try std.testing.expect(false),
        }
    }
    try std.testing.expectEqual(@as(usize, 2), rename_count);
    try std.testing.expect(leftover_add);
}

// go-git TestExactRename_OneDeleteManyAdds
test "detectRenames exact one delete many adds" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    const c0 = try fx.makeAdd("src/com/foo/a.java", filemode.Regular, "foo");
    const c1 = try fx.makeAdd("src/com/foo/b.java", filemode.Regular, "foo");
    const c2 = try fx.makeAdd("c.txt", filemode.Regular, "foo");
    const c3 = try fx.makeDelete("d.txt", filemode.Regular, "foo");

    var result = try runDetect(gpa, &[_]*Change{ c0, c1, c2, c3 }, DiffTreeOptions.default);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.items.len);

    var found_rename = false;
    var inserts: usize = 0;
    for (result.items) |c| {
        switch (try c.action()) {
            .modify => {
                found_rename = true;
                try std.testing.expectEqualStrings("d.txt", c.from.name);
                try std.testing.expectEqualStrings("c.txt", c.to.name);
            },
            .insert => inserts += 1,
            .delete => try std.testing.expect(false),
        }
    }
    try std.testing.expect(found_rename);
    try std.testing.expectEqual(@as(usize, 2), inserts);
}

// go-git TestExactRename_UnstagedFile
test "detectRenames exact unstaged style paths" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    const d = try fx.makeDelete(path_a, filemode.Regular, "foo");
    const a = try fx.makeAdd(path_b, filemode.Regular, "foo");
    var result = try runDetect(gpa, &[_]*Change{ d, a }, DiffTreeOptions.default);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqualStrings(path_a, result.items[0].from.name);
    try std.testing.expectEqualStrings(path_b, result.items[0].to.name);
}

// go-git TestContentRename_OnePair
test "detectRenames content one pair" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    const a = try fx.makeAdd(path_a, filemode.Regular, "foo\nbar\nbaz\nblarg\n");
    const d = try fx.makeDelete(path_a, filemode.Regular, "foo\nbar\nbaz\nblah\n");
    // Note: same path on both is fine for content rename detection on Changes list.
    // Wait - both have path_a? go-git uses pathA for both add and delete.
    // Delete from pathA, add to pathA with different content = would be modify normally.
    // Looking at go-git again:
    // makeAdd(pathA, ... blarg)
    // makeDelete(pathA, ... blah)
    // So delete and add at same path - detects as rename (modify with same names).

    var result = try runDetect(gpa, &[_]*Change{ a, d }, DiffTreeOptions.default);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expect((try result.items[0].action()) == .modify);
    try std.testing.expectEqualStrings(path_a, result.items[0].from.name);
    try std.testing.expectEqualStrings(path_a, result.items[0].to.name);
}

// go-git TestContentRename_OneRenameTwoUnrelatedFiles
test "detectRenames content one rename two unrelated" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    const c0 = try fx.makeAdd(path_a, filemode.Regular, "foo\nbar\nbaz\nblarg\n");
    const c1 = try fx.makeDelete(path_q, filemode.Regular, "foo\nbar\nbaz\nblah\n");
    const c2 = try fx.makeAdd(path_b, filemode.Regular, "some\nsort\nof\ntext\n");
    const c3 = try fx.makeDelete(path_h, filemode.Regular, "completely\nunrelated\ntext\n");

    var result = try runDetect(gpa, &[_]*Change{ c0, c1, c2, c3 }, DiffTreeOptions.default);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.items.len);

    var renames: usize = 0;
    var inserts: usize = 0;
    var deletes: usize = 0;
    for (result.items) |c| {
        switch (try c.action()) {
            .modify => {
                renames += 1;
                try std.testing.expectEqualStrings(path_q, c.from.name);
                try std.testing.expectEqualStrings(path_a, c.to.name);
            },
            .insert => {
                inserts += 1;
                try std.testing.expectEqualStrings(path_b, c.to.name);
            },
            .delete => {
                deletes += 1;
                try std.testing.expectEqualStrings(path_h, c.from.name);
            },
        }
    }
    try std.testing.expectEqual(@as(usize, 1), renames);
    try std.testing.expectEqual(@as(usize, 1), inserts);
    try std.testing.expectEqual(@as(usize, 1), deletes);
}

// go-git TestContentRename_LastByteDifferent
test "detectRenames content last byte different" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    const a = try fx.makeAdd(path_a, filemode.Regular, "foo\nbar\na");
    const d = try fx.makeDelete(path_q, filemode.Regular, "foo\nbar\nb");
    var result = try runDetect(gpa, &[_]*Change{ a, d }, DiffTreeOptions.default);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqualStrings(path_q, result.items[0].from.name);
    try std.testing.expectEqualStrings(path_a, result.items[0].to.name);
}

// go-git TestContentRename_NewlinesOnly
test "detectRenames content newlines only" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    const newlines3 = "\n\n\n";
    const newlines4 = "\n\n\n\n";
    const a = try fx.makeAdd(path_a, filemode.Regular, newlines3);
    const d = try fx.makeDelete(path_q, filemode.Regular, newlines4);
    var result = try runDetect(gpa, &[_]*Change{ a, d }, DiffTreeOptions.default);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expect((try result.items[0].action()) == .modify);
}

// go-git TestContentRename_SameContentMultipleTimes
test "detectRenames content same line repeated" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    const a = try fx.makeAdd(path_a, filemode.Regular, "a\na\na\na\n");
    const d = try fx.makeDelete(path_q, filemode.Regular, "a\na\na\n");
    var result = try runDetect(gpa, &[_]*Change{ a, d }, DiffTreeOptions.default);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expect((try result.items[0].action()) == .modify);
}

// go-git TestContentRename_OnePairRenameScore50
test "detectRenames content score threshold 50" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    const a = try fx.makeAdd(path_a, filemode.Regular, "ab\nab\nab\nac\nad\nae\n");
    const d = try fx.makeDelete(path_q, filemode.Regular, "ac\nab\nab\nab\naa\na0\na1\n");
    var result = try runDetect(gpa, &[_]*Change{ a, d }, .{
        .detect_renames = true,
        .rename_score = 50,
        .rename_limit = 0,
        .only_exact_renames = false,
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expect((try result.items[0].action()) == .modify);
}

// go-git TestNoRenames_SingleByteFiles
test "detectRenames no renames single byte files only adds" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    const a = try fx.makeAdd(path_a, filemode.Regular, "a");
    const q = try fx.makeAdd(path_q, filemode.Regular, "b");
    var result = try runDetect(gpa, &[_]*Change{ a, q }, DiffTreeOptions.default);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expect((try result.items[0].action()) == .insert);
    try std.testing.expect((try result.items[1].action()) == .insert);
}

// go-git TestNoRenames_EmptyFile / EmptyFile2
test "detectRenames no renames empty file" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    {
        const a = try fx.makeAdd(path_a, filemode.Regular, "");
        var result = try runDetect(gpa, &[_]*Change{a}, DiffTreeOptions.default);
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.items.len);
        try std.testing.expect((try result.items[0].action()) == .insert);
    }
    {
        const a = try fx.makeAdd(path_a, filemode.Regular, "");
        const d = try fx.makeDelete(path_q, filemode.Regular, "blah");
        var result = try runDetect(gpa, &[_]*Change{ a, d }, DiffTreeOptions.default);
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 2), result.items.len);
        try std.testing.expect((try result.items[0].action()) == .insert);
        try std.testing.expect((try result.items[1].action()) == .delete);
    }
}

// go-git TestNoRenames_SymlinkAndFile / SamePath
test "detectRenames no renames symlink vs file" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    {
        const a = try fx.makeAdd(path_a, filemode.Regular, "src/dest");
        const d = try fx.makeDelete(path_q, filemode.Symlink, "src/dest");
        var result = try runDetect(gpa, &[_]*Change{ a, d }, DiffTreeOptions.default);
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 2), result.items.len);
    }
    {
        const a = try fx.makeAdd(path_a, filemode.Regular, "src/dest");
        const d = try fx.makeDelete(path_a, filemode.Symlink, "src/dest");
        var result = try runDetect(gpa, &[_]*Change{ a, d }, DiffTreeOptions.default);
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 2), result.items.len);
    }
}

// go-git TestRenameLimit
test "detectRenames content rename limit" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    const c0 = try fx.makeAdd(path_a, filemode.Regular, "foo\nbar\nbaz\nblarg\n");
    const c1 = try fx.makeDelete(path_b, filemode.Regular, "foo\nbar\nbaz\nblah\n");
    const c2 = try fx.makeAdd(path_h, filemode.Regular, "a\nb\nc\nd\n");
    const c3 = try fx.makeDelete(path_q, filemode.Regular, "a\nb\nc\n");

    var result = try runDetect(gpa, &[_]*Change{ c0, c1, c2, c3 }, .{
        .detect_renames = true,
        .rename_score = 60,
        .rename_limit = 1,
        .only_exact_renames = false,
    });
    defer result.deinit();
    // Limit 1 skips content rename detection entirely (max(adds,dels)=2 > 1).
    try std.testing.expectEqual(@as(usize, 4), result.items.len);
    for (result.items) |c| {
        const act = try c.action();
        try std.testing.expect(act == .insert or act == .delete);
    }
}

// only_exact_renames skips content pairing
test "detectRenames only exact skips content" {
    const gpa = std.testing.allocator;
    var fx: RenameFixture = undefined;
    fx.init(gpa);
    defer fx.deinit();

    const a = try fx.makeAdd(path_a, filemode.Regular, "foo\nbar\nbaz\nblarg\n");
    const d = try fx.makeDelete(path_q, filemode.Regular, "foo\nbar\nbaz\nblah\n");
    var result = try runDetect(gpa, &[_]*Change{ a, d }, .{
        .detect_renames = true,
        .rename_score = 50,
        .rename_limit = 0,
        .only_exact_renames = true,
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
}

// Destination IndexFull: mark skip, do not abort the whole similarity matrix
// (intentional improvement over go-git's return-after-mark).
fn noteDstIndexFull(dst_too_large: []bool, idx: usize) void {
    dst_too_large[idx] = true;
}

test "destination IndexFull marks skip not abort" {
    var flags = [_]bool{ false, false, false };
    noteDstIndexFull(flags[0..], 1);
    try std.testing.expect(flags[1]);
    try std.testing.expect(!flags[0]);
    try std.testing.expect(!flags[2]);
    // Remaining destinations stay eligible (flags stay false until their own IndexFull).
}

