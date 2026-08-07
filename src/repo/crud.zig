//! Repository config/ref CRUD — remotes, branches, tags, Worktree probe.
//!
//! Port of go-git `repository.go` methods that do **not** need network or a full
//! Worktree engine. Methods take `*Repository` from `repository.zig`.

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");
const objpkg = @import("object");

const repository_mod = @import("repository.zig");
const remote_mod = @import("remote.zig");
const error_mod = @import("error.zig");

const Allocator = std.mem.Allocator;
const Repository = repository_mod.Repository;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const Hash = plumbing.Hash;
const Remote = remote_mod.Remote;

// ---------------------------------------------------------------------------
// CreateTag options
// ---------------------------------------------------------------------------

/// go-git `CreateTagOptions` (unsigned annotated tags; no OpenPGP).
pub const CreateTagOptions = struct {
    /// Required for annotated tags.
    tagger: objpkg.Signature = .{},
    message: []const u8 = "",
};

// ---------------------------------------------------------------------------
// Worktree probe
// ---------------------------------------------------------------------------

/// go-git `Repository.Worktree` — returns the worktree FS or bare error.
///
/// Full Worktree type (status/add/commit) is phase 12; this only exposes the
/// attached `?*fs.Mem` handle when non-bare.
pub fn worktreeFs(self: *Repository) error{IsBareRepository}!*@import("fs").Mem {
    return self.worktree orelse error.IsBareRepository;
}

// ---------------------------------------------------------------------------
// Remotes (config-only; no fetch/push)
// ---------------------------------------------------------------------------

/// go-git `Repository.Remote`.
pub fn remote(self: *Repository, name: []const u8) !Remote {
    const cfg = try self.config();
    const c = cfg.remotes.getPtr(name) orelse return error.RemoteNotFound;
    return remote_mod.newRemote(self.storer, c);
}

/// go-git `Repository.Remotes` — heap slice of Remote handles; caller frees the slice only.
pub fn remotes(self: *Repository, allocator: Allocator) ![]Remote {
    const cfg = try self.config();
    const out = try allocator.alloc(Remote, cfg.remotes.count());
    var i: usize = 0;
    var it = cfg.remotes.iterator();
    while (it.next()) |e| {
        out[i] = remote_mod.newRemote(self.storer, e.value_ptr);
        i += 1;
    }
    return out;
}

/// go-git `Repository.CreateRemote` — validates and inserts into config.
///
/// Does not return a network-capable remote (phase 11). Returns a thin handle.
pub fn createRemote(
    self: *Repository,
    name: []const u8,
    urls: []const []const u8,
) !Remote {
    return createRemoteFull(self, name, urls, &.{}, false);
}

/// CreateRemote with fetch refspecs and mirror.
pub fn createRemoteFull(
    self: *Repository,
    name: []const u8,
    urls: []const []const u8,
    fetch: []const []const u8,
    mirror: bool,
) !Remote {
    if (name.len == 0) return error.RemoteConfigEmptyName;
    if (urls.len == 0) return error.RemoteConfigEmptyURL;

    const cfg = try self.config();
    if (cfg.remotes.contains(name)) return error.RemoteExists;
    try cfg.putRemoteFull(name, urls, fetch, mirror);
    try self.setConfig(cfg);
    const c = cfg.remotes.getPtr(name).?;
    return remote_mod.newRemote(self.storer, c);
}

/// go-git CreateRemoteAnonymous: ephemeral remote **not** written to config.
/// Caller frees via `AnonymousRemote.deinit`.
pub const AnonymousRemote = struct {
    remote: Remote,
    owned: *memory.RemoteConfig,
    allocator: Allocator,

    pub fn deinit(self: *AnonymousRemote) void {
        self.owned.deinit(self.allocator);
        self.allocator.destroy(self.owned);
        self.* = undefined;
    }
};

/// go-git `Repository.CreateRemoteAnonymous` (name is always `"anonymous"`).
pub fn createRemoteAnonymous(
    self: *Repository,
    allocator: Allocator,
    urls: []const []const u8,
) !AnonymousRemote {
    if (urls.len == 0) return error.RemoteConfigEmptyURL;
    const rc = try allocator.create(memory.RemoteConfig);
    errdefer allocator.destroy(rc);
    rc.* = .{};
    rc.name = try allocator.dupe(u8, "anonymous");
    errdefer allocator.free(rc.name);
    rc.urls = try allocator.alloc([]u8, urls.len);
    errdefer {
        for (rc.urls) |u| allocator.free(u);
        allocator.free(rc.urls);
    }
    for (urls, 0..) |u, i| {
        rc.urls[i] = try allocator.dupe(u8, u);
    }
    try rc.validate();
    return .{
        .remote = remote_mod.newRemote(self.storer, rc),
        .owned = rc,
        .allocator = allocator,
    };
}

/// go-git `Repository.DeleteRemote`.
pub fn deleteRemote(self: *Repository, name: []const u8) !void {
    const cfg = try self.config();
    if (!cfg.removeRemote(name)) return error.RemoteNotFound;
    try self.setConfig(cfg);
}

// ---------------------------------------------------------------------------
// Branches (config tracking entries — not ref creation)
// ---------------------------------------------------------------------------

/// go-git `Repository.Branch` — tracking config entry.
pub fn branch(self: *Repository, name: []const u8) !*const memory.BranchConfig {
    const cfg = try self.config();
    return cfg.branches.getPtr(name) orelse error.BranchNotFound;
}

/// go-git `Repository.CreateBranch`.
pub fn createBranch(
    self: *Repository,
    name: []const u8,
    remote_name: []const u8,
    merge: []const u8,
) !void {
    if (name.len == 0) return error.BranchEmptyName;
    const cfg = try self.config();
    if (cfg.branches.contains(name)) return error.BranchExists;
    try cfg.putBranch(name, remote_name, merge);
    try self.setConfig(cfg);
}

/// go-git `Repository.DeleteBranch`.
pub fn deleteBranch(self: *Repository, name: []const u8) !void {
    const cfg = try self.config();
    if (!cfg.removeBranch(name)) return error.BranchNotFound;
    try self.setConfig(cfg);
}

// ---------------------------------------------------------------------------
// Tags
// ---------------------------------------------------------------------------

/// go-git `Repository.Tag` — lightweight or annotated tag *reference*.
pub fn tag(self: *Repository, name: []const u8) !Reference {
    var buf: [256]u8 = undefined;
    const rname = plumbing.newTagReferenceName(name, &buf) catch return error.InvalidReferenceName;
    try rname.validate();
    return self.storer.reference(rname) catch |err| switch (err) {
        error.ReferenceNotFound => error.TagNotFound,
        else => |e| e,
    };
}

/// go-git `Repository.CreateTag` — lightweight when `opts == null`; annotated otherwise (no PGP).
pub fn createTag(
    self: *Repository,
    name: []const u8,
    hash: Hash,
    opts: ?CreateTagOptions,
) !Reference {
    var buf: [256]u8 = undefined;
    const rname = plumbing.newTagReferenceName(name, &buf) catch return error.InvalidReferenceName;
    try rname.validate();

    if (self.storer.reference(rname)) |_| {
        return error.TagExists;
    } else |err| switch (err) {
        error.ReferenceNotFound => {},
        else => |e| return e,
    }

    const target: Hash = if (opts) |o| blk: {
        if (o.tagger.name.len == 0 and o.tagger.email.len == 0) return error.MissingTagger;
        break :blk try createAnnotatedTagObject(self, name, hash, o);
    } else hash;

    // setReference duplicates the name; stack buffer is fine for the call.
    const ref = Reference.newHashReference(rname, target);
    try self.storer.setReference(ref);
    return try self.storer.reference(rname);
}

fn createAnnotatedTagObject(
    self: *Repository,
    name: []const u8,
    hash: Hash,
    opts: CreateTagOptions,
) !Hash {
    const gpa = self.storer.allocator;
    const storer_pkg = @import("storer");
    const enc = try self.storer.encodedObject(.any, hash);

    var tag_obj = objpkg.Tag.init(gpa);
    defer tag_obj.deinit();
    tag_obj.name = try gpa.dupe(u8, name);
    tag_obj.message = try gpa.dupe(u8, opts.message);
    tag_obj.tagger = .{
        .name = try gpa.dupe(u8, opts.tagger.name),
        .email = try gpa.dupe(u8, opts.tagger.email),
        .when = opts.tagger.when,
        .tz_offset_minutes = opts.tagger.tz_offset_minutes,
    };
    tag_obj.target_type = enc.object_type;
    tag_obj.target = hash;
    tag_obj.storage = storer_pkg.ObjectGetter.from(@TypeOf(self.storer.*), self.storer);

    const out = try self.storer.newEncodedObject();
    try tag_obj.encode(out);
    return try self.storer.setEncodedObject(out);
}

/// go-git `Repository.DeleteTag`.
pub fn deleteTag(self: *Repository, name: []const u8) !void {
    _ = try tag(self, name);
    var buf: [256]u8 = undefined;
    const rname = plumbing.newTagReferenceName(name, &buf) catch return error.InvalidReferenceName;
    self.storer.removeReference(rname);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "createRemote deleteRemote remote" {
    const gpa = std.testing.allocator;
    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    var r = try repository_mod.init(s, null);

    const rem = try createRemote(&r, "origin", &[_][]const u8{"https://example.com/r.git"});
    try std.testing.expectEqualStrings("origin", rem.name());

    try std.testing.expectError(error.RemoteExists, createRemote(&r, "origin", &[_][]const u8{"x"}));

    const got = try remote(&r, "origin");
    try std.testing.expectEqualStrings("origin", got.name());

    try deleteRemote(&r, "origin");
    try std.testing.expectError(error.RemoteNotFound, remote(&r, "origin"));
}

test "createBranch deleteBranch" {
    const gpa = std.testing.allocator;
    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    var r = try repository_mod.init(s, null);

    try createBranch(&r, "main", "origin", "refs/heads/main");
    const b = try branch(&r, "main");
    try std.testing.expectEqualStrings("origin", b.remote);
    try std.testing.expectError(error.BranchExists, createBranch(&r, "main", "o", "m"));
    try deleteBranch(&r, "main");
    try std.testing.expectError(error.BranchNotFound, branch(&r, "main"));
}

test "createTag lightweight and deleteTag" {
    const gpa = std.testing.allocator;
    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    var r = try repository_mod.init(s, null);

    // Empty blob as tag target.
    const blob = try s.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write("x");
    const h = try s.setEncodedObject(blob);

    const ref = try createTag(&r, "v1", h, null);
    try std.testing.expect(ref.hash.eql(h));
    try std.testing.expectError(error.TagExists, createTag(&r, "v1", h, null));

    const t = try tag(&r, "v1");
    try std.testing.expect(t.hash.eql(h));

    try deleteTag(&r, "v1");
    try std.testing.expectError(error.TagNotFound, tag(&r, "v1"));
}

test "worktreeFs bare vs non-bare" {
    const gpa = std.testing.allocator;
    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    var bare = try repository_mod.init(s, null);
    try std.testing.expectError(error.IsBareRepository, worktreeFs(&bare));

    const s2 = try memory.newStorage(gpa);
    defer {
        s2.deinit();
        gpa.destroy(s2);
    }
    var wt = try @import("fs").Mem.init(gpa);
    defer wt.deinit();
    var r = try repository_mod.init(s2, &wt);
    const got = try worktreeFs(&r);
    try std.testing.expect(got == &wt);
}

test "createRemoteAnonymous not stored" {
    const gpa = std.testing.allocator;
    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    var r = try repository_mod.init(s, null);
    var anon = try createRemoteAnonymous(&r, gpa, &[_][]const u8{"git@h:r.git"});
    defer anon.deinit();
    try std.testing.expectEqualStrings("anonymous", anon.remote.name());
    try std.testing.expectError(error.RemoteNotFound, remote(&r, "anonymous"));
}
