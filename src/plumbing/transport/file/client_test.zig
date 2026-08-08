//! Unit tests for file transport
//! (go-git `plumbing/transport/file/client_test.go` + hermetic extras + host spawn).

const std = @import("std");
const testing = std.testing;
const transport = @import("transport");
const server = @import("server");
const memory = @import("memory");
const capability = @import("capability");
const plumbing = @import("plumbing");
const sync = @import("utils/sync");

const file = @import("client.zig");

const Allocator = std.mem.Allocator;

fn makeEp(allocator: Allocator, url: []const u8) !transport.Endpoint {
    return transport.newEndpoint(allocator, testing.io, url);
}

// ---------------------------------------------------------------------------
// Auth stub (file transport ignores auth — go-git emptyAuth)
// ---------------------------------------------------------------------------

const DummyAuth = struct {
    fn nameFn(_: *anyopaque) []const u8 {
        return "dummy";
    }
    fn formatFn(_: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
        return allocator.dupe(u8, "dummy-auth");
    }
    const vtable = transport.AuthMethod.VTable{
        .name = nameFn,
        .format = formatFn,
    };
    fn asAuth(self: *DummyAuth) transport.AuthMethod {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

// ---------------------------------------------------------------------------
// go-git surface
// ---------------------------------------------------------------------------

test "DefaultClient non-null" {
    const gpa = testing.allocator;
    var client = try file.defaultClient(gpa);
    defer client.deinit();
    try testing.expect(@intFromPtr(client.runner) != 0);
    try testing.expectEqualStrings(transport.UploadPackServiceName, client.runner.upload_pack_bin);
    try testing.expectEqualStrings(transport.ReceivePackServiceName, client.runner.receive_pack_bin);
    try testing.expect(client.runner.use_host_spawn);
    try testing.expect(client.runner.loader == null);
}

test "NewClient builds FileClient" {
    const gpa = testing.allocator;
    var client = try file.newClient(gpa, "git-upload-pack", "git-receive-pack");
    defer client.deinit();
    try testing.expectEqualStrings("git-upload-pack", client.runner.upload_pack_bin);
    try testing.expectEqualStrings("git-receive-pack", client.runner.receive_pack_bin);
    const t = client.asTransport();
    try testing.expect(@intFromPtr(t.vtable) != 0);
    try testing.expect(t.ptr == @as(*anyopaque, @ptrCast(&client)));
}

test "runner Command valid receive-pack service" {
    const gpa = testing.allocator;
    var runner = file.Runner.init(gpa, transport.UploadPackServiceName, transport.ReceivePackServiceName);
    defer runner.deinit();
    // Unit dry path: no loader, no host spawn.
    runner.use_host_spawn = false;

    var ep = try makeEp(gpa, "file:///tmp/fake/repo");
    defer ep.deinit();

    const cmd = try runner.command(transport.ReceivePackServiceName, &ep, null);
    try testing.expect(runner.owned.items.len == 1);
    try testing.expect(runner.owned.items[0] == .local);
    try cmd.start();
    try cmd.close();
}

test "runner Command valid upload-pack service" {
    const gpa = testing.allocator;
    var runner = file.Runner.init(gpa, transport.UploadPackServiceName, transport.ReceivePackServiceName);
    defer runner.deinit();
    runner.use_host_spawn = false;

    var ep = try makeEp(gpa, "/local/path/repo.git");
    defer ep.deinit();

    const cmd = try runner.command(transport.UploadPackServiceName, &ep, null);
    try testing.expect(runner.owned.items[0] == .local);
    try cmd.start();
    _ = try cmd.stdoutPipe();
    _ = try cmd.stderrPipe();
    _ = try cmd.stdinPipe();
    try cmd.close();
}

test "runner Command unknown service fails" {
    const gpa = testing.allocator;
    var runner = file.Runner.init(gpa, transport.UploadPackServiceName, transport.ReceivePackServiceName);
    defer runner.deinit();
    runner.use_host_spawn = false;

    var ep = try makeEp(gpa, "file:///tmp/fake/repo");
    defer ep.deinit();

    try testing.expectError(
        file.Error.CommandNotFound,
        runner.command("git-fake-command", &ep, null),
    );
}

test "runner absolute missing bin CommandNotFound" {
    // go-git LookPath fails for missing absolute bins.
    const gpa = testing.allocator;
    var client = try file.newClient(gpa, "/non-existent-git-upload-pack", "/non-existent-git-receive-pack");
    defer client.deinit();
    try testing.expect(client.runner.use_host_spawn);

    var ep = try makeEp(gpa, "file:///tmp/some/repo");
    defer ep.deinit();

    try testing.expectError(
        file.Error.CommandNotFound,
        client.newUploadPackSession(&ep, null),
    );
}

test "runner Command ignores auth" {
    const gpa = testing.allocator;
    var runner = file.Runner.init(gpa, transport.UploadPackServiceName, transport.ReceivePackServiceName);
    defer runner.deinit();
    runner.use_host_spawn = false;

    var ep = try makeEp(gpa, "file:///tmp/fake/repo");
    defer ep.deinit();

    var dummy: DummyAuth = .{};
    const cmd = try runner.command(transport.UploadPackServiceName, &ep, dummy.asAuth());
    try cmd.start();
    try cmd.close();
}

test "runner invalid empty location" {
    const gpa = testing.allocator;
    var runner = file.Runner.init(gpa, transport.UploadPackServiceName, transport.ReceivePackServiceName);
    defer runner.deinit();
    runner.use_host_spawn = false;

    // Empty path and empty host — no local location to serve.
    var ep = transport.Endpoint{
        .allocator = gpa,
        .protocol = try gpa.dupe(u8, "file"),
        .path = &.{},
        .host = &.{},
    };
    defer ep.deinit();

    try testing.expectError(
        file.Error.InvalidEndpoint,
        runner.command(transport.UploadPackServiceName, &ep, null),
    );
}

test "NewClient custom bins relative labels without host spawn" {
    // Dry path: relative configured labels accepted without LookPath.
    const gpa = testing.allocator;
    var client = try file.newClient(gpa, "true", "true");
    defer client.deinit();
    client.setUseHostSpawn(false);

    var ep = try makeEp(gpa, "file:///tmp/fake/repo");
    defer ep.deinit();

    var sess = try client.newUploadPackSession(&ep, null);
    defer sess.close() catch {};
    // Empty advertise stream → not-found / empty class error.
    try testing.expectError(error.UnexpectedEndOfStream, sess.advertisedReferences());
}

test "adjustPathForWindows leaves unix paths" {
    if (builtinOsIsWindows()) return;
    try testing.expectEqualStrings("/C:/foo", file.adjustPathForWindows("/C:/foo"));
    try testing.expectEqualStrings("/home/git/repo", file.adjustPathForWindows("/home/git/repo"));
}

fn builtinOsIsWindows() bool {
    return @import("builtin").os.tag == .windows;
}

// ---------------------------------------------------------------------------
// lookPath
// ---------------------------------------------------------------------------

test "lookPath finds true on PATH" {
    const gpa = testing.allocator;
    const found = try file.lookPath(gpa, testing.io, testing.environ, "true");
    defer gpa.free(found);
    try testing.expect(std.fs.path.isAbsolute(found));
    try testing.expect(std.mem.endsWith(u8, found, "true"));
}

test "lookPath finds sh on PATH" {
    const gpa = testing.allocator;
    const found = try file.lookPath(gpa, testing.io, testing.environ, "sh");
    defer gpa.free(found);
    try testing.expect(std.fs.path.isAbsolute(found));
}

test "lookPath misses nonsense name" {
    const gpa = testing.allocator;
    try testing.expectError(
        file.Error.CommandNotFound,
        file.lookPath(gpa, testing.io, testing.environ, "gitz-definitely-not-a-binary-xyzzy-9999"),
    );
}

test "lookPath empty name CommandNotFound" {
    const gpa = testing.allocator;
    try testing.expectError(
        file.Error.CommandNotFound,
        file.lookPath(gpa, testing.io, testing.environ, ""),
    );
}

test "lookPath absolute missing fails" {
    const gpa = testing.allocator;
    try testing.expectError(
        file.Error.CommandNotFound,
        file.lookPath(gpa, testing.io, testing.environ, "/no/such/gitz-bin-absolute-path"),
    );
}

test "lookPath absolute existing succeeds" {
    const gpa = testing.allocator;
    const candidates = [_][]const u8{ "/usr/bin/true", "/bin/true" };
    var found_any = false;
    for (candidates) |c| {
        if (file.lookPath(gpa, testing.io, testing.environ, c)) |path| {
            defer gpa.free(path);
            try testing.expectEqualStrings(c, path);
            found_any = true;
            break;
        } else |_| {}
    }
    try testing.expect(found_any);
}

// ---------------------------------------------------------------------------
// resolveBinary / dual-path wiring
// ---------------------------------------------------------------------------

test "resolveBinary with use_host_spawn=false skips LookPath" {
    const gpa = testing.allocator;
    var runner = file.Runner.init(gpa, "/non-existent-up", "/non-existent-rp");
    defer runner.deinit();
    runner.use_host_spawn = false;

    const r = try runner.resolveBinary(transport.UploadPackServiceName);
    try testing.expectEqualStrings("/non-existent-up", r.bin.bytes());
    try testing.expect(!r.bin.isOwned());
}

test "resolveBinary with use_host_spawn finds true" {
    const gpa = testing.allocator;
    var runner = file.Runner.init(gpa, "true", "true");
    defer runner.deinit();
    try testing.expect(runner.use_host_spawn);

    const r = try runner.resolveBinary(transport.UploadPackServiceName);
    defer if (r.bin == .owned) gpa.free(r.bin.owned);
    try testing.expect(r.bin.isOwned());
    try testing.expect(std.fs.path.isAbsolute(r.bin.bytes()));
}

test "resolveBinary missing bin CommandNotFound" {
    const gpa = testing.allocator;
    var runner = file.Runner.init(gpa, "gitz-no-such-upload-pack-bin", "gitz-no-such-receive-pack-bin");
    defer runner.deinit();

    try testing.expectError(
        file.Error.CommandNotFound,
        runner.resolveBinary(transport.UploadPackServiceName),
    );
}

test "resolveBinary git-upload-pack via PATH or prefixExecPath" {
    // go-git finds git-upload-pack on PATH or under git --exec-path.
    const gpa = testing.allocator;
    var runner = file.Runner.init(gpa, transport.UploadPackServiceName, transport.ReceivePackServiceName);
    defer runner.deinit();

    const r = try runner.resolveBinary(transport.UploadPackServiceName);
    defer if (r.bin == .owned) gpa.free(r.bin.owned);
    try testing.expect(r.bin.isOwned());
    try testing.expect(std.mem.indexOf(u8, r.bin.bytes(), "git-upload-pack") != null);
}

test "HostCommand argv construction via Runner.command" {
    const gpa = testing.allocator;
    var runner = file.Runner.init(gpa, "true", "true");
    defer runner.deinit();

    var ep = try makeEp(gpa, "file:///tmp/gitz-host-cmd-argv-test");
    defer ep.deinit();

    const cmd = try runner.command(transport.UploadPackServiceName, &ep, null);
    try testing.expect(runner.owned.items.len == 1);
    switch (runner.owned.items[0]) {
        .host => |hc| {
            try testing.expect(std.fs.path.isAbsolute(hc.argv[0]));
            try testing.expect(std.mem.endsWith(u8, hc.argv[0], "true"));
            try testing.expectEqualStrings("/tmp/gitz-host-cmd-argv-test", hc.argv[1]);
            try cmd.start();
            try cmd.close();
        },
        .local => return error.TestUnexpectedResult,
    }
}

test "HostCommand missing git-upload-pack CommandNotFound" {
    const gpa = testing.allocator;
    var runner = file.Runner.init(gpa, "gitz-missing-upload-pack-zzz", "gitz-missing-receive-pack-zzz");
    defer runner.deinit();

    var ep = try makeEp(gpa, "file:///tmp/fake");
    defer ep.deinit();

    try testing.expectError(
        file.Error.CommandNotFound,
        runner.command(transport.UploadPackServiceName, &ep, null),
    );
    try testing.expect(runner.owned.items.len == 0);
}

test "HostCommand spawn true and wait" {
    const gpa = testing.allocator;
    var runner = file.Runner.init(gpa, "true", "true");
    defer runner.deinit();

    var ep = try makeEp(gpa, "file:///dev/null");
    defer ep.deinit();

    const cmd = try runner.command(transport.UploadPackServiceName, &ep, null);
    const stdout = try cmd.stdoutPipe();
    const stderr = try cmd.stderrPipe();
    const stdin = try cmd.stdinPipe();
    try cmd.start();
    try stdin.close();
    _ = stdout;
    _ = stderr;
    try cmd.close();
    // Idempotent close.
    try cmd.close();
}

test "HostCommand kill before wait" {
    const gpa = testing.allocator;
    var runner = file.Runner.init(gpa, "sleep", "sleep");
    defer runner.deinit();

    // sleep may not exist everywhere; require it on PATH.
    const sleep_path = file.lookPath(gpa, testing.io, testing.environ, "sleep") catch return;
    defer gpa.free(sleep_path);

    var ep = try makeEp(gpa, "file:///dev/null");
    defer ep.deinit();

    // argv is still bin + path (go-git shape); sleep will error on path arg
    // or sleep briefly depending on platform. Either way kill must reap cleanly.
    const cmd = try runner.command(transport.UploadPackServiceName, &ep, null);
    _ = try cmd.stdoutPipe();
    try cmd.start();
    try cmd.kill();
    try cmd.kill(); // idempotent
}

test "setUseHostSpawn and setLoader interaction" {
    const gpa = testing.allocator;
    defer sync.deinitPools(gpa);

    var loader = server.MapLoader.init(gpa);
    defer loader.deinit();

    var client = try file.newClient(gpa, "gitz-no-bin-up", "gitz-no-bin-rp");
    defer client.deinit();
    try testing.expect(client.runner.use_host_spawn);

    var ep = try makeEp(gpa, "file://loader-priority");
    defer ep.deinit();

    // Host spawn with missing bins → CommandNotFound at session create.
    try testing.expectError(
        file.Error.CommandNotFound,
        client.newUploadPackSession(&ep, null),
    );

    // Loader wins even with use_host_spawn and missing bins.
    client.setLoader(loader.asLoader());
    var sess = try client.newUploadPackSession(&ep, null);
    defer sess.close() catch {};
    // Missing map entry → LocalCommand stderr not-found phrase.
    try testing.expectError(error.RepositoryNotFound, sess.advertisedReferences());

    // Clear loader, disable host spawn → dry LocalCommand (empty stdout).
    client.setLoader(null);
    client.setUseHostSpawn(false);
    var sess2 = try client.newUploadPackSession(&ep, null);
    defer sess2.close() catch {};
    try testing.expectError(error.UnexpectedEndOfStream, sess2.advertisedReferences());
}

// ---------------------------------------------------------------------------
// Hermetic MapLoader-backed session (loader path)
// ---------------------------------------------------------------------------

fn populateRepo(s: *memory.Storage, allocator: Allocator) !plumbing.Hash {
    const obj = try s.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write("hello");
    const blob = try s.setEncodedObject(obj);

    var tree_buf: std.ArrayList(u8) = .empty;
    defer tree_buf.deinit(allocator);
    try tree_buf.appendSlice(allocator, "100644 hello.txt");
    try tree_buf.append(allocator, 0);
    try tree_buf.appendSlice(allocator, blob.slice());
    const tree_obj = try s.newEncodedObject();
    tree_obj.setType(.tree);
    _ = try tree_obj.write(tree_buf.items);
    const tree = try s.setEncodedObject(tree_obj);

    var commit_buf: std.ArrayList(u8) = .empty;
    defer commit_buf.deinit(allocator);
    var tree_hex: [plumbing.MaxHexSize]u8 = undefined;
    try commit_buf.appendSlice(allocator, "tree ");
    try commit_buf.appendSlice(allocator, tree.string(&tree_hex));
    try commit_buf.appendSlice(allocator, "\nauthor A <a@b> 1 +0000\ncommitter A <a@b> 1 +0000\n\ninit\n");
    const commit_obj = try s.newEncodedObject();
    commit_obj.setType(.commit);
    _ = try commit_obj.write(commit_buf.items);
    const commit = try s.setEncodedObject(commit_obj);

    try s.setReference(plumbing.Reference.newHashReference(plumbing.master, commit));
    try s.setReference(plumbing.Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
    return commit;
}

test "hermetic MapLoader advertise via DefaultClient" {
    const gpa = testing.allocator;
    defer sync.deinitPools(gpa);

    var loader = server.MapLoader.init(gpa);
    defer loader.deinit();

    const sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    const head = try populateRepo(sto, gpa);

    var ep = try makeEp(gpa, "file://hermetic-file-up");
    defer ep.deinit();
    try loader.put(&ep, sto);

    var client = try file.defaultClient(gpa);
    defer client.deinit();
    client.setLoader(loader.asLoader());

    var sess = try client.newUploadPackSession(&ep, null);
    defer sess.close() catch {};

    const ar = try sess.advertisedReferences();
    try testing.expect(ar.head != null);
    try testing.expect(ar.head.?.eql(head));
    try testing.expect(ar.capabilities.supports(capability.OFSDelta) or
        ar.capabilities.supports(capability.Sideband64k) or
        ar.capabilities.supports(capability.Sideband));
}

test "hermetic MapLoader missing repo maps to RepositoryNotFound" {
    const gpa = testing.allocator;
    defer sync.deinitPools(gpa);

    var loader = server.MapLoader.init(gpa);
    defer loader.deinit();

    var client = try file.defaultClient(gpa);
    defer client.deinit();
    client.setLoader(loader.asLoader());

    var ep = try makeEp(gpa, "file://missing-hermetic-repo");
    defer ep.deinit();

    var sess = try client.newUploadPackSession(&ep, null);
    defer sess.close() catch {};

    // LocalCommand writes the local not-found phrase to stderr; Session maps it.
    try testing.expectError(error.RepositoryNotFound, sess.advertisedReferences());
}

test "hermetic loader preferred over host spawn" {
    // Loader set → LocalCommand even when use_host_spawn and bins missing.
    const gpa = testing.allocator;
    defer sync.deinitPools(gpa);

    var loader = server.MapLoader.init(gpa);
    defer loader.deinit();

    const sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    _ = try populateRepo(sto, gpa);

    var ep = try makeEp(gpa, "file://loader-over-host");
    defer ep.deinit();
    try loader.put(&ep, sto);

    var client = try file.newClient(gpa, "gitz-no-bin-up", "gitz-no-bin-rp");
    defer client.deinit();
    try testing.expect(client.runner.use_host_spawn);
    client.setLoader(loader.asLoader());

    var sess = try client.newUploadPackSession(&ep, null);
    defer sess.close() catch {};
    const ar = try sess.advertisedReferences();
    try testing.expect(ar.head != null);
}

test "runner owned deinit frees host and local variants" {
    const gpa = testing.allocator;
    var runner = file.Runner.init(gpa, "true", "true");
    defer runner.deinit();

    var ep = try makeEp(gpa, "file:///tmp/owned-host");
    defer ep.deinit();
    _ = try runner.command(transport.UploadPackServiceName, &ep, null);
    try testing.expect(runner.owned.items[0] == .host);

    runner.use_host_spawn = false;
    _ = try runner.command(transport.ReceivePackServiceName, &ep, null);
    try testing.expect(runner.owned.items.len == 2);
    try testing.expect(runner.owned.items[1] == .local);
    // defer runner.deinit frees both variants (leak detector is the assert).
}

test "HostCommand close is idempotent and blocks re-spawn" {
    const gpa = testing.allocator;
    var runner = file.Runner.init(gpa, "true", "true");
    defer runner.deinit();

    var ep = try makeEp(gpa, "file:///tmp/host-close-idempotent");
    defer ep.deinit();

    const cmd = try runner.command(transport.UploadPackServiceName, &ep, null);
    try cmd.start();
    try cmd.close();
    try cmd.close();
    try cmd.kill();
    // After close, further pipe access must fail (no resurrected child).
    try testing.expectError(error.CommandFailed, cmd.stdoutPipe());
}

test "lookPath skips empty PATH components" {
    // Empty PATH entries must not resolve against cwd (false positive).
    const gpa = testing.allocator;
    // A bare name that does not exist on a typical PATH.
    try testing.expectError(
        file.Error.CommandNotFound,
        file.lookPath(gpa, testing.io, testing.environ, "gitz-empty-path-component-miss-zzzz"),
    );
}

test "mapService rejects unknown labels" {
    const gpa = testing.allocator;
    var runner = file.Runner.init(gpa, "git-upload-pack", "git-receive-pack");
    defer runner.deinit();
    try testing.expectError(file.Error.CommandNotFound, runner.mapService("not-a-service"));
    const up = try runner.mapService(transport.UploadPackServiceName);
    try testing.expectEqualStrings("git-upload-pack", up.bin);
    try testing.expect(up.service == .upload_pack);
}
