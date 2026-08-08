//! git:// TCP transport (go-git `plumbing/transport/git/common.go`).
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `DefaultClient` | `defaultClient` / `newClient` over `Runner` |
//! | `DefaultPort` | `DefaultPort` |
//! | `runner.Command` | `Runner.command` |
//! | `command.Start` | `GitCommand.start` (encodes `GitProtoRequest`) |
//! | `net.Dial("tcp", …)` | `DialFn` (default TCP; injectable for tests) |

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
const Client = transport_common.Client;

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
/// Produced by `DialFn`. `close` releases connection resources.
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

const TcpConnState = struct {
    allocator: Allocator,
    io: Io,
    stream: Stream = undefined,
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
        self.stream.close(self.io);
        const a = self.allocator;
        a.destroy(self);
    }
};

/// Real TCP dial (go-git `net.Dial("tcp", host:port)`).
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

    tc.reader_impl = tc.stream.reader(io, &tc.read_buf);
    tc.writer_impl = tc.stream.writer(io, &tc.write_buf);
    return tc.asConn();
}

fn bareHost(host: []const u8) []const u8 {
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
    pub fn command(
        self: *Runner,
        cmd: []const u8,
        ep: *const Endpoint,
        auth: ?AuthMethod,
    ) anyerror!Command {
        // Auth not allowed — git protocol has no authentication.
        if (auth != null) return error.InvalidAuthMethod;

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
/// connection — safe to call more than once.
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
        if (self.connected) return error.AlreadyConnected;
        const port = connectPort(self.endpoint);
        const host = self.endpoint.host;
        self.conn = try runner.dial_fn(runner.dial_ctx, self.allocator, runner.io, host, port);
        self.connected = true;
    }

    /// go-git `(*command).Start` — encode `GitProtoRequest` on the connection.
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
    pub fn protoHost(self: *GitCommand) Allocator.Error![]const u8 {
        if (self.endpoint.port != DefaultPort) {
            if (self.host_owned) |h| self.allocator.free(h);
            self.host_owned = try joinHostPort(self.allocator, self.endpoint.host, self.endpoint.port);
            return self.host_owned.?;
        }
        return self.endpoint.host;
    }

    /// go-git `StderrPipe` — no dedicated error channel.
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
pub fn connectPort(ep: *const Endpoint) u16 {
    if (ep.port <= 0) return @intCast(DefaultPort);
    return @intCast(ep.port);
}

/// go-git / Go `net.JoinHostPort`.
pub fn joinHostPort(allocator: Allocator, host: []const u8, port: i32) Allocator.Error![]u8 {
    // Go: if host contains ':', wrap in brackets (even if already bracketed).
    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        return try std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ host, port });
    }
    return try std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, port });
}

/// Build GitProtoRequest host string without allocating a command
/// (same rules as `GitCommand.protoHost` / go-git `Start`).
pub fn requestHost(allocator: Allocator, ep: *const Endpoint) Allocator.Error![]u8 {
    if (ep.port != DefaultPort) {
        return joinHostPort(allocator, ep.host, ep.port);
    }
    return try allocator.dupe(u8, ep.host);
}
