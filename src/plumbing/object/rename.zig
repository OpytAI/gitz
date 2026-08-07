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

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Change = change_mod.Change;
const Changes = change_mod.Changes;
const DiffTreeOptions = change_mod.DiffTreeOptions;
const SimilarityIndex = similarity_mod.SimilarityIndex;

const max_matrix_size: usize = 10_000;

/// Content renames load blobs through the storer → open error set.
pub const RenameError = anyerror;

/// go-git `DetectRenames`.
///
/// Takes ownership of `changes`. On error every input change is freed.
pub fn detectRenames(
    allocator: Allocator,
    changes: Changes,
    opts: DiffTreeOptions,
) RenameError!Changes {
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
        _ = hash;
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
        if (dels.len > 0) {
            const h = changeHash(dels[0]);
            if (remain.items.len == 0) {
                removeHashGroup(deletes_by, h, self.allocator);
            } else {
                const slice = try self.allocator.dupe(*Change, remain.items);
                if (deletes_by.fetchRemove(h)) |old| self.allocator.free(old.value);
                try deletes_by.put(h, slice);
            }
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
        const mod = try self.allocator.create(Change);
        mod.* = .{
            .from = del.from,
            .to = add.to,
        };
        // Sever name ownership so shell destroy is a pure free of the node.
        del.* = .{};
        add.* = .{};

        var shells_live = true;
        errdefer {
            if (shells_live) {
                paired.put(del, {}) catch {};
                paired.put(add, {}) catch {};
                self.allocator.destroy(del);
                self.allocator.destroy(add);
            }
        }

        self.modified.append(self.allocator, mod) catch |err| {
            // Names live in mod; free everything we own here.
            mod.destroy(self.allocator);
            return err; // errdefer frees shells
        };
        // `mod` is owned by `modified` now.
        try paired.put(del, {});
        try paired.put(add, {});
        self.allocator.destroy(del);
        self.allocator.destroy(add);
        shells_live = false;
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
    var dst_too_large = try allocator.alloc(bool, dsts.len);
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
            var di = SimilarityIndex.fromFile(allocator, &to) catch |err| {
                if (err == error.IndexFull) {
                    dst_too_large[dst_idx] = true;
                    return error.IndexFull;
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

test "nameSimilarityScore exact" {
    try std.testing.expectEqual(@as(i32, 100), nameSimilarityScore("a/b.txt", "a/b.txt"));
}

test "detectExact rename same hash" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");
    const Storage = memory.Storage;
    const storer = @import("storer");
    const tree_mod = @import("tree.zig");
    const difftree = @import("difftree.zig");

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
