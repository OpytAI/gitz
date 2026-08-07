//! End-to-end tests for `serveUploadPack` / `serveReceivePack` over in-memory
//! buffers (pipe simulation of go-git `ServerCommand` stdio).

const std = @import("std");
const plumbing = @import("plumbing");
const transport = @import("transport");
const packp = @import("packp");
const capability = @import("capability");
const memory = @import("memory");
const sync = @import("utils/sync");
const server_pkg = @import("server");
const server_mod = @import("server.zig");

const MapLoader = server_pkg.MapLoader;
const newServer = server_pkg.newServer;
const ServerCommand = server_mod.ServerCommand;
const serveUploadPack = server_mod.serveUploadPack;
const serveReceivePack = server_mod.serveReceivePack;

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const Reference = plumbing.Reference;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

// ---------------------------------------------------------------------------
// Helpers (minimal copies of transport/server/server_test populate pattern)
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

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn looksLikePktLinePrefix(buf: []const u8) bool {
    if (buf.len < 4) return false;
    return isHexDigit(buf[0]) and isHexDigit(buf[1]) and isHexDigit(buf[2]) and isHexDigit(buf[3]);
}

// ---------------------------------------------------------------------------
// serveUploadPack e2e
// ---------------------------------------------------------------------------

test "serveUploadPack e2e over memory buffers" {
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

    var ep = try makeEndpoint(allocator, "file://serve-up-e2e");
    defer freeEndpoint(allocator, &ep);
    try loader.put(&ep, sto);

    var srv = newServer(allocator, loader.asLoader());
    var sess = try srv.newUploadPackSession(&ep, null);
    defer sess.close();

    // Client stdin: wants=[head] + caps (mirrors go-git UploadRequest encode).
    var stdin_aw: Writer.Allocating = .init(allocator);
    defer stdin_aw.deinit();
    {
        var client_req = packp.newUploadPackRequest(allocator);
        defer client_req.deinit();
        try client_req.upload_request.wants.append(allocator, head);
        try client_req.upload_request.capabilities.set(capability.OFSDelta, &.{});
        try client_req.upload_request.encode(&stdin_aw.writer);
    }
    var stdin_reader: Reader = .fixed(stdin_aw.written());

    var stdout_aw: Writer.Allocating = .init(allocator);
    defer stdout_aw.deinit();

    const cmd = ServerCommand{
        .stdin = &stdin_reader,
        .stdout = &stdout_aw.writer,
    };
    try serveUploadPack(allocator, cmd, &sess);

    const out = stdout_aw.written();
    try std.testing.expect(out.len > 0);
    try std.testing.expect(looksLikePktLinePrefix(out));

    // Parse AdvRefs then UploadPackResponse (NAK + pack stream).
    var out_reader: Reader = .fixed(out);
    var ar = packp.AdvRefs.init(allocator);
    defer ar.deinit();
    try ar.decode(&out_reader);
    try std.testing.expect(ar.head != null);
    try std.testing.expect(ar.head.?.eql(head));

    var parse_req = packp.newUploadPackRequest(allocator);
    defer parse_req.deinit();
    try parse_req.upload_request.wants.append(allocator, head);
    var resp = packp.UploadPackResponse.init(allocator, &parse_req);
    defer resp.deinit();
    try resp.decodeNopClose(&out_reader);

    const pack_bytes = try resp.readAll(allocator);
    defer allocator.free(pack_bytes);
    try std.testing.expect(pack_bytes.len >= 4);
    try std.testing.expectEqualStrings("PACK", pack_bytes[0..4]);

    // Also require pack signature present in the demuxed stdout tail path
    // (NAK pkt-line then raw pack).
    try std.testing.expect(std.mem.indexOf(u8, out, "PACK") != null);
}

// ---------------------------------------------------------------------------
// serveReceivePack e2e
// ---------------------------------------------------------------------------

test "serveReceivePack e2e create ref and report-status" {
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

    var ep = try makeEndpoint(allocator, "file://serve-rp-e2e");
    defer freeEndpoint(allocator, &ep);
    try loader.put(&ep, sto);

    var srv = newServer(allocator, loader.asLoader());
    var sess = try srv.newReceivePackSession(&ep, null);
    defer sess.close();

    // Client stdin: create refs/heads/topic → head, with report-status.
    var stdin_aw: Writer.Allocating = .init(allocator);
    defer stdin_aw.deinit();
    {
        var client_req = try packp.newReferenceUpdateRequest(allocator);
        defer client_req.deinit();
        try client_req.capabilities.set(capability.ReportStatus, &.{});
        try client_req.appendCommand(.{
            .name = plumbing.ReferenceName.init("refs/heads/topic"),
            .old = ZeroHash,
            .new = head,
        });
        try client_req.encode(&stdin_aw.writer);
    }
    var stdin_reader: Reader = .fixed(stdin_aw.written());

    var stdout_aw: Writer.Allocating = .init(allocator);
    defer stdout_aw.deinit();

    const cmd = ServerCommand{
        .stdin = &stdin_reader,
        .stdout = &stdout_aw.writer,
    };
    try serveReceivePack(allocator, cmd, &sess);

    // Ref created in storage.
    const got = try sto.reference(plumbing.ReferenceName.init("refs/heads/topic"));
    try std.testing.expect(got.hash.eql(head));

    const out = stdout_aw.written();
    try std.testing.expect(out.len > 0);
    try std.testing.expect(looksLikePktLinePrefix(out));

    // AdvRefs then report-status on stdout when capability set.
    var out_reader: Reader = .fixed(out);
    var ar = packp.AdvRefs.init(allocator);
    defer ar.deinit();
    try ar.decode(&out_reader);
    try std.testing.expect(ar.capabilities.supports(capability.ReportStatus));

    var rs = packp.ReportStatus.init(allocator);
    defer rs.deinit();
    try rs.decode(&out_reader);
    try std.testing.expect(rs.isOk());
    try std.testing.expectEqualStrings("ok", rs.unpack_status);

    var found_topic = false;
    for (rs.command_statuses.items) |cs| {
        if (std.mem.eql(u8, cs.reference_name.raw, "refs/heads/topic")) {
            found_topic = true;
            try std.testing.expectEqualStrings("ok", cs.status);
        }
    }
    try std.testing.expect(found_topic);
}
