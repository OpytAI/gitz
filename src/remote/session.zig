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
const options = @import("options.zig");

const Allocator = std.mem.Allocator;
const Endpoint = transport.Endpoint;
const AuthMethod = transport.AuthMethod;
const TransportClientOpts = options.TransportClientOpts;

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
    proxy: transport.ProxyOptions = .{},

    /// From shared `TransportClientOpts` (nested on Fetch/Push/List options).
    pub fn fromClient(c: TransportClientOpts) SessionOpts {
        return .{
            .auth = c.auth,
            .insecure_skip_tls = c.insecure_skip_tls,
            .client_cert = c.client_cert,
            .client_key = c.client_key,
            .ca_bundle = c.ca_bundle,
            .proxy = c.proxy,
        };
    }

    pub fn applyToEndpoint(self: SessionOpts, ep: *Endpoint) void {
        ep.insecure_skip_tls = self.insecure_skip_tls;
        ep.client_cert = self.client_cert;
        ep.client_key = self.client_key;
        ep.ca_bundle = self.ca_bundle;
        ep.proxy = self.proxy;
    }
};

/// @deprecated Prefer `SessionOpts.fromClient`. Kept as a free function for
/// call sites that pass bare fields.
pub fn sessionOptsFrom(
    auth: ?AuthMethod,
    insecure_skip_tls: bool,
    client_cert: []const u8,
    client_key: []const u8,
    ca_bundle: []const u8,
    proxy: transport.ProxyOptions,
) SessionOpts {
    return SessionOpts.fromClient(.{
        .auth = auth,
        .insecure_skip_tls = insecure_skip_tls,
        .client_cert = client_cert,
        .client_key = client_key,
        .ca_bundle = ca_bundle,
        .proxy = proxy,
    });
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

/// Single-threaded host Io for scheme-less path endpoints (file:// absolute).
fn singleThreadedIo() std.Io {
    // Threaded must live for the duration of open*; callers using this helper
    // only need Io during endpoint construction. We use a threadlocal so the
    // Threaded storage outlives the temporary Io handle for the call stack.
    const Holder = struct {
        threadlocal var threaded: std.Io.Threaded = .init_single_threaded;
    };
    return Holder.threaded.io();
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
    opts.applyToEndpoint(&ep);

    const srv = try resolveServer(&ep, embedded);
    const sess = try srv.newUploadPackSession(&ep, opts.auth);
    return .{
        .endpoint = ep,
        .sess = sess,
    };
}

/// Like `openUploadPack` with a process-local single-threaded `std.Io`.
pub fn openUploadPackUrl(
    allocator: Allocator,
    url: []const u8,
    opts: SessionOpts,
    embedded: ?*server.Server,
) !SessionUpload {
    return openUploadPack(allocator, singleThreadedIo(), url, opts, embedded);
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
    opts.applyToEndpoint(&ep);

    const srv = try resolveServer(&ep, embedded);
    const sess = try srv.newReceivePackSession(&ep, opts.auth);
    return .{
        .endpoint = ep,
        .sess = sess,
    };
}

/// Like `openReceivePack` with a process-local single-threaded `std.Io`.
pub fn openReceivePackUrl(
    allocator: Allocator,
    url: []const u8,
    opts: SessionOpts,
    embedded: ?*server.Server,
) !SessionReceive {
    return openReceivePack(allocator, singleThreadedIo(), url, opts, embedded);
}

test "SessionOpts defaults" {
    const o = SessionOpts{};
    try std.testing.expect(o.auth == null);
    try std.testing.expect(!o.insecure_skip_tls);
    try std.testing.expectEqualStrings("", o.client_cert);
}

test "SessionOpts.fromClient maps fields" {
    const o = SessionOpts.fromClient(.{
        .insecure_skip_tls = true,
        .client_cert = "cert",
        .client_key = "key",
        .ca_bundle = "ca",
    });
    try std.testing.expect(o.insecure_skip_tls);
    try std.testing.expectEqualStrings("cert", o.client_cert);
    try std.testing.expectEqualStrings("key", o.client_key);
    try std.testing.expectEqualStrings("ca", o.ca_bundle);
}
