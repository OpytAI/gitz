//! Unit tests for transport/server (memory MapLoader path).
//!
//! Covers advertise-refs, upload-pack encode, and receive-pack ref updates
//! without network I/O (go-git server suite spirit, hermetic).

const std = @import("std");
const plumbing = @import("plumbing");
const transport = @import("transport");
const packp = @import("packp");
const capability = @import("capability");
const memory = @import("memory");
const packfile = @import("packfile");
const sync = @import("utils/sync");
const revlist = @import("revlist");

const server_pkg = @import("root.zig");
const MapLoader = server_pkg.MapLoader;
const newServer = server_pkg.newServer;
const newClient = server_pkg.newClient;

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const Reference = plumbing.Reference;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn makeEndpoint(allocator: Allocator, url: []const u8) !transport.Endpoint {
    return transport.newEndpoint(allocator, std.testing.io, url);
}

fn freeEndpoint(allocator: Allocator, ep: *transport.Endpoint) void {
    _ = allocator;
    ep.deinit();
}

fn storeBlob(s: *memory.Storage, content: []const u8) !Hash {
    const obj = try s.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write(content);
    return s.setEncodedObject(obj);
}

fn storeTree(s: *memory.Storage, allocator: Allocator, blob: Hash, name: []const u8) !Hash {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "100644 ");
    try buf.appendSlice(allocator, name);
    try buf.append(allocator, 0);
    try buf.appendSlice(allocator, blob.bytes[0..]);
    const obj = try s.newEncodedObject();
    obj.setType(.tree);
    _ = try obj.write(buf.items);
    return s.setEncodedObject(obj);
}

fn storeCommit(s: *memory.Storage, allocator: Allocator, tree: Hash, msg: []const u8) !Hash {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var tree_hex: [plumbing.HexSize]u8 = undefined;
    try buf.appendSlice(allocator, "tree ");
    try buf.appendSlice(allocator, tree.string(&tree_hex));
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, "author A <a@b> 1 +0000\n");
    try buf.appendSlice(allocator, "committer A <a@b> 1 +0000\n");
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, msg);
    const obj = try s.newEncodedObject();
    obj.setType(.commit);
    _ = try obj.write(buf.items);
    return s.setEncodedObject(obj);
}

fn populateRepo(s: *memory.Storage, allocator: Allocator) !Hash {
    const blob = try storeBlob(s, "hello");
    const tree = try storeTree(s, allocator, blob, "hello.txt");
    const commit = try storeCommit(s, allocator, tree, "init\n");
    try s.setReference(Reference.newHashReference(plumbing.master, commit));
    try s.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
    return commit;
}

// ---------------------------------------------------------------------------
// MapLoader
// ---------------------------------------------------------------------------

test "MapLoader load and miss" {
    const allocator = std.testing.allocator;
    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    var ep = try makeEndpoint(allocator, "file://test-repo");
    defer freeEndpoint(allocator, &ep);

    try std.testing.expectError(error.RepositoryNotFound, loader.load(&ep));

    const sto = try memory.newStorage(allocator);
    defer {
        sto.deinit();
        allocator.destroy(sto);
    }
    try loader.put(&ep, sto);

    const got = try loader.load(&ep);
    // Same underlying pointer for memory storage.
    try std.testing.expect(got.ptr == @as(*anyopaque, @ptrCast(sto)));
}

// ---------------------------------------------------------------------------
// Advertise refs
// ---------------------------------------------------------------------------

test "advertise refs on memory storage" {
    const allocator = std.testing.allocator;

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const sto = try memory.newStorage(allocator);
    defer {
        sto.deinit();
        allocator.destroy(sto);
    }
    const head = try populateRepo(sto, allocator);

    var ep = try makeEndpoint(allocator, "file://adv-repo");
    defer freeEndpoint(allocator, &ep);
    try loader.put(&ep, sto);

    var srv = newServer(allocator, loader.asLoader());
    var sess = try srv.newUploadPackSession(&ep, null);
    defer sess.close();

    const ar = try sess.advertisedReferences();
    defer packp.freeAdvRefs(allocator, ar);

    try std.testing.expect(ar.capabilities.supports(capability.Agent));
    try std.testing.expect(ar.capabilities.supports(capability.OFSDelta));
    try std.testing.expect(!ar.capabilities.supports(capability.MultiACK));

    // HEAD / master present.
    try std.testing.expect(ar.head != null);
    _ = head;
}

test "asClient empty repo yields EmptyRemoteRepository" {
    const allocator = std.testing.allocator;

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const sto = try memory.newStorage(allocator);
    defer {
        sto.deinit();
        allocator.destroy(sto);
    }

    var ep = try makeEndpoint(allocator, "file://empty-repo");
    defer freeEndpoint(allocator, &ep);
    try loader.put(&ep, sto);

    var client = newClient(allocator, loader.asLoader());
    var sess = try client.newUploadPackSession(&ep, null);
    defer sess.close();

    try std.testing.expectError(error.EmptyRemoteRepository, sess.advertisedReferences());
}

test "receive-pack advertise empty repo is ok" {
    const allocator = std.testing.allocator;

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const sto = try memory.newStorage(allocator);
    defer {
        sto.deinit();
        allocator.destroy(sto);
    }

    var ep = try makeEndpoint(allocator, "file://empty-rp");
    defer freeEndpoint(allocator, &ep);
    try loader.put(&ep, sto);

    var srv = newServer(allocator, loader.asLoader());
    var sess = try srv.newReceivePackSession(&ep, null);
    defer sess.close();

    const ar = try sess.advertisedReferences();
    defer packp.freeAdvRefs(allocator, ar);
    try std.testing.expect(ar.capabilities.supports(capability.ReportStatus));
    try std.testing.expect(ar.capabilities.supports(capability.DeleteRefs));
}

// ---------------------------------------------------------------------------
// Upload-pack
// ---------------------------------------------------------------------------

test "upload-pack roundtrip pack objects" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const sto = try memory.newStorage(allocator);
    defer {
        sto.deinit();
        allocator.destroy(sto);
    }
    const head = try populateRepo(sto, allocator);

    var ep = try makeEndpoint(allocator, "file://up-repo");
    defer freeEndpoint(allocator, &ep);
    try loader.put(&ep, sto);

    var srv = newServer(allocator, loader.asLoader());
    var sess = try srv.newUploadPackSession(&ep, null);
    defer sess.close();

    // Need capabilities set from advertise first (optional for our ensureCaps path).
    const ar = try sess.advertisedReferences();
    defer packp.freeAdvRefs(allocator, ar);

    var req = packp.newUploadPackRequest(allocator);
    defer req.deinit();
    try req.upload_request.wants.append(allocator, head);
    // Mirror go-git: optional agent/ofs-delta from server.
    if (ar.capabilities.supports(capability.OFSDelta)) {
        try req.upload_request.capabilities.set(capability.OFSDelta, &.{});
    }

    const resp = try sess.uploadPack(&req);
    defer packp.freeUploadPackResponse(allocator, resp);

    const pack_bytes = try readPackBytes(allocator, resp);
    defer allocator.free(pack_bytes);
    try std.testing.expect(pack_bytes.len > 12);

    // Ingest into a fresh ObjectStore and check commit is present.
    var obj_store = packfile.ObjectStore.init(allocator);
    defer obj_store.deinit();
    _ = try packfile.updateObjectStorage(allocator, &obj_store, pack_bytes);
    _ = try obj_store.get(head);

    // Reachable set non-empty from source store.
    const objs = try revlist.objects(allocator, sto, &.{head}, &.{});
    defer allocator.free(objs);
    try std.testing.expect(objs.len >= 1);
}

// ---------------------------------------------------------------------------
// Receive-pack ref updates (no pack / with pack)
// ---------------------------------------------------------------------------

test "receive-pack create update delete refs" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const sto = try memory.newStorage(allocator);
    defer {
        sto.deinit();
        allocator.destroy(sto);
    }
    const head = try populateRepo(sto, allocator);

    // Second commit object already in store for update target.
    const blob2 = try storeBlob(sto, "world");
    const tree2 = try storeTree(sto, allocator, blob2, "hello.txt");
    const head2 = try storeCommit(sto, allocator, tree2, "second\n");

    var ep = try makeEndpoint(allocator, "file://rp-repo");
    defer freeEndpoint(allocator, &ep);
    try loader.put(&ep, sto);

    var srv = newServer(allocator, loader.asLoader());
    var sess = try srv.newReceivePackSession(&ep, null);
    defer sess.close();

    const ar = try sess.advertisedReferences();
    defer packp.freeAdvRefs(allocator, ar);

    // --- Create refs/heads/topic ---
    {
        var req = try packp.newReferenceUpdateRequest(allocator);
        defer req.deinit();
        try req.capabilities.set(capability.ReportStatus, &.{});
        try req.appendCommand(.{
            .name = plumbing.ReferenceName.init("refs/heads/topic"),
            .old = ZeroHash,
            .new = head,
        });

        const out = try sess.receivePackOutcome(&req);
        defer if (out.report) |r| packp.freeReportStatus(allocator, r);
        try std.testing.expect(out.err == null);

        const got = try sto.reference(plumbing.ReferenceName.init("refs/heads/topic"));
        try std.testing.expect(got.hash.eql(head));
    }

    // --- Update refs/heads/topic ---
    {
        // Fresh session (go-git often one shot; re-open is fine).
        var sess2 = try srv.newReceivePackSession(&ep, null);
        defer sess2.close();
        const ar2 = try sess2.advertisedReferences();
        defer packp.freeAdvRefs(allocator, ar2);

        var req = try packp.newReferenceUpdateRequest(allocator);
        defer req.deinit();
        try req.capabilities.set(capability.ReportStatus, &.{});
        try req.appendCommand(.{
            .name = plumbing.ReferenceName.init("refs/heads/topic"),
            .old = head,
            .new = head2,
        });

        const out = try sess2.receivePackOutcome(&req);
        defer if (out.report) |r| packp.freeReportStatus(allocator, r);
        try std.testing.expect(out.err == null);

        const got = try sto.reference(plumbing.ReferenceName.init("refs/heads/topic"));
        try std.testing.expect(got.hash.eql(head2));
    }

    // --- Delete refs/heads/topic ---
    {
        var sess3 = try srv.newReceivePackSession(&ep, null);
        defer sess3.close();
        const ar3 = try sess3.advertisedReferences();
        defer packp.freeAdvRefs(allocator, ar3);

        var req = try packp.newReferenceUpdateRequest(allocator);
        defer req.deinit();
        try req.capabilities.set(capability.ReportStatus, &.{});
        try req.capabilities.set(capability.DeleteRefs, &.{});
        try req.appendCommand(.{
            .name = plumbing.ReferenceName.init("refs/heads/topic"),
            .old = head2,
            .new = ZeroHash,
        });

        const out = try sess3.receivePackOutcome(&req);
        defer if (out.report) |r| packp.freeReportStatus(allocator, r);
        try std.testing.expect(out.err == null);

        try std.testing.expectError(
            error.ReferenceNotFound,
            sto.reference(plumbing.ReferenceName.init("refs/heads/topic")),
        );
    }
}

test "receive-pack create fails when ref exists" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const sto = try memory.newStorage(allocator);
    defer {
        sto.deinit();
        allocator.destroy(sto);
    }
    const head = try populateRepo(sto, allocator);

    var ep = try makeEndpoint(allocator, "file://rp-exists");
    defer freeEndpoint(allocator, &ep);
    try loader.put(&ep, sto);

    var srv = newServer(allocator, loader.asLoader());
    var sess = try srv.newReceivePackSession(&ep, null);
    defer sess.close();
    const ar = try sess.advertisedReferences();
    defer packp.freeAdvRefs(allocator, ar);

    var req = try packp.newReferenceUpdateRequest(allocator);
    defer req.deinit();
    try req.capabilities.set(capability.ReportStatus, &.{});
    // Create master while it already exists.
    try req.appendCommand(.{
        .name = plumbing.master,
        .old = ZeroHash,
        .new = head,
    });

    const out = try sess.receivePackOutcome(&req);
    defer if (out.report) |r| packp.freeReportStatus(allocator, r);
    try std.testing.expect(out.err != null);
}

test "receive-pack atomic rejects all when one command invalid" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const sto = try memory.newStorage(allocator);
    defer {
        sto.deinit();
        allocator.destroy(sto);
    }
    const head = try populateRepo(sto, allocator);

    var ep = try makeEndpoint(allocator, "file://rp-atomic");
    defer freeEndpoint(allocator, &ep);
    try loader.put(&ep, sto);

    var srv = newServer(allocator, loader.asLoader());
    var sess = try srv.newReceivePackSession(&ep, null);
    defer sess.close();
    const ar = try sess.advertisedReferences();
    defer packp.freeAdvRefs(allocator, ar);
    try std.testing.expect(ar.capabilities.supports(capability.Atomic));

    var req = try packp.newReferenceUpdateRequest(allocator);
    defer req.deinit();
    try req.capabilities.set(capability.ReportStatus, &.{});
    try req.capabilities.set(capability.Atomic, &.{});
    // Valid create of a new branch…
    try req.appendCommand(.{
        .name = plumbing.ReferenceName.init("refs/heads/topic"),
        .old = ZeroHash,
        .new = head,
    });
    // …and invalid create of master (already exists).
    try req.appendCommand(.{
        .name = plumbing.master,
        .old = ZeroHash,
        .new = head,
    });

    const out = try sess.receivePackOutcome(&req);
    defer if (out.report) |r| packp.freeReportStatus(allocator, r);
    try std.testing.expect(out.err != null);
    // Atomic: neither ref should have been created/changed for the valid command.
    try std.testing.expectError(
        error.ReferenceNotFound,
        sto.reference(plumbing.ReferenceName.init("refs/heads/topic")),
    );
}

test "upload-pack empty request" {
    const allocator = std.testing.allocator;

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const sto = try memory.newStorage(allocator);
    defer {
        sto.deinit();
        allocator.destroy(sto);
    }
    _ = try populateRepo(sto, allocator);

    var ep = try makeEndpoint(allocator, "file://up-empty");
    defer freeEndpoint(allocator, &ep);
    try loader.put(&ep, sto);

    var srv = newServer(allocator, loader.asLoader());
    var sess = try srv.newUploadPackSession(&ep, null);
    defer sess.close();

    var req = packp.newUploadPackRequest(allocator);
    defer req.deinit();
    // No wants → IsEmpty
    try std.testing.expectError(error.EmptyUploadPackRequest, sess.uploadPack(&req));
}

fn readPackBytes(allocator: Allocator, resp: *packp.UploadPackResponse) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    if (resp.r) |rc| {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try rc.reader.readSliceShort(&buf);
            if (n == 0) break;
            try list.appendSlice(allocator, buf[0..n]);
        }
    }
    return try list.toOwnedSlice(allocator);
}
