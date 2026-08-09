//! HTTP smart-protocol client surface (go-git `plumbing/transport/http/common.go`).
//!
//! Implements auth, client options, URL helpers, redirect policy, session base,
//! status-code error mapping, and RoundTripper plumbing.
//!
//! Default clients own an `OsRoundTripper` (`std.http.Client`). Hermetic tests
//! inject `MockRoundTripper` via `newClientWithOptions`.

const std = @import("std");
const transport = @import("transport");
const packp = @import("packp");
const capability = @import("capability");
const os_round_tripper = @import("os_round_tripper.zig");

const Allocator = std.mem.Allocator;
const Endpoint = transport.Endpoint;
const testing = std.testing;
const OsRoundTripper = os_round_tripper.OsRoundTripper;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// Path suffix for smart HTTP info/refs discovery (go-git `infoRefsPath`).
pub const info_refs_path: []const u8 = "/info/refs";

/// Default transport-cache capacity (go-git `defaultTransportCacheSize` = 0, off).
pub const default_transport_cache_size: usize = 0;

// ---------------------------------------------------------------------------
// Redirect policy (go-git `RedirectPolicy`)
// ---------------------------------------------------------------------------

/// Controls how redirects are followed (mirrors Git `http.followRedirects`).
pub const RedirectPolicy = enum {
    /// Follow redirects only for the initial `/info/refs` request (default).
    initial,
    /// Follow redirects for all requests.
    always,
    /// Treat redirects as errors.
    never,

    /// go-git string values: "initial" | "true" | "false".
    pub fn fromString(s: []const u8) ?RedirectPolicy {
        if (std.mem.eql(u8, s, "initial") or s.len == 0) return .initial;
        if (std.mem.eql(u8, s, "true")) return .always;
        if (std.mem.eql(u8, s, "false")) return .never;
        return null;
    }

    pub fn toString(self: RedirectPolicy) []const u8 {
        return switch (self) {
            .initial => "initial",
            .always => "true",
            .never => "false",
        };
    }
};

pub const FollowInitialRedirects = RedirectPolicy.initial;
pub const FollowRedirects = RedirectPolicy.always;
pub const NoFollowRedirects = RedirectPolicy.never;

// ---------------------------------------------------------------------------
// Header map + HTTP request/response (lightweight, no OS sockets)
// ---------------------------------------------------------------------------

/// Case-insensitive HTTP header bag used by auth and framing.
pub const HeaderMap = struct {
    allocator: Allocator,
    /// Stored as list of pairs (order preserved; last write wins on get).
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    pub const Entry = struct {
        name: []u8,
        value: []u8,
    };

    pub fn init(allocator: Allocator) HeaderMap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *HeaderMap) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.name);
            self.allocator.free(e.value);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Add a header (does not remove existing same-name headers; matches Go Add).
    pub fn add(self: *HeaderMap, name: []const u8, value: []const u8) Allocator.Error!void {
        const n = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(n);
        const v = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(v);
        try self.entries.append(self.allocator, .{ .name = n, .value = v });
    }

    /// Set/replace first matching header (case-insensitive), or add if missing.
    pub fn set(self: *HeaderMap, name: []const u8, value: []const u8) Allocator.Error!void {
        for (self.entries.items) |*e| {
            if (std.ascii.eqlIgnoreCase(e.name, name)) {
                const v = try self.allocator.dupe(u8, value);
                // Free after successful dupe so a failed set leaves the old value.
                self.allocator.free(e.value);
                e.value = v;
                return;
            }
        }
        try self.add(name, value);
    }

    pub fn get(self: *const HeaderMap, name: []const u8) ?[]const u8 {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (std.ascii.eqlIgnoreCase(self.entries.items[i].name, name)) {
                return self.entries.items[i].value;
            }
        }
        return null;
    }

    /// go-git `Request.SetBasicAuth` — sets `Authorization: Basic …`.
    pub fn setBasicAuth(self: *HeaderMap, username: []const u8, password: []const u8) Allocator.Error!void {
        const plain = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ username, password });
        defer self.allocator.free(plain);

        const enc_len = std.base64.standard.Encoder.calcSize(plain.len);
        const b64 = try self.allocator.alloc(u8, enc_len);
        defer self.allocator.free(b64);
        _ = std.base64.standard.Encoder.encode(b64, plain);

        const auth = try std.fmt.allocPrint(self.allocator, "Basic {s}", .{b64});
        defer self.allocator.free(auth);
        try self.set("Authorization", auth);
    }
};

/// Outgoing HTTP request (go-git `*http.Request` subset).
///
/// `url` and `headers` are owned. `method` and `body` are borrowed.
pub const Request = struct {
    allocator: Allocator,
    method: []const u8,
    url: []u8,
    headers: HeaderMap,
    /// Borrowed request body (not freed by deinit).
    body: []const u8 = "",
    /// True for the initial `/info/refs` discovery (redirect policy).
    is_initial: bool = false,

    pub fn deinit(self: *Request) void {
        self.allocator.free(self.url);
        self.headers.deinit();
        self.* = undefined;
    }
};

/// Incoming HTTP response (go-git `*http.Response` subset).
///
/// `body`, `final_url`, and `headers` are owned; call `deinit` exactly once.
pub const Response = struct {
    allocator: Allocator,
    status_code: u16,
    /// Response body bytes (owned).
    body: []u8,
    /// Final request URL after redirects (owned); used by `modifyEndpointIfRedirect`.
    final_url: ?[]u8 = null,
    headers: HeaderMap,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        if (self.final_url) |u| self.allocator.free(u);
        self.headers.deinit();
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// RoundTripper (mockable net/http RoundTripper)
// ---------------------------------------------------------------------------

/// Pluggable HTTP round-trip (go-git `http.RoundTripper` / `http.Client.Do`).
pub const RoundTripper = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        roundTrip: *const fn (ptr: *anyopaque, req: *const Request) anyerror!Response,
    };

    pub fn roundTrip(self: RoundTripper, req: *const Request) anyerror!Response {
        return self.vtable.roundTrip(self.ptr, req);
    }

    pub fn from(comptime T: type, impl: *T) RoundTripper {
        const gen = struct {
            fn rt(ptr: *anyopaque, req: *const Request) anyerror!Response {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.roundTrip(req);
            }
            const vtable = VTable{ .roundTrip = rt };
        };
        return .{ .ptr = impl, .vtable = &gen.vtable };
    }
};

/// In-memory RoundTripper for hermetic unit tests (no OS sockets).
///
/// Does not auto-follow redirects. Supply `Canned.final_url` to simulate a
/// post-redirect URI for `Session.modifyEndpointIfRedirect` (same contract as
/// `OsRoundTripper` setting `Response.final_url` after followed hops).
/// Redirect *policy* for live traffic is enforced in `OsRoundTripper` via
/// `checkRedirectPolicy` / `redirectBehaviorFor`.
pub const MockRoundTripper = struct {
    allocator: Allocator,
    /// FIFO of canned responses; matching entries are removed when `consume`.
    canned: std.ArrayListUnmanaged(Canned) = .empty,
    /// Recorded requests (owned copies of method/url/authorization).
    requests: std.ArrayListUnmanaged(Recorded) = .empty,
    /// When true and no canned entry matches, return status 404.
    default_not_found: bool = true,

    /// Borrowed name/value for a canned response header (copied on match).
    pub const HeaderKV = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const Canned = struct {
        /// If non-empty, only match when request URL contains this substring.
        url_contains: []const u8 = "",
        status_code: u16 = 200,
        body: []const u8 = "",
        /// Simulated post-redirect URL for ModifyEndpointIfRedirect.
        final_url: ?[]const u8 = null,
        /// Response headers (each pair is `HeaderMap.add`ed; multi-value OK).
        headers: []const HeaderKV = &.{},
        /// Remove this entry after a match (default true).
        consume: bool = true,
    };

    pub const Recorded = struct {
        method: []u8,
        url: []u8,
        authorization: ?[]u8 = null,

        pub fn deinit(self: *Recorded, allocator: Allocator) void {
            allocator.free(self.method);
            allocator.free(self.url);
            if (self.authorization) |a| allocator.free(a);
        }
    };

    pub fn init(allocator: Allocator) MockRoundTripper {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MockRoundTripper) void {
        for (self.requests.items) |*r| r.deinit(self.allocator);
        self.requests.deinit(self.allocator);
        self.canned.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn push(self: *MockRoundTripper, c: Canned) Allocator.Error!void {
        try self.canned.append(self.allocator, c);
    }

    pub fn asRoundTripper(self: *MockRoundTripper) RoundTripper {
        return RoundTripper.from(MockRoundTripper, self);
    }

    pub fn roundTrip(self: *MockRoundTripper, req: *const Request) anyerror!Response {
        // Record request under a nested scope so errdefers do not free slices
        // after ownership moves into `requests`.
        {
            const method = try self.allocator.dupe(u8, req.method);
            errdefer self.allocator.free(method);
            const url = try self.allocator.dupe(u8, req.url);
            errdefer self.allocator.free(url);
            const auth = if (req.headers.get("Authorization")) |a|
                try self.allocator.dupe(u8, a)
            else
                null;
            errdefer if (auth) |a| self.allocator.free(a);
            try self.requests.append(self.allocator, .{
                .method = method,
                .url = url,
                .authorization = auth,
            });
        }

        var match_idx: ?usize = null;
        for (self.canned.items, 0..) |c, i| {
            if (c.url_contains.len == 0 or std.mem.indexOf(u8, req.url, c.url_contains) != null) {
                match_idx = i;
                break;
            }
        }

        if (match_idx) |i| {
            const c = self.canned.items[i];
            const body = try self.allocator.dupe(u8, c.body);
            errdefer self.allocator.free(body);
            const final = if (c.final_url) |fu| try self.allocator.dupe(u8, fu) else null;
            errdefer if (final) |f| self.allocator.free(f);
            var headers = HeaderMap.init(self.allocator);
            errdefer headers.deinit();
            for (c.headers) |hv| {
                try headers.add(hv.name, hv.value);
            }
            if (c.consume) {
                _ = self.canned.orderedRemove(i);
            }
            return Response{
                .allocator = self.allocator,
                .status_code = c.status_code,
                .body = body,
                .final_url = final,
                .headers = headers,
            };
        }

        if (self.default_not_found) {
            const empty = try self.allocator.dupe(u8, "");
            return Response{
                .allocator = self.allocator,
                .status_code = 404,
                .body = empty,
                .headers = HeaderMap.init(self.allocator),
            };
        }
        return error.NoCannedResponse;
    }
};

// ---------------------------------------------------------------------------
// Auth (go-git `AuthMethod`, `BasicAuth`, `TokenAuth`)
// ---------------------------------------------------------------------------

/// HTTP auth that can set request headers (go-git `http.AuthMethod`).
pub const AuthMethod = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ptr: *anyopaque) []const u8,
        format: *const fn (ptr: *anyopaque, allocator: Allocator) Allocator.Error![]u8,
        setAuth: *const fn (ptr: *anyopaque, headers: *HeaderMap) anyerror!void,
    };

    pub fn name(self: AuthMethod) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn format(self: AuthMethod, allocator: Allocator) Allocator.Error![]u8 {
        return self.vtable.format(self.ptr, allocator);
    }

    pub fn setAuth(self: AuthMethod, headers: *HeaderMap) anyerror!void {
        return self.vtable.setAuth(self.ptr, headers);
    }

};

/// Recover HTTP auth from a transport.AuthMethod produced by BasicAuth/TokenAuth.
pub fn authFromTransport(auth: transport.AuthMethod) transport.Error!AuthMethod {
    if (auth.vtable == &BasicAuth.transport_vtable) {
        return BasicAuth.asHttpAuth(@ptrCast(@alignCast(auth.ptr)));
    }
    if (auth.vtable == &TokenAuth.transport_vtable) {
        return TokenAuth.asHttpAuth(@ptrCast(@alignCast(auth.ptr)));
    }
    return transport.Error.InvalidAuthMethod;
}

/// HTTP basic authentication (go-git `BasicAuth`).
pub const BasicAuth = struct {
    username: []const u8,
    password: []const u8,

    pub fn name(_: *const BasicAuth) []const u8 {
        return "http-basic-auth";
    }

    /// go-git `(*BasicAuth).String` — password masked.
    pub fn string(self: *const BasicAuth, allocator: Allocator) Allocator.Error![]u8 {
        const masked: []const u8 = if (self.password.len == 0) "<empty>" else "*******";
        return std.fmt.allocPrint(allocator, "{s} - {s}:{s}", .{ self.name(), self.username, masked });
    }

    pub fn setAuth(self: *const BasicAuth, headers: *HeaderMap) anyerror!void {
        try headers.setBasicAuth(self.username, self.password);
    }

    const http_vtable = AuthMethod.VTable{
        .name = nameFn,
        .format = formatFn,
        .setAuth = setAuthFn,
    };

    pub const transport_vtable = transport.AuthMethod.VTable{
        .name = nameFn,
        .format = formatFn,
    };

    fn nameFn(ptr: *anyopaque) []const u8 {
        const self: *const BasicAuth = @ptrCast(@alignCast(ptr));
        return self.name();
    }
    fn formatFn(ptr: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
        const self: *const BasicAuth = @ptrCast(@alignCast(ptr));
        return self.string(allocator);
    }
    fn setAuthFn(ptr: *anyopaque, headers: *HeaderMap) anyerror!void {
        const self: *const BasicAuth = @ptrCast(@alignCast(ptr));
        return self.setAuth(headers);
    }

    pub fn asHttpAuth(self: *BasicAuth) AuthMethod {
        return .{ .ptr = self, .vtable = &http_vtable };
    }

    pub fn asTransportAuth(self: *BasicAuth) transport.AuthMethod {
        return .{ .ptr = self, .vtable = &transport_vtable };
    }
};

/// Bearer token authentication (go-git `TokenAuth`).
///
/// Prefer BasicAuth for GitHub/GitLab/Bitbucket OAuth (token as user/password).
pub const TokenAuth = struct {
    token: []const u8,

    pub fn name(_: *const TokenAuth) []const u8 {
        return "http-token-auth";
    }

    pub fn string(self: *const TokenAuth, allocator: Allocator) Allocator.Error![]u8 {
        const masked: []const u8 = if (self.token.len == 0) "<empty>" else "*******";
        return std.fmt.allocPrint(allocator, "{s} - {s}", .{ self.name(), masked });
    }

    pub fn setAuth(self: *const TokenAuth, headers: *HeaderMap) anyerror!void {
        const v = try std.fmt.allocPrint(headers.allocator, "Bearer {s}", .{self.token});
        defer headers.allocator.free(v);
        try headers.set("Authorization", v);
    }

    const http_vtable = AuthMethod.VTable{
        .name = nameFn,
        .format = formatFn,
        .setAuth = setAuthFn,
    };

    pub const transport_vtable = transport.AuthMethod.VTable{
        .name = nameFn,
        .format = formatFn,
    };

    fn nameFn(ptr: *anyopaque) []const u8 {
        const self: *const TokenAuth = @ptrCast(@alignCast(ptr));
        return self.name();
    }
    fn formatFn(ptr: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
        const self: *const TokenAuth = @ptrCast(@alignCast(ptr));
        return self.string(allocator);
    }
    fn setAuthFn(ptr: *anyopaque, headers: *HeaderMap) anyerror!void {
        const self: *const TokenAuth = @ptrCast(@alignCast(ptr));
        return self.setAuth(headers);
    }

    pub fn asHttpAuth(self: *TokenAuth) AuthMethod {
        return .{ .ptr = self, .vtable = &http_vtable };
    }

    pub fn asTransportAuth(self: *TokenAuth) transport.AuthMethod {
        return .{ .ptr = self, .vtable = &transport_vtable };
    }
};

fn basicAuthFromEndpoint(ep: *const Endpoint) ?BasicAuth {
    if (ep.user.len == 0) return null;
    return BasicAuth{ .username = ep.user, .password = ep.password };
}

// ---------------------------------------------------------------------------
// Errors (go-git `Err`, `NewErr`)
// ---------------------------------------------------------------------------

/// HTTP status-based error (go-git `http.Err`).
pub const HttpError = struct {
    status_code: u16,
    reason: []const u8,
    /// Request URL for Error() message (may be empty).
    request_url: []const u8 = "",

    pub fn statusCode(self: *const HttpError) u16 {
        return self.status_code;
    }

    pub fn format(self: *const HttpError, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "unexpected requesting \"{s}\" status code: {d}",
            .{ self.request_url, self.status_code },
        );
    }
};

/// Map an HTTP status to transport errors or HttpError (go-git `NewErr`).
///
/// - 2xx → null (ok)
/// - 401 → `AuthenticationRequired`
/// - 403 → `AuthorizationFailed`
/// - 404 → `RepositoryNotFound`
/// - other → `HttpStatusError` (caller may inspect `out_http`)
pub const NewErrResult = union(enum) {
    ok,
    transport: transport.Error,
    http: HttpError,
};

pub fn newErr(status_code: u16, reason: []const u8, request_url: []const u8) NewErrResult {
    if (status_code >= 200 and status_code < 300) return .ok;
    return switch (status_code) {
        401 => .{ .transport = transport.Error.AuthenticationRequired },
        403 => .{ .transport = transport.Error.AuthorizationFailed },
        404 => .{ .transport = transport.Error.RepositoryNotFound },
        else => .{ .http = .{
            .status_code = status_code,
            .reason = reason,
            .request_url = request_url,
        } },
    };
}

/// Package error set for HTTP transport operations.
pub const Error = error{
    /// Non-2xx status not mapped to transport.Error (go-git plumbing.UnexpectedError + http.Err).
    HttpStatusError,
    /// Redirect policy blocked following a 3xx hop (go-git CheckRedirect reject).
    RedirectBlocked,
    /// Redirect target has unsupported scheme or shape.
    RedirectInvalid,
    /// Too many redirects (go-git: len(via) >= 10).
    TooManyRedirects,
    /// No RoundTripper configured (should be unreachable for default clients).
    NoRoundTripper,
    /// Endpoint protocol is not http/https.
    InvalidScheme,
    /// Proxy URL failed to parse or uses an unsupported scheme.
    InvalidProxyURL,
    /// Custom CA PEM could not be loaded into the trust store.
    CertificateBundleLoadFailure,
    /// Client cert set without key (or vice versa), or PEM markers missing.
    ClientCertificateConfigInvalid,
    /// Client certificate requested but Zig 0.16 std TLS has no mTLS option.
    ClientCertificateUnsupported,
    /// HTTP CONNECT to proxy failed or returned a non-200 status.
    HttpConnectFailed,
    /// Proxy does not support CONNECT tunneling.
    TunnelNotSupported,
};

// ---------------------------------------------------------------------------
// URL helpers
// ---------------------------------------------------------------------------

/// Build `{endpoint}/info/refs?service={service}` (go-git advertisedReferences URL).
pub fn infoRefsURL(allocator: Allocator, ep: *const Endpoint, service: []const u8) Allocator.Error![]u8 {
    const base = try ep.string(allocator);
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}{s}?service={s}", .{ base, info_refs_path, service });
}

/// Build `{endpoint}/{service}` for POST upload-pack / receive-pack.
pub fn serviceURL(allocator: Allocator, ep: *const Endpoint, service: []const u8) Allocator.Error![]u8 {
    const base = try ep.string(allocator);
    defer allocator.free(base);
    // go-git: fmt.Sprintf("%s/%s", endpoint.String(), serviceName)
    // Endpoint.String() has no trailing slash typically; path may end without /.
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, service });
}

/// True when scheme is http or https (case-insensitive).
pub fn isHttpScheme(protocol: []const u8) bool {
    return std.ascii.eqlIgnoreCase(protocol, "http") or
        std.ascii.eqlIgnoreCase(protocol, "https");
}

// ---------------------------------------------------------------------------
// Headers for smart HTTP (go-git `applyHeadersToRequest`)
// ---------------------------------------------------------------------------

/// Apply User-Agent / Accept / Content-Type / Content-Length.
///
/// When `content_len` is null, sets `Accept: */*` (info/refs GET).
/// When set, uses `application/x-{request_type}-request/result`.
pub fn applyHeaders(
    headers: *HeaderMap,
    content_len: ?usize,
    host: []const u8,
    request_type: []const u8,
) (Allocator.Error)!void {
    const agent = try capability.defaultAgent(headers.allocator, null);
    defer headers.allocator.free(agent);
    try headers.add("User-Agent", agent);
    try headers.add("Host", host);

    if (content_len == null) {
        try headers.add("Accept", "*/*");
        return;
    }

    var accept_buf: [128]u8 = undefined;
    const accept = std.fmt.bufPrint(&accept_buf, "application/x-{s}-result", .{request_type}) catch unreachable;
    try headers.add("Accept", accept);

    var ctype_buf: [128]u8 = undefined;
    const ctype = std.fmt.bufPrint(&ctype_buf, "application/x-{s}-request", .{request_type}) catch unreachable;
    try headers.add("Content-Type", ctype);

    var cl_buf: [32]u8 = undefined;
    const cl = std.fmt.bufPrint(&cl_buf, "{d}", .{content_len.?}) catch unreachable;
    try headers.add("Content-Length", cl);
}

// ---------------------------------------------------------------------------
// Client options + Client (go-git `ClientOptions`, `client`, `NewClient*`)
// ---------------------------------------------------------------------------

/// User-configurable client options (go-git `ClientOptions` + TLS/proxy).
///
/// Endpoint fields override matching ClientOptions when non-empty / true.
pub const ClientOptions = struct {
    /// Max cached transport configs (0 = disabled). Parity field for go-git
    /// transport cache; no cache is implemented yet.
    cache_max_entries: usize = default_transport_cache_size,
    /// Redirect policy; default is initial-only (Git `http.followRedirects`).
    redirect_policy: RedirectPolicy = .initial,
    /// When true, HTTPS uses the insecure TLS path (`tls.Client` with
    /// host/CA `no_verification`). See `os_round_tripper.zig`.
    insecure_skip_tls: bool = false,
    /// Client certificate PEM bytes (borrowed).
    client_cert: []const u8 = "",
    /// Client private key PEM bytes (borrowed).
    client_key: []const u8 = "",
    /// Extra CA PEM bytes appended to the system trust store (borrowed).
    ca_bundle: []const u8 = "",
    /// HTTP(S) proxy applied on the live OS client.
    proxy: transport.ProxyOptions = .{},
};

/// HTTP transport client (go-git `client`).
///
/// Implements `transport.Transport` via `asTransport()` / package `asTransport`.
///
/// # RoundTripper ownership
///
/// | Construction | `round_tripper` | `owned_os_rt` | `deinit` |
/// |---|---|---|---|
/// | `newClient` / `defaultClient` / `init(null)` | owned OsRoundTripper | non-null | frees OS RT |
/// | `init(injected)` / mock | borrowed inject | null | no-op on RT |
///
/// Call `deinit` exactly once. Inject path never stores `owned_os_rt`; owned
/// path nulls the pointer after destroy.
pub const Client = struct {
    allocator: Allocator,
    round_tripper: ?RoundTripper = null,
    options: ClientOptions = .{},
    follow: RedirectPolicy = .initial,
    /// Heap-owned default OS round tripper when no external RT was injected.
    owned_os_rt: ?*OsRoundTripper = null,

    /// go-git `NewClient` / `NewClientWithOptions`.
    ///
    /// When `rt` is null, allocates and attaches an `OsRoundTripper` with
    /// single-threaded host Io. When `rt` is non-null, uses the inject and
    /// does not own an OsRoundTripper.
    pub fn init(allocator: Allocator, rt: ?RoundTripper, opts: ClientOptions) Allocator.Error!Client {
        var client = Client{
            .allocator = allocator,
            .round_tripper = rt,
            .options = opts,
            .follow = opts.redirect_policy,
            .owned_os_rt = null,
        };
        if (rt == null) {
            const os_rt = try allocator.create(OsRoundTripper);
            errdefer allocator.destroy(os_rt);
            os_rt.* = OsRoundTripper.init(allocator, singleThreadedIo());
            os_rt.redirect_policy = opts.redirect_policy;
            os_rt.insecure_skip_tls = opts.insecure_skip_tls;
            client.owned_os_rt = os_rt;
            client.round_tripper = os_rt.asRoundTripper();
        }
        return client;
    }

    /// Free owned OsRoundTripper if any. Safe when a mock RoundTripper was injected.
    pub fn deinit(self: *Client) void {
        if (self.owned_os_rt) |os_rt| {
            os_rt.deinit();
            self.allocator.destroy(os_rt);
            self.owned_os_rt = null;
        }
        self.round_tripper = null;
        self.* = undefined;
    }

    /// Build a base session (used by upload_pack / receive_pack wrappers).
    ///
    /// `ep` is borrowed and may be mutated on HTTP redirect (go-git).
    pub fn newSession(self: *Client, ep: *Endpoint, auth: ?transport.AuthMethod) !Session {
        if (!isHttpScheme(ep.protocol)) return Error.InvalidScheme;

        var http_auth: ?AuthMethod = null;
        var owned_basic: ?BasicAuth = null;

        if (auth) |a| {
            http_auth = try authFromTransport(a);
        } else if (basicAuthFromEndpoint(ep)) |ba| {
            owned_basic = ba;
        }

        // Endpoint wins when set (non-empty / true); else ClientOptions.
        const insecure = ep.insecure_skip_tls or self.options.insecure_skip_tls;
        const proxy = if (ep.proxy.url.len != 0) ep.proxy else self.options.proxy;
        const ca_bundle = if (ep.ca_bundle.len != 0) ep.ca_bundle else self.options.ca_bundle;
        const client_cert = if (ep.client_cert.len != 0) ep.client_cert else self.options.client_cert;
        const client_key = if (ep.client_key.len != 0) ep.client_key else self.options.client_key;

        if (self.owned_os_rt) |os_rt| {
            try os_rt.configure(.{
                .redirect_policy = self.follow,
                .insecure_skip_tls = insecure,
                .proxy = proxy,
                .ca_bundle = ca_bundle,
                .client_cert = client_cert,
                .client_key = client_key,
            });
        }

        return Session{
            .client = self,
            .allocator = self.allocator,
            .endpoint = ep,
            .auth = http_auth,
            .owned_basic = owned_basic,
            .insecure_skip_tls = insecure,
        };
    }
};

/// Single-threaded host Io for default OsRoundTripper construction.
///
/// Threadlocal so the Threaded storage outlives the Io handle for the process
/// lifetime of the Client on this thread (same pattern as `remote/session.zig`).
fn singleThreadedIo() std.Io {
    const Holder = struct {
        threadlocal var threaded: std.Io.Threaded = .init_single_threaded;
    };
    return Holder.threaded.io();
}

/// go-git `NewClient(nil)` — default options with owned OsRoundTripper.
pub fn newClient(allocator: Allocator) Allocator.Error!Client {
    return Client.init(allocator, null, .{});
}

/// go-git `NewClientWithOptions`. Null `rt` still attaches OsRoundTripper.
pub fn newClientWithOptions(allocator: Allocator, rt: ?RoundTripper, opts: ClientOptions) Allocator.Error!Client {
    return Client.init(allocator, rt, opts);
}

/// go-git package-level `DefaultClient` construction helper.
///
/// Equivalent of `DefaultClient = NewClient(nil)`. Owns an OsRoundTripper —
/// call `Client.deinit` when finished.
pub fn defaultClient(allocator: Allocator) Allocator.Error!Client {
    return newClient(allocator);
}

// ---------------------------------------------------------------------------
// Session base (go-git `session`)
// ---------------------------------------------------------------------------

/// Shared session state for upload-pack and receive-pack.
pub const Session = struct {
    client: *Client,
    allocator: Allocator,
    /// Borrowed endpoint (caller owns lifetime; may be mutated on redirect).
    endpoint: *Endpoint,
    auth: ?AuthMethod = null,
    /// When auth comes from endpoint user/password.
    owned_basic: ?BasicAuth = null,
    adv_refs: ?*packp.AdvRefs = null,
    insecure_skip_tls: bool = false,

    pub fn applyAuthToRequest(self: *Session, headers: *HeaderMap) !void {
        if (self.auth) |a| {
            try a.setAuth(headers);
            return;
        }
        if (self.owned_basic) |*ba| {
            try ba.setAuth(headers);
        }
    }

    pub fn close(self: *Session) void {
        if (self.adv_refs) |ar| {
            packp.freeAdvRefs(self.allocator, ar);
            self.adv_refs = null;
        }
    }

    /// go-git `advertisedReferences`.
    pub fn advertisedReferences(self: *Session, service_name: []const u8) !*packp.AdvRefs {
        if (self.adv_refs) |ar| return ar;

        const url = try infoRefsURL(self.allocator, self.endpoint, service_name);
        defer self.allocator.free(url);

        var req = Request{
            .allocator = self.allocator,
            .method = "GET",
            .url = try self.allocator.dupe(u8, url),
            .headers = HeaderMap.init(self.allocator),
            .is_initial = true,
        };
        defer req.deinit();
        try applyHeaders(&req.headers, null, self.endpoint.host, service_name);
        try self.applyAuthToRequest(&req.headers);

        var res = try self.doRequest(&req);
        defer res.deinit();

        try self.modifyEndpointIfRedirect(&res);
        try mapResponseErr(&res, url);

        const ar = try packp.allocAdvRefs(self.allocator);
        errdefer packp.freeAdvRefs(self.allocator, ar);

        var reader: std.Io.Reader = .fixed(res.body);
        ar.decode(&reader) catch |err| {
            if (err == error.EmptyAdvRefs) {
                return transport.Error.EmptyRemoteRepository;
            }
            return err;
        };

        // Empty repos are valid for receive-pack only (go-git).
        if (ar.isEmpty() and !std.mem.eql(u8, service_name, transport.ReceivePackServiceName)) {
            return transport.Error.EmptyRemoteRepository;
        }

        transport.filterUnsupportedCapabilities(&ar.capabilities);
        self.adv_refs = ar;
        return ar;
    }

    /// go-git `(*session).ModifyEndpointIfRedirect`.
    pub fn modifyEndpointIfRedirect(self: *Session, res: *const Response) !void {
        const final = res.final_url orelse return;
        try applyRedirectUrl(self, final);
    }

    /// Apply a redirect target URL string to the session endpoint.
    ///
    /// On allocation failure, replacement slices are freed and the endpoint is
    /// left unchanged. Credential clear for cross-host happens only after all
    /// allocations succeed.
    pub fn applyRedirectUrl(self: *Session, final_url: []const u8) !void {
        const uri = std.Uri.parse(final_url) catch return Error.RedirectInvalid;
        const scheme = uri.scheme;
        if (!isHttpScheme(scheme)) return Error.RedirectInvalid;

        const path = switch (uri.path) {
            .raw => |p| p,
            .percent_encoded => |p| p,
        };
        if (!std.mem.endsWith(u8, path, info_refs_path)) return Error.RedirectInvalid;

        // Scheme change rules: only http→https upgrade is allowed (go-git).
        if (!std.ascii.eqlIgnoreCase(scheme, self.endpoint.protocol)) {
            const ok_upgrade = std.ascii.eqlIgnoreCase(self.endpoint.protocol, "http") and
                std.ascii.eqlIgnoreCase(scheme, "https");
            if (!ok_upgrade) return Error.RedirectInvalid;
        }

        const host_raw = blk: {
            if (uri.host) |h| break :blk switch (h) {
                .raw => |s| s,
                .percent_encoded => |s| s,
            };
            break :blk "";
        };
        // Endpoint empty fields use non-owned `&.{}` (see Endpoint.deinit).
        var host: []u8 = if (host_raw.len == 0)
            &.{}
        else
            try endpointHostOwned(self.allocator, host_raw);
        errdefer freeEndpointField(self.allocator, &host);

        const port: i32 = if (uri.port) |p| @intCast(p) else 0;

        const new_path_len = path.len - info_refs_path.len;
        var new_path: []u8 = if (new_path_len == 0)
            &.{}
        else
            try self.allocator.dupe(u8, path[0..new_path_len]);
        errdefer freeEndpointField(self.allocator, &new_path);

        var new_proto: []u8 = try self.allocator.dupe(u8, scheme);
        errdefer freeEndpointField(self.allocator, &new_proto);

        // Cross-host: clear credentials (go-git). Drop auth first — owned_basic
        // may borrow endpoint user/password slices.
        const cross = !std.mem.eql(u8, host, self.endpoint.host) or
            effectivePort(scheme, port) != effectivePort(self.endpoint.protocol, self.endpoint.port);
        if (cross) {
            self.auth = null;
            self.owned_basic = null;
            freeEndpointField(self.allocator, &self.endpoint.user);
            freeEndpointField(self.allocator, &self.endpoint.password);
        }

        // Commit: free old owned fields, then install replacements.
        freeEndpointField(self.allocator, &self.endpoint.protocol);
        freeEndpointField(self.allocator, &self.endpoint.host);
        freeEndpointField(self.allocator, &self.endpoint.path);
        self.endpoint.protocol = new_proto;
        self.endpoint.host = host;
        self.endpoint.port = port;
        self.endpoint.path = new_path;
    }

    fn doRequest(self: *Session, req: *const Request) !Response {
        const rt = self.client.round_tripper orelse return Error.NoRoundTripper;
        // Live redirect policy lives in OsRoundTripper. MockRoundTripper
        // returns canned status/body/final_url without following hops.
        return rt.roundTrip(req);
    }

    /// POST with body; returns owned Response.
    pub fn doPost(
        self: *Session,
        service_name: []const u8,
        url: []const u8,
        body: []const u8,
    ) !Response {
        var req = Request{
            .allocator = self.allocator,
            .method = "POST",
            .url = try self.allocator.dupe(u8, url),
            .headers = HeaderMap.init(self.allocator),
            .body = body,
            .is_initial = false,
        };
        defer req.deinit();
        try applyHeaders(&req.headers, body.len, self.endpoint.host, service_name);
        try self.applyAuthToRequest(&req.headers);

        var res = try self.doRequest(&req);
        errdefer res.deinit();
        try mapResponseErr(&res, url);
        return res;
    }
};

fn mapResponseErr(res: *const Response, request_url: []const u8) !void {
    switch (newErr(res.status_code, res.body, request_url)) {
        .ok => {},
        .transport => |e| return e,
        .http => return Error.HttpStatusError,
    }
}

/// Free an Endpoint owned field and reset to empty non-owned `&.{}`.
fn freeEndpointField(allocator: Allocator, field: *[]u8) void {
    if (field.*.len != 0) allocator.free(field.*);
    field.* = &.{};
}

fn endpointHostOwned(allocator: Allocator, host: []const u8) Allocator.Error![]u8 {
    // go-git endpointHost: wrap IPv6 in brackets when host contains ':'.
    if (std.mem.indexOfScalar(u8, host, ':') != null and
        !(host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']'))
    {
        return std.fmt.allocPrint(allocator, "[{s}]", .{host});
    }
    return allocator.dupe(u8, host);
}

pub fn endpointHost(host: []const u8, buf: []u8) []const u8 {
    if (std.mem.indexOfScalar(u8, host, ':') != null and
        !(host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']'))
    {
        return std.fmt.bufPrint(buf, "[{s}]", .{host}) catch host;
    }
    return host;
}

pub fn endpointPort(port_str: []const u8) !i32 {
    if (port_str.len == 0) return 0;
    return std.fmt.parseInt(i32, port_str, 10) catch return Error.RedirectInvalid;
}

pub fn effectivePort(scheme: []const u8, port: i32) i32 {
    if (port != 0) return port;
    if (std.ascii.eqlIgnoreCase(scheme, "http")) return 80;
    if (std.ascii.eqlIgnoreCase(scheme, "https")) return 443;
    return 0;
}

/// go-git `checkRedirect` — called for each hop about to be followed, not on
/// the original request. `redirect_count` is `len(via)` in go-git terms
/// (0 on the first redirect decision; reject at `>= 10`).
///
/// Shared policy oracle for the insecure OS path, unit tests, and any custom
/// RoundTripper that walks hops manually. The verified OS path encodes the
/// same rules into `std.http.Client.Request.RedirectBehavior`.
pub fn checkRedirectPolicy(
    policy: RedirectPolicy,
    is_initial: bool,
    target_url: []const u8,
    redirect_count: usize,
) Error!void {
    switch (policy) {
        .always => {},
        .never => return Error.RedirectBlocked,
        .initial => {
            if (!is_initial) return Error.RedirectBlocked;
        },
    }
    if (std.mem.indexOf(u8, target_url, "://")) |idx| {
        const scheme = target_url[0..idx];
        if (!isHttpScheme(scheme)) return Error.RedirectInvalid;
    }
    if (redirect_count >= 10) return Error.TooManyRedirects;
}

// ---------------------------------------------------------------------------
// Unit tests (auth, URL, NewErr, redirect policy — more in common_test.zig)
// ---------------------------------------------------------------------------

test "BasicAuth Name and String" {
    const gpa = testing.allocator;
    var a = BasicAuth{ .username = "foo", .password = "qux" };
    try testing.expectEqualStrings("http-basic-auth", a.name());
    const s = try a.string(gpa);
    defer gpa.free(s);
    try testing.expectEqualStrings("http-basic-auth - foo:*******", s);

    var empty_pw = BasicAuth{ .username = "u", .password = "" };
    const s2 = try empty_pw.string(gpa);
    defer gpa.free(s2);
    try testing.expectEqualStrings("http-basic-auth - u:<empty>", s2);
}

test "TokenAuth Name String SetAuth" {
    const gpa = testing.allocator;
    var a = TokenAuth{ .token = "OAUTH-TOKEN-TEXT" };
    try testing.expectEqualStrings("http-token-auth", a.name());
    const s = try a.string(gpa);
    defer gpa.free(s);
    try testing.expectEqualStrings("http-token-auth - *******", s);

    var headers = HeaderMap.init(gpa);
    defer headers.deinit();
    try a.setAuth(&headers);
    try testing.expectEqualStrings("Bearer OAUTH-TOKEN-TEXT", headers.get("Authorization").?);
}

test "BasicAuth SetAuth base64" {
    const gpa = testing.allocator;
    var a = BasicAuth{ .username = "user", .password = "pass" };
    var headers = HeaderMap.init(gpa);
    defer headers.deinit();
    try a.setAuth(&headers);
    // user:pass → dXNlcjpwYXNz
    try testing.expectEqualStrings("Basic dXNlcjpwYXNz", headers.get("Authorization").?);
}

test "NewErr status mapping" {
    try testing.expect(newErr(200, "", "") == .ok);
    try testing.expect(newErr(204, "", "") == .ok);
    switch (newErr(401, "nope", "http://x")) {
        .transport => |e| try testing.expect(e == transport.Error.AuthenticationRequired),
        else => return error.TestUnexpectedResult,
    }
    switch (newErr(403, "", "")) {
        .transport => |e| try testing.expect(e == transport.Error.AuthorizationFailed),
        else => return error.TestUnexpectedResult,
    }
    switch (newErr(404, "", "")) {
        .transport => |e| try testing.expect(e == transport.Error.RepositoryNotFound),
        else => return error.TestUnexpectedResult,
    }
    switch (newErr(402, "pay", "http://x")) {
        .http => |h| {
            try testing.expectEqual(@as(u16, 402), h.status_code);
            try testing.expectEqualStrings("pay", h.reason);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (newErr(500, "boom", "http://x")) {
        .http => |h| try testing.expectEqual(@as(u16, 500), h.status_code),
        else => return error.TestUnexpectedResult,
    }
}

test "infoRefsURL and serviceURL" {
    const gpa = testing.allocator;
    var ep = try transport.newEndpoint(gpa, testing.io, "https://github.com/git-fixtures/basic");
    defer ep.deinit();

    const info = try infoRefsURL(gpa, &ep, transport.UploadPackServiceName);
    defer gpa.free(info);
    try testing.expectEqualStrings(
        "https://github.com/git-fixtures/basic/info/refs?service=git-upload-pack",
        info,
    );

    const svc = try serviceURL(gpa, &ep, transport.UploadPackServiceName);
    defer gpa.free(svc);
    try testing.expectEqualStrings(
        "https://github.com/git-fixtures/basic/git-upload-pack",
        svc,
    );

    const rcv = try serviceURL(gpa, &ep, transport.ReceivePackServiceName);
    defer gpa.free(rcv);
    try testing.expectEqualStrings(
        "https://github.com/git-fixtures/basic/git-receive-pack",
        rcv,
    );
}

test "isHttpScheme and invalid schemes" {
    try testing.expect(isHttpScheme("http"));
    try testing.expect(isHttpScheme("https"));
    try testing.expect(isHttpScheme("HTTP"));
    try testing.expect(!isHttpScheme("git"));
    try testing.expect(!isHttpScheme("ssh"));
    try testing.expect(!isHttpScheme("file"));
}

test "newSession applies ClientOptions proxy onto OsRoundTripper" {
    const gpa = testing.allocator;
    var cl = try newClientWithOptions(gpa, null, .{
        .proxy = .{ .url = "http://proxy.local:8888" },
    });
    defer cl.deinit();

    var ep = try transport.newEndpoint(gpa, testing.io, "https://example.com/repo.git");
    defer ep.deinit();
    var sess = try cl.newSession(&ep, null);
    defer sess.close();

    const os_rt = cl.owned_os_rt.?;
    try testing.expect(os_rt.client.http_proxy != null);
    try testing.expectEqualStrings("proxy.local", os_rt.client.http_proxy.?.host.bytes);
    try testing.expectEqual(@as(u16, 8888), os_rt.client.http_proxy.?.port);
}

test "newSession Endpoint proxy wins over ClientOptions" {
    const gpa = testing.allocator;
    var cl = try newClientWithOptions(gpa, null, .{
        .proxy = .{ .url = "http://from-opts:1" },
    });
    defer cl.deinit();

    var ep = try transport.newEndpoint(gpa, testing.io, "https://example.com/repo.git");
    defer ep.deinit();
    ep.proxy = .{ .url = "http://from-endpoint:9" };
    var sess = try cl.newSession(&ep, null);
    defer sess.close();

    try testing.expectEqualStrings("from-endpoint", cl.owned_os_rt.?.client.http_proxy.?.host.bytes);
    try testing.expectEqual(@as(u16, 9), cl.owned_os_rt.?.client.http_proxy.?.port);
}

test "newSession CA load failure surfaces" {
    const gpa = testing.allocator;
    var cl = try newClient(gpa);
    defer cl.deinit();
    var ep = try transport.newEndpoint(gpa, testing.io, "https://example.com/repo.git");
    defer ep.deinit();
    ep.ca_bundle = "not-a-certificate";
    try testing.expectError(error.CertificateBundleLoadFailure, cl.newSession(&ep, null));
}

test "mock RoundTripper still works with proxy ClientOptions" {
    const gpa = testing.allocator;
    var mock = MockRoundTripper.init(gpa);
    defer mock.deinit();
    try mock.push(.{
        .status_code = 200,
        .body = "ok",
    });
    var cl = try newClientWithOptions(gpa, mock.asRoundTripper(), .{
        .proxy = .{ .url = "http://unused-proxy:1" },
        .ca_bundle = "ignored-for-mock",
    });
    defer cl.deinit();
    try testing.expect(cl.owned_os_rt == null);

    var ep = try transport.newEndpoint(gpa, testing.io, "https://example.com/r.git");
    defer ep.deinit();
    var sess = try cl.newSession(&ep, null);
    defer sess.close();

    var req = Request{
        .allocator = gpa,
        .method = "GET",
        .url = try gpa.dupe(u8, "https://example.com/r.git/info/refs"),
        .headers = HeaderMap.init(gpa),
    };
    defer req.deinit();
    var res = try cl.round_tripper.?.roundTrip(&req);
    defer res.deinit();
    try testing.expectEqual(@as(u16, 200), res.status_code);
}

test "DefaultClient / NewClient skeleton" {

    const gpa = testing.allocator;
    var c = try defaultClient(gpa);
    defer c.deinit();
    try testing.expect(c.round_tripper != null);
    try testing.expect(c.owned_os_rt != null);
    try testing.expect(c.follow == .initial);
    try testing.expect(!c.options.insecure_skip_tls);
    try testing.expectEqual(@as(usize, 0), c.options.cache_max_entries);
    try testing.expect(c.owned_os_rt.?.redirect_policy == .initial);

    var c2 = try newClientWithOptions(gpa, null, .{
        .cache_max_entries = 3,
        .redirect_policy = .always,
        .insecure_skip_tls = true,
    });
    defer c2.deinit();
    try testing.expect(c2.follow == .always);
    try testing.expect(c2.options.insecure_skip_tls);
    try testing.expectEqual(@as(usize, 3), c2.options.cache_max_entries);
    try testing.expect(c2.round_tripper != null);
    try testing.expect(c2.owned_os_rt != null);
    try testing.expect(c2.owned_os_rt.?.insecure_skip_tls);
    try testing.expect(c2.owned_os_rt.?.redirect_policy == .always);

    // Inject path: no owned OsRoundTripper; deinit is still required and safe.
    var mock = MockRoundTripper.init(gpa);
    defer mock.deinit();
    var c3 = try newClientWithOptions(gpa, mock.asRoundTripper(), .{ .redirect_policy = .never });
    defer c3.deinit();
    try testing.expect(c3.owned_os_rt == null);
    try testing.expect(c3.round_tripper != null);
    try testing.expect(c3.follow == .never);
}

test "applyRedirectUrl preserves credentials on same host" {
    const gpa = testing.allocator;
    var c = try newClient(gpa);
    defer c.deinit();
    var ep = try transport.newEndpoint(gpa, testing.io, "https://user:pass@example.com/old.git");
    defer ep.deinit();
    var auth = BasicAuth{ .username = "user", .password = "pass" };
    var sess = try c.newSession(&ep, auth.asTransportAuth());
    defer sess.close();

    try sess.applyRedirectUrl("https://example.com/new.git/info/refs");
    try testing.expect(sess.auth != null);
    try testing.expectEqualStrings("user", ep.user);
    try testing.expectEqualStrings("pass", ep.password);
    try testing.expectEqualStrings("example.com", ep.host);
    try testing.expectEqualStrings("/new.git", ep.path);
}

test "MockRoundTripper final_url drives modifyEndpointIfRedirect" {
    const gpa = testing.allocator;
    var mock = MockRoundTripper.init(gpa);
    defer mock.deinit();
    try mock.push(.{
        .status_code = 200,
        .body = "0000",
        .final_url = "https://cdn.example.com/repo.git/info/refs",
    });

    var c = try Client.init(gpa, mock.asRoundTripper(), .{});
    defer c.deinit();
    var ep = try transport.newEndpoint(gpa, testing.io, "https://example.com/repo.git");
    defer ep.deinit();
    var sess = try c.newSession(&ep, null);
    defer sess.close();

    // EmptyAdvRefs → EmptyRemoteRepository, but redirect mutation still runs first.
    _ = sess.advertisedReferences(transport.UploadPackServiceName) catch {};
    try testing.expectEqualStrings("cdn.example.com", ep.host);
    try testing.expectEqualStrings("/repo.git", ep.path);
}

test "MockRoundTripper copies canned response headers including multi-value" {
    const gpa = testing.allocator;
    var mock = MockRoundTripper.init(gpa);
    defer mock.deinit();
    try mock.push(.{
        .status_code = 200,
        .body = "ok",
        .headers = &.{
            .{ .name = "Content-Type", .value = "application/x-git-upload-pack-result" },
            .{ .name = "Set-Cookie", .value = "a=1" },
            .{ .name = "Set-Cookie", .value = "b=2" },
            .{ .name = "X-Custom", .value = "yes" },
        },
    });

    var req = Request{
        .allocator = gpa,
        .method = "GET",
        .url = try gpa.dupe(u8, "https://example.com/info/refs"),
        .headers = HeaderMap.init(gpa),
    };
    defer req.deinit();

    var res = try mock.roundTrip(&req);
    defer res.deinit();

    try testing.expectEqual(@as(u16, 200), res.status_code);
    try testing.expectEqualStrings("ok", res.body);
    try testing.expectEqual(@as(usize, 4), res.headers.entries.items.len);
    try testing.expectEqualStrings(
        "application/x-git-upload-pack-result",
        res.headers.get("Content-Type").?,
    );
    try testing.expectEqualStrings("yes", res.headers.get("X-Custom").?);
    try testing.expectEqualStrings("b=2", res.headers.get("Set-Cookie").?);
    var n_cookie: usize = 0;
    for (res.headers.entries.items) |e| {
        if (std.ascii.eqlIgnoreCase(e.name, "Set-Cookie")) n_cookie += 1;
    }
    try testing.expectEqual(@as(usize, 2), n_cookie);
}

test "invalid scheme on session" {
    const gpa = testing.allocator;
    var c = try newClient(gpa);
    defer c.deinit();
    var ep = try transport.newEndpoint(gpa, testing.io, "git://github.com/foo/bar");
    defer ep.deinit();
    try testing.expectError(Error.InvalidScheme, c.newSession(&ep, null));
}

test "InvalidAuthMethod rejects non-HTTP auth" {
    const gpa = testing.allocator;
    var c = try newClient(gpa);
    defer c.deinit();
    var ep = try transport.newEndpoint(gpa, testing.io, "https://example.com/repo.git");
    defer ep.deinit();

    const Dummy = struct {
        fn nameFn(_: *anyopaque) []const u8 {
            return "dummy";
        }
        fn formatFn(_: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
            return allocator.dupe(u8, "dummy");
        }
        const vt = transport.AuthMethod.VTable{ .name = nameFn, .format = formatFn };
    };
    var dummy_storage: u8 = 0;
    const dummy_auth = transport.AuthMethod{ .ptr = &dummy_storage, .vtable = &Dummy.vt };
    try testing.expectError(transport.Error.InvalidAuthMethod, c.newSession(&ep, dummy_auth));
}

test "checkRedirectPolicy" {
    try checkRedirectPolicy(.initial, true, "http://example.com/r", 0);
    try testing.expectError(Error.RedirectBlocked, checkRedirectPolicy(.initial, false, "http://x", 0));
    try checkRedirectPolicy(.always, false, "http://x", 0);
    try testing.expectError(Error.RedirectBlocked, checkRedirectPolicy(.never, true, "http://x", 0));
    try testing.expectError(Error.RedirectInvalid, checkRedirectPolicy(.always, true, "ftp://x", 0));
    try testing.expectError(Error.TooManyRedirects, checkRedirectPolicy(.always, true, "http://x", 10));
}

test "RedirectPolicy strings" {
    try testing.expect(RedirectPolicy.fromString("").? == .initial);
    try testing.expect(RedirectPolicy.fromString("initial").? == .initial);
    try testing.expect(RedirectPolicy.fromString("true").? == .always);
    try testing.expect(RedirectPolicy.fromString("false").? == .never);
    try testing.expect(RedirectPolicy.fromString("bogus") == null);
    try testing.expectEqualStrings("initial", RedirectPolicy.initial.toString());
    try testing.expectEqualStrings("true", RedirectPolicy.always.toString());
    try testing.expectEqualStrings("false", RedirectPolicy.never.toString());
}

test "effectivePort and endpointHost" {
    try testing.expectEqual(@as(i32, 80), effectivePort("http", 0));
    try testing.expectEqual(@as(i32, 443), effectivePort("https", 0));
    try testing.expectEqual(@as(i32, 8080), effectivePort("https", 8080));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("example.com", endpointHost("example.com", &buf));
    try testing.expectEqualStrings("[::1]", endpointHost("::1", &buf));
    try testing.expectEqualStrings("[::1]", endpointHost("[::1]", &buf));
}

test "applyHeaders info/refs and post" {
    const gpa = testing.allocator;
    var h = HeaderMap.init(gpa);
    defer h.deinit();
    try applyHeaders(&h, null, "example.com", transport.UploadPackServiceName);
    try testing.expectEqualStrings("go-git/5.x", h.get("User-Agent").?);
    try testing.expectEqualStrings("example.com", h.get("Host").?);
    try testing.expectEqualStrings("*/*", h.get("Accept").?);

    var h2 = HeaderMap.init(gpa);
    defer h2.deinit();
    try applyHeaders(&h2, 42, "h", transport.UploadPackServiceName);
    try testing.expectEqualStrings("application/x-git-upload-pack-result", h2.get("Accept").?);
    try testing.expectEqualStrings("application/x-git-upload-pack-request", h2.get("Content-Type").?);
    try testing.expectEqualStrings("42", h2.get("Content-Length").?);
}
