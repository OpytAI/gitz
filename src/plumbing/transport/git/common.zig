//! git:// TCP transport (go-git `plumbing/transport/git/common.go`).
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `DefaultClient` | `defaultClient` / `newClient` over `Runner` |
//! | `DefaultPort` | `DefaultPort` |
//! | `runner.Command` | `Runner.command` |
//! | `command.Start` | `GitCommand.start` (encodes `GitProtoRequest`) |
//! | `net.Dial("tcp", …)` | `DialFn` / `defaultDial` (injectable) |
//!
//! Production dial: `defaultDial` resolves IPv4/IPv6 literals via
//! `IpAddress.parse`, else `HostName.connect`. Bracketed IPv6 hosts (`[::1]`)
//! are stripped for connect. Unit tests inject `BufferConn.dialFn` — no network.

const std = @import("std");
const transport = @import("transport");
const packp = @import("packp");
const transport_common = @import("transport_common");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Endpoint = transport.Endpoint;
const AuthMethod = transport.AuthMethod;
const Commander = transport_common.Commander;
const Command = transport_common.Command;
const WriteCloser = transport_common.WriteCloser;
pub const Client = transport_common.Client;

const IpAddress = std.Io.net.IpAddress;
const HostName = std.Io.net.HostName;
const Stream = std.Io.net.Stream;

/// go-git `DefaultPort` (git daemon TCP port).
pub const DefaultPort: i32 = 9418;

// ---------------------------------------------------------------------------
// Conn — abstract duplex (go-git `net.Conn`)
// ---------------------------------------------------------------------------

/// Reader/writer pair used by a git:// command (go-git `net.Conn` analogue).
///
/// Produced by `DialFn`. `close` releases connection resources exactly once
/// from the caller's side (`GitCommand.close` nulls `conn` first).
pub const Conn = struct {
    ptr: *anyopaque,
    reader: *Reader,
    writer: *Writer,
    close_fn: *const fn (ptr: *anyopaque) anyerror!void,

    pub fn close(self: Conn) anyerror!void {
        return self.close_fn(self.ptr);
    }
};

/// TCP connect hook (go-git `net.Dial`). Inject a mock for hermetic tests.
pub const DialFn = *const fn (
    ctx: ?*anyopaque,
    allocator: Allocator,
    io: Io,
    host: []const u8,
    port: u16,
) anyerror!Conn;

// ---------------------------------------------------------------------------
// BufferConn — in-memory duplex for unit tests (no network)
// ---------------------------------------------------------------------------

/// Captures writes and serves a fixed read buffer (test double for `net.Conn`).
///
/// Set `read_data` before dial to feed a canned advertise / pack stream.
/// `written()` includes the `GitProtoRequest` bytes from `Start`.
pub const BufferConn = struct {
    allocator: Allocator,
    write_alloc: Writer.Allocating,
    read_data: []const u8 = "",
    reader: Reader = undefined,
    closed: bool = false,
    /// Last host:port seen by the mock dial (test inspection).
    dial_host: []const u8 = "",
    dial_port: u16 = 0,
    dial_host_owned: ?[]u8 = null,

    pub fn init(allocator: Allocator) BufferConn {
        return .{
            .allocator = allocator,
            .write_alloc = Writer.Allocating.init(allocator),
        };
    }

    pub fn deinit(self: *BufferConn) void {
        self.write_alloc.deinit();
        if (self.dial_host_owned) |h| self.allocator.free(h);
        self.* = undefined;
    }

    /// Bytes written by the peer (includes GitProtoRequest from `Start`).
    pub fn written(self: *BufferConn) []const u8 {
        return self.write_alloc.written();
    }

    pub fn asConn(self: *BufferConn) Conn {
        self.reader = Reader.fixed(self.read_data);
        return .{
            .ptr = self,
            .reader = &self.reader,
            .writer = &self.write_alloc.writer,
            .close_fn = closeFn,
        };
    }

    fn closeFn(ptr: *anyopaque) anyerror!void {
        const self: *BufferConn = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }

    /// DialFn that returns this BufferConn (store `self` as dial ctx).
    pub fn dialFn(
        ctx: ?*anyopaque,
        allocator: Allocator,
        io: Io,
        host: []const u8,
        port: u16,
    ) anyerror!Conn {
        _ = io;
        const self: *BufferConn = @ptrCast(@alignCast(ctx.?));
        if (self.closed) return error.ConnectionClosed;
        if (self.dial_host_owned) |h| allocator.free(h);
        self.dial_host_owned = try allocator.dupe(u8, host);
        self.dial_host = self.dial_host_owned.?;
        self.dial_port = port;
        return self.asConn();
    }
};

// ---------------------------------------------------------------------------
// Default TCP dial (production)
// ---------------------------------------------------------------------------

/// Heap state for one TCP connection. Destroyed exactly once in `closeFn`.
const TcpConnState = struct {
    allocator: Allocator,
    io: Io,
    stream: Stream = undefined,
    stream_open: bool = false,
    reader_impl: Stream.Reader = undefined,
    writer_impl: Stream.Writer = undefined,
    read_buf: [8192]u8 = undefined,
    write_buf: [8192]u8 = undefined,

    fn asConn(self: *TcpConnState) Conn {
        return .{
            .ptr = self,
            .reader = &self.reader_impl.interface,
            .writer = &self.writer_impl.interface,
            .close_fn = closeFn,
        };
    }

    fn closeFn(ptr: *anyopaque) anyerror!void {
        const self: *TcpConnState = @ptrCast(@alignCast(ptr));
        // Always free the heap object; close the stream at most once.
        const a = self.allocator;
        if (self.stream_open) {
            self.stream_open = false;
            self.stream.close(self.io);
        }
        a.destroy(self);
    }
};

/// Real TCP dial (go-git `net.Dial("tcp", host:port)`).
///
/// - Literal IPv4 / IPv6 → `IpAddress.parse` + `connect`
/// - Host name → `HostName.init` + `connect`
/// - Bracketed IPv6 (`[::1]`) → strip brackets before parse/connect
/// - On success, returned `Conn.close` closes the stream and frees state
/// - On failure after connect, stream is closed and state freed (no leak)
pub fn defaultDial(
    ctx: ?*anyopaque,
    allocator: Allocator,
    io: Io,
    host: []const u8,
    port: u16,
) anyerror!Conn {
    _ = ctx;
    const tc = try allocator.create(TcpConnState);
    errdefer allocator.destroy(tc);
    tc.* = .{ .allocator = allocator, .io = io };

    // Endpoints may store IPv6 with brackets (`[::1]`); strip for parse/connect.
    const bare = bareHost(host);

    if (IpAddress.parse(bare, port)) |addr| {
        var a = addr;
        tc.stream = try a.connect(io, .{ .mode = .stream });
    } else |_| {
        const hn = try HostName.init(bare);
        tc.stream = try hn.connect(io, port, .{ .mode = .stream });
    }
    tc.stream_open = true;
    // If reader/writer setup ever gains fallible steps, close the stream first.
    errdefer {
        tc.stream_open = false;
        tc.stream.close(io);
    }

    tc.reader_impl = tc.stream.reader(io, &tc.read_buf);
    tc.writer_impl = tc.stream.writer(io, &tc.write_buf);
    return tc.asConn();
}

/// Strip surrounding `[]` from an IPv6 host literal (endpoint / URL form).
pub fn bareHost(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        return host[1 .. host.len - 1];
    }
    return host;
}

// ---------------------------------------------------------------------------
// Runner (go-git `runner`)
// ---------------------------------------------------------------------------

/// Creates git:// commands (go-git `runner` implementing `Commander`).
///
/// Owns heap `GitCommand` values until `deinit` (same pattern as `MockCommander`).
pub const Runner = struct {
    allocator: Allocator,
    io: Io,
    dial_fn: DialFn = defaultDial,
    dial_ctx: ?*anyopaque = null,
    owned: std.ArrayListUnmanaged(*GitCommand) = .empty,

    pub fn init(allocator: Allocator, io: Io) Runner {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Runner) void {
        for (self.owned.items) |c| {
            c.release();
            self.allocator.destroy(c);
        }
        self.owned.deinit(self.allocator);
        self.* = undefined;
    }

    /// Install a dial hook (e.g. `BufferConn.dialFn`) for hermetic tests.
    pub fn setDial(self: *Runner, ctx: ?*anyopaque, dial_fn: DialFn) void {
        self.dial_ctx = ctx;
        self.dial_fn = dial_fn;
    }

    pub fn asCommander(self: *Runner) Commander {
        return Commander.from(Runner, self);
    }

    /// go-git `(*runner).Command`.
    ///
    /// Connects at create time (go-git). Auth is rejected. On dial failure the
    /// command is not retained. On append failure the connection is released.
    pub fn command(
        self: *Runner,
        cmd: []const u8,
        ep: *const Endpoint,
        auth: ?AuthMethod,
    ) anyerror!Command {
        // Auth not allowed — git protocol has no authentication.
        if (auth != null) return transport.Error.InvalidAuthMethod;
        if (!std.mem.eql(u8, cmd, transport.UploadPackServiceName) and
            !std.mem.eql(u8, cmd, transport.ReceivePackServiceName))
            return transport.Error.InvalidEndpoint;
        if (std.mem.indexOfScalar(u8, ep.path, 0) != null or
            std.mem.indexOfScalar(u8, ep.host, 0) != null)
            return transport.Error.InvalidEndpoint;

        const c = try self.allocator.create(GitCommand);
        errdefer self.allocator.destroy(c);
        c.* = GitCommand.init(self.allocator, cmd, ep);
        try c.connect(self);
        errdefer c.release();
        try self.owned.append(self.allocator, c);
        return c.asCommand();
    }
};

/// go-git `DefaultClient = common.NewClient(&runner{})`.
///
/// `runner` must outlive the returned client (Commander holds a pointer).
pub fn defaultClient(allocator: Allocator, runner: *Runner) Client {
    return transport_common.newClient(allocator, runner.asCommander());
}

/// Alias matching go-git `common.NewClient` usage for this transport.
pub const newClient = defaultClient;

// ---------------------------------------------------------------------------
// GitCommand (go-git `command`)
// ---------------------------------------------------------------------------

/// Single git:// command over one TCP (or mock) connection.
///
/// Heap-owned by `Runner` (freed in `Runner.deinit`). `close` only drops the
/// connection — safe to call more than once. Stdin close is a no-op (go-git
/// `WriteNopCloser`); only `close`/`kill` tear down TCP.
pub const GitCommand = struct {
    allocator: Allocator,
    command_name: []const u8,
    endpoint: *const Endpoint,
    conn: ?Conn = null,
    connected: bool = false,
    /// Owned host string when Start formats `host:port` for GitProtoRequest.
    host_owned: ?[]u8 = null,

    pub fn init(allocator: Allocator, command_name: []const u8, endpoint: *const Endpoint) GitCommand {
        return .{
            .allocator = allocator,
            .command_name = command_name,
            .endpoint = endpoint,
        };
    }

    fn connect(self: *GitCommand, runner: *Runner) !void {
        if (self.connected) return transport.Error.AlreadyConnected;
        const port = try connectPort(self.endpoint);
        const host = self.endpoint.host;
        // Dial owns the Conn until close/release. On dial error, no state kept.
        self.conn = try runner.dial_fn(runner.dial_ctx, self.allocator, runner.io, host, port);
        self.connected = true;
    }

    /// go-git `(*command).Start` — encode `GitProtoRequest` on the connection.
    ///
    /// Wire form: one pkt-line `command pathname\0host=host\0` (see packp).
    /// Flushes after encode so the daemon sees the request immediately.
    pub fn start(self: *GitCommand) anyerror!void {
        const conn = self.conn orelse return error.NotConnected;

        var req = packp.GitProtoRequest.init(self.allocator);
        defer req.deinit();
        req.request_command = self.command_name;
        req.pathname = self.endpoint.path;
        req.host = try self.protoHost();

        try req.encode(conn.writer);
        try conn.writer.flush();
    }

    /// Host field for GitProtoRequest (go-git `Start` host logic).
    ///
    /// When `endpoint.port != DefaultPort`, formats `host:port` (Go `net.JoinHostPort`).
    /// When equal to `DefaultPort`, uses bare host. Port `0` is not default → `host:0`.
    /// Endpoint hosts may already be bracketed IPv6; `joinHostPort` does not double-wrap.
    pub fn protoHost(self: *GitCommand) Allocator.Error![]const u8 {
        if (self.endpoint.port != DefaultPort) {
            if (self.host_owned) |h| self.allocator.free(h);
            self.host_owned = try joinHostPort(self.allocator, self.endpoint.host, self.endpoint.port);
            return self.host_owned.?;
        }
        return self.endpoint.host;
    }

    /// go-git `StderrPipe` — no dedicated error channel (returns error; session treats as null).
    pub fn stderrPipe(self: *GitCommand) anyerror!*Reader {
        _ = self;
        return error.NoStderrChannel;
    }

    /// go-git `StdinPipe` — write side with nop close (must not close TCP).
    pub fn stdinPipe(self: *GitCommand) anyerror!WriteCloser {
        const conn = self.conn orelse return error.NotConnected;
        return .{
            .ptr = self,
            .writer = conn.writer,
            .close_fn = nopClose,
        };
    }

    /// go-git `StdoutPipe` — read side of the connection.
    pub fn stdoutPipe(self: *GitCommand) anyerror!*Reader {
        const conn = self.conn orelse return error.NotConnected;
        return conn.reader;
    }

    /// go-git `Close` — close TCP connection (idempotent).
    ///
    /// Nulls `conn` before calling `Conn.close` so a failing close cannot double-free.
    pub fn close(self: *GitCommand) anyerror!void {
        if (!self.connected) return;
        self.connected = false;
        if (self.conn) |c| {
            self.conn = null;
            try c.close();
        }
    }

    /// go-git `CommandKiller.Kill` — same as close for TCP.
    pub fn kill(self: *GitCommand) anyerror!void {
        return self.close();
    }

    /// Free owned strings and drop any open connection (Runner.deinit).
    fn release(self: *GitCommand) void {
        self.close() catch {};
        if (self.host_owned) |h| {
            self.allocator.free(h);
            self.host_owned = null;
        }
    }

    pub fn asCommand(self: *GitCommand) Command {
        return Command.from(GitCommand, self);
    }
};

fn nopClose(_: *anyopaque) anyerror!void {}

/// Port used for TCP dial (go-git `getHostWithPort` port half).
pub fn connectPort(ep: *const Endpoint) transport.Error!u16 {
    if (ep.port <= 0) return @intCast(DefaultPort);
    if (ep.port > std.math.maxInt(u16)) return transport.Error.InvalidEndpoint;
    return @intCast(ep.port);
}

/// Go `net.JoinHostPort` for dial/GitProtoRequest host fields.
///
/// If `host` is an unbracketed IPv6 literal (contains `:`), wrap in `[]`.
/// If already bracketed (`[::1]`), do not double-wrap (gitz endpoints keep brackets).
pub fn joinHostPort(allocator: Allocator, host: []const u8, port: i32) Allocator.Error![]u8 {
    const bare = bareHost(host);
    if (std.mem.indexOfScalar(u8, bare, ':') != null) {
        return try std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ bare, port });
    }
    return try std.fmt.allocPrint(allocator, "{s}:{d}", .{ bare, port });
}

/// Build GitProtoRequest host string without allocating a command
/// (same rules as `GitCommand.protoHost` / go-git `Start`).
pub fn requestHost(allocator: Allocator, ep: *const Endpoint) Allocator.Error![]u8 {
    if (ep.port != DefaultPort) {
        return joinHostPort(allocator, ep.host, ep.port);
    }
    return try allocator.dupe(u8, ep.host);
}
