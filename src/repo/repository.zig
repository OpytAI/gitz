//! Repository Init/Open core (go-git root `repository.go` subset).
//!
//! Memory-backed repository lifecycle:
//! - `init` / `initWithOptions` / `open` over `*memory.Storage`
//! - optional worktree FS field `wt`: `?*fs.Mem` (null = bare; go-git `r.wt`)
//! - head / config / setConfig / configScoped / reference helpers
//!
//! Storer config remains `memory.Config` (storage backends write that shape).
//! `configScoped` loads system/global via `//src/config` (`gitconfig.loadConfig`)
//! and merges remotes/branches/`is_bare` into a **heap copy** of the local
//! storer config (caller owns the returned pointer).
//!
//! Filesystem path lifecycle: `plain.zig` (`plainInit` / `plainOpen` over
//! `//src/storage/filesystem` + `fs.Mem`). Full Worktree: `Repository.worktree`.
//! Remote Fetch / List / Push use `//src/remote` through the methods below.

const std = @import("std");
const plumbing = @import("plumbing");
const storer = @import("storer");
const memory = @import("memory");
const fs_pkg = @import("fs");
const gitconfig = @import("gitconfig");
const format_config = @import("config");
const transport = @import("transport");

const error_mod = @import("error.zig");
const facade = @import("facade.zig");
const log_mod = @import("log.zig");
const crud = @import("crud.zig");
const remote_mod = @import("remote.zig");
const objpkg = @import("object");
const worktree_pkg = @import("worktree");
const server_pkg = @import("server");
const repack_mod = @import("repack.zig");
const prune_pkg = @import("prune");
const blame_pkg = @import("blame");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const Config = memory.Config;

pub const LogOptions = log_mod.LogOptions;
pub const LogOrder = log_mod.LogOrder;
pub const LogResult = log_mod.LogResult;
pub const CreateTagOptions = crud.CreateTagOptions;
pub const Remote = remote_mod.Remote;
pub const FetchOptions = remote_mod.FetchOptions;
pub const PushOptions = remote_mod.PushOptions;
pub const ListOptions = remote_mod.ListOptions;
pub const AnonymousRemote = crud.AnonymousRemote;
pub const RepackConfig = repack_mod.RepackConfig;
pub const PruneOptions = prune_pkg.PruneOptions;
pub const BlameResult = blame_pkg.BlameResult;

pub const Error = error_mod.Error;

/// go-git `GitDirName` — special folder where all the git stuff is.
pub const git_dir_name = ".git";

/// go-git `InitOptions`.
pub const InitOptions = struct {
    /// Default branch (e.g. `refs/heads/master`). Empty → `plumbing.master`.
    default_branch: ReferenceName = plumbing.master,
};

/// Git repository over a storage and worktree-filesystem backend.
///
/// Does **not** own `storer` or `wt`. Caller allocates and frees them. The
/// default `Repository` alias retains the memory-backed API.
pub fn RepositoryFor(comptime Storage: type, comptime Fs: type) type {
    return struct {
        const Self = @This();

        /// Repository object storage and refs (go-git `Storer`).
        storer: *Storage,
        /// Optional worktree filesystem; null means bare (go-git `Repository.wt`).
        /// Named `wt` so the method `worktree` can match go-git `Repository.Worktree`.
        wt: ?*Fs = null,

        // -----------------------------------------------------------------------
        // Config
        // -----------------------------------------------------------------------

        /// Activate this repository's object format for process-wide wire codecs.
        pub fn activateFormat(self: *const Self) void {
            self.storer.activateFormat();
        }

        /// go-git `Repository.Config` — return repository config from the storer.
        pub fn config(self: *Self) !*Config {
            return self.storer.config();
        }

        /// go-git `Repository.SetConfig` — write repository config via the storer.
        /// Takes ownership of `cfg` on success (memory.ConfigStorage contract).
        pub fn setConfig(self: *Self, cfg: *Config) !void {
            return self.storer.setConfig(cfg);
        }

        /// go-git `Repository.ConfigScoped` — local storer config merged with
        /// requested scope and lower (system ⊂ global ⊂ local).
        ///
        /// Returns a **heap copy** of the local config with missing remotes/branches
        /// filled from system then global, and `is_bare` filled from higher scopes
        /// only when local is still false (mergo zero-value rule). Caller owns the
        /// pointer (`deinit` + `destroy`). Do not pass the result to `setConfig`.
        ///
        /// `io` / `environ` feed `gitconfig.loadConfig` (Zig 0.16 host paths).
        pub fn configScoped(
            self: *Self,
            allocator: Allocator,
            scope: gitconfig.Scope,
            io: std.Io,
            environ: std.process.Environ,
        ) !*Config {
            return configScopedFromLocal(try self.config(), allocator, scope, io, environ);
        }

        // -----------------------------------------------------------------------
        // References
        // -----------------------------------------------------------------------

        /// go-git `Repository.Head` — resolve HEAD to a hash reference.
        pub fn head(self: *const Self) !Reference {
            return resolveBackendReference(self.storer, plumbing.HEAD);
        }

        /// go-git `Repository.Reference`.
        /// When `resolved` is true, symbolic refs are resolved to a hash ref.
        pub fn reference(self: *const Self, name: ReferenceName, resolved: bool) !Reference {
            if (resolved) return resolveBackendReference(self.storer, name);
            return self.storer.reference(name);
        }

        /// Release a reference returned by `head` or `reference`.
        pub fn freeReference(self: *const Self, ref: Reference) void {
            self.storer.freeReference(ref);
        }

        /// Abandon a caller-owned EncodedObject create that was never successfully set.
        pub fn discardEncodedObject(self: *Self, obj: *plumbing.MemoryObject) void {
            self.storer.discardEncodedObject(obj);
        }

        /// go-git `Repository.References` — unsorted iterator over all references.
        pub fn references(self: *const Self) !Storage.ReferenceIter {
            return self.storer.iterReferences();
        }

        // -----------------------------------------------------------------------
        // Worktree (go-git Repository.Worktree + bare probe)
        // -----------------------------------------------------------------------

        /// Whether this repository has a worktree filesystem attached.
        pub fn isBare(self: *const Self) bool {
            return self.wt == null;
        }

        /// go-git `setIsBare` — set `core.bare` in config.
        pub fn setIsBare(self: *Self, bare: bool) !void {
            const cfg = try self.config();
            cfg.is_bare = bare;
            try self.setConfig(cfg);
        }

        /// Attached worktree filesystem only, or `error.IsBareRepository`.
        /// Prefer `worktree` when you need the full `worktree.Worktree` handle.
        pub fn worktreeFs(self: *Self) error{IsBareRepository}!*Fs {
            return self.wt orelse error.IsBareRepository;
        }

        /// go-git `Repository.Worktree` — Worktree handle over the attached FS.
        ///
        /// Returns `error.IsBareRepository` when no worktree filesystem is attached.
        pub fn worktree(self: *Self) !worktree_pkg.WorktreeFor(Storage, Fs) {
            const fs: *Fs = self.wt orelse return error.IsBareRepository;
            return worktree_pkg.newWorktreeFor(Storage, Fs, self.storer.allocator, self.storer, fs);
        }

        /// Like `worktree` but binds an in-process server for Pull tests.
        pub fn worktreeEmbedded(self: *Self, srv: *server_pkg.Server) !worktree_pkg.WorktreeFor(Storage, Fs) {
            const fs: *Fs = self.wt orelse return error.IsBareRepository;
            var result = worktree_pkg.newWorktreeFor(Storage, Fs, self.storer.allocator, self.storer, fs);
            result.embedded = srv;
            return result;
        }

        // -----------------------------------------------------------------------
        // Remotes / config branches / tags
        // -----------------------------------------------------------------------

        pub fn remote(self: *Self, name: []const u8) !remote_mod.RemoteFor(Storage) {
            return crud.remote(self.storer, name);
        }
        pub fn remotes(self: *Self, allocator: Allocator) ![]remote_mod.RemoteFor(Storage) {
            return crud.remotes(self.storer, allocator);
        }
        pub fn createRemote(self: *Self, name: []const u8, urls: []const []const u8) !remote_mod.RemoteFor(Storage) {
            return crud.createRemote(self.storer, name, urls);
        }
        pub fn createRemoteFull(
            self: *Self,
            name: []const u8,
            urls: []const []const u8,
            fetch_specs: []const []const u8,
            mirror: bool,
        ) !remote_mod.RemoteFor(Storage) {
            return crud.createRemoteFull(self.storer, name, urls, fetch_specs, mirror);
        }
        pub fn createRemoteAnonymous(
            self: *Self,
            allocator: Allocator,
            urls: []const []const u8,
        ) !crud.AnonymousRemoteFor(Storage) {
            return crud.createRemoteAnonymous(self.storer, allocator, urls);
        }
        pub fn deleteRemote(self: *Self, name: []const u8) !void {
            return crud.deleteRemote(self.storer, name);
        }

        /// go-git `Repository.Fetch` — resolve remote by `o.remote_name`, then fetch.
        pub fn fetch(self: *Self, o: *FetchOptions) !void {
            try o.validate();
            var rem = try self.remote(o.remote_name);
            return rem.fetch(o);
        }
        /// go-git `Repository.FetchContext` via cooperative transport context.
        pub fn fetchContext(
            self: *Self,
            context: transport.OperationContext,
            o: *const FetchOptions,
        ) !void {
            var opts = o.*;
            opts.transport.operation_context = context;
            return self.fetch(&opts);
        }

        /// go-git `Repository.Push` — resolve remote by `o.remote_name`, then push.
        pub fn push(self: *Self, o: *PushOptions) !void {
            try o.validate();
            var rem = try self.remote(o.remote_name);
            return rem.push(o);
        }
        /// go-git `Repository.PushContext` via cooperative transport context.
        pub fn pushContext(
            self: *Self,
            context: transport.OperationContext,
            o: *const PushOptions,
        ) !void {
            var opts = o.*;
            opts.transport.operation_context = context;
            return self.push(&opts);
        }
        pub fn branch(self: *Self, name: []const u8) !*const memory.BranchConfig {
            return crud.branch(self.storer, name);
        }
        pub fn createBranch(
            self: *Self,
            name: []const u8,
            remote_name: []const u8,
            merge_ref: []const u8,
        ) !void {
            return crud.createBranch(self.storer, name, remote_name, merge_ref);
        }
        pub fn deleteBranch(self: *Self, name: []const u8) !void {
            return crud.deleteBranch(self.storer, name);
        }
        pub fn tag(self: *Self, name: []const u8) !Reference {
            return crud.tag(self.storer, name);
        }
        pub fn createTag(
            self: *Self,
            name: []const u8,
            hash: plumbing.Hash,
            opts: ?CreateTagOptions,
        ) !Reference {
            return crud.createTag(self.storer, name, hash, opts);
        }
        pub fn deleteTag(self: *Self, name: []const u8) !void {
            return crud.deleteTag(self.storer, name);
        }

        // -----------------------------------------------------------------------
        // Object getters, Log, ResolveRevision, ref filters
        // -----------------------------------------------------------------------

        pub fn commitObject(self: *Self, h: plumbing.Hash) !*objpkg.Commit {
            return facade.commitObject(self.storer, h);
        }
        pub fn blobObject(self: *Self, h: plumbing.Hash) !objpkg.Blob {
            return facade.blobObject(self.storer, h);
        }
        pub fn treeObject(self: *Self, h: plumbing.Hash) !*objpkg.Tree {
            return facade.treeObject(self.storer, h);
        }
        pub fn tagObject(self: *Self, h: plumbing.Hash) !objpkg.Tag {
            return facade.tagObject(self.storer, h);
        }
        pub fn object(self: *Self, t: plumbing.ObjectType, h: plumbing.Hash) !objpkg.Object {
            return facade.object(self.storer, t, h);
        }
        pub fn commitObjects(self: *Self) !facade.EncodedCommitIterFor(Storage) {
            return facade.commitObjects(self.storer);
        }
        pub fn blobObjects(self: *Self) !facade.BlobObjectsIterFor(Storage) {
            return facade.blobObjects(self.storer);
        }
        pub fn treeObjects(self: *Self) !objpkg.TreeIter {
            return facade.treeObjects(self.storer);
        }
        pub fn tagObjects(self: *Self) !facade.TagObjectsIterFor(Storage) {
            return facade.tagObjects(self.storer);
        }
        pub fn objects(self: *Self) !facade.ObjectsIterFor(Storage) {
            return facade.objects(self.storer);
        }
        pub fn branches(self: *Self) !facade.FilteredRefIterFor(Storage.ReferenceIter) {
            return facade.branches(self.storer);
        }
        pub fn tags(self: *Self) !facade.FilteredRefIterFor(Storage.ReferenceIter) {
            return facade.tags(self.storer);
        }
        pub fn notes(self: *Self) !facade.FilteredRefIterFor(Storage.ReferenceIter) {
            return facade.notes(self.storer);
        }
        pub fn log(self: *Self, opts: LogOptions) !LogResult {
            return log_mod.log(self.storer, opts);
        }
        pub fn resolveRevision(self: *Self, rev: []const u8) !plumbing.Hash {
            return facade.resolveRevision(self.storer, rev);
        }

        /// go-git `Self.Grep`. Searches commit trees and works for bare repos.
        pub fn grep(
            self: *Self,
            allocator: Allocator,
            opts: worktree_pkg.GrepOptions,
        ) ![]worktree_pkg.GrepResult {
            return worktree_pkg.grepRepository(allocator, self.storer, opts);
        }

        /// Self method form of blame for callers that have a commit hash.
        pub fn blame(
            self: *Self,
            allocator: Allocator,
            commit_hash: Hash,
            path: []const u8,
        ) !BlameResult {
            const c = try objpkg.getCommit(allocator, self.storer, commit_hash);
            defer {
                c.deinit();
                allocator.destroy(c);
            }
            return blame_pkg.blame(allocator, c, path);
        }

        /// go-git `Self.DeleteObject` method form.
        pub fn deleteObject(self: *Self, hash: Hash) !void {
            return prune_pkg.deleteObject(self.storer, hash);
        }

        /// go-git `Self.Prune` method form.
        pub fn prune(self: *Self, allocator: Allocator, opts: PruneOptions) !void {
            return prune_pkg.prune(allocator, self.storer, opts);
        }

        // -----------------------------------------------------------------------
        // Repack
        // -----------------------------------------------------------------------

        /// go-git `Self.RepackObjects` over memory storage.
        ///
        /// Memory implements PackedObjectStorer (empty packs) but not PackfileWriter,
        /// so this always returns `error.PackfileWriterNotSupported`. Use
        /// `PlainRepository.repackObjects` / `repackObjectsFs` for filesystem backends.
        pub fn repackObjects(self: *Self, allocator: Allocator, cfg: *const RepackConfig) !void {
            return repack_mod.repackObjects(allocator, self.storer, cfg);
        }

        // -----------------------------------------------------------------------
        // Merge (go-git Self.Merge — FastForwardOnly)
        // -----------------------------------------------------------------------

        /// go-git `Self.Merge`. Only `fast_forward_merge` is supported.
        ///
        /// When `ref` is a fast-forward of HEAD, updates the current branch tip
        /// (or detached HEAD) to `ref.hash`.
        pub fn merge(
            self: *Self,
            allocator: Allocator,
            ref: plumbing.Reference,
            opts: MergeOptions,
        ) !void {
            if (opts.strategy != .fast_forward_merge) {
                return error.UnsupportedMergeStrategy;
            }

            const head_tip = try resolveBackendReference(self.storer, plumbing.HEAD);
            defer self.storer.freeReference(head_tip);
            const shallow_list = self.storer.shallow();
            const earliest: ?Hash = if (shallow_list.len > 0) shallow_list[0] else null;

            // isFastForward(old=head, new=ref) ⇒ ref is descendant of head.
            const ff = try remote_mod.isFastForward(
                allocator,
                self.storer,
                head_tip.hash,
                ref.hash,
                earliest,
            );
            if (!ff) return error.FastForwardMergeNotPossible;

            // Update current branch tip (symbolic HEAD → branch name) or detached HEAD.
            var tip_name = plumbing.HEAD;
            const head_sym = try self.storer.reference(plumbing.HEAD);
            defer self.storer.freeReference(head_sym);
            if (head_sym.type == .symbolic) {
                tip_name = head_sym.target;
            }
            try self.storer.setReference(plumbing.Reference.newHashReference(tip_name, ref.hash));
        }
    };
}

pub const Repository = RepositoryFor(memory.Storage, fs_pkg.Mem);

/// Resolve references while releasing owned symbolic hops for filesystem
/// backends. The caller releases the returned reference with `freeReference`.
fn resolveBackendReference(storage: anytype, name: ReferenceName) !Reference {
    var current = try storage.reference(name);
    var recursion: usize = 0;
    while (current.type == .symbolic) {
        if (recursion > storer.MaxResolveRecursion) {
            storage.freeReference(current);
            return error.MaxResolveRecursion;
        }
        const next = storage.reference(current.target) catch |err| {
            storage.freeReference(current);
            return err;
        };
        storage.freeReference(current);
        current = next;
        recursion += 1;
    }
    return current;
}

/// go-git `MergeStrategy`.
pub const MergeStrategy = enum(i8) {
    /// go-git `FastForwardMerge`.
    fast_forward_merge = 0,
    _,
};

/// go-git `MergeOptions`.
pub const MergeOptions = struct {
    strategy: MergeStrategy = .fast_forward_merge,
};

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/// go-git `newRepository`.
pub fn newRepository(s: *memory.Storage, worktree: ?*fs_pkg.Mem) Repository {
    return newRepositoryFor(memory.Storage, fs_pkg.Mem, s, worktree);
}

/// Construct a repository over any compatible storage and filesystem pair.
pub fn newRepositoryFor(
    comptime Storage: type,
    comptime Fs: type,
    s: *Storage,
    worktree: ?*Fs,
) RepositoryFor(Storage, Fs) {
    return .{ .storer = s, .wt = worktree };
}

/// go-git `Init` — create an empty repository. `worktree == null` → bare.
/// If the storer already has HEAD, returns `error.RepositoryAlreadyExists`.
pub fn init(s: *memory.Storage, worktree: ?*fs_pkg.Mem) !Repository {
    return initWithOptions(s, worktree, .{});
}

/// go-git `InitWithOptions`.
///
/// go-git calls storer `Initializer` when present; `memory.Storage` has none
/// (type assert fails → no-op). Filesystem layout init is `plainInit` /
/// `Storage.initLayout`.
pub fn initWithOptions(s: *memory.Storage, worktree: ?*fs_pkg.Mem, options: InitOptions) !Repository {
    var opts = options;
    if (opts.default_branch.raw.len == 0) {
        opts.default_branch = plumbing.master;
    }
    try opts.default_branch.validate();

    // Activate per-repo format for wire codecs (object hashing uses MemoryObject.hash_algo).
    s.activateFormat();

    var r = newRepository(s, worktree);

    if (r.reference(plumbing.HEAD, false)) |_| {
        return error.RepositoryAlreadyExists;
    } else |err| switch (err) {
        error.ReferenceNotFound => {},
        else => |e| return e,
    }

    const head_ref = Reference.newSymbolicReference(plumbing.HEAD, opts.default_branch);
    try s.setReference(head_ref);

    if (worktree == null) {
        // go-git ignores setIsBare error with `_ =`; we propagate for correctness.
        try r.setIsBare(true);
        return r;
    }

    // setWorktreeAndStoragePaths: only for filesystem-based storers that expose
    // Filesystem(); memory storer → no-op (go-git type assert fails).
    return r;
}

/// go-git `Open` — open an existing repository.
///
/// Empty storer (no HEAD) → `error.RepositoryNotExists`.
/// `worktree` may be null for bare and non-bare repos (go-git currently does
/// not enforce `ErrWorktreeNotProvided` despite the comment).
pub fn open(s: *memory.Storage, worktree: ?*fs_pkg.Mem) !Repository {
    _ = s.reference(plumbing.HEAD) catch |err| switch (err) {
        error.ReferenceNotFound => return error.RepositoryNotExists,
        else => |e| return e,
    };

    // Load config and enforce every extension represented by memory.Config.
    const cfg = try s.config();
    try verifyExtensions(cfg);
    // Apply objectformat from config onto this storage (per-repo).
    if (cfg.object_format.len > 0) {
        if (std.mem.eql(u8, cfg.object_format, "sha256")) {
            s.setHashAlgo(.sha256);
        } else {
            s.setHashAlgo(.sha1);
        }
    } else {
        s.activateFormat();
    }

    return newRepository(s, worktree);
}

/// go-git `verifyExtensions` for the repository fields modeled by
/// `memory.Config`. Unknown raw extension keys are not retained by this storer,
/// but repository format and objectformat are enforced here.
pub fn verifyExtensions(cfg: *const Config) Error!void {
    const version = cfg.repository_format_version;
    if (version.len > 0 and
        !std.mem.eql(u8, version, format_config.Version0) and
        !std.mem.eql(u8, version, format_config.Version1))
    {
        return error.UnsupportedRepositoryFormatVersion;
    }

    if (cfg.object_format.len == 0) return;
    if (!std.mem.eql(u8, version, format_config.Version1)) {
        return error.UnsupportedExtensionRepositoryFormatVersion;
    }
    if (!std.mem.eql(u8, cfg.object_format, format_config.SHA1) and
        !std.mem.eql(u8, cfg.object_format, format_config.SHA256))
    {
        return error.UnknownExtension;
    }
}

// ---------------------------------------------------------------------------
// ConfigScoped helpers (go-git mergo subset for memory.Config)
// ---------------------------------------------------------------------------

/// Clone local, load system/global via `gitconfig.loadConfig`, merge into the
/// clone. Caller owns the returned `*memory.Config`.
pub fn configScopedFromLocal(
    local: *const Config,
    allocator: Allocator,
    scope: gitconfig.Scope,
    io: std.Io,
    environ: std.process.Environ,
) !*Config {
    const merged = try cloneMemoryConfig(allocator, local);
    errdefer {
        merged.deinit();
        allocator.destroy(merged);
    }

    // go-git: LoadConfig(system) then LoadConfig(global); mergo.Merge(global, system)
    // then mergo.Merge(local, global). Fill-missing into a local clone with priority
    // local > global > system: apply global first, then system (only gaps remain).
    // Scope order: local=0, global=1, system=2.
    if (@intFromEnum(scope) >= @intFromEnum(gitconfig.Scope.global)) {
        var global = try gitconfig.loadConfig(allocator, .global, io, environ);
        defer global.deinit();
        try mergeGitconfigIntoMemory(merged, &global);
    }
    if (@intFromEnum(scope) >= @intFromEnum(gitconfig.Scope.system)) {
        var system = try gitconfig.loadConfig(allocator, .system, io, environ);
        defer system.deinit();
        try mergeGitconfigIntoMemory(merged, &system);
    }

    return merged;
}

/// Deep-copy `src` into a heap `*Config` owned by the caller.
pub fn cloneMemoryConfig(allocator: Allocator, src: *const Config) Allocator.Error!*Config {
    const c = try allocator.create(Config);
    errdefer allocator.destroy(c);
    c.* = Config.init(allocator);
    errdefer c.deinit();

    c.is_bare = src.is_bare;

    var rit = src.remotes.iterator();
    while (rit.next()) |e| {
        const rc = e.value_ptr.*;
        const urls = try slicesAsConst(allocator, rc.urls);
        defer if (urls.len > 0) allocator.free(urls);
        const fetch = try slicesAsConst(allocator, rc.fetch);
        defer if (fetch.len > 0) allocator.free(fetch);
        try c.putRemoteFull(rc.name, urls, fetch, rc.mirror);
    }

    var bit = src.branches.iterator();
    while (bit.next()) |e| {
        const bc = e.value_ptr.*;
        try c.putBranch(bc.name, bc.remote, bc.merge);
    }

    return c;
}

/// Merge gitconfig remotes/branches/`is_bare` into `dst` (dst wins on key collision).
/// Matches go-git `mergo.Merge(dst, src)` for the fields we carry on `memory.Config`.
pub fn mergeGitconfigIntoMemory(dst: *Config, src: *const gitconfig.Config) Allocator.Error!void {
    var rit = src.remotes.iterator();
    while (rit.next()) |e| {
        const name = e.key_ptr.*;
        if (dst.remotes.contains(name)) continue;
        const rc = e.value_ptr.*;
        const fetch = try refspecsAsStrings(dst.allocator, rc.fetch);
        defer if (fetch.len > 0) dst.allocator.free(fetch);
        try dst.putRemoteFull(name, rc.urls, fetch, rc.mirror);
    }

    var bit = src.branches.iterator();
    while (bit.next()) |e| {
        const name = e.key_ptr.*;
        if (dst.branches.contains(name)) continue;
        const b = e.value_ptr.*;
        try dst.putBranch(name, b.remote, b.merge.raw);
    }

    // Go bool zero is false: fill dst.is_bare from src only when still false.
    if (!dst.is_bare) dst.is_bare = src.core.is_bare;
}

fn slicesAsConst(allocator: Allocator, items: []const []u8) Allocator.Error![]const []const u8 {
    if (items.len == 0) return &.{};
    const out = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |s, i| out[i] = s;
    return out;
}

fn refspecsAsStrings(allocator: Allocator, specs: []const gitconfig.RefSpec) Allocator.Error![]const []const u8 {
    if (specs.len == 0) return &.{};
    const out = try allocator.alloc([]const u8, specs.len);
    for (specs, 0..) |rs, i| out[i] = rs.raw;
    return out;
}

// ---------------------------------------------------------------------------
// Tests (go-git repository_test.go Init/Open subset — memory.Storage)
// ---------------------------------------------------------------------------

test "Init bare sets is_bare" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    var r = try init(s, null);
    try std.testing.expect(r.isBare());

    const cfg = try r.config();
    try std.testing.expect(cfg.is_bare);

    // HEAD is symbolic → master
    const head_sym = try r.reference(plumbing.HEAD, false);
    try std.testing.expect(head_sym.type == .symbolic);
    try std.testing.expectEqualStrings(plumbing.master.raw, head_sym.target.raw);
}

test "Init with worktree Mem is not bare" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    var wt = try fs_pkg.Mem.init(allocator);
    defer wt.deinit();

    var r = try init(s, &wt);
    try std.testing.expect(!r.isBare());
    try std.testing.expect(r.wt != null);

    const cfg = try r.config();
    try std.testing.expect(!cfg.is_bare);
}

test "InitWithOptions custom default branch" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    var wt = try fs_pkg.Mem.init(allocator);
    defer wt.deinit();

    const r = try initWithOptions(s, &wt, .{
        .default_branch = ReferenceName.init("refs/heads/foo"),
    });
    const head_sym = try r.reference(plumbing.HEAD, false);
    try std.testing.expectEqualStrings("refs/heads/foo", head_sym.target.raw);
}

test "InitWithOptions invalid default branch" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    try std.testing.expectError(
        error.InvalidReferenceName,
        initWithOptions(s, null, .{
            .default_branch = ReferenceName.init("foo"),
        }),
    );
}

test "Init already exists" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const r1 = try init(s, null);
    try std.testing.expect(r1.storer == s);

    try std.testing.expectError(error.RepositoryAlreadyExists, init(s, null));
}

test "Open after Init" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    var wt = try fs_pkg.Mem.init(allocator);
    defer wt.deinit();

    _ = try init(s, &wt);

    var wt2 = try fs_pkg.Mem.init(allocator);
    defer wt2.deinit();

    const r = try open(s, &wt2);
    try std.testing.expect(r.storer == s);
    try std.testing.expect(r.wt == &wt2);
}

test "Open bare" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    _ = try init(s, null);
    const r = try open(s, null);
    try std.testing.expect(r.isBare());
}

test "Open not exists" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    try std.testing.expectError(error.RepositoryNotExists, open(s, null));
}

test "Open non-bare with nil worktree still succeeds" {
    // go-git TestOpenBareMissingWorktree: Open does not enforce worktree.
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    var wt = try fs_pkg.Mem.init(allocator);
    defer wt.deinit();

    _ = try init(s, &wt);
    const r = try open(s, null);
    try std.testing.expect(r.isBare()); // worktree pointer is null on this handle
}

test "setConfig and config round-trip via repository" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    var r = try init(s, null);
    const cfg = try r.config();
    try cfg.putRemote("origin", &[_][]const u8{"http://example.com/r.git"});
    try r.setConfig(cfg);

    const got = try r.config();
    try std.testing.expect(got.is_bare);
    const remote = got.remotes.get("origin") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("origin", remote.name);
}

test "reference unresolved HEAD after Init" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const r = try init(s, null);
    // Resolved HEAD fails: master has no hash yet.
    try std.testing.expectError(error.ReferenceNotFound, r.head());

    // Unresolved HEAD is the symbolic ref.
    const sym = try r.reference(plumbing.HEAD, false);
    try std.testing.expect(sym.type == .symbolic);
}

test "head resolves after branch hash is set" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const r = try init(s, null);
    const h = plumbing.newHash("c3f4688a08fd86f1bf8e055724c84b7a40a09733");
    try s.setReference(Reference.newHashReference(plumbing.master, h));

    const head_ref = try r.head();
    try std.testing.expect(head_ref.type == .hash);
    try std.testing.expect(head_ref.hash.eql(h));
    try std.testing.expectEqualStrings(plumbing.master.raw, head_ref.name.raw);
}

test "references iter includes HEAD" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const r = try init(s, null);
    var iter = try r.references();
    defer iter.deinit();

    var found_head = false;
    while (true) {
        const ref = iter.next() catch |err| switch (err) {
            error.EndOfStream => break,
        };
        if (std.mem.eql(u8, ref.name.raw, plumbing.HEAD.raw)) found_head = true;
    }
    try std.testing.expect(found_head);
}

test "facade commitObject and resolveRevision after Init" {
    // Integration: Init lifecycle + facade methods on the same Repository.
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    var r = try init(s, null);

    // Empty blob + empty tree + commit.
    const blob_obj = try s.newEncodedObject();
    blob_obj.setType(.blob);
    _ = try blob_obj.write("");
    const blob_h = try s.setEncodedObject(blob_obj);

    const tree_obj = try s.newEncodedObject();
    tree_obj.setType(.tree);
    _ = try tree_obj.write("");
    const tree_h = try s.setEncodedObject(tree_obj);

    var commit_body: std.ArrayList(u8) = .empty;
    defer commit_body.deinit(allocator);
    var tree_hex: [plumbing.MaxHexSize]u8 = undefined;
    try commit_body.appendSlice(allocator, "tree ");
    try commit_body.appendSlice(allocator, tree_h.string(&tree_hex));
    try commit_body.appendSlice(allocator, "\nauthor A <a@b> 1 +0000\ncommitter A <a@b> 1 +0000\n\nmsg\n");
    const commit_obj = try s.newEncodedObject();
    commit_obj.setType(.commit);
    _ = try commit_obj.write(commit_body.items);
    const commit_h = try s.setEncodedObject(commit_obj);

    try s.setReference(Reference.newHashReference(plumbing.master, commit_h));

    const c = try r.commitObject(commit_h);
    defer {
        c.deinit();
        allocator.destroy(c);
    }
    try std.testing.expect(c.hash.eql(commit_h));

    const blob = try r.blobObject(blob_h);
    try std.testing.expect(blob.hash.eql(blob_h));

    const resolved = try r.resolveRevision("HEAD");
    try std.testing.expect(resolved.eql(commit_h));
}

test "configScoped LocalScope returns heap copy of local" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    var r = try init(s, null);
    const cfg = try r.config();
    try cfg.putRemote("origin", &[_][]const u8{"http://example.com/r.git"});
    try r.setConfig(cfg);

    const scoped = try r.configScoped(allocator, .local, std.testing.io, std.testing.environ);
    defer {
        scoped.deinit();
        allocator.destroy(scoped);
    }
    try std.testing.expect(scoped != try r.config());
    const remote = scoped.remotes.get("origin") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("http://example.com/r.git", remote.urls[0]);
}

test "mergeGitconfigIntoMemory fills missing remotes branches is_bare" {
    const allocator = std.testing.allocator;
    var local = Config.init(allocator);
    defer local.deinit();
    try local.putRemote("origin", &[_][]const u8{"http://local/r.git"});

    var gc = try gitconfig.readConfig(
        allocator,
        "[core]\n" ++
            "\tbare = true\n" ++
            "[remote \"origin\"]\n" ++
            "\turl = http://global-should-not-win/r.git\n" ++
            "[remote \"upstream\"]\n" ++
            "\turl = http://upstream/r.git\n" ++
            "[branch \"main\"]\n" ++
            "\tremote = origin\n" ++
            "\tmerge = refs/heads/main\n",
    );
    defer gc.deinit();

    try mergeGitconfigIntoMemory(&local, &gc);

    // Local origin wins
    const origin = local.remotes.get("origin") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("http://local/r.git", origin.urls[0]);

    // Missing remote filled
    const up = local.remotes.get("upstream") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("http://upstream/r.git", up.urls[0]);

    // Branch filled
    const br = local.branches.get("main") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("origin", br.remote);
    try std.testing.expectEqualStrings("refs/heads/main", br.merge);

    // is_bare filled from higher scope when local was false
    try std.testing.expect(local.is_bare);
}

test "configScoped GlobalScope with empty env still returns local" {
    // No HOME / XDG files → empty global; result equals local clone.
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    var r = try init(s, null);
    const scoped = try r.configScoped(allocator, .global, std.testing.io, std.process.Environ.empty);
    defer {
        scoped.deinit();
        allocator.destroy(scoped);
    }
    try std.testing.expect(scoped.is_bare);
    try std.testing.expectEqual(@as(usize, 0), scoped.remotes.count());
}

fn storeMergeTestCommit(
    allocator: Allocator,
    s: *memory.Storage,
    tree: Hash,
    parents: []const Hash,
    message: []const u8,
) !Hash {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var hex: [plumbing.MaxHexSize]u8 = undefined;
    try body.appendSlice(allocator, "tree ");
    try body.appendSlice(allocator, tree.string(&hex));
    try body.append(allocator, '\n');
    for (parents) |parent| {
        try body.appendSlice(allocator, "parent ");
        try body.appendSlice(allocator, parent.string(&hex));
        try body.append(allocator, '\n');
    }
    try body.appendSlice(
        allocator,
        "author A <a@example.com> 1 +0000\ncommitter A <a@example.com> 1 +0000\n\n",
    );
    try body.appendSlice(allocator, message);
    const obj = try s.newEncodedObject();
    obj.setType(.commit);
    _ = try obj.write(body.items);
    return s.setEncodedObject(obj);
}

test "Repository.merge fast-forwards symbolic HEAD and rejects non-fast-forward" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }
    var r = try init(s, null);

    const tree_obj = try s.newEncodedObject();
    tree_obj.setType(.tree);
    _ = try tree_obj.write("");
    const tree = try s.setEncodedObject(tree_obj);
    const base = try storeMergeTestCommit(allocator, s, tree, &.{}, "base\n");
    const descendant = try storeMergeTestCommit(allocator, s, tree, &.{base}, "next\n");
    const sibling = try storeMergeTestCommit(allocator, s, tree, &.{}, "sibling\n");
    try s.setReference(Reference.newHashReference(plumbing.master, base));

    try r.merge(
        allocator,
        Reference.newHashReference(ReferenceName.init("refs/heads/topic"), descendant),
        .{},
    );
    const advanced = try r.head();
    try std.testing.expect(advanced.hash.eql(descendant));
    try std.testing.expectEqualStrings(plumbing.master.raw, advanced.name.raw);

    try std.testing.expectError(
        error.FastForwardMergeNotPossible,
        r.merge(
            allocator,
            Reference.newHashReference(ReferenceName.init("refs/heads/other"), sibling),
            .{},
        ),
    );
    const unchanged = try r.head();
    try std.testing.expect(unchanged.hash.eql(descendant));
}

test "Repository.merge rejects unsupported strategy without changing HEAD" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }
    var r = try init(s, null);
    const h = plumbing.newHash("1111111111111111111111111111111111111111");
    try s.setReference(Reference.newHashReference(plumbing.master, h));
    try std.testing.expectError(
        error.UnsupportedMergeStrategy,
        r.merge(
            allocator,
            Reference.newHashReference(ReferenceName.init("refs/heads/topic"), h),
            .{ .strategy = @enumFromInt(1) },
        ),
    );
    const head = try r.head();
    try std.testing.expect(head.hash.eql(h));
}

test "open verifies repository format and modeled objectformat extension" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }
    _ = try init(s, null);
    const cfg = try s.config();

    try cfg.setRepositoryFormatVersion("2");
    try std.testing.expectError(error.UnsupportedRepositoryFormatVersion, open(s, null));

    try cfg.setRepositoryFormatVersion(format_config.Version0);
    try cfg.setObjectFormat(format_config.SHA256);
    try std.testing.expectError(
        error.UnsupportedExtensionRepositoryFormatVersion,
        open(s, null),
    );

    try cfg.setRepositoryFormatVersion(format_config.Version1);
    try cfg.setObjectFormat("unknown-hash");
    try std.testing.expectError(error.UnknownExtension, open(s, null));

    try cfg.setObjectFormat(format_config.SHA256);
    const opened = try open(s, null);
    try std.testing.expect(opened.storer.hash_algo == .sha256);
}

test "Repository.grep searches commit tree without worktree" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }
    var r = try init(s, null);

    const blob_obj = try s.newEncodedObject();
    blob_obj.setType(.blob);
    _ = try blob_obj.write("first\nneedle here\nlast\n");
    const blob = try s.setEncodedObject(blob_obj);

    var tree_body: std.ArrayList(u8) = .empty;
    defer tree_body.deinit(allocator);
    try tree_body.appendSlice(allocator, "100644 file.txt");
    try tree_body.append(allocator, 0);
    try tree_body.appendSlice(allocator, blob.slice());
    const tree_obj = try s.newEncodedObject();
    tree_obj.setType(.tree);
    _ = try tree_obj.write(tree_body.items);
    const tree = try s.setEncodedObject(tree_obj);
    const commit_hash = try storeMergeTestCommit(allocator, s, tree, &.{}, "grep\n");

    const results = try r.grep(allocator, .{
        .commit_hash = commit_hash,
        .patterns = &.{"needle"},
    });
    defer worktree_pkg.freeGrepResults(allocator, results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("file.txt", results[0].file_name);
    try std.testing.expectEqual(@as(usize, 2), results[0].line_number);
    try std.testing.expectEqualStrings("needle here", results[0].content);
}

test "ResetOptions.validate defaults HEAD and rejects non-commit hash" {
    const allocator = std.testing.allocator;
    const s = try memory.newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }
    var r = try init(s, null);

    const tree_obj = try s.newEncodedObject();
    tree_obj.setType(.tree);
    _ = try tree_obj.write("");
    const tree = try s.setEncodedObject(tree_obj);
    const commit_hash = try storeMergeTestCommit(allocator, s, tree, &.{}, "head\n");
    try s.setReference(Reference.newHashReference(plumbing.master, commit_hash));

    var defaults: worktree_pkg.ResetOptions = .{};
    try defaults.validate(&r);
    try std.testing.expect(defaults.commit.eql(commit_hash));

    const blob_obj = try s.newEncodedObject();
    blob_obj.setType(.blob);
    _ = try blob_obj.write("not a commit");
    const blob_hash = try s.setEncodedObject(blob_obj);
    var invalid: worktree_pkg.ResetOptions = .{ .commit = blob_hash };
    try std.testing.expectError(error.ObjectNotFound, invalid.validate(&r));
}
