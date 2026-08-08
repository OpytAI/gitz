//! OS HTTP RoundTripper backed by Zig 0.16 `std.http.Client` (secure path)
//! and an intentional insecure HTTPS path using `std.crypto.tls.Client`.
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
//! Redirect policy is applied here (go-git `CheckRedirect` on `http.Client`):
//! - `never` — do not follow; first 3xx surfaces as `Error.RedirectBlocked`
//! - `initial` — follow only when `Request.is_initial` (info/refs GET)
//! - `always` — follow GETs up to 10 hops; POST bodies stay unhandled
//!
//! After auto-followed redirects, `Response.final_url` is the final request
//! URI (no userinfo) so `Session.modifyEndpointIfRedirect` can rewrite the
//! endpoint like go-git `res.Request.URL`.
//!
//! # TLS / `insecure_skip_tls`
//!
//! When `insecure_skip_tls` is false, requests use `std.http.Client`, which
//! verifies server certificates against the system CA bundle (secure default).
//!
//! When `insecure_skip_tls` is true **and** the URL scheme is `https://`, this
//! type takes a dedicated path that is a full intentional implementation:
//! 1. TCP connect via `HostName.connect`
//! 2. TLS handshake with `std.crypto.tls.Client` options
//!    `host: .no_verification` and `ca: .no_verification`
//! 3. HTTP/1.1 request/response over the TLS stream
//!
//! Redirects are not auto-followed on the insecure path; `final_url` is the
//! request URL. Plain `http://` with the flag set still uses `std.http.Client`
//! (no TLS to skip).
//!
//! This is the Zig equivalent of go-git / `InsecureSkipVerify`: verification
//! is intentionally disabled. Prefer injecting a custom RoundTripper for
//! custom trust stores rather than broad skip-verify when possible.

const std = @import("std");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const http = std.http;
const HostName = std.Io.net.HostName;
const TlsClient = std.crypto.tls.Client;

const Request = common.Request;
const Response = common.Response;
const HeaderMap = common.HeaderMap;
const RoundTripper = common.RoundTripper;
const RedirectPolicy = common.RedirectPolicy;
const Error = common.Error;

/// Real OS sockets RoundTripper using `std.http.Client` (verified TLS) and an
/// optional insecure HTTPS path when `insecure_skip_tls` is set.
pub const OsRoundTripper = struct {
    allocator: Allocator,
    /// Borrowed Io handle. For the default Client path this is a process
    /// threadlocal single-threaded `std.Io.Threaded`; keep Client use and
    /// deinit on the same thread that constructed it.
    io: std.Io,
    client: http.Client,
    /// Mirrored from `Client.follow` / session options.
    redirect_policy: RedirectPolicy = .initial,
    /// When true, HTTPS trips use `tls.Client` with no host/CA verification.
    /// Wired from `ClientOptions` / `Endpoint` via `Client.newSession`.
    insecure_skip_tls: bool = false,

    /// Create a client bound to `allocator` and `io`.
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
        self.client.deinit();
        self.* = undefined;
    }

    pub fn asRoundTripper(self: *OsRoundTripper) RoundTripper {
        return RoundTripper.from(OsRoundTripper, self);
    }

    /// Perform one HTTP request. Returns an owned `Response` (caller deinits).
    pub fn roundTrip(self: *OsRoundTripper, req: *const Request) anyerror!Response {
        if (usesInsecureTlsPath(self.insecure_skip_tls, req.url)) {
            return self.roundTripInsecureHttps(req);
        }
        return self.roundTripVerified(req);
    }

    /// Secure default path: `std.http.Client` with system CA verification.
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

        const has_payload = req.body.len > 0 or std.mem.eql(u8, req.method, "POST");
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
            try self.allocator.alloc(u8, 8 * 1024)
        else
            &.{};
        defer if (redirect_buffer.len != 0) self.allocator.free(redirect_buffer);

        var response = http_req.receiveHead(redirect_buffer) catch |err| switch (err) {
            error.TooManyHttpRedirects => return Error.RedirectBlocked,
            else => |e| return e,
        };

        // Final URI after auto-followed redirects (no userinfo).
        const final_url = try formatUriNoAuth(self.allocator, &http_req.uri);
        errdefer self.allocator.free(final_url);

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
            .headers = HeaderMap.init(self.allocator),
        };
    }

    /// Insecure HTTPS: TCP + `tls.Client` with host/CA verification disabled.
    ///
    /// Full intentional implementation (not a stub). GET and POST with body,
    /// request headers, owned status/body/`final_url` (request URL; redirects
    /// are not followed on this path).
    pub fn roundTripInsecureHttps(self: *OsRoundTripper, req: *const Request) anyerror!Response {
        const uri = try std.Uri.parse(req.url);
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.UnsupportedUriScheme;

        var host_name_buffer: [HostName.max_len]u8 = undefined;
        const host = try uri.getHost(&host_name_buffer);
        const port: u16 = uri.port orelse 443;

        var stream = try host.connect(self.io, port, .{ .mode = .stream });
        defer stream.close(self.io);

        // Buffer layout mirrors std.http.Client TLS connection sizing.
        const tls_min = TlsClient.min_buffer_len;
        const http_read_cap: usize = 8 * 1024;
        const clear_write_cap: usize = 1024;

        const socket_read_buf = try self.allocator.alloc(u8, tls_min);
        defer self.allocator.free(socket_read_buf);
        const socket_write_buf = try self.allocator.alloc(u8, tls_min);
        defer self.allocator.free(socket_write_buf);
        const tls_read_buf = try self.allocator.alloc(u8, tls_min + http_read_cap);
        defer self.allocator.free(tls_read_buf);
        const tls_write_buf = try self.allocator.alloc(u8, clear_write_cap);
        defer self.allocator.free(tls_write_buf);

        var stream_reader = stream.reader(self.io, socket_read_buf);
        var stream_writer = stream.writer(self.io, socket_write_buf);

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
                // HTTP Content-Length / chunked framing detects truncation.
                .allow_truncation_attacks = true,
            },
        );

        try writeInsecureHttpRequest(&tls.writer, req, &uri);
        try tls.writer.flush();
        try stream_writer.interface.flush();

        var http_reader: http.Reader = .{
            .in = &tls.reader,
            .interface = undefined,
            .state = .ready,
            .max_head_len = http_read_cap,
        };

        const head_buffer = try http_reader.receiveHead();
        const head = try http.Client.Response.Head.parse(head_buffer);

        var body_aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body_aw.deinit();

        const decompress_buffer: []u8 = switch (head.content_encoding) {
            .identity => &.{},
            .zstd => try self.allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try self.allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer if (decompress_buffer.len != 0) self.allocator.free(decompress_buffer);

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
        errdefer self.allocator.free(body);

        // Redirects optional under insecure; leave unhandled, report request URL.
        const final_url = try self.allocator.dupe(u8, req.url);
        errdefer self.allocator.free(final_url);

        return Response{
            .allocator = self.allocator,
            .status_code = @intFromEnum(head.status),
            .body = body,
            .final_url = final_url,
            .headers = HeaderMap.init(self.allocator),
        };
    }
};

/// True when the OS tripper should use the insecure TLS path (https + skip).
/// Exported for unit tests of branch selection.
pub fn usesInsecureTlsPath(insecure_skip_tls: bool, url: []const u8) bool {
    if (!insecure_skip_tls) return false;
    const uri = std.Uri.parse(url) catch return false;
    return std.ascii.eqlIgnoreCase(uri.scheme, "https");
}

/// Write an HTTP/1.1 request line, headers, and optional body to `w`.
fn writeInsecureHttpRequest(w: *std.Io.Writer, req: *const Request, uri: *const std.Uri) anyerror!void {
    try w.writeAll(req.method);
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
    for (req.headers.entries.items) |e| {
        if (std.ascii.eqlIgnoreCase(e.name, "Host")) continue;
        if (std.ascii.eqlIgnoreCase(e.name, "Content-Length")) continue;
        if (std.ascii.eqlIgnoreCase(e.name, "User-Agent")) saw_user_agent = true;
        try w.writeAll(e.name);
        try w.writeAll(": ");
        try w.writeAll(e.value);
        try w.writeAll("\r\n");
    }
    if (!saw_user_agent) {
        try w.writeAll("user-agent: gitz/http-insecure\r\n");
    }

    const has_payload = req.body.len > 0 or std.mem.eql(u8, req.method, "POST");
    if (has_payload) {
        try w.print("content-length: {d}\r\n", .{req.body.len});
    }

    // One-shot connection; no keep-alive on the insecure path.
    try w.writeAll("connection: close\r\n");
    try w.writeAll("\r\n");

    if (has_payload and req.body.len > 0) {
        try w.writeAll(req.body);
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
        .initial => if (is_initial) @enumFromInt(10) else .not_allowed,
        .always => @enumFromInt(10),
    };
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

    // Vtable is wired; closed port surfaces a network error (not NoRoundTripper).
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
    // Payload: never auto-follow (POST resend is not supported).
    try std.testing.expect(redirectBehaviorFor(.always, true, true) == .unhandled);
    try std.testing.expect(redirectBehaviorFor(.initial, true, true) == .unhandled);
}

test "usesInsecureTlsPath branch selection" {
    try std.testing.expect(!usesInsecureTlsPath(false, "https://example.com/"));
    try std.testing.expect(!usesInsecureTlsPath(false, "http://example.com/"));
    try std.testing.expect(!usesInsecureTlsPath(true, "http://example.com/"));
    try std.testing.expect(!usesInsecureTlsPath(true, "HTTP://example.com/"));
    try std.testing.expect(usesInsecureTlsPath(true, "https://example.com/repo.git"));
    try std.testing.expect(usesInsecureTlsPath(true, "HTTPS://example.com/repo.git"));
    try std.testing.expect(usesInsecureTlsPath(true, "https://127.0.0.1:1/"));
    // Malformed URL with flag set does not select the path.
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

test "roundTripInsecureHttps exists and reaches TCP connect" {
    // Direct call into the insecure path (no CA verify). Closed port fails at
    // connect, proving the custom path is exercised rather than std.http CA load.
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

    // Branch: https + insecure → roundTripInsecureHttps (connect refused).
    const result = os_rt.roundTrip(&req);
    try std.testing.expect(std.meta.isError(result));
}

test "roundTrip http+insecure still uses verified client path" {
    // http:// with skip flag must not take the TLS insecure path.
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
        try writeInsecureHttpRequest(&aw.writer, &req, &uri);
        const out = aw.written();
        try std.testing.expect(std.mem.startsWith(u8, out, "GET /r.git/info/refs?service=git-upload-pack HTTP/1.1\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, out, "host: example.com\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "Authorization: Basic dXNlcjpwYXNz\r\n") != null);
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
        try writeInsecureHttpRequest(&aw.writer, &req, &uri);
        const out = aw.written();
        try std.testing.expect(std.mem.startsWith(u8, out, "POST /r.git/git-upload-pack HTTP/1.1\r\n"));
        try std.testing.expect(std.mem.indexOf(u8, out, "host: example.com:8443\r\n") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "content-length: 9\r\n") != null);
        try std.testing.expect(std.mem.endsWith(u8, out, "\r\n\r\npack-body"));
    }
}
