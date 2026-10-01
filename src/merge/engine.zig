//! Three-way tree merge used by every built-in strategy.
//!
//! `ort` and `recursive` call this with rename detection. `resolve` calls it
//! with renames forced off. `octopus` calls it once per head and refuses any
//! path that is not a trivial take. `subtree` shifts the ancestor and the
//! incoming tree, then calls it. `ours` does not call it: the result tree is
//! the current tree.

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const obj = @import("object");
const diff = @import("diff");
const gitattributes = @import("gitattributes");

const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const FileMode = filemode.FileMode;
const Leaf = model.Leaf;
const LeafMap = model.LeafMap;

const rename_limit: usize = 7000;
const rename_matrix_cap: usize = 10_000;
const virtual_depth_limit: u32 = 32;

pub const OutPath = struct {
    path: []u8,
    resolved: ?Leaf = null,
    base: ?Leaf = null,
    ours: ?Leaf = null,
    theirs: ?Leaf = null,
    /// Owned conflict-marker text. The index stages stay the original blobs.
    marker: ?[]u8 = null,
    /// Blob to write when `marker` is null.
    work: ?Leaf = null,
    write_file: bool = false,
    conflict: bool = false,
    work_mode: FileMode = filemode.Regular,
};

pub const TreeMerge = struct {
    clean: bool,
    paths: []OutPath,
    /// Worktree-shaped tree: resolved blobs, marker blobs, and the blob written
    /// for a binary or modify/delete conflict.
    tree_hash: Hash,
    /// Set for an `ort` / `recursive` / `subtree` conflict (`AUTO_MERGE`).
    marker_tree: ?Hash = null,
};

pub const Spec = struct {
    renames: bool,
    rename_threshold: u8,
    trivial_only: bool,
    favor: diff.Favor,
    algorithm: diff.LineAlgorithm,
    style: diff.ConflictStyle,
    ours_label: []const u8,
    theirs_label: []const u8,
    base_label: []const u8,
    allow_unrelated: bool,
    auto_merge: bool,
};

pub fn deinitTreeMerge(allocator: Allocator, tm: *TreeMerge) void {
    for (tm.paths) |*p| {
        allocator.free(p.path);
        if (p.marker) |m| allocator.free(m);
    }
    if (tm.paths.len > 0) allocator.free(tm.paths);
    tm.* = undefined;
}

pub fn shallowNonEmpty(storage: anytype) !bool {
    const result = storage.shallow();
    if (comptime @typeInfo(@TypeOf(result)) == .error_union) {
        const commits = try result;
        return commits.len > 0;
    } else {
        return result.len > 0;
    }
}

/// Tree of the merge base of `a` and `b`. More than one base is folded with
/// the same spec (a conflicted fold keeps the marker tree). Octopus refuses
/// that fold. An empty result is the empty tree when unrelated histories are
/// allowed and the repository is not shallow.
pub fn ancestorTree(
    allocator: Allocator,
    s: anytype,
    a: *obj.Commit,
    b: *obj.Commit,
    depth: u32,
    spec: Spec,
) !Hash {
    if (depth > virtual_depth_limit) return error.VirtualMergeDepth;
    const bases = obj.mergeBase(a, allocator, b) catch |err| {
        if (err == error.ObjectNotFound and try shallowNonEmpty(s)) return error.ShallowHistory;
        return err;
    };
    defer obj.freeMergeBaseResult(allocator, bases);
    if (bases.len == 0) {
        if (try shallowNonEmpty(s)) return error.ShallowHistory;
        if (!spec.allow_unrelated) return error.UnrelatedHistories;
        return model.emptyTree(allocator, s);
    }
    if (bases.len == 1) return bases[0].tree_hash;
    if (spec.trivial_only) return error.OctopusConflict;
    return foldBases(allocator, s, bases, depth, spec);
}

fn foldBases(
    allocator: Allocator,
    s: anytype,
    bases: []*obj.Commit,
    depth: u32,
    spec: Spec,
) !Hash {
    var left = bases[0];
    var left_owned = false;
    var left_hash = bases[0].hash;
    var left_tree = bases[0].tree_hash;
    errdefer if (left_owned) obj.freeCommit(allocator, left);

    var i: usize = 1;
    while (i < bases.len) : (i += 1) {
        const next = bases[i];
        const anc = try ancestorTree(allocator, s, left, next, depth + 1, spec);
        var merged = try mergeTrees(allocator, s, anc, left_tree, next.tree_hash, spec);
        const tree = merged.tree_hash;
        deinitTreeMerge(allocator, &merged);
        if (i + 1 == bases.len) {
            if (left_owned) obj.freeCommit(allocator, left);
            left_owned = false;
            return tree;
        }
        const parents = [_]Hash{ left_hash, next.hash };
        const stored = try model.storeTempCommit(allocator, s, tree, &parents);
        const created = try obj.getCommit(allocator, s, stored);
        if (left_owned) obj.freeCommit(allocator, left);
        left = created;
        left_owned = true;
        left_hash = stored;
        left_tree = tree;
    }
    return left_tree;
}

/// Sequential trivial merges. `head` is the original HEAD for every base.
/// `others` must be non-empty. The caller frees `others`.
pub fn mergeOctopus(
    allocator: Allocator,
    s: anytype,
    head: *obj.Commit,
    others: []*obj.Commit,
    spec: Spec,
) !TreeMerge {
    if (others.len == 0) return error.NoMergeHeads;
    var acc = head.tree_hash;
    var last: ?TreeMerge = null;
    errdefer if (last) |*tm| deinitTreeMerge(allocator, tm);

    for (others) |other| {
        const base = try ancestorTree(allocator, s, head, other, 0, spec);
        const merged = try mergeTrees(allocator, s, base, acc, other.tree_hash, spec);
        if (last) |*prev| deinitTreeMerge(allocator, prev);
        acc = merged.tree_hash;
        last = merged;
    }
    return last.?;
}

/// Stage-0 copy of one tree. Used for `ours` and for a fast-forward checkout.
pub fn takeTree(allocator: Allocator, s: anytype, tree_hash: Hash) !TreeMerge {
    var leaves = LeafMap{};
    defer leaves.deinit(allocator);
    try model.walkTree(allocator, s, tree_hash, &leaves);

    var paths: std.ArrayList(OutPath) = .empty;
    errdefer {
        for (paths.items) |*p| allocator.free(p.path);
        paths.deinit(allocator);
    }
    var it = leaves.map.iterator();
    while (it.next()) |e| {
        const leaf = e.value_ptr.*;
        try paths.append(allocator, .{
            .path = try allocator.dupe(u8, e.key_ptr.*),
            .resolved = leaf,
            .work = leaf,
            .work_mode = leaf.mode,
            .write_file = leaf.mode != filemode.Submodule,
        });
    }
    const owned = try paths.toOwnedSlice(allocator);
    return .{
        .clean = true,
        .paths = owned,
        .tree_hash = tree_hash,
        .marker_tree = null,
    };
}

pub fn validatePrefix(prefix: []const u8) !void {
    if (prefix.len == 0 or prefix[0] == '/' or prefix[0] == '\\') return error.StrategyOptionNotSupported;
    var it = std.mem.splitScalar(u8, prefix, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "..")) return error.StrategyOptionNotSupported;
    }
}

/// Owned prefix. A null `given` selects the single root directory of `ours`
/// whose entry names overlap the root of `theirs`.
pub fn subtreePrefix(
    allocator: Allocator,
    s: anytype,
    ours_tree: Hash,
    theirs_tree: Hash,
    given: ?[]const u8,
) ![]u8 {
    if (given) |p| {
        try validatePrefix(p);
        return allocator.dupe(u8, p);
    }
    return detectSubtreePrefix(allocator, s, ours_tree, theirs_tree);
}

fn detectSubtreePrefix(allocator: Allocator, s: anytype, ours_tree: Hash, theirs_tree: Hash) ![]u8 {
    const ours = try obj.getTree(allocator, s, ours_tree);
    defer obj.freeTree(allocator, ours);
    const theirs = try obj.getTree(allocator, s, theirs_tree);
    defer obj.freeTree(allocator, theirs);

    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(allocator);
    for (theirs.entries.items) |e| try names.put(allocator, e.name, {});

    var found: ?[]const u8 = null;
    for (ours.entries.items) |e| {
        if (e.mode != filemode.Dir) continue;
        const sub = try obj.getTree(allocator, s, e.hash);
        defer obj.freeTree(allocator, sub);
        var overlap = false;
        for (sub.entries.items) |child| {
            if (names.get(child.name) != null) {
                overlap = true;
                break;
            }
        }
        if (!overlap) continue;
        if (found != null) return error.SubtreeShiftNotFound;
        found = e.name;
    }
    const name = found orelse return error.SubtreeShiftNotFound;
    return allocator.dupe(u8, name);
}

pub fn mergeTrees(
    allocator: Allocator,
    s: anytype,
    base_tree: Hash,
    ours_tree: Hash,
    theirs_tree: Hash,
    spec: Spec,
) !TreeMerge {
    var base_map = LeafMap{};
    defer base_map.deinit(allocator);
    var ours_map = LeafMap{};
    defer ours_map.deinit(allocator);
    var theirs_map = LeafMap{};
    defer theirs_map.deinit(allocator);
    try model.walkTree(allocator, s, base_tree, &base_map);
    try model.walkTree(allocator, s, ours_tree, &ours_map);
    try model.walkTree(allocator, s, theirs_tree, &theirs_map);

    var ours_ren = RenameMap{};
    defer ours_ren.map.deinit(allocator);
    var theirs_ren = RenameMap{};
    defer theirs_ren.map.deinit(allocator);
    if (spec.renames) {
        try detectRenames(allocator, s, &base_map, &ours_map, spec.rename_threshold, &ours_ren);
        try detectRenames(allocator, s, &base_map, &theirs_map, spec.rename_threshold, &theirs_ren);
    }

    var nodes = NodeMap{};
    defer deinitNodes(allocator, &nodes);
    try alignTrees(allocator, &base_map, &ours_map, &theirs_map, &ours_ren, &theirs_ren, &nodes);
    try applyDirectoryFile(allocator, &nodes, spec.ours_label, spec.theirs_label);

    var attrs = try loadAttrs(allocator, s, ours_tree);
    defer if (attrs) |*a| a.deinit(allocator);

    var paths: std.ArrayList(OutPath) = .empty;
    errdefer {
        for (paths.items) |*p| freeOut(allocator, p);
        paths.deinit(allocator);
    }
    var clean = true;
    const keys = try collectKeys(allocator, &nodes);
    defer allocator.free(keys);
    for (keys) |path| {
        const node = nodes.get(path) orelse continue;
        try decide(allocator, s, spec, if (attrs) |*a| a else null, path, node, &paths, &clean);
    }

    const owned = try paths.toOwnedSlice(allocator);
    errdefer {
        var tmp = TreeMerge{ .clean = clean, .paths = owned, .tree_hash = plumbing.ZeroHash };
        deinitTreeMerge(allocator, &tmp);
    }
    const tree_hash = try treeFromPaths(allocator, s, owned);
    return .{
        .clean = clean,
        .paths = owned,
        .tree_hash = tree_hash,
        .marker_tree = if (spec.auto_merge and !clean) tree_hash else null,
    };
}

fn freeOut(allocator: Allocator, p: *OutPath) void {
    allocator.free(p.path);
    if (p.marker) |m| allocator.free(m);
    p.* = undefined;
}

const Kind = enum { text, symlink, gitlink, other };

fn kindOf(mode: FileMode) Kind {
    return switch (mode) {
        filemode.Regular, filemode.Executable, filemode.Deprecated => .text,
        filemode.Symlink => .symlink,
        filemode.Submodule => .gitlink,
        else => .other,
    };
}

fn optEql(a: ?Leaf, b: ?Leaf) bool {
    if (a == null and b == null) return true;
    const x = a orelse return false;
    const y = b orelse return false;
    return x.mode == y.mode and x.hash.eql(y.hash);
}

fn fileOf(leaf: Leaf) bool {
    return leaf.mode != filemode.Submodule;
}

fn decide(
    allocator: Allocator,
    s: anytype,
    spec: Spec,
    attrs: ?*Attrs,
    path: []const u8,
    node: Node,
    paths: *std.ArrayList(OutPath),
    clean: *bool,
) !void {
    switch (node.forced) {
        .md_ours => {
            if (spec.trivial_only) return error.OctopusConflict;
            clean.* = false;
            try appendConflict(allocator, paths, path, node.base, node.ours, null, null, node.ours, if (node.ours) |o| o.mode else filemode.Regular, fileOf(node.ours orelse return));
            return;
        },
        .md_theirs => {
            if (spec.trivial_only) return error.OctopusConflict;
            clean.* = false;
            const leaf = node.theirs orelse return;
            try appendConflict(allocator, paths, path, node.base, null, node.theirs, null, leaf, leaf.mode, fileOf(leaf));
            return;
        },
        .keep_stages => {
            if (spec.trivial_only) return error.OctopusConflict;
            clean.* = false;
            try appendConflict(allocator, paths, path, node.base, node.ours, node.theirs, null, null, filemode.Regular, false);
            return;
        },
        .none => {},
    }

    if (node.rename_rename) {
        if (spec.trivial_only) return error.OctopusConflict;
        clean.* = false;
        if (node.ours) |o| {
            try appendConflict(allocator, paths, path, node.base, node.ours, null, null, o, o.mode, fileOf(o));
        } else if (node.theirs) |t| {
            try appendConflict(allocator, paths, path, node.base, null, node.theirs, null, t, t.mode, fileOf(t));
        }
        return;
    }

    if (optEql(node.ours, node.theirs)) {
        if (node.ours) |o| try appendResolved(allocator, paths, path, o);
        return;
    }
    if (optEql(node.ours, node.base)) {
        if (node.ours_renamed and node.theirs == null) {
            if (spec.trivial_only) return error.OctopusConflict;
            clean.* = false;
            const o = node.ours orelse return;
            try appendConflict(allocator, paths, path, node.base, node.ours, null, null, o, o.mode, fileOf(o));
            return;
        }
        if (node.theirs) |t| try appendResolved(allocator, paths, path, t);
        return;
    }
    if (optEql(node.theirs, node.base)) {
        if (node.theirs_renamed and node.ours == null) {
            if (spec.trivial_only) return error.OctopusConflict;
            clean.* = false;
            const t = node.theirs orelse return;
            try appendConflict(allocator, paths, path, node.base, null, node.theirs, null, t, t.mode, fileOf(t));
            return;
        }
        if (node.ours) |o| try appendResolved(allocator, paths, path, o);
        return;
    }
    if (spec.trivial_only) return error.OctopusConflict;

    const ours = node.ours;
    const theirs = node.theirs;
    if (ours == null or theirs == null) {
        clean.* = false;
        if (ours == null) {
            const t = theirs orelse return;
            try appendConflict(allocator, paths, path, node.base, null, theirs, null, t, t.mode, fileOf(t));
        } else {
            const o = ours.?;
            try appendConflict(allocator, paths, path, node.base, ours, null, null, o, o.mode, fileOf(o));
        }
        return;
    }

    const o = ours.?;
    const t = theirs.?;
    const ko = kindOf(o.mode);
    const kt = kindOf(t.mode);
    if (ko == .gitlink and kt == .gitlink) {
        try mergeGitlink(allocator, s, paths, path, node, o, t, clean);
        return;
    }
    if (ko != kt) {
        clean.* = false;
        try emitDistinct(allocator, paths, path, node.base, o, t, spec.theirs_label);
        return;
    }
    if (ko != .text) {
        clean.* = false;
        try appendConflict(allocator, paths, path, node.base, o, t, null, o, o.mode, fileOf(o));
        return;
    }

    const base_bytes = if (node.base) |b| try model.blobBytes(allocator, s, b.hash) else try allocator.dupe(u8, "");
    defer allocator.free(base_bytes);
    const ours_bytes = try model.blobBytes(allocator, s, o.hash);
    defer allocator.free(ours_bytes);
    const theirs_bytes = try model.blobBytes(allocator, s, t.hash);
    defer allocator.free(theirs_bytes);

    if (blobIsBinary(base_bytes) or blobIsBinary(ours_bytes) or blobIsBinary(theirs_bytes) or try markedNonText(allocator, attrs, path)) {
        clean.* = false;
        try appendConflict(allocator, paths, path, node.base, o, t, null, o, o.mode, true);
        return;
    }

    var merged = try diff.mergeText(
        allocator,
        spec.algorithm,
        spec.style,
        spec.favor,
        .{ .ours = spec.ours_label, .theirs = spec.theirs_label, .base = spec.base_label },
        base_bytes,
        ours_bytes,
        theirs_bytes,
    );
    defer merged.deinit(allocator);

    const mode = pickMode(node.base, o, t);
    if (!merged.clean or mode == null) {
        clean.* = false;
        if (!merged.clean) {
            const marker = try allocator.dupe(u8, merged.bytes);
            errdefer allocator.free(marker);
            try appendConflict(allocator, paths, path, node.base, o, t, marker, null, filemode.Regular, true);
        } else {
            const hash = try model.storeBlob(s, merged.bytes);
            const work = Leaf{ .mode = o.mode, .hash = hash };
            try appendConflict(allocator, paths, path, node.base, o, t, null, work, o.mode, true);
        }
        return;
    }
    const hash = try model.storeBlob(s, merged.bytes);
    try appendResolved(allocator, paths, path, .{ .mode = mode.?, .hash = hash });
}

fn pickMode(base: ?Leaf, ours: Leaf, theirs: Leaf) ?FileMode {
    if (ours.mode == theirs.mode) return ours.mode;
    if (base) |b| {
        if (ours.mode == b.mode) return theirs.mode;
        if (theirs.mode == b.mode) return ours.mode;
    }
    return null;
}

fn mergeGitlink(
    allocator: Allocator,
    s: anytype,
    paths: *std.ArrayList(OutPath),
    path: []const u8,
    node: Node,
    ours: Leaf,
    theirs: Leaf,
    clean: *bool,
) !void {
    if (gitlinkWinner(allocator, s, ours, theirs)) |winner| {
        if (winner) |leaf| {
            try appendResolved(allocator, paths, path, leaf);
            return;
        }
    } else |err| {
        if (err != error.ObjectNotFound) return err;
    }
    clean.* = false;
    try appendConflict(allocator, paths, path, node.base, ours, theirs, null, null, filemode.Submodule, false);
}

fn gitlinkWinner(allocator: Allocator, s: anytype, ours: Leaf, theirs: Leaf) !?Leaf {
    const co = obj.getCommit(allocator, s, ours.hash) catch |err| {
        if (err == error.ObjectNotFound) return null;
        return err;
    };
    defer obj.freeCommit(allocator, co);
    const ct = obj.getCommit(allocator, s, theirs.hash) catch |err| {
        if (err == error.ObjectNotFound) return null;
        return err;
    };
    defer obj.freeCommit(allocator, ct);
    if (obj.isAncestor(co, ct) catch |err| {
        if (err == error.ObjectNotFound) return null;
        return err;
    }) return theirs;
    if (obj.isAncestor(ct, co) catch |err| {
        if (err == error.ObjectNotFound) return null;
        return err;
    }) return ours;
    return null;
}

fn emitDistinct(
    allocator: Allocator,
    paths: *std.ArrayList(OutPath),
    path: []const u8,
    base: ?Leaf,
    ours: Leaf,
    theirs: Leaf,
    theirs_label: []const u8,
) !void {
    try appendConflict(allocator, paths, path, null, ours, null, null, ours, ours.mode, fileOf(ours));
    const alt = try std.fmt.allocPrint(allocator, "{s}~{s}", .{ path, theirs_label });
    errdefer allocator.free(alt);
    try appendConflict(allocator, paths, alt, base, null, theirs, null, theirs, theirs.mode, fileOf(theirs));
    allocator.free(alt);
}

fn appendResolved(allocator: Allocator, paths: *std.ArrayList(OutPath), path: []const u8, leaf: Leaf) !void {
    try paths.append(allocator, .{
        .path = try allocator.dupe(u8, path),
        .resolved = leaf,
        .work = leaf,
        .work_mode = leaf.mode,
        .write_file = fileOf(leaf),
    });
}

fn appendConflict(
    allocator: Allocator,
    paths: *std.ArrayList(OutPath),
    path: []const u8,
    base: ?Leaf,
    ours: ?Leaf,
    theirs: ?Leaf,
    marker: ?[]u8,
    work: ?Leaf,
    work_mode: FileMode,
    write_file: bool,
) !void {
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    try paths.append(allocator, .{
        .path = owned,
        .base = base,
        .ours = ours,
        .theirs = theirs,
        .marker = marker,
        .work = work,
        .work_mode = work_mode,
        .write_file = write_file,
        .conflict = true,
    });
}

fn blobIsBinary(bytes: []const u8) bool {
    const n = @min(bytes.len, 8000);
    return std.mem.indexOfScalar(u8, bytes[0..n], 0) != null;
}

fn treeFromPaths(allocator: Allocator, s: anytype, paths: []const OutPath) !Hash {
    var items: std.ArrayList(model.TreeItem) = .empty;
    defer items.deinit(allocator);
    for (paths) |p| {
        if (p.marker) |m| {
            const hash = try model.storeBlob(s, m);
            try items.append(allocator, .{ .path = p.path, .mode = filemode.Regular, .hash = hash });
        } else if (p.resolved) |leaf| {
            try items.append(allocator, .{ .path = p.path, .mode = leaf.mode, .hash = leaf.hash });
        } else if (p.work) |leaf| {
            try items.append(allocator, .{ .path = p.path, .mode = p.work_mode, .hash = leaf.hash });
        } else if (p.ours) |leaf| {
            try items.append(allocator, .{ .path = p.path, .mode = leaf.mode, .hash = leaf.hash });
        } else if (p.theirs) |leaf| {
            try items.append(allocator, .{ .path = p.path, .mode = leaf.mode, .hash = leaf.hash });
        }
    }
    std.mem.sort(model.TreeItem, items.items, {}, struct {
        fn less(_: void, a: model.TreeItem, b: model.TreeItem) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.less);
    if (items.items.len == 0) return model.emptyTree(allocator, s);
    return model.storeTree(allocator, s, items.items);
}

// ---------------------------------------------------------------------------
// Renames
// ---------------------------------------------------------------------------

const Cand = struct { path: []const u8, leaf: Leaf };

const RenameMap = struct {
    map: std.StringHashMapUnmanaged([]const u8) = .empty,
};

fn detectRenames(
    allocator: Allocator,
    s: anytype,
    base_map: *const LeafMap,
    side_map: *const LeafMap,
    threshold: u8,
    into: *RenameMap,
) !void {
    var deletes: std.ArrayList(Cand) = .empty;
    defer deletes.deinit(allocator);
    var adds: std.ArrayList(Cand) = .empty;
    defer adds.deinit(allocator);

    var bit = base_map.map.iterator();
    while (bit.next()) |e| {
        if (side_map.get(e.key_ptr.*) == null) {
            try deletes.append(allocator, .{ .path = e.key_ptr.*, .leaf = e.value_ptr.* });
        }
    }
    var sit = side_map.map.iterator();
    while (sit.next()) |e| {
        if (base_map.get(e.key_ptr.*) == null) {
            try adds.append(allocator, .{ .path = e.key_ptr.*, .leaf = e.value_ptr.* });
        }
    }

    var used_d = try allocator.alloc(bool, deletes.items.len);
    defer allocator.free(used_d);
    var used_a = try allocator.alloc(bool, adds.items.len);
    defer allocator.free(used_a);
    @memset(used_d, false);
    @memset(used_a, false);

    for (deletes.items, 0..) |d, di| {
        const ai = uniqueLeaf(adds.items, d.leaf) orelse continue;
        if (uniqueLeaf(deletes.items, d.leaf) == null) continue;
        if (used_a[ai]) continue;
        try into.map.put(allocator, d.path, adds.items[ai].path);
        used_d[di] = true;
        used_a[ai] = true;
    }

    var nd: usize = 0;
    var na: usize = 0;
    for (used_d) |u| {
        if (!u) nd += 1;
    }
    for (used_a) |u| {
        if (!u) na += 1;
    }
    if (nd == 0 or na == 0) return;
    if (nd > rename_limit or na > rename_limit or nd * na > rename_matrix_cap) return;

    const Hit = struct { score: i32, d: usize, a: usize };
    var hits: std.ArrayList(Hit) = .empty;
    defer hits.deinit(allocator);

    for (deletes.items, 0..) |d, di| {
        if (used_d[di]) continue;
        const d_bytes = model.blobBytes(allocator, s, d.leaf.hash) catch |err| {
            if (err == error.ObjectNotFound) continue;
            return err;
        };
        defer allocator.free(d_bytes);
        var d_idx = obj.SimilarityIndex.fromContent(allocator, d_bytes, blobIsBinary(d_bytes)) catch |err| {
            if (err == error.IndexFull) continue;
            return err;
        };
        defer d_idx.deinit();
        for (adds.items, 0..) |a, ai| {
            if (used_a[ai]) continue;
            const a_bytes = model.blobBytes(allocator, s, a.leaf.hash) catch |err| {
                if (err == error.ObjectNotFound) continue;
                return err;
            };
            defer allocator.free(a_bytes);
            var a_idx = obj.SimilarityIndex.fromContent(allocator, a_bytes, blobIsBinary(a_bytes)) catch |err| {
                if (err == error.IndexFull) continue;
                return err;
            };
            defer a_idx.deinit();
            const score = d_idx.score(&a_idx, 100);
            if (score >= @as(i32, threshold)) {
                try hits.append(allocator, .{ .score = score, .d = di, .a = ai });
            }
        }
    }

    std.mem.sort(Hit, hits.items, {}, struct {
        fn less(_: void, a: Hit, b: Hit) bool {
            if (a.score != b.score) return a.score > b.score;
            if (a.d != b.d) return a.d < b.d;
            return a.a < b.a;
        }
    }.less);

    for (hits.items) |h| {
        if (used_d[h.d] or used_a[h.a]) continue;
        try into.map.put(allocator, deletes.items[h.d].path, adds.items[h.a].path);
        used_d[h.d] = true;
        used_a[h.a] = true;
    }
}

fn uniqueLeaf(list: []const Cand, leaf: Leaf) ?usize {
    var found: ?usize = null;
    for (list, 0..) |c, i| {
        if (c.leaf.mode == leaf.mode and c.leaf.hash.eql(leaf.hash)) {
            if (found != null) return null;
            found = i;
        }
    }
    return found;
}

// ---------------------------------------------------------------------------
// Alignment and directory/file conflicts
// ---------------------------------------------------------------------------

const Forced = enum { none, md_ours, md_theirs, keep_stages };

const Node = struct {
    base: ?Leaf = null,
    ours: ?Leaf = null,
    theirs: ?Leaf = null,
    ours_renamed: bool = false,
    theirs_renamed: bool = false,
    rename_rename: bool = false,
    forced: Forced = .none,
};

const NodeMap = std.StringHashMapUnmanaged(Node);

fn deinitNodes(allocator: Allocator, map: *NodeMap) void {
    var it = map.iterator();
    while (it.next()) |e| allocator.free(e.key_ptr.*);
    map.deinit(allocator);
}

fn putNode(map: *NodeMap, allocator: Allocator, path: []const u8) !*Node {
    if (map.getPtr(path)) |n| return n;
    const key = try allocator.dupe(u8, path);
    errdefer allocator.free(key);
    try map.put(allocator, key, .{});
    return map.getPtr(key).?;
}

fn putNodeOwned(map: *NodeMap, allocator: Allocator, key: []u8) !*Node {
    if (map.getPtr(key)) |n| {
        allocator.free(key);
        return n;
    }
    try map.put(allocator, key, .{});
    return map.getPtr(key).?;
}

fn removeNode(map: *NodeMap, allocator: Allocator, path: []const u8) void {
    if (map.fetchRemove(path)) |kv| allocator.free(kv.key);
}

fn alignTrees(
    allocator: Allocator,
    base_map: *const LeafMap,
    ours_map: *const LeafMap,
    theirs_map: *const LeafMap,
    ours_ren: *const RenameMap,
    theirs_ren: *const RenameMap,
    nodes: *NodeMap,
) !void {
    var consumed: std.StringHashMapUnmanaged(void) = .empty;
    defer consumed.deinit(allocator);

    var it = base_map.map.iterator();
    while (it.next()) |e| {
        const path = e.key_ptr.*;
        const o_to = ours_ren.map.get(path);
        const t_to = theirs_ren.map.get(path);
        if (o_to != null and t_to != null and !std.mem.eql(u8, o_to.?, t_to.?)) {
            {
                const n = try putNode(nodes, allocator, o_to.?);
                if (n.ours == null) n.ours = ours_map.get(o_to.?);
                n.ours_renamed = true;
                n.rename_rename = true;
            }
            {
                const n = try putNode(nodes, allocator, t_to.?);
                if (n.theirs == null) n.theirs = theirs_map.get(t_to.?);
                n.theirs_renamed = true;
                n.rename_rename = true;
            }
            try consumed.put(allocator, path, {});
            try consumed.put(allocator, o_to.?, {});
            try consumed.put(allocator, t_to.?, {});
            continue;
        }
        const dest = o_to orelse t_to orelse path;
        const n = try putNode(nodes, allocator, dest);
        if (n.base == null) n.base = e.value_ptr.*;
        if (o_to) |dest_path| {
            if (n.ours == null) n.ours = ours_map.get(dest_path);
            n.ours_renamed = true;
            try consumed.put(allocator, dest_path, {});
        } else if (ours_map.get(path)) |leaf| {
            if (n.ours == null) n.ours = leaf;
            try consumed.put(allocator, path, {});
        }
        if (t_to) |dest_path| {
            if (n.theirs == null) n.theirs = theirs_map.get(dest_path);
            n.theirs_renamed = true;
            try consumed.put(allocator, dest_path, {});
        } else if (theirs_map.get(path)) |leaf| {
            if (n.theirs == null) n.theirs = leaf;
            try consumed.put(allocator, path, {});
        }
        try consumed.put(allocator, path, {});
    }

    var oit = ours_map.map.iterator();
    while (oit.next()) |e| {
        if (consumed.get(e.key_ptr.*) != null) continue;
        const n = try putNode(nodes, allocator, e.key_ptr.*);
        if (n.ours == null) n.ours = e.value_ptr.*;
    }
    var tit = theirs_map.map.iterator();
    while (tit.next()) |e| {
        if (consumed.get(e.key_ptr.*) != null) continue;
        const n = try putNode(nodes, allocator, e.key_ptr.*);
        if (n.theirs == null) n.theirs = e.value_ptr.*;
    }
}

fn collectKeys(allocator: Allocator, map: *NodeMap) ![][]const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    errdefer keys.deinit(allocator);
    var it = map.iterator();
    while (it.next()) |e| try keys.append(allocator, e.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return try keys.toOwnedSlice(allocator);
}

fn hasChildKey(keys: []const []const u8, path: []const u8) bool {
    for (keys) |k| {
        if (k.len > path.len + 1 and std.mem.startsWith(u8, k, path) and k[path.len] == '/') return true;
    }
    return false;
}

const Side = enum { ours, theirs };

fn sideHasChild(map: *NodeMap, keys: []const []const u8, path: []const u8, side: Side) bool {
    for (keys) |k| {
        if (!(k.len > path.len + 1 and std.mem.startsWith(u8, k, path) and k[path.len] == '/')) continue;
        const n = map.get(k) orelse continue;
        const leaf = switch (side) {
            .ours => n.ours,
            .theirs => n.theirs,
        };
        if (leaf != null) return true;
    }
    return false;
}

fn applyDirectoryFile(allocator: Allocator, map: *NodeMap, ours_label: []const u8, theirs_label: []const u8) !void {
    const keys = try collectKeys(allocator, map);
    defer allocator.free(keys);
    for (keys) |path| {
        if (!hasChildKey(keys, path)) continue;
        const node = map.get(path) orelse continue;
        const ours_file = node.ours != null;
        const theirs_file = node.theirs != null;
        const ours_dir = sideHasChild(map, keys, path, .ours);
        const theirs_dir = sideHasChild(map, keys, path, .theirs);
        if (!ours_dir and !theirs_dir) continue;
        if (ours_file and theirs_file) {
            if (map.getPtr(path)) |n| n.forced = .keep_stages;
            continue;
        }
        if (ours_dir and !ours_file and theirs_file) {
            try relocate(allocator, map, path, theirs_label, .theirs);
        } else if (theirs_dir and !theirs_file and ours_file) {
            try relocate(allocator, map, path, ours_label, .ours);
        } else if (ours_file or theirs_file) {
            if (map.getPtr(path)) |n| n.forced = .keep_stages;
        }
    }
}

fn relocate(
    allocator: Allocator,
    map: *NodeMap,
    path: []const u8,
    label: []const u8,
    which: Side,
) !void {
    const node = map.get(path) orelse return;
    const dest = try std.fmt.allocPrint(allocator, "{s}~{s}", .{ path, label });
    const n = try putNodeOwned(map, allocator, dest);
    switch (which) {
        .theirs => {
            if (n.base == null) n.base = node.base;
            if (n.theirs == null) n.theirs = node.theirs;
            n.forced = .md_theirs;
        },
        .ours => {
            if (n.base == null) n.base = node.base;
            if (n.ours == null) n.ours = node.ours;
            n.forced = .md_ours;
        },
    }
    if (map.getPtr(path)) |src| {
        switch (which) {
            .theirs => {
                src.base = null;
                src.theirs = null;
            },
            .ours => {
                src.base = null;
                src.ours = null;
            },
        }
        if (src.base == null and src.ours == null and src.theirs == null and !src.rename_rename) {
            removeNode(map, allocator, path);
        }
    }
}

// ---------------------------------------------------------------------------
// Attributes
// ---------------------------------------------------------------------------

const Attrs = struct {
    stack: []gitattributes.MatchAttribute,
    matcher: gitattributes.Matcher,

    fn deinit(self: *Attrs, allocator: Allocator) void {
        self.matcher.deinit();
        gitattributes.freeMatchAttributes(allocator, self.stack);
        self.* = undefined;
    }
};

fn loadAttrs(allocator: Allocator, s: anytype, ours_tree: Hash) !?Attrs {
    if (ours_tree.isZero()) return null;
    const tree = try obj.getTree(allocator, s, ours_tree);
    defer obj.freeTree(allocator, tree);
    for (tree.entries.items) |e| {
        if (!std.mem.eql(u8, e.name, ".gitattributes") or e.mode == filemode.Dir) continue;
        const bytes = try model.blobBytes(allocator, s, e.hash);
        defer allocator.free(bytes);
        const stack = try gitattributes.readAttributes(allocator, bytes, &.{}, true);
        errdefer gitattributes.freeMatchAttributes(allocator, stack);
        const matcher = try gitattributes.newMatcher(allocator, stack);
        return .{ .stack = stack, .matcher = matcher };
    }
    return null;
}

fn markedNonText(allocator: Allocator, attrs: ?*Attrs, path: []const u8) !bool {
    const held = attrs orelse return false;
    var segs: std.ArrayList([]const u8) = .empty;
    defer segs.deinit(allocator);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        try segs.append(allocator, part);
    }
    const names = [_][]const u8{ "binary", "merge" };
    var matched = try held.matcher.match(allocator, segs.items, &names);
    defer matched.results.deinit(allocator);
    if (matched.results.get("binary")) |attr| if (attr.isSet()) return true;
    if (matched.results.get("merge")) |attr| {
        if (attr.isUnset() or attr.isValueSet()) return true;
    }
    return false;
}
