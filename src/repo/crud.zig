//! Repository config/ref CRUD helpers (go-git `repository.go` non-network surface).
//!
//! Free functions take `*memory.Storage` so this module does **not** import
//! `repository.zig` (no cycle). `Repository` methods are thin wrappers.

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");
const objpkg = @import("object");
const storer_pkg = @import("storer");

const remote_mod = @import("remote.zig");

const Allocator = std.mem.Allocator;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const Hash = plumbing.Hash;
const Remote = remote_mod.Remote;

/// go-git `CreateTagOptions`.
///
/// When `sign_key` is set, the tag is signed with OpenPGP `ArmoredDetachSign`
/// (go-git `SignKey *openpgp.Entity`). That path takes precedence over a
/// pre-formed `pgp_signature`. Use `pgp_signature` alone to attach an already
/// armored block without an Entity.
pub const CreateTagOptions = struct {
    /// Who creates the tag (go-git `Tagger`). Require non-empty name or email;
    /// go-git may load Author/User via ConfigScoped when Tagger is nil — not done
    /// here (`memory.Config` has no identity fields).
    tagger: objpkg.Signature = .{},
    /// Annotation body (go-git `Message`). Required; canonicalized on create
    /// (`TrimSpace` + trailing `\n`, same as go-git `Validate`).
    message: []const u8 = "",
    /// go-git `SignKey *openpgp.Entity`. When non-null, signs the unsigned tag
    /// encoding and stores the armored signature in `Tag.pgp_signature`.
    /// Entity must already be decrypted (`Entity.decrypt`).
    sign_key: ?*objpkg.Entity = null,
    /// Optional trailing armored signature block when not using `sign_key`.
    pgp_signature: ?[]const u8 = null,

    /// go-git `CreateTagOptions.Validate`.
    ///
    /// Requires non-empty tagger name or email, and a non-empty message.
    /// `store` and `hash` are accepted for API parity (go-git uses `r` for config load).
    pub fn validate(self: *const CreateTagOptions, store: *memory.Storage, hash: Hash) !void {
        _ = store;
        _ = hash;
        if (self.tagger.name.len == 0 and self.tagger.email.len == 0) return error.MissingTagger;
        if (self.message.len == 0) return error.MissingMessage;
    }
};

// ---------------------------------------------------------------------------
// Remotes (config-only; no fetch/push)
// ---------------------------------------------------------------------------

/// go-git `Repository.Remote`.
pub fn remote(store: *memory.Storage, name: []const u8) !Remote {
    const cfg = try store.config();
    const c = cfg.remotes.getPtr(name) orelse return error.RemoteNotFound;
    return remote_mod.newRemote(store, c);
}

/// go-git `Repository.Remotes` — caller frees the returned slice only.
pub fn remotes(store: *memory.Storage, allocator: Allocator) ![]Remote {
    const cfg = try store.config();
    const out = try allocator.alloc(Remote, cfg.remotes.count());
    var i: usize = 0;
    var it = cfg.remotes.iterator();
    while (it.next()) |e| {
        out[i] = remote_mod.newRemote(store, e.value_ptr);
        i += 1;
    }
    return out;
}

/// go-git `Repository.CreateRemote`.
pub fn createRemote(
    store: *memory.Storage,
    name: []const u8,
    urls: []const []const u8,
) !Remote {
    return createRemoteFull(store, name, urls, &.{}, false);
}

/// CreateRemote with fetch refspecs and mirror.
pub fn createRemoteFull(
    store: *memory.Storage,
    name: []const u8,
    urls: []const []const u8,
    fetch: []const []const u8,
    mirror: bool,
) !Remote {
    if (name.len == 0) return error.RemoteConfigEmptyName;
    if (urls.len == 0) return error.RemoteConfigEmptyURL;

    const cfg = try store.config();
    if (cfg.remotes.contains(name)) return error.RemoteExists;
    try cfg.putRemoteFull(name, urls, fetch, mirror);
    try store.setConfig(cfg);
    const c = cfg.remotes.getPtr(name).?;
    return remote_mod.newRemote(store, c);
}

/// Ephemeral anonymous remote **not** written to config (go-git CreateRemoteAnonymous).
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
    store: *memory.Storage,
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
        .remote = remote_mod.newRemote(store, rc),
        .owned = rc,
        .allocator = allocator,
    };
}

/// go-git `Repository.DeleteRemote`.
pub fn deleteRemote(store: *memory.Storage, name: []const u8) !void {
    const cfg = try store.config();
    if (!cfg.removeRemote(name)) return error.RemoteNotFound;
    try store.setConfig(cfg);
}

// ---------------------------------------------------------------------------
// Branches (config tracking — not ref creation)
// ---------------------------------------------------------------------------

/// go-git `Repository.Branch`.
pub fn branch(store: *memory.Storage, name: []const u8) !*const memory.BranchConfig {
    const cfg = try store.config();
    return cfg.branches.getPtr(name) orelse error.BranchNotFound;
}

/// go-git `Repository.CreateBranch`.
pub fn createBranch(
    store: *memory.Storage,
    name: []const u8,
    remote_name: []const u8,
    merge: []const u8,
) !void {
    if (name.len == 0) return error.BranchEmptyName;
    const cfg = try store.config();
    if (cfg.branches.contains(name)) return error.BranchExists;
    try cfg.putBranch(name, remote_name, merge);
    try store.setConfig(cfg);
}

/// go-git `Repository.DeleteBranch`.
pub fn deleteBranch(store: *memory.Storage, name: []const u8) !void {
    const cfg = try store.config();
    if (!cfg.removeBranch(name)) return error.BranchNotFound;
    try store.setConfig(cfg);
}

// ---------------------------------------------------------------------------
// Tags
// ---------------------------------------------------------------------------

/// go-git `Repository.Tag`.
pub fn tag(store: *memory.Storage, name: []const u8) !Reference {
    var buf: [256]u8 = undefined;
    const rname = plumbing.newTagReferenceName(name, &buf) catch return error.InvalidReferenceName;
    try rname.validate();
    return store.reference(rname) catch |err| switch (err) {
        error.ReferenceNotFound => error.TagNotFound,
        else => |e| e,
    };
}

/// go-git `Repository.CreateTag` — lightweight when `opts == null`; annotated otherwise.
pub fn createTag(
    store: *memory.Storage,
    name: []const u8,
    hash: Hash,
    opts: ?CreateTagOptions,
) !Reference {
    var buf: [256]u8 = undefined;
    const rname = plumbing.newTagReferenceName(name, &buf) catch return error.InvalidReferenceName;
    try rname.validate();

    if (store.reference(rname)) |_| {
        return error.TagExists;
    } else |err| switch (err) {
        error.ReferenceNotFound => {},
        else => |e| return e,
    }

    const target: Hash = if (opts) |o| blk: {
        try o.validate(store, hash);
        break :blk try createAnnotatedTagObject(store, name, hash, o);
    } else hash;

    const ref = Reference.newHashReference(rname, target);
    try store.setReference(ref);
    return try store.reference(rname);
}

fn createAnnotatedTagObject(
    store: *memory.Storage,
    name: []const u8,
    hash: Hash,
    opts: CreateTagOptions,
) !Hash {
    const gpa = store.allocator;
    const enc = try store.encodedObject(.any, hash);

    var tag_obj = objpkg.Tag.init(gpa);
    defer tag_obj.deinit();
    tag_obj.name = try gpa.dupe(u8, name);
    tag_obj.message = try canonicalizeTagMessage(gpa, opts.message);
    tag_obj.tagger = .{
        .name = try gpa.dupe(u8, opts.tagger.name),
        .email = try gpa.dupe(u8, opts.tagger.email),
        .when = opts.tagger.when,
        .tz_offset_minutes = opts.tagger.tz_offset_minutes,
    };
    tag_obj.target_type = enc.object_type;
    tag_obj.target = hash;
    tag_obj.storage = storer_pkg.ObjectGetter.from(memory.Storage, store);

    // go-git: sign the unsigned encoding, then attach PGPSignature and store.
    if (opts.sign_key) |key| {
        var encoded = plumbing.MemoryObject.init(gpa);
        defer encoded.deinit();
        try tag_obj.encodeWithoutSignature(&encoded);
        const message = encoded.readerBytes();
        tag_obj.pgp_signature = try objpkg.armoredDetachSign(gpa, key, message);
    } else if (opts.pgp_signature) |sig| {
        tag_obj.pgp_signature = try gpa.dupe(u8, sig);
    }

    const out = try store.newEncodedObject();
    try tag_obj.encode(out);
    return try store.setEncodedObject(out);
}

/// go-git `CreateTagOptions.Validate` message canonicalize: `TrimSpace(msg) + "\n"`.
fn canonicalizeTagMessage(allocator: Allocator, message: []const u8) Allocator.Error![]u8 {
    const trimmed = std.mem.trim(u8, message, &std.ascii.whitespace);
    const out = try allocator.alloc(u8, trimmed.len + 1);
    @memcpy(out[0..trimmed.len], trimmed);
    out[trimmed.len] = '\n';
    return out;
}

/// go-git `Repository.DeleteTag`.
pub fn deleteTag(store: *memory.Storage, name: []const u8) !void {
    _ = try tag(store, name);
    var buf: [256]u8 = undefined;
    const rname = plumbing.newTagReferenceName(name, &buf) catch return error.InvalidReferenceName;
    store.removeReference(rname);
}

// ---------------------------------------------------------------------------
// Tests (storage-level; no repository import)
// ---------------------------------------------------------------------------

fn bareStore(gpa: Allocator) !*memory.Storage {
    const s = try memory.newStorage(gpa);
    // Minimal HEAD so Open-shaped use works; Init sets bare via config.
    try s.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
    const cfg = try s.config();
    cfg.is_bare = true;
    try s.setConfig(cfg);
    return s;
}

test "createRemote deleteRemote remote" {
    const gpa = std.testing.allocator;
    const s = try bareStore(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    const rem = try createRemote(s, "origin", &[_][]const u8{"https://example.com/r.git"});
    try std.testing.expectEqualStrings("origin", rem.name());

    try std.testing.expectError(error.RemoteExists, createRemote(s, "origin", &[_][]const u8{"x"}));
    const got = try remote(s, "origin");
    try std.testing.expectEqualStrings("origin", got.name());

    try deleteRemote(s, "origin");
    try std.testing.expectError(error.RemoteNotFound, remote(s, "origin"));
}

test "createBranch deleteBranch" {
    const gpa = std.testing.allocator;
    const s = try bareStore(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    try createBranch(s, "main", "origin", "refs/heads/main");
    const b = try branch(s, "main");
    try std.testing.expectEqualStrings("origin", b.remote);
    try std.testing.expectError(error.BranchExists, createBranch(s, "main", "o", "m"));
    try deleteBranch(s, "main");
    try std.testing.expectError(error.BranchNotFound, branch(s, "main"));
}

test "createTag lightweight and deleteTag" {
    const gpa = std.testing.allocator;
    const store = try bareStore(gpa);
    defer {
        store.deinit();
        gpa.destroy(store);
    }

    const blob = try store.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write("x");
    const h = try store.setEncodedObject(blob);

    const ref = try createTag(store, "v1", h, null);
    try std.testing.expect(ref.hash.eql(h));
    try std.testing.expectError(error.TagExists, createTag(store, "v1", h, null));

    const t = try tag(store, "v1");
    try std.testing.expect(t.hash.eql(h));

    try deleteTag(store, "v1");
    try std.testing.expectError(error.TagNotFound, tag(store, "v1"));
}

test "createTag annotated message and tagger" {
    const gpa = std.testing.allocator;
    const store = try bareStore(gpa);
    defer {
        store.deinit();
        gpa.destroy(store);
    }

    const blob = try store.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write("payload");
    const h = try store.setEncodedObject(blob);

    try std.testing.expectError(error.MissingMessage, createTag(store, "bad-msg", h, .{
        .tagger = .{ .name = "A", .email = "a@b.c", .when = 1 },
        .message = "",
    }));
    try std.testing.expectError(error.MissingTagger, createTag(store, "bad-tagger", h, .{
        .message = "x",
    }));

    const ref = try createTag(store, "v1.0", h, .{
        .tagger = .{
            .name = "Tagger",
            .email = "tagger@example.com",
            .when = 1_500_000_000,
            .tz_offset_minutes = 0,
        },
        .message = "  release notes  ",
    });
    try std.testing.expect(!ref.hash.eql(h));

    var tag_obj = try objpkg.getTag(gpa, store, ref.hash);
    defer tag_obj.deinit();
    try std.testing.expectEqualStrings("v1.0", tag_obj.name);
    try std.testing.expectEqualStrings("release notes\n", tag_obj.message);
    try std.testing.expectEqualStrings("Tagger", tag_obj.tagger.name);
    try std.testing.expectEqualStrings("tagger@example.com", tag_obj.tagger.email);
    try std.testing.expect(tag_obj.target.eql(h));
    try std.testing.expect(tag_obj.target_type == .blob);
    try std.testing.expectEqualStrings("", tag_obj.pgp_signature);
}

test "createTag annotated pgp_signature round-trip via tagObject" {
    const gpa = std.testing.allocator;
    const store = try bareStore(gpa);
    defer {
        store.deinit();
        gpa.destroy(store);
    }

    const blob = try store.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write("signed-payload");
    const h = try store.setEncodedObject(blob);

    const sig =
        \\-----BEGIN PGP SIGNATURE-----
        \\
        \\iQIzBAABCAAdFiEE...
        \\-----END PGP SIGNATURE-----
        \\
    ;

    const ref = try createTag(store, "signed", h, .{
        .tagger = .{
            .name = "Signer",
            .email = "s@example.com",
            .when = 42,
        },
        .message = "signed tag",
        .pgp_signature = sig,
    });

    // Round-trip through the same path as `Repository.tagObject` / `facade.tagObject`.
    var tag_obj = try objpkg.getTag(gpa, store, ref.hash);
    defer tag_obj.deinit();
    try std.testing.expectEqualStrings("signed", tag_obj.name);
    try std.testing.expectEqualStrings("signed tag\n", tag_obj.message);
    try std.testing.expectEqualStrings(sig, tag_obj.pgp_signature);
    try std.testing.expect(tag_obj.target.eql(h));
}

// Shared go-git armored private key fixture (object/openpgp/fixtures.zig).
const go_git_armored_private_key = objpkg.go_git_armored_private_key;
const go_git_key_passphrase = objpkg.go_git_key_passphrase;

test "createTag sign_key produces verifiable pgp_signature" {
    const gpa = std.testing.allocator;
    const store = try bareStore(gpa);
    defer {
        store.deinit();
        gpa.destroy(store);
    }

    const ents = try objpkg.readArmoredKeyRing(gpa, go_git_armored_private_key);
    defer objpkg.freeEntities(gpa, ents);
    try ents[0].decrypt(go_git_key_passphrase);

    const blob = try store.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write("tag-sign-target");
    const h = try store.setEncodedObject(blob);

    const ref = try createTag(store, "v-signed", h, .{
        .tagger = .{
            .name = "Signer",
            .email = "s@example.com",
            .when = 1_534_915_842,
        },
        .message = "signed with entity",
        .sign_key = &ents[0],
    });

    var tag_obj = try objpkg.getTag(gpa, store, ref.hash);
    defer tag_obj.deinit();
    try std.testing.expect(tag_obj.pgp_signature.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, tag_obj.pgp_signature, "BEGIN PGP SIGNATURE") != null);

    const pub_armor = try ents[0].serializePublicArmored(gpa);
    defer gpa.free(pub_armor);
    try tag_obj.verify(pub_armor);
}

test "createTag encrypted sign_key fails" {
    const gpa = std.testing.allocator;
    const store = try bareStore(gpa);
    defer {
        store.deinit();
        gpa.destroy(store);
    }

    const ents = try objpkg.readArmoredKeyRing(gpa, go_git_armored_private_key);
    defer objpkg.freeEntities(gpa, ents);
    try std.testing.expect(ents[0].primary.encrypted);

    const blob = try store.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write("x");
    const h = try store.setEncodedObject(blob);

    try std.testing.expectError(error.EncryptedKey, createTag(store, "v-enc", h, .{
        .tagger = .{
            .name = "Signer",
            .email = "s@example.com",
            .when = 1,
        },
        .message = "should fail",
        .sign_key = &ents[0],
    }));
}

test "createRemoteAnonymous not stored" {
    const gpa = std.testing.allocator;
    const s = try bareStore(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    var anon = try createRemoteAnonymous(s, gpa, &[_][]const u8{"git@h:r.git"});
    defer anon.deinit();
    try std.testing.expectEqualStrings("anonymous", anon.remote.name());
    try std.testing.expectError(error.RemoteNotFound, remote(s, "anonymous"));
}
