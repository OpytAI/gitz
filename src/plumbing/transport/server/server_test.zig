//! Unit tests for transport/server (memory MapLoader path).
//!
//! Covers advertise-refs, upload-pack encode, and receive-pack ref updates
//! without network I/O (go-git server suite spirit, hermetic).

const std = @import("std");
const plumbing = @import("plumbing");
const packp = @import("packp");
const capability = @import("capability");
const memory = @import("memory");
const packfile = @import("packfile");
const sync = @import("utils/sync");
const revlist = @import("revlist");
const fs_pkg = @import("fs");
const fixtures = @import("transport_test_fixtures");

const server_pkg = @import("root.zig");
const MapLoader = server_pkg.MapLoader;
const FilesystemLoaderMem = server_pkg.FilesystemLoaderMem;
const newFilesystemLoaderMem = server_pkg.newFilesystemLoaderMem;
const newServer = server_pkg.newServer;
const newClient = server_pkg.newClient;

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const Reference = plumbing.Reference;

const makeEndpoint = fixtures.makeEndpoint;
const populateRepo = fixtures.populateRepo;
const storeBlob = fixtures.storeBlob;
const storeTree = fixtures.storeTree;
const storeCommit = fixtures.storeCommit;
const storeAnnotatedTag = fixtures.storeAnnotatedTag;

// ---------------------------------------------------------------------------
// MapLoader
// ---------------------------------------------------------------------------

test "MapLoader load and miss" {
    const allocator = std.testing.allocator;
    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    var ep = try makeEndpoint(allocator, "file://test-repo");
    defer ep.deinit();

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

test "RepoStorer reference is always caller-owned" {
    const allocator = std.testing.allocator;
    const sto = try memory.newStorage(allocator);
    defer {
        sto.deinit();
        allocator.destroy(sto);
    }
    _ = try populateRepo(sto, allocator);

    const rs = server_pkg.RepoStorer.from(memory.Storage, sto);
    // Memory backend borrows internally; RepoStorer must dupe so free is safe.
    const head = try rs.reference(plumbing.HEAD);
    defer rs.freeReference(head);
    try std.testing.expect(head.type == .symbolic);

    const resolved = try rs.resolveReference(plumbing.HEAD);
    defer rs.freeReference(resolved);
    try std.testing.expect(resolved.type == .hash);

    try std.testing.expect(try rs.hasReference(plumbing.master));
    try std.testing.expect(!try rs.hasReference(plumbing.ReferenceName.init("refs/heads/nope")));
}

// ---------------------------------------------------------------------------
// FilesystemLoader (Mem) — go-git loader_test.go parity + usable DotGit root
// ---------------------------------------------------------------------------

fn writeMemFile(mem: *fs_pkg.Mem, path: []const u8, content: []const u8) !void {
    var f = try mem.create(path);
    defer f.close() catch {};
    if (content.len > 0) _ = try f.write(content);
}

/// Minimal bare git dir under `root` (config + objects/refs scaffolding).
fn seedBareLayout(mem: *fs_pkg.Mem, root: []const u8) !void {
    try mem.mkdirAll(root, 0o755);
    var path_buf: [256]u8 = undefined;
    const config = try std.fmt.bufPrint(&path_buf, "{s}/config", .{root});
    try writeMemFile(mem, config, "[core]\n\tbare = true\n");
    inline for (.{ "objects/pack", "objects/info", "refs/heads", "refs/tags" }) |sub| {
        const p = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ root, sub });
        try mem.mkdirAll(p, 0o755);
    }
}

/// Minimal non-bare worktree: `$root/.git/{config,objects,refs}`.
fn seedNonBareLayout(mem: *fs_pkg.Mem, root: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const git = try std.fmt.bufPrint(&path_buf, "{s}/.git", .{root});
    try seedBareLayout(mem, git);
    // Overwrite bare flag for honesty; layout detection only needs `.git` present.
    const config = try std.fmt.bufPrint(&path_buf, "{s}/.git/config", .{root});
    try writeMemFile(mem, config, "[core]\n\tbare = false\n");
}

/// Write a hash ref through the loaded storer (proves DotGit root is live).
fn writeProbeRef(sto: server_pkg.RepoStorer) !void {
    const h = plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    try sto.setReference(Reference.newHashReference(
        plumbing.ReferenceName.init("refs/heads/loader-check"),
        h,
    ));
}

test "FilesystemLoaderMem loads bare repo" {
    const allocator = std.testing.allocator;

    var mem = try fs_pkg.Mem.init(allocator);
    defer mem.deinit();
    try seedBareLayout(&mem, "/repo");

    var loader = newFilesystemLoaderMem(allocator, &mem);
    defer loader.deinit();

    var ep = try makeEndpoint(allocator, "/repo");
    defer ep.deinit();

    const sto = try loader.load(&ep);
    try writeProbeRef(sto);
    // Loose ref lands under the bare root (not a nested `.git`).
    _ = try mem.stat("/repo/refs/heads/loader-check");
}

test "FilesystemLoaderMem loads non-bare repo via .git" {
    const allocator = std.testing.allocator;

    var mem = try fs_pkg.Mem.init(allocator);
    defer mem.deinit();
    try seedNonBareLayout(&mem, "/work");

    var loader = newFilesystemLoaderMem(allocator, &mem);
    defer loader.deinit();

    var ep = try makeEndpoint(allocator, "/work");
    defer ep.deinit();

    // Storage must be rooted at `.git`, not the worktree.
    const sto = try loader.load(&ep);
    try writeProbeRef(sto);
    _ = try mem.stat("/work/.git/refs/heads/loader-check");
    // Without the `.git` chroot, refs would incorrectly appear under the worktree.
    try std.testing.expectError(error.NotExist, mem.stat("/work/refs/heads/loader-check"));
}

test "FilesystemLoaderMem missing path is RepositoryNotFound" {
    const allocator = std.testing.allocator;

    var mem = try fs_pkg.Mem.init(allocator);
    defer mem.deinit();

    var loader = newFilesystemLoaderMem(allocator, &mem);
    defer loader.deinit();

    var ep = try makeEndpoint(allocator, "/does-not-exist");
    defer ep.deinit();

    try std.testing.expectError(error.RepositoryNotFound, loader.load(&ep));
}

test "FilesystemLoaderMem ignore host on missing path" {
    const allocator = std.testing.allocator;

    var mem = try fs_pkg.Mem.init(allocator);
    defer mem.deinit();

    var loader = newFilesystemLoaderMem(allocator, &mem);
    defer loader.deinit();

    // Host is ignored; only path `/does-not-exist` is resolved on base FS.
    var ep = try makeEndpoint(allocator, "https://github.com/does-not-exist");
    defer ep.deinit();

    try std.testing.expectError(error.RepositoryNotFound, loader.load(&ep));
}

test "FilesystemLoaderMem empty dir without config or .git is RepositoryNotFound" {
    const allocator = std.testing.allocator;

    var mem = try fs_pkg.Mem.init(allocator);
    defer mem.deinit();
    try mem.mkdirAll("/empty", 0o755);

    var loader = newFilesystemLoaderMem(allocator, &mem);
    defer loader.deinit();

    var ep = try makeEndpoint(allocator, "/empty");
    defer ep.deinit();

    try std.testing.expectError(error.RepositoryNotFound, loader.load(&ep));
}

test "FilesystemLoaderMem file URL bare repo" {
    const allocator = std.testing.allocator;

    var mem = try fs_pkg.Mem.init(allocator);
    defer mem.deinit();
    try seedBareLayout(&mem, "/bare.git");

    var loader = FilesystemLoaderMem.init(allocator, &mem);
    defer loader.deinit();

    var ep = try makeEndpoint(allocator, "file:///bare.git");
    defer ep.deinit();
    try std.testing.expectEqualStrings("/bare.git", ep.path);

    const sto = try loader.load(&ep);
    try writeProbeRef(sto);
    _ = try mem.stat("/bare.git/refs/heads/loader-check");
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
    defer ep.deinit();
    try loader.put(&ep, sto);

    var srv = newServer(allocator, loader.asLoader());
    var sess = try srv.newUploadPackSession(&ep, null);
    defer sess.close();

    const ar = try sess.advertisedReferences();
    defer packp.freeAdvRefs(allocator, ar);

    try std.testing.expect(ar.capabilities.supports(capability.Agent));
    try std.testing.expect(ar.capabilities.supports(capability.OFSDelta));
    try std.testing.expect(ar.capabilities.supports(capability.Shallow));
    try std.testing.expect(!ar.capabilities.supports(capability.MultiACK));

    // HEAD / master present.
    try std.testing.expect(ar.head != null);
    _ = head;
}

test "advertise peels annotated tag under refs/tags" {
    const allocator = std.testing.allocator;

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const sto = try memory.newStorage(allocator);
    defer {
        sto.deinit();
        allocator.destroy(sto);
    }
    const commit = try populateRepo(sto, allocator);

    // Lightweight tag: hash ref points at commit — no peeled entry.
    try sto.setReference(Reference.newHashReference(
        plumbing.ReferenceName.init("refs/tags/v-light"),
        commit,
    ));

    // Annotated tag object → commit.
    const tag_hash = try storeAnnotatedTag(sto, allocator, commit, "commit", "v1.0");
    try sto.setReference(Reference.newHashReference(
        plumbing.ReferenceName.init("refs/tags/v1.0"),
        tag_hash,
    ));

    // Tag-of-tag: peel recursively to the commit.
    const outer_tag = try storeAnnotatedTag(sto, allocator, tag_hash, "tag", "v1.0-meta");
    try sto.setReference(Reference.newHashReference(
        plumbing.ReferenceName.init("refs/tags/v1.0-meta"),
        outer_tag,
    ));

    var ep = try makeEndpoint(allocator, "file://peel-repo");
    defer ep.deinit();
    try loader.put(&ep, sto);

    var srv = newServer(allocator, loader.asLoader());
    var sess = try srv.newUploadPackSession(&ep, null);
    defer sess.close();

    const ar = try sess.advertisedReferences();
    defer packp.freeAdvRefs(allocator, ar);

    // Tip refs present with tag object hashes (not commit).
    try std.testing.expect(ar.references.get("refs/tags/v1.0").?.eql(tag_hash));
    try std.testing.expect(ar.references.get("refs/tags/v1.0-meta").?.eql(outer_tag));
    try std.testing.expect(ar.references.get("refs/tags/v-light").?.eql(commit));

    // Peeled map has entry for annotated tags only; value is ultimate non-tag.
    try std.testing.expect(ar.peeled.get("refs/tags/v1.0") != null);
    try std.testing.expect(ar.peeled.get("refs/tags/v1.0").?.eql(commit));
    try std.testing.expect(ar.peeled.get("refs/tags/v1.0-meta") != null);
    try std.testing.expect(ar.peeled.get("refs/tags/v1.0-meta").?.eql(commit));

    // Lightweight tag must not appear in peeled.
    try std.testing.expect(ar.peeled.get("refs/tags/v-light") == null);
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
    defer ep.deinit();
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
    defer ep.deinit();
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
    defer ep.deinit();
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
    defer ep.deinit();
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
    defer ep.deinit();
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
    defer ep.deinit();
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
    defer ep.deinit();
    try loader.put(&ep, sto);

    var srv = newServer(allocator, loader.asLoader());
    var sess = try srv.newUploadPackSession(&ep, null);
    defer sess.close();

    var req = packp.newUploadPackRequest(allocator);
    defer req.deinit();
    // No wants → IsEmpty
    try std.testing.expectError(error.EmptyUploadPackRequest, sess.uploadPack(&req));
}

/// Commit with a single parent (2-commit chain fixture helper).
fn storeCommitWithParent(
    s: *memory.Storage,
    allocator: Allocator,
    tree: Hash,
    parent: Hash,
    msg: []const u8,
) !Hash {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var hex: [plumbing.MaxHexSize]u8 = undefined;
    try buf.appendSlice(allocator, "tree ");
    try buf.appendSlice(allocator, tree.string(&hex));
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, "parent ");
    try buf.appendSlice(allocator, parent.string(&hex));
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

test "upload-pack depth=1 reports shallow tip and omits parent" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const sto = try memory.newStorage(allocator);
    defer {
        sto.deinit();
        allocator.destroy(sto);
    }

    // Two-commit chain: root → child.
    const root = try populateRepo(sto, allocator);
    const blob2 = try storeBlob(sto, "world");
    const tree2 = try storeTree(sto, allocator, blob2, "hello.txt");
    const child = try storeCommitWithParent(sto, allocator, tree2, root, "second\n");
    try sto.setReference(Reference.newHashReference(plumbing.master, child));

    var ep = try makeEndpoint(allocator, "file://up-depth1");
    defer ep.deinit();
    try loader.put(&ep, sto);

    var srv = newServer(allocator, loader.asLoader());
    var sess = try srv.newUploadPackSession(&ep, null);
    defer sess.close();

    const ar = try sess.advertisedReferences();
    defer packp.freeAdvRefs(allocator, ar);
    try std.testing.expect(ar.capabilities.supports(capability.Shallow));

    var req = packp.newUploadPackRequest(allocator);
    defer req.deinit();
    try req.upload_request.wants.append(allocator, child);
    req.upload_request.depth = .{ .commits = 1 };
    try req.upload_request.capabilities.set(capability.Shallow, &.{});
    if (ar.capabilities.supports(capability.OFSDelta)) {
        try req.upload_request.capabilities.set(capability.OFSDelta, &.{});
    }

    const resp = try sess.uploadPack(&req);
    defer packp.freeUploadPackResponse(allocator, resp);

    try std.testing.expect(resp.is_shallow);
    try std.testing.expectEqual(@as(usize, 1), resp.shallow_update.shallows.items.len);
    try std.testing.expect(resp.shallow_update.shallows.items[0].eql(root));

    const pack_bytes = try readPackBytes(allocator, resp);
    defer allocator.free(pack_bytes);
    try std.testing.expect(pack_bytes.len > 12);

    var obj_store = packfile.ObjectStore.init(allocator);
    defer obj_store.deinit();
    _ = try packfile.updateObjectStorage(allocator, &obj_store, pack_bytes);

    // Tip commit is in the pack; parent (shallow boundary) is not.
    _ = try obj_store.get(child);
    try std.testing.expectError(error.ObjectNotFound, obj_store.get(root));
}

test "upload-pack with client shallows deepen does not reject" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var loader = MapLoader.init(allocator);
    defer loader.deinit();

    const sto = try memory.newStorage(allocator);
    defer {
        sto.deinit();
        allocator.destroy(sto);
    }

    // root → mid → tip  (client previously fetched depth=1: has tip, shallow=mid)
    const root = try populateRepo(sto, allocator);
    const blob_m = try storeBlob(sto, "mid");
    const tree_m = try storeTree(sto, allocator, blob_m, "mid.txt");
    const mid = try storeCommitWithParent(sto, allocator, tree_m, root, "mid\n");
    const blob_t = try storeBlob(sto, "tip");
    const tree_t = try storeTree(sto, allocator, blob_t, "tip.txt");
    const tip = try storeCommitWithParent(sto, allocator, tree_t, mid, "tip\n");
    try sto.setReference(Reference.newHashReference(plumbing.master, tip));

    var ep = try makeEndpoint(allocator, "file://up-client-shallow");
    defer ep.deinit();
    try loader.put(&ep, sto);

    var srv = newServer(allocator, loader.asLoader());
    var sess = try srv.newUploadPackSession(&ep, null);
    defer sess.close();

    const ar = try sess.advertisedReferences();
    defer packp.freeAdvRefs(allocator, ar);

    // Deepen to 2 with existing client shallow at mid (go-git would reject).
    var req = packp.newUploadPackRequest(allocator);
    defer req.deinit();
    try req.upload_request.wants.append(allocator, tip);
    try req.upload_request.shallows.append(allocator, mid);
    req.upload_request.depth = .{ .commits = 2 };
    try req.upload_request.capabilities.set(capability.Shallow, &.{});
    if (ar.capabilities.supports(capability.OFSDelta)) {
        try req.upload_request.capabilities.set(capability.OFSDelta, &.{});
    }

    const resp = try sess.uploadPack(&req);
    defer packp.freeUploadPackResponse(allocator, resp);

    try std.testing.expect(resp.is_shallow);
    // New shallow edge is root; mid is already client-listed so not re-reported.
    try std.testing.expectEqual(@as(usize, 1), resp.shallow_update.shallows.items.len);
    try std.testing.expect(resp.shallow_update.shallows.items[0].eql(root));

    const pack_bytes = try readPackBytes(allocator, resp);
    defer allocator.free(pack_bytes);

    var obj_store = packfile.ObjectStore.init(allocator);
    defer obj_store.deinit();
    _ = try packfile.updateObjectStorage(allocator, &obj_store, pack_bytes);

    // tip + mid within depth 2; root is the new shallow boundary (omitted).
    _ = try obj_store.get(tip);
    _ = try obj_store.get(mid);
    try std.testing.expectError(error.ObjectNotFound, obj_store.get(root));
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
