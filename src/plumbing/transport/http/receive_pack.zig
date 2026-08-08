//! HTTP git-receive-pack session (go-git `plumbing/transport/http/receive_pack.go`).

const std = @import("std");
const transport = @import("transport");
const packp = @import("packp");
const capability = @import("capability");
const sideband = @import("sideband");
const ioutil = @import("ioutil");

const common = @import("common.zig");

const Endpoint = transport.Endpoint;
const testing = std.testing;

/// Receive-pack session over HTTP (go-git `rpSession`).
pub const ReceivePackSession = struct {
    session: common.Session,

    pub fn close(self: *ReceivePackSession) void {
        self.session.close();
    }

    /// go-git `AdvertisedReferences`.
    pub fn advertisedReferences(self: *ReceivePackSession) !*packp.AdvRefs {
        return self.session.advertisedReferences(transport.ReceivePackServiceName);
    }

    /// go-git `AdvertisedReferencesContext`.
    pub fn advertisedReferencesContext(self: *ReceivePackSession) !*packp.AdvRefs {
        return self.advertisedReferences();
    }

    /// go-git `ReceivePack` — POST update-request, decode report-status.
    ///
    /// Returns null when the response body is empty (go-git empty reader → nil).
    /// Caller owns a non-null report: free with `packp.freeReportStatus`.
    /// go-git also returns `report.Error()` as a second result; callers check
    /// `report.err()` / `report.isOk()` after a successful decode.
    pub fn receivePack(
        self: *ReceivePackSession,
        req: *packp.ReferenceUpdateRequest,
    ) !?*packp.ReportStatus {
        const url = try common.serviceURL(
            self.session.allocator,
            self.session.endpoint,
            transport.ReceivePackServiceName,
        );
        defer self.session.allocator.free(url);

        var aw: std.Io.Writer.Allocating = .init(self.session.allocator);
        defer aw.deinit();
        try req.encode(&aw.writer);
        const body = aw.written();

        var res = try self.session.doPost(transport.ReceivePackServiceName, url, body);
        defer res.deinit();

        if (res.body.len == 0) return null;

        var reader: std.Io.Reader = .fixed(res.body);
        ioutil.nonEmptyReader(&reader) catch |err| {
            if (err == error.EmptyReader) return null;
            return err;
        };
        reader = .fixed(res.body);

        var body_buf: ?[]u8 = null;
        defer if (body_buf) |b| self.session.allocator.free(b);

        var decode_reader: *std.Io.Reader = &reader;
        var demuxed_reader: std.Io.Reader = undefined;

        if (req.capabilities.supports(capability.Sideband64k) or
            req.capabilities.supports(capability.Sideband))
        {
            const demux_type: sideband.Type = if (req.capabilities.supports(capability.Sideband64k))
                .sideband64k
            else
                .sideband;
            var demux = sideband.Demuxer.init(demux_type, &reader);
            demux.progress = req.progress;

            var collected: std.ArrayListUnmanaged(u8) = .empty;
            errdefer collected.deinit(self.session.allocator);
            var chunk: [4096]u8 = undefined;
            while (true) {
                const n = demux.read(&chunk) catch |e| switch (e) {
                    error.EndOfStream => break,
                    else => |err| return err,
                };
                if (n == 0) {
                    if (demux.last_n == 0) break;
                    try collected.appendSlice(self.session.allocator, chunk[0..demux.last_n]);
                    break;
                }
                try collected.appendSlice(self.session.allocator, chunk[0..n]);
            }
            body_buf = try collected.toOwnedSlice(self.session.allocator);
            demuxed_reader = .fixed(body_buf.?);
            decode_reader = &demuxed_reader;
        }

        const report = try packp.newReportStatus(self.session.allocator);
        errdefer packp.freeReportStatus(self.session.allocator, report);
        try report.decode(decode_reader);
        return report;
    }
};

/// go-git `newReceivePackSession`.
pub fn newReceivePackSession(
    c: *common.Client,
    ep: *Endpoint,
    auth: ?transport.AuthMethod,
) !ReceivePackSession {
    const s = try c.newSession(ep, auth);
    return .{ .session = s };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ReceivePackSession empty repo AdvRefs allowed" {
    const gpa = testing.allocator;
    var mock = common.MockRoundTripper.init(gpa);
    defer mock.deinit();
    // Body "0000" is a single flush → EmptyAdvRefs on decode → EmptyRemoteRepository.
    // go-git still maps EmptyAdvRefs to ErrEmptyRemoteRepository before the
    // post-decode empty exemption for receive-pack.
    try mock.push(.{ .status_code = 200, .body = "0000" });

    var client = try common.Client.init(gpa, mock.asRoundTripper(), .{});
    defer client.deinit();
    var ep = try transport.newEndpoint(gpa, testing.io, "https://example.com/empty.git");
    defer ep.deinit();

    var sess = try newReceivePackSession(&client, &ep, null);
    defer sess.close();
    try testing.expectError(transport.Error.EmptyRemoteRepository, sess.advertisedReferences());
}

test "ReceivePackSession 401 AuthenticationRequired" {
    const gpa = testing.allocator;
    var mock = common.MockRoundTripper.init(gpa);
    defer mock.deinit();
    try mock.push(.{ .status_code = 401, .body = "auth" });

    var client = try common.Client.init(gpa, mock.asRoundTripper(), .{});
    defer client.deinit();
    var ep = try transport.newEndpoint(gpa, testing.io, "https://example.com/priv.git");
    defer ep.deinit();

    var sess = try newReceivePackSession(&client, &ep, null);
    defer sess.close();
    try testing.expectError(transport.Error.AuthenticationRequired, sess.advertisedReferences());
}

test "ReceivePackSession service URL uses receive-pack" {
    const gpa = testing.allocator;
    var ep = try transport.newEndpoint(gpa, testing.io, "http://host/repo.git");
    defer ep.deinit();
    const u = try common.serviceURL(gpa, &ep, transport.ReceivePackServiceName);
    defer gpa.free(u);
    try testing.expectEqualStrings("http://host/repo.git/git-receive-pack", u);
}
