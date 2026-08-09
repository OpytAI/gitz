//! Submodule core (go-git `submodule.go`).
//!
//! Core surface: Init, Status, Config, Submodules list, Update (fetch + checkout).

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const memory = @import("memory");
const fs_pkg = @import("fs");
const gitconfig = @import("gitconfig");
const storer = @import("storer");
const index_format = @import("index");
const worktree = @import("worktree");
const remote = @import("remote");
const object = @import("object");
const server = @import("server");
const transport = @import("transport");
const repo_pkg = @import("repo");
const pathutil = @import("pathutil");

const options_mod = @import("options.zig");
const status_mod = @import("status.zig");
const host_mod = @import("host.zig");
const relative_url_mod = @import("relative_url.zig");
const owned = @import("owned.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const SubmoduleConfig = gitconfig.Submodule;
const Modules = gitconfig.Modules;
const Host = host_mod.Host;
const SubmoduleStatus = status_mod.SubmoduleStatus;
const SubmodulesStatus = status_mod.SubmodulesStatus;
const SubmoduleUpdateOptions = options_mod.SubmoduleUpdateOptions;
const RemoteError = remote.Error;

// Relative URL helpers (go-git Repository relative path).
pub const isRelativeSubmoduleURL = relative_url_mod.isRelativeSubmoduleURL;
pub const resolveSubmoduleURL = relative_url_mod.resolveSubmoduleURL;
pub const resolveRelativeURL = relative_url_mod.resolveRelativeURL;
pub const defaultRemote = relative_url_mod.defaultRemote;
pub const default_remote_name = relative_url_mod.default_remote_name;

/// go-git `.gitmodules` path constant.
pub const gitmodules_file = ".gitmodules";

/// go-git `Submodule` — another Git repository recorded in a subdirectory.
///
/// Does **not** own `host`. Owns `c` (typed submodule config copy).
pub const Submodule = struct {
    host: *Host,
    /// Whether Init has recorded this submodule (go-git `initialized`).
    initialized: bool = false,
    /// Submodule config (go-git `c`). Owned by this Submodule.
    c: *SubmoduleConfig,

    /// go-git `Submodule.Config`.
    pub fn config(self: *const Submodule) *SubmoduleConfig {
        return self.c;
    }

    /// Free owned config. Does not free Host.
    pub fn deinit(self: *Submodule) void {
        self.c.deinit();
        self.host.allocator.destroy(self.c);
        self.* = undefined;
    }

    /// go-git `Submodule.Init` — record the submodule in the host registry.
    pub fn init(self: *Submodule) !void {
        try pathutil.validTreePath(self.c.path);
        try self.host.putInitialized(self.c);
        self.initialized = true;
    }

    /// go-git `Submodule.Status`.
    pub fn status(self: *Submodule) !SubmoduleStatus {
        const idx = try self.host.storer.index();
        return try self.statusWithIndex(idx);
    }

    /// go-git `Submodule.Repository` with explicit ownership for the chrooted
    /// worktree filesystem. Caller must call `OwnedRepository.deinit`.
    pub fn repository(self: *Submodule) !OwnedRepository {
        if (!self.initialized) return error.SubmoduleNotInitialized;
        try pathutil.validTreePath(self.c.path);

        const allocator = self.host.allocator;
        const mod = try self.host.storer.module(self.c.name);
        const view = try allocator.create(fs_pkg.Mem);
        errdefer allocator.destroy(view);
        view.* = try self.host.filesystem.chroot(self.c.path);
        errdefer view.deinit();

        const exists = blk: {
            _ = mod.reference(plumbing.HEAD) catch |err| switch (err) {
                error.ReferenceNotFound => break :blk false,
                else => |e| return e,
            };
            break :blk true;
        };

        var repository_handle = if (exists)
            try repo_pkg.open(mod, view)
        else
            try repo_pkg.init(mod, view);

        if (!exists) {
            const default_opts = SubmoduleUpdateOptions{};
            const resolved = try resolveFetchURL(self, &default_opts);
            defer allocator.free(resolved);
            const cfg = try repository_handle.config();
            try cfg.putRemoteFull(
                default_remote_name,
                &[_][]const u8{resolved},
                &[_][]const u8{"+refs/heads/*:refs/remotes/origin/*"},
                false,
            );
            try repository_handle.setConfig(cfg);
        }

        return .{
            .allocator = allocator,
            .worktree_fs = view,
            .repo = repository_handle,
        };
    }

    /// Status using a pre-loaded index (go-git unexported `status`).
    pub fn statusWithIndex(self: *Submodule, idx: *index_format.Index) !SubmoduleStatus {
        var st: SubmoduleStatus = .{
            .path = self.c.path,
        };

        const e = idx.entry(self.c.path) catch |err| switch (err) {
            error.EntryNotFound => null,
            else => return err,
        };
        if (e) |entry| {
            st.expected = entry.hash;
        }

        if (!self.initialized) return st;

        // Current = module repo HEAD when present (go-git Submodule.Repository + Head).
        const mod = try self.host.storer.module(self.c.name);
        const head = storer.resolveReference(mod, plumbing.HEAD) catch |err| switch (err) {
            error.ReferenceNotFound => return st,
            else => return err,
        };
        st.current = head.hash;
        return st;
    }

    /// go-git `Submodule.Update` / `fetchAndCheckout`.
    ///
    /// Flow (matches go-git `update` + `fetchAndCheckout`):
    /// 1. Require Init (or `o.init`).
    /// 2. Resolve target hash: `force_hash` or superproject index gitlink.
    /// 3. Optionally fetch into module storage (`//src/remote`; `o.embedded`
    ///    for hermetic MapLoader tests).
    /// 4. Materialize the commit tree at `c.path` on the host FS, then detach
    ///    HEAD at the gitlink (go-git Checkout + `NewHashReference(HEAD)`).
    /// 5. Recurse when `o.recurse_submodules > 0`.
    ///
    /// Ownership: does not free `o` or strings it borrows (`remote_url`, auth).
    /// Module storage and host FS outlive this call (owned by Host / caller).
    pub fn update(self: *Submodule, o: *const SubmoduleUpdateOptions) !void {
        return self.updateWithHash(o, ZeroHash);
    }

    /// go-git `Submodule.UpdateContext` via cooperative transport context.
    pub fn updateContext(
        self: *Submodule,
        context: transport.OperationContext,
        o: *const SubmoduleUpdateOptions,
    ) !void {
        var opts = o.*;
        opts.operation_context = context;
        return self.update(&opts);
    }

    /// Like `update`, but when `force_hash` is non-zero use it as the target
    /// commit instead of the superproject index gitlink (go-git `update` forceHash).
    ///
    /// Explicit `anyerror` breaks the inferred-error cycle with `doRecursiveUpdate`.
    fn updateWithHash(self: *Submodule, o: *const SubmoduleUpdateOptions, force_hash: Hash) anyerror!void {
        try pathutil.validTreePath(self.c.path);
        if (!self.initialized and !o.init) return error.SubmoduleNotInitialized;
        if (!self.initialized and o.init) try self.init();

        const expected = try resolveExpectedHash(self, force_hash);
        const mod = try self.host.storer.module(self.c.name);

        if (!o.no_fetch) try fetchModule(self, mod, o, expected);

        // go-git: Checkout then SetReference(HEAD, hash). Checkout already detaches
        // HEAD when Hash is set; the explicit set matches go-git and keeps HEAD
        // correct if Checkout's HEAD path ever diverges.
        try checkoutModuleWorktree(self, mod, expected);
        try mod.setReference(plumbing.Reference.newHashReference(plumbing.HEAD, expected));

        try doRecursiveUpdate(self, mod, o, expected);
    }
};

/// Owned result of `Submodule.repository`. The module storage remains owned by
/// the superproject storer; this handle owns only its worktree chroot.
pub const OwnedRepository = struct {
    allocator: Allocator,
    worktree_fs: *fs_pkg.Mem,
    repo: repo_pkg.Repository,

    pub fn deinit(self: *OwnedRepository) void {
        self.worktree_fs.deinit();
        self.allocator.destroy(self.worktree_fs);
        self.* = undefined;
    }
};

/// Target commit: non-zero force wins; else index gitlink at `c.path`.
fn resolveExpectedHash(self: *Submodule, force_hash: Hash) !Hash {
    if (!force_hash.isZero()) return force_hash;
    const idx = try self.host.storer.index();
    const e = try idx.entry(self.c.path);
    return e.hash;
}

// ---------------------------------------------------------------------------
// Fetch (go-git fetchAndCheckout fetch half)
// ---------------------------------------------------------------------------

/// Ensure module storage has remote objects for `expected`.
///
/// Ownership stack:
/// - `resolveFetchURL` returns an owned URL (freed here).
/// - `putRemoteFull` copies name/urls/fetch into module config (config owns them).
/// - `remote.Remote` borrows `remote_cfg` for the duration of `fetch`.
/// - `FetchOptions.remote_url` is a borrowed slice valid for each `fetch` call.
fn fetchModule(
    self: *Submodule,
    mod: *memory.Storage,
    o: *const SubmoduleUpdateOptions,
    expected: Hash,
) !void {
    const allocator = self.host.allocator;

    const resolved = try resolveFetchURL(self, o);
    defer allocator.free(resolved);
    if (resolved.len == 0) return error.SubmoduleEmptyURL;

    // go-git `Repository` path: CreateRemote("origin", resolved URL).
    const cfg = try mod.config();
    try cfg.putRemoteFull(
        "origin",
        &[_][]const u8{resolved},
        &[_][]const u8{"+refs/heads/*:refs/remotes/origin/*"},
        false,
    );
    const remote_cfg = cfg.remotes.getPtr("origin") orelse return error.SubmoduleEmptyURL;

    var rem = if (o.embedded) |srv|
        remote.newRemoteEmbedded(mod, remote_cfg, srv)
    else
        remote.newRemote(mod, remote_cfg);

    // Default fetch; AlreadyUpToDate is success (go-git).
    var fetch_opts = makeFetchOptions(o, resolved, &.{});
    try fetchIgnoringUpToDate(&rem, &fetch_opts);

    // Orphaned gitlink: exact-SHA1 want (go-git allow_reachable_sha1_in_want).
    if (objectPresent(mod, expected)) return;

    var hex_buf: [plumbing.MaxHexSize]u8 = undefined;
    const hex = expected.string(&hex_buf);
    const raw = try std.fmt.allocPrint(allocator, "+{s}:{s}", .{ hex, hex });
    defer allocator.free(raw);
    const rs = gitconfig.RefSpec.init(raw);
    var exact_opts = makeFetchOptions(o, resolved, &[_]gitconfig.RefSpec{rs});
    try fetchExactSha1(&rem, &exact_opts);
}

/// Effective fetch URL: options override, else resolve relative against parent.
/// Caller owns the returned slice.
fn resolveFetchURL(self: *Submodule, o: *const SubmoduleUpdateOptions) ![]u8 {
    const allocator = self.host.allocator;
    if (o.remote_url.len > 0) return try allocator.dupe(u8, o.remote_url);

    const raw = self.c.url;
    if (raw.len == 0) return try allocator.dupe(u8, "");

    const super_cfg = try self.host.storer.config();
    // HEAD may be missing on a bare/memory superproject; relative resolution
    // then falls through to the single-remote / "origin" rules.
    const head = self.host.storer.reference(plumbing.HEAD) catch null;
    return relative_url_mod.resolveSubmoduleURL(
        allocator,
        singleThreadedIo(),
        super_cfg,
        head,
        raw,
    );
}

fn singleThreadedIo() std.Io {
    // Transport endpoint resolution may need cwd for bare file paths. Submodule
    // fetch uses a process-wide single-threaded Io (same pattern as other
    // non-test call sites that are not under std.testing.io).
    const Holder = struct {
        threadlocal var threaded: std.Io.Threaded = .init_single_threaded;
    };
    return Holder.threaded.io();
}

fn makeFetchOptions(
    o: *const SubmoduleUpdateOptions,
    url: []const u8,
    ref_specs: []const gitconfig.RefSpec,
) remote.FetchOptions {
    return .{
        .remote_name = "origin",
        .remote_url = url,
        .depth = o.depth,
        .transport = .{
            .auth = o.auth,
            .operation_context = o.operation_context,
        },
        .ref_specs = ref_specs,
    };
}

fn fetchIgnoringUpToDate(rem: *remote.Remote, opts: *remote.FetchOptions) !void {
    rem.fetch(opts) catch |err| {
        if (err == RemoteError.AlreadyUpToDate) return;
        return err;
    };
}

/// Exact-SHA1 fetch: ignore AlreadyUpToDate and ExactSHA1NotSupported (go-git).
fn fetchExactSha1(rem: *remote.Remote, opts: *remote.FetchOptions) !void {
    rem.fetch(opts) catch |err| {
        if (err == RemoteError.AlreadyUpToDate) return;
        if (err == RemoteError.ExactSHA1NotSupported) return;
        return err;
    };
}

fn objectPresent(mod: *memory.Storage, h: Hash) bool {
    _ = mod.encodedObject(.any, h) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Checkout (go-git fetchAndCheckout worktree half)
// ---------------------------------------------------------------------------

/// Materialize `expected` commit into the host worktree at `self.c.path`.
///
/// go-git opens the submodule `Worktree` (FS already rooted at the module path)
/// and calls `Checkout(&CheckoutOptions{Hash: hash})` **without Force** (Merge
/// reset). gitz matches that: default Merge on the module storage + chroot Mem
/// view. Empty module index/worktree is a full insert set under Merge; dirty
/// worktrees with unstaged changes surface `UnstagedChanges` like go-git.
///
/// gitz binds module storage to a **chroot view** of the host Mem FS at
/// `c.path`:
/// - `view` is stack-local; `deinit` frees only `root_path` (`owns_store=false`).
/// - `Worktree` borrows `&view` for the duration of `checkout` only.
///
/// Missing commit/tree after fetch surfaces the object error (no silent skip).
fn checkoutModuleWorktree(self: *Submodule, mod: *memory.Storage, expected: Hash) !void {
    const host_fs = self.host.filesystem;

    // Chroot requires an existing directory node.
    try host_fs.mkdirAll(self.c.path, 0o755);

    var view = try host_fs.chroot(self.c.path);
    defer view.deinit();

    // Worktree must not outlive `view`. Checkout is the only use of `wt`.
    // go-git: Checkout(&CheckoutOptions{Hash: hash}) — Merge, not Force.
    var wt = worktree.newWorktree(self.host.allocator, mod, &view);
    try wt.checkout(.{
        .hash = expected,
        .force = false,
    });
    // `view` still live here; `wt` is not retained.
}

// ---------------------------------------------------------------------------
// Recursion (go-git doRecursiveUpdate) via object graph
// ---------------------------------------------------------------------------

/// Nested Update with chrooted host FS under this module path.
///
/// go-git: open submodule worktree, list nested modules from on-disk
/// `.gitmodules`, then `Submodules.Update` with depth − 1.
///
/// gitz memory path has no nested on-disk gitdir layout, so nested modules are
/// discovered from the `.gitmodules` blob + gitlink entries at `parent_commit`
/// in `mod`. Nested checkouts write under `self.c.path/<nested-path>` via a
/// chroot of the host FS (shared node map; view does not own the store).
///
/// Nested Host uses **module storage** as storer. Init persists into
/// `mod.config().submodules` (go-git Config.Submodules). A later nested Host
/// for the same module reloads that registry — Init is not frame-local.
/// Pass `o.init` so first-time nested modules can Init there.
///
/// No-op when `recurse_submodules == 0` or the commit has no `.gitmodules`.
fn doRecursiveUpdate(
    self: *Submodule,
    mod: *memory.Storage,
    o: *const SubmoduleUpdateOptions,
    parent_commit: Hash,
) anyerror!void {
    if (o.recurse_submodules == options_mod.no_recurse_submodules) return;

    const allocator = self.host.allocator;

    var modules = (try loadModulesFromCommit(allocator, mod, parent_commit)) orelse return;
    defer modules.deinit();

    // Nested host: storer = this module; FS chroot so nested paths are relative
    // to the parent module directory on the superproject worktree.
    // Host.init loads any prior Init entries from mod.config().
    try self.host.filesystem.mkdirAll(self.c.path, 0o755);
    var nested_fs = try self.host.filesystem.chroot(self.c.path);
    defer nested_fs.deinit();

    var nested_host = Host.init(allocator, mod, &nested_fs);
    defer nested_host.deinit();

    var list = try listSubmodules(&nested_host, &modules);
    defer list.free(allocator);

    var child_opts = o.*;
    // Saturating: depth 1 → 0 (no further recurse). Wrapping would re-enable.
    child_opts.recurse_submodules -|= 1;

    for (list.items) |sm| {
        const force = (try gitlinkHashAt(allocator, mod, parent_commit, sm.c.path)) orelse {
            // .gitmodules path without a tree gitlink — same class as missing
            // superproject index entry.
            return error.EntryNotFound;
        };
        try sm.updateWithHash(&child_opts, force);
    }
    // nested_host then nested_fs: Host does not own FS; deinit order is safe.
}

/// Parse `.gitmodules` from the tree of `commit_hash`. Null when absent.
fn loadModulesFromCommit(
    allocator: Allocator,
    sto: *memory.Storage,
    commit_hash: Hash,
) !?Modules {
    const c = object.getCommit(allocator, sto, commit_hash) catch |err| switch (err) {
        error.ObjectNotFound => return null,
        else => return err,
    };
    defer {
        c.deinit();
        allocator.destroy(c);
    }

    const file = c.file(gitmodules_file) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const data = try file.contents(allocator);
    defer allocator.free(data);

    var m = try Modules.create(allocator);
    errdefer m.deinit();
    try m.unmarshal(data);
    return m;
}

/// Gitlink hash at `path` under `commit_hash`, or null when missing / not a submodule.
fn gitlinkHashAt(
    allocator: Allocator,
    sto: *memory.Storage,
    commit_hash: Hash,
    path: []const u8,
) !?Hash {
    const c = try object.getCommit(allocator, sto, commit_hash);
    defer {
        c.deinit();
        allocator.destroy(c);
    }
    const t = try c.tree();
    defer object.freeTree(allocator, t);

    const entry = t.findEntry(path) catch |err| switch (err) {
        error.EntryNotFound, error.DirectoryNotFound, error.FileNotFound, error.InvalidPath => return null,
        else => return err,
    };
    if (entry.mode != filemode.Submodule) return null;
    return entry.hash;
}

// ---------------------------------------------------------------------------
// Submodules list
// ---------------------------------------------------------------------------

/// go-git `Submodules` — list of submodule pointers from one repository.
pub const Submodules = struct {
    items: []*Submodule = &.{},

    pub fn free(self: *Submodules, allocator: Allocator) void {
        for (self.items) |sm| {
            sm.deinit();
            allocator.destroy(sm);
        }
        if (self.items.len > 0) allocator.free(self.items);
        self.items = &.{};
    }

    /// go-git `Submodules.Init`.
    pub fn initAll(self: *Submodules) !void {
        for (self.items) |sm| {
            try sm.init();
        }
    }

    /// go-git `Submodules.Update`.
    pub fn update(self: *Submodules, o: *const SubmoduleUpdateOptions) !void {
        for (self.items) |sm| {
            try sm.update(o);
        }
    }

    /// go-git `Submodules.Status`.
    ///
    /// Loads the superproject index once and reuses it for every entry
    /// (go-git loads per item; same index content).
    pub fn status(self: *Submodules, allocator: Allocator) !SubmodulesStatus {
        var list: std.ArrayList(SubmoduleStatus) = .empty;
        errdefer list.deinit(allocator);

        if (self.items.len == 0) return .{ .items = &.{} };

        const idx = try self.items[0].host.storer.index();
        for (self.items) |sm| {
            const st = try sm.statusWithIndex(idx);
            try list.append(allocator, st);
        }
        return .{ .items = try list.toOwnedSlice(allocator) };
    }
};

// ---------------------------------------------------------------------------
// Worktree / Modules integration (go-git Worktree.Submodule / Submodules)
// ---------------------------------------------------------------------------

/// Clone a config.Submodule into a heap entry (caller owns).
fn cloneSubmoduleConfig(allocator: Allocator, src: *const SubmoduleConfig) Allocator.Error!*SubmoduleConfig {
    const m = try allocator.create(SubmoduleConfig);
    errdefer allocator.destroy(m);
    m.* = SubmoduleConfig.init(allocator);
    errdefer m.deinit();
    try owned.set(allocator, &m.name, src.name);
    try owned.set(allocator, &m.path, src.path);
    try owned.set(allocator, &m.url, src.url);
    try owned.set(allocator, &m.branch, src.branch);
    return m;
}

/// go-git `Worktree.newSubmodule` — merge Modules entry with initialized config.
fn newSubmodule(host: *Host, from_modules: *const SubmoduleConfig, from_config: ?*const SubmoduleConfig) !*Submodule {
    try pathutil.validTreePath(from_modules.path);
    const sm = try host.allocator.create(Submodule);
    errdefer host.allocator.destroy(sm);

    const initialized = from_config != null;
    const src = if (from_config) |fc| fc else from_modules;
    const c = try cloneSubmoduleConfig(host.allocator, src);
    errdefer {
        c.deinit();
        host.allocator.destroy(c);
    }
    // Always take path from .gitmodules (go-git: m.c.Path = fromModules.Path).
    try owned.set(host.allocator, &c.path, from_modules.path);

    sm.* = .{
        .host = host,
        .initialized = initialized,
        .c = c,
    };
    return sm;
}

/// Read `.gitmodules` from a Mem FS into Modules (go-git `readGitmodulesFile`).
///
/// Returns `null` when the file does not exist. Errors on symlink.
pub fn readGitmodulesFile(allocator: Allocator, filesystem: *fs_pkg.Mem) !?Modules {
    if (isSymlink(filesystem, gitmodules_file)) return error.GitModulesSymlink;

    const data = readFileAll(allocator, filesystem, gitmodules_file) catch |err| switch (err) {
        error.NotExist => return null,
        else => return err,
    };
    defer allocator.free(data);

    var m = try Modules.create(allocator);
    errdefer m.deinit();
    try m.unmarshal(data);
    return m;
}

fn isSymlink(filesystem: *fs_pkg.Mem, path: []const u8) bool {
    const info = filesystem.lstat(path) catch return false;
    return info.isSymlink();
}

fn readFileAll(allocator: Allocator, filesystem: *fs_pkg.Mem, path: []const u8) ![]u8 {
    var f = try filesystem.open(path);
    defer f.close() catch {};
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [256]u8 = undefined;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
    }
    return try list.toOwnedSlice(allocator);
}

/// go-git `Worktree.Submodules` over Host + optional pre-parsed Modules.
///
/// When `modules_opt` is null, reads `.gitmodules` from the host filesystem.
/// Caller frees the returned list with `Submodules.free`.
pub fn listSubmodules(host: *Host, modules_opt: ?*const Modules) !Submodules {
    var owned_modules: ?Modules = null;
    defer if (owned_modules) |*m| m.deinit();

    const modules: *const Modules = blk: {
        if (modules_opt) |m| break :blk m;
        owned_modules = try readGitmodulesFile(host.allocator, host.filesystem);
        if (owned_modules) |*m| break :blk m;
        return .{ .items = &.{} };
    };

    var list: std.ArrayList(*Submodule) = .empty;
    errdefer {
        for (list.items) |sm| {
            sm.deinit();
            host.allocator.destroy(sm);
        }
        list.deinit(host.allocator);
    }

    var it = modules.submodules.iterator();
    while (it.next()) |e| {
        const from_modules = e.value_ptr.*;
        const from_config = host.getInitialized(from_modules.name);
        const sm = try newSubmodule(host, from_modules, from_config);
        try list.append(host.allocator, sm);
    }

    return .{ .items = try list.toOwnedSlice(host.allocator) };
}

/// go-git `Worktree.Submodule(name)`.
///
/// Caller owns the returned pointer (`deinit` + `destroy`).
pub fn getSubmodule(host: *Host, name: []const u8) !*Submodule {
    var list = try listSubmodules(host, null);
    // On success we free the list slice and all other items; on not-found
    // free everything. Do not `defer list.free` — that would free `found`.
    const found_idx = blk: {
        for (list.items, 0..) |sm, i| {
            if (std.mem.eql(u8, sm.config().name, name)) break :blk i;
        }
        list.free(host.allocator);
        return error.SubmoduleNotFound;
    };

    const found = list.items[found_idx];
    for (list.items, 0..) |sm, i| {
        if (i == found_idx) continue;
        sm.deinit();
        host.allocator.destroy(sm);
    }
    if (list.items.len > 0) host.allocator.free(list.items);
    return found;
}

/// List submodules for a worktree.Worktree + Host registry.
///
/// Host must share the same storer/filesystem as `w` (use `Host.fromWorktree`
/// then keep Host alive while list is used). Caller still owns init registry
/// on Host after Init.
pub fn listFromWorktree(host: *Host, w: anytype) !Submodules {
    std.debug.assert(host.storer == w.storer);
    std.debug.assert(host.filesystem == w.filesystem);
    return listSubmodules(host, null);
}

/// Owned Worktree.Submodules glue. This keeps the Host at a stable address for
/// the lifetime of every returned Submodule.
pub const WorktreeSubmodules = struct {
    allocator: Allocator,
    host: *Host,
    items: Submodules,

    pub fn deinit(self: *WorktreeSubmodules) void {
        self.items.free(self.allocator);
        self.host.deinit();
        self.allocator.destroy(self.host);
        self.* = undefined;
    }
};

/// go-git `Worktree.Submodules` method glue without a package cycle.
pub fn submodulesForWorktree(w: anytype) !WorktreeSubmodules {
    const h = try w.allocator.create(Host);
    errdefer w.allocator.destroy(h);
    h.* = Host.fromWorktree(w);
    errdefer h.deinit();
    return .{
        .allocator = w.allocator,
        .host = h,
        .items = try listSubmodules(h, null),
    };
}

/// Owned Worktree.Submodule glue for one named module.
pub const WorktreeSubmodule = struct {
    allocator: Allocator,
    host: *Host,
    item: *Submodule,

    pub fn deinit(self: *WorktreeSubmodule) void {
        self.item.deinit();
        self.allocator.destroy(self.item);
        self.host.deinit();
        self.allocator.destroy(self.host);
        self.* = undefined;
    }
};

/// go-git `Worktree.Submodule(name)` method glue without a package cycle.
pub fn submoduleForWorktree(w: anytype, name: []const u8) !WorktreeSubmodule {
    const h = try w.allocator.create(Host);
    errdefer w.allocator.destroy(h);
    h.* = Host.fromWorktree(w);
    errdefer h.deinit();
    return .{
        .allocator = w.allocator,
        .host = h,
        .item = try getSubmodule(h, name),
    };
}

/// Expected gitlink hash from an index entry, or zero when not a submodule.
/// Exported for tests / call sites that already have an Entry.
pub fn expectedFromEntry(entry: *const index_format.Entry) Hash {
    if (entry.mode == filemode.Submodule or entry.mode == filemode.Empty) {
        return entry.hash;
    }
    return ZeroHash;
}

/// Post-pull submodule init+update (go-git Worktree.Pull recurse path).
///
/// Call after `worktree.pull` when `PullOptions.recurse_submodules > 0`
/// (from porcelain or app code — worktree cannot import this package).
pub fn updateFromWorktreePull(
    allocator: Allocator,
    storer_ptr: *memory.Storage,
    filesystem: *fs_pkg.Mem,
    embedded: ?*server.Server,
    recurse: u32,
    depth: i32,
    auth: ?transport.AuthMethod,
    operation_context: transport.OperationContext,
) !void {
    if (recurse == 0) return;
    var h = Host.init(allocator, storer_ptr, filesystem);
    defer h.deinit();
    var list = try listSubmodules(&h, null);
    defer list.free(allocator);
    const o = SubmoduleUpdateOptions{
        .init = true,
        .no_fetch = false,
        .recurse_submodules = recurse,
        .depth = depth,
        .auth = auth,
        .operation_context = operation_context,
        .embedded = embedded,
    };
    try list.update(&o);
}

/// Bind the concrete submodule updater to worktree PullOptions without adding
/// a worktree -> submodule package dependency.
pub fn bindPullOptions(o: anytype) void {
    o.submodule_updater = .{ .update_fn = pullUpdateCallback };
}

fn pullUpdateCallback(
    _: ?*anyopaque,
    allocator: Allocator,
    storer_ptr: *memory.Storage,
    filesystem: *fs_pkg.Mem,
    embedded: ?*server.Server,
    recurse: u32,
    depth: i32,
    auth: ?transport.AuthMethod,
    operation_context: transport.OperationContext,
) anyerror!void {
    return updateFromWorktreePull(
        allocator,
        storer_ptr,
        filesystem,
        embedded,
        recurse,
        depth,
        auth,
        operation_context,
    );
}
