//! Pluggable pack-protocol client over Command pipes
//! (go-git `plumbing/transport/internal/common/common.go`).
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `Commander` / `Command` / `CommandKiller` | vtables below |
//! | `NewClient` | `newClient` / `Client` |
//! | session upload/receive-pack | `Session` |
//! | `ErrTimeoutExceeded` | `Error.TimeoutExceeded` |
//! | `DecodeUploadPackResponse` | `decodeUploadPackResponse` |
//! | `isRepoNotFoundError` | `isRepoNotFoundError` |

const std = @import("std");
const transport = @import("transport");
const packp = @import("packp");
const capability = @import("capability");
const sideband = @import("sideband");
const pktline = @import("pktline");
const ioutil = @import("ioutil");

const Allocator = std.mem.Allocator;
const Endpoint = transport.Endpoint;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

pub const Error = error{
    /// go-git `ErrTimeoutExceeded`.
    TimeoutExceeded,
    /// Stderr carried an unrecognized remote error line.
    UnknownRemoteError,
    /// Command failed to provide pipes or start.
    CommandFailed,
};

const read_error_seconds_timeout: u64 = 10;

// ---------------------------------------------------------------------------
// Commander / Command / CommandKiller
// ---------------------------------------------------------------------------

/// Creates Command instances (go-git `Commander`).
pub const Commander = struct {
    ptr: *anyopaque,
    command_fn: *const fn (
        ptr: *anyopaque,
        cmd: []const u8,
        ep: *const Endpoint,
        auth: ?transport.AuthMethod,
    ) anyerror!Command,

    pub fn command(
        self: Commander,
        cmd: []const u8,
        ep: *const Endpoint,
        auth: ?transport.AuthMethod,
    ) anyerror!Command {
        return self.command_fn(self.ptr, cmd, ep, auth);
    }

    pub fn from(comptime T: type, impl: *T) Commander {
        const gen = struct {
            fn commandFn(
                ptr: *anyopaque,
                cmd: []const u8,
                ep: *const Endpoint,
                auth: ?transport.AuthMethod,
            ) anyerror!Command {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.command(cmd, ep, auth);
            }
        };
        return .{ .ptr = impl, .command_fn = gen.commandFn };
    }
};

/// Single command execution (go-git `Command`).
pub const Command = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        stderrPipe: *const fn (ptr: *anyopaque) anyerror!*Reader,
        stdinPipe: *const fn (ptr: *anyopaque) anyerror!WriteCloser,
        stdoutPipe: *const fn (ptr: *anyopaque) anyerror!*Reader,
        start: *const fn (ptr: *anyopaque) anyerror!void,
        close: *const fn (ptr: *anyopaque) anyerror!void,
        /// Always present: dedicated kill or same as close (go-git CommandKiller).
        kill: *const fn (ptr: *anyopaque) anyerror!void,
    };

    pub fn stderrPipe(self: Command) anyerror!*Reader {
        return self.vtable.stderrPipe(self.ptr);
    }
    pub fn stdinPipe(self: Command) anyerror!WriteCloser {
        return self.vtable.stdinPipe(self.ptr);
    }
    pub fn stdoutPipe(self: Command) anyerror!*Reader {
        return self.vtable.stdoutPipe(self.ptr);
    }
    pub fn start(self: Command) anyerror!void {
        return self.vtable.start(self.ptr);
    }
    pub fn close(self: Command) anyerror!void {
        return self.vtable.close(self.ptr);
    }
    /// Terminate the command (go-git `CommandKiller.Kill`, or `Close` when absent).
    pub fn kill(self: Command) anyerror!void {
        return self.vtable.kill(self.ptr);
    }

    pub fn from(comptime T: type, impl: *T) Command {
        const gen = struct {
            fn stderrPipeFn(ptr: *anyopaque) anyerror!*Reader {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.stderrPipe();
            }
            fn stdinPipeFn(ptr: *anyopaque) anyerror!WriteCloser {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.stdinPipe();
            }
            fn stdoutPipeFn(ptr: *anyopaque) anyerror!*Reader {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.stdoutPipe();
            }
            fn startFn(ptr: *anyopaque) anyerror!void {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.start();
            }
            fn closeFn(ptr: *anyopaque) anyerror!void {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.close();
            }
            fn killFn(ptr: *anyopaque) anyerror!void {
                const s: *T = @ptrCast(@alignCast(ptr));
                // Backends must implement kill (may delegate to close).
                return s.kill();
            }
            const vtable = VTable{
                .stderrPipe = stderrPipeFn,
                .stdinPipe = stdinPipeFn,
                .stdoutPipe = stdoutPipeFn,
                .start = startFn,
                .close = closeFn,
                .kill = killFn,
            };
        };
        return .{
            .ptr = impl,
            .vtable = &gen.vtable,
        };
    }
};

/// Write end of a command stdin pipe (close ends the stream).
pub const WriteCloser = struct {
    ptr: *anyopaque,
    writer: *Writer,
    close_fn: *const fn (ptr: *anyopaque) anyerror!void,

    pub fn close(self: WriteCloser) anyerror!void {
        return self.close_fn(self.ptr);
    }
};

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// Pack-protocol client over a Commander (go-git `client`).
pub const Client = struct {
    cmdr: Commander,
    allocator: Allocator,

    pub fn init(allocator: Allocator, cmdr: Commander) Client {
        return .{ .cmdr = cmdr, .allocator = allocator };
    }

    pub fn newUploadPackSession(
        self: *Client,
        ep: *const Endpoint,
        auth: ?transport.AuthMethod,
    ) !Session {
        return self.newSession(uploadPackServiceName(), ep, auth);
    }

    pub fn newReceivePackSession(
        self: *Client,
        ep: *const Endpoint,
        auth: ?transport.AuthMethod,
    ) !Session {
        return self.newSession(receivePackServiceName(), ep, auth);
    }

    /// Expose command-backed file/git/ssh clients through the shared transport
    /// registry. Each returned interface owns one heap session.
    pub fn asTransport(self: *Client) transport.Transport {
        return .{ .ptr = self, .vtable = &client_transport_vtable };
    }

    fn newSession(
        self: *Client,
        service: []const u8,
        ep: *const Endpoint,
        auth: ?transport.AuthMethod,
    ) !Session {
        const cmd = try self.cmdr.command(service, ep, auth);
        const stdin = try cmd.stdinPipe();
        const stdout = try cmd.stdoutPipe();
        const stderr = cmd.stderrPipe() catch null;
        try cmd.start();

        return Session{
            .allocator = self.allocator,
            .stdin = stdin,
            .stdout = stdout,
            .command = cmd,
            .stderr = stderr,
            .is_receive_pack = std.mem.eql(u8, service, receivePackServiceName()),
        };
    }
};

const OwnedSession = struct {
    allocator: Allocator,
    session: Session,
};

fn cloneAdvRefs(allocator: Allocator, src: *const packp.AdvRefs) !*packp.AdvRefs {
    const dst = try packp.allocAdvRefs(allocator);
    errdefer packp.freeAdvRefs(allocator, dst);
    dst.head = src.head;
    const caps = try src.capabilities.clone(allocator);
    dst.capabilities.deinit();
    dst.capabilities = caps;
    for (src.prefix.items) |p| try dst.appendPrefix(p);
    var refs = src.references.iterator();
    while (refs.next()) |entry| try dst.putReference(entry.key_ptr.*, entry.value_ptr.*);
    var peeled = src.peeled.iterator();
    while (peeled.next()) |entry| try dst.putPeeled(entry.key_ptr.*, entry.value_ptr.*);
    for (src.shallows.items) |hash| try dst.appendShallow(hash);
    return dst;
}

fn ownedClose(ptr: *anyopaque) void {
    const owned: *OwnedSession = @ptrCast(@alignCast(ptr));
    const allocator = owned.allocator;
    owned.session.close() catch {};
    allocator.destroy(owned);
}

fn ownedAdvertised(ptr: *anyopaque, ctx: transport.OperationContext) anyerror!*packp.AdvRefs {
    const owned: *OwnedSession = @ptrCast(@alignCast(ptr));
    try ctx.check();
    const refs = try owned.session.advertisedReferencesContext();
    return cloneAdvRefs(owned.allocator, refs);
}

fn ownedUpload(ptr: *anyopaque, ctx: transport.OperationContext, req: *const packp.UploadPackRequest) anyerror!*packp.UploadPackResponse {
    const owned: *OwnedSession = @ptrCast(@alignCast(ptr));
    try ctx.check();
    return owned.session.uploadPack(@constCast(req));
}

fn ownedReceive(ptr: *anyopaque, ctx: transport.OperationContext, req: *const packp.ReferenceUpdateRequest) anyerror!transport.ReceivePackOutcome {
    const owned: *OwnedSession = @ptrCast(@alignCast(ptr));
    try ctx.check();
    const report = try owned.session.receivePack(@constCast(req));
    return .{ .report = report, .err = null };
}

fn ownedSetAuth(_: *anyopaque, auth: ?transport.AuthMethod) anyerror!void {
    if (auth != null) return transport.Error.AlreadyConnected;
}

const upload_session_vtable = transport.UploadPackSession.VTable{
    .close = ownedClose,
    .advertised_references = ownedAdvertised,
    .upload_pack = ownedUpload,
    .set_auth = ownedSetAuth,
};

const receive_session_vtable = transport.ReceivePackSession.VTable{
    .close = ownedClose,
    .advertised_references = ownedAdvertised,
    .receive_pack = ownedReceive,
    .set_auth = ownedSetAuth,
};

fn clientNewUpload(ptr: *anyopaque, ep: *const Endpoint, auth: ?transport.AuthMethod) anyerror!transport.UploadPackSession {
    const client: *Client = @ptrCast(@alignCast(ptr));
    const owned = try client.allocator.create(OwnedSession);
    errdefer client.allocator.destroy(owned);
    owned.* = .{ .allocator = client.allocator, .session = try client.newUploadPackSession(ep, auth) };
    return .{ .ptr = owned, .vtable = &upload_session_vtable };
}

fn clientNewReceive(ptr: *anyopaque, ep: *const Endpoint, auth: ?transport.AuthMethod) anyerror!transport.ReceivePackSession {
    const client: *Client = @ptrCast(@alignCast(ptr));
    const owned = try client.allocator.create(OwnedSession);
    errdefer client.allocator.destroy(owned);
    owned.* = .{ .allocator = client.allocator, .session = try client.newReceivePackSession(ep, auth) };
    return .{ .ptr = owned, .vtable = &receive_session_vtable };
}

const client_transport_vtable = transport.Transport.VTable{
    .newUploadPackSession = clientNewUpload,
    .newReceivePackSession = clientNewReceive,
};

/// go-git `NewClient`.
pub fn newClient(allocator: Allocator, cmdr: Commander) Client {
    return Client.init(allocator, cmdr);
}

fn uploadPackServiceName() []const u8 {
    return transport.UploadPackServiceName;
}

fn receivePackServiceName() []const u8 {
    return transport.ReceivePackServiceName;
}

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

/// Shared upload-pack / receive-pack session over command pipes.
pub const Session = struct {
    allocator: Allocator,
    stdin: WriteCloser,
    stdout: *Reader,
    command: Command,
    stderr: ?*Reader = null,

    is_receive_pack: bool = false,
    adv_refs: ?*packp.AdvRefs = null,
    pack_run: bool = false,
    finished: bool = false,
    /// Cached first non-skipped stderr line (read on demand).
    first_err_line: ?[]u8 = null,
    first_err_read: bool = false,

    /// Returns session-owned AdvRefs (freed in `close`). Do not free the pointer.
    pub fn advertisedReferences(self: *Session) !*packp.AdvRefs {
        return self.advertisedReferencesContext();
    }

    /// Returns session-owned AdvRefs (freed in `close`). Do not free the pointer.
    pub fn advertisedReferencesContext(self: *Session) !*packp.AdvRefs {
        if (self.adv_refs) |ar| return ar;

        const ar = try packp.allocAdvRefs(self.allocator);
        // Freed on error paths only; success stores `ar` in `self.adv_refs` (Session.close frees).
        errdefer if (self.adv_refs != ar) packp.freeAdvRefs(self.allocator, ar);

        ar.decode(self.stdout) catch |err| {
            try self.handleAdvRefDecodeError(err);
        };

        if (!self.is_receive_pack and ar.isEmpty()) {
            return transport.Error.EmptyRemoteRepository;
        }

        transport.filterUnsupportedCapabilities(&ar.capabilities);
        self.adv_refs = ar;
        return ar;
    }

    fn handleAdvRefDecodeError(self: *Session, err: anyerror) !void {
        // Empty stdout: look at stderr for not-found / remote errors (go-git).
        if (err == error.EmptyInput or err == error.EndOfStream) {
            self.finished = true;
            try self.raiseFromStderr();
            return error.UnexpectedEndOfStream;
        }
        if (err == error.EmptyAdvRefs) {
            // Empty repositories are valid for git-receive-pack.
            if (self.is_receive_pack) return;
            try self.finish();
            return transport.Error.EmptyRemoteRepository;
        }
        if (err == error.ErrorLine) {
            try self.raiseFromStderr();
            return transport.Error.RepositoryNotFound;
        }
        // Unexpected data / other: still try stderr not-found mapping.
        self.ensureFirstErrLine();
        if (self.first_err_line) |line| {
            if (isRepoNotFoundError(line)) return transport.Error.RepositoryNotFound;
        }
        return err;
    }

    pub fn uploadPack(
        self: *Session,
        // Non-const: packp encode sorts wants/haves (go-git mutates for wire order).
        req: *packp.UploadPackRequest,
    ) !*packp.UploadPackResponse {
        if (req.isEmpty()) {
            try self.finish();
            return transport.Error.EmptyUploadPackRequest;
        }
        try req.validate();
        _ = try self.advertisedReferencesContext();

        self.pack_run = true;

        try uploadPackWrite(self.stdin.writer, req);
        try self.stdin.close();

        // Non-empty check on stdout.
        _ = ioutil.nonEmptyReader(self.stdout) catch |err| {
            if (err == error.EmptyReader) {
                return transport.Error.EmptyUploadPackRequest;
            }
            return err;
        };

        return decodeUploadPackResponse(self.allocator, self.stdout, req, self);
    }

    pub fn receivePack(
        self: *Session,
        // Non-const: packp encode may order commands for the wire.
        req: *packp.ReferenceUpdateRequest,
    ) !?*packp.ReportStatus {
        _ = try self.advertisedReferences();
        self.pack_run = true;

        try req.encode(self.stdin.writer);
        try self.stdin.close();

        if (!req.capabilities.supports(capability.ReportStatus)) {
            try self.command.close();
            return null;
        }

        const report = try packp.newReportStatus(self.allocator);
        errdefer packp.freeReportStatus(self.allocator, report);

        if (req.capabilities.supports(capability.Sideband64k) or
            req.capabilities.supports(capability.Sideband))
        {
            const demux_type: sideband.Type = if (req.capabilities.supports(capability.Sideband64k))
                .sideband64k
            else
                .sideband;
            var demux = sideband.Demuxer.init(demux_type, self.stdout);
            demux.progress = req.progress;
            // Drain demuxed pack channel into a buffer, then decode report-status.
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(self.allocator);
            var chunk: [4096]u8 = undefined;
            while (true) {
                const n = demux.read(&chunk) catch |e| switch (e) {
                    error.EndOfStream => break,
                    else => |err| return err,
                };
                if (n == 0) {
                    if (demux.last_n == 0) break;
                    try body.appendSlice(self.allocator, chunk[0..demux.last_n]);
                    break;
                }
                try body.appendSlice(self.allocator, chunk[0..n]);
            }
            var fixed: Reader = .fixed(body.items);
            try report.decode(&fixed);
        } else {
            try report.decode(self.stdout);
        }

        if (report.err() != null) {
            // go-git surfaces report-status failures via ReportStatus.Error().
            // Keep the report for inspection; caller sees non-null err via report.err().
        }

        try self.command.close();
        return report;
    }

    fn finish(self: *Session) !void {
        if (self.finished) return;
        self.finished = true;
        if (!self.pack_run) {
            // Graceful flush to server.
            try self.stdin.writer.writeAll(&pktline.FlushPkt);
        }
    }

    pub fn close(self: *Session) !void {
        var err: ?anyerror = null;
        self.finish() catch |e| {
            err = e;
        };
        // Always close stdin WriteCloser (may hold Allocating buffers).
        self.stdin.close() catch |e| {
            if (err == null) err = e;
        };
        self.command.close() catch |e| {
            if (err == null) err = e;
        };
        if (self.adv_refs) |ar| {
            packp.freeAdvRefs(self.allocator, ar);
            self.adv_refs = null;
        }
        if (self.first_err_line) |line| {
            self.allocator.free(line);
            self.first_err_line = null;
        }
        if (err) |e| return e;
    }

    fn onError(self: *Session) void {
        self.command.kill() catch {};
        self.close() catch {};
    }

    /// Read the first non-skipped stderr line (go-git `listenFirstError`, sync).
    pub fn ensureFirstErrLine(self: *Session) void {
        if (self.first_err_read) return;
        self.first_err_read = true;
        const r = self.stderr orelse return;
        // Read line-oriented stderr; skip decorative remote: lines.
        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(self.allocator);

        while (true) {
            const byte = r.takeByte() catch break;
            if (byte == '\n') {
                if (!stdErrSkipLine(line_buf.items)) {
                    self.first_err_line = line_buf.toOwnedSlice(self.allocator) catch null;
                    drainReader(r);
                    return;
                }
                line_buf.clearRetainingCapacity();
                continue;
            }
            if (byte != '\r') {
                line_buf.append(self.allocator, byte) catch break;
            }
        }
        if (line_buf.items.len > 0 and !stdErrSkipLine(line_buf.items)) {
            self.first_err_line = line_buf.toOwnedSlice(self.allocator) catch null;
        }
    }

    /// go-git `checkNotFoundError` — map stderr to RepositoryNotFound / UnknownRemoteError.
    pub fn raiseFromStderr(self: *Session) !void {
        self.ensureFirstErrLine();
        const line = self.first_err_line orelse return;
        if (line.len == 0) return;
        if (isRepoNotFoundError(line)) return transport.Error.RepositoryNotFound;
        return Error.UnknownRemoteError;
    }
};

fn drainReader(r: *Reader) void {
    while (true) {
        _ = r.takeByte() catch break;
    }
}

// ---------------------------------------------------------------------------
// upload-pack wire helpers
// ---------------------------------------------------------------------------

fn uploadPackWrite(w: *Writer, req: *packp.UploadPackRequest) !void {
    // go-git uploadPack: UploadRequest.Encode + UploadHaves.Encode + "done".
    try req.upload_request.encode(w);
    try req.upload_haves.encode(w, true);
    var enc = pktline.Encoder.init(w);
    try enc.encodef("done\n", .{});
}

/// go-git `DecodeUploadPackResponse`.
pub fn decodeUploadPackResponse(
    allocator: Allocator,
    r: *Reader,
    req: *const packp.UploadPackRequest,
    closer: anytype,
) !*packp.UploadPackResponse {
    const res = try packp.newUploadPackResponse(allocator, req);
    errdefer packp.freeUploadPackResponse(allocator, res);
    try res.decode(r, closer);
    return res;
}

// ---------------------------------------------------------------------------
// Stderr / not-found helpers
// ---------------------------------------------------------------------------

/// go-git `stdErrSkipPattern` = `^remote:( =*){0,1}$`
pub fn stdErrSkipLine(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "remote:")) return false;
    const rest = line["remote:".len..];
    if (rest.len == 0) return true;
    if (rest[0] != ' ') return false;
    for (rest[1..]) |c| {
        if (c != '=') return false;
    }
    return true;
}

const github_repo_not_found_err = "Repository not found.";
const bitbucket_repo_not_found_err = "repository does not exist.";
const local_repo_not_found_err = "does not appear to be a git repository";
const git_protocol_not_found_err = "Repository not found.";
const git_protocol_no_such_err = "no such repository";
const git_protocol_access_denied_err = "access denied";
const gogs_access_denied_err = "Repository does not exist or you do not have access";
const gitlab_repo_not_found_err = "The project you were looking for could not be found";

/// go-git `isRepoNotFoundError`.
pub fn isRepoNotFoundError(s: []const u8) bool {
    const needles = [_][]const u8{
        github_repo_not_found_err,
        bitbucket_repo_not_found_err,
        local_repo_not_found_err,
        git_protocol_not_found_err,
        git_protocol_no_such_err,
        git_protocol_access_denied_err,
        gogs_access_denied_err,
        gitlab_repo_not_found_err,
    };
    for (needles) |n| {
        if (std.mem.indexOf(u8, s, n) != null) return true;
    }
    return false;
}
