//! Upload-pack / receive-pack session open helpers (go-git `remote.go`
//! `newUploadPackSession` / `newSendPackSession` / `newClient`).
//!
//! An embedded `server.Server` and registered file/git/http/ssh clients use the
//! same owned transport-session interfaces. When `embedded` is null, install
//! go-git's default protocol set lazily and resolve the endpoint scheme.

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
    operation_context: transport.OperationContext = .{},

    /// From shared `TransportClientOpts` (nested on Fetch/Push/List options).
    pub fn fromClient(c: TransportClientOpts) SessionOpts {
        return .{
            .auth = c.auth,
            .insecure_skip_tls = c.insecure_skip_tls,
            .client_cert = c.client_cert,
            .client_key = c.client_key,
            .ca_bundle = c.ca_bundle,
            .proxy = c.proxy,
            .operation_context = c.operation_context,
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

// ---------------------------------------------------------------------------
// Server as client-registry Transport
// ---------------------------------------------------------------------------

/// Wrap `*server.Server` as a `transport.Transport` for `client.installProtocol`.
///
pub fn transportFromServer(srv: *server.Server) transport.Transport {
    return srv.asTransport();
}

// ---------------------------------------------------------------------------
// Resolve Server from embedded override or client registry
// ---------------------------------------------------------------------------

fn resolveTransport(
    allocator: Allocator,
    ep: *const Endpoint,
    embedded: ?*server.Server,
) !transport.Transport {
    if (embedded) |srv| return transportFromServer(srv);
    try client.installDefaults(allocator);
    return client.newClient(ep);
}

/// Single-threaded host Io for scheme-less path endpoints (file:// absolute).
pub fn defaultIo() std.Io {
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
    allocator: Allocator,
    /// Heap-owned so HTTP redirect/session pointers remain stable after return.
    endpoint: *Endpoint,
    sess: transport.UploadPackSession,
    operation_context: transport.OperationContext,

    pub fn close(self: *SessionUpload) void {
        self.sess.close();
        self.endpoint.deinit();
        self.allocator.destroy(self.endpoint);
        self.* = undefined;
    }

    /// Caller owns the returned pointer: free with `packp.freeAdvRefs`.
    pub fn advertisedReferences(self: *SessionUpload) !*packp.AdvRefs {
        return self.sess.advertisedReferencesContext(self.operation_context);
    }

    /// Cooperative cancellation/deadline check at transport operation
    /// boundaries. It does not interrupt an already-blocked OS call.
    pub fn advertisedReferencesContext(
        self: *SessionUpload,
        ctx: transport.OperationContext,
    ) !*packp.AdvRefs {
        return self.sess.advertisedReferencesContext(ctx);
    }

    /// Caller owns the returned pointer: free with `packp.freeUploadPackResponse`.
    pub fn uploadPack(
        self: *SessionUpload,
        req: *const packp.UploadPackRequest,
    ) !*packp.UploadPackResponse {
        return self.sess.uploadPackContext(self.operation_context, req);
    }

    pub fn uploadPackContext(
        self: *SessionUpload,
        ctx: transport.OperationContext,
        req: *const packp.UploadPackRequest,
    ) !*packp.UploadPackResponse {
        return self.sess.uploadPackContext(ctx, req);
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
    try opts.operation_context.check();
    const ep = try allocator.create(Endpoint);
    errdefer allocator.destroy(ep);
    ep.* = try transport.newEndpoint(allocator, io, url);
    errdefer ep.deinit();
    opts.applyToEndpoint(ep);

    const backend = try resolveTransport(allocator, ep, embedded);
    const sess = try backend.newUploadPackSession(ep, opts.auth);
    return .{
        .allocator = allocator,
        .endpoint = ep,
        .sess = sess,
        .operation_context = opts.operation_context,
    };
}

/// Like `openUploadPack` with a process-local single-threaded `std.Io`.
pub fn openUploadPackUrl(
    allocator: Allocator,
    url: []const u8,
    opts: SessionOpts,
    embedded: ?*server.Server,
) !SessionUpload {
    return openUploadPack(allocator, defaultIo(), url, opts, embedded);
}

// ---------------------------------------------------------------------------
// Receive-pack session wrapper
// ---------------------------------------------------------------------------

/// go-git receive-pack session opened for Remote push
/// (`newSendPackSession` in go-git naming).
pub const SessionReceive = struct {
    allocator: Allocator,
    endpoint: *Endpoint,
    sess: transport.ReceivePackSession,
    operation_context: transport.OperationContext,

    pub fn close(self: *SessionReceive) void {
        self.sess.close();
        self.endpoint.deinit();
        self.allocator.destroy(self.endpoint);
        self.* = undefined;
    }

    /// Caller owns the returned pointer: free with `packp.freeAdvRefs`.
    pub fn advertisedReferences(self: *SessionReceive) !*packp.AdvRefs {
        return self.sess.advertisedReferencesContext(self.operation_context);
    }

    pub fn advertisedReferencesContext(
        self: *SessionReceive,
        ctx: transport.OperationContext,
    ) !*packp.AdvRefs {
        return self.sess.advertisedReferencesContext(ctx);
    }

    pub fn receivePackOutcome(
        self: *SessionReceive,
        req: *const packp.ReferenceUpdateRequest,
    ) !transport.ReceivePackOutcome {
        return self.sess.receivePackContext(self.operation_context, req);
    }

    pub fn receivePackOutcomeContext(
        self: *SessionReceive,
        ctx: transport.OperationContext,
        req: *const packp.ReferenceUpdateRequest,
    ) !transport.ReceivePackOutcome {
        return self.sess.receivePackContext(ctx, req);
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
    try opts.operation_context.check();
    const ep = try allocator.create(Endpoint);
    errdefer allocator.destroy(ep);
    ep.* = try transport.newEndpoint(allocator, io, url);
    errdefer ep.deinit();
    opts.applyToEndpoint(ep);

    const backend = try resolveTransport(allocator, ep, embedded);
    const sess = try backend.newReceivePackSession(ep, opts.auth);
    return .{
        .allocator = allocator,
        .endpoint = ep,
        .sess = sess,
        .operation_context = opts.operation_context,
    };
}

/// Like `openReceivePack` with a process-local single-threaded `std.Io`.
pub fn openReceivePackUrl(
    allocator: Allocator,
    url: []const u8,
    opts: SessionOpts,
    embedded: ?*server.Server,
) !SessionReceive {
    return openReceivePack(allocator, defaultIo(), url, opts, embedded);
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

test "open session observes cancellation before endpoint or dial" {
    const State = struct {
        fn cancelled(_: ?*anyopaque) bool {
            return true;
        }
    };
    const opts = SessionOpts{
        .operation_context = .{ .cancelled_fn = State.cancelled },
    };
    try std.testing.expectError(
        error.Cancelled,
        openUploadPack(std.testing.allocator, std.testing.io, "://invalid", opts, null),
    );
    try std.testing.expectError(
        error.Cancelled,
        openReceivePack(std.testing.allocator, std.testing.io, "://invalid", opts, null),
    );
}
