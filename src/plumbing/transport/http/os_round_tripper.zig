//! OS HTTP RoundTripper: verified `std.http.Client` plus insecure HTTPS.
//!
//! Default production path for HTTP transport sessions. Hermetic tests inject
//! `MockRoundTripper` instead.
//!
//! # Ownership
//!
//! `Client` owns the heap `OsRoundTripper` when constructed with a null inject
//! (`newClient` / `defaultClient` / `newClientWithOptions(..., null, ...)`).
//! Call `Client.deinit` exactly once; it calls `OsRoundTripper.deinit` and
//! destroys the heap value. Injected RoundTrippers are never owned.
//!
//! # Redirects
//!
//! Both the verified and insecure paths apply the same `RedirectPolicy`
//! (go-git `CheckRedirect` on `http.Client`):
//! - `never` — do not follow; first 3xx → `Error.RedirectBlocked`
//! - `initial` — follow only when `Request.is_initial` (info/refs GET)
//! - `always` — follow GETs up to 10 hops
//! - POST / payload requests never auto-follow (3xx returned to the session)
//!
//! After followed redirects, `Response.final_url` is the final request URI
//! (no userinfo) so `Session.modifyEndpointIfRedirect` can rewrite the
//! endpoint like go-git `res.Request.URL`.
//!
//! # Response headers
//!
//! Both paths copy every response header name/value into an owned
//! `HeaderMap` on `Response` (multi-value headers via `HeaderMap.add`).
//! Headers are snapshotted before the body stream invalidates head slices.
//!
//! # TLS / `insecure_skip_tls`
//!
//! Secure default (`insecure_skip_tls == false`): `std.http.Client` verifies
//! server certificates against the system CA bundle.
//!
//! When `insecure_skip_tls` is true **and** the URL scheme is `https://`,
//! requests use a dedicated path:
//! 1. TCP connect via `HostName.connect`
//! 2. TLS handshake with `std.crypto.tls.Client`
//!    (`host: .no_verification`, `ca: .no_verification`)
//! 3. HTTP/1.1 request/response over the TLS stream (`connection: close`)
//! 4. Redirect following under the same policy as the verified path
//!    (subsequent hops may be `http://` plain or `https://` insecure TLS)
//!
//! Plain `http://` with the flag set still uses `std.http.Client` (no TLS).
//!
//! # Proxy / CA / client certificate
//!
//! `configure` applies `TransportConfig` (ClientOptions + Endpoint; Endpoint
//! wins when set) onto the live OS client:
//! - **Proxy** — `std.http.Client.Proxy` on `http_proxy` / `https_proxy`.
//!   Insecure HTTPS uses HTTP CONNECT through the same proxy.
//! - **CA bundle** — PEM bytes into `client.ca_bundle` (system roots + custom).
//! - **Client cert/key** — validated; Zig 0.16 std TLS has no client-cert
//!   option, so HTTPS returns `error.ClientCertificateUnsupported`.
//!
//! Equivalent of go-git `InsecureSkipVerify` / `configureTransport`.

const std = @import("std");
const common = @import("common.zig");
const transport = @import("transport");

const Allocator = std.mem.Allocator;
const http = std.http;
const HostName = std.Io.net.HostName;
const TlsClient = std.crypto.tls.Client;
const Certificate = std.crypto.Certificate;
const ProxyOptions = transport.ProxyOptions;

const Request = common.Request;
const Response = common.Response;
const HeaderMap = common.HeaderMap;
const RoundTripper = common.RoundTripper;
const RedirectPolicy = common.RedirectPolicy;
const Error = common.Error;

/// Zig 0.16's std TLS client has no client-certificate/private-key inputs.
/// Keep this public so callers can reject mTLS before attempting a request.
pub const ClientCertificateCapability = enum {
    unsupported_zig_0_16_std_tls,
};

pub fn clientCertificateCapability() ClientCertificateCapability {
    return .unsupported_zig_0_16_std_tls;
}

/// Effective transport knobs applied to a live `OsRoundTripper`.
pub const TransportConfig = struct {
    redirect_policy: RedirectPolicy = .initial,
    insecure_skip_tls: bool = false,
    proxy: ProxyOptions = .{},
    ca_bundle: []const u8 = "",
    client_cert: []const u8 = "",
    client_key: []const u8 = "",
};

/// Max redirect hops (go-git `len(via) >= 10`).
const max_redirect_hops: usize = 10;

/// Buffer sizes for the insecure TLS path (mirrors std.http.Client sizing).
const insecure_tls_min = TlsClient.min_buffer_len;
const insecure_http_read_cap: usize = 8 * 1024;
const insecure_clear_write_cap: usize = 1024;
const insecure_redirect_buf_cap: usize = 8 * 1024;

/// Real OS sockets RoundTripper.
pub const OsRoundTripper = struct {
    allocator: Allocator,
    /// Borrowed Io handle. Default Client path uses a process threadlocal
    /// single-threaded `std.Io.Threaded`; keep use and deinit on that thread.
    io: std.Io,
    client: http.Client,
    /// Mirrored from `Client.follow` / session options.
    redirect_policy: RedirectPolicy = .initial,
    /// When true, HTTPS uses `tls.Client` with no host/CA verification.
    insecure_skip_tls: bool = false,

    proxy_opts: ProxyOptions = .{},
    ca_bundle_pem: []const u8 = "",
    client_cert: []const u8 = "",
    client_key: []const u8 = "",
    owned_proxy: ?http.Client.Proxy = null,
    proxy_host_owned: []u8 = &.{},
    proxy_auth_owned: ?[]u8 = null,

    pub fn init(allocator: Allocator, io: std.Io) OsRoundTripper {
        return .{
            .allocator = allocator,
            .io = io,
            .client = .{
                .allocator = allocator,
                .io = io,
            },
        };
    }

    pub fn deinit(self: *OsRoundTripper) void {
        self.clearProxyStorage();
        self.client.deinit();
        self.* = undefined;
    }

    pub fn asRoundTripper(self: *OsRoundTripper) RoundTripper {
        return RoundTripper.from(OsRoundTripper, self);
    }

    /// Apply proxy / CA / client-cert onto the live `std.http.Client`.
    pub fn configure(self: *OsRoundTripper, cfg: TransportConfig) !void {
        try validateClientCertConfig(cfg.client_cert, cfg.client_key);

        self.clearProxyStorage();
        self.client.deinit();
        self.client = .{
            .allocator = self.allocator,
            .io = self.io,
        };

        self.redirect_policy = cfg.redirect_policy;
        self.insecure_skip_tls = cfg.insecure_skip_tls;
        self.proxy_opts = cfg.proxy;
        self.ca_bundle_pem = cfg.ca_bundle;
        self.client_cert = cfg.client_cert;
        self.client_key = cfg.client_key;

        if (cfg.proxy.url.len != 0) {
            try self.installProxy(cfg.proxy);
        }
        if (cfg.ca_bundle.len != 0) {
            try self.loadCaBundle(cfg.ca_bundle);
        }
    }

    /// Perform one HTTP request. Returns an owned `Response` (caller deinits).
    pub fn roundTrip(self: *OsRoundTripper, req: *const Request) anyerror!Response {
        if (self.client_cert.len != 0 and isHttpsUrl(req.url)) {
            return error.ClientCertificateUnsupported;
        }
        if (usesInsecureTlsPath(self.insecure_skip_tls, req.url)) {
            return self.roundTripInsecure(req);
        }
        return self.roundTripVerified(req);
    }

    fn clearProxyStorage(self: *OsRoundTripper) void {
        self.client.http_proxy = null;
        self.client.https_proxy = null;
        self.owned_proxy = null;
        if (self.proxy_host_owned.len != 0) {
            self.allocator.free(self.proxy_host_owned);
            self.proxy_host_owned = &.{};
        }
        if (self.proxy_auth_owned) |auth| {
            self.allocator.free(auth);
            self.proxy_auth_owned = null;
        }
    }

    fn installProxy(self: *OsRoundTripper, opts: ProxyOptions) !void {
        const built = try buildHttpProxy(self.allocator, opts);
        self.proxy_host_owned = built.host_owned;
        self.proxy_auth_owned = built.auth_owned;
        self.owned_proxy = built.proxy;
        self.client.http_proxy = &self.owned_proxy.?;
        self.client.https_proxy = &self.owned_proxy.?;
    }

    fn loadCaBundle(self: *OsRoundTripper, pem: []const u8) !void {
        const now = std.Io.Clock.real.now(self.io);
        var bundle: Certificate.Bundle = .empty;
        errdefer bundle.deinit(self.allocator);

        bundle.rescan(self.allocator, self.io, now) catch {
            bundle.deinit(self.allocator);
            bundle = .empty;
        };
        try addCertsFromPemBytes(&bundle, self.allocator, pem, now.toSeconds());
        self.client.ca_bundle.deinit(self.allocator);
        self.client.ca_bundle = bundle;
        self.client.now = now;
    }

    // -----------------------------------------------------------------------
    // Verified path (std.http.Client + system CAs)
    // -----------------------------------------------------------------------

    fn roundTripVerified(self: *OsRoundTripper, req: *const Request) anyerror!Response {
        const method = try mapMethod(req.method);
        const uri = try std.Uri.parse(req.url);

        // Host and Content-Length are owned by std.http.Client.
        // Authorization is privileged (stripped on cross-domain redirect).
        var extra_list: std.ArrayListUnmanaged(http.Header) = .empty;
        defer extra_list.deinit(self.allocator);
        var privileged_list: std.ArrayListUnmanaged(http.Header) = .empty;
        defer privileged_list.deinit(self.allocator);

        var std_headers: http.Client.Request.Headers = .{};

        for (req.headers.entries.items) |e| {
            if (std.ascii.eqlIgnoreCase(e.name, "Host")) continue;
            if (std.ascii.eqlIgnoreCase(e.name, "Content-Length")) continue;
            if (std.ascii.eqlIgnoreCase(e.name, "User-Agent")) {
                std_headers.user_agent = .{ .override = e.value };
                continue;
            }
            if (std.ascii.eqlIgnoreCase(e.name, "Authorization")) {
                try privileged_list.append(self.allocator, .{
                    .name = e.name,
                    .value = e.value,
                });
                continue;
            }
            if (std.ascii.eqlIgnoreCase(e.name, "Content-Type")) {
                std_headers.content_type = .{ .override = e.value };
                continue;
            }
            try extra_list.append(self.allocator, .{
                .name = e.name,
                .value = e.value,
            });
        }

        const has_payload = requestHasPayload(req.method, req.body);
        const redirect_behavior = redirectBehaviorFor(self.redirect_policy, req.is_initial, has_payload);

        var http_req = try self.client.request(method, uri, .{
            .redirect_behavior = redirect_behavior,
            .headers = std_headers,
            .extra_headers = extra_list.items,
            .privileged_headers = privileged_list.items,
        });
        defer http_req.deinit();

        if (has_payload) {
            http_req.transfer_encoding = .{ .content_length = req.body.len };
            var body_writer = try http_req.sendBodyUnflushed(&.{});
            try body_writer.writer.writeAll(req.body);
            try body_writer.end();
            try http_req.connection.?.flush();
        } else {
            try http_req.sendBodiless();
        }

        const follows = redirect_behavior != .unhandled and redirect_behavior != .not_allowed;
        const redirect_buffer: []u8 = if (follows)
            try self.allocator.alloc(u8, insecure_redirect_buf_cap)
        else
            &.{};
        defer if (redirect_buffer.len != 0) self.allocator.free(redirect_buffer);

        var response = http_req.receiveHead(redirect_buffer) catch |err| switch (err) {
            error.TooManyHttpRedirects => return mapTooManyRedirects(redirect_behavior),
            else => |e| return e,
        };

        const final_url = try formatUriNoAuth(self.allocator, &http_req.uri);
        errdefer self.allocator.free(final_url);

        // Snapshot headers before body stream invalidates `response.head` strings.
        var headers = try copyHeadHeaders(self.allocator, response.head);
        errdefer headers.deinit();

        var body_aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body_aw.deinit();

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try self.allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer if (decompress_buffer.len != 0) self.allocator.free(decompress_buffer);

        var transfer_buffer: [64]u8 = undefined;
        var decompress: http.Decompress = undefined;
        const body_reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        _ = body_reader.streamRemaining(&body_aw.writer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
            else => |e| return e,
        };

        const body = try body_aw.toOwnedSlice();
        errdefer self.allocator.free(body);

        return Response{
            .allocator = self.allocator,
            .status_code = @intFromEnum(response.head.status),
            .body = body,
            .final_url = final_url,
            .headers = headers,
        };
    }

    // -----------------------------------------------------------------------
    // Insecure HTTPS path (tls.Client no_verification + HTTP/1.1)
    // -----------------------------------------------------------------------

    /// Insecure HTTPS entry: full HTTP/1.1 with body, redirect policy, and
    /// owned `Response` (`final_url` is the last request URL after follows).
    pub fn roundTripInsecureHttps(self: *OsRoundTripper, req: *const Request) anyerror!Response {
        return self.roundTripInsecure(req);
    }

    fn roundTripInsecure(self: *OsRoundTripper, req: *const Request) anyerror!Response {
        var current_url = try self.allocator.dupe(u8, req.url);
        defer self.allocator.free(current_url);

        // Method may switch POST→GET on 301/302/303; keep a small owned buffer.
        var method_buf: [8]u8 = undefined;
        var method: []const u8 = copyMethodToBuf(&method_buf, req.method);
        var body: []const u8 = req.body;
        var drop_auth = false;
        var via_len: usize = 0;

        while (true) {
            var hop = try self.performInsecureHop(method, current_url, body, &req.headers, drop_auth);
            // Manual cleanup only — errdefer would double-free after hop.deinit on continue.

            if (hop.status.class() != .redirect or requestHasPayload(method, body)) {
                const status = hop.status;
                const final_url = self.allocator.dupe(u8, current_url) catch |err| {
                    hop.deinit(self.allocator);
                    return err;
                };
                errdefer self.allocator.free(final_url);
                const owned_body = hop.takeBody();
                errdefer self.allocator.free(owned_body);
                const headers = hop.takeHeaders();
                hop.deinit(self.allocator);
                return Response{
                    .allocator = self.allocator,
                    .status_code = @intFromEnum(status),
                    .body = owned_body,
                    .final_url = final_url,
                    .headers = headers,
                };
            }

            const location = hop.headers.get("Location") orelse {
                hop.deinit(self.allocator);
                return Error.RedirectInvalid;
            };

            // Resolve Location against the current request URI.
            var aux_storage: [insecure_redirect_buf_cap]u8 = undefined;
            if (location.len > aux_storage.len) {
                hop.deinit(self.allocator);
                return Error.RedirectInvalid;
            }
            @memcpy(aux_storage[0..location.len], location);
            var aux_buf: []u8 = aux_storage[0..];
            const base_uri = std.Uri.parse(current_url) catch {
                hop.deinit(self.allocator);
                return Error.RedirectInvalid;
            };
            const new_uri = base_uri.resolveInPlace(location.len, &aux_buf) catch {
                hop.deinit(self.allocator);
                return Error.RedirectInvalid;
            };

            const next_url = formatUriNoAuth(self.allocator, &new_uri) catch |err| {
                hop.deinit(self.allocator);
                return err;
            };

            // Policy oracle (same as Mock / go-git CheckRedirect).
            common.checkRedirectPolicy(
                self.redirect_policy,
                req.is_initial,
                next_url,
                via_len,
            ) catch |err| {
                hop.deinit(self.allocator);
                self.allocator.free(next_url);
                return err;
            };

            // Cross-host / scheme change: drop Authorization (std.http parity).
            if (shouldDropAuthOnRedirect(current_url, next_url)) {
                drop_auth = true;
            }

            // 301/302/303 with POST → GET (no body). 307/308 keep method.
            if (redirectForcesGet(hop.status) and std.ascii.eqlIgnoreCase(method, "POST")) {
                method = copyMethodToBuf(&method_buf, "GET");
                body = "";
            }

            hop.deinit(self.allocator);
            self.allocator.free(current_url);
            current_url = next_url;
            via_len += 1;
        }
    }

    /// Single TCP(+TLS) hop: write request, read status/headers/body, close.
    fn performInsecureHop(
        self: *OsRoundTripper,
        method: []const u8,
        url: []const u8,
        body: []const u8,
        headers: *const HeaderMap,
        drop_auth: bool,
    ) anyerror!InsecureHop {
        const uri = try std.Uri.parse(url);
        const use_tls = std.ascii.eqlIgnoreCase(uri.scheme, "https");
        if (!use_tls and !std.ascii.eqlIgnoreCase(uri.scheme, "http")) {
            return Error.RedirectInvalid;
        }

        var host_name_buffer: [HostName.max_len]u8 = undefined;
        const host = try uri.getHost(&host_name_buffer);
        const port: u16 = uri.port orelse if (use_tls) @as(u16, 443) else @as(u16, 80);

        var stream = try self.connectInsecureStream(host, port, use_tls);
        defer stream.close(self.io);

        // Scratch buffers live for the hop only.
        const socket_read_buf = try self.allocator.alloc(u8, insecure_tls_min);
        defer self.allocator.free(socket_read_buf);
        const socket_write_buf = try self.allocator.alloc(u8, insecure_tls_min);
        defer self.allocator.free(socket_write_buf);

        var stream_reader = stream.reader(self.io, socket_read_buf);
        var stream_writer = stream.writer(self.io, socket_write_buf);

        if (use_tls) {
            const tls_read_buf = try self.allocator.alloc(u8, insecure_tls_min + insecure_http_read_cap);
            defer self.allocator.free(tls_read_buf);
            const tls_write_buf = try self.allocator.alloc(u8, insecure_clear_write_cap);
            defer self.allocator.free(tls_write_buf);

            var random_buffer: [TlsClient.Options.entropy_len]u8 = undefined;
            self.io.random(&random_buffer);
            const now = std.Io.Clock.real.now(self.io);

            var tls = try TlsClient.init(
                &stream_reader.interface,
                &stream_writer.interface,
                .{
                    .host = .no_verification,
                    .ca = .no_verification,
                    .read_buffer = tls_read_buf,
                    .write_buffer = tls_write_buf,
                    .entropy = &random_buffer,
                    .realtime_now = now,
                    // HTTP framing detects truncation; close_notify is best-effort.
                    .allow_truncation_attacks = true,
                },
            );

            try writeInsecureHttpRequest(&tls.writer, method, &uri, body, headers, drop_auth);
            try tls.writer.flush();
            try stream_writer.interface.flush();

            var http_reader: http.Reader = .{
                .in = &tls.reader,
                .interface = undefined,
                .state = .ready,
                .max_head_len = insecure_http_read_cap,
            };

            const hop = try readInsecureResponse(self.allocator, &http_reader);
            tls.end() catch {};
            stream_writer.interface.flush() catch {};
            return hop;
        }

        try writeInsecureHttpRequest(&stream_writer.interface, method, &uri, body, headers, drop_auth);
        try stream_writer.interface.flush();

        var http_reader: http.Reader = .{
            .in = &stream_reader.interface,
            .interface = undefined,
            .state = .ready,
            .max_head_len = insecure_http_read_cap,
        };
        return try readInsecureResponse(self.allocator, &http_reader);
    }

    fn connectInsecureStream(
        self: *OsRoundTripper,
        target_host: HostName,
        target_port: u16,
        use_tls: bool,
    ) !std.Io.net.Stream {
        const proxy = self.owned_proxy orelse {
            return target_host.connect(self.io, target_port, .{ .mode = .stream });
        };
        _ = use_tls;
        if (!proxy.supports_connect) return error.TunnelNotSupported;

        var stream = try proxy.host.connect(self.io, proxy.port, .{ .mode = .stream });
        errdefer stream.close(self.io);

        var read_buf: [1024]u8 = undefined;
        var write_buf: [1024]u8 = undefined;
        var reader = stream.reader(self.io, &read_buf);
        var writer = stream.writer(self.io, &write_buf);

        try writer.interface.print("CONNECT {s}:{d} HTTP/1.1\r\n", .{ target_host.bytes, target_port });
        try writer.interface.print("host: {s}:{d}\r\n", .{ target_host.bytes, target_port });
        if (proxy.authorization) |auth| {
            try writer.interface.print("proxy-authorization: {s}\r\n", .{auth});
        }
        try writer.interface.writeAll("\r\n");
        try writer.interface.flush();

        const status_line = try reader.interface.takeDelimiterExclusive('\n');
        const status = std.mem.trimEnd(u8, status_line, "\r");
        if (!connectStatusOk(status)) return error.HttpConnectFailed;

        while (true) {
            const line = try reader.interface.takeDelimiterExclusive('\n');
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (trimmed.len == 0) break;
        }
        return stream;
    }
};

/// One insecure-path response hop (owned body + full response headers).
const InsecureHop = struct {
    status: http.Status,
    body: []u8 = &.{},
    headers: HeaderMap,

    fn takeBody(self: *InsecureHop) []u8 {
        const b = self.body;
        self.body = &.{};
        return b;
    }

    fn takeHeaders(self: *InsecureHop) HeaderMap {
        const h = self.headers;
        self.headers = HeaderMap.init(h.allocator);
        return h;
    }

    /// Idempotent: safe if body/headers already transferred or cleared.
    fn deinit(self: *InsecureHop, allocator: Allocator) void {
        // free is a no-op for zero-length slices.
        allocator.free(self.body);
        self.body = &.{};
        self.headers.deinit();
        self.headers = HeaderMap.init(allocator);
    }
};

fn readInsecureResponse(allocator: Allocator, http_reader: *http.Reader) anyerror!InsecureHop {
    const head_buffer = try http_reader.receiveHead();
    const head = try http.Client.Response.Head.parse(head_buffer);

    // Snapshot every header before body read invalidates head buffer slices.
    var headers = try copyHeadHeaders(allocator, head);
    errdefer headers.deinit();

    var body_aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer body_aw.deinit();

    const decompress_buffer: []u8 = switch (head.content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buffer.len != 0) allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const body_reader = http_reader.bodyReaderDecompressing(
        &transfer_buffer,
        head.transfer_encoding,
        head.content_length,
        head.content_encoding,
        &decompress,
        decompress_buffer,
    );
    _ = body_reader.streamRemaining(&body_aw.writer) catch |err| switch (err) {
        error.ReadFailed => return http_reader.body_err orelse error.ReadFailed,
        else => |e| return e,
    };

    const body = try body_aw.toOwnedSlice();
    return .{
        .status = head.status,
        .body = body,
        .headers = headers,
    };
}

/// Copy every non-trailer header from a parsed response head into an owned map.
/// Multi-value headers are each `add`ed (Go `Header.Add` / `HeaderMap.add`).
fn copyHeadHeaders(allocator: Allocator, head: http.Client.Response.Head) Allocator.Error!HeaderMap {
    var map = HeaderMap.init(allocator);
    errdefer map.deinit();
    var it = head.iterateHeaders();
    while (it.next()) |h| {
        // Head buffer may include trailer section after the blank line; skip it.
        if (it.is_trailer) continue;
        try map.add(h.name, h.value);
    }
    return map;
}

/// Parse HTTP response head bytes into an owned `HeaderMap`.
///
/// `head_bytes` is status-line + headers ending with `\r\n\r\n` (as produced by
/// `http.Reader.receiveHead` / `http.Client.Response.Head.bytes`). Used by both
/// OS paths and unit-tested hermetically without sockets.
pub fn headerMapFromHeadBytes(allocator: Allocator, head_bytes: []const u8) (http.Client.Response.Head.ParseError || Allocator.Error)!HeaderMap {
    const head = try http.Client.Response.Head.parse(head_bytes);
    return copyHeadHeaders(allocator, head);
}

/// True when the OS tripper should use the insecure TLS path (https + skip).
pub fn usesInsecureTlsPath(insecure_skip_tls: bool, url: []const u8) bool {
    if (!insecure_skip_tls) return false;
    return isHttpsUrl(url);
}

pub fn isHttpsUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    return std.ascii.eqlIgnoreCase(uri.scheme, "https");
}

pub fn validateClientCertConfig(cert: []const u8, key: []const u8) error{ClientCertificateConfigInvalid}!void {
    if (cert.len == 0 and key.len == 0) return;
    if (cert.len == 0 or key.len == 0) return error.ClientCertificateConfigInvalid;
    if (std.mem.indexOf(u8, cert, "-----BEGIN") == null) return error.ClientCertificateConfigInvalid;
    if (std.mem.indexOf(u8, key, "-----BEGIN") == null) return error.ClientCertificateConfigInvalid;
}

const BuiltProxy = struct {
    proxy: http.Client.Proxy,
    host_owned: []u8,
    auth_owned: ?[]u8,
};

pub fn buildHttpProxy(allocator: Allocator, opts: ProxyOptions) !BuiltProxy {
    if (opts.url.len == 0) return error.InvalidProxyURL;
    try opts.validate();

    var uri = std.Uri.parse(opts.url) catch return error.InvalidProxyURL;
    if (opts.username.len != 0) {
        uri.user = .{ .raw = opts.username };
        if (opts.password.len != 0) {
            uri.password = .{ .raw = opts.password };
        } else {
            uri.password = null;
        }
    }

    const protocol: http.Client.Protocol = blk: {
        if (std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "ws"))
            break :blk .plain;
        if (std.ascii.eqlIgnoreCase(uri.scheme, "https") or std.ascii.eqlIgnoreCase(uri.scheme, "wss"))
            break :blk .tls;
        return error.InvalidProxyURL;
    };

    var host_buf: [HostName.max_len]u8 = undefined;
    const host_tmp = uri.getHost(&host_buf) catch return error.InvalidProxyURL;
    const host_owned = try allocator.dupe(u8, host_tmp.bytes);
    errdefer allocator.free(host_owned);

    var auth_owned: ?[]u8 = null;
    errdefer if (auth_owned) |a| allocator.free(a);
    if (uri.user != null or uri.password != null) {
        const auth = try allocator.alloc(u8, http.Client.basic_authorization.valueLengthFromUri(uri));
        _ = http.Client.basic_authorization.value(uri, auth);
        auth_owned = auth;
    }

    const port: u16 = uri.port orelse switch (protocol) {
        .plain => @as(u16, 80),
        .tls => @as(u16, 443),
    };
    return .{
        .proxy = .{
            .protocol = protocol,
            .host = .{ .bytes = host_owned },
            .authorization = auth_owned,
            .port = port,
            .supports_connect = true,
        },
        .host_owned = host_owned,
        .auth_owned = auth_owned,
    };
}

pub fn addCertsFromPemBytes(
    bundle: *Certificate.Bundle,
    gpa: Allocator,
    pem: []const u8,
    now_sec: i64,
) error{ CertificateBundleLoadFailure, OutOfMemory }!void {
    if (pem.len == 0) return;

    const begin_marker = "-----BEGIN CERTIFICATE-----";
    const end_marker = "-----END CERTIFICATE-----";
    const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");

    var start_index: usize = 0;
    var found: usize = 0;
    while (std.mem.indexOfPos(u8, pem, start_index, begin_marker)) |begin_marker_start| {
        const cert_start = begin_marker_start + begin_marker.len;
        const cert_end = std.mem.indexOfPos(u8, pem, cert_start, end_marker) orelse
            return error.CertificateBundleLoadFailure;
        start_index = cert_end + end_marker.len;
        const encoded_cert = std.mem.trim(u8, pem[cert_start..cert_end], " \t\r\n");

        const decoded_size_upper = encoded_cert.len / 4 * 3 + 3;
        const decoded_start: u32 = @intCast(bundle.bytes.items.len);
        try bundle.bytes.ensureUnusedCapacity(gpa, decoded_size_upper);
        const dest_buf = bundle.bytes.allocatedSlice()[decoded_start..];
        const written = base64.decode(dest_buf, encoded_cert) catch
            return error.CertificateBundleLoadFailure;
        bundle.bytes.items.len = decoded_start + written;

        bundle.parseCert(gpa, decoded_start, now_sec) catch {
            bundle.bytes.items.len = decoded_start;
            continue;
        };
        found += 1;
    }
    if (found == 0) return error.CertificateBundleLoadFailure;
}

fn connectStatusOk(status_line: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, status_line, " \t");
    _ = it.next() orelse return false;
    const code = it.next() orelse return false;
    return std.mem.eql(u8, code, "200");
}

fn requestHasPayload(method: []const u8, body: []const u8) bool {
    return body.len > 0 or std.ascii.eqlIgnoreCase(method, "POST");
}

fn redirectForcesGet(status: http.Status) bool {
    return switch (status) {
        .moved_permanently, .found, .see_other => true,
        else => false,
    };
}

fn copyMethodToBuf(buf: *[8]u8, method: []const u8) []const u8 {
    if (method.len > buf.len) return method; // caller only passes short methods
    @memcpy(buf.*[0..method.len], method);
    return buf.*[0..method.len];
}

fn shouldDropAuthOnRedirect(from_url: []const u8, to_url: []const u8) bool {
    const from = std.Uri.parse(from_url) catch return true;
    const to = std.Uri.parse(to_url) catch return true;
    if (!std.ascii.eqlIgnoreCase(from.scheme, to.scheme)) return true;

    var from_host_buf: [HostName.max_len]u8 = undefined;
    var to_host_buf: [HostName.max_len]u8 = undefined;
    const from_host = from.getHost(&from_host_buf) catch return true;
    const to_host = to.getHost(&to_host_buf) catch return true;
    return !from_host.sameParentDomain(to_host);
}

/// Write HTTP/1.1 request line, headers, and optional body to `w`.
fn writeInsecureHttpRequest(
    w: *std.Io.Writer,
    method: []const u8,
    uri: *const std.Uri,
    body: []const u8,
    headers: *const HeaderMap,
    drop_auth: bool,
) anyerror!void {
    try w.writeAll(method);
    try w.writeByte(' ');
    try uri.writeToStream(w, .{
        .path = true,
        .query = true,
    });
    try w.writeAll(" HTTP/1.1\r\n");

    try w.writeAll("host: ");
    try uri.writeToStream(w, .{ .authority = true });
    try w.writeAll("\r\n");

    var saw_user_agent = false;
    for (headers.entries.items) |e| {
        if (std.ascii.eqlIgnoreCase(e.name, "Host")) continue;
        if (std.ascii.eqlIgnoreCase(e.name, "Content-Length")) continue;
        if (drop_auth and std.ascii.eqlIgnoreCase(e.name, "Authorization")) continue;
        if (std.ascii.eqlIgnoreCase(e.name, "User-Agent")) saw_user_agent = true;
        try w.writeAll(e.name);
        try w.writeAll(": ");
        try w.writeAll(e.value);
        try w.writeAll("\r\n");
    }
    if (!saw_user_agent) {
        try w.writeAll("user-agent: gitz/http-insecure\r\n");
    }

    const has_payload = requestHasPayload(method, body);
    if (has_payload) {
        try w.print("content-length: {d}\r\n", .{body.len});
    }

    // One-shot connection; no keep-alive on the insecure path.
    try w.writeAll("connection: close\r\n");
    try w.writeAll("\r\n");

    if (has_payload and body.len > 0) {
        try w.writeAll(body);
    }
}

/// Map go-git redirect policy + request kind to std.http redirect behavior.
///
/// POST with a body cannot be auto-resent by std after a redirect; leave those
/// unhandled so the 3xx status returns to the session layer.
fn redirectBehaviorFor(
    policy: RedirectPolicy,
    is_initial: bool,
    has_payload: bool,
) http.Client.Request.RedirectBehavior {
    if (has_payload) return .unhandled;
    return switch (policy) {
        .never => .not_allowed,
        // go-git allows up to 10 prior hops (`len(via) >= 10`).
        .initial => if (is_initial) @enumFromInt(max_redirect_hops) else .not_allowed,
        .always => @enumFromInt(max_redirect_hops),
    };
}

/// Map std `TooManyHttpRedirects` to policy-specific package errors.
fn mapTooManyRedirects(behavior: http.Client.Request.RedirectBehavior) Error {
    // `not_allowed` means policy blocked the first redirect hop.
    // Integer remaining exhausted means too many hops after following.
    return if (behavior == .not_allowed) Error.RedirectBlocked else Error.TooManyRedirects;
}

fn formatUriNoAuth(allocator: Allocator, uri: *const std.Uri) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const flags = std.Uri.Format.Flags{
        .scheme = true,
        .authentication = false,
        .authority = true,
        .path = true,
        .query = true,
        .fragment = true,
        .port = true,
    };
    uri.writeToStream(&aw.writer, flags) catch return error.OutOfMemory;
    return try aw.toOwnedSlice();
}

fn mapMethod(method: []const u8) error{UnsupportedMethod}!http.Method {
    if (std.ascii.eqlIgnoreCase(method, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(method, "POST")) return .POST;
    return error.UnsupportedMethod;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "OsRoundTripper init deinit and asRoundTripper vtable" {
    const gpa = std.testing.allocator;
    var os_rt = OsRoundTripper.init(gpa, std.testing.io);
    defer os_rt.deinit();

    const rt = os_rt.asRoundTripper();
    try std.testing.expect(rt.ptr == @as(*anyopaque, @ptrCast(&os_rt)));

    var req = Request{
        .allocator = gpa,
        .method = "GET",
        .url = try gpa.dupe(u8, "http://127.0.0.1:1/"),
        .headers = HeaderMap.init(gpa),
    };
    defer req.deinit();

    const result = rt.roundTrip(&req);
    try std.testing.expect(std.meta.isError(result));
}

test "OsRoundTripper mapMethod" {
    try std.testing.expect((try mapMethod("GET")) == .GET);
    try std.testing.expect((try mapMethod("get")) == .GET);
    try std.testing.expect((try mapMethod("POST")) == .POST);
    try std.testing.expect((try mapMethod("post")) == .POST);
    try std.testing.expectError(error.UnsupportedMethod, mapMethod("PUT"));
    try std.testing.expectError(error.UnsupportedMethod, mapMethod("DELETE"));
}

test "redirectBehaviorFor policy matrix" {
    const Beh = http.Client.Request.RedirectBehavior;
    try std.testing.expect(redirectBehaviorFor(.never, true, false) == .not_allowed);
    try std.testing.expect(redirectBehaviorFor(.never, false, false) == .not_allowed);
    try std.testing.expect(redirectBehaviorFor(.initial, true, false) == @as(Beh, @enumFromInt(10)));
    try std.testing.expect(redirectBehaviorFor(.initial, false, false) == .not_allowed);
    try std.testing.expect(redirectBehaviorFor(.always, false, false) == @as(Beh, @enumFromInt(10)));
    try std.testing.expect(redirectBehaviorFor(.always, true, true) == .unhandled);
    try std.testing.expect(redirectBehaviorFor(.initial, true, true) == .unhandled);
}

test "mapTooManyRedirects distinguishes policy block vs hop limit" {
    try std.testing.expect(mapTooManyRedirects(.not_allowed) == Error.RedirectBlocked);
    try std.testing.expect(mapTooManyRedirects(@enumFromInt(10)) == Error.TooManyRedirects);
    try std.testing.expect(mapTooManyRedirects(@enumFromInt(1)) == Error.TooManyRedirects);
}

test "usesInsecureTlsPath branch selection" {
    try std.testing.expect(!usesInsecureTlsPath(false, "https://example.com/"));
    try std.testing.expect(!usesInsecureTlsPath(false, "http://example.com/"));
    try std.testing.expect(!usesInsecureTlsPath(true, "http://example.com/"));
    try std.testing.expect(!usesInsecureTlsPath(true, "HTTP://example.com/"));
    try std.testing.expect(usesInsecureTlsPath(true, "https://example.com/repo.git"));
    try std.testing.expect(usesInsecureTlsPath(true, "HTTPS://example.com/repo.git"));
    try std.testing.expect(usesInsecureTlsPath(true, "https://127.0.0.1:1/"));
    try std.testing.expect(!usesInsecureTlsPath(true, "not-a-url"));
}

test "insecure_skip_tls flag on OsRoundTripper" {
    const gpa = std.testing.allocator;
    var os_rt = OsRoundTripper.init(gpa, std.testing.io);
    defer os_rt.deinit();
    try std.testing.expect(!os_rt.insecure_skip_tls);
    os_rt.insecure_skip_tls = true;
    try std.testing.expect(os_rt.insecure_skip_tls);
    try std.testing.expect(usesInsecureTlsPath(os_rt.insecure_skip_tls, "https://x/"));
}

test "roundTripInsecureHttps reaches TCP connect" {
    const gpa = std.testing.allocator;
    var os_rt = OsRoundTripper.init(gpa, std.testing.io);
    defer os_rt.deinit();
    os_rt.insecure_skip_tls = true;

    var req = Request{
        .allocator = gpa,
        .method = "GET",
        .url = try gpa.dupe(u8, "https://127.0.0.1:1/"),
        .headers = HeaderMap.init(gpa),
        .body = "",
    };
    defer req.deinit();

    const result = os_rt.roundTripInsecureHttps(&req);
    try std.testing.expect(std.meta.isError(result));
}

test "roundTrip selects insecure path for https+skip" {
    const gpa = std.testing.allocator;
    var os_rt = OsRoundTripper.init(gpa, std.testing.io);
    defer os_rt.deinit();
    os_rt.insecure_skip_tls = true;

    var req = Request{
        .allocator = gpa,
        .method = "POST",
        .url = try gpa.dupe(u8, "https://127.0.0.1:1/git-upload-pack"),
        .headers = HeaderMap.init(gpa),
        .body = "0000",
    };
    defer req.deinit();
    try req.headers.set("Content-Type", "application/x-git-upload-pack-request");

    const result = os_rt.roundTrip(&req);
    try std.testing.expect(std.meta.isError(result));
}

test "roundTrip http+insecure still uses verified client path" {
    const gpa = std.testing.allocator;
    var os_rt = OsRoundTripper.init(gpa, std.testing.io);
    defer os_rt.deinit();
    os_rt.insecure_skip_tls = true;
    try std.testing.expect(!usesInsecureTlsPath(true, "http://127.0.0.1:1/"));

    var req = Request{
        .allocator = gpa,
        .method = "GET",
        .url = try gpa.dupe(u8, "http://127.0.0.1:1/"),
        .headers = HeaderMap.init(gpa),
    };
    defer req.deinit();

    const result = os_rt.roundTrip(&req);
    try std.testing.expect(std.meta.isError(result));
}

test "writeInsecureHttpRequest formats GET and POST" {
    const gpa = std.testing.allocator;

    {
        var req = Request{
            .allocator = gpa,
            .method = "GET",
            .url = try gpa.dupe(u8, "https://example.com/r.git/info/refs?service=git-upload-pack"),
            .headers = HeaderMap.init(gpa),
        };
        defer req.deinit();
        try req.headers.set("Authorization", "Basic dXNlcjpwYXNz");

        const uri = try std.Uri.parse(req.url);
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try writeInsecureHttpRequest(&aw.writer, req.method, &uri, req.body, &req.headers, false);
        const out = aw.written();
        try std.testing.expect(std.mem.startsWith(u8, out, "GET /r.git/info/refs?service=git-upload-pack HTTP/1.1\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, out, "host: example.com\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "Authorization: Basic dXNlcjpwYXNz\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "connection: close\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "content-length:") == null);
        try std.testing.expect(std.mem.endsWith(u8, out, "\r\n\r\n"));
    }

    {
        var req = Request{
            .allocator = gpa,
            .method = "POST",
            .url = try gpa.dupe(u8, "https://example.com:8443/r.git/git-upload-pack"),
            .headers = HeaderMap.init(gpa),
            .body = "pack-body",
        };
        defer req.deinit();
        try req.headers.set("Content-Type", "application/x-git-upload-pack-request");

        const uri = try std.Uri.parse(req.url);
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try writeInsecureHttpRequest(&aw.writer, req.method, &uri, req.body, &req.headers, false);
        const out = aw.written();
        try std.testing.expect(std.mem.startsWith(u8, out, "POST /r.git/git-upload-pack HTTP/1.1\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, out, "host: example.com:8443\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "content-length: 9\r\n") != null);
        try std.testing.expect(std.mem.endsWith(u8, out, "\r\n\r\npack-body"));
    }

    {
        // drop_auth strips Authorization on cross-host redirect hops.
        var req = Request{
            .allocator = gpa,
            .method = "GET",
            .url = try gpa.dupe(u8, "https://example.com/x"),
            .headers = HeaderMap.init(gpa),
        };
        defer req.deinit();
        try req.headers.set("Authorization", "Basic dXNlcjpwYXNz");
        const uri = try std.Uri.parse(req.url);
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try writeInsecureHttpRequest(&aw.writer, req.method, &uri, "", &req.headers, true);
        const out = aw.written();
        try std.testing.expect(std.mem.indexOf(u8, out, "Authorization:") == null);
    }
}

test "shouldDropAuthOnRedirect host matrix" {
    try std.testing.expect(!shouldDropAuthOnRedirect(
        "https://example.com/a",
        "https://example.com/b",
    ));
    try std.testing.expect(!shouldDropAuthOnRedirect(
        "https://example.com/a",
        "https://cdn.example.com/b",
    ));
    try std.testing.expect(shouldDropAuthOnRedirect(
        "https://example.com/a",
        "https://other.com/b",
    ));
    try std.testing.expect(shouldDropAuthOnRedirect(
        "http://example.com/a",
        "https://example.com/a",
    ));
}

test "redirectForcesGet status matrix" {
    try std.testing.expect(redirectForcesGet(.moved_permanently));
    try std.testing.expect(redirectForcesGet(.found));
    try std.testing.expect(redirectForcesGet(.see_other));
    try std.testing.expect(!redirectForcesGet(.temporary_redirect));
    try std.testing.expect(!redirectForcesGet(.permanent_redirect));
    try std.testing.expect(!redirectForcesGet(.ok));
}

test "headerMapFromHeadBytes copies all headers including multi-value" {
    const gpa = std.testing.allocator;
    const head_bytes =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/x-git-upload-pack-result\r\n" ++
        "Content-Length: 4\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Set-Cookie: a=1\r\n" ++
        "Set-Cookie: b=2\r\n" ++
        "X-Git-Protocol: version=2\r\n" ++
        "\r\n";

    var map = try headerMapFromHeadBytes(gpa, head_bytes);
    defer map.deinit();

    try std.testing.expectEqual(@as(usize, 6), map.entries.items.len);
    try std.testing.expectEqualStrings(
        "application/x-git-upload-pack-result",
        map.get("Content-Type").?,
    );
    try std.testing.expectEqualStrings("4", map.get("Content-Length").?);
    try std.testing.expectEqualStrings("no-cache", map.get("Cache-Control").?);
    try std.testing.expectEqualStrings("version=2", map.get("X-Git-Protocol").?);
    // get returns the last same-name value; both Set-Cookie entries are stored.
    try std.testing.expectEqualStrings("b=2", map.get("Set-Cookie").?);
    var set_cookie_count: usize = 0;
    for (map.entries.items) |e| {
        if (std.ascii.eqlIgnoreCase(e.name, "Set-Cookie")) set_cookie_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), set_cookie_count);
    try std.testing.expectEqualStrings("a=1", map.entries.items[3].value);
    try std.testing.expectEqualStrings("b=2", map.entries.items[4].value);
}

test "headerMapFromHeadBytes preserves name casing and trims values" {
    const gpa = std.testing.allocator;
    const head_bytes =
        "HTTP/1.1 302 Found\r\n" ++
        "LOcation:  /next  \r\n" ++
        "content-tYpe:\ttext/plain\r\n" ++
        "\r\n";

    var map = try headerMapFromHeadBytes(gpa, head_bytes);
    defer map.deinit();

    try std.testing.expectEqual(@as(usize, 2), map.entries.items.len);
    try std.testing.expectEqualStrings("LOcation", map.entries.items[0].name);
    try std.testing.expectEqualStrings("/next", map.entries.items[0].value);
    try std.testing.expectEqualStrings("content-tYpe", map.entries.items[1].name);
    try std.testing.expectEqualStrings("text/plain", map.entries.items[1].value);
    // Case-insensitive lookup still works.
    try std.testing.expectEqualStrings("/next", map.get("location").?);
    try std.testing.expectEqualStrings("text/plain", map.get("CONTENT-TYPE").?);
}

test "headerMapFromHeadBytes empty header section" {
    const gpa = std.testing.allocator;
    const head_bytes = "HTTP/1.1 204 No Content\r\n\r\n";
    var map = try headerMapFromHeadBytes(gpa, head_bytes);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 0), map.entries.items.len);
}

test "headerMapFromHeadBytes rejects invalid head" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.HttpHeadersInvalid,
        headerMapFromHeadBytes(gpa, "not-http"),
    );
    try std.testing.expectError(
        error.HttpHeadersInvalid,
        headerMapFromHeadBytes(gpa, "HTTP/1.1 200 OK\r\n: empty-name\r\n\r\n"),
    );
}

test "copyHeadHeaders skips trailers after blank line" {
    const gpa = std.testing.allocator;
    // HeaderIterator can surface trailers after the blank line; response HeaderMap
    // must only include the head section (go-git / net/http Header, not Trailer).
    const head_bytes =
        "HTTP/1.1 200 OK\r\n" ++
        "X-Head: one\r\n" ++
        "\r\n" ++
        "X-Trailer: two\r\n" ++
        "\r\n";
    var map = try headerMapFromHeadBytes(gpa, head_bytes);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 1), map.entries.items.len);
    try std.testing.expectEqualStrings("one", map.get("X-Head").?);
    try std.testing.expect(map.get("X-Trailer") == null);
}

test "InsecureHop transfers headers ownership" {
    const gpa = std.testing.allocator;
    var hop_headers = HeaderMap.init(gpa);
    try hop_headers.add("Location", "https://example.com/b");
    try hop_headers.add("Content-Type", "text/plain");

    var hop = InsecureHop{
        .status = .found,
        .body = try gpa.dupe(u8, "moved"),
        .headers = hop_headers,
    };

    const body = hop.takeBody();
    defer gpa.free(body);
    try std.testing.expectEqualStrings("moved", body);

    var headers = hop.takeHeaders();
    defer headers.deinit();
    try std.testing.expectEqualStrings("https://example.com/b", headers.get("Location").?);
    try std.testing.expectEqualStrings("text/plain", headers.get("Content-Type").?);

    // Leftover hop state is empty after take*; deinit must not free transferred data.
    hop.deinit(gpa);
    try std.testing.expectEqualStrings("https://example.com/b", headers.get("Location").?);
}

test "configure applies proxy to std.http.Client fields" {
    const gpa = std.testing.allocator;
    var os_rt = OsRoundTripper.init(gpa, std.testing.io);
    defer os_rt.deinit();
    try os_rt.configure(.{
        .proxy = .{
            .url = "http://proxy.example.com:8080",
            .username = "user",
            .password = "pass",
        },
    });
    try std.testing.expect(os_rt.client.http_proxy != null);
    try std.testing.expect(os_rt.client.https_proxy != null);
    try std.testing.expect(os_rt.client.http_proxy == os_rt.client.https_proxy);
    try std.testing.expectEqualStrings("proxy.example.com", os_rt.client.http_proxy.?.host.bytes);
    try std.testing.expectEqual(@as(u16, 8080), os_rt.client.http_proxy.?.port);
    try std.testing.expect(os_rt.client.http_proxy.?.protocol == .plain);
    try std.testing.expect(os_rt.client.http_proxy.?.supports_connect);
    try std.testing.expect(os_rt.client.http_proxy.?.authorization != null);
    try std.testing.expect(std.mem.startsWith(u8, os_rt.client.http_proxy.?.authorization.?, "Basic "));
}

test "configure invalid proxy URL fails" {
    const gpa = std.testing.allocator;
    var os_rt = OsRoundTripper.init(gpa, std.testing.io);
    defer os_rt.deinit();
    try std.testing.expectError(error.InvalidProxyURL, os_rt.configure(.{
        .proxy = .{ .url = "://not-a-url" },
    }));
}

test "buildHttpProxy parses host port scheme" {
    const gpa = std.testing.allocator;
    const built = try buildHttpProxy(gpa, .{ .url = "http://127.0.0.1:3128" });
    defer {
        gpa.free(built.host_owned);
        if (built.auth_owned) |a| gpa.free(a);
    }
    try std.testing.expectEqualStrings("127.0.0.1", built.proxy.host.bytes);
    try std.testing.expectEqual(@as(u16, 3128), built.proxy.port);
    try std.testing.expect(built.proxy.authorization == null);
}

test "addCertsFromPemBytes rejects garbage" {
    const gpa = std.testing.allocator;
    var bundle: Certificate.Bundle = .empty;
    defer bundle.deinit(gpa);
    try std.testing.expectError(
        error.CertificateBundleLoadFailure,
        addCertsFromPemBytes(&bundle, gpa, "not-a-pem", 0),
    );
}

test "configure CA load failure surfaces" {
    const gpa = std.testing.allocator;
    var os_rt = OsRoundTripper.init(gpa, std.testing.io);
    defer os_rt.deinit();
    try std.testing.expectError(error.CertificateBundleLoadFailure, os_rt.configure(.{
        .ca_bundle = "not-pem-data",
    }));
}

test "validateClientCertConfig pairing" {
    try validateClientCertConfig("", "");
    try std.testing.expectError(error.ClientCertificateConfigInvalid, validateClientCertConfig("x", ""));
    try std.testing.expectError(error.ClientCertificateConfigInvalid, validateClientCertConfig("", "y"));
    try std.testing.expectError(error.ClientCertificateConfigInvalid, validateClientCertConfig("nocerts", "nokeys"));
    try validateClientCertConfig(
        "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n",
        "-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----\n",
    );
}

test "client cert blocks HTTPS roundTrip with clear error" {
    const gpa = std.testing.allocator;
    var os_rt = OsRoundTripper.init(gpa, std.testing.io);
    defer os_rt.deinit();
    try os_rt.configure(.{
        .client_cert = "-----BEGIN CERTIFICATE-----\nx\n-----END CERTIFICATE-----\n",
        .client_key = "-----BEGIN PRIVATE KEY-----\ny\n-----END PRIVATE KEY-----\n",
    });
    var req = Request{
        .allocator = gpa,
        .method = "GET",
        .url = try gpa.dupe(u8, "https://127.0.0.1:1/"),
        .headers = HeaderMap.init(gpa),
    };
    defer req.deinit();
    try std.testing.expectError(error.ClientCertificateUnsupported, os_rt.roundTrip(&req));
}

test "client certificate capability names the Zig 0.16 TLS limitation" {
    try std.testing.expectEqual(
        ClientCertificateCapability.unsupported_zig_0_16_std_tls,
        clientCertificateCapability(),
    );
    try std.testing.expect(!@hasField(std.crypto.tls.Client.Options, "client_certificate"));
    try std.testing.expect(!@hasField(std.crypto.tls.Client.Options, "client_private_key"));
}

test "connectStatusOk accepts 200" {
    try std.testing.expect(connectStatusOk("HTTP/1.1 200 Connection Established"));
    try std.testing.expect(connectStatusOk("HTTP/1.0 200 OK"));
    try std.testing.expect(!connectStatusOk("HTTP/1.1 403 Forbidden"));
    try std.testing.expect(!connectStatusOk(""));
}
