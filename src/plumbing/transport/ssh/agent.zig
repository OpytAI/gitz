//! OpenSSH SSH agent client (wire protocol over `SSH_AUTH_SOCK`).
//!
//! Pure Zig — Unix domain socket + big-endian length-prefixed messages.
//! See PROTOCOL.agent / OpenSSH `ssh-agent` message types.
//!
//! # Resource lifecycle
//!
//! `AgentClient.connect` opens the Unix socket. Call `disconnect` (or let
//! `defer client.disconnect()` run) to close it. `listIdentities` / `sign`
//! allocate reply buffers the caller frees; the client keeps only I/O buffers.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const testing = std.testing;

// ---------------------------------------------------------------------------
// Message types (OpenSSH SSH2 agent)
// ---------------------------------------------------------------------------

pub const SSH2_AGENTC_REQUEST_IDENTITIES: u8 = 11;
pub const SSH2_AGENT_IDENTITIES_ANSWER: u8 = 12;
pub const SSH2_AGENTC_SIGN_REQUEST: u8 = 13;
pub const SSH2_AGENT_SIGN_RESPONSE: u8 = 14;
pub const SSH_AGENT_FAILURE: u8 = 5;
pub const SSH_AGENT_SUCCESS: u8 = 6;

/// Hard cap on a single agent message body (type + payload), 1 MiB.
pub const max_message_len: u32 = 1 * 1024 * 1024;
/// Hard cap on identities listed in one answer.
pub const max_identities: u32 = 1024;
/// Hard cap on a single wire string (key blob / comment / signature).
pub const max_string_len: u32 = 256 * 1024;

pub const Error = error{
    /// Agent returned SSH_AGENT_FAILURE or unexpected type.
    AgentFailure,
    /// Response truncated / malformed / over size limits.
    AgentProtocol,
    /// Signature request rejected or empty.
    AgentSignFailed,
};

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

/// One public key listed by the agent.
pub const Identity = struct {
    /// Raw public key blob (SSH wire format: algo string + key material).
    key_blob: []u8,
    comment: []u8,

    pub fn deinit(self: *Identity, allocator: Allocator) void {
        if (self.key_blob.len > 0) allocator.free(self.key_blob);
        if (self.comment.len > 0) allocator.free(self.comment);
        self.* = .{ .key_blob = &.{}, .comment = &.{} };
    }
};

pub fn freeIdentities(allocator: Allocator, list: []Identity) void {
    for (list) |*id| id.deinit(allocator);
    allocator.free(list);
}

// ---------------------------------------------------------------------------
// Wire helpers (parse without I/O — unit-testable)
// ---------------------------------------------------------------------------

/// Parse SSH2_AGENT_IDENTITIES_ANSWER body (after the type byte).
/// `body` is: u32 nkeys, then nkeys × (string key_blob, string comment).
pub fn parseIdentitiesAnswer(allocator: Allocator, body: []const u8) (Allocator.Error || Error)![]Identity {
    if (body.len < 4) return error.AgentProtocol;
    var off: usize = 0;
    const nkeys = readU32(body, &off) catch return error.AgentProtocol;
    if (nkeys > max_identities) return error.AgentProtocol;

    var list: std.ArrayList(Identity) = .empty;
    errdefer {
        for (list.items) |*id| id.deinit(allocator);
        list.deinit(allocator);
    }

    var i: u32 = 0;
    while (i < nkeys) : (i += 1) {
        const blob = readString(body, &off) catch return error.AgentProtocol;
        const comment = readString(body, &off) catch return error.AgentProtocol;
        const blob_owned = try allocator.dupe(u8, blob);
        errdefer allocator.free(blob_owned);
        const comment_owned = try allocator.dupe(u8, comment);
        errdefer allocator.free(comment_owned);
        try list.append(allocator, .{
            .key_blob = blob_owned,
            .comment = comment_owned,
        });
    }
    return try list.toOwnedSlice(allocator);
}

/// Parse SSH2_AGENT_SIGN_RESPONSE body (after the type byte): string signature.
pub fn parseSignResponse(allocator: Allocator, body: []const u8) (Allocator.Error || Error)![]u8 {
    var off: usize = 0;
    const sig = readString(body, &off) catch return error.AgentProtocol;
    if (sig.len == 0) return error.AgentSignFailed;
    return try allocator.dupe(u8, sig);
}

fn readU32(buf: []const u8, off: *usize) error{AgentProtocol}!u32 {
    if (off.* > buf.len or buf.len - off.* < 4) return error.AgentProtocol;
    const v = std.mem.readInt(u32, buf[off.* ..][0..4], .big);
    off.* += 4;
    return v;
}

fn readString(buf: []const u8, off: *usize) error{AgentProtocol}![]const u8 {
    const n = try readU32(buf, off);
    if (n > max_string_len) return error.AgentProtocol;
    if (n > buf.len - off.*) return error.AgentProtocol;
    const s = buf[off.* .. off.* + n];
    off.* += n;
    return s;
}

/// Build a request message: u32be(len) || type || payload. Caller frees.
pub fn buildRequest(allocator: Allocator, msg_type: u8, payload: []const u8) Allocator.Error![]u8 {
    const total = 4 + 1 + payload.len;
    const out = try allocator.alloc(u8, total);
    std.mem.writeInt(u32, out[0..4], @intCast(1 + payload.len), .big);
    out[4] = msg_type;
    if (payload.len > 0) @memcpy(out[5..], payload);
    return out;
}

/// Build SSH2_AGENTC_SIGN_REQUEST payload (without outer length/type).
pub fn buildSignRequestPayload(
    allocator: Allocator,
    key_blob: []const u8,
    data: []const u8,
    flags: u32,
) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    writeString(w, key_blob) catch return error.OutOfMemory;
    writeString(w, data) catch return error.OutOfMemory;
    var flag_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &flag_buf, flags, .big);
    w.writeAll(&flag_buf) catch return error.OutOfMemory;
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeString(w: *std.Io.Writer, s: []const u8) anyerror!void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(s.len), .big);
    try w.writeAll(&len_buf);
    try w.writeAll(s);
}

// ---------------------------------------------------------------------------
// AgentClient
// ---------------------------------------------------------------------------

fn singleThreadedIo() Io {
    const Holder = struct {
        threadlocal var threaded: Io.Threaded = .init_single_threaded;
    };
    return Holder.threaded.io();
}

/// Connected SSH agent client over a Unix domain socket.
///
/// # Lifecycle
///
/// - `connect` opens the Unix socket; pair with `disconnect` (or `defer disconnect()`).
/// - `listIdentities` / `sign` open no extra resources beyond reply allocations
///   the caller frees. The client does not retain agent state across calls.
/// - `newSSHAgentAuth` does **not** hold a live `AgentClient`; the signers
///   callback connects and disconnects per invocation.
/// - Readers/writers are rebound on each I/O call so return-by-value is safe
///   (buffers live inside this struct).
pub const AgentClient = struct {
    allocator: Allocator,
    io: Io,
    stream: ?Io.net.Stream = null,
    read_buf: [8192]u8 = undefined,
    write_buf: [4096]u8 = undefined,
    reader_impl: Io.net.Stream.Reader = undefined,
    writer_impl: Io.net.Stream.Writer = undefined,

    /// Connect to `sock_path` (typically `$SSH_AUTH_SOCK`).
    pub fn connect(allocator: Allocator, io: Io, sock_path: []const u8) !AgentClient {
        const addr = try Io.net.UnixAddress.init(sock_path);
        const stream = try addr.connect(io);
        return .{
            .allocator = allocator,
            .io = io,
            .stream = stream,
        };
    }

    pub fn connectDefaultIo(allocator: Allocator, sock_path: []const u8) !AgentClient {
        return connect(allocator, singleThreadedIo(), sock_path);
    }

    /// Close the agent socket. Idempotent.
    pub fn disconnect(self: *AgentClient) void {
        if (self.stream) |s| {
            s.close(self.io);
            self.stream = null;
        }
    }

    fn rebind(self: *AgentClient) Error!void {
        const s = self.stream orelse return error.AgentProtocol;
        self.reader_impl = s.reader(self.io, &self.read_buf);
        self.writer_impl = s.writer(self.io, &self.write_buf);
    }

    /// SSH2_AGENTC_REQUEST_IDENTITIES → list of identities.
    pub fn listIdentities(self: *AgentClient, allocator: Allocator) ![]Identity {
        try self.rebind();
        const req = try buildRequest(allocator, SSH2_AGENTC_REQUEST_IDENTITIES, &.{});
        defer allocator.free(req);
        try self.writeAll(req);

        const msg = try self.readMessage(allocator);
        defer allocator.free(msg);
        if (msg.len < 1) return error.AgentProtocol;
        if (msg[0] == SSH_AGENT_FAILURE) return error.AgentFailure;
        if (msg[0] != SSH2_AGENT_IDENTITIES_ANSWER) return error.AgentProtocol;
        return parseIdentitiesAnswer(allocator, msg[1..]);
    }

    /// SSH2_AGENTC_SIGN_REQUEST → signature blob.
    pub fn sign(
        self: *AgentClient,
        allocator: Allocator,
        key_blob: []const u8,
        data: []const u8,
        flags: u32,
    ) ![]u8 {
        try self.rebind();
        const payload = try buildSignRequestPayload(allocator, key_blob, data, flags);
        defer allocator.free(payload);
        const req = try buildRequest(allocator, SSH2_AGENTC_SIGN_REQUEST, payload);
        defer allocator.free(req);
        try self.writeAll(req);

        const msg = try self.readMessage(allocator);
        defer allocator.free(msg);
        if (msg.len < 1) return error.AgentProtocol;
        if (msg[0] == SSH_AGENT_FAILURE) return error.AgentSignFailed;
        if (msg[0] != SSH2_AGENT_SIGN_RESPONSE) return error.AgentProtocol;
        return parseSignResponse(allocator, msg[1..]);
    }

    fn writeAll(self: *AgentClient, bytes: []const u8) !void {
        const w = &self.writer_impl.interface;
        try w.writeAll(bytes);
        try w.flush();
    }

    /// Read one agent message: u32be length + that many bytes (type + payload).
    /// Returns owned type||payload (without the length prefix).
    fn readMessage(self: *AgentClient, allocator: Allocator) ![]u8 {
        const r = &self.reader_impl.interface;
        var len_buf: [4]u8 = undefined;
        try r.readSliceAll(&len_buf);
        const len = std.mem.readInt(u32, &len_buf, .big);
        if (len == 0 or len > max_message_len) return error.AgentProtocol;
        const body = try allocator.alloc(u8, len);
        errdefer allocator.free(body);
        try r.readSliceAll(body);
        return body;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildRequest identities" {
    const req = try buildRequest(testing.allocator, SSH2_AGENTC_REQUEST_IDENTITIES, &.{});
    defer testing.allocator.free(req);
    try testing.expectEqual(@as(usize, 5), req.len);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, req[0..4], .big));
    try testing.expectEqual(SSH2_AGENTC_REQUEST_IDENTITIES, req[4]);
}

test "parseIdentitiesAnswer canned" {
    // body after type: nkeys=1, blob="KEY", comment="me@host"
    var body: [4 + 4 + 3 + 4 + 7]u8 = undefined;
    var o: usize = 0;
    std.mem.writeInt(u32, body[o..][0..4], 1, .big);
    o += 4;
    std.mem.writeInt(u32, body[o..][0..4], 3, .big);
    o += 4;
    @memcpy(body[o .. o + 3], "KEY");
    o += 3;
    std.mem.writeInt(u32, body[o..][0..4], 7, .big);
    o += 4;
    @memcpy(body[o .. o + 7], "me@host");

    const ids = try parseIdentitiesAnswer(testing.allocator, body[0..]);
    defer freeIdentities(testing.allocator, ids);
    try testing.expectEqual(@as(usize, 1), ids.len);
    try testing.expectEqualStrings("KEY", ids[0].key_blob);
    try testing.expectEqualStrings("me@host", ids[0].comment);
}

test "parseIdentitiesAnswer empty list" {
    var body: [4]u8 = undefined;
    std.mem.writeInt(u32, body[0..4], 0, .big);
    const ids = try parseIdentitiesAnswer(testing.allocator, &body);
    defer freeIdentities(testing.allocator, ids);
    try testing.expectEqual(@as(usize, 0), ids.len);
}

test "parseSignResponse canned" {
    var body: [4 + 4]u8 = undefined;
    std.mem.writeInt(u32, body[0..4], 4, .big);
    @memcpy(body[4..8], "SIG!");
    const sig = try parseSignResponse(testing.allocator, &body);
    defer testing.allocator.free(sig);
    try testing.expectEqualStrings("SIG!", sig);
}

test "buildSignRequestPayload layout" {
    const p = try buildSignRequestPayload(testing.allocator, "kb", "data", 0);
    defer testing.allocator.free(p);
    // 4+2 + 4+4 + 4 flags = 18
    try testing.expectEqual(@as(usize, 18), p.len);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, p[0..4], .big));
}

test "parseIdentitiesAnswer rejects oversized nkeys" {
    var body: [4]u8 = undefined;
    std.mem.writeInt(u32, body[0..4], max_identities + 1, .big);
    try testing.expectError(error.AgentProtocol, parseIdentitiesAnswer(testing.allocator, &body));
}

test "parseIdentitiesAnswer rejects truncated string" {
    // nkeys=1 but no strings follow
    var body: [4]u8 = undefined;
    std.mem.writeInt(u32, body[0..4], 1, .big);
    try testing.expectError(error.AgentProtocol, parseIdentitiesAnswer(testing.allocator, &body));
}

test "parseSignResponse empty signature fails" {
    var body: [4]u8 = undefined;
    std.mem.writeInt(u32, body[0..4], 0, .big);
    try testing.expectError(error.AgentSignFailed, parseSignResponse(testing.allocator, &body));
}

test "readString rejects oversize via parseSignResponse" {
    // string length claims max_string_len+1 with no following bytes
    var body: [4]u8 = undefined;
    std.mem.writeInt(u32, body[0..4], max_string_len + 1, .big);
    try testing.expectError(error.AgentProtocol, parseSignResponse(testing.allocator, &body));
}
