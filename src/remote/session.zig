//! Upload-pack / receive-pack session open helpers (go-git `remote.go`
//! `newUploadPackSession` / `newSendPackSession` / `newClient`).
//!
//! Prefer an embedded `server.Server` (in-process / tests). When `embedded`
//! is null, resolve the scheme via `client.newClient` and require a
//! `transportFromServer` registration (phase-11 in-process path).
//! Phase 13 adds real HTTP/SSH transports that return typed sessions without
//! casting through `*server.Server`.

const std = @import("std");
const transport = @import("transport");
const packp = @import("packp");
const server = @import("server");
const client = @import("client");

const Allocator = std.mem.Allocator;
const Endpoint = transport.Endpoint;
const AuthMethod = transport.AuthMethod;
const ProxyOptions = transport.ProxyOptions;

// ---------------------------------------------------------------------------
// Open options (TLS / proxy / auth applied onto Endpoint)
// ---------------------------------------------------------------------------

/// Transport open parameters shared by list / fetch / push.
pub const SessionOpts = struct {
    auth: ?AuthMethod = null,
    insecure_skip_tls: bool = false,
    client_cert: []const u8 = "",
    client_key: []const u8 = "",
    ca_bundle: []const u8 = "",
    proxy: ProxyOptions = .{},
};

/// Build `SessionOpts` from Fetch/Push/List option fields (auth, TLS, mTLS, proxy).
///
/// Lives here so `options.zig` does not import `session.zig` (avoids cycles).
pub fn sessionOptsFrom(
    auth: ?AuthMethod,
    insecure_skip_tls: bool,
    client_cert: []const u8,
    client_key: []const u8,
    ca_bundle: []const u8,
    proxy: ProxyOptions,
) SessionOpts {
    return .{
        .auth = auth,
        .insecure_skip_tls = insecure_skip_tls,
        .client_cert = client_cert,
        .client_key = client_key,
        .ca_bundle = ca_bundle,
        .proxy = proxy,
    };
}

fn applySessionOpts(ep: *Endpoint, opts: SessionOpts) void {
    ep.insecure_skip_tls = opts.insecure_skip_tls;
    ep.client_cert = opts.client_cert;
    ep.client_key = opts.client_key;
    ep.ca_bundle = opts.ca_bundle;
    ep.proxy = opts.proxy;
}

// ---------------------------------------------------------------------------
// Server as client-registry Transport
// ---------------------------------------------------------------------------

/// Wrap `*server.Server` as a `transport.Transport` for `client.installProtocol`.
///
/// Vtable session hooks return null; typed sessions open via `*server.Server`.
pub fn transportFromServer(srv: *server.Server) transport.Transport {
    return .{
        .ptr = srv,
        .vtable = &server_transport_vtable,
    };
}

fn serverNewUploadPackSession(
    _: *anyopaque,
    _: *const Endpoint,
    _: ?AuthMethod,
) anyerror!?transport.SessionHandle {
    return null;
}

fn serverNewReceivePackSession(
    _: *anyopaque,
    _: *const Endpoint,
    _: ?AuthMethod,
) anyerror!?transport.SessionHandle {
    return null;
}

const server_transport_vtable = transport.Transport.VTable{
    .newUploadPackSession = serverNewUploadPackSession,
    .newReceivePackSession = serverNewReceivePackSession,
};

// ---------------------------------------------------------------------------
// Resolve Server from embedded override or client registry
// ---------------------------------------------------------------------------

fn resolveServer(
    ep: *const Endpoint,
    embedded: ?*server.Server,
) (transport.Error || error{MalformedClient})!*server.Server {
    if (embedded) |srv| return srv;
    const t = try client.newClient(ep);
    if (t.vtable != &server_transport_vtable) return error.MalformedClient;
    return @ptrCast(@alignCast(t.ptr));
}

// ---------------------------------------------------------------------------
// Upload-pack session wrapper
// ---------------------------------------------------------------------------

/// go-git upload-pack session opened for Remote fetch/list.
pub const SessionUpload = struct {
    /// Owned endpoint used to open the session.
    endpoint: Endpoint,
    sess: server.UploadPackSession,

    pub fn close(self: *SessionUpload) void {
        self.sess.close();
        self.endpoint.deinit();
        self.* = undefined;
    }

    /// Caller owns the returned pointer: free with `packp.freeAdvRefs`.
    pub fn advertisedReferences(self: *SessionUpload) !*packp.AdvRefs {
        return self.sess.advertisedReferences();
    }

    /// Caller owns the returned pointer: free with `packp.freeUploadPackResponse`.
    pub fn uploadPack(
        self: *SessionUpload,
        req: *const packp.UploadPackRequest,
    ) !*packp.UploadPackResponse {
        return self.sess.uploadPack(req);
    }

    pub fn setAuth(self: *SessionUpload, auth: ?AuthMethod) !void {
        return self.sess.setAuth(auth);
    }
};

/// Open an upload-pack session (go-git `newUploadPackSession`).
///
/// `io` is used only for scheme-less path endpoints (`filepath.Abs` / cwd).
pub fn openUploadPack(
    allocator: Allocator,
    io: std.Io,
    url: []const u8,
    opts: SessionOpts,
    embedded: ?*server.Server,
) !SessionUpload {
    var ep = try transport.newEndpoint(allocator, io, url);
    errdefer ep.deinit();
    applySessionOpts(&ep, opts);

    const srv = try resolveServer(&ep, embedded);
    const sess = try srv.newUploadPackSession(&ep, opts.auth);
    return .{
        .endpoint = ep,
        .sess = sess,
    };
}

// ---------------------------------------------------------------------------
// Receive-pack session wrapper
// ---------------------------------------------------------------------------

/// go-git receive-pack session opened for Remote push
/// (`newSendPackSession` in go-git naming).
pub const SessionReceive = struct {
    endpoint: Endpoint,
    sess: server.ReceivePackSession,

    pub fn close(self: *SessionReceive) void {
        self.sess.close();
        self.endpoint.deinit();
        self.* = undefined;
    }

    /// Caller owns the returned pointer: free with `packp.freeAdvRefs`.
    pub fn advertisedReferences(self: *SessionReceive) !*packp.AdvRefs {
        return self.sess.advertisedReferences();
    }

    pub fn receivePackOutcome(
        self: *SessionReceive,
        req: *const packp.ReferenceUpdateRequest,
    ) !server.ReceivePackOutcome {
        return self.sess.receivePackOutcome(req);
    }

    pub fn setAuth(self: *SessionReceive, auth: ?AuthMethod) !void {
        return self.sess.setAuth(auth);
    }
};

/// Open a receive-pack session (go-git `newSendPackSession`).
pub fn openReceivePack(
    allocator: Allocator,
    io: std.Io,
    url: []const u8,
    opts: SessionOpts,
    embedded: ?*server.Server,
) !SessionReceive {
    var ep = try transport.newEndpoint(allocator, io, url);
    errdefer ep.deinit();
    applySessionOpts(&ep, opts);

    const srv = try resolveServer(&ep, embedded);
    const sess = try srv.newReceivePackSession(&ep, opts.auth);
    return .{
        .endpoint = ep,
        .sess = sess,
    };
}

test "SessionOpts defaults" {
    const o = SessionOpts{};
    try std.testing.expect(o.auth == null);
    try std.testing.expect(!o.insecure_skip_tls);
    try std.testing.expectEqualStrings("", o.client_cert);
    try std.testing.expectEqualStrings("", o.client_key);
    try std.testing.expectEqualStrings("", o.ca_bundle);
}

test "sessionOptsFrom maps fields" {
    const proxy = ProxyOptions{};
    const o = sessionOptsFrom(null, true, "cert", "key", "ca", proxy);
    try std.testing.expect(o.auth == null);
    try std.testing.expect(o.insecure_skip_tls);
    try std.testing.expectEqualStrings("cert", o.client_cert);
    try std.testing.expectEqualStrings("key", o.client_key);
    try std.testing.expectEqualStrings("ca", o.ca_bundle);
}
