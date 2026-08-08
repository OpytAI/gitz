//! Integration tests for clone / plainClone over MapLoader + in-process server.
//!
//! Pattern matches `src/remote/tests.zig` and `src/repo/network_tests.zig`.

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");
const fs_pkg = @import("fs");
const server_pkg = @import("server");
const sync = @import("utils/sync");
const fixtures = @import("transport_test_fixtures");
const worktree = @import("worktree");

const clone_mod = @import("clone.zig");

const Allocator = std.mem.Allocator;
const MapLoader = server_pkg.MapLoader;
const newClient = server_pkg.newClient;
const CloneOptions = worktree.CloneOptions;

fn destroyStorage(allocator: Allocator, sto: *memory.Storage) void {
    sto.deinit();
    allocator.destroy(sto);
}

test "cloneEmbedded bare fetches HEAD and master" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);
    const head = try fixtures.populateRepo(remote_sto, allocator);

    var ep = try fixtures.makeEndpoint(allocator, "file://clone-bare");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var srv = newClient(allocator, loader.asLoader());

    const local_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, local_sto);

    var opts: CloneOptions = .{
        .url = "file://clone-bare",
        .no_checkout = true,
    };
    var r = try clone_mod.cloneEmbedded(allocator, local_sto, null, &opts, &srv);

    try std.testing.expect(r.isBare());

    const master = try local_sto.reference(plumbing.master);
    try std.testing.expect(master.hash.eql(head));

    const tracking = try local_sto.reference(
        plumbing.ReferenceName.init("refs/remotes/origin/master"),
    );
    try std.testing.expect(tracking.hash.eql(head));

    const head_ref = try r.head();
    try std.testing.expect(head_ref.hash.eql(head));

    // Branch tracking config for the cloned branch.
    const b = try r.branch("master");
    try std.testing.expectEqualStrings("origin", b.remote);
    try std.testing.expectEqualStrings("refs/heads/master", b.merge);
}

test "cloneEmbedded mirror uses refs/* refspec" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);
    const head = try fixtures.populateRepo(remote_sto, allocator);

    var ep = try fixtures.makeEndpoint(allocator, "file://clone-mirror");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var srv = newClient(allocator, loader.asLoader());

    const local_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, local_sto);

    var opts: CloneOptions = .{
        .url = "file://clone-mirror",
        .mirror = true,
    };
    var r = try clone_mod.cloneEmbedded(allocator, local_sto, null, &opts, &srv);
    try std.testing.expect(r.isBare());

    // Mirror maps all refs including heads locally (not only remotes/*).
    const master = try local_sto.reference(plumbing.master);
    try std.testing.expect(master.hash.eql(head));

    const cfg = try r.config();
    const rem = cfg.remotes.get("origin").?;
    try std.testing.expect(rem.mirror);
    try std.testing.expectEqual(@as(usize, 1), rem.fetch.len);
    try std.testing.expectEqualStrings("+refs/*:refs/*", rem.fetch[0]);
}

test "plainCloneEmbedded non-bare with no_checkout" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);
    const head = try fixtures.populateRepo(remote_sto, allocator);

    var ep = try fixtures.makeEndpoint(allocator, "file://plain-clone");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var srv = newClient(allocator, loader.asLoader());

    var path_fs = try fs_pkg.Mem.init(allocator);
    defer path_fs.deinit();

    var opts: CloneOptions = .{
        .url = "file://plain-clone",
        .no_checkout = true,
    };
    var owned = try clone_mod.plainCloneEmbedded(allocator, &path_fs, false, &opts, &srv);
    defer owned.deinit();

    try std.testing.expect(!owned.repo.isBare());
    const master = try owned.storer.reference(plumbing.master);
    try std.testing.expect(master.hash.eql(head));
}

test "plainCloneEmbedded bare" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);
    const head = try fixtures.populateRepo(remote_sto, allocator);

    var ep = try fixtures.makeEndpoint(allocator, "file://plain-bare");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var srv = newClient(allocator, loader.asLoader());

    var path_fs = try fs_pkg.Mem.init(allocator);
    defer path_fs.deinit();

    var opts: CloneOptions = .{ .url = "file://plain-bare" };
    var owned = try clone_mod.plainCloneEmbedded(allocator, &path_fs, true, &opts, &srv);
    defer owned.deinit();

    try std.testing.expect(owned.repo.isBare());
    const master = try owned.storer.reference(plumbing.master);
    try std.testing.expect(master.hash.eql(head));
}

test "cloneEmbedded with checkout materialises worktree file" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const remote_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, remote_sto);
    _ = try fixtures.populateRepo(remote_sto, allocator);

    var ep = try fixtures.makeEndpoint(allocator, "file://clone-checkout");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var srv = newClient(allocator, loader.asLoader());

    const local_sto = try memory.newStorage(allocator);
    defer destroyStorage(allocator, local_sto);

    var wt_fs = try fs_pkg.Mem.init(allocator);
    defer wt_fs.deinit();

    var opts: CloneOptions = .{
        .url = "file://clone-checkout",
        .no_checkout = false,
    };
    _ = try clone_mod.cloneEmbedded(allocator, local_sto, &wt_fs, &opts, &srv);

    // populateRepo writes hello.txt with content "hello".
    var f = try wt_fs.open("hello.txt");
    defer f.close() catch {};
    var buf: [64]u8 = undefined;
    const n = try f.read(&buf);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
}
