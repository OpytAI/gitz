//! PlainInit / PlainOpen — filesystem-backed repository lifecycle (go-git root).
//!
//! Hermetic path uses `fs.Mem` + `//src/storage/filesystem` (no host `Os` required
//! for tests). Host `Os` can follow the same flow via `filesystem.newStorageOs`.
//!
//! PlainClone is in `//src/porcelain`. Linked-worktree commondir repositories
//! use a local storage for worktree-private HEAD/index and a common storage
//! for refs, objects, config, and packs.

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");
const filesystem = @import("filesystem");
const fs_pkg = @import("fs");
const format_config = @import("config");
const hash_algo = @import("hash");
const storer = @import("storer");
const dotgit = @import("dotgit");
const utils_sync = @import("utils/sync");

const repository = @import("repository.zig");
const error_mod = @import("error.zig");
const repack_mod = @import("repack.zig");

const Allocator = std.mem.Allocator;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const Config = memory.Config;
const Mem = fs_pkg.Mem;

pub const Error = error_mod.Error;
pub const git_dir_name = repository.git_dir_name;
pub const InitOptions = repository.InitOptions;
pub const RepackConfig = repack_mod.RepackConfig;

/// go-git `PlainInitOptions`.
pub const PlainInitOptions = struct {
    /// Embedded init options (default branch).
    init_options: InitOptions = .{},
    /// Bare repository (no worktree).
    bare: bool = false,
    /// Object hash format (`""` / `"sha1"` default; `"sha256"` enables SHA-256 OIDs).
    object_format: []const u8 = "",
    /// Filesystem root used to resolve `objects/info/alternates` paths.
    /// The caller owns this filesystem and must keep it alive with the repository.
    alternates_fs: ?*Mem = null,
};

/// go-git `PlainOpenOptions`.
pub const PlainOpenOptions = struct {
    /// Walk parent directories until `.git` is found.
    detect_dot_git: bool = false,
    /// Enable `.git/commondir` linked-worktree layout.
    enable_dot_git_common_dir: bool = false,
};

/// Filesystem-backed repository (go-git `Repository` over filesystem storage).
///
/// Owns the storage and any chroot `Mem` created for `.git` / detect walks.
/// Does **not** own the caller's original worktree / bare root `Mem`.
pub const PlainRepository = struct {
    allocator: Allocator,
    storer: *filesystem.StorageMem,
    /// Worktree-local gitdir storage for a linked worktree. `storer` points at
    /// the common directory when this is non-null.
    local_storer: ?*filesystem.StorageMem = null,
    /// Owned chroot into `.git` (non-bare) or into a `gitdir:` target.
    owned_dot: ?*Mem = null,
    /// Owned worktree chroot when DetectDotGit walked to a parent.
    owned_worktree: ?*Mem = null,
    /// Owned chroot of the common git directory for linked worktrees.
    owned_common: ?*Mem = null,
    /// Worktree FS; null when bare. May equal `owned_worktree` or caller's Mem.
    worktree: ?*Mem = null,

    pub fn deinit(self: *PlainRepository) void {
        if (self.local_storer) |local| {
            local.deinit();
            self.allocator.destroy(local);
        }
        self.storer.deinit();
        self.allocator.destroy(self.storer);
        if (self.owned_common) |common| {
            common.deinit();
            self.allocator.destroy(common);
        }
        if (self.owned_dot) |dot| {
            dot.deinit();
            self.allocator.destroy(dot);
        }
        if (self.owned_worktree) |wt| {
            wt.deinit();
            self.allocator.destroy(wt);
        }
        self.* = undefined;
    }

    pub fn isBare(self: *const PlainRepository) bool {
        return self.worktree == null;
    }

    /// Activate this repository's object format for process-wide wire codecs.
    pub fn activateFormat(self: *const PlainRepository) void {
        self.storer.activateFormat();
        if (self.local_storer) |local| local.setHashAlgo(self.storer.hashAlgo());
    }

    pub fn config(self: *PlainRepository) !*Config {
        self.activateFormat();
        return self.storer.config();
    }

    pub fn setConfig(self: *PlainRepository, cfg: *Config) !void {
        return self.storer.setConfig(cfg);
    }

    pub fn setIsBare(self: *PlainRepository, bare: bool) !void {
        const cfg = try self.config();
        cfg.is_bare = bare;
        try self.setConfig(cfg);
    }

    /// Index is worktree-private in Git's commondir layout.
    pub fn index(self: *PlainRepository) !*filesystem.StorageMem.Index {
        if (self.local_storer) |local| return local.index();
        return self.storer.index();
    }

    /// Store an index in the worktree-local gitdir when commondir is active.
    pub fn setIndex(self: *PlainRepository, idx: *filesystem.StorageMem.Index) void {
        if (self.local_storer) |local| {
            local.setIndex(idx);
        } else {
            self.storer.setIndex(idx);
        }
    }

    /// Unresolved reference lookup. FS refs are owned — free with `freeReference`.
    pub fn reference(self: *PlainRepository, name: ReferenceName, resolved: bool) !Reference {
        self.activateFormat();
        if (self.local_storer) |local| {
            if (name.eql(plumbing.HEAD)) {
                const head_ref = try local.reference(name);
                if (!resolved or head_ref.type == .hash) return head_ref;
                const target = head_ref.target;
                // Resolve through common refs before freeing the owned local ref.
                const result = resolveOwnedFsReference(self.storer, self.allocator, target) catch |err| {
                    dotgit.freeRef(self.allocator, head_ref);
                    return err;
                };
                dotgit.freeRef(self.allocator, head_ref);
                return result;
            }
        }
        if (resolved) return resolveOwnedFsReference(self.storer, self.allocator, name);
        return self.storer.reference(name);
    }

    /// Free a reference returned by `reference` / `head` on this backend.
    pub fn freeReference(self: *const PlainRepository, ref: Reference) void {
        dotgit.freeRef(self.allocator, ref);
    }

    /// Abandon a caller-owned EncodedObject create that was never successfully set.
    pub fn discardEncodedObject(self: *PlainRepository, obj: *plumbing.MemoryObject) void {
        self.storer.discardEncodedObject(obj);
    }

    pub fn head(self: *PlainRepository) !Reference {
        return self.reference(plumbing.HEAD, true);
    }

    /// go-git `Repository.RepackObjects` over filesystem storage.
    ///
    /// Walks all refs, writes one new pack of reachable objects, deletes packed
    /// loose objects, then deletes older packs per `cfg.only_delete_packs_older_than`.
    pub fn repackObjects(self: *PlainRepository, cfg: *const RepackConfig) !void {
        self.activateFormat();
        return repack_mod.repackObjectsFs(self.allocator, self.storer, cfg);
    }
};

/// Resolve filesystem references while releasing each owned symbolic hop.
/// The generic storer resolver is correct for borrowed reference values, but
/// filesystem reference names and targets are heap-owned.
fn resolveOwnedFsReference(
    storage: *filesystem.StorageMem,
    allocator: Allocator,
    name: ReferenceName,
) !Reference {
    var current = try storage.reference(name);
    var recursion: usize = 0;
    while (current.type == .symbolic) {
        if (recursion > storer.MaxResolveRecursion) {
            dotgit.freeRef(allocator, current);
            return error.MaxResolveRecursion;
        }
        const next = storage.reference(current.target) catch |err| {
            dotgit.freeRef(allocator, current);
            return err;
        };
        dotgit.freeRef(allocator, current);
        current = next;
        recursion += 1;
    }
    return current;
}

// ---------------------------------------------------------------------------
// PlainInit
// ---------------------------------------------------------------------------

/// go-git `PlainInit` — empty repo at the root of `path_fs`.
pub fn plainInit(allocator: Allocator, path_fs: *Mem, is_bare: bool) !PlainRepository {
    return plainInitWithOptions(allocator, path_fs, .{ .bare = is_bare });
}

/// go-git `PlainInitWithOptions` over `fs.Mem`.
pub fn plainInitWithOptions(allocator: Allocator, path_fs: *Mem, opts: PlainInitOptions) !PlainRepository {
    // Validate object format up front (go-git only special-cases SHA-256 support).
    const fmt = try resolveObjectFormat(opts.object_format);

    var owned_dot: ?*Mem = null;
    errdefer if (owned_dot) |d| {
        d.deinit();
        allocator.destroy(d);
    };

    const worktree: ?*Mem = if (opts.bare) null else path_fs;
    const dot_fs: *Mem = if (opts.bare) path_fs else blk: {
        try path_fs.mkdirAll(git_dir_name, fs_pkg.Mode.dir);
        const chrooted = try path_fs.chroot(git_dir_name);
        const p = try allocator.create(Mem);
        p.* = chrooted;
        owned_dot = p;
        break :blk p;
    };

    const s = try filesystem.newStorageWithOptions(
        allocator,
        dot_fs,
        null,
        .{ .alternates_fs = opts.alternates_fs },
    );
    errdefer {
        s.deinit();
        allocator.destroy(s);
    }
    // Per-repo format on storage + activate for wire codecs.
    s.setHashAlgo(fmt);

    // go-git initStorer → filesystem Storage.Init
    try s.initLayout();

    // Already initialised?
    if (s.reference(plumbing.HEAD)) |existing| {
        freeFsRef(allocator, existing);
        return error.RepositoryAlreadyExists;
    } else |err| switch (err) {
        error.ReferenceNotFound => {},
        else => |e| return e,
    }

    var default_branch = opts.init_options.default_branch;
    if (default_branch.raw.len == 0) default_branch = plumbing.master;
    try default_branch.validate();

    const head_ref = Reference.newSymbolicReference(plumbing.HEAD, default_branch);
    try s.setReference(head_ref);

    // Config: bare flag + object format (go-git always SetConfig after init).
    const cfg = try s.config();
    if (worktree == null) cfg.is_bare = true;
    if (fmt == .sha256 or (opts.object_format.len > 0 and std.mem.eql(u8, opts.object_format, format_config.SHA1))) {
        // go-git: non-default format → Version_1 + Extensions.ObjectFormat
        try cfg.setRepositoryFormatVersion(format_config.Version1);
        try cfg.setObjectFormat(if (fmt == .sha256) format_config.SHA256 else format_config.SHA1);
    }
    try s.setConfig(cfg);

    // Transfer owned_dot / s to the result; success return cancels errdefers.
    const result = PlainRepository{
        .allocator = allocator,
        .storer = s,
        .owned_dot = owned_dot,
        .worktree = worktree,
    };
    owned_dot = null;
    return result;
}

// ---------------------------------------------------------------------------
// PlainOpen
// ---------------------------------------------------------------------------

/// go-git `PlainOpen` at the root of `path_fs`.
pub fn plainOpen(allocator: Allocator, path_fs: *Mem) !PlainRepository {
    return plainOpenWithOptions(allocator, path_fs, .{});
}

/// go-git `PlainOpenWithOptions` over `fs.Mem`.
pub fn plainOpenWithOptions(allocator: Allocator, path_fs: *Mem, o: PlainOpenOptions) !PlainRepository {
    var resolved = try resolveDotGitMem(allocator, path_fs, o.detect_dot_git);
    errdefer resolved.deinitOwned(allocator);

    var common_fs: ?*Mem = null;
    errdefer if (common_fs) |common| {
        common.deinit();
        allocator.destroy(common);
    };
    if (o.enable_dot_git_common_dir)
        common_fs = try resolveCommonDir(allocator, resolved.dot, resolved.worktree orelse path_fs);

    const local_s = try filesystem.newStorage(allocator, resolved.dot, null);
    errdefer {
        local_s.deinit();
        allocator.destroy(local_s);
    }

    // Open: worktree-local HEAD must exist.
    if (local_s.reference(plumbing.HEAD)) |ref| {
        freeFsRef(allocator, ref);
    } else |err| switch (err) {
        error.ReferenceNotFound => return error.RepositoryNotExists,
        else => |e| return e,
    }

    var common_s: ?*filesystem.StorageMem = null;
    errdefer if (common_s) |common| {
        common.deinit();
        allocator.destroy(common);
    };
    const s = if (common_fs) |common| blk: {
        const storage = try filesystem.newStorage(allocator, common, null);
        common_s = storage;
        break :blk storage;
    } else local_s;

    const cfg = try s.config();
    try repository.verifyExtensions(cfg);
    const fmt = resolveObjectFormat(cfg.object_format) catch .sha1;
    s.setHashAlgo(fmt);

    const r = PlainRepository{
        .allocator = allocator,
        .storer = s,
        .local_storer = if (common_fs != null) local_s else null,
        .owned_dot = resolved.owned_dot,
        .owned_worktree = resolved.owned_worktree,
        .owned_common = common_fs,
        .worktree = resolved.worktree,
    };
    if (common_fs != null) common_s = null;
    common_fs = null;
    resolved.owned_dot = null;
    resolved.owned_worktree = null;
    return r;
}

/// Resolve `.git/commondir`. Null means a normal repository. The path is
/// relative to the worktree-local gitdir, as specified by Git.
fn resolveCommonDir(allocator: Allocator, dot: *Mem, base: *Mem) !?*Mem {
    var f = dot.open("commondir") catch |err| switch (err) {
        error.NotExist => return null,
        else => |e| return e,
    };
    defer f.close() catch {};
    const raw = try readAll(allocator, &f);
    defer allocator.free(raw);
    const path = std.mem.trim(u8, raw, " \t\r\n");
    if (path.len == 0) return error.RepositoryIncomplete;

    const absolute = try std.fs.path.resolve(allocator, &.{ dot.root(), path });
    defer allocator.free(absolute);
    const view = base.chroot(absolute) catch |err| switch (err) {
        error.NotExist, error.NotDir, error.CrossedBoundary => return error.RepositoryIncomplete,
        else => |e| return e,
    };
    const owned = try allocator.create(Mem);
    owned.* = view;
    return owned;
}

/// Map config/option object format string to algorithm.
/// Empty / "sha1" → SHA-1; "sha256" → SHA-256; anything else → error.
fn resolveObjectFormat(s: []const u8) error{ InvalidObjectFormat, SHA256NotSupported }!hash_algo.Algorithm {
    if (s.len == 0 or std.mem.eql(u8, s, format_config.SHA1)) return .sha1;
    if (std.mem.eql(u8, s, format_config.SHA256)) {
        // Honest go-git ErrSHA256NotSupported when dual support is compiled out.
        if (!hash_algo.supportsObjectFormat(.sha256)) return error.SHA256NotSupported;
        return .sha256;
    }
    return error.InvalidObjectFormat;
}

const ResolvedDot = struct {
    dot: *Mem,
    owned_dot: ?*Mem = null,
    owned_worktree: ?*Mem = null,
    worktree: ?*Mem = null,

    fn deinitOwned(self: *ResolvedDot, allocator: Allocator) void {
        if (self.owned_dot) |d| {
            d.deinit();
            allocator.destroy(d);
            self.owned_dot = null;
        }
        if (self.owned_worktree) |w| {
            w.deinit();
            allocator.destroy(w);
            self.owned_worktree = null;
        }
    }
};

/// go-git `dotGitToOSFilesystems` subset for Mem (search from `path_fs` root).
fn resolveDotGitMem(allocator: Allocator, path_fs: *Mem, detect: bool) !ResolvedDot {
    var search: *Mem = path_fs;
    // At most one owned parent chroot while walking (detect=true).
    var walk_owned: ?*Mem = null;
    errdefer if (walk_owned) |w| {
        w.deinit();
        allocator.destroy(w);
    };

    while (true) {
        const st = search.stat(git_dir_name) catch |err| switch (err) {
            error.NotExist => {
                if (detect) {
                    if (try tryParentMem(allocator, search)) |parent| {
                        if (walk_owned) |old| {
                            old.deinit();
                            allocator.destroy(old);
                        }
                        const p = try allocator.create(Mem);
                        p.* = parent;
                        walk_owned = p;
                        search = p;
                        continue;
                    }
                }
                // Bare: caller's path is the git directory (go-git last fs).
                if (walk_owned) |w| {
                    w.deinit();
                    allocator.destroy(w);
                    walk_owned = null;
                }
                return .{ .dot = path_fs, .worktree = null };
            },
            else => |e| return e,
        };

        if (st.isDir()) {
            const chrooted = try search.chroot(git_dir_name);
            const p = try allocator.create(Mem);
            p.* = chrooted;
            // Transfer walk_owned as worktree ownership when we walked parents.
            const owned_wt = walk_owned;
            walk_owned = null;
            return .{
                .dot = p,
                .owned_dot = p,
                .owned_worktree = owned_wt,
                .worktree = search,
            };
        }

        // `.git` is a file → `gitdir: <path>`
        const target = try readGitDirFile(allocator, search);
        defer allocator.free(target);

        const chrooted = search.chroot(target) catch |err| switch (err) {
            error.NotExist, error.NotDir, error.CrossedBoundary => return error.RepositoryNotExists,
            else => |e| return e,
        };
        const p = try allocator.create(Mem);
        p.* = chrooted;
        const owned_wt = walk_owned;
        walk_owned = null;
        return .{
            .dot = p,
            .owned_dot = p,
            .owned_worktree = owned_wt,
            .worktree = search,
        };
    }
}

fn tryParentMem(allocator: Allocator, cur: *Mem) !?Mem {
    _ = allocator;
    const root = cur.root();
    if (root.len <= 1) return null;
    var i = root.len - 1;
    while (i > 0 and root[i] != '/') : (i -= 1) {}
    const parent_path = if (i == 0) "/" else root[0..i];
    return cur.chroot(parent_path) catch return null;
}

fn readGitDirFile(allocator: Allocator, fs: *Mem) ![]u8 {
    var f = try fs.open(git_dir_name);
    defer f.close() catch {};
    const data = try readAll(allocator, &f);
    errdefer allocator.free(data);

    const prefix = "gitdir: ";
    if (!std.mem.startsWith(u8, data, prefix)) return error.InvalidGitDirFile;

    var rest: []const u8 = data[prefix.len..];
    if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| rest = rest[0..nl];
    rest = std.mem.trim(u8, rest, " \t\r");
    if (rest.len == 0) return error.InvalidGitDirFile;

    const out = try allocator.dupe(u8, rest);
    allocator.free(data);
    return out;
}

fn readAll(allocator: Allocator, file: anytype) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [512]u8 = undefined;
    while (true) {
        const n = try file.read(buf[0..]);
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
    }
    return try list.toOwnedSlice(allocator);
}

fn freeFsRef(allocator: Allocator, ref: Reference) void {
    dotgit.freeRef(allocator, ref);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "PlainInit non-bare creates .git layout and HEAD" {
    const gpa = std.testing.allocator;
    var root = try Mem.init(gpa);
    defer root.deinit();

    var r = try plainInit(gpa, &root, false);
    defer r.deinit();

    try std.testing.expect(!r.isBare());
    try std.testing.expect(r.worktree != null);

    // Layout under .git
    _ = try root.stat(".git/objects/info");
    _ = try root.stat(".git/refs/heads");

    const head_ref = try r.reference(plumbing.HEAD, false);
    defer r.freeReference(head_ref);
    try std.testing.expect(head_ref.type == .symbolic);
    try std.testing.expectEqualStrings(plumbing.master.raw, head_ref.target.raw);

    const cfg = try r.config();
    try std.testing.expect(!cfg.is_bare);
}

test "PlainInit bare sets is_bare and layout at root" {
    const gpa = std.testing.allocator;
    var root = try Mem.init(gpa);
    defer root.deinit();

    var r = try plainInit(gpa, &root, true);
    defer r.deinit();

    try std.testing.expect(r.isBare());
    _ = try root.stat("objects/pack");
    _ = try root.stat("refs/tags");

    const cfg = try r.config();
    try std.testing.expect(cfg.is_bare);
}

test "PlainOpen after PlainInit works" {
    const gpa = std.testing.allocator;
    var root = try Mem.init(gpa);
    defer root.deinit();

    {
        var r = try plainInit(gpa, &root, false);
        r.deinit();
    }

    var r = try plainOpen(gpa, &root);
    defer r.deinit();
    try std.testing.expect(!r.isBare());

    const head_ref = try r.reference(plumbing.HEAD, false);
    defer r.freeReference(head_ref);
    try std.testing.expectEqualStrings(plumbing.master.raw, head_ref.target.raw);
}

test "PlainOpen EnableDotGitCommonDir routes local HEAD and common storage" {
    const gpa = std.testing.allocator;
    var root = try Mem.init(gpa);
    defer root.deinit();

    {
        var initialized = try plainInit(gpa, &root, false);
        initialized.deinit();
    }
    {
        var opened = try plainOpenWithOptions(gpa, &root, .{
            .enable_dot_git_common_dir = true,
        });
        opened.deinit();
    }

    var f = try root.create(".git/commondir");
    _ = try f.write("../common\n");
    try f.close();
    // A declared but missing common directory is an incomplete repository.
    try std.testing.expectError(
        error.RepositoryIncomplete,
        plainOpenWithOptions(gpa, &root, .{ .enable_dot_git_common_dir = true }),
    );

    try root.mkdirAll("common", fs_pkg.Mode.dir);
    var common_fs = try root.chroot("common");
    defer common_fs.deinit();
    const common_head = plumbing.newHash("2222222222222222222222222222222222222222");
    {
        var common_repo = try plainInit(gpa, &common_fs, true);
        try common_repo.storer.setReference(
            Reference.newHashReference(plumbing.master, common_head),
        );
        const common_cfg = try common_repo.config();
        try common_cfg.setUser("Common User", "common@example.com");
        try common_repo.setConfig(common_cfg);
        common_repo.deinit();
    }

    var linked = try plainOpenWithOptions(gpa, &root, .{
        .enable_dot_git_common_dir = true,
    });
    defer linked.deinit();
    try std.testing.expect(linked.local_storer != null);
    const unresolved = try linked.reference(plumbing.HEAD, false);
    defer linked.freeReference(unresolved);
    try std.testing.expect(unresolved.type == .symbolic);
    const resolved_head = try linked.head();
    defer linked.freeReference(resolved_head);
    try std.testing.expect(resolved_head.hash.eql(common_head));
    const cfg = try linked.config();
    try std.testing.expectEqualStrings("Common User", cfg.user_name);
}

test "PlainOpen missing returns RepositoryNotExists" {
    const gpa = std.testing.allocator;
    var root = try Mem.init(gpa);
    defer root.deinit();

    try std.testing.expectError(error.RepositoryNotExists, plainOpen(gpa, &root));
}

test "PlainInit already exists" {
    const gpa = std.testing.allocator;
    var root = try Mem.init(gpa);
    defer root.deinit();

    var r = try plainInit(gpa, &root, true);
    r.deinit();

    try std.testing.expectError(error.RepositoryAlreadyExists, plainInit(gpa, &root, true));
}

test "PlainInitWithOptions custom default branch" {
    const gpa = std.testing.allocator;
    var root = try Mem.init(gpa);
    defer root.deinit();

    var r = try plainInitWithOptions(gpa, &root, .{
        .bare = false,
        .init_options = .{ .default_branch = ReferenceName.init("refs/heads/main") },
    });
    defer r.deinit();

    const head_ref = try r.reference(plumbing.HEAD, false);
    defer r.freeReference(head_ref);
    try std.testing.expectEqualStrings("refs/heads/main", head_ref.target.raw);
}

test "PlainInitWithOptions rejects invalid object_format" {
    const gpa = std.testing.allocator;
    defer hash_algo.setObjectFormat(.sha1);

    var root = try Mem.init(gpa);
    defer root.deinit();

    try std.testing.expectError(
        error.InvalidObjectFormat,
        plainInitWithOptions(gpa, &root, .{
            .bare = true,
            .object_format = "md5",
        }),
    );
}

test "PlainInitWithOptions SHA256 succeeds" {
    const gpa = std.testing.allocator;
    defer hash_algo.setObjectFormat(.sha1);

    var root = try Mem.init(gpa);
    defer root.deinit();

    var r = try plainInitWithOptions(gpa, &root, .{
        .bare = true,
        .object_format = format_config.SHA256,
    });
    defer r.deinit();

    try std.testing.expect(hash_algo.objectFormat() == .sha256);
    try std.testing.expectEqual(@as(usize, 32), hash_algo.digestSize());

    const cfg = try r.config();
    try std.testing.expectEqualStrings(format_config.Version1, cfg.repository_format_version);
    try std.testing.expectEqualStrings(format_config.SHA256, cfg.object_format);

    // On-disk config contains extensions.objectformat
    var f = try root.open("config");
    defer f.close() catch {};
    const data = try readAll(gpa, &f);
    defer gpa.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "objectformat = sha256") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "repositoryformatversion = 1") != null);

    // Empty blob OID is SHA-256 of "blob 0\0"
    const empty_blob = plumbing.computeHash(.blob, "");
    try std.testing.expectEqual(@as(usize, 32), empty_blob.slice().len);
    var hex_buf: [plumbing.MaxHexSize]u8 = undefined;
    const hex = empty_blob.string(&hex_buf);
    try std.testing.expectEqualStrings(
        "473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813",
        hex,
    );

    // Store via filesystem storage (ObjectWriter uses utils/sync zlib pool).
    const obj = try r.storer.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write("");
    const h = try r.storer.setEncodedObject(obj);
    try std.testing.expect(h.eql(empty_blob));
    try std.testing.expectEqual(@as(usize, 32), h.slice().len);

    const path = try r.storer.dir.objectPath(h);
    defer gpa.free(path);
    try std.testing.expect(std.mem.indexOf(u8, path, "objects/47/") != null);
    _ = try root.stat(path);

    // Drain free-lists so testing.allocator does not report retained pool nodes.
    utils_sync.deinitPools(gpa);
}

test "PlainOpen applies SHA256 object format from config" {
    const gpa = std.testing.allocator;
    defer hash_algo.setObjectFormat(.sha1);

    var root = try Mem.init(gpa);
    defer root.deinit();

    {
        var r = try plainInitWithOptions(gpa, &root, .{
            .bare = true,
            .object_format = format_config.SHA256,
        });
        r.deinit();
    }

    // Reset to sha1 then open must re-activate sha256 from config.
    hash_algo.setObjectFormat(.sha1);
    var r = try plainOpen(gpa, &root);
    defer r.deinit();
    try std.testing.expect(hash_algo.objectFormat() == .sha256);
}

test "PlainOpen bare after PlainInit bare" {
    const gpa = std.testing.allocator;
    var root = try Mem.init(gpa);
    defer root.deinit();

    {
        var r = try plainInit(gpa, &root, true);
        r.deinit();
    }

    var r = try plainOpen(gpa, &root);
    defer r.deinit();
    try std.testing.expect(r.isBare());
}

test "PlainRepository.repackObjects packs loose commit" {
    const gpa = std.testing.allocator;
    defer utils_sync.deinitPools(gpa);

    var root = try Mem.init(gpa);
    defer root.deinit();

    var r = try plainInit(gpa, &root, true);
    defer r.deinit();

    const s = r.storer;
    const blob_obj = try s.newEncodedObject();
    blob_obj.setType(.blob);
    _ = try blob_obj.write("plain-repack");
    const blob_h = try s.setEncodedObject(blob_obj);

    var tbuf: std.ArrayList(u8) = .empty;
    defer tbuf.deinit(gpa);
    try tbuf.appendSlice(gpa, "100644 f.txt\x00");
    try tbuf.appendSlice(gpa, blob_h.slice());
    const tree_obj = try s.newEncodedObject();
    tree_obj.setType(.tree);
    _ = try tree_obj.write(tbuf.items);
    const tree_h = try s.setEncodedObject(tree_obj);

    var cbuf: std.ArrayList(u8) = .empty;
    defer cbuf.deinit(gpa);
    var tree_hex: [plumbing.MaxHexSize]u8 = undefined;
    try cbuf.appendSlice(gpa, "tree ");
    try cbuf.appendSlice(gpa, tree_h.string(&tree_hex));
    try cbuf.appendSlice(gpa, "\nauthor T <t@e.com> 1 +0000\ncommitter T <t@e.com> 1 +0000\n\nm\n");
    const commit_obj = try s.newEncodedObject();
    commit_obj.setType(.commit);
    _ = try commit_obj.write(cbuf.items);
    const commit_h = try s.setEncodedObject(commit_obj);

    try s.setReference(Reference.newHashReference(plumbing.master, commit_h));

    const cfg = RepackConfig{};
    try r.repackObjects(&cfg);

    const Count = struct {
        n: usize = 0,
        fn cb(self: *@This(), _: plumbing.Hash) anyerror!void {
            self.n += 1;
        }
    };
    var loose = Count{};
    try s.forEachObjectHash(&loose, Count.cb);
    try std.testing.expectEqual(@as(usize, 0), loose.n);

    const packs = try s.objectPacks();
    defer dotgit.freeHashes(s.allocator, packs);
    try std.testing.expectEqual(@as(usize, 1), packs.len);

    try s.hasEncodedObject(commit_h);
    const got = try s.encodedObject(.blob, blob_h);
    try std.testing.expectEqualStrings("plain-repack", got.readerBytes());
}
