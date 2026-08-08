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
const RemoteError = error_mod.Error;

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
