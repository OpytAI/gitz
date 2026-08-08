//! Package http — HTTP smart protocol transport client.
//!
//! Port of go-git v5.19.2 `plumbing/transport/http`.
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `BasicAuth` / `TokenAuth` / `AuthMethod` | `common.zig` |
//! | `DefaultClient` / `NewClient` / `ClientOptions` | `newClient` / `defaultClient` / `Client` |
//! | `RedirectPolicy` | `RedirectPolicy` |
//! | `NewErr` / `Err` | `newErr` / `HttpError` |
//! | upload-pack session | `upload_pack.zig` |
//! | receive-pack session | `receive_pack.zig` |
//! | `http.RoundTripper` (injectable) | `RoundTripper` / `MockRoundTripper` / `OsRoundTripper` |
//!
//! # Design
//!
//! - `defaultClient` / `newClient` attach an owned `OsRoundTripper`
//!   (verified `std.http.Client`; insecure HTTPS via `tls.Client`
//!   `no_verification` when `insecure_skip_tls` is set). Call `Client.deinit`
//!   once when finished.
//! - Inject `MockRoundTripper` (or any `RoundTripper`) for hermetic tests;
//!   inject path does not own the RoundTripper.
//! - Single request path: `Session.doRequest` → `RoundTripper.roundTrip`.
//! - Redirect policy is enforced in `OsRoundTripper` (verified + insecure)
//!   using the same rules as `checkRedirectPolicy`. Endpoint mutation is
//!   `Session.applyRedirectUrl` (go-git `ModifyEndpointIfRedirect`).
//! - OS and mock RoundTrippers populate owned `Response.headers` (multi-value
//!   via `HeaderMap.add`).
//! - `asTransport` exposes the go-git Transport vtable for protocol install.
//!
//! # go-git test map
//!
//! | go-git | Zig |
//! |--------|-----|
//! | TestNewBasicAuth | `BasicAuth Name and String` |
//! | TestNewTokenAuth | `TokenAuth Name String SetAuth` |
//! | TestNewErr* | `NewErr status mapping` |
//! | TestNewClient | `DefaultClient / NewClient skeleton` |
//! | TestSetAuthWrongType | `InvalidAuthMethod rejects non-HTTP auth` |
//! | TestCheckRedirectPolicy | `checkRedirectPolicy` |
//! | info/refs + service URLs | `infoRefsURL and serviceURL` |
//! | uploadPackRequestToReader | `uploadPackRequestToReader golden` |
//! | mock AdvRefs | `UploadPackSession AdvertisedReferences via mock` |

const common = @import("common.zig");
const upload_pack = @import("upload_pack.zig");
const receive_pack = @import("receive_pack.zig");
const os_round_tripper = @import("os_round_tripper.zig");

const std = @import("std");
const transport = @import("transport");
const packp = @import("packp");

const Allocator = std.mem.Allocator;
const Endpoint = transport.Endpoint;

// --- common ---
pub const info_refs_path = common.info_refs_path;
pub const default_transport_cache_size = common.default_transport_cache_size;

pub const RedirectPolicy = common.RedirectPolicy;
pub const FollowInitialRedirects = common.FollowInitialRedirects;
pub const FollowRedirects = common.FollowRedirects;
pub const NoFollowRedirects = common.NoFollowRedirects;

pub const HeaderMap = common.HeaderMap;
pub const Request = common.Request;
pub const Response = common.Response;
pub const RoundTripper = common.RoundTripper;
pub const MockRoundTripper = common.MockRoundTripper;
pub const OsRoundTripper = os_round_tripper.OsRoundTripper;
pub const headerMapFromHeadBytes = os_round_tripper.headerMapFromHeadBytes;

pub const AuthMethod = common.AuthMethod;
pub const BasicAuth = common.BasicAuth;
pub const TokenAuth = common.TokenAuth;
pub const authFromTransport = common.authFromTransport;

pub const HttpError = common.HttpError;
pub const NewErrResult = common.NewErrResult;
pub const newErr = common.newErr;
pub const Error = common.Error;

pub const infoRefsURL = common.infoRefsURL;
pub const serviceURL = common.serviceURL;
pub const isHttpScheme = common.isHttpScheme;
pub const applyHeaders = common.applyHeaders;
pub const checkRedirectPolicy = common.checkRedirectPolicy;
pub const effectivePort = common.effectivePort;
pub const endpointHost = common.endpointHost;
pub const endpointPort = common.endpointPort;

pub const ClientOptions = common.ClientOptions;
pub const Client = common.Client;
pub const Session = common.Session;
pub const newClient = common.newClient;
pub const newClientWithOptions = common.newClientWithOptions;
pub const defaultClient = common.defaultClient;

// --- sessions ---
pub const UploadPackSession = upload_pack.UploadPackSession;
pub const ReceivePackSession = receive_pack.ReceivePackSession;
pub const newUploadPackSession = upload_pack.newUploadPackSession;
pub const newReceivePackSession = receive_pack.newReceivePackSession;
pub const uploadPackRequestToReader = upload_pack.uploadPackRequestToReader;

// ---------------------------------------------------------------------------
// Client convenience methods (go-git method names on client)
// ---------------------------------------------------------------------------

/// go-git `(*client).NewUploadPackSession`.
pub fn clientNewUploadPackSession(
    c: *Client,
    ep: *Endpoint,
    auth: ?transport.AuthMethod,
) !UploadPackSession {
    return newUploadPackSession(c, ep, auth);
}

/// go-git `(*client).NewReceivePackSession`.
pub fn clientNewReceivePackSession(
    c: *Client,
    ep: *Endpoint,
    auth: ?transport.AuthMethod,
) !ReceivePackSession {
    return newReceivePackSession(c, ep, auth);
}

/// go-git `Transport` vtable for protocol registry install.
pub fn asTransport(c: *Client) transport.Transport {
    return .{
        .ptr = c,
        .vtable = &transport_vtable,
    };
}

const transport_vtable = transport.Transport.VTable{
    .newUploadPackSession = newUploadPackSessionV,
    .newReceivePackSession = newReceivePackSessionV,
};

fn newUploadPackSessionV(
    ptr: *anyopaque,
    endpoint: *const Endpoint,
    auth: ?transport.AuthMethod,
) anyerror!?transport.SessionHandle {
    const self: *Client = @ptrCast(@alignCast(ptr));
    // go-git mutates endpoint on redirect; callers pass owned mutable endpoints.
    const ep: *Endpoint = @constCast(endpoint);
    const session = try newUploadPackSession(self, ep, auth);
    const heap = try self.allocator.create(UploadPackSession);
    heap.* = session;
    return @ptrCast(heap);
}

fn newReceivePackSessionV(
    ptr: *anyopaque,
    endpoint: *const Endpoint,
    auth: ?transport.AuthMethod,
) anyerror!?transport.SessionHandle {
    const self: *Client = @ptrCast(@alignCast(ptr));
    const ep: *Endpoint = @constCast(endpoint);
    const session = try newReceivePackSession(self, ep, auth);
    const heap = try self.allocator.create(ReceivePackSession);
    heap.* = session;
    return @ptrCast(heap);
}

// Free heap session from Transport vtable (caller responsibility).
pub fn freeUploadPackSession(allocator: Allocator, s: *UploadPackSession) void {
    s.close();
    allocator.destroy(s);
}

pub fn freeReceivePackSession(allocator: Allocator, s: *ReceivePackSession) void {
    s.close();
    allocator.destroy(s);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    _ = @import("common.zig");
    _ = @import("upload_pack.zig");
    _ = @import("receive_pack.zig");
    _ = @import("os_round_tripper.zig");
}

test "Client asTransport and session factory" {
    const gpa = std.testing.allocator;
    var mock = MockRoundTripper.init(gpa);
    defer mock.deinit();
    try mock.push(.{
        .status_code = 401,
        .body = "need auth",
    });

    var client = try newClientWithOptions(gpa, mock.asRoundTripper(), .{
        .insecure_skip_tls = true,
    });
    defer client.deinit();
    try std.testing.expect(client.options.insecure_skip_tls);
    try std.testing.expect(client.owned_os_rt == null);

    const t = asTransport(&client);
    var ep = try transport.newEndpoint(gpa, std.testing.io, "https://example.com/x.git");
    defer ep.deinit();

    const handle = try t.newUploadPackSession(&ep, null);
    try std.testing.expect(handle != null);
    const sess: *UploadPackSession = @ptrCast(@alignCast(handle.?));
    defer freeUploadPackSession(gpa, sess);
    try std.testing.expectError(transport.Error.AuthenticationRequired, sess.advertisedReferences());
}

test "modifyEndpointIfRedirect updates path" {
    const gpa = std.testing.allocator;
    var client = try newClient(gpa);
    defer client.deinit();
    var ep = try transport.newEndpoint(gpa, std.testing.io, "https://old.example.com/old.git");
    defer ep.deinit();

    var sess = try newUploadPackSession(&client, &ep, null);
    defer sess.close();

    try sess.session.applyRedirectUrl("https://new.example.com/new.git/info/refs");
    try std.testing.expectEqualStrings("new.example.com", ep.host);
    try std.testing.expectEqualStrings("/new.git", ep.path);
    try std.testing.expectEqualStrings("https", ep.protocol);
}

test "modifyEndpointIfRedirect clears credentials cross-host" {
    const gpa = std.testing.allocator;
    var client = try newClient(gpa);
    defer client.deinit();
    var ep = try transport.newEndpoint(gpa, std.testing.io, "https://user:pass@old.example.com/repo.git");
    defer ep.deinit();

    var auth = BasicAuth{ .username = "user", .password = "pass" };
    var sess = try newUploadPackSession(&client, &ep, auth.asTransportAuth());
    defer sess.close();
    try std.testing.expect(sess.session.auth != null);

    try sess.session.applyRedirectUrl("https://new.example.com/repo.git/info/refs");
    try std.testing.expect(sess.session.auth == null);
    try std.testing.expectEqualStrings("", ep.user);
    try std.testing.expectEqualStrings("", ep.password);
    try std.testing.expectEqualStrings("new.example.com", ep.host);
}

test "modifyEndpointIfRedirect rejects bad path" {
    const gpa = std.testing.allocator;
    var client = try newClient(gpa);
    defer client.deinit();
    var ep = try transport.newEndpoint(gpa, std.testing.io, "https://example.com/repo.git");
    defer ep.deinit();
    var sess = try newUploadPackSession(&client, &ep, null);
    defer sess.close();
    try std.testing.expectError(Error.RedirectInvalid, sess.session.applyRedirectUrl("https://example.com/foo/bar"));
}

test "defaultClient has OsRoundTripper (no NoRoundTripper)" {
    const gpa = std.testing.allocator;
    var client = try defaultClient(gpa);
    defer client.deinit();
    try std.testing.expect(client.round_tripper != null);
    try std.testing.expect(client.owned_os_rt != null);

    var ep = try transport.newEndpoint(gpa, std.testing.io, "http://127.0.0.1:1/r.git");
    defer ep.deinit();
    var sess = try newUploadPackSession(&client, &ep, null);
    defer sess.close();
    // OS path is taken: connection to closed port fails with a network error,
    // not Error.NoRoundTripper.
    const result = sess.advertisedReferences();
    try std.testing.expect(std.meta.isError(result));
    if (result) |_| unreachable else |err| {
        try std.testing.expect(err != Error.NoRoundTripper);
    }
}

test "endpoint user becomes BasicAuth" {
    const gpa = std.testing.allocator;
    var mock = MockRoundTripper.init(gpa);
    defer mock.deinit();
    try mock.push(.{ .status_code = 200, .body = "0000" });

    var client = try newClientWithOptions(gpa, mock.asRoundTripper(), .{});
    defer client.deinit();
    var ep = try transport.newEndpoint(gpa, std.testing.io, "https://alice:secret@example.com/r.git");
    defer ep.deinit();

    var sess = try newUploadPackSession(&client, &ep, null);
    defer sess.close();
    try std.testing.expect(sess.session.owned_basic != null);
    _ = sess.advertisedReferences() catch {};
    try std.testing.expect(mock.requests.items.len >= 1);
    const authz = mock.requests.items[0].authorization orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.startsWith(u8, authz, "Basic "));
}

test "insecure_skip_tls from ClientOptions" {
    const gpa = std.testing.allocator;
    var client = try newClientWithOptions(gpa, null, .{ .insecure_skip_tls = true });
    defer client.deinit();
    var ep = try transport.newEndpoint(gpa, std.testing.io, "https://example.com/r.git");
    defer ep.deinit();
    var sess = try newUploadPackSession(&client, &ep, null);
    defer sess.close();
    try std.testing.expect(sess.session.insecure_skip_tls);
    try std.testing.expect(client.owned_os_rt.?.insecure_skip_tls);
}

test "never redirect policy does not block first request" {
    // go-git CheckRedirect runs only on hops; the first request always proceeds.
    const gpa = std.testing.allocator;
    var client = try newClientWithOptions(gpa, null, .{ .redirect_policy = .never });
    defer client.deinit();
    try std.testing.expect(client.owned_os_rt.?.redirect_policy == .never);

    var ep = try transport.newEndpoint(gpa, std.testing.io, "http://127.0.0.1:1/r.git");
    defer ep.deinit();
    var sess = try newUploadPackSession(&client, &ep, null);
    defer sess.close();
    const result = sess.advertisedReferences();
    try std.testing.expect(std.meta.isError(result));
    if (result) |_| unreachable else |err| {
        try std.testing.expect(err != Error.RedirectBlocked);
        try std.testing.expect(err != Error.NoRoundTripper);
    }
}

test "empty upload-pack request" {
    const gpa = std.testing.allocator;
    var client = try newClient(gpa);
    defer client.deinit();
    var ep = try transport.newEndpoint(gpa, std.testing.io, "https://example.com/r.git");
    defer ep.deinit();
    var sess = try newUploadPackSession(&client, &ep, null);
    defer sess.close();
    var req = packp.UploadPackRequest.init(gpa);
    defer req.deinit();
    try std.testing.expectError(transport.Error.EmptyUploadPackRequest, sess.uploadPack(&req));
}
