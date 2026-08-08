//! Clone / PlainClone — port of go-git `Repository.clone`, `Clone`, `PlainClone`.
//!
//! Memory-backed path (hermetic):
//! - `clone` / `cloneEmbedded` — go-git `Clone` into `*memory.Storage` + optional `fs.Mem`
//! - `plainClone` / `plainCloneEmbedded` — path-style API: own storage, use `path_fs` as worktree
//!
//! Flow (go-git `Repository.clone`):
//! validate → createRemote (clone refspecs) → fetchAndUpdateReferences →
//! optional worktree checkout → updateRemoteConfigIfNeeded → CreateBranch tracking.

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");
const fs_pkg = @import("fs");
const storer = @import("storer");
const gitconfig = @import("gitconfig");
const objpkg = @import("object");
const remote_pkg = @import("remote");
const server = @import("server");
const repo = @import("repo");
const worktree = @import("worktree");

const error_mod = @import("error.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const Mem = fs_pkg.Mem;
const Repository = repo.Repository;
const Remote = remote_pkg.Remote;
const FetchOptions = remote_pkg.FetchOptions;
const CloneOptions = worktree.CloneOptions;
const RefSpec = gitconfig.RefSpec;

pub const Error = error_mod.Error;

// ---------------------------------------------------------------------------
// Owned result (plainClone convenience)
// ---------------------------------------------------------------------------

/// go-git-style clone result that owns the memory storage (not the worktree Mem).
///
/// `path_fs` passed to `plainClone` is borrowed for non-bare clones (not freed here).
pub const OwnedRepository = struct {
    allocator: Allocator,
    storer: *memory.Storage,
    repo: Repository,

    pub fn deinit(self: *OwnedRepository) void {
        self.storer.deinit();
        self.allocator.destroy(self.storer);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// go-git `Clone` — init empty repo in `s` then clone from `opts.url`.
///
/// `worktree_fs == null` → bare. Uses the transport client registry (installProtocol
/// / defaults). For MapLoader tests prefer `cloneEmbedded`.
pub fn clone(
    allocator: Allocator,
    s: *memory.Storage,
    worktree_fs: ?*Mem,
    opts: *CloneOptions,
) !Repository {
    return cloneInner(allocator, s, worktree_fs, opts, null);
}

/// Like `clone`, but binds an in-process `server.Server` as the transport client
/// (MapLoader tests — same pattern as `remote.newRemoteEmbedded`).
pub fn cloneEmbedded(
    allocator: Allocator,
    s: *memory.Storage,
    worktree_fs: ?*Mem,
    opts: *CloneOptions,
    srv: *server.Server,
) !Repository {
    return cloneInner(allocator, s, worktree_fs, opts, srv);
}

/// go-git `PlainClone` hermetic equivalent over `fs.Mem`.
///
/// Owns a new `memory.Storage`. Non-bare: `path_fs` is the worktree (not owned).
/// Mirror forces bare. Supports `opts.bare` when set.
pub fn plainClone(
    allocator: Allocator,
    path_fs: *Mem,
    is_bare: bool,
    opts: *CloneOptions,
) !OwnedRepository {
    return plainCloneInner(allocator, path_fs, is_bare, opts, null);
}

/// `plainClone` with embedded MapLoader server.
pub fn plainCloneEmbedded(
    allocator: Allocator,
    path_fs: *Mem,
    is_bare: bool,
    opts: *CloneOptions,
    srv: *server.Server,
) !OwnedRepository {
    return plainCloneInner(allocator, path_fs, is_bare, opts, srv);
}

fn plainCloneInner(
    allocator: Allocator,
    path_fs: *Mem,
    is_bare: bool,
    opts: *CloneOptions,
    embedded: ?*server.Server,
) !OwnedRepository {
    var bare = is_bare or opts.bare;
    if (opts.mirror) bare = true;

    const s = try memory.newStorage(allocator);
    errdefer {
        s.deinit();
        allocator.destroy(s);
    }

    const wt: ?*Mem = if (bare) null else path_fs;
    _ = try cloneInner(allocator, s, wt, opts, embedded);

    return .{
        .allocator = allocator,
        .storer = s,
        .repo = repo.newRepository(s, wt),
    };
}

fn cloneInner(
    allocator: Allocator,
    s: *memory.Storage,
    worktree_fs: ?*Mem,
    opts: *CloneOptions,
    embedded: ?*server.Server,
) !Repository {
    var r = try repo.init(s, worktree_fs);
    try cloneInto(&r, allocator, opts, embedded);
    return r;
}

/// go-git `(*Repository).clone` — operate on an already-init repository.
pub fn cloneInto(
    r: *Repository,
    allocator: Allocator,
    opts: *CloneOptions,
    embedded: ?*server.Server,
) !void {
    try opts.validate();

    // Own temporary refspec strings written into remote config.
    const fetch_specs = try cloneRefSpec(allocator, opts);
    defer freeStringSlice(allocator, fetch_specs);

    _ = try r.createRemoteFull(
        opts.remote_name,
        &[_][]const u8{opts.url},
        fetch_specs,
        opts.mirror,
    );

    const branch_info = try fetchAndUpdateReferences(r, allocator, opts, embedded);
    defer if (branch_info.merge_owned) |m| allocator.free(m);

    if (r.wt != null and !opts.no_checkout) {
        try checkoutDefault(r, allocator, embedded);
    }

    try updateRemoteConfigIfNeeded(r, opts);

    if (!opts.mirror) {
        if (branch_info.merge_owned) |merge| {
            const branch_name = ReferenceName.init(merge).short();
            const remote_name = if (opts.remote_name.len == 0)
                remote_pkg.default_remote_name
            else
                opts.remote_name;
            try r.createBranch(branch_name, remote_name, merge);
        }
    }
}

// ---------------------------------------------------------------------------
// clone refspecs (go-git `cloneRefSpec`)
// ---------------------------------------------------------------------------

const refspec_tag = "+refs/tags/{s}:refs/tags/{s}";
const refspec_single_branch = "+refs/heads/{s}:refs/remotes/{s}/{s}";
const refspec_single_branch_head = "+HEAD:refs/remotes/{s}/HEAD";
const refspec_mirror = "+refs/*:refs/*";

fn cloneRefSpec(allocator: Allocator, o: *const CloneOptions) ![]const []const u8 {
    if (o.mirror) {
        const s = try allocator.dupe(u8, refspec_mirror);
        errdefer allocator.free(s);
        const arr = try allocator.alloc([]const u8, 1);
        arr[0] = s;
        return arr;
    }

    if (o.reference_name.isTag()) {
        const short = o.reference_name.short();
        const s = try std.fmt.allocPrint(allocator, refspec_tag, .{ short, short });
        errdefer allocator.free(s);
        const arr = try allocator.alloc([]const u8, 1);
        arr[0] = s;
        return arr;
    }

    if (o.single_branch and o.reference_name.eql(plumbing.HEAD)) {
        const s = try std.fmt.allocPrint(allocator, refspec_single_branch_head, .{o.remote_name});
        errdefer allocator.free(s);
        const arr = try allocator.alloc([]const u8, 1);
        arr[0] = s;
        return arr;
    }

    if (o.single_branch) {
        const short = o.reference_name.short();
        const s = try std.fmt.allocPrint(allocator, refspec_single_branch, .{
            short,
            o.remote_name,
            short,
        });
        errdefer allocator.free(s);
        const arr = try allocator.alloc([]const u8, 1);
        arr[0] = s;
        return arr;
    }

    // Default: +refs/heads/*:refs/remotes/<name>/*
    const s = try std.fmt.allocPrint(allocator, gitconfig.default_fetch_ref_spec, .{o.remote_name});
    errdefer allocator.free(s);
    const arr = try allocator.alloc([]const u8, 1);
    arr[0] = s;
    return arr;
}

fn freeStringSlice(allocator: Allocator, specs: []const []const u8) void {
    for (specs) |s| allocator.free(s);
    allocator.free(specs);
}

// ---------------------------------------------------------------------------
// fetchAndUpdateReferences (go-git)
// ---------------------------------------------------------------------------

/// Branch tracking info extracted while remote-ref names are still valid.
const BranchInfo = struct {
    /// Owned `refs/heads/...` when the resolved tip is a branch; null when detached.
    merge_owned: ?[]u8 = null,
};

fn fetchAndUpdateReferences(
    r: *Repository,
    allocator: Allocator,
    o: *const CloneOptions,
    embedded: ?*server.Server,
) !BranchInfo {
    var rem = try remoteHandle(r, o.remote_name, embedded);

    var fetch_opts: FetchOptions = .{
        .remote_name = o.remote_name,
        .depth = o.depth,
        .tags = o.tags,
        .force = o.force,
        .transport = o.transport,
        .progress = o.progress,
    };

    var objs_updated = true;
    rem.fetch(&fetch_opts) catch |err| {
        if (err == remote_pkg.Error.AlreadyUpToDate or err == error.AlreadyUpToDate) {
            objs_updated = false;
        } else if (err == error.EmptyUploadPackRequest) {
            // go-git maps packfile.ErrEmptyPackfile → ErrFetching in some paths;
            // EmptyUploadPackRequest is "already up to date" at pack level.
            objs_updated = false;
        } else {
            return err;
        }
    };

    // go-git uses the fetch session's advertised refs. Re-list as a substitute.
    const remote_refs = try rem.list(.{ .transport = o.transport });
    defer remote_pkg.freeReferences(allocator, remote_refs);

    var remote_store = memory.ReferenceStorage.init(allocator);
    defer remote_store.deinit();
    for (remote_refs) |ref| {
        try remote_store.setReference(ref);
    }

    const resolved = try expandRef(&remote_store, o.reference_name);

    // Copy branch name before remote_store deinit frees borrowed name slices.
    var info: BranchInfo = .{};
    if (resolved.name.isBranch()) {
        info.merge_owned = try allocator.dupe(u8, resolved.name.raw);
    }
    errdefer if (info.merge_owned) |m| allocator.free(m);

    const refs_updated = try updateReferences(r, allocator, rem.config.fetch, resolved);

    if (!objs_updated and !refs_updated) {
        return remote_pkg.Error.AlreadyUpToDate;
    }

    return info;
}

fn remoteHandle(r: *Repository, name: []const u8, embedded: ?*server.Server) !Remote {
    const cfg = try r.config();
    const rc = cfg.remotes.getPtr(name) orelse return error.RemoteNotFound;
    if (embedded) |srv| {
        return remote_pkg.newRemoteEmbedded(r.storer, rc, srv);
    }
    return remote_pkg.newRemote(r.storer, rc);
}

/// go-git `expand_ref` over a reference storer (remote advertisement).
///
/// Rules mirror `plumbing.ref_rev_parse_rules`. Each format is a separate
/// `bufPrint` so the format string is comptime-known (Zig 0.16).
fn expandRef(get: anytype, ref: ReferenceName) !Reference {
    var first_err: ?anyerror = null;
    var name_buf: [512]u8 = undefined;

    if (tryExpandRef(get, ref.raw, &first_err)) |r| return r;
    if (tryExpandRefFmt(get, &name_buf, "refs/{s}", ref.raw, &first_err)) |r| return r;
    if (tryExpandRefFmt(get, &name_buf, "refs/tags/{s}", ref.raw, &first_err)) |r| return r;
    if (tryExpandRefFmt(get, &name_buf, "refs/heads/{s}", ref.raw, &first_err)) |r| return r;
    if (tryExpandRefFmt(get, &name_buf, "refs/remotes/{s}", ref.raw, &first_err)) |r| return r;
    if (tryExpandRefFmt(get, &name_buf, "refs/remotes/{s}/HEAD", ref.raw, &first_err)) |r| return r;

    return first_err orelse error.ReferenceNotFound;
}

fn tryExpandRef(get: anytype, name_str: []const u8, first_err: *?anyerror) ?Reference {
    return storer.resolveReference(get, ReferenceName.init(name_str)) catch |err| {
        if (first_err.* == null) first_err.* = err;
        return null;
    };
}

fn tryExpandRefFmt(
    get: anytype,
    buf: []u8,
    comptime fmt: []const u8,
    short: []const u8,
    first_err: *?anyerror,
) ?Reference {
    const name_str = std.fmt.bufPrint(buf, fmt, .{short}) catch return null;
    return tryExpandRef(get, name_str, first_err);
}

/// go-git `updateReferences`.
fn updateReferences(
    r: *Repository,
    allocator: Allocator,
    fetch_specs: []const []u8,
    resolved_ref: Reference,
) !bool {
    if (!resolved_ref.name.isBranch()) {
        // Detached HEAD mode
        const h = try resolveToCommitHash(r, allocator, resolved_ref.hash);
        const head = Reference.newHashReference(plumbing.HEAD, h);
        return updateReferenceIfNeeded(r.storer, head);
    }

    var updated = false;

    // Create local branch tip for the resolved ref.
    if (try updateReferenceIfNeeded(r.storer, resolved_ref)) updated = true;

    // Symbolic HEAD → branch
    const head_sym = Reference.newSymbolicReference(plumbing.HEAD, resolved_ref.name);
    if (try updateReferenceIfNeeded(r.storer, head_sym)) updated = true;

    // Remote-tracking HEAD when missing (single-branch / first clone).
    const extra = try calculateRemoteHeadReference(r, allocator, fetch_specs, resolved_ref);
    defer freeOwnedRefs(allocator, extra);
    for (extra) |ref| {
        if (try updateReferenceIfNeeded(r.storer, ref)) updated = true;
    }

    return updated;
}

fn freeOwnedRefs(allocator: Allocator, refs: []Reference) void {
    for (refs) |ref| {
        // calculateRemoteHeadReference owns name strings for dst results.
        if (ref.name.raw.len > 0) allocator.free(ref.name.raw);
    }
    allocator.free(refs);
}

/// go-git `calculateRemoteHeadReference`.
fn calculateRemoteHeadReference(
    r: *Repository,
    allocator: Allocator,
    fetch_specs: []const []u8,
    resolved_head: Reference,
) ![]Reference {
    var out: std.ArrayList(Reference) = .empty;
    errdefer {
        for (out.items) |ref| {
            if (ref.name.raw.len > 0) allocator.free(ref.name.raw);
        }
        out.deinit(allocator);
    }

    // When config fetch is empty, use default mapping for remote name from first URL remote.
    // createRemoteFull always stores our clone refspecs, so fetch_specs should be non-empty.
    for (fetch_specs) |raw| {
        const rs = RefSpec.init(raw);
        if (!rs.match(resolved_head.name)) continue;

        const dst_name = try rs.dst(allocator, resolved_head.name);
        // dst always allocates; ownership moves into the Reference.
        errdefer allocator.free(dst_name.raw);

        if (r.storer.reference(dst_name)) |_| {
            // Already present — free unused name.
            allocator.free(dst_name.raw);
            continue;
        } else |err| {
            if (err != error.ReferenceNotFound) {
                allocator.free(dst_name.raw);
                return err;
            }
        }

        try out.append(allocator, Reference.newHashReference(dst_name, resolved_head.hash));
    }

    return try out.toOwnedSlice(allocator);
}

/// go-git `updateReferenceStorerIfNeeded` (old == nil).
fn updateReferenceIfNeeded(sto: *memory.Storage, ref: Reference) !bool {
    const existing = sto.reference(ref.name) catch |err| {
        if (err != error.ReferenceNotFound) return err;
        try sto.setReference(ref);
        return true;
    };
    if (ref.eql(existing)) return false;
    try sto.setReference(ref);
    return true;
}

/// go-git `resolveToCommitHash`.
fn resolveToCommitHash(r: *Repository, allocator: Allocator, h: Hash) !Hash {
    const obj = try r.storer.encodedObject(.any, h);
    return switch (obj.object_type) {
        .commit => h,
        .tag => blk: {
            var tag = try objpkg.getTag(allocator, r.storer, h);
            defer tag.deinit();
            break :blk try resolveToCommitHash(r, allocator, tag.target);
        },
        else => error_mod.Error.UnableToResolveCommit,
    };
}

// ---------------------------------------------------------------------------
// Checkout worktree after clone
// ---------------------------------------------------------------------------

fn checkoutDefault(r: *Repository, allocator: Allocator, embedded: ?*server.Server) !void {
    const fs = r.wt orelse return error_mod.Error.IsBareRepository;

    var w = if (embedded) |srv|
        worktree.newWorktreeEmbedded(allocator, r.storer, fs, srv)
    else
        worktree.newWorktree(allocator, r.storer, fs);

    // go-git uses MergeReset after clone. Hard reset materialises every path into
    // an empty worktree/index (same end state for a fresh destination).
    const head = try storer.resolveReference(r.storer, plumbing.HEAD);
    try w.reset(.{ .mode = .hard, .commit = head.hash });
}

// ---------------------------------------------------------------------------
// Single-branch remote config rewrite (go-git `updateRemoteConfigIfNeeded`)
// ---------------------------------------------------------------------------

fn updateRemoteConfigIfNeeded(r: *Repository, o: *const CloneOptions) !void {
    if (!o.single_branch) return;

    const fetch_specs = try cloneRefSpec(r.storer.allocator, o);
    defer freeStringSlice(r.storer.allocator, fetch_specs);

    const cfg = try r.config();
    const rc = cfg.remotes.getPtr(o.remote_name) orelse return error.RemoteNotFound;
    // Rewrite fetch refspecs (putRemoteFull replaces the remote entry).
    var urls_buf: [8][]const u8 = undefined;
    if (rc.urls.len > urls_buf.len) return error.OutOfMemory;
    for (rc.urls, 0..) |u, i| urls_buf[i] = u;
    try cfg.putRemoteFull(o.remote_name, urls_buf[0..rc.urls.len], fetch_specs, rc.mirror);
    try r.setConfig(cfg);
}

// ---------------------------------------------------------------------------
// Unit tests (no transport)
// ---------------------------------------------------------------------------

test "CloneOptions validate requires URL" {
    var o: CloneOptions = .{};
    try std.testing.expectError(error.MissingURL, o.validate());
}

test "CloneOptions validate defaults" {
    var o: CloneOptions = .{ .url = "file://repo" };
    try o.validate();
    try std.testing.expectEqualStrings(remote_pkg.default_remote_name, o.remote_name);
    try std.testing.expectEqualStrings(plumbing.HEAD.raw, o.reference_name.raw);
    try std.testing.expect(o.tags == .all);
}

test "cloneRefSpec default and mirror" {
    const allocator = std.testing.allocator;
    var o: CloneOptions = .{ .url = "x", .remote_name = "origin" };
    try o.validate();

    const def = try cloneRefSpec(allocator, &o);
    defer freeStringSlice(allocator, def);
    try std.testing.expectEqual(@as(usize, 1), def.len);
    try std.testing.expectEqualStrings("+refs/heads/*:refs/remotes/origin/*", def[0]);

    o.mirror = true;
    const mir = try cloneRefSpec(allocator, &o);
    defer freeStringSlice(allocator, mir);
    try std.testing.expectEqualStrings(refspec_mirror, mir[0]);
}

test "cloneRefSpec single branch" {
    const allocator = std.testing.allocator;
    var o: CloneOptions = .{
        .url = "x",
        .remote_name = "origin",
        .single_branch = true,
        .reference_name = plumbing.master,
    };
    try o.validate();
    const specs = try cloneRefSpec(allocator, &o);
    defer freeStringSlice(allocator, specs);
    try std.testing.expectEqualStrings(
        "+refs/heads/master:refs/remotes/origin/master",
        specs[0],
    );
}
