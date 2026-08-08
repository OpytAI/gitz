//! Integration tests for Remote List / Fetch / Push over MapLoader + server.
//!
//! Uses `transport_test_fixtures` and an in-process `server.NewClient` so no
//! real network is required.

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");
const server_pkg = @import("server");
const sync = @import("utils/sync");
const fixtures = @import("transport_test_fixtures");
const gitconfig = @import("gitconfig");

const options_mod = @import("options.zig");
const error_mod = @import("error.zig");
const remote_mod = @import("remote.zig");
const session_mod = @import("session.zig");

const Allocator = std.mem.Allocator;
const Reference = plumbing.Reference;
const MapLoader = server_pkg.MapLoader;
const newClient = server_pkg.newClient;
const Remote = remote_mod.Remote;
const newRemoteEmbedded = remote_mod.newRemoteEmbedded;
const freeReferences = remote_mod.freeReferences;
const FetchOptions = options_mod.FetchOptions;
const PushOptions = options_mod.PushOptions;
const ListOptions = options_mod.ListOptions;
const ForceWithLease = options_mod.ForceWithLease;
const PeelingOption = options_mod.PeelingOption;
const TagMode = options_mod.TagMode;
const SessionOpts = session_mod.SessionOpts;
const RemoteError = error_mod.Error;
const packp = @import("packp");

const default_fetch_spec = "+refs/heads/*:refs/remotes/origin/*";
const default_push_spec = "refs/heads/*:refs/heads/*";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const OwnedRemoteConfig = struct {
    name: []u8,
    urls: [][]u8,
    fetch: [][]u8,
    cfg: memory.RemoteConfig = undefined,

    fn init(allocator: Allocator, name: []const u8, url: []const u8, fetch_spec: []const u8) !OwnedRemoteConfig {
        const name_owned = try allocator.dupe(u8, name);
        errdefer allocator.free(name_owned);
        const url_owned = try allocator.dupe(u8, url);
        errdefer allocator.free(url_owned);
        const urls = try allocator.alloc([]u8, 1);
        errdefer allocator.free(urls);
        urls[0] = url_owned;
        const fetch_owned = try allocator.dupe(u8, fetch_spec);
        errdefer allocator.free(fetch_owned);
        const fetch = try allocator.alloc([]u8, 1);
        errdefer allocator.free(fetch);
        fetch[0] = fetch_owned;

        var self: OwnedRemoteConfig = .{
            .name = name_owned,
            .urls = urls,
            .fetch = fetch,
        };
        self.cfg = .{
            .name = self.name,
            .urls = self.urls,
            .fetch = self.fetch,
            .mirror = false,
        };
        return self;
    }

    fn deinit(self: *OwnedRemoteConfig, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.urls) |u| allocator.free(u);
        allocator.free(self.urls);
        for (self.fetch) |f| allocator.free(f);
        allocator.free(self.fetch);
        self.* = undefined;
    }
};

fn destroyStorage(allocator: Allocator, sto: *memory.Storage) void {
    sto.deinit();
    allocator.destroy(sto);
}

fn refNamed(refs: []const Reference, name: []const u8) ?Reference {
    for (refs) |r| {
        if (std.mem.eql(u8, r.name.raw, name)) return r;
    }
    return null;
}

// ---------------------------------------------------------------------------
// String / constructors (no transport)
// ---------------------------------------------------------------------------

test "Remote.String two urls" {
    const allocator = std.testing.allocator;
    const sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, sto);

    const name = try allocator.dupe(u8, "origin");
    defer allocator.free(name);
    const url_fetch = try allocator.dupe(u8, "file://fetch-url");
    defer allocator.free(url_fetch);
    const url_push = try allocator.dupe(u8, "file://push-url");
    defer allocator.free(url_push);
    var urls = [_][]u8{ url_fetch, url_push };
    const cfg = memory.RemoteConfig{ .name = name, .urls = urls[0..] };
    const r = remote_mod.newRemote(sto, &cfg);
    const s = try r.string(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings(
        "origin\tfile://fetch-url (fetch)\norigin\tfile://push-url (push)",
        s,
    );
}

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

test "Remote.List returns HEAD and refs/heads/master" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);
    const head = try fixtures.populateRepo(remote_sto, allocator);

    const local_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, local_sto);

    var ep = try fixtures.makeEndpoint(allocator, "file://list-remote");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var client = newClient(allocator, loader.asLoader());
    var owned = try OwnedRemoteConfig.init(allocator, "origin", "file://list-remote", default_fetch_spec);
    defer owned.deinit(allocator);

    var rem = newRemoteEmbedded(local_sto, &owned.cfg, &client);
    const refs = try rem.list(.{});
    defer freeReferences(allocator, refs);

    try std.testing.expect(refNamed(refs, "HEAD") != null);
    const master = refNamed(refs, "refs/heads/master");
    try std.testing.expect(master != null);
    try std.testing.expect(master.?.hash.eql(head));
}

// ---------------------------------------------------------------------------
// Fetch
// ---------------------------------------------------------------------------

test "Remote.Fetch empty local gains objects and tracking ref" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);
    const head = try fixtures.populateRepo(remote_sto, allocator);

    const local_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, local_sto);

    var ep = try fixtures.makeEndpoint(allocator, "file://fetch-remote");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var client = newClient(allocator, loader.asLoader());
    var owned = try OwnedRemoteConfig.init(allocator, "origin", "file://fetch-remote", default_fetch_spec);
    defer owned.deinit(allocator);

    var rem = newRemoteEmbedded(local_sto, &owned.cfg, &client);
    var opts: FetchOptions = .{
        .remote_name = "origin",
    };
    try rem.fetch(&opts);

    const tracking = try local_sto.reference(plumbing.ReferenceName.init("refs/remotes/origin/master"));
    try std.testing.expect(tracking.hash.eql(head));

    // Objects must be present locally.
    const commit_obj = try local_sto.encodedObject(.commit, head);
    try std.testing.expect(commit_obj.hash().eql(head));
}

test "Remote.Fetch second call AlreadyUpToDate" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);
    _ = try fixtures.populateRepo(remote_sto, allocator);

    const local_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, local_sto);

    var ep = try fixtures.makeEndpoint(allocator, "file://fetch-uptodate");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var client = newClient(allocator, loader.asLoader());
    var owned = try OwnedRemoteConfig.init(allocator, "origin", "file://fetch-uptodate", default_fetch_spec);
    defer owned.deinit(allocator);

    var rem = newRemoteEmbedded(local_sto, &owned.cfg, &client);
    var opts: FetchOptions = .{ .remote_name = "origin" };
    try rem.fetch(&opts);

    var opts2: FetchOptions = .{ .remote_name = "origin" };
    try std.testing.expectError(RemoteError.AlreadyUpToDate, rem.fetch(&opts2));
}

// ---------------------------------------------------------------------------
// Push
// ---------------------------------------------------------------------------

test "Remote.Push local commit to empty remote" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    // Local has content; remote is empty.
    const local_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, local_sto);
    const head = try fixtures.populateRepo(local_sto, allocator);

    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);

    var ep = try fixtures.makeEndpoint(allocator, "file://push-remote");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var client = newClient(allocator, loader.asLoader());
    // Push uses URLs[last]; single URL is fine. Fetch refspec unused for push.
    var owned = try OwnedRemoteConfig.init(allocator, "origin", "file://push-remote", default_fetch_spec);
    defer owned.deinit(allocator);

    var rem = newRemoteEmbedded(local_sto, &owned.cfg, &client);

    const push_spec = gitconfig.RefSpec.init(default_push_spec);
    var opts: PushOptions = .{
        .remote_name = "origin",
        .ref_specs = &.{push_spec},
    };
    try rem.push(&opts);

    const remote_master = try remote_sto.reference(plumbing.master);
    try std.testing.expect(remote_master.hash.eql(head));
}

// ---------------------------------------------------------------------------
// ForceWithLease reject (when remote tip moved)
// ---------------------------------------------------------------------------

test "Remote.Push ForceWithLease rejects mismatched tip" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    // Remote has master at first commit.
    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);
    const remote_head = try fixtures.populateRepo(remote_sto, allocator);

    // Local has a different tip (second commit) and a tracking ref that does
    // not match the remote advertisement (stale lease).
    const local_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, local_sto);
    const first = try fixtures.populateRepo(local_sto, allocator);
    try std.testing.expect(first.eql(remote_head));

    const blob = try fixtures.storeBlob(local_sto, "second");
    const tree = try fixtures.storeTree(local_sto, allocator, blob, "second.txt");
    const second = try fixtures.storeCommit(local_sto, allocator, tree, "second\n");
    try local_sto.setReference(Reference.newHashReference(plumbing.master, second));

    // Tracking claims the remote is still at ZeroHash — not remote_head.
    try local_sto.setReference(Reference.newHashReference(
        plumbing.ReferenceName.init("refs/remotes/origin/master"),
        plumbing.ZeroHash,
    ));

    var ep = try fixtures.makeEndpoint(allocator, "file://fwl-remote");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var client = newClient(allocator, loader.asLoader());
    var owned = try OwnedRemoteConfig.init(allocator, "origin", "file://fwl-remote", default_fetch_spec);
    defer owned.deinit(allocator);

    var rem = newRemoteEmbedded(local_sto, &owned.cfg, &client);

    const push_spec = gitconfig.RefSpec.init("+refs/heads/master:refs/heads/master");
    var opts: PushOptions = .{
        .remote_name = "origin",
        .ref_specs = &.{push_spec},
        // Empty lease hash → compare remote tip to local tracking (ZeroHash).
        .force_with_lease = ForceWithLease{},
    };

    try std.testing.expectError(RemoteError.ForceWithLeaseRejected, rem.push(&opts));

    // Remote tip must remain unchanged.
    const tip = try remote_sto.reference(plumbing.master);
    try std.testing.expect(tip.hash.eql(remote_head));
}

// ---------------------------------------------------------------------------
// List peeling (annotated tag + append_peeled)
// ---------------------------------------------------------------------------

test "Remote.List append_peeled includes peeled tag suffix" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);
    const head = try fixtures.populateRepo(remote_sto, allocator);

    const tag_hash = try fixtures.storeAnnotatedTag(remote_sto, allocator, head, "commit", "v1.0");
    try remote_sto.setReference(Reference.newHashReference(
        plumbing.ReferenceName.init("refs/tags/v1.0"),
        tag_hash,
    ));

    const local_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, local_sto);

    var ep = try fixtures.makeEndpoint(allocator, "file://list-peel");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var client = newClient(allocator, loader.asLoader());
    var owned = try OwnedRemoteConfig.init(allocator, "origin", "file://list-peel", default_fetch_spec);
    defer owned.deinit(allocator);

    var rem = newRemoteEmbedded(local_sto, &owned.cfg, &client);

    const peeled_name = try std.fmt.allocPrint(allocator, "refs/tags/v1.0{s}", .{packp.peeled});
    defer allocator.free(peeled_name);

    // Default ignore_peeled still returns the tag tip itself.
    {
        const refs = try rem.list(.{ .peeling = .ignore_peeled });
        defer freeReferences(allocator, refs);
        try std.testing.expect(refNamed(refs, "refs/tags/v1.0") != null);
        try std.testing.expect(refNamed(refs, peeled_name) == null);
    }

    // append_peeled adds the peeled name with ^{} suffix.
    {
        const refs = try rem.list(.{ .peeling = .append_peeled });
        defer freeReferences(allocator, refs);
        try std.testing.expect(refNamed(refs, "refs/tags/v1.0") != null);
        const peeled = refNamed(refs, peeled_name);
        try std.testing.expect(peeled != null);
        try std.testing.expect(peeled.?.hash.eql(head));
        _ = PeelingOption.append_peeled;
    }
}

// ---------------------------------------------------------------------------
// Fetch prune
// ---------------------------------------------------------------------------

test "Remote.Fetch prune removes stale tracking ref" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);
    const head = try fixtures.populateRepo(remote_sto, allocator);

    const local_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, local_sto);

    // Stale tracking ref that no longer exists on the remote.
    try local_sto.setReference(Reference.newHashReference(
        plumbing.ReferenceName.init("refs/remotes/origin/gone"),
        head,
    ));

    var ep = try fixtures.makeEndpoint(allocator, "file://fetch-prune");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var client = newClient(allocator, loader.asLoader());
    var owned = try OwnedRemoteConfig.init(allocator, "origin", "file://fetch-prune", default_fetch_spec);
    defer owned.deinit(allocator);

    var rem = newRemoteEmbedded(local_sto, &owned.cfg, &client);
    var opts: FetchOptions = .{
        .remote_name = "origin",
        .prune = true,
    };
    try rem.fetch(&opts);

    const tracking = try local_sto.reference(plumbing.ReferenceName.init("refs/remotes/origin/master"));
    try std.testing.expect(tracking.hash.eql(head));

    try std.testing.expectError(
        error.ReferenceNotFound,
        local_sto.reference(plumbing.ReferenceName.init("refs/remotes/origin/gone")),
    );
}

// ---------------------------------------------------------------------------
// Fetch AllTags / NoTags
// ---------------------------------------------------------------------------

test "Remote.Fetch AllTags gains tag; NoTags does not" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);
    const head = try fixtures.populateRepo(remote_sto, allocator);

    const tag_hash = try fixtures.storeAnnotatedTag(remote_sto, allocator, head, "commit", "v-all");
    try remote_sto.setReference(Reference.newHashReference(
        plumbing.ReferenceName.init("refs/tags/v-all"),
        tag_hash,
    ));

    // --- AllTags ---
    {
        const local_sto = try memory.newStorage(allocator);
        defer destroyStorage(allocator, local_sto);

        var ep = try fixtures.makeEndpoint(allocator, "file://fetch-alltags");
        defer ep.deinit();
        try loader.put(&ep, remote_sto);

        var client = newClient(allocator, loader.asLoader());
        var owned = try OwnedRemoteConfig.init(allocator, "origin", "file://fetch-alltags", default_fetch_spec);
        defer owned.deinit(allocator);

        var rem = newRemoteEmbedded(local_sto, &owned.cfg, &client);
        var opts: FetchOptions = .{
            .remote_name = "origin",
            .tags = .all,
        };
        try rem.fetch(&opts);

        const got = try local_sto.reference(plumbing.ReferenceName.init("refs/tags/v-all"));
        try std.testing.expect(got.hash.eql(tag_hash));
        _ = TagMode.all;
    }

    // --- NoTags ---
    {
        const local_sto = try memory.newStorage(allocator);
        defer destroyStorage(allocator, local_sto);

        var ep = try fixtures.makeEndpoint(allocator, "file://fetch-notags");
        defer ep.deinit();
        try loader.put(&ep, remote_sto);

        var client = newClient(allocator, loader.asLoader());
        var owned = try OwnedRemoteConfig.init(allocator, "origin", "file://fetch-notags", default_fetch_spec);
        defer owned.deinit(allocator);

        var rem = newRemoteEmbedded(local_sto, &owned.cfg, &client);
        var opts: FetchOptions = .{
            .remote_name = "origin",
            .tags = .none,
        };
        try rem.fetch(&opts);

        const tracking = try local_sto.reference(plumbing.ReferenceName.init("refs/remotes/origin/master"));
        try std.testing.expect(tracking.hash.eql(head));
        try std.testing.expectError(
            error.ReferenceNotFound,
            local_sto.reference(plumbing.ReferenceName.init("refs/tags/v-all")),
        );
    }
}

// ---------------------------------------------------------------------------
// Push force
// ---------------------------------------------------------------------------

test "Remote.Push ForceNeeded without force; force succeeds" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);
    const remote_head = try fixtures.populateRepo(remote_sto, allocator);

    const local_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, local_sto);
    const first = try fixtures.populateRepo(local_sto, allocator);
    try std.testing.expect(first.eql(remote_head));

    // Divergent tip: second commit has no parent, so it is not a fast-forward.
    const blob = try fixtures.storeBlob(local_sto, "divergent");
    const tree = try fixtures.storeTree(local_sto, allocator, blob, "div.txt");
    const second = try fixtures.storeCommit(local_sto, allocator, tree, "divergent\n");
    try local_sto.setReference(Reference.newHashReference(plumbing.master, second));

    var ep = try fixtures.makeEndpoint(allocator, "file://push-force");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var client = newClient(allocator, loader.asLoader());
    var owned = try OwnedRemoteConfig.init(allocator, "origin", "file://push-force", default_fetch_spec);
    defer owned.deinit(allocator);

    var rem = newRemoteEmbedded(local_sto, &owned.cfg, &client);
    const push_spec = gitconfig.RefSpec.init("refs/heads/master:refs/heads/master");

    var opts_noforce: PushOptions = .{
        .remote_name = "origin",
        .ref_specs = &.{push_spec},
        .force = false,
    };
    try std.testing.expectError(RemoteError.ForceNeeded, rem.push(&opts_noforce));

    const tip_before = try remote_sto.reference(plumbing.master);
    try std.testing.expect(tip_before.hash.eql(remote_head));

    var opts_force: PushOptions = .{
        .remote_name = "origin",
        .ref_specs = &.{push_spec},
        .force = true,
    };
    try rem.push(&opts_force);

    const tip_after = try remote_sto.reference(plumbing.master);
    try std.testing.expect(tip_after.hash.eql(second));
}

// ---------------------------------------------------------------------------
// Push delete ref
// ---------------------------------------------------------------------------

test "Remote.Push delete ref removes remote branch" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);
    const head = try fixtures.populateRepo(remote_sto, allocator);
    try remote_sto.setReference(Reference.newHashReference(
        plumbing.ReferenceName.init("refs/heads/temp"),
        head,
    ));

    // Local can be empty for a pure delete push.
    const local_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, local_sto);

    var ep = try fixtures.makeEndpoint(allocator, "file://push-delete");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var client = newClient(allocator, loader.asLoader());
    var owned = try OwnedRemoteConfig.init(allocator, "origin", "file://push-delete", default_fetch_spec);
    defer owned.deinit(allocator);

    var rem = newRemoteEmbedded(local_sto, &owned.cfg, &client);
    const del_spec = gitconfig.RefSpec.init(":refs/heads/temp");
    var opts: PushOptions = .{
        .remote_name = "origin",
        .ref_specs = &.{del_spec},
    };
    try rem.push(&opts);

    try std.testing.expectError(
        error.ReferenceNotFound,
        remote_sto.reference(plumbing.ReferenceName.init("refs/heads/temp")),
    );
    // master remains.
    const master = try remote_sto.reference(plumbing.master);
    try std.testing.expect(master.hash.eql(head));
}

// ---------------------------------------------------------------------------
// Push require_remote_refs
// ---------------------------------------------------------------------------

test "Remote.Push require_remote_refs match succeeds; mismatch fails" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);
    const remote_head = try fixtures.populateRepo(remote_sto, allocator);

    const local_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, local_sto);
    _ = try fixtures.populateRepo(local_sto, allocator);

    var ep = try fixtures.makeEndpoint(allocator, "file://push-require");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var client = newClient(allocator, loader.asLoader());
    var owned = try OwnedRemoteConfig.init(allocator, "origin", "file://push-require", default_fetch_spec);
    defer owned.deinit(allocator);

    var rem = newRemoteEmbedded(local_sto, &owned.cfg, &client);

    var hex_buf: [plumbing.MaxHexSize]u8 = undefined;
    const head_hex = remote_head.string(&hex_buf);

    // Matching tip SHA → require passes; nothing to push → AlreadyUpToDate.
    {
        const require_raw = try std.fmt.allocPrint(allocator, "{s}:refs/heads/master", .{head_hex});
        defer allocator.free(require_raw);
        const require_spec = gitconfig.RefSpec.init(require_raw);
        const push_spec = gitconfig.RefSpec.init(default_push_spec);
        var opts: PushOptions = .{
            .remote_name = "origin",
            .ref_specs = &.{push_spec},
            .require_remote_refs = &.{require_spec},
        };
        try std.testing.expectError(RemoteError.AlreadyUpToDate, rem.push(&opts));
    }

    // Mismatched tip → RequireRemoteRefsFailed before any update.
    {
        const bad = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        const require_raw = try std.fmt.allocPrint(allocator, "{s}:refs/heads/master", .{bad});
        defer allocator.free(require_raw);
        const require_spec = gitconfig.RefSpec.init(require_raw);
        const push_spec = gitconfig.RefSpec.init(default_push_spec);
        var opts: PushOptions = .{
            .remote_name = "origin",
            .ref_specs = &.{push_spec},
            .require_remote_refs = &.{require_spec},
        };
        try std.testing.expectError(RemoteError.RequireRemoteRefsFailed, rem.push(&opts));
    }
}

// ---------------------------------------------------------------------------
// Push follow_tags
// ---------------------------------------------------------------------------

test "Remote.Push follow_tags pushes annotated tag for tip commit" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const local_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, local_sto);
    const head = try fixtures.populateRepo(local_sto, allocator);

    const tag_hash = try fixtures.storeAnnotatedTag(local_sto, allocator, head, "commit", "v-follow");
    try local_sto.setReference(Reference.newHashReference(
        plumbing.ReferenceName.init("refs/tags/v-follow"),
        tag_hash,
    ));

    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);

    var ep = try fixtures.makeEndpoint(allocator, "file://push-follow-tags");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var client = newClient(allocator, loader.asLoader());
    var owned = try OwnedRemoteConfig.init(allocator, "origin", "file://push-follow-tags", default_fetch_spec);
    defer owned.deinit(allocator);

    var rem = newRemoteEmbedded(local_sto, &owned.cfg, &client);
    const push_spec = gitconfig.RefSpec.init(default_push_spec);
    var opts: PushOptions = .{
        .remote_name = "origin",
        .ref_specs = &.{push_spec},
        .follow_tags = true,
    };
    try rem.push(&opts);

    const remote_master = try remote_sto.reference(plumbing.master);
    try std.testing.expect(remote_master.hash.eql(head));
    const remote_tag = try remote_sto.reference(plumbing.ReferenceName.init("refs/tags/v-follow"));
    try std.testing.expect(remote_tag.hash.eql(tag_hash));
}

// ---------------------------------------------------------------------------
// Fetch depth (shallow) e2e — server depth pack + client updateShallow
// ---------------------------------------------------------------------------

test "Remote.Fetch depth=1 records shallow tip and omits parent object" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    // Two-commit chain: root → tip.
    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);
    const blob1 = try fixtures.storeBlob(remote_sto, "one");
    const tree1 = try fixtures.storeTree(remote_sto, allocator, blob1, "a.txt");
    const root = try fixtures.storeCommitParents(remote_sto, allocator, tree1, "root\n", &.{});
    const blob2 = try fixtures.storeBlob(remote_sto, "two");
    const tree2 = try fixtures.storeTree(remote_sto, allocator, blob2, "b.txt");
    const tip = try fixtures.storeCommitParents(remote_sto, allocator, tree2, "tip\n", &.{root});
    try remote_sto.setReference(Reference.newHashReference(plumbing.master, tip));
    try remote_sto.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

    const local_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, local_sto);

    var ep = try fixtures.makeEndpoint(allocator, "file://fetch-depth");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var client = newClient(allocator, loader.asLoader());
    var owned = try OwnedRemoteConfig.init(allocator, "origin", "file://fetch-depth", default_fetch_spec);
    defer owned.deinit(allocator);

    var rem = newRemoteEmbedded(local_sto, &owned.cfg, &client);
    var opts: FetchOptions = .{
        .remote_name = "origin",
        .depth = 1,
    };
    try rem.fetch(&opts);

    const tracking = try local_sto.reference(plumbing.ReferenceName.init("refs/remotes/origin/master"));
    try std.testing.expect(tracking.hash.eql(tip));

    // Tip object present; root commit should not be in the pack (depth=1).
    _ = try local_sto.encodedObject(.commit, tip);
    try std.testing.expectError(error.ObjectNotFound, local_sto.encodedObject(.commit, root));

    // Shallow list must record the boundary (root).
    const shallows = local_sto.shallow();
    try std.testing.expect(shallows.len >= 1);
    var found_root = false;
    for (shallows) |h| {
        if (h.eql(root)) found_root = true;
    }
    try std.testing.expect(found_root);
}

// ---------------------------------------------------------------------------
// List InvalidTimeout
// ---------------------------------------------------------------------------

test "Remote.List InvalidTimeout for negative timeout_sec" {
    const allocator = std.testing.allocator;
    const sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, sto);

    const name = try allocator.dupe(u8, "origin");
    defer allocator.free(name);
    const url = try allocator.dupe(u8, "file://timeout");
    defer allocator.free(url);
    var urls = [_][]u8{url};
    const cfg = memory.RemoteConfig{ .name = name, .urls = urls[0..] };
    const rem = remote_mod.newRemote(sto, &cfg);

    try std.testing.expectError(
        RemoteError.InvalidTimeout,
        rem.list(.{ .timeout_sec = -1 }),
    );
}

// ---------------------------------------------------------------------------
// SessionOpts / insecure (construct + ListOptions field surface)
// ---------------------------------------------------------------------------

test "SessionOpts from TransportClientOpts and ListOptions transport" {
    const opts = SessionOpts.fromClient(.{
        .insecure_skip_tls = true,
        .client_cert = "cert-pem",
        .client_key = "key-pem",
        .ca_bundle = "ca-pem",
    });
    try std.testing.expect(opts.insecure_skip_tls);
    try std.testing.expectEqualStrings("cert-pem", opts.client_cert);
    try std.testing.expectEqualStrings("key-pem", opts.client_key);
    try std.testing.expectEqualStrings("ca-pem", opts.ca_bundle);
    try std.testing.expect(opts.auth == null);

    const list_opts = ListOptions{
        .transport = .{
            .insecure_skip_tls = true,
            .client_cert = "list-cert",
            .client_key = "list-key",
            .ca_bundle = "list-ca",
        },
        .timeout_sec = 30,
        .peeling = .ignore_peeled,
    };
    try std.testing.expect(list_opts.transport.insecure_skip_tls);
    try std.testing.expectEqualStrings("list-cert", list_opts.transport.client_cert);
    try std.testing.expectEqual(@as(i32, 30), list_opts.effectiveTimeoutSec());

    const sopts = SessionOpts.fromClient(list_opts.transport);
    try std.testing.expectEqualStrings("list-cert", sopts.client_cert);
}

// ---------------------------------------------------------------------------
// Empty URLs
// ---------------------------------------------------------------------------

test "Remote.List EmptyUrls" {
    const allocator = std.testing.allocator;
    const sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, sto);

    const name = try allocator.dupe(u8, "origin");
    defer allocator.free(name);
    const cfg = memory.RemoteConfig{ .name = name, .urls = &.{} };
    const rem = remote_mod.newRemote(sto, &cfg);
    try std.testing.expectError(RemoteError.EmptyUrls, rem.list(.{}));
    _ = ListOptions{}; // keep type referenced for inventory
    _ = Remote;
}
