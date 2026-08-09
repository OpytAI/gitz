//! Repository.Fetch / Push over MapLoader.

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");
const server_pkg = @import("server");
const client_pkg = @import("client");
const sync = @import("utils/sync");
const fixtures = @import("transport_test_fixtures");
const remote_pkg = @import("remote");
const gitconfig = @import("gitconfig");

const repository = @import("repository.zig");

const MapLoader = server_pkg.MapLoader;
const newClient = server_pkg.newClient;

fn destroyStorage(allocator: std.mem.Allocator, sto: *memory.Storage) void {
    sto.deinit();
    allocator.destroy(sto);
}

test "Repository.fetch and push over MapLoader" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    client_pkg.init(allocator);
    defer client_pkg.deinit();

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);
    const head = try fixtures.populateRepo(remote_sto, allocator);

    var ep = try fixtures.makeEndpoint(allocator, "file://repo-net");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var srv = newClient(allocator, loader.asLoader());
    try client_pkg.installProtocol("file", remote_pkg.transportFromServer(&srv));

    const local_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, local_sto);
    var local = try repository.init(local_sto, null);
    _ = try local.createRemoteFull(
        "origin",
        &[_][]const u8{"file://repo-net"},
        &[_][]const u8{"+refs/heads/*:refs/remotes/origin/*"},
        false,
    );

    var fetch_opts: remote_pkg.FetchOptions = .{ .remote_name = "origin" };
    try local.fetch(&fetch_opts);

    const tracking = try local_sto.reference(plumbing.ReferenceName.init("refs/remotes/origin/master"));
    try std.testing.expect(tracking.hash.eql(head));

    // Local advances and force-pushes tip to remote.
    const blob = try fixtures.storeBlob(local_sto, "pushed");
    const tree = try fixtures.storeTree(local_sto, allocator, blob, "p.txt");
    const new_head = try fixtures.storeCommit(local_sto, allocator, tree, "push me\n");
    try local_sto.setReference(plumbing.Reference.newHashReference(plumbing.master, new_head));

    const push_spec = gitconfig.RefSpec.init("+refs/heads/master:refs/heads/master");
    var push_opts: remote_pkg.PushOptions = .{
        .remote_name = "origin",
        .ref_specs = &.{push_spec},
    };
    try local.push(&push_opts);

    const remote_master = try remote_sto.reference(plumbing.master);
    try std.testing.expect(remote_master.hash.eql(new_head));
}
