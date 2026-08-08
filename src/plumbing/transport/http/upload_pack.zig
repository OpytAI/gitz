//! HTTP git-upload-pack session (go-git `plumbing/transport/http/upload_pack.go`).

const std = @import("std");
const transport = @import("transport");
const packp = @import("packp");
const pktline = @import("pktline");
const ioutil = @import("ioutil");
const transport_common = @import("transport_common");

const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const Endpoint = transport.Endpoint;
const testing = std.testing;

/// Upload-pack session over HTTP (go-git `upSession`).
pub const UploadPackSession = struct {
    session: common.Session,

    pub fn close(self: *UploadPackSession) void {
        self.session.close();
    }

    /// go-git `AdvertisedReferences`.
    pub fn advertisedReferences(self: *UploadPackSession) !*packp.AdvRefs {
        return self.session.advertisedReferences(transport.UploadPackServiceName);
    }

    /// go-git `AdvertisedReferencesContext` (context ignored; no cancel yet).
    pub fn advertisedReferencesContext(self: *UploadPackSession) !*packp.AdvRefs {
        return self.advertisedReferences();
    }

    /// go-git `UploadPack` — POST smart HTTP body, decode pack response.
    pub fn uploadPack(
        self: *UploadPackSession,
        req: *const packp.UploadPackRequest,
    ) !*packp.UploadPackResponse {
        if (req.isEmpty()) return transport.Error.EmptyUploadPackRequest;
        try req.validate();

        const url = try common.serviceURL(
            self.session.allocator,
            self.session.endpoint,
            transport.UploadPackServiceName,
        );
        defer self.session.allocator.free(url);

        const body = try uploadPackRequestToReader(self.session.allocator, req);
        defer self.session.allocator.free(body);

        var res = try self.session.doPost(transport.UploadPackServiceName, url, body);
        defer res.deinit();

        if (res.body.len == 0) return transport.Error.EmptyUploadPackRequest;

        var reader: std.Io.Reader = .fixed(res.body);
        _ = ioutil.nonEmptyReader(&reader) catch |err| {
            if (err == error.EmptyReader) return transport.Error.EmptyUploadPackRequest;
            return err;
        };

        // Re-seat after nonEmptyReader peek; decode owns its heap response.
        reader = .fixed(res.body);
        var nop = ioutil.NopCloser{};
        return transport_common.decodeUploadPackResponse(
            self.session.allocator,
            &reader,
            req,
            &nop,
        );
    }
};

/// go-git `newUploadPackSession`.
pub fn newUploadPackSession(
    c: *common.Client,
    ep: *Endpoint,
    auth: ?transport.AuthMethod,
) !UploadPackSession {
    const s = try c.newSession(ep, auth);
    return .{ .session = s };
}

/// go-git `uploadPackRequestToReader` — encode wants/haves/done for POST body.
///
/// Haves encode with `flush=false` (HTTP path differs from pipe common).
pub fn uploadPackRequestToReader(
    allocator: Allocator,
    req: *const packp.UploadPackRequest,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    // encode takes mutable *UploadHaves / *UploadRequest (sort/dedup).
    var haves = req.upload_haves;
    var ur = req.upload_request;
    try ur.encode(w);
    try haves.encode(w, false);

    var enc = pktline.Encoder.init(w);
    try enc.encodef("done\n", .{});

    return try aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "uploadPackRequestToReader golden" {
    const gpa = testing.allocator;
    const plumbing = @import("plumbing");

    var r = packp.UploadPackRequest.init(gpa);
    defer r.deinit();

    try r.upload_request.wants.append(gpa, plumbing.newHash("d82f291cde9987322c8a0c81a325e1ba6159684c"));
    try r.upload_request.wants.append(gpa, plumbing.newHash("2b41ef280fdb67a9b250678686a0c3e03b0a9989"));
    try r.upload_haves.haves.append(gpa, plumbing.newHash("6ecf0ef2c2dffb796033e5a02219af86ec6584e5"));

    const body = try uploadPackRequestToReader(gpa, &r);
    defer gpa.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "want ") != null);
    try testing.expect(std.mem.indexOf(u8, body, "have 6ecf0ef2c2dffb796033e5a02219af86ec6584e5") != null);
    try testing.expect(std.mem.indexOf(u8, body, "done\n") != null);
    // HTTP path: no flush between haves and done (flush=false).
    try testing.expect(std.mem.indexOf(u8, body, "0009done\n") != null);
}

test "UploadPackSession AdvertisedReferences via mock" {
    const gpa = testing.allocator;
    const plumbing = @import("plumbing");
    const capability = @import("capability");

    var ar_body: std.ArrayList(u8) = .empty;
    defer ar_body.deinit(gpa);
    {
        var adv = packp.AdvRefs.init(gpa);
        defer adv.deinit();
        const head_hash = plumbing.newHash("6ecf0ef2c2dffb796033e5a02219af86ec6584e5");
        adv.head = head_hash;
        try adv.putReference("HEAD", head_hash);
        try adv.putReference("refs/heads/master", head_hash);
        try adv.capabilities.set(capability.OFSDelta, &.{});
        try adv.appendPrefix("# service=git-upload-pack\n");
        try adv.appendPrefix(&.{}); // flush

        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try adv.encode(&aw.writer);
        try ar_body.appendSlice(gpa, aw.written());
    }

    var mock = common.MockRoundTripper.init(gpa);
    defer mock.deinit();
    try mock.push(.{
        .url_contains = "info/refs",
        .status_code = 200,
        .body = ar_body.items,
    });

    var client = try common.Client.init(gpa, mock.asRoundTripper(), .{});
    defer client.deinit();
    var ep = try transport.newEndpoint(gpa, testing.io, "https://example.com/repo.git");
    defer ep.deinit();

    var sess = try newUploadPackSession(&client, &ep, null);
    defer sess.close();

    const refs = try sess.advertisedReferences();
    try testing.expect(refs.head != null);
    try testing.expect(!refs.isEmpty());
}

test "UploadPackSession 404 maps RepositoryNotFound" {
    const gpa = testing.allocator;
    var mock = common.MockRoundTripper.init(gpa);
    defer mock.deinit();
    try mock.push(.{ .status_code = 404, .body = "missing" });

    var client = try common.Client.init(gpa, mock.asRoundTripper(), .{});
    defer client.deinit();
    var ep = try transport.newEndpoint(gpa, testing.io, "http://localhost/nope.git");
    defer ep.deinit();

    var sess = try newUploadPackSession(&client, &ep, null);
    defer sess.close();
    try testing.expectError(transport.Error.RepositoryNotFound, sess.advertisedReferences());
}

test "UploadPackSession BasicAuth applied on info/refs" {
    const gpa = testing.allocator;
    var mock = common.MockRoundTripper.init(gpa);
    defer mock.deinit();
    try mock.push(.{ .status_code = 200, .body = "0000" });

    var client = try common.Client.init(gpa, mock.asRoundTripper(), .{});
    defer client.deinit();
    var ep = try transport.newEndpoint(gpa, testing.io, "https://example.com/r.git");
    defer ep.deinit();

    var auth = common.BasicAuth{ .username = "foo", .password = "bar" };
    var sess = try newUploadPackSession(&client, &ep, auth.asTransportAuth());
    defer sess.close();
    _ = sess.advertisedReferences() catch {};
    try testing.expect(mock.requests.items.len >= 1);
    try testing.expect(mock.requests.items[0].authorization != null);
    try testing.expect(std.mem.startsWith(u8, mock.requests.items[0].authorization.?, "Basic "));
}
