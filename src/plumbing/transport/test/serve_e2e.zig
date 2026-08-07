//! End-to-end: `serveUploadPack` / `serveReceivePack` over memory buffers.
//!
//! Cross-package: server sessions + common serve helpers (go-git ServerCommand
//! stdio path). Lives in `plumbing/transport/test`, not inside either package.

const std = @import("std");
const plumbing = @import("plumbing");
const packp = @import("packp");
const capability = @import("capability");
const memory = @import("memory");
const sync = @import("utils/sync");
const transport_server = @import("server");
const transport_common = @import("transport_common");
const fixtures = @import("fixtures.zig");

const MapLoader = transport_server.MapLoader;
const newServer = transport_server.newServer;
const serveUploadPack = transport_common.serveUploadPack;
const serveReceivePack = transport_common.serveReceivePack;

const Allocator = std.mem.Allocator;
const ZeroHash = plumbing.ZeroHash;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

fn looksLikePktLinePrefix(buf: []const u8) bool {
    if (buf.len < 4) return false;
    for (buf[0..4]) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

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
    const head = try fixtures.populateRepo(sto, allocator);

    var ep = try fixtures.makeEndpoint(allocator, "file://serve-up-e2e");
    defer ep.deinit();
    try loader.put(&ep, sto);

    var srv = newServer(allocator, loader.asLoader());
    var sess = try srv.newUploadPackSession(&ep, null);
    defer sess.close();

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

    try serveUploadPack(allocator, .{
        .stdin = &stdin_reader,
        .stdout = &stdout_aw.writer,
    }, &sess);

    const out = stdout_aw.written();
    try std.testing.expect(out.len > 0);
    try std.testing.expect(looksLikePktLinePrefix(out));

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
    try std.testing.expect(std.mem.indexOf(u8, out, "PACK") != null);
}

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
    const head = try fixtures.populateRepo(sto, allocator);

    var ep = try fixtures.makeEndpoint(allocator, "file://serve-rp-e2e");
    defer ep.deinit();
    try loader.put(&ep, sto);

    var srv = newServer(allocator, loader.asLoader());
    var sess = try srv.newReceivePackSession(&ep, null);
    defer sess.close();

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

    try serveReceivePack(allocator, .{
        .stdin = &stdin_reader,
        .stdout = &stdout_aw.writer,
    }, &sess);

    const got = try sto.reference(plumbing.ReferenceName.init("refs/heads/topic"));
    try std.testing.expect(got.hash.eql(head));

    const out = stdout_aw.written();
    try std.testing.expect(out.len > 0);
    try std.testing.expect(looksLikePktLinePrefix(out));

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
