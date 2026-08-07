//! Repository Init/Open core (go-git root `repository.go` subset).
//!
//! Memory-backed lifecycle for phase 10:
//! - `init` / `initWithOptions` / `open` over `*memory.Storage`
//! - optional worktree: `?*fs.Mem` (null = bare)
//! - head / config / setConfig / reference helpers
//!
//! Storer config remains `memory.Config` (storage backends write that shape).
//! Typed `gitconfig.Config` (`//src/config`) is the high-level go-git config
//! model for remotes/branches/URLs; bridging storer Config ↔ gitconfig is a
//! later polish (phase 11 remotes will need it).
//!
//! PlainInit/PlainOpen (host path + filesystem storage) are deferred until a
//! shared storer façade owns both memory and filesystem backends.

const std = @import("std");
const plumbing = @import("plumbing");
const storer = @import("storer");
const memory = @import("memory");
const fs_pkg = @import("fs");

const error_mod = @import("error.zig");
const facade = @import("facade.zig");
const objpkg = @import("object");

const Allocator = std.mem.Allocator;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const Config = memory.Config;

pub const LogOptions = facade.LogOptions;
pub const LogOrder = facade.LogOrder;
pub const LogResult = facade.LogResult;

pub const Error = error_mod.Error;

/// go-git `GitDirName` — special folder where all the git stuff is.
pub const git_dir_name = ".git";

/// go-git `InitOptions`.
pub const InitOptions = struct {
    /// Default branch (e.g. `refs/heads/master`). Empty → `plumbing.master`.
    default_branch: ReferenceName = plumbing.master,
};

/// Git repository (go-git `Repository` subset: storer + optional worktree).
///
/// Does **not** own `storer` or `worktree`. Caller allocates and frees them.
pub const Repository = struct {
    /// Repository object storage and refs (go-git `Storer`).
    storer: *memory.Storage,
    /// Optional worktree filesystem; null means bare.
    worktree: ?*fs_pkg.Mem = null,

    // -----------------------------------------------------------------------
    // Config
    // -----------------------------------------------------------------------

    /// go-git `Repository.Config` — return repository config from the storer.
    pub fn config(self: *Repository) Allocator.Error!*Config {
        return self.storer.config();
    }

    /// go-git `Repository.SetConfig` — write repository config via the storer.
    /// Takes ownership of `cfg` on success (memory.ConfigStorage contract).
    pub fn setConfig(self: *Repository, cfg: *Config) (Allocator.Error || memory.ConfigError)!void {
        return self.storer.setConfig(cfg);
    }

    // -----------------------------------------------------------------------
    // References
    // -----------------------------------------------------------------------

    /// go-git `Repository.Head` — resolve HEAD to a hash reference.
    pub fn head(self: *const Repository) !Reference {
        return storer.resolveReference(self.storer, plumbing.HEAD);
    }

    /// go-git `Repository.Reference`.
    /// When `resolved` is true, symbolic refs are resolved to a hash ref.
    pub fn reference(self: *const Repository, name: ReferenceName, resolved: bool) !Reference {
        if (resolved) return storer.resolveReference(self.storer, name);
        return self.storer.reference(name);
    }

    /// go-git `Repository.References` — unsorted iterator over all references.
    pub fn references(self: *const Repository) Allocator.Error!memory.ReferenceSliceIter {
        return self.storer.iterReferences();
    }

    // -----------------------------------------------------------------------
    // Worktree probe (thin; full Worktree type is phase 12)
    // -----------------------------------------------------------------------

    /// Whether this repository has a worktree filesystem attached.
    pub fn isBare(self: *const Repository) bool {
        return self.worktree == null;
    }

    /// go-git `setIsBare` — set `core.bare` in config.
    pub fn setIsBare(self: *Repository, bare: bool) (Allocator.Error || memory.ConfigError)!void {
        const cfg = try self.config();
        cfg.is_bare = bare;
        try self.setConfig(cfg);
    }

    // -----------------------------------------------------------------------
    // Object getters, Log, ResolveRevision, Branches/Tags/Notes
    // -----------------------------------------------------------------------

    pub fn commitObject(self: *Repository, h: plumbing.Hash) !*objpkg.Commit {
        return facade.commitObject(self.storer, h);
    }
    pub fn blobObject(self: *Repository, h: plumbing.Hash) !objpkg.Blob {
        return facade.blobObject(self.storer, h);
    }
    pub fn treeObject(self: *Repository, h: plumbing.Hash) !*objpkg.Tree {
        return facade.treeObject(self.storer, h);
    }
    pub fn tagObject(self: *Repository, h: plumbing.Hash) !objpkg.Tag {
        return facade.tagObject(self.storer, h);
    }
    pub fn object(self: *Repository, t: plumbing.ObjectType, h: plumbing.Hash) !objpkg.Object {
        return facade.object(self.storer, t, h);
    }
    pub fn commitObjects(self: *Repository) !facade.EncodedCommitIter {
        return facade.commitObjects(self.storer);
    }
    pub fn blobObjects(self: *Repository) !facade.BlobObjectsIter {
        return facade.blobObjects(self.storer);
    }
    pub fn treeObjects(self: *Repository) !objpkg.TreeIter {
        return facade.treeObjects(self.storer);
    }
    pub fn tagObjects(self: *Repository) !facade.TagObjectsIter {
        return facade.tagObjects(self.storer);
    }
    pub fn objects(self: *Repository) !facade.ObjectsIter {
        return facade.objects(self.storer);
    }
    pub fn branches(self: *Repository) !facade.FilteredRefIter {
        return facade.branches(self.storer);
    }
    pub fn tags(self: *Repository) !facade.FilteredRefIter {
        return facade.tags(self.storer);
    }
    pub fn notes(self: *Repository) !facade.FilteredRefIter {
        return facade.notes(self.storer);
    }
    pub fn log(self: *Repository, opts: LogOptions) !LogResult {
        return facade.log(self.storer, opts);
    }
    pub fn resolveRevision(self: *Repository, rev: []const u8) !plumbing.Hash {
        return facade.resolveRevision(self.storer, rev);
    }
};

// ---------------------------------------------------------------------------
// Construction
// ---------------------------------------------------------------------------

/// go-git `newRepository`.
pub fn newRepository(s: *memory.Storage, worktree: ?*fs_pkg.Mem) Repository {
    return .{
        .storer = s,
        .worktree = worktree,
    };
}

/// go-git `Init` — create an empty repository. `worktree == null` → bare.
/// If the storer already has HEAD, returns `error.RepositoryAlreadyExists`.
pub fn init(s: *memory.Storage, worktree: ?*fs_pkg.Mem) !Repository {
    return initWithOptions(s, worktree, .{});
}

/// go-git `InitWithOptions`.
///
/// go-git calls storer `Initializer` when present; `memory.Storage` has none
/// (type assert fails → no-op). Filesystem layout init lands with PlainInit.
pub fn initWithOptions(s: *memory.Storage, worktree: ?*fs_pkg.Mem, options: InitOptions) !Repository {
    var opts = options;
    if (opts.default_branch.raw.len == 0) {
        opts.default_branch = plumbing.master;
    }
    try opts.default_branch.validate();

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

    // Load config (go-git Open always reads config; verifyExtensions is a no-op
    // until typed gitconfig extensions are ported).
    _ = try s.config();

    return newRepository(s, worktree);
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
    try std.testing.expect(r.worktree != null);

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
    try std.testing.expect(r.worktree == &wt2);
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
    var tree_hex: [plumbing.HexSize]u8 = undefined;
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
