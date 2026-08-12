//! Ref matching and have/want negotiation helpers (go-git `remote.go`
//! `calculateRefs` / `getWants` / `getHaves` / `objectExists`).

const std = @import("std");
const plumbing = @import("plumbing");
const gitconfig = @import("gitconfig");
const memory = @import("memory");
const storer = @import("storer");
const objpkg = @import("object");

const remote_error = @import("error.zig");
const options = @import("options.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const RefSpec = gitconfig.RefSpec;
const TagMode = options.TagMode;
const HashSet = objpkg.HashSet;

/// go-git `refspecAllTags` — force-fetch all tags.
pub const refspec_all_tags: []const u8 = "+refs/tags/*:refs/tags/*";

/// go-git `maxHavesToVisitPerRef`.
pub const max_haves_to_visit_per_ref: i32 = 100;

// ---------------------------------------------------------------------------
// calculateRefs
// ---------------------------------------------------------------------------

/// Result of `calculateRefs` (go-git `refs` + `specToRefs`).
///
/// - `refs` owns reference name/target strings.
/// - `spec_to_refs[i]` holds value copies; names borrow from `refs` storage.
pub const CalculateRefsResult = struct {
    refs: memory.ReferenceStorage,
    /// One slice of matched refs per input refspec (plus all-tags when added).
    spec_to_refs: [][]Reference,
    allocator: Allocator,

    pub fn deinit(self: *CalculateRefsResult) void {
        for (self.spec_to_refs) |slice| {
            if (slice.len > 0) self.allocator.free(slice);
        }
        if (self.spec_to_refs.len > 0) self.allocator.free(self.spec_to_refs);
        self.refs.deinit();
        self.* = undefined;
    }
};

/// go-git `calculateRefs`.
///
/// `remote_refs` is typically from `AdvRefs.allReferences()`.
/// Caller owns the result (`deinit`).
pub fn calculateRefs(
    allocator: Allocator,
    specs: []const RefSpec,
    remote_refs: *const memory.ReferenceStorage,
    tag_mode: TagMode,
) !CalculateRefsResult {
    var expanded: std.ArrayList(RefSpec) = .empty;
    defer expanded.deinit(allocator);

    try expanded.appendSlice(allocator, specs);
    if (tag_mode == .all) {
        try expanded.append(allocator, RefSpec.init(refspec_all_tags));
    }

    var refs = memory.ReferenceStorage.init(allocator);
    errdefer refs.deinit();

    const n = expanded.items.len;
    var spec_to_refs = try allocator.alloc([]Reference, n);
    errdefer {
        for (spec_to_refs) |slice| {
            if (slice.len > 0) allocator.free(slice);
        }
        allocator.free(spec_to_refs);
    }
    for (spec_to_refs) |*slot| slot.* = &.{};

    for (expanded.items, 0..) |spec, i| {
        spec_to_refs[i] = try doCalculateRefs(allocator, spec, remote_refs, &refs);
    }

    return .{
        .refs = refs,
        .spec_to_refs = spec_to_refs,
        .allocator = allocator,
    };
}

fn doCalculateRefs(
    allocator: Allocator,
    s: RefSpec,
    remote_refs: *const memory.ReferenceStorage,
    refs: *memory.ReferenceStorage,
) ![]Reference {
    var ref_list: std.ArrayList(Reference) = .empty;
    errdefer ref_list.deinit(allocator);

    if (s.isExactSHA1()) {
        const dst_name = try s.dst(allocator, ReferenceName.init(""));
        defer allocator.free(dst_name.raw);
        const h = plumbing.newHash(s.src());
        const ref = Reference.newHashReference(dst_name, h);
        try refs.setReference(ref);
        const stored = try refs.reference(dst_name);
        try ref_list.append(allocator, stored);
        return try ref_list.toOwnedSlice(allocator);
    }

    var matched = false;

    if (s.isWildcard()) {
        var iter = try remote_refs.iterReferences();
        defer iter.deinit();
        while (true) {
            const ref = iter.next() catch |err| switch (err) {
                error.EndOfStream => break,
            };
            if (!s.match(ref.name)) continue;
            try onMatched(allocator, remote_refs, refs, &ref_list, &matched, ref);
        }
    } else {
        const src = s.src();
        if (expandRef(remote_refs, ReferenceName.init(src))) |resolved| {
            try onMatched(allocator, remote_refs, refs, &ref_list, &matched, resolved);
        } else |_| {}
    }

    if (!matched and !s.isWildcard()) {
        return remote_error.Error.NoMatchingRefSpec;
    }

    return try ref_list.toOwnedSlice(allocator);
}

fn onMatched(
    allocator: Allocator,
    remote: *const memory.ReferenceStorage,
    refs: *memory.ReferenceStorage,
    list: *std.ArrayList(Reference),
    matched: *bool,
    ref_in: Reference,
) !void {
    var ref = ref_in;
    if (ref.type == .symbolic) {
        const target = try storer.resolveReference(remote, ref.name);
        ref = Reference.newHashReference(ref.name, target.hash);
    }
    if (ref.type != .hash) return;

    matched.* = true;
    try refs.setReference(ref);
    const stored = try refs.reference(ref.name);
    try list.append(allocator, stored);
}

/// go-git `expand_ref` — try `RefRevParseRules` until one resolves.
fn expandRef(s: *const memory.ReferenceStorage, short: ReferenceName) !Reference {
    var first_err: ?anyerror = null;
    var name_buf: [512]u8 = undefined;

    if (tryExpand(s, short.raw, &first_err)) |r| return r;
    if (tryExpandFmt(s, &name_buf, "refs/{s}", short.raw, &first_err)) |r| return r;
    if (tryExpandFmt(s, &name_buf, "refs/tags/{s}", short.raw, &first_err)) |r| return r;
    if (tryExpandFmt(s, &name_buf, "refs/heads/{s}", short.raw, &first_err)) |r| return r;
    if (tryExpandFmt(s, &name_buf, "refs/remotes/{s}", short.raw, &first_err)) |r| return r;
    if (tryExpandFmt(s, &name_buf, "refs/remotes/{s}/HEAD", short.raw, &first_err)) |r| return r;

    return first_err orelse error.ReferenceNotFound;
}

fn tryExpand(
    s: *const memory.ReferenceStorage,
    name_str: []const u8,
    first_err: *?anyerror,
) ?Reference {
    return storer.resolveReference(s, ReferenceName.init(name_str)) catch |err| {
        if (first_err.* == null) first_err.* = err;
        return null;
    };
}

fn tryExpandFmt(
    s: *const memory.ReferenceStorage,
    buf: []u8,
    comptime fmt: []const u8,
    short: []const u8,
    first_err: *?anyerror,
) ?Reference {
    const name_str = std.fmt.bufPrint(buf, fmt, .{short}) catch return null;
    return tryExpand(s, name_str, first_err);
}

// ---------------------------------------------------------------------------
// objectExists / getWants
// ---------------------------------------------------------------------------

/// go-git `objectExists` — true when any object type is present for `hash`.
pub fn objectExists(store: anytype, hash: Hash) bool {
    _ = store.encodedObject(.any, hash) catch return false;
    return true;
}

/// go-git `getWants`. Caller frees the returned slice.
///
/// `local_store` must provide `encodedObject(type, hash)` and `shallow()`.
pub fn getWants(
    allocator: Allocator,
    local_store: anytype,
    matched_refs: *const memory.ReferenceStorage,
    depth: i32,
) ![]Hash {
    // If depth is anything other than 1 and the repo has shallow commits,
    // having the tip object does not mean parents are present.
    var shallow = false;
    if (depth != 1) {
        const shallows = local_store.shallow();
        if (shallows.len > 0) shallow = true;
    }

    var wants: HashSet = .empty;
    defer wants.deinit(allocator);

    var it = matched_refs.refs.iterator();
    while (it.next()) |e| {
        const ref = e.value_ptr.*;
        if (ref.type != .hash) continue;
        const hash = ref.hash;
        const exists = objectExists(local_store, hash);
        if (!exists or shallow) {
            try wants.put(allocator, hash, {});
        }
    }

    var result = try allocator.alloc(Hash, wants.count());
    var i: usize = 0;
    var wit = wants.keyIterator();
    while (wit.next()) |hp| {
        result[i] = hp.*;
        i += 1;
    }
    return result;
}

// ---------------------------------------------------------------------------
// getHaves
// ---------------------------------------------------------------------------

/// go-git `getHaves`. Caller frees the returned slice.
///
/// `local_store` must be a mutable pointer with `encodedObject` (e.g. `*memory.Storage`).
pub fn getHaves(
    allocator: Allocator,
    local_refs: []const Reference,
    remote_ref_store: *const memory.ReferenceStorage,
    local_store: anytype,
    depth: i32,
) ![]Hash {
    var haves: HashSet = .empty;
    errdefer haves.deinit(allocator);

    var remote_hashes: HashSet = .empty;
    defer remote_hashes.deinit(allocator);
    try getRemoteRefsFromStorer(allocator, remote_ref_store, &remote_hashes);

    for (local_refs) |ref| {
        if (haves.contains(ref.hash)) continue;
        if (ref.type != .hash) continue;
        try getHavesFromRef(allocator, ref, &remote_hashes, local_store, &haves, depth);
    }

    var result = try allocator.alloc(Hash, haves.count());
    var i: usize = 0;
    var it = haves.keyIterator();
    while (it.next()) |hp| {
        result[i] = hp.*;
        i += 1;
    }
    haves.deinit(allocator);
    return result;
}

fn getRemoteRefsFromStorer(
    allocator: Allocator,
    remote_ref_store: *const memory.ReferenceStorage,
    out: *HashSet,
) !void {
    var iter = try remote_ref_store.iterReferences();
    defer iter.deinit();
    while (true) {
        const ref = iter.next() catch |err| switch (err) {
            error.EndOfStream => break,
        };
        if (ref.type != .hash) continue;
        try out.put(allocator, ref.hash, {});
    }
}

fn getHavesFromRef(
    allocator: Allocator,
    ref: Reference,
    remote_refs: *const HashSet,
    local_store: anytype,
    haves: *HashSet,
    depth: i32,
) !void {
    const h = ref.hash;
    if (haves.contains(h)) return;

    const commit = objpkg.getCommit(allocator, local_store, h) catch |err| {
        if (err != error.ObjectNotFound) {
            // Not a missing object (e.g. decode failure): still advertise the tip.
            try haves.put(allocator, ref.hash, {});
        }
        return;
    };
    // Free tip if the walker never yields it (init failure / immediate stop).
    var tip_owned = true;
    defer if (tip_owned) objpkg.freeCommit(allocator, commit);

    var to_visit: i32 = max_haves_to_visit_per_ref;
    if (depth > 0 and depth < max_haves_to_visit_per_ref) {
        to_visit = depth;
    }

    // seenExternal = haves so shared history across refs is not re-walked.
    var walker = objpkg.newCommitPreorderIter(allocator, commit, haves, &.{}) catch return;
    defer walker.deinit();

    // Ignore walker errors (shallow missing parents) — same as go-git `_ = walker.ForEach`.
    while (true) {
        const c = walker.next() catch break;
        if (c == commit) tip_owned = false;
        defer objpkg.freeCommit(allocator, c);
        haves.put(allocator, c.hash, {}) catch break;
        to_visit -= 1;
        if (to_visit == 0 or remote_refs.contains(c.hash)) break;
    }
}

// ---------------------------------------------------------------------------
// Shared local-ref + fast-forward helpers (fetch + push)
// ---------------------------------------------------------------------------

/// Collect all local references (borrowed name/target). Caller frees the slice only.
pub fn collectLocalRefs(allocator: Allocator, sto: *memory.Storage) ![]Reference {
    var iter = try sto.iterReferences();
    defer iter.deinit();
    var list: std.ArrayList(Reference) = .empty;
    errdefer list.deinit(allocator);
    while (true) {
        const ref = iter.next() catch |err| switch (err) {
            error.EndOfStream => break,
        };
        try list.append(allocator, ref);
    }
    return try list.toOwnedSlice(allocator);
}

/// go-git `isFastForward` — true when `old` is reachable from `new_h` by walking
/// commit parents (preorder). Uses `object.Commit` + preorder iter (not a raw
/// parent-hex scan).
///
/// `earliest_shallow` when set stops the walk before that commit's parents
/// (go-git shallow pull support).
pub fn isFastForward(
    allocator: Allocator,
    sto: *memory.Storage,
    old: Hash,
    new_h: Hash,
    earliest_shallow: ?Hash,
) !bool {
    if (old.eql(new_h)) return true;
    if (old.isZero()) return true;

    const tip = try objpkg.getCommit(allocator, sto, new_h);
    var tip_owned = true;
    defer if (tip_owned) objpkg.freeCommit(allocator, tip);

    var ignore: []const Hash = &.{};
    var ignore_owned: ?[]Hash = null;
    defer if (ignore_owned) |s| allocator.free(s);

    if (earliest_shallow) |es| {
        const shallow_c = try objpkg.getCommit(allocator, sto, es);
        defer objpkg.freeCommit(allocator, shallow_c);
        ignore_owned = try allocator.dupe(Hash, shallow_c.parent_hashes);
        ignore = ignore_owned.?;
    }

    var walker = try objpkg.newCommitPreorderIter(allocator, tip, null, ignore);
    defer walker.deinit();

    while (true) {
        const c = walker.next() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (c == tip) tip_owned = false;
        defer objpkg.freeCommit(allocator, c);
        if (c.hash.eql(old)) return true;
    }
    return false;
}

test "isFastForward equal hashes" {
    const gpa = std.testing.allocator;
    const sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    const h = plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    try std.testing.expect(try isFastForward(gpa, sto, h, h, null));
    try std.testing.expect(try isFastForward(gpa, sto, plumbing.ZeroHash, h, null));
}

test "isFastForward production walk free yields zero leaks" {
    const gpa = std.testing.allocator;
    const sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }

    const empty_tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
    const storeCommit = struct {
        fn call(alloc: Allocator, store: *memory.Storage, parents: []const Hash, when: i64) !Hash {
            var body: std.Io.Writer.Allocating = .init(alloc);
            defer body.deinit();
            try body.writer.print("tree {s}\n", .{empty_tree});
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
    }.call;

    const h_root = try storeCommit(gpa, sto, &.{}, 1);
    const h_mid = try storeCommit(gpa, sto, &.{h_root}, 2);
    const h_tip = try storeCommit(gpa, sto, &.{h_mid}, 3);

    try std.testing.expect(try isFastForward(gpa, sto, h_root, h_tip, null));
    try std.testing.expect(try isFastForward(gpa, sto, h_mid, h_tip, null));
    try std.testing.expect(!(try isFastForward(gpa, sto, h_tip, h_root, null)));
}
