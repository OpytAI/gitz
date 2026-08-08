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

const options_mod = @import("options.zig");
const status_mod = @import("status.zig");
const host_mod = @import("host.zig");
const relative_url_mod = @import("relative_url.zig");

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
        try self.host.putInitialized(self.c);
        self.initialized = true;
    }

    /// go-git `Submodule.Status`.
    pub fn status(self: *Submodule) !SubmoduleStatus {
        const idx = try self.host.storer.index();
        return try self.statusWithIndex(idx);
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
    /// When `no_fetch` is false, fetches the submodule remote into module
    /// storage (`remote` package; optional `o.embedded` MapLoader server for
    /// hermetic tests). Always materializes the commit tree into the host
    /// worktree at `c.path` (go-git `Worktree.Checkout`), then sets a detached
    /// HEAD at the superproject gitlink.
    ///
    /// Recursion (`o.recurse_submodules > 0`): nested modules are discovered
    /// from the `.gitmodules` blob at the checked-out commit (object graph)
    /// and checked out under the parent module path on the host FS.
    pub fn update(self: *Submodule, o: *const SubmoduleUpdateOptions) !void {
        return self.updateWithHash(o, ZeroHash);
    }

    /// Like `update`, but when `force_hash` is non-zero use it as the target
    /// commit instead of the superproject index gitlink (go-git `update` forceHash).
    ///
    /// Explicit `anyerror` breaks the inferred-error cycle with `doRecursiveUpdate`.
    fn updateWithHash(self: *Submodule, o: *const SubmoduleUpdateOptions, force_hash: Hash) anyerror!void {
        if (!self.initialized and !o.init) return error.SubmoduleNotInitialized;

        if (!self.initialized and o.init) {
            try self.init();
        }

        const expected = if (!force_hash.isZero()) force_hash else blk: {
            const idx = try self.host.storer.index();
            const e = try idx.entry(self.c.path);
            break :blk e.hash;
        };

        const mod = try self.host.storer.module(self.c.name);

        if (!o.no_fetch) {
            try fetchModule(self, mod, o, expected);
        }

        // Materialize commit tree into host FS at c.path, then detach HEAD
        // (go-git fetchAndCheckout: Checkout + NewHashReference HEAD).
        try checkoutModuleWorktree(self, mod, expected);
        try mod.setReference(plumbing.Reference.newHashReference(plumbing.HEAD, expected));

        try doRecursiveUpdate(self, mod, o, expected);
    }
};

// ---------------------------------------------------------------------------
// Fetch (go-git fetchAndCheckout fetch half)
// ---------------------------------------------------------------------------

/// Ensure module storage has remote objects for `expected`.
///
/// Layering: resolve relative submodule URLs against the superproject default
/// remote; `putRemoteFull` owns RemoteConfig string copies; `remote.Remote`
/// borrows that config; `FetchOptions.remote_url` is a borrowed slice valid
/// for the duration of each `fetch` call.
fn fetchModule(
    self: *Submodule,
    mod: *memory.Storage,
    o: *const SubmoduleUpdateOptions,
    expected: Hash,
) !void {
    const allocator = self.host.allocator;

    // Resolve effective URL: override wins; else config URL with relative join.
    const resolved = try resolveFetchURL(self, o);
    defer allocator.free(resolved);
    if (resolved.len == 0) return error.SubmoduleEmptyURL;

    // Ensure origin remote on module config (go-git Repository CreateRemote).
    // putRemoteFull duplicates name/urls/fetch into config-owned storage.
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

    var fetch_opts = makeFetchOptions(o, resolved, &.{});
    rem.fetch(&fetch_opts) catch |err| {
        if (err != RemoteError.AlreadyUpToDate) return err;
    };

    // Orphaned gitlink: exact-SHA1 want (go-git allow_reachable_sha1_in_want).
    if (objectPresent(mod, expected)) return;

    var hex_buf: [plumbing.MaxHexSize]u8 = undefined;
    const hex = expected.string(&hex_buf);
    const raw = try std.fmt.allocPrint(allocator, "+{s}:{s}", .{ hex, hex });
    defer allocator.free(raw);
    const rs = gitconfig.RefSpec.init(raw);
    var exact_opts = makeFetchOptions(o, resolved, &[_]gitconfig.RefSpec{rs});
    rem.fetch(&exact_opts) catch |err| {
        if (err == RemoteError.AlreadyUpToDate) {
            // ok
        } else if (err == RemoteError.ExactSHA1NotSupported) {
            // go-git ignores ErrExactSHA1NotSupported
        } else {
            return err;
        }
    };
}

/// Effective fetch URL: options override, else resolve relative against parent.
/// Caller owns the returned slice.
fn resolveFetchURL(self: *Submodule, o: *const SubmoduleUpdateOptions) ![]u8 {
    const allocator = self.host.allocator;
    if (o.remote_url.len > 0) {
        // Explicit override is used as-is (go-git options path).
        return try allocator.dupe(u8, o.remote_url);
    }
    const raw = self.c.url;
    if (raw.len == 0) return try allocator.dupe(u8, "");

    const super_cfg = try self.host.storer.config();
    const head = self.host.storer.reference(plumbing.HEAD) catch null;
    return relative_url_mod.resolveSubmoduleURL(
        allocator,
        singleThreadedIo(),
        super_cfg,
        head,
        raw,
    ) catch |err| switch (err) {
        error.ParentRemoteNotFound, error.ParentRemoteEmptyURL => return err,
        else => return err,
    };
}

fn singleThreadedIo() std.Io {
    const Holder = struct {
        threadlocal var threaded: std.Io.Threaded = .init_single_threaded;
    };
    return Holder.threaded.io();
}

/// Build `remote.FetchOptions` with auth + depth fully wired from update options.
fn makeFetchOptions(
    o: *const SubmoduleUpdateOptions,
    url: []const u8,
    ref_specs: []const gitconfig.RefSpec,
) remote.FetchOptions {
    return .{
        .remote_name = "origin",
        .remote_url = url,
        .depth = o.depth,
        .transport = .{ .auth = o.auth },
        .ref_specs = ref_specs,
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
/// go-git: `w.Checkout(&CheckoutOptions{Hash: hash})` on the submodule repo
/// worktree (already rooted at the submodule path). gitz binds module storage
/// to a chroot of the host FS at `c.path`.
///
/// Missing commit/tree after fetch surfaces the object error (no silent skip).
fn checkoutModuleWorktree(self: *Submodule, mod: *memory.Storage, expected: Hash) !void {
    const host_fs = self.host.filesystem;

    // Ensure submodule directory exists so chroot can open it.
    try host_fs.mkdirAll(self.c.path, 0o755);

    var view = try host_fs.chroot(self.c.path);
    defer view.deinit(); // chroot view: frees root_path only (owns_store = false)

    var wt = worktree.newWorktree(self.host.allocator, mod, &view);
    // Force hard materialization (empty or dirty module worktree).
    try wt.checkout(.{
        .hash = expected,
        .force = true,
    });
}

// ---------------------------------------------------------------------------
// Recursion (go-git doRecursiveUpdate) via object graph
// ---------------------------------------------------------------------------

/// Nested Update with chrooted host FS under this module path.
///
/// go-git chroots the submodule worktree and re-lists `.gitmodules` from disk.
/// Here, nested modules are discovered from the `.gitmodules` blob and gitlink
/// entries at `parent_commit` in `mod`, and nested checkouts write under
/// `self.c.path/<nested-path>` on the host filesystem.
///
/// When the commit has no `.gitmodules`, there is nothing to recurse into
/// (equivalent to an empty nested list). When `recurse_submodules == 0`,
/// this is a pure no-op.
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

    // Nested host: child superproject storer is this module storage; FS is a
    // chroot of the parent module path so nested checkout lands under path/.
    try self.host.filesystem.mkdirAll(self.c.path, 0o755);
    var nested_fs = try self.host.filesystem.chroot(self.c.path);
    defer nested_fs.deinit();
    var nested_host = Host.init(allocator, mod, &nested_fs);
    defer nested_host.deinit();

    var list = try listSubmodules(&nested_host, &modules);
    defer list.free(allocator);

    var child_opts = o.*;
    child_opts.recurse_submodules -%= 1;

    for (list.items) |sm| {
        const force = (try gitlinkHashAt(allocator, mod, parent_commit, sm.c.path)) orelse {
            // Path recorded in .gitmodules but no gitlink in the tree — same
            // class of failure as a missing index entry on the top level.
            return error.EntryNotFound;
        };
        try sm.updateWithHash(&child_opts, force);
    }
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
    pub fn status(self: *Submodules, allocator: Allocator) !SubmodulesStatus {
        var list: std.ArrayList(SubmoduleStatus) = .empty;
        errdefer list.deinit(allocator);

        var r_storer: ?*memory.Storage = null;
        for (self.items) |sm| {
            if (r_storer == null) r_storer = sm.host.storer;
            const idx = try r_storer.?.index();
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
    try setOwned(allocator, &m.name, src.name);
    try setOwned(allocator, &m.path, src.path);
    try setOwned(allocator, &m.url, src.url);
    try setOwned(allocator, &m.branch, src.branch);
    return m;
}

fn setOwned(allocator: Allocator, dest: *[]const u8, value: []const u8) Allocator.Error!void {
    if (dest.*.len > 0) allocator.free(dest.*);
    if (value.len == 0) {
        dest.* = "";
        return;
    }
    dest.* = try allocator.dupe(u8, value);
}

/// go-git `Worktree.newSubmodule` — merge Modules entry with initialized config.
fn newSubmodule(host: *Host, from_modules: *const SubmoduleConfig, from_config: ?*const SubmoduleConfig) Allocator.Error!*Submodule {
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
    try setOwned(host.allocator, &c.path, from_modules.path);

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

    var found_idx: ?usize = null;
    for (list.items, 0..) |sm, i| {
        if (std.mem.eql(u8, sm.config().name, name)) {
            found_idx = i;
            break;
        }
    }
    if (found_idx == null) {
        list.free(host.allocator);
        return error.SubmoduleNotFound;
    }

    const found = list.items[found_idx.?];
    // Free every other submodule and the list slice; transfer `found` to caller.
    for (list.items, 0..) |sm, i| {
        if (i == found_idx.?) continue;
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
pub fn listFromWorktree(host: *Host, w: *worktree.Worktree) !Submodules {
    std.debug.assert(host.storer == w.storer);
    std.debug.assert(host.filesystem == w.filesystem);
    return listSubmodules(host, null);
}

/// Build a SubmoduleStatus expected hash helper from a gitlink index entry.
/// Exported for tests / call sites that already have an Entry.
pub fn expectedFromEntry(entry: *const index_format.Entry) Hash {
    if (entry.mode == filemode.Submodule or entry.mode == filemode.Empty) {
        return entry.hash;
    }
    return entry.hash;
}
