//! PlainInit / PlainOpen — filesystem-backed repository lifecycle (go-git root).
//!
//! Hermetic path uses `fs.Mem` + `//src/storage/filesystem` (no host `Os` required
//! for tests). Host `Os` can follow the same flow via `filesystem.newStorageOs`.
//!
//! Out of scope: PlainClone, EnableDotGitCommonDir (stub flag ignored).

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");
const filesystem = @import("filesystem");
const fs_pkg = @import("fs");
const format_config = @import("config");
const storer = @import("storer");
const dotgit = @import("dotgit");

const repository = @import("repository.zig");
const error_mod = @import("error.zig");

const Allocator = std.mem.Allocator;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const Config = memory.Config;
const Mem = fs_pkg.Mem;

pub const Error = error_mod.Error;
pub const git_dir_name = repository.git_dir_name;
pub const InitOptions = repository.InitOptions;

/// go-git `PlainInitOptions`.
pub const PlainInitOptions = struct {
    /// Embedded init options (default branch).
    init_options: InitOptions = .{},
    /// Bare repository (no worktree).
    bare: bool = false,
    /// Object hash format (`""` / `"sha1"` default; `"sha256"` → `SHA256NotSupported`).
    object_format: []const u8 = "",
};

/// go-git `PlainOpenOptions`.
pub const PlainOpenOptions = struct {
    /// Walk parent directories until `.git` is found.
    detect_dot_git: bool = false,
    /// `.git/commondir` support — stubbed (ignored; not implemented).
    enable_dot_git_common_dir: bool = false,
};

/// Filesystem-backed repository (go-git `Repository` over filesystem storage).
///
/// Owns the storage and any chroot `Mem` created for `.git` / detect walks.
/// Does **not** own the caller's original worktree / bare root `Mem`.
pub const PlainRepository = struct {
    allocator: Allocator,
    storer: *filesystem.StorageMem,
    /// Owned chroot into `.git` (non-bare) or into a `gitdir:` target.
    owned_dot: ?*Mem = null,
    /// Owned worktree chroot when DetectDotGit walked to a parent.
    owned_worktree: ?*Mem = null,
    /// Worktree FS; null when bare. May equal `owned_worktree` or caller's Mem.
    worktree: ?*Mem = null,

    pub fn deinit(self: *PlainRepository) void {
        self.storer.deinit();
        self.allocator.destroy(self.storer);
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

    pub fn config(self: *PlainRepository) !*Config {
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

    /// Unresolved reference lookup. FS refs are owned — free with `freeReference`.
    pub fn reference(self: *PlainRepository, name: ReferenceName, resolved: bool) !Reference {
        if (resolved) return storer.resolveReference(self.storer, name);
        return self.storer.reference(name);
    }

    /// Free a reference returned by `reference` / `head` on this backend.
    pub fn freeReference(self: *const PlainRepository, ref: Reference) void {
        dotgit.freeRef(self.allocator, ref);
    }

    pub fn head(self: *PlainRepository) !Reference {
        return storer.resolveReference(self.storer, plumbing.HEAD);
    }
};

// ---------------------------------------------------------------------------
// PlainInit
// ---------------------------------------------------------------------------

/// go-git `PlainInit` — empty repo at the root of `path_fs`.
pub fn plainInit(allocator: Allocator, path_fs: *Mem, is_bare: bool) !PlainRepository {
    return plainInitWithOptions(allocator, path_fs, .{ .bare = is_bare });
}

/// go-git `PlainInitWithOptions` over `fs.Mem`.
pub fn plainInitWithOptions(allocator: Allocator, path_fs: *Mem, opts: PlainInitOptions) !PlainRepository {
    if (opts.object_format.len > 0 and std.mem.eql(u8, opts.object_format, format_config.SHA256)) {
        return error.SHA256NotSupported;
    }

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

    const s = try filesystem.newStorage(allocator, dot_fs, null);
    errdefer {
        s.deinit();
        allocator.destroy(s);
    }

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

    if (worktree == null) {
        const cfg = try s.config();
        cfg.is_bare = true;
        try s.setConfig(cfg);
    }

    // ObjectFormat: only SHA-256 is rejected above; SHA-1 is the default.
    _ = opts.object_format;

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
    // CommonDir support is a residual stub.
    _ = o.enable_dot_git_common_dir;

    var resolved = try resolveDotGitMem(allocator, path_fs, o.detect_dot_git);
    errdefer resolved.deinitOwned(allocator);

    const s = try filesystem.newStorage(allocator, resolved.dot, null);
    errdefer {
        s.deinit();
        allocator.destroy(s);
    }

    // Open: HEAD must exist
    if (s.reference(plumbing.HEAD)) |ref| {
        freeFsRef(allocator, ref);
    } else |err| switch (err) {
        error.ReferenceNotFound => return error.RepositoryNotExists,
        else => |e| return e,
    }

    _ = try s.config();

    const r = PlainRepository{
        .allocator = allocator,
        .storer = s,
        .owned_dot = resolved.owned_dot,
        .owned_worktree = resolved.owned_worktree,
        .worktree = resolved.worktree,
    };
    resolved.owned_dot = null;
    resolved.owned_worktree = null;
    return r;
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

test "PlainInitWithOptions SHA256 not supported" {
    const gpa = std.testing.allocator;
    var root = try Mem.init(gpa);
    defer root.deinit();

    try std.testing.expectError(
        error.SHA256NotSupported,
        plainInitWithOptions(gpa, &root, .{
            .bare = true,
            .object_format = format_config.SHA256,
        }),
    );
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
