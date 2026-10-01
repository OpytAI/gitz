//! Apply a computed merge to HEAD, the index, and the worktree.
//!
//! `mergeTrees` may store content-addressed objects before this runs. An error
//! from `merge` is returned before those results are checked out, so HEAD, the
//! index, and the worktree stay as they were. A conflict is a result with
//! `clean == false`: stages and `MERGE_HEAD` are written and HEAD stays.
//!
//! `conflict_style` comes from `MergeOptions`. Repository config does not
//! store `merge.conflictStyle`. A path whose `merge` attribute names a custom
//! driver is left conflicted; the driver is not run. rerere, mergetools, and
//! hooks are not run. The index and every tracked worktree path must already
//! match HEAD.

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const obj = @import("object");
const index_fmt = @import("index");

const options = @import("options.zig");
const engine = @import("engine.zig");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Reference = plumbing.Reference;

const o_rdonly: u32 = 0;
const o_wronly: u32 = 1;
const o_create: u32 = 0x40;
const o_trunc: u32 = 0x200;

pub fn merge(w: anytype, heads: []const Hash, opts: options.MergeOptions) !options.MergeResult {
    const strategy = opts.strategy orelse if (heads.len > 1) options.Strategy.octopus else options.Strategy.ort;
    try validate(strategy, heads, opts);

    if (try gitPresent(w, "MERGE_HEAD")) return error.MergeInProgress;
    const head_hash = try resolveHead(w);
    try assertClean(w, head_hash);

    const head_c = try obj.getCommit(w.allocator, w.storer, head_hash);
    defer obj.freeCommit(w.allocator, head_c);

    var others: std.ArrayList(*obj.Commit) = .empty;
    defer {
        for (others.items) |c| obj.freeCommit(w.allocator, c);
        others.deinit(w.allocator);
    }
    for (heads) |h| {
        const c = obj.getCommit(w.allocator, w.storer, h) catch |err| {
            if (err == error.ObjectNotFound and try engine.shallowNonEmpty(w.storer)) return error.ShallowHistory;
            return err;
        };
        try others.append(w.allocator, c);
    }

    var rels = try w.allocator.alloc(Rel, others.items.len);
    defer w.allocator.free(rels);
    for (others.items, 0..) |c, i| {
        rels[i] = try relation(w.storer, head_c, c);
    }

    const fast = switch (strategy) {
        .ort, .recursive, .resolve, .subtree => true,
        .ours, .octopus => false,
    };
    if (upToDate(fast, rels)) return .{ .clean = true, .commit = null };

    if (!fast and opts.fast_forward == .ff_only) return error.NotFastForward;

    if (fast and heads.len == 1 and rels[0] == .can_ff and opts.fast_forward != .no_ff) {
        try fastForward(w, head_hash, others.items[0]);
        return .{ .clean = true, .commit = null };
    }
    if (fast and heads.len == 1 and rels[0] == .diverged and opts.fast_forward == .ff_only) {
        return error.NotFastForward;
    }

    const skip_shift = fast and heads.len == 1 and rels[0] == .can_ff;
    const commit_hash = try computeAndApply(w, strategy, opts, head_hash, head_c, others.items, skip_shift);
    return commit_hash;
}

pub fn mergeAbort(w: anytype) !void {
    if (!try gitPresent(w, "MERGE_HEAD")) return error.MergeNotInProgress;
    const orig = (try w.storer.readGitFile(w.allocator, "ORIG_HEAD")) orelse return error.CorruptMergeState;
    defer w.allocator.free(orig);
    const hash = parseOneHash(orig) catch return error.CorruptMergeState;
    const commit = try obj.getCommit(w.allocator, w.storer, hash);
    defer obj.freeCommit(w.allocator, commit);
    var tm = try engine.takeTree(w.allocator, w.storer, commit.tree_hash);
    defer engine.deinitTreeMerge(w.allocator, &tm);
    try materialize(w, &tm);
    try updateHead(w, hash);
    try removeMergeFiles(w, true);
}

pub fn mergeContinue(w: anytype) !Hash {
    if (!try gitPresent(w, "MERGE_HEAD")) return error.MergeNotInProgress;
    const msg = (try w.storer.readGitFile(w.allocator, "MERGE_MSG")) orelse return error.CorruptMergeState;
    defer w.allocator.free(msg);
    const merged = (try w.storer.readGitFile(w.allocator, "MERGE_HEAD")) orelse return error.CorruptMergeState;
    defer w.allocator.free(merged);

    const idx = try w.storer.index();
    for (idx.entries.items) |e| {
        if (e.stage != 0) return error.UnmergedPaths;
    }
    var items: std.ArrayList(model.TreeItem) = .empty;
    defer items.deinit(w.allocator);
    for (idx.entries.items) |e| {
        try items.append(w.allocator, .{ .path = e.name, .mode = e.mode, .hash = e.hash });
    }
    std.mem.sort(model.TreeItem, items.items, {}, pathLess);
    const tree = if (items.items.len == 0)
        try model.emptyTree(w.allocator, w.storer)
    else
        try model.storeTree(w.allocator, w.storer, items.items);

    const head_hash = try resolveHead(w);
    var parents: std.ArrayList(Hash) = .empty;
    defer parents.deinit(w.allocator);
    try parents.append(w.allocator, head_hash);
    var lines = std.mem.splitScalar(u8, merged, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try parents.append(w.allocator, parseOneHash(trimmed) catch return error.CorruptMergeState);
    }
    if (parents.items.len < 2) return error.CorruptMergeState;

    const id = try writeCommit(w, msg, parents.items, tree);
    try updateHead(w, id);
    try removeMergeFiles(w, false);
    return id;
}

fn pathLess(_: void, a: model.TreeItem, b: model.TreeItem) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

const Rel = enum { equal, can_ff, contained, diverged };

fn relation(s: anytype, head: *obj.Commit, other: *obj.Commit) !Rel {
    if (head.hash.eql(other.hash)) return .equal;
    if (obj.isAncestor(head, other) catch |err| return mapWalk(s, err)) return .can_ff;
    if (obj.isAncestor(other, head) catch |err| return mapWalk(s, err)) return .contained;
    return .diverged;
}

fn mapWalk(s: anytype, err: anyerror) !Rel {
    if (err == error.ObjectNotFound and try engine.shallowNonEmpty(s)) return error.ShallowHistory;
    return err;
}

fn upToDate(fast: bool, rels: []const Rel) bool {
    _ = fast;
    for (rels) |r| {
        if (r != .equal and r != .contained) return false;
    }
    return true;
}

fn validate(strategy: options.Strategy, heads: []const Hash, opts: options.MergeOptions) !void {
    if (heads.len == 0) return error.NoMergeHeads;
    switch (strategy) {
        .ort, .recursive, .resolve, .subtree => {
            if (heads.len != 1) return error.StrategyOptionNotSupported;
        },
        .octopus, .ours => {},
    }
    if (opts.rename_threshold > 100) return error.StrategyOptionNotSupported;
    if (opts.favor != .none) {
        switch (strategy) {
            .ort, .recursive, .subtree => {},
            else => return error.StrategyOptionNotSupported,
        }
    }
    switch (strategy) {
        .ours, .octopus => {
            if (opts.diff_algorithm != .histogram) return error.StrategyOptionNotSupported;
            if (!opts.find_renames) return error.StrategyOptionNotSupported;
            if (opts.rename_threshold != 50) return error.StrategyOptionNotSupported;
            if (opts.conflict_style != .merge) return error.StrategyOptionNotSupported;
            if (opts.subtree_path != null) return error.StrategyOptionNotSupported;
        },
        .resolve => {
            if (opts.rename_threshold != 50) return error.StrategyOptionNotSupported;
            if (opts.subtree_path != null) return error.StrategyOptionNotSupported;
        },
        .ort, .recursive => {
            if (opts.subtree_path != null) return error.StrategyOptionNotSupported;
        },
        .subtree => if (opts.subtree_path) |p| try engine.validatePrefix(p),
    }
}

fn computeAndApply(
    w: anytype,
    strategy: options.Strategy,
    opts: options.MergeOptions,
    head_hash: Hash,
    head_c: *obj.Commit,
    others: []*obj.Commit,
    skip_shift: bool,
) !options.MergeResult {
    var theirs_buf: [plumbing.MaxHexSize]u8 = undefined;
    const theirs_label = if (others.len == 1) others[0].hash.string(&theirs_buf) else "theirs";
    var base_raw: [7]u8 = undefined;
    const base_label = if (others.len == 1)
        try shortBaseLabel(w.allocator, w.storer, head_c, others[0], &base_raw)
    else
        "base";
    const spec = makeSpec(opts, strategy, "HEAD", theirs_label, base_label);

    var tm = switch (strategy) {
        .ours => try engine.takeTree(w.allocator, w.storer, head_c.tree_hash),
        .octopus => try engine.mergeOctopus(w.allocator, w.storer, head_c, others, spec),
        .ort, .recursive, .resolve, .subtree => blk: {
            var base_tree = try engine.ancestorTree(w.allocator, w.storer, head_c, others[0], 0, spec);
            var theirs_tree = others[0].tree_hash;
            if (strategy == .subtree and !skip_shift) {
                const prefix = try engine.subtreePrefix(
                    w.allocator,
                    w.storer,
                    head_c.tree_hash,
                    theirs_tree,
                    opts.subtree_path,
                );
                defer w.allocator.free(prefix);
                base_tree = try model.shiftTree(w.allocator, w.storer, base_tree, prefix);
                theirs_tree = try model.shiftTree(w.allocator, w.storer, theirs_tree, prefix);
            }
            break :blk try engine.mergeTrees(
                w.allocator,
                w.storer,
                base_tree,
                head_c.tree_hash,
                theirs_tree,
                spec,
            );
        },
    };
    defer engine.deinitTreeMerge(w.allocator, &tm);

    const message = try commitMessage(w.allocator, opts.message, others);
    defer if (message.owned) w.allocator.free(message.text);

    if (!tm.clean) {
        try materialize(w, &tm);
        try writeOrig(w, head_hash);
        try writeHeads(w, "MERGE_HEAD", others);
        try w.storer.writeGitFile("MERGE_MSG", message.text);
        if (tm.marker_tree) |h| try writeHashFile(w, "AUTO_MERGE", h);
        return .{ .clean = false, .commit = null };
    }

    var parents: std.ArrayList(Hash) = .empty;
    defer parents.deinit(w.allocator);
    try parents.append(w.allocator, head_hash);
    for (others) |c| try parents.append(w.allocator, c.hash);

    if (opts.no_commit) {
        try materialize(w, &tm);
        try writeOrig(w, head_hash);
        try writeHeads(w, "MERGE_HEAD", others);
        try w.storer.writeGitFile("MERGE_MSG", message.text);
        return .{ .clean = true, .commit = null };
    }

    const id = try writeCommit(w, message.text, parents.items, tm.tree_hash);
    try materialize(w, &tm);
    try writeOrig(w, head_hash);
    try updateHead(w, id);
    try removeMergeFiles(w, false);
    return .{ .clean = true, .commit = id };
}

fn makeSpec(
    opts: options.MergeOptions,
    strategy: options.Strategy,
    ours_label: []const u8,
    theirs_label: []const u8,
    base_label: []const u8,
) engine.Spec {
    const renames = switch (strategy) {
        .ort, .recursive, .subtree => opts.find_renames,
        else => false,
    };
    return .{
        .renames = renames,
        .rename_threshold = opts.rename_threshold,
        .trivial_only = strategy == .octopus,
        .favor = switch (opts.favor) {
            .none => .none,
            .ours => .ours,
            .theirs => .theirs,
        },
        .algorithm = switch (opts.diff_algorithm) {
            .histogram => .histogram,
            .myers => .myers,
            .minimal => .minimal,
            .patience => .patience,
        },
        .style = switch (opts.conflict_style) {
            .merge => .merge,
            .diff3 => .diff3,
            .zdiff3 => .zdiff3,
        },
        .ours_label = ours_label,
        .theirs_label = theirs_label,
        .base_label = base_label,
        .allow_unrelated = opts.allow_unrelated_histories,
        .auto_merge = switch (strategy) {
            .ort, .recursive, .subtree => true,
            else => false,
        },
    };
}

fn shortBaseLabel(
    allocator: Allocator,
    s: anytype,
    head: *obj.Commit,
    other: *obj.Commit,
    buf: *[7]u8,
) ![]const u8 {
    const bases = obj.mergeBase(head, allocator, other) catch |err| {
        if (err == error.ObjectNotFound and try engine.shallowNonEmpty(s)) return error.ShallowHistory;
        return err;
    };
    defer obj.freeMergeBaseResult(allocator, bases);
    if (bases.len != 1) return "base";
    var hex_buf: [plumbing.MaxHexSize]u8 = undefined;
    const hex = bases[0].hash.string(&hex_buf);
    const n = @min(@as(usize, 7), hex.len);
    @memcpy(buf[0..n], hex[0..n]);
    return buf[0..n];
}

const Message = struct { text: []const u8, owned: bool };

fn commitMessage(allocator: Allocator, given: ?[]const u8, others: []*obj.Commit) !Message {
    if (given) |msg| {
        if (msg.len > 0 and msg[msg.len - 1] == '\n') return .{ .text = msg, .owned = false };
        const text = try allocator.alloc(u8, msg.len + 1);
        @memcpy(text[0..msg.len], msg);
        text[msg.len] = '\n';
        return .{ .text = text, .owned = true };
    }
    if (others.len == 1) {
        var buf: [plumbing.MaxHexSize]u8 = undefined;
        const hex = others[0].hash.string(&buf);
        return .{
            .text = try std.fmt.allocPrint(allocator, "Merge commit '{s}'\n", .{hex}),
            .owned = true,
        };
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Merge commits ");
    for (others, 0..) |c, i| {
        if (i > 0) try out.appendSlice(allocator, " ");
        var buf: [plumbing.MaxHexSize]u8 = undefined;
        try out.appendSlice(allocator, c.hash.string(&buf));
    }
    try out.append(allocator, '\n');
    return .{ .text = try out.toOwnedSlice(allocator), .owned = true };
}

fn fastForward(w: anytype, head_hash: Hash, incoming: *obj.Commit) !void {
    var tm = try engine.takeTree(w.allocator, w.storer, incoming.tree_hash);
    defer engine.deinitTreeMerge(w.allocator, &tm);
    try materialize(w, &tm);
    try writeOrig(w, head_hash);
    try updateHead(w, incoming.hash);
}

fn materialize(w: anytype, tm: *const engine.TreeMerge) !void {
    var keep: std.StringHashMapUnmanaged(void) = .empty;
    defer keep.deinit(w.allocator);
    for (tm.paths) |p| {
        if (p.write_file) try keep.put(w.allocator, p.path, {});
    }

    const idx_old = try w.storer.index();
    var stale: std.ArrayList([]u8) = .empty;
    defer {
        for (stale.items) |p| w.allocator.free(p);
        stale.deinit(w.allocator);
    }
    for (idx_old.entries.items) |e| {
        if (keep.get(e.name) != null) continue;
        var seen = false;
        for (stale.items) |p| {
            if (std.mem.eql(u8, p, e.name)) seen = true;
        }
        if (seen) continue;
        try stale.append(w.allocator, try w.allocator.dupe(u8, e.name));
    }
    for (stale.items) |p| w.filesystem.remove(p) catch {};

    for (tm.paths) |p| {
        if (!p.write_file) continue;
        try ensureParent(w, p.path);
        if (p.marker) |m| {
            try writeBytes(w, p.path, m, filemode.Regular);
        } else if (p.resolved) |leaf| {
            try writeLeaf(w, p.path, leaf);
        } else if (p.work) |leaf| {
            const mode = if (p.work_mode == filemode.Empty) leaf.mode else p.work_mode;
            const bytes = try model.blobBytes(w.allocator, w.storer, leaf.hash);
            defer w.allocator.free(bytes);
            try writeBytes(w, p.path, bytes, mode);
        }
    }

    const idx = try w.allocator.create(index_fmt.Index);
    idx.* = index_fmt.Index.init(w.allocator);
    idx.version = 2;
    errdefer {
        idx.deinit();
        w.allocator.destroy(idx);
    }
    for (tm.paths) |p| {
        if (p.resolved) |leaf| {
            try addStage(idx, p.path, leaf, 0);
        } else {
            if (p.base) |leaf| try addStage(idx, p.path, leaf, 1);
            if (p.ours) |leaf| try addStage(idx, p.path, leaf, 2);
            if (p.theirs) |leaf| try addStage(idx, p.path, leaf, 3);
        }
    }
    try adoptIndex(w.storer, idx);
}

fn addStage(idx: *index_fmt.Index, path: []const u8, leaf: model.Leaf, stage: i32) !void {
    const e = try idx.add(path);
    e.hash = leaf.hash;
    e.mode = leaf.mode;
    e.stage = stage;
}

fn writeLeaf(w: anytype, path: []const u8, leaf: model.Leaf) !void {
    if (leaf.mode == filemode.Submodule) return;
    const bytes = try model.blobBytes(w.allocator, w.storer, leaf.hash);
    defer w.allocator.free(bytes);
    try writeBytes(w, path, bytes, leaf.mode);
}

fn writeBytes(w: anytype, path: []const u8, bytes: []const u8, mode: filemode.FileMode) !void {
    w.filesystem.remove(path) catch {};
    if (mode == filemode.Symlink) {
        w.filesystem.symlink(bytes, path) catch {
            try writeRegular(w, path, bytes, filemode.Regular);
        };
        return;
    }
    try writeRegular(w, path, bytes, mode);
}

fn writeRegular(w: anytype, path: []const u8, bytes: []const u8, mode: filemode.FileMode) !void {
    const perm: u32 = if (mode == filemode.Executable) 0o755 else 0o644;
    var file = try w.filesystem.openFile(path, o_wronly | o_create | o_trunc, perm);
    errdefer file.close() catch {};
    var off: usize = 0;
    while (off < bytes.len) {
        const n = try file.write(bytes[off..]);
        if (n == 0) return error.ShortGitFileWrite;
        off += n;
    }
    try file.close();
}

fn ensureParent(w: anytype, path: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        if (i > 0) try w.filesystem.mkdirAll(path[0..i], 0o755);
    }
}

fn adoptIndex(storage: anytype, idx: *index_fmt.Index) !void {
    const Storage = @TypeOf(storage.*);
    if (comptime @hasDecl(Storage, "setIndexOwned")) {
        try storage.setIndexOwned(idx);
    } else if (comptime @hasDecl(Storage, "set_index_can_fail") and Storage.set_index_can_fail) {
        try storage.setIndex(idx);
    } else {
        storage.setIndex(idx);
    }
}

fn assertClean(w: anytype, head_hash: Hash) !void {
    const head = try obj.getCommit(w.allocator, w.storer, head_hash);
    defer obj.freeCommit(w.allocator, head);
    var leaves = model.LeafMap{};
    defer leaves.deinit(w.allocator);
    try model.walkTree(w.allocator, w.storer, head.tree_hash, &leaves);

    const idx = try w.storer.index();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(w.allocator);
    for (idx.entries.items) |e| {
        if (e.stage != 0) return error.DirtyIndex;
        const leaf = leaves.get(e.name) orelse return error.DirtyIndex;
        if (leaf.mode != e.mode or !leaf.hash.eql(e.hash)) return error.DirtyIndex;
        try seen.put(w.allocator, e.name, {});
        if (e.mode == filemode.Submodule) continue;
        try assertWorktree(w, e.name, e.mode, e.hash);
    }
    var it = leaves.map.iterator();
    while (it.next()) |e| {
        if (seen.get(e.key_ptr.*) == null) return error.DirtyIndex;
    }
}

fn assertWorktree(w: anytype, path: []const u8, mode: filemode.FileMode, hash: Hash) !void {
    const info = w.filesystem.lstat(path) catch |err| switch (err) {
        error.NotExist => return error.DirtyWorktree,
        else => return err,
    };
    if (info.isDir()) return error.DirtyWorktree;
    const bytes = try model.blobBytes(w.allocator, w.storer, hash);
    defer w.allocator.free(bytes);
    if (mode == filemode.Symlink) {
        if (w.filesystem.readlink(path)) |target| {
            defer w.filesystem.allocator.free(target);
            if (!std.mem.eql(u8, target, bytes)) return error.DirtyWorktree;
            return;
        } else |err| switch (err) {
            error.NotLink => {},
            else => return err,
        }
    }
    const got = try readRegular(w, path);
    defer w.allocator.free(got);
    if (!std.mem.eql(u8, got, bytes)) return error.DirtyWorktree;
}

fn readRegular(w: anytype, path: []const u8) ![]u8 {
    var file = try w.filesystem.openFile(path, o_rdonly, 0);
    defer file.close() catch {};
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(w.allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = try file.read(&tmp);
        if (n == 0) break;
        try buf.appendSlice(w.allocator, tmp[0..n]);
    }
    return buf.toOwnedSlice(w.allocator);
}

fn resolveHead(w: anytype) !Hash {
    var current = w.storer.reference(plumbing.HEAD) catch |err| {
        if (err == error.ReferenceNotFound) return error.UnbornHead;
        return err;
    };
    var depth: usize = 0;
    while (current.type == .symbolic) {
        if (depth == 10) {
            w.storer.freeReference(current);
            return error.UnbornHead;
        }
        const next = w.storer.reference(current.target) catch |err| {
            w.storer.freeReference(current);
            if (err == error.ReferenceNotFound) return error.UnbornHead;
            return err;
        };
        w.storer.freeReference(current);
        current = next;
        depth += 1;
    }
    defer w.storer.freeReference(current);
    if (current.hash.isZero()) return error.UnbornHead;
    return current.hash;
}

fn updateHead(w: anytype, commit_hash: Hash) !void {
    const head = try w.storer.reference(plumbing.HEAD);
    defer w.storer.freeReference(head);
    const name = if (head.type != .hash) head.target else plumbing.HEAD;
    const ref = Reference.newHashReference(name, commit_hash);
    try w.storer.setReference(ref);
}

fn writeCommit(w: anytype, message: []const u8, parents: []const Hash, tree: Hash) !Hash {
    const cfg = try w.storer.config();
    const when = w.storer.now().sec;
    const author_name = if (cfg.author_name.len != 0 and cfg.author_email.len != 0) cfg.author_name else cfg.user_name;
    const author_email = if (cfg.author_name.len != 0 and cfg.author_email.len != 0) cfg.author_email else cfg.user_email;
    if (author_name.len == 0 or author_email.len == 0) return error.MissingAuthor;
    const committer_name = if (cfg.committer_name.len != 0 and cfg.committer_email.len != 0) cfg.committer_name else author_name;
    const committer_email = if (cfg.committer_name.len != 0 and cfg.committer_email.len != 0) cfg.committer_email else author_email;
    const author = obj.Signature{
        .name = author_name,
        .email = author_email,
        .when = when,
        .tz_offset_minutes = 0,
    };
    const committer = obj.Signature{
        .name = committer_name,
        .email = committer_email,
        .when = when,
        .tz_offset_minutes = 0,
    };

    var c = obj.Commit.init(w.allocator);
    c.tree_hash = tree;
    c.message = message;
    c.author = author;
    c.committer = committer;
    const parent_copy = try w.allocator.dupe(Hash, parents);
    defer w.allocator.free(parent_copy);
    c.parent_hashes = parent_copy;
    const enc = try w.storer.newEncodedObject();
    errdefer w.storer.discardEncodedObject(enc);
    try c.encode(enc);
    c.parent_hashes = &.{};
    c.message = "";
    c.author = .{};
    c.committer = .{};
    return try w.storer.setEncodedObject(enc);
}

fn writeOrig(w: anytype, hash: Hash) !void {
    try writeHashFile(w, "ORIG_HEAD", hash);
}

fn writeHashFile(w: anytype, name: []const u8, hash: Hash) !void {
    var buf: [plumbing.MaxHexSize]u8 = undefined;
    const hex = hash.string(&buf);
    const text = try std.fmt.allocPrint(w.allocator, "{s}\n", .{hex});
    defer w.allocator.free(text);
    try w.storer.writeGitFile(name, text);
}

fn writeHeads(w: anytype, name: []const u8, commits: []*obj.Commit) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(w.allocator);
    for (commits) |c| {
        var buf: [plumbing.MaxHexSize]u8 = undefined;
        try out.appendSlice(w.allocator, c.hash.string(&buf));
        try out.append(w.allocator, '\n');
    }
    try w.storer.writeGitFile(name, out.items);
}

fn removeMergeFiles(w: anytype, include_orig: bool) !void {
    try w.storer.removeGitFile("MERGE_HEAD");
    try w.storer.removeGitFile("MERGE_MSG");
    try w.storer.removeGitFile("AUTO_MERGE");
    if (include_orig) try w.storer.removeGitFile("ORIG_HEAD");
}

fn gitPresent(w: anytype, name: []const u8) !bool {
    const bytes = try w.storer.readGitFile(w.allocator, name);
    if (bytes) |b| {
        w.allocator.free(b);
        return true;
    }
    return false;
}

fn parseOneHash(text: []const u8) !Hash {
    const line = std.mem.trim(u8, text, " \t\r\n");
    return plumbing.parseHash(line);
}
