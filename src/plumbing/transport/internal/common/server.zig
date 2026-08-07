//! Server-side helpers that drive a session over stdio
//! (go-git `plumbing/transport/internal/common/server.go`).

const std = @import("std");
const packp = @import("packp");

const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

/// go-git `ServerCommand` — stdio handles for one server command execution.
pub const ServerCommand = struct {
    stderr: ?*Writer = null,
    stdout: *Writer,
    stdin: *Reader,
};

/// go-git `ServeUploadPack` — advertise → decode request → upload-pack → encode response.
///
/// `session` must provide:
/// - `advertisedReferences() !*packp.AdvRefs`
/// - `uploadPack(*const UploadPackRequest) !*packp.UploadPackResponse`
pub fn serveUploadPack(allocator: Allocator, cmd: ServerCommand, session: anytype) !void {
    const ar = try session.advertisedReferences();
    defer packp.freeAdvRefs(allocator, ar);
    try ar.encode(cmd.stdout);

    var req = packp.newUploadPackRequest(allocator);
    defer req.deinit();
    try req.upload_request.decode(cmd.stdin);

    const resp = try session.uploadPack(&req);
    defer packp.freeUploadPackResponse(allocator, resp);
    try resp.encode(cmd.stdout);
}

/// go-git `ServeReceivePack`.
///
/// `session` must provide advertise + `receivePackOutcome(*const ReferenceUpdateRequest)`.
pub fn serveReceivePack(allocator: Allocator, cmd: ServerCommand, session: anytype) !void {
    const ar = session.advertisedReferences() catch {
        return error.InternalAdvertisedReferences;
    };
    defer packp.freeAdvRefs(allocator, ar);

    ar.encode(cmd.stdout) catch return error.AdvertisedReferencesEncode;

    var req = packp.newReferenceUpdateRequest(allocator) catch {
        return error.DecodeRequest;
    };
    defer req.deinit();
    req.decode(cmd.stdin) catch return error.DecodeRequest;

    const out = try session.receivePackOutcome(&req);
    defer if (out.report) |rs| packp.freeReportStatus(allocator, rs);
    if (out.report) |rs| {
        rs.encode(cmd.stdout) catch return error.ReportStatusEncode;
    }
    if (out.err) |e| return e;
}
