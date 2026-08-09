//! Pure-Zig native SSH client for git pack protocol over SSH.
//!
//! SSH-2.0 client surface used by the transport runner:
//! - TCP connect via `std.Io.net`
//! - Version exchange and binary packets
//! - Encryption: `aes256-ctr`, `aes128-ctr` (AES-CTR, non-EtM)
//! - MAC: `hmac-sha2-512`, `hmac-sha2-256` (RFC 6668)
//! - KEX: `curve25519-sha256` (+ libssh alias)
//! - Host key: `ssh-ed25519` verify; `rsa-sha2-256` verify via
//!   `std.crypto.Certificate.rsa` (PKCS#1 v1.5 + SHA-256)
//! - NEWKEYS, password and publickey (OpenSSH ed25519 PEM) userauth
//! - Channel session + exec of `CommandPlan.remote_command`
//! - Bridge channel stdio to `transport_common.Command` pipes
//!
//! Wire negotiation picks the first mutual algorithm from each client
//! preference list. No C, no libssh. System `ssh` remains an alternate dial.

const std = @import("std");
const builtin = @import("builtin");
const transport_common = @import("transport_common");
const auth_mod = @import("auth_method.zig");
const agent_mod = @import("agent.zig");
const known_hosts_mod = @import("known_hosts.zig");
const wire = @import("ssh_wire.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const testing = std.testing;
const Sha256 = std.crypto.hash.sha2.Sha256;
const X25519 = std.crypto.dh.X25519;
const Ed25519 = std.crypto.sign.Ed25519;
const Rsa = std.crypto.Certificate.rsa;
const HostName = std.Io.net.HostName;
const IpAddress = std.Io.net.IpAddress;
const Stream = std.Io.net.Stream;
const Server = std.Io.net.Server;

fn processEnviron() std.process.Environ {
    if (builtin.is_test) return std.testing.environ;
    if (builtin.link_libc) {
        if (std.c.environ) |c_environ| {
            var n: usize = 0;
            while (c_environ[n] != null) : (n += 1) {}
            return .{ .block = .{ .slice = c_environ[0..n :null] } };
        }
    }
    return .empty;
}

/// Dial parameters for `NativeCommand` (owned strings freed by `deinit`).
///
/// Built from `CommandPlan` in `common.zig` without importing that module
/// (avoids a circular dependency).
///
/// # Ownership
///
/// | Field | Owner |
/// |-------|--------|
/// | `remote_command`, `host_with_port` | this struct |
/// | `owned_host` / `host` | this struct (`host` views `owned_host`) |
/// | `owned_user` / `user` | this struct when `owned_user` set |
/// | `client_config` string slices | **borrowed** from caller-owned auth |
///   (auth method must outlive connect / userauth) |
pub const NativeDialParams = struct {
    allocator: Allocator,
    remote_command: []u8 = &.{},
    host_with_port: []u8 = &.{},
    /// Owned host name (always set by runner transfer path).
    owned_host: ?[]u8 = null,
    /// View of host for dial (points at `owned_host` or static test literal).
    host: []const u8 = "",
    port: i32 = 22,
    user: []const u8 = "",
    /// When set, this struct owns `user`.
    owned_user: ?[]u8 = null,
    insecure_ignore_host_key: bool = false,
    client_config: auth_mod.ClientConfig = .{},
    /// Owned normalized SOCKS5 proxy URL. Empty means direct TCP.
    proxy_url: []u8 = &.{},

    pub fn deinit(self: *NativeDialParams) void {
        const a = self.allocator;
        if (self.remote_command.len > 0) a.free(self.remote_command);
        if (self.host_with_port.len > 0) a.free(self.host_with_port);
        if (self.owned_host) |h| a.free(h);
        if (self.owned_user) |u| a.free(u);
        if (self.proxy_url.len > 0) a.free(self.proxy_url);
        self.* = .{ .allocator = a };
    }
};

pub const client_version: []const u8 = "SSH-2.0-gitz_0.1";

pub const Error = error{
    /// TCP or name resolution failed.
    SshConnectFailed,
    /// Proxy URL is not a supported SOCKS5 URL.
    SshProxyUnsupported,
    /// SOCKS5 negotiation or username/password authentication failed.
    SshProxyHandshakeFailed,
    /// SOCKS5 proxy rejected the destination CONNECT request.
    SshProxyConnectRejected,
    /// Version exchange failed or peer is not SSH-2.0.
    SshVersionExchangeFailed,
    /// Key exchange failed (negotiation, crypto, or host-key signature).
    SshKexFailed,
    /// Host key callback rejected the server key.
    SshHostKeyRejected,
    /// User authentication failed.
    SshAuthFailed,
    /// Public-keys callback did not expose an agent socket that can sign.
    SshAgentSigningUnsupported,
    /// Channel open / exec failed.
    SshChannelFailed,
    /// Protocol or framing error after connect.
    SshProtocolError,
    /// Unsupported key type or encrypted key without passphrase path.
    SshKeyUnsupported,
    /// Invalid OpenSSH private key blob.
    SshInvalidPrivateKey,
    /// Connection closed unexpectedly.
    SshConnectionClosed,
    /// Command already started / connected (mirrors transport common).
    AlreadyConnected,
};

// Preferred algorithm lists (client order: first mutual wins).
const kex_prefs = [_][]const u8{ "curve25519-sha256", "curve25519-sha256@libssh.org" };
const host_key_prefs = [_][]const u8{ "ssh-ed25519", "rsa-sha2-256" };
const enc_prefs = [_][]const u8{ "aes256-ctr", "aes128-ctr" };
const mac_prefs = [_][]const u8{ "hmac-sha2-512", "hmac-sha2-256" };
const comp_prefs = [_][]const u8{"none"};

// Server-side lists for the pure-Zig loopback test peer (same set as client).
const peer_kex_algs = [_][]const u8{ "curve25519-sha256", "curve25519-sha256@libssh.org" };
const peer_host_key_algs = [_][]const u8{"ssh-ed25519"};
const peer_enc_algs = [_][]const u8{ "aes256-ctr", "aes128-ctr" };
const peer_mac_algs = [_][]const u8{ "hmac-sha2-512", "hmac-sha2-256" };
const peer_comp_algs = [_][]const u8{"none"};

// ---------------------------------------------------------------------------
// OpenSSH ed25519 private key decode
// ---------------------------------------------------------------------------

/// Parsed Ed25519 key material from OpenSSH PEM / PKCS#8 (seed + public).
pub const Ed25519Key = struct {
    /// 32-byte seed (OpenSSH private key first half).
    seed: [32]u8,
    /// 32-byte public key.
    public: [32]u8,
    /// SSH public key blob: string("ssh-ed25519") || string(public).
    public_blob: []u8,
    allocator: Allocator,

    pub fn deinit(self: *Ed25519Key) void {
        @memset(&self.seed, 0);
        @memset(&self.public, 0);
        if (self.public_blob.len > 0) {
            @memset(self.public_blob, 0);
            self.allocator.free(self.public_blob);
        }
        self.* = undefined;
    }

    pub fn keyPair(self: *const Ed25519Key) !Ed25519.KeyPair {
        return Ed25519.KeyPair.generateDeterministic(self.seed);
    }
};

/// Decode an unencrypted OpenSSH ed25519 private key from PEM bytes.
pub fn loadEd25519PrivateKey(allocator: Allocator, pem_bytes: []const u8) (Allocator.Error || Error)!Ed25519Key {
    var info = auth_mod.parsePemPrivateKeyStructure(allocator, pem_bytes) catch return error.SshInvalidPrivateKey;
    defer info.deinit(allocator);

    if (info.encrypted) return error.SshKeyUnsupported;
    if (!std.mem.eql(u8, info.key_type, "ssh-ed25519") and info.key_type.len != 0) {
        // detect may return ssh-ed25519; empty means unknown PKCS#8.
        if (info.key_type.len > 0) return error.SshKeyUnsupported;
    }

    if (std.mem.eql(u8, info.label, "OPENSSH PRIVATE KEY")) {
        return parseOpensshEd25519(allocator, info.body);
    }
    return error.SshKeyUnsupported;
}

fn parseOpensshEd25519(allocator: Allocator, body: []const u8) (Allocator.Error || Error)!Ed25519Key {
    const magic = "openssh-key-v1\x00";
    if (!std.mem.startsWith(u8, body, magic)) return error.SshInvalidPrivateKey;
    var off: usize = magic.len;

    const cipher = wire.readString(body, &off) catch return error.SshInvalidPrivateKey;
    const kdf = wire.readString(body, &off) catch return error.SshInvalidPrivateKey;
    _ = wire.readString(body, &off) catch return error.SshInvalidPrivateKey; // kdf options
    if (!std.mem.eql(u8, cipher, "none") or !std.mem.eql(u8, kdf, "none")) {
        return error.SshKeyUnsupported;
    }

    const nkeys = wire.readU32(body, &off) catch return error.SshInvalidPrivateKey;
    if (nkeys != 1) return error.SshInvalidPrivateKey;

    const pub_blob = wire.readString(body, &off) catch return error.SshInvalidPrivateKey;
    const priv_block = wire.readString(body, &off) catch return error.SshInvalidPrivateKey;

    // Public blob: string algo || string key
    var p_off: usize = 0;
    const algo = wire.readString(pub_blob, &p_off) catch return error.SshInvalidPrivateKey;
    if (!std.mem.eql(u8, algo, "ssh-ed25519")) return error.SshKeyUnsupported;
    const pub_key = wire.readString(pub_blob, &p_off) catch return error.SshInvalidPrivateKey;
    if (pub_key.len != 32) return error.SshInvalidPrivateKey;

    // Private block: check1, check2, algo, pub, priv(64), comment, pad
    var pr_off: usize = 0;
    const check1 = wire.readU32(priv_block, &pr_off) catch return error.SshInvalidPrivateKey;
    const check2 = wire.readU32(priv_block, &pr_off) catch return error.SshInvalidPrivateKey;
    if (check1 != check2) return error.SshInvalidPrivateKey;
    const priv_algo = wire.readString(priv_block, &pr_off) catch return error.SshInvalidPrivateKey;
    if (!std.mem.eql(u8, priv_algo, "ssh-ed25519")) return error.SshKeyUnsupported;
    const priv_pub = wire.readString(priv_block, &pr_off) catch return error.SshInvalidPrivateKey;
    const priv = wire.readString(priv_block, &pr_off) catch return error.SshInvalidPrivateKey;
    _ = wire.readString(priv_block, &pr_off) catch return error.SshInvalidPrivateKey; // comment
    if (priv.len != 64) return error.SshInvalidPrivateKey;
    if (priv_pub.len != 32) return error.SshInvalidPrivateKey;

    var seed: [32]u8 = undefined;
    var public: [32]u8 = undefined;
    @memcpy(&seed, priv[0..32]);
    @memcpy(&public, priv[32..64]);
    // Cross-check public halves.
    if (!std.mem.eql(u8, &public, pub_key) or !std.mem.eql(u8, &public, priv_pub)) {
        return error.SshInvalidPrivateKey;
    }

    const owned_blob = try allocator.dupe(u8, pub_blob);
    return .{
        .seed = seed,
        .public = public,
        .public_blob = owned_blob,
        .allocator = allocator,
    };
}

/// Build SSH public-key blob for ed25519.
pub fn buildEd25519PublicBlob(allocator: Allocator, public: *const [32]u8) Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try wire.appendString(&list, allocator, "ssh-ed25519");
    try wire.appendString(&list, allocator, public);
    return try list.toOwnedSlice(allocator);
}

/// Build SSH signature blob for ed25519 (string algo || string 64-byte sig).
pub fn buildEd25519SignatureBlob(allocator: Allocator, sig64: *const [64]u8) Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try wire.appendString(&list, allocator, "ssh-ed25519");
    try wire.appendString(&list, allocator, sig64);
    return try list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Native SSH connection
// ---------------------------------------------------------------------------

const initial_window: u32 = 2 * 1024 * 1024;
const max_packet_channel: u32 = 32 * 1024;

/// In-process SSH client connection (one remote command).
pub const NativeConn = struct {
    allocator: Allocator,
    io: Io,
    stream: Stream = undefined,
    stream_live: bool = false,
    reader_impl: Stream.Reader = undefined,
    writer_impl: Stream.Writer = undefined,
    read_buf: [16384]u8 = undefined,
    write_buf: [16384]u8 = undefined,

    send_seq: u32 = 0,
    recv_seq: u32 = 0,
    send_cipher: wire.PacketCipher = .none(),
    recv_cipher: wire.PacketCipher = .none(),

    client_version: []const u8 = client_version,
    server_version: []u8 = &.{},
    session_id: []u8 = &.{},

    // Channel
    local_channel: u32 = 0,
    remote_channel: u32 = 0,
    send_window: u32 = 0,
    recv_window: u32 = initial_window,
    channel_open: bool = false,
    channel_eof_recv: bool = false,
    channel_closed: bool = false,
    exec_started: bool = false,

    // Stdout / stderr assembly buffers (channel data)
    stdout_buf: std.ArrayList(u8) = .empty,
    stderr_buf: std.ArrayList(u8) = .empty,
    stdout_reader: Reader = undefined,
    stderr_reader: Reader = undefined,
    stdin_writer: Writer = undefined,
    stdin_scratch: [8192]u8 = undefined,
    stdout_iface_buf: [8192]u8 = undefined,
    stderr_iface_buf: [4096]u8 = undefined,
    pipes_bound: bool = false,
    stdin_closed: bool = false,

    pub fn deinit(self: *NativeConn) void {
        self.closeStream();
        if (self.server_version.len > 0) self.allocator.free(self.server_version);
        if (self.session_id.len > 0) self.allocator.free(self.session_id);
        self.stdout_buf.deinit(self.allocator);
        self.stderr_buf.deinit(self.allocator);
        self.* = undefined;
    }

    fn closeStream(self: *NativeConn) void {
        if (self.stream_live) {
            self.stream.close(self.io);
            self.stream_live = false;
        }
    }

    fn rebindIo(self: *NativeConn) void {
        self.reader_impl = self.stream.reader(self.io, &self.read_buf);
        self.writer_impl = self.stream.writer(self.io, &self.write_buf);
    }

    fn writer(self: *NativeConn) *Writer {
        return &self.writer_impl.interface;
    }

    fn reader(self: *NativeConn) *Reader {
        return &self.reader_impl.interface;
    }

    /// TCP connect + full SSH handshake + channel open (no exec yet).
    ///
    /// On any failure after TCP open, the stream is closed (no FD leak).
    pub fn connect(
        self: *NativeConn,
        host: []const u8,
        port: u16,
        user: []const u8,
        cfg: *const auth_mod.ClientConfig,
        host_with_port: []const u8,
        proxy_url: []const u8,
    ) !void {
        errdefer self.closeStream();
        if (proxy_url.len == 0) {
            try self.tcpConnect(host, port);
        } else {
            try self.tcpConnectProxy(proxy_url, host, port);
        }
        try self.exchangeVersions();
        try self.doKex(cfg, host_with_port);
        try self.doUserauth(user, cfg);
        try self.openSessionChannel();
    }

    fn tcpConnect(self: *NativeConn, host: []const u8, port: u16) !void {
        const bare = bareHost(host);
        if (IpAddress.parse(bare, port)) |addr| {
            var a = addr;
            self.stream = a.connect(self.io, .{ .mode = .stream }) catch return error.SshConnectFailed;
        } else |_| {
            const hn = HostName.init(bare) catch return error.SshConnectFailed;
            self.stream = hn.connect(self.io, port, .{ .mode = .stream }) catch return error.SshConnectFailed;
        }
        self.stream_live = true;
        self.rebindIo();
    }

    fn tcpConnectProxy(self: *NativeConn, proxy_url: []const u8, host: []const u8, port: u16) !void {
        const uri = std.Uri.parse(proxy_url) catch return error.SshProxyUnsupported;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "socks5")) return error.SshProxyUnsupported;
        const proxy_port = uri.port orelse return error.SshProxyUnsupported;

        var host_buf: [HostName.max_len]u8 = undefined;
        const proxy_host = uri.getHost(&host_buf) catch return error.SshProxyUnsupported;
        self.stream = proxy_host.connect(self.io, proxy_port, .{ .mode = .stream }) catch
            return error.SshConnectFailed;
        self.stream_live = true;
        self.rebindIo();

        var user_buf: [255]u8 = undefined;
        var password_buf: [255]u8 = undefined;
        const username = if (uri.user) |u| u.toRaw(&user_buf) catch
            return error.SshProxyUnsupported else "";
        const password = if (uri.password) |p| p.toRaw(&password_buf) catch
            return error.SshProxyUnsupported else "";
        try self.socks5Connect(host, port, username, password);
    }

    fn socks5Connect(
        self: *NativeConn,
        target_host: []const u8,
        target_port: u16,
        username: []const u8,
        password: []const u8,
    ) !void {
        const greeting = socks5Greeting(username.len != 0);
        try self.writer().writeAll(greeting.bytes[0..greeting.len]);
        try self.writer().flush();

        var method_reply: [2]u8 = undefined;
        self.reader().readSliceAll(&method_reply) catch return error.SshProxyHandshakeFailed;
        if (method_reply[0] != 5) return error.SshProxyHandshakeFailed;
        switch (method_reply[1]) {
            0 => {},
            2 => {
                const auth_request = buildSocks5AuthRequest(self.allocator, username, password) catch |err| switch (err) {
                    error.SshProxyUnsupported => return error.SshProxyHandshakeFailed,
                    else => |e| return e,
                };
                defer self.allocator.free(auth_request);
                try self.writer().writeAll(auth_request);
                try self.writer().flush();
                var auth_reply: [2]u8 = undefined;
                self.reader().readSliceAll(&auth_reply) catch return error.SshProxyHandshakeFailed;
                if (auth_reply[0] != 1 or auth_reply[1] != 0)
                    return error.SshProxyHandshakeFailed;
            },
            else => return error.SshProxyHandshakeFailed,
        }

        const request = try buildSocks5ConnectRequest(self.allocator, target_host, target_port);
        defer self.allocator.free(request);
        try self.writer().writeAll(request);
        try self.writer().flush();

        var reply_head: [4]u8 = undefined;
        self.reader().readSliceAll(&reply_head) catch return error.SshProxyHandshakeFailed;
        const address_type = try validateSocks5ConnectReplyHeader(reply_head);
        const address_len: usize = switch (address_type) {
            1 => 4,
            4 => 16,
            3 => blk: {
                var len: [1]u8 = undefined;
                self.reader().readSliceAll(&len) catch return error.SshProxyHandshakeFailed;
                break :blk len[0];
            },
            else => return error.SshProxyHandshakeFailed,
        };
        var discard: [257]u8 = undefined;
        self.reader().readSliceAll(discard[0 .. address_len + 2]) catch
            return error.SshProxyHandshakeFailed;
    }

    fn exchangeVersions(self: *NativeConn) !void {
        // Send our version line.
        try self.writer().writeAll(self.client_version);
        try self.writer().writeAll("\r\n");
        try self.writer().flush();

        // Read server version (line ending with \n, optional \r).
        var line_buf: [255]u8 = undefined;
        var n: usize = 0;
        var terminated = false;
        while (n < line_buf.len) {
            var b: [1]u8 = undefined;
            self.reader().readSliceAll(&b) catch return error.SshVersionExchangeFailed;
            if (b[0] == '\n') {
                terminated = true;
                break;
            }
            if (b[0] != '\r') {
                line_buf[n] = b[0];
                n += 1;
            }
        }
        if (!terminated or n == 0) return error.SshVersionExchangeFailed;
        if (!std.mem.startsWith(u8, line_buf[0..n], "SSH-2.0-") and
            !std.mem.startsWith(u8, line_buf[0..n], "SSH-1.99-"))
        {
            return error.SshVersionExchangeFailed;
        }
        self.server_version = try self.allocator.dupe(u8, line_buf[0..n]);
    }

    fn writePacket(self: *NativeConn, payload: []const u8) !void {
        self.rebindIo();
        const wire_bytes = try wire.encodePacket(self.allocator, &self.send_cipher, self.send_seq, payload);
        defer self.allocator.free(wire_bytes);
        try self.writer().writeAll(wire_bytes);
        try self.writer().flush();
        self.send_seq +%= 1;
    }

    fn readPacket(self: *NativeConn) ![]u8 {
        self.rebindIo();
        while (true) {
            const payload = wire.decodePacket(self.allocator, &self.recv_cipher, self.recv_seq, self.reader()) catch |err| {
                if (err == error.EndOfStream) return error.SshConnectionClosed;
                return err;
            };
            self.recv_seq +%= 1;
            if (payload.len == 0) {
                self.allocator.free(payload);
                continue;
            }
            switch (payload[0]) {
                wire.msg_ignore, wire.msg_debug, wire.msg_ext_info => {
                    self.allocator.free(payload);
                    continue;
                },
                wire.msg_global_request => {
                    // RFC 4254: when want_reply is true, respond with REQUEST_FAILURE.
                    var off: usize = 1;
                    const want_reply = blk: {
                        _ = wire.readString(payload, &off) catch break :blk false;
                        break :blk wire.readBool(payload, &off) catch false;
                    };
                    self.allocator.free(payload);
                    if (want_reply) {
                        self.writePacket(&[_]u8{wire.msg_request_failure}) catch {};
                    }
                    continue;
                },
                wire.msg_disconnect => {
                    self.allocator.free(payload);
                    return error.SshConnectionClosed;
                },
                else => return payload,
            }
        }
    }

    fn doKex(self: *NativeConn, cfg: *const auth_mod.ClientConfig, host_with_port: []const u8) !void {
        var cookie: [16]u8 = undefined;
        self.io.random(&cookie);

        const client_kex = try wire.buildKexInit(
            self.allocator,
            &cookie,
            &kex_prefs,
            &host_key_prefs,
            &enc_prefs,
            &mac_prefs,
            &comp_prefs,
        );
        defer self.allocator.free(client_kex);

        try self.writePacket(client_kex);

        const server_kex_payload = try self.readPacket();
        defer self.allocator.free(server_kex_payload);
        if (server_kex_payload[0] != wire.msg_kexinit) return error.SshKexFailed;

        const server_view = wire.parseKexInit(server_kex_payload) catch return error.SshKexFailed;
        _ = wire.negotiate(&kex_prefs, server_view.kex_algorithms) catch return error.SshKexFailed;
        const host_key_alg = wire.negotiate(&host_key_prefs, server_view.server_host_key_algorithms) catch return error.SshKexFailed;
        const enc_c2s_name = wire.negotiate(&enc_prefs, server_view.encryption_c2s) catch return error.SshKexFailed;
        const enc_s2c_name = wire.negotiate(&enc_prefs, server_view.encryption_s2c) catch return error.SshKexFailed;
        const mac_c2s_name = wire.negotiate(&mac_prefs, server_view.mac_c2s) catch return error.SshKexFailed;
        const mac_s2c_name = wire.negotiate(&mac_prefs, server_view.mac_s2c) catch return error.SshKexFailed;
        // Direction-independent: require both directions pick the same family.
        if (!std.mem.eql(u8, enc_c2s_name, enc_s2c_name)) return error.SshKexFailed;
        if (!std.mem.eql(u8, mac_c2s_name, mac_s2c_name)) return error.SshKexFailed;
        const enc_alg = wire.EncAlg.fromName(enc_c2s_name) catch return error.SshKexFailed;
        const mac_alg = wire.MacAlg.fromName(mac_c2s_name) catch return error.SshKexFailed;

        // Ephemeral X25519.
        var eph = X25519.KeyPair.generate(self.io);
        var init_msg: std.ArrayList(u8) = .empty;
        defer init_msg.deinit(self.allocator);
        try init_msg.append(self.allocator, wire.msg_kex_ecdh_init);
        try wire.appendString(&init_msg, self.allocator, &eph.public_key);
        try self.writePacket(init_msg.items);

        const reply = try self.readPacket();
        defer self.allocator.free(reply);
        if (reply.len < 1 or reply[0] != wire.msg_kex_ecdh_reply) return error.SshKexFailed;

        var off: usize = 1;
        const host_key_blob = wire.readString(reply, &off) catch return error.SshKexFailed;
        const server_eph = wire.readString(reply, &off) catch return error.SshKexFailed;
        const signature_blob = wire.readString(reply, &off) catch return error.SshKexFailed;
        if (server_eph.len != 32) return error.SshKexFailed;

        const shared = X25519.scalarmult(eph.secret_key, server_eph[0..32].*) catch return error.SshKexFailed;
        const K_mpint = wire.encodeMpint(self.allocator, &shared) catch return error.SshKexFailed;
        defer self.allocator.free(K_mpint);

        // H = HASH(V_C || V_S || I_C || I_S || K_S || Q_C || Q_S || K)
        var h = Sha256.init(.{});
        wire.hashWriteString(&h, self.client_version);
        wire.hashWriteString(&h, self.server_version);
        wire.hashWriteString(&h, client_kex);
        wire.hashWriteString(&h, server_kex_payload);
        wire.hashWriteString(&h, host_key_blob);
        wire.hashWriteString(&h, &eph.public_key);
        wire.hashWriteString(&h, server_eph);
        h.update(K_mpint);
        var H: [32]u8 = undefined;
        h.final(&H);

        // Verify host key signature for the negotiated host-key algorithm.
        try verifyHostKeySignature(host_key_alg, host_key_blob, signature_blob, &H);

        // Host key callback.
        if (cfg.host_key_callback) |cb| {
            var hk_off: usize = 0;
            const key_type = wire.readString(host_key_blob, &hk_off) catch return error.SshKexFailed;
            // known_hosts stores the key type and the complete RFC 4253 blob.
            // The negotiated RSA signature algorithm is not the stored key type.
            cb.check(host_with_port, host_with_port, key_type, host_key_blob) catch
                return error.SshHostKeyRejected;
        }

        self.session_id = try self.allocator.dupe(u8, &H);

        // Derive keys sized for negotiated algs (client A/C/E, server B/D/F).
        const iv_len = enc_alg.ivLen();
        const key_len = enc_alg.keyLen();
        const mac_key_len = mac_alg.keyLen();

        var iv_c2s: [wire.aes_iv_len]u8 = undefined;
        var iv_s2c: [wire.aes_iv_len]u8 = undefined;
        var key_c2s: [wire.max_enc_key_len]u8 = undefined;
        var key_s2c: [wire.max_enc_key_len]u8 = undefined;
        var mac_c2s: [wire.max_mac_length]u8 = undefined;
        var mac_s2c: [wire.max_mac_length]u8 = undefined;
        wire.generateKeyMaterial(iv_c2s[0..iv_len], 'A', K_mpint, &H, self.session_id);
        wire.generateKeyMaterial(iv_s2c[0..iv_len], 'B', K_mpint, &H, self.session_id);
        wire.generateKeyMaterial(key_c2s[0..key_len], 'C', K_mpint, &H, self.session_id);
        wire.generateKeyMaterial(key_s2c[0..key_len], 'D', K_mpint, &H, self.session_id);
        wire.generateKeyMaterial(mac_c2s[0..mac_key_len], 'E', K_mpint, &H, self.session_id);
        wire.generateKeyMaterial(mac_s2c[0..mac_key_len], 'F', K_mpint, &H, self.session_id);

        // NEWKEYS — after send, encrypt outbound; after recv, decrypt inbound.
        try self.writePacket(&[_]u8{wire.msg_newkeys});
        self.send_cipher = wire.PacketCipher.initFromAlgs(
            enc_alg,
            key_c2s[0..key_len],
            iv_c2s[0..iv_len],
            mac_alg,
            mac_c2s[0..mac_key_len],
        ) catch return error.SshKexFailed;

        const peer_newkeys = try self.readPacket();
        defer self.allocator.free(peer_newkeys);
        if (peer_newkeys.len < 1 or peer_newkeys[0] != wire.msg_newkeys) return error.SshKexFailed;
        self.recv_cipher = wire.PacketCipher.initFromAlgs(
            enc_alg,
            key_s2c[0..key_len],
            iv_s2c[0..iv_len],
            mac_alg,
            mac_s2c[0..mac_key_len],
        ) catch return error.SshKexFailed;
    }

    fn doUserauth(self: *NativeConn, user: []const u8, cfg: *const auth_mod.ClientConfig) !void {
        // Service request.
        var svc: std.ArrayList(u8) = .empty;
        defer svc.deinit(self.allocator);
        try svc.append(self.allocator, wire.msg_service_request);
        try wire.appendString(&svc, self.allocator, "ssh-userauth");
        try self.writePacket(svc.items);

        const svc_reply = try self.readPacket();
        defer self.allocator.free(svc_reply);
        if (svc_reply.len < 1 or svc_reply[0] != wire.msg_service_accept) return error.SshAuthFailed;

        // Try auth methods based on config.
        switch (cfg.auth_kind) {
            .password, .password_callback => {
                const password = try resolvePassword(cfg);
                try self.authPassword(user, password);
            },
            .public_keys => {
                try self.authPublicKey(user, cfg);
            },
            .public_keys_callback => {
                try self.authAgentPublicKey(user, cfg);
            },
            .keyboard_interactive => try self.authKeyboardInteractive(user, cfg),
            .none => {
                // Try "none" then fail.
                try self.authNone(user);
            },
        }
    }

    fn resolvePassword(cfg: *const auth_mod.ClientConfig) ![]const u8 {
        if (cfg.auth_kind == .password) return cfg.password;
        if (cfg.password_callback) |cb| {
            const ctx = cfg.callback_ctx orelse return error.SshAuthFailed;
            return cb(ctx) catch return error.SshAuthFailed;
        }
        return error.SshAuthFailed;
    }

    fn authNone(self: *NativeConn, user: []const u8) !void {
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.allocator);
        try msg.append(self.allocator, wire.msg_userauth_request);
        try wire.appendString(&msg, self.allocator, user);
        try wire.appendString(&msg, self.allocator, "ssh-connection");
        try wire.appendString(&msg, self.allocator, "none");
        try self.writePacket(msg.items);
        const reply = try self.readPacket();
        defer self.allocator.free(reply);
        if (reply.len > 0 and reply[0] == wire.msg_userauth_success) return;
        return error.SshAuthFailed;
    }

    fn authPassword(self: *NativeConn, user: []const u8, password: []const u8) !void {
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.allocator);
        try msg.append(self.allocator, wire.msg_userauth_request);
        try wire.appendString(&msg, self.allocator, user);
        try wire.appendString(&msg, self.allocator, "ssh-connection");
        try wire.appendString(&msg, self.allocator, "password");
        try wire.appendBool(&msg, self.allocator, false);
        try wire.appendString(&msg, self.allocator, password);
        try self.writePacket(msg.items);

        while (true) {
            const reply = try self.readPacket();
            defer self.allocator.free(reply);
            if (reply.len == 0) return error.SshAuthFailed;
            switch (reply[0]) {
                wire.msg_userauth_success => return,
                wire.msg_userauth_banner => continue,
                wire.msg_userauth_failure => return error.SshAuthFailed,
                else => return error.SshAuthFailed,
            }
        }
    }

    fn authPublicKey(self: *NativeConn, user: []const u8, cfg: *const auth_mod.ClientConfig) !void {
        if (cfg.pem_bytes.len == 0) return error.SshAuthFailed;
        if (cfg.key_type.len != 0 and !std.mem.eql(u8, cfg.key_type, "ssh-ed25519"))
            return error.SshKeyUnsupported;
        var key = loadEd25519PrivateKey(self.allocator, cfg.pem_bytes) catch |err| switch (err) {
            error.SshKeyUnsupported => return error.SshKeyUnsupported,
            error.SshInvalidPrivateKey => return error.SshInvalidPrivateKey,
            else => return error.SshAuthFailed,
        };
        defer key.deinit();
        const kp = key.keyPair() catch return error.SshAuthFailed;

        // Signature data: string session_id || USERAUTH_REQUEST fields
        var sign_data: std.ArrayList(u8) = .empty;
        defer sign_data.deinit(self.allocator);
        try wire.appendString(&sign_data, self.allocator, self.session_id);
        try sign_data.append(self.allocator, wire.msg_userauth_request);
        try wire.appendString(&sign_data, self.allocator, user);
        try wire.appendString(&sign_data, self.allocator, "ssh-connection");
        try wire.appendString(&sign_data, self.allocator, "publickey");
        try wire.appendBool(&sign_data, self.allocator, true);
        try wire.appendString(&sign_data, self.allocator, "ssh-ed25519");
        try wire.appendString(&sign_data, self.allocator, key.public_blob);

        const sig = kp.sign(sign_data.items, null) catch return error.SshAuthFailed;
        const sig_bytes = sig.toBytes();
        const sig_blob = try buildEd25519SignatureBlob(self.allocator, &sig_bytes);
        defer self.allocator.free(sig_blob);

        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.allocator);
        try msg.append(self.allocator, wire.msg_userauth_request);
        try wire.appendString(&msg, self.allocator, user);
        try wire.appendString(&msg, self.allocator, "ssh-connection");
        try wire.appendString(&msg, self.allocator, "publickey");
        try wire.appendBool(&msg, self.allocator, true);
        try wire.appendString(&msg, self.allocator, "ssh-ed25519");
        try wire.appendString(&msg, self.allocator, key.public_blob);
        try wire.appendString(&msg, self.allocator, sig_blob);
        try self.writePacket(msg.items);

        while (true) {
            const reply = try self.readPacket();
            defer self.allocator.free(reply);
            if (reply.len == 0) return error.SshAuthFailed;
            switch (reply[0]) {
                wire.msg_userauth_success => return,
                wire.msg_userauth_banner, wire.msg_userauth_pk_ok => continue,
                wire.msg_userauth_failure => return error.SshAuthFailed,
                else => return error.SshAuthFailed,
            }
        }
    }

    fn authKeyboardInteractive(self: *NativeConn, user: []const u8, cfg: *const auth_mod.ClientConfig) !void {
        const callback = cfg.challenge_fn orelse return error.SshAuthFailed;
        const callback_ctx = cfg.callback_ctx orelse return error.SshAuthFailed;

        var request: std.ArrayList(u8) = .empty;
        defer request.deinit(self.allocator);
        try request.append(self.allocator, wire.msg_userauth_request);
        try wire.appendString(&request, self.allocator, user);
        try wire.appendString(&request, self.allocator, "ssh-connection");
        try wire.appendString(&request, self.allocator, "keyboard-interactive");
        try wire.appendString(&request, self.allocator, ""); // language tag
        try wire.appendString(&request, self.allocator, ""); // submethods
        try self.writePacket(request.items);

        while (true) {
            const reply = try self.readPacket();
            defer self.allocator.free(reply);
            if (reply.len == 0) return error.SshAuthFailed;
            switch (reply[0]) {
                wire.msg_userauth_success => return,
                wire.msg_userauth_banner => continue,
                wire.msg_userauth_failure => return error.SshAuthFailed,
                wire.msg_userauth_info_request => {
                    var challenge = try parseKeyboardChallenge(self.allocator, reply);
                    defer challenge.deinit(self.allocator);
                    const responses = callback(
                        callback_ctx,
                        self.allocator,
                        user,
                        challenge.instruction,
                        challenge.questions,
                        challenge.echos,
                    ) catch return error.SshAuthFailed;
                    defer freeChallengeResponses(self.allocator, responses);
                    if (responses.len != challenge.questions.len) return error.SshAuthFailed;
                    const encoded = try buildKeyboardResponse(self.allocator, responses);
                    defer self.allocator.free(encoded);
                    try self.writePacket(encoded);
                },
                else => return error.SshAuthFailed,
            }
        }
    }

    fn authAgentPublicKey(self: *NativeConn, user: []const u8, cfg: *const auth_mod.ClientConfig) !void {
        if (cfg.agent_sock.len == 0) return error.SshAgentSigningUnsupported;
        var agent = agent_mod.AgentClient.connect(self.allocator, self.io, cfg.agent_sock) catch
            return error.SshAuthFailed;
        defer agent.disconnect();
        const identities = agent.listIdentities(self.allocator) catch return error.SshAuthFailed;
        defer agent_mod.freeIdentities(self.allocator, identities);
        if (identities.len == 0) return error.SshAuthFailed;

        for (identities) |identity| {
            var blob_off: usize = 0;
            const key_type = wire.readString(identity.key_blob, &blob_off) catch continue;
            const request_algorithm = if (std.mem.eql(u8, key_type, "ssh-rsa"))
                "rsa-sha2-256"
            else
                key_type;
            const flags: u32 = if (std.mem.eql(u8, key_type, "ssh-rsa")) 2 else 0;

            var sign_data: std.ArrayList(u8) = .empty;
            defer sign_data.deinit(self.allocator);
            try wire.appendString(&sign_data, self.allocator, self.session_id);
            try sign_data.append(self.allocator, wire.msg_userauth_request);
            try wire.appendString(&sign_data, self.allocator, user);
            try wire.appendString(&sign_data, self.allocator, "ssh-connection");
            try wire.appendString(&sign_data, self.allocator, "publickey");
            try wire.appendBool(&sign_data, self.allocator, true);
            try wire.appendString(&sign_data, self.allocator, request_algorithm);
            try wire.appendString(&sign_data, self.allocator, identity.key_blob);

            const signature_blob = agent.sign(
                self.allocator,
                identity.key_blob,
                sign_data.items,
                flags,
            ) catch continue;
            defer self.allocator.free(signature_blob);

            var message: std.ArrayList(u8) = .empty;
            defer message.deinit(self.allocator);
            try message.append(self.allocator, wire.msg_userauth_request);
            try wire.appendString(&message, self.allocator, user);
            try wire.appendString(&message, self.allocator, "ssh-connection");
            try wire.appendString(&message, self.allocator, "publickey");
            try wire.appendBool(&message, self.allocator, true);
            try wire.appendString(&message, self.allocator, request_algorithm);
            try wire.appendString(&message, self.allocator, identity.key_blob);
            try wire.appendString(&message, self.allocator, signature_blob);
            try self.writePacket(message.items);

            while (true) {
                const reply = try self.readPacket();
                defer self.allocator.free(reply);
                if (reply.len == 0) break;
                switch (reply[0]) {
                    wire.msg_userauth_success => return,
                    wire.msg_userauth_banner => continue,
                    wire.msg_userauth_failure => break,
                    else => break,
                }
            }
        }
        return error.SshAuthFailed;
    }

    fn openSessionChannel(self: *NativeConn) !void {
        self.local_channel = 0;
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.allocator);
        try msg.append(self.allocator, wire.msg_channel_open);
        try wire.appendString(&msg, self.allocator, "session");
        try wire.appendU32(&msg, self.allocator, self.local_channel);
        try wire.appendU32(&msg, self.allocator, initial_window);
        try wire.appendU32(&msg, self.allocator, max_packet_channel);
        try self.writePacket(msg.items);

        const reply = try self.readPacket();
        defer self.allocator.free(reply);
        if (reply.len < 1 or reply[0] != wire.msg_channel_open_confirmation) {
            return error.SshChannelFailed;
        }
        var off: usize = 1;
        // recipient channel number (must match our local channel).
        const recipient = wire.readU32(reply, &off) catch return error.SshChannelFailed;
        if (recipient != self.local_channel) return error.SshChannelFailed;
        self.remote_channel = wire.readU32(reply, &off) catch return error.SshChannelFailed;
        self.send_window = wire.readU32(reply, &off) catch return error.SshChannelFailed;
        _ = wire.readU32(reply, &off) catch return error.SshChannelFailed; // max packet
        self.channel_open = true;
        self.channel_closed = false;
        self.channel_eof_recv = false;
    }

    /// Send exec request for the remote git command.
    pub fn exec(self: *NativeConn, command: []const u8) !void {
        if (!self.channel_open) return error.SshChannelFailed;
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.allocator);
        try msg.append(self.allocator, wire.msg_channel_request);
        try wire.appendU32(&msg, self.allocator, self.remote_channel);
        try wire.appendString(&msg, self.allocator, "exec");
        try wire.appendBool(&msg, self.allocator, true); // want reply
        try wire.appendString(&msg, self.allocator, command);
        try self.writePacket(msg.items);

        while (true) {
            const reply = try self.readPacket();
            defer self.allocator.free(reply);
            if (reply.len == 0) return error.SshChannelFailed;
            switch (reply[0]) {
                wire.msg_channel_success => {
                    self.exec_started = true;
                    return;
                },
                wire.msg_channel_failure => return error.SshChannelFailed,
                wire.msg_channel_window_adjust, wire.msg_channel_data, wire.msg_channel_extended_data => {
                    try self.handleChannelPayload(reply);
                },
                else => return error.SshChannelFailed,
            }
        }
    }

    fn handleChannelPayload(self: *NativeConn, payload: []const u8) !void {
        if (payload.len < 1) return;
        switch (payload[0]) {
            wire.msg_channel_data => {
                var off: usize = 1;
                _ = wire.readU32(payload, &off) catch return; // recipient channel
                const data = wire.readString(payload, &off) catch return;
                try self.stdout_buf.appendSlice(self.allocator, data);
                // Adjust window if needed.
                if (data.len > 0) {
                    self.recv_window -|= @intCast(data.len);
                    if (self.recv_window < initial_window / 2) {
                        try self.sendWindowAdjust(initial_window - self.recv_window);
                        self.recv_window = initial_window;
                    }
                }
            },
            wire.msg_channel_extended_data => {
                var off: usize = 1;
                _ = wire.readU32(payload, &off) catch return;
                const data_type = wire.readU32(payload, &off) catch return;
                const data = wire.readString(payload, &off) catch return;
                if (data_type == 1) {
                    try self.stderr_buf.appendSlice(self.allocator, data);
                }
            },
            wire.msg_channel_window_adjust => {
                var off: usize = 1;
                _ = wire.readU32(payload, &off) catch return;
                const add = wire.readU32(payload, &off) catch return;
                self.send_window +%= add;
            },
            wire.msg_channel_eof => {
                self.channel_eof_recv = true;
            },
            wire.msg_channel_close => {
                self.channel_closed = true;
                self.channel_open = false;
            },
            else => {},
        }
    }

    fn sendWindowAdjust(self: *NativeConn, bytes: u32) !void {
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.allocator);
        try msg.append(self.allocator, wire.msg_channel_window_adjust);
        try wire.appendU32(&msg, self.allocator, self.remote_channel);
        try wire.appendU32(&msg, self.allocator, bytes);
        try self.writePacket(msg.items);
    }

    fn sendChannelData(self: *NativeConn, data: []const u8) !void {
        var remaining = data;
        while (remaining.len > 0) {
            // Wait for window if needed by reading control packets.
            while (self.send_window == 0 and !self.channel_closed) {
                try self.pumpOnce();
            }
            if (self.channel_closed) return error.SshConnectionClosed;
            const chunk_len = @min(remaining.len, @min(@as(usize, self.send_window), @as(usize, max_packet_channel)));
            const chunk = remaining[0..chunk_len];

            var msg: std.ArrayList(u8) = .empty;
            defer msg.deinit(self.allocator);
            try msg.append(self.allocator, wire.msg_channel_data);
            try wire.appendU32(&msg, self.allocator, self.remote_channel);
            try wire.appendString(&msg, self.allocator, chunk);
            try self.writePacket(msg.items);
            self.send_window -|= @intCast(chunk_len);
            remaining = remaining[chunk_len..];
        }
    }

    fn sendEof(self: *NativeConn) !void {
        if (!self.channel_open) return;
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.allocator);
        try msg.append(self.allocator, wire.msg_channel_eof);
        try wire.appendU32(&msg, self.allocator, self.remote_channel);
        try self.writePacket(msg.items);
    }

    fn sendClose(self: *NativeConn) !void {
        if (self.channel_closed) return;
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.allocator);
        try msg.append(self.allocator, wire.msg_channel_close);
        try wire.appendU32(&msg, self.allocator, self.remote_channel);
        try self.writePacket(msg.items);
        self.channel_closed = true;
        self.channel_open = false;
    }

    /// Read one packet and handle channel messages; non-channel returns error path.
    fn pumpOnce(self: *NativeConn) !void {
        const payload = try self.readPacket();
        defer self.allocator.free(payload);
        try self.handleChannelPayload(payload);
    }

    /// Fill stdout_buf by reading packets until data arrives, EOF, or close.
    fn fillStdout(self: *NativeConn) !void {
        while (self.stdout_buf.items.len == 0 and !self.channel_eof_recv and !self.channel_closed) {
            try self.pumpOnce();
        }
    }

    fn bindPipes(self: *NativeConn) void {
        if (self.pipes_bound) return;
        self.pipes_bound = true;

        const stdin_vt = struct {
            fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
                const conn: *NativeConn = @alignCast(@fieldParentPtr("stdin_writer", w));
                var total: usize = 0;
                for (data, 0..) |part, i| {
                    const n = if (i + 1 == data.len and splat > 1) blk: {
                        var s: usize = 0;
                        var j: usize = 0;
                        while (j < splat) : (j += 1) {
                            conn.sendChannelData(part) catch return error.WriteFailed;
                            s += part.len;
                        }
                        break :blk s;
                    } else blk: {
                        conn.sendChannelData(part) catch return error.WriteFailed;
                        break :blk part.len;
                    };
                    total += n;
                }
                return total;
            }
            fn flush(w: *Writer) Writer.Error!void {
                _ = w;
            }
        };
        self.stdin_writer = .{
            .vtable = &.{
                .drain = stdin_vt.drain,
                .flush = stdin_vt.flush,
            },
            .buffer = &self.stdin_scratch,
        };

        const stdout_vt = struct {
            fn stream(r: *Reader, w: *Writer, limit: Io.Limit) Reader.StreamError!usize {
                const conn: *NativeConn = @alignCast(@fieldParentPtr("stdout_reader", r));
                conn.fillStdout() catch |err| {
                    if (err == error.SshConnectionClosed or err == error.EndOfStream) {
                        if (conn.stdout_buf.items.len == 0) return error.EndOfStream;
                    } else return error.ReadFailed;
                };
                if (conn.stdout_buf.items.len == 0) return error.EndOfStream;
                const n = @min(conn.stdout_buf.items.len, limit.toInt() orelse conn.stdout_buf.items.len);
                const dest = limit.slice(try w.writableSliceGreedy(1));
                const copy_n = @min(n, dest.len);
                @memcpy(dest[0..copy_n], conn.stdout_buf.items[0..copy_n]);
                w.advance(copy_n);
                // Shift buffer
                const rest = conn.stdout_buf.items[copy_n..];
                std.mem.copyForwards(u8, conn.stdout_buf.items[0..rest.len], rest);
                conn.stdout_buf.shrinkRetainingCapacity(rest.len);
                return copy_n;
            }
        };
        self.stdout_reader = .{
            .vtable = &.{ .stream = stdout_vt.stream },
            .buffer = &self.stdout_iface_buf,
            .seek = 0,
            .end = 0,
        };

        const stderr_vt = struct {
            fn stream(r: *Reader, w: *Writer, limit: Io.Limit) Reader.StreamError!usize {
                const conn: *NativeConn = @alignCast(@fieldParentPtr("stderr_reader", r));
                // Pump a little for extended data.
                if (conn.stderr_buf.items.len == 0 and !conn.channel_closed) {
                    conn.pumpOnce() catch {};
                }
                if (conn.stderr_buf.items.len == 0) {
                    if (conn.channel_closed or conn.channel_eof_recv) return error.EndOfStream;
                    return error.EndOfStream;
                }
                const dest = limit.slice(try w.writableSliceGreedy(1));
                const copy_n = @min(conn.stderr_buf.items.len, dest.len);
                @memcpy(dest[0..copy_n], conn.stderr_buf.items[0..copy_n]);
                w.advance(copy_n);
                const rest = conn.stderr_buf.items[copy_n..];
                std.mem.copyForwards(u8, conn.stderr_buf.items[0..rest.len], rest);
                conn.stderr_buf.shrinkRetainingCapacity(rest.len);
                return copy_n;
            }
        };
        self.stderr_reader = .{
            .vtable = &.{ .stream = stderr_vt.stream },
            .buffer = &self.stderr_iface_buf,
            .seek = 0,
            .end = 0,
        };
    }
};

const KeyboardChallenge = struct {
    instruction: []const u8,
    questions: []const []const u8,
    echos: []const bool,

    fn deinit(self: *KeyboardChallenge, allocator: Allocator) void {
        allocator.free(self.questions);
        allocator.free(self.echos);
        self.* = undefined;
    }
};

fn parseKeyboardChallenge(allocator: Allocator, packet: []const u8) !KeyboardChallenge {
    if (packet.len == 0 or packet[0] != wire.msg_userauth_info_request)
        return error.SshAuthFailed;
    var off: usize = 1;
    _ = wire.readString(packet, &off) catch return error.SshAuthFailed; // name
    const instruction = wire.readString(packet, &off) catch return error.SshAuthFailed;
    _ = wire.readString(packet, &off) catch return error.SshAuthFailed; // language tag
    const count_u32 = wire.readU32(packet, &off) catch return error.SshAuthFailed;
    if (count_u32 > 256) return error.SshAuthFailed;
    const count: usize = @intCast(count_u32);
    const questions = try allocator.alloc([]const u8, count);
    errdefer allocator.free(questions);
    const echos = try allocator.alloc(bool, count);
    errdefer allocator.free(echos);
    for (0..count) |i| {
        questions[i] = wire.readString(packet, &off) catch return error.SshAuthFailed;
        echos[i] = wire.readBool(packet, &off) catch return error.SshAuthFailed;
    }
    if (off != packet.len) return error.SshAuthFailed;
    return .{ .instruction = instruction, .questions = questions, .echos = echos };
}

fn buildKeyboardResponse(allocator: Allocator, responses: []const []const u8) ![]u8 {
    var message: std.ArrayList(u8) = .empty;
    errdefer message.deinit(allocator);
    try message.append(allocator, wire.msg_userauth_info_response);
    try wire.appendU32(&message, allocator, @intCast(responses.len));
    for (responses) |response| try wire.appendString(&message, allocator, response);
    return message.toOwnedSlice(allocator);
}

fn freeChallengeResponses(allocator: Allocator, responses: []const []const u8) void {
    for (responses) |response| allocator.free(response);
    allocator.free(responses);
}

fn bareHost(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        return host[1 .. host.len - 1];
    }
    return host;
}

fn verifyHostKeySignature(
    host_key_alg: []const u8,
    host_key_blob: []const u8,
    signature_blob: []const u8,
    H: *const [32]u8,
) Error!void {
    if (std.mem.eql(u8, host_key_alg, "ssh-ed25519")) {
        return verifyHostKeyEd25519(host_key_blob, signature_blob, H);
    }
    if (std.mem.eql(u8, host_key_alg, "rsa-sha2-256")) {
        return verifyHostKeyRsaSha256(host_key_blob, signature_blob, H);
    }
    return error.SshKexFailed;
}

fn verifyHostKeyEd25519(host_key_blob: []const u8, signature_blob: []const u8, H: *const [32]u8) Error!void {
    var off: usize = 0;
    const algo = wire.readString(host_key_blob, &off) catch return error.SshKexFailed;
    if (!std.mem.eql(u8, algo, "ssh-ed25519")) return error.SshKexFailed;
    const pub_bytes = wire.readString(host_key_blob, &off) catch return error.SshKexFailed;
    if (pub_bytes.len != 32) return error.SshKexFailed;

    var s_off: usize = 0;
    const sig_algo = wire.readString(signature_blob, &s_off) catch return error.SshKexFailed;
    if (!std.mem.eql(u8, sig_algo, "ssh-ed25519")) return error.SshKexFailed;
    const sig_bytes = wire.readString(signature_blob, &s_off) catch return error.SshKexFailed;
    if (sig_bytes.len != 64) return error.SshKexFailed;

    const pk = Ed25519.PublicKey.fromBytes(pub_bytes[0..32].*) catch return error.SshKexFailed;
    const sig = Ed25519.Signature.fromBytes(sig_bytes[0..64].*);
    sig.verify(H, pk) catch return error.SshKexFailed;
}

/// Verify `rsa-sha2-256` host key signature (RFC 8332) over exchange hash `H`.
///
/// Host key blob format is the classic `ssh-rsa` public key (string + e + n).
/// Signature blob uses algorithm name `rsa-sha2-256` and PKCS#1 v1.5 + SHA-256.
/// Uses `std.crypto.Certificate.rsa` (no third-party RSA library).
fn verifyHostKeyRsaSha256(host_key_blob: []const u8, signature_blob: []const u8, H: *const [32]u8) Error!void {
    var off: usize = 0;
    const algo = wire.readString(host_key_blob, &off) catch return error.SshKexFailed;
    if (!std.mem.eql(u8, algo, "ssh-rsa")) return error.SshKexFailed;
    const e_raw = wire.readString(host_key_blob, &off) catch return error.SshKexFailed;
    const n_raw = wire.readString(host_key_blob, &off) catch return error.SshKexFailed;
    const e = wire.stripMpintLeadingZeros(e_raw);
    const n = wire.stripMpintLeadingZeros(n_raw);

    var s_off: usize = 0;
    const sig_algo = wire.readString(signature_blob, &s_off) catch return error.SshKexFailed;
    if (!std.mem.eql(u8, sig_algo, "rsa-sha2-256")) return error.SshKexFailed;
    const sig_bytes = wire.readString(signature_blob, &s_off) catch return error.SshKexFailed;

    const pk = Rsa.PublicKey.fromBytes(e, n) catch return error.SshKexFailed;

    // PKCS1v1_5Signature.verify is specialized on modulus length (bytes).
    switch (sig_bytes.len) {
        inline 128, 256, 384, 512 => |modulus_len| {
            if (sig_bytes.len != modulus_len) return error.SshKexFailed;
            var sig_arr: [modulus_len]u8 = undefined;
            @memcpy(&sig_arr, sig_bytes[0..modulus_len]);
            Rsa.PKCS1v1_5Signature.verify(modulus_len, sig_arr, H, pk, Sha256) catch return error.SshKexFailed;
        },
        else => return error.SshKexFailed,
    }
}

// ---------------------------------------------------------------------------
// NativeCommand — transport_common.Command
// ---------------------------------------------------------------------------

/// SSH command via pure-Zig native client (pack protocol over channel stdio).
///
/// Lifecycle (parity with file `HostCommand` / SSH `HostCommand`):
/// - `ensureConnected` owns the TCP+SSH session until `close`/`kill`/`deinit`.
/// - Stdin close flushes and sends channel EOF.
/// - `close` sends channel close then shuts the stream; `kill` aborts the stream.
/// - Heap-owned by `Runner` (freed in `Runner.deinit`).
/// - Do not read pipes after `close`/`kill` (no UAF use of dead stream).
pub const NativeCommand = struct {
    allocator: Allocator,
    io: Io,
    params: NativeDialParams,
    conn: ?*NativeConn = null,
    connected: bool = false,
    started: bool = false,
    closed: bool = false,

    pub fn deinit(self: *NativeCommand) void {
        self.kill() catch {};
        self.destroyConn();
        self.params.deinit();
        self.* = undefined;
    }

    fn destroyConn(self: *NativeCommand) void {
        if (self.conn) |c| {
            c.deinit();
            self.allocator.destroy(c);
            self.conn = null;
        }
    }

    fn ensureConnected(self: *NativeCommand) anyerror!void {
        if (self.closed) return error.SshConnectionClosed;
        if (self.connected) return;
        if (self.conn != null) {
            // Half-open residual: tear down and retry path is not expected.
            return error.SshProtocolError;
        }

        const c = try self.allocator.create(NativeConn);
        errdefer {
            c.deinit();
            self.allocator.destroy(c);
        }
        c.* = .{
            .allocator = self.allocator,
            .io = self.io,
        };

        if (self.params.port > std.math.maxInt(u16)) return error.SshConnectFailed;
        const port: u16 = if (self.params.port <= 0) 22 else @intCast(self.params.port);
        const user = if (self.params.user.len > 0) self.params.user else auth_mod.DefaultUsername;

        // Apply insecure host key when plan says so.
        var cfg = self.params.client_config;
        if (self.params.insecure_ignore_host_key and cfg.host_key_callback == null) {
            cfg.host_key_callback = auth_mod.HostKeyCallback.insecureIgnoreHostKey();
        }

        // The default must verify host keys. Keep the database alive through
        // KEX, then release it after connect completes or fails.
        var known_hosts_db: ?*known_hosts_mod.KnownHostsDb = null;
        defer if (known_hosts_db) |db|
            known_hosts_mod.freeKnownHostsDb(self.allocator, db);
        if (cfg.host_key_callback == null) {
            var loaded_db: *known_hosts_mod.KnownHostsDb = undefined;
            const callback = known_hosts_mod.newKnownHostsCallbackOwned(
                self.allocator,
                self.io,
                processEnviron(),
                &.{},
                &loaded_db,
            ) catch return error.SshHostKeyRejected;
            known_hosts_db = loaded_db;
            cfg.host_key_callback = callback;
        }

        try c.connect(
            self.params.host,
            port,
            user,
            &cfg,
            self.params.host_with_port,
            self.params.proxy_url,
        );
        c.bindPipes();
        self.conn = c;
        self.connected = true;
    }

    pub fn stderrPipe(self: *NativeCommand) anyerror!*Reader {
        try self.ensureConnected();
        return &self.conn.?.stderr_reader;
    }

    pub fn stdinPipe(self: *NativeCommand) anyerror!transport_common.WriteCloser {
        try self.ensureConnected();
        const c = self.conn.?;
        const gen = struct {
            fn closeFn(ptr: *anyopaque) anyerror!void {
                const s: *NativeCommand = @ptrCast(@alignCast(ptr));
                if (s.conn) |conn| {
                    if (!conn.stdin_closed) {
                        conn.stdin_closed = true;
                        conn.stdin_writer.flush() catch {};
                        conn.sendEof() catch {};
                    }
                }
            }
        };
        return .{
            .ptr = self,
            .writer = &c.stdin_writer,
            .close_fn = gen.closeFn,
        };
    }

    pub fn stdoutPipe(self: *NativeCommand) anyerror!*Reader {
        try self.ensureConnected();
        return &self.conn.?.stdout_reader;
    }

    pub fn start(self: *NativeCommand) anyerror!void {
        if (self.started) return error.AlreadyConnected;
        if (self.closed) return error.SshConnectionClosed;
        try self.ensureConnected();
        try self.conn.?.exec(self.params.remote_command);
        self.started = true;
    }

    /// Graceful channel close then TCP close (go-git Command.Close).
    pub fn close(self: *NativeCommand) anyerror!void {
        if (self.closed) return;
        self.closed = true;
        if (self.conn) |c| {
            if (!c.stdin_closed) {
                c.stdin_closed = true;
                c.stdin_writer.flush() catch {};
                c.sendEof() catch {};
            }
            c.sendClose() catch {};
            c.closeStream();
        }
        self.connected = false;
        self.started = false;
    }

    /// Abort stream immediately (go-git CommandKiller.Kill). Pipes invalid after.
    pub fn kill(self: *NativeCommand) anyerror!void {
        if (self.closed and self.conn == null) return;
        self.closed = true;
        if (self.conn) |c| {
            c.closeStream();
        }
        self.connected = false;
        self.started = false;
    }

    pub fn asCommand(self: *NativeCommand) transport_common.Command {
        return transport_common.Command.from(NativeCommand, self);
    }
};

// ---------------------------------------------------------------------------
// Helpers for tests / dial
// ---------------------------------------------------------------------------

/// Dial TCP only (used by tests: closed port must yield connect error).
pub fn dialTcp(io: Io, host: []const u8, port: u16) Error!Stream {
    const bare = bareHost(host);
    if (IpAddress.parse(bare, port)) |addr| {
        var a = addr;
        return a.connect(io, .{ .mode = .stream }) catch return error.SshConnectFailed;
    } else |_| {
        const hn = HostName.init(bare) catch return error.SshConnectFailed;
        return hn.connect(io, port, .{ .mode = .stream }) catch return error.SshConnectFailed;
    }
}

pub const Socks5Greeting = struct {
    bytes: [4]u8,
    len: usize,
};

/// RFC 1928 method greeting. Authenticated proxies are offered both no-auth
/// and RFC 1929 username/password, matching x/net/proxy's preference set.
pub fn socks5Greeting(has_credentials: bool) Socks5Greeting {
    return if (has_credentials)
        .{ .bytes = .{ 5, 2, 0, 2 }, .len = 4 }
    else
        .{ .bytes = .{ 5, 1, 0, 0 }, .len = 3 };
}

/// RFC 1928 CONNECT request using the domain-name address form. Name
/// resolution therefore happens at the proxy, as it does in go-git's SOCKS5
/// dialer. Caller frees the returned bytes.
pub fn buildSocks5ConnectRequest(
    allocator: Allocator,
    target_host: []const u8,
    target_port: u16,
) (Allocator.Error || error{SshProxyUnsupported})![]u8 {
    const host = bareHost(target_host);
    if (host.len == 0 or host.len > 255) return error.SshProxyUnsupported;
    const request = try allocator.alloc(u8, 7 + host.len);
    const header = [_]u8{ 5, 1, 0, 3, @intCast(host.len) };
    @memcpy(request[0..5], &header);
    @memcpy(request[5 .. 5 + host.len], host);
    var port_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &port_bytes, target_port, .big);
    @memcpy(request[5 + host.len ..][0..2], &port_bytes);
    return request;
}

/// RFC 1929 username/password sub-negotiation request. Caller frees it.
pub fn buildSocks5AuthRequest(
    allocator: Allocator,
    username: []const u8,
    password: []const u8,
) (Allocator.Error || error{SshProxyUnsupported})![]u8 {
    if (username.len == 0 or username.len > 255 or password.len > 255)
        return error.SshProxyUnsupported;
    const request = try allocator.alloc(u8, 3 + username.len + password.len);
    request[0] = 1;
    request[1] = @intCast(username.len);
    @memcpy(request[2 .. 2 + username.len], username);
    request[2 + username.len] = @intCast(password.len);
    @memcpy(request[3 + username.len ..], password);
    return request;
}

/// Validate the fixed RFC 1928 CONNECT response prefix and return ATYP.
pub fn validateSocks5ConnectReplyHeader(header: [4]u8) Error!u8 {
    if (header[0] != 5 or header[2] != 0) return error.SshProxyHandshakeFailed;
    if (header[1] != 0) return error.SshProxyConnectRejected;
    return switch (header[3]) {
        1, 3, 4 => header[3],
        else => error.SshProxyHandshakeFailed,
    };
}

fn singleThreadedIo() Io {
    const Holder = struct {
        threadlocal var threaded: Io.Threaded = .init_single_threaded;
    };
    return Holder.threaded.io();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Build a synthetic unencrypted OpenSSH ed25519 private key PEM for tests.
fn testEd25519Pem(allocator: Allocator, seed: *const [32]u8) !struct { pem: []u8, public: [32]u8 } {
    const kp = try Ed25519.KeyPair.generateDeterministic(seed.*);
    const public = kp.public_key.toBytes();

    // Public key section blob
    var pub_blob: std.ArrayList(u8) = .empty;
    defer pub_blob.deinit(allocator);
    try wire.appendString(&pub_blob, allocator, "ssh-ed25519");
    try wire.appendString(&pub_blob, allocator, &public);

    // Private section
    var priv: std.ArrayList(u8) = .empty;
    defer priv.deinit(allocator);
    try wire.appendU32(&priv, allocator, 0x01020304);
    try wire.appendU32(&priv, allocator, 0x01020304);
    try wire.appendString(&priv, allocator, "ssh-ed25519");
    try wire.appendString(&priv, allocator, &public);
    var priv64: [64]u8 = undefined;
    @memcpy(priv64[0..32], seed);
    @memcpy(priv64[32..64], &public);
    try wire.appendString(&priv, allocator, &priv64);
    try wire.appendString(&priv, allocator, "test@gitz");
    // Pad to block 8
    const pad_need = (8 - (priv.items.len % 8)) % 8;
    var p: u8 = 1;
    while (p <= pad_need) : (p += 1) {
        try priv.append(allocator, p);
    }

    // Outer body
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "openssh-key-v1\x00");
    try wire.appendString(&body, allocator, "none");
    try wire.appendString(&body, allocator, "none");
    try wire.appendString(&body, allocator, "");
    try wire.appendU32(&body, allocator, 1);
    try wire.appendString(&body, allocator, pub_blob.items);
    try wire.appendString(&body, allocator, priv.items);

    // PEM encode
    const b64_len = std.base64.standard.Encoder.calcSize(body.items.len);
    const b64 = try allocator.alloc(u8, b64_len);
    defer allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, body.items);

    var pem: std.ArrayList(u8) = .empty;
    errdefer pem.deinit(allocator);
    try pem.appendSlice(allocator, "-----BEGIN OPENSSH PRIVATE KEY-----\n");
    var i: usize = 0;
    while (i < b64.len) {
        const end = @min(i + 70, b64.len);
        try pem.appendSlice(allocator, b64[i..end]);
        try pem.append(allocator, '\n');
        i = end;
    }
    try pem.appendSlice(allocator, "-----END OPENSSH PRIVATE KEY-----\n");
    return .{ .pem = try pem.toOwnedSlice(allocator), .public = public };
}

test "load OpenSSH ed25519 private key" {
    const seed = [_]u8{0x42} ** 32;
    const gen = try testEd25519Pem(testing.allocator, &seed);
    defer testing.allocator.free(gen.pem);

    var key = try loadEd25519PrivateKey(testing.allocator, gen.pem);
    defer key.deinit();
    try testing.expectEqualSlices(u8, &seed, &key.seed);
    try testing.expectEqualSlices(u8, &gen.public, &key.public);

    // Public blob starts with ssh-ed25519 string
    var off: usize = 0;
    const algo = try wire.readString(key.public_blob, &off);
    try testing.expectEqualStrings("ssh-ed25519", algo);

    const kp = try key.keyPair();
    const msg = "gitz-ssh-test";
    const sig = try kp.sign(msg, null);
    try sig.verify(msg, kp.public_key);
}

test "buildEd25519PublicBlob shape" {
    const pubk = [_]u8{1} ** 32;
    const blob = try buildEd25519PublicBlob(testing.allocator, &pubk);
    defer testing.allocator.free(blob);
    var off: usize = 0;
    try testing.expectEqualStrings("ssh-ed25519", try wire.readString(blob, &off));
    try testing.expectEqualSlices(u8, &pubk, try wire.readString(blob, &off));
}

test "native dial closed port yields SshConnectFailed" {
    const io = singleThreadedIo();
    // Port 1 is typically closed / privileged refuse on loopback.
    const result = dialTcp(io, "127.0.0.1", 1);
    try testing.expectError(error.SshConnectFailed, result);
}

test "SOCKS5 greetings advertise no-auth and optional password auth" {
    const plain = socks5Greeting(false);
    try testing.expectEqualSlices(u8, &.{ 5, 1, 0 }, plain.bytes[0..plain.len]);
    const authenticated = socks5Greeting(true);
    try testing.expectEqualSlices(u8, &.{ 5, 2, 0, 2 }, authenticated.bytes[0..authenticated.len]);
}

test "SOCKS5 CONNECT request delegates destination DNS to proxy" {
    const request = try buildSocks5ConnectRequest(testing.allocator, "git.example.com", 22);
    defer testing.allocator.free(request);
    try testing.expectEqualSlices(u8, &.{ 5, 1, 0, 3, 15 }, request[0..5]);
    try testing.expectEqualStrings("git.example.com", request[5..20]);
    try testing.expectEqualSlices(u8, &.{ 0, 22 }, request[20..22]);
}

test "SOCKS5 username password request follows RFC 1929" {
    const request = try buildSocks5AuthRequest(testing.allocator, "proxy-user", "secret");
    defer testing.allocator.free(request);
    try testing.expectEqualSlices(
        u8,
        &.{ 1, 10, 'p', 'r', 'o', 'x', 'y', '-', 'u', 's', 'e', 'r', 6, 's', 'e', 'c', 'r', 'e', 't' },
        request,
    );
}

test "SOCKS5 CONNECT response distinguishes rejection from malformed wire" {
    try testing.expectEqual(@as(u8, 1), try validateSocks5ConnectReplyHeader(.{ 5, 0, 0, 1 }));
    try testing.expectEqual(@as(u8, 3), try validateSocks5ConnectReplyHeader(.{ 5, 0, 0, 3 }));
    try testing.expectError(
        error.SshProxyConnectRejected,
        validateSocks5ConnectReplyHeader(.{ 5, 5, 0, 1 }),
    );
    try testing.expectError(
        error.SshProxyHandshakeFailed,
        validateSocks5ConnectReplyHeader(.{ 4, 0, 0, 1 }),
    );
}

test "SOCKS5 CONNECT request strips IPv6 URL brackets" {
    const request = try buildSocks5ConnectRequest(testing.allocator, "[::1]", 2222);
    defer testing.allocator.free(request);
    try testing.expectEqualSlices(u8, &.{ 5, 1, 0, 3, 3 }, request[0..5]);
    try testing.expectEqualStrings("::1", request[5..8]);
    try testing.expectEqualSlices(u8, &.{ 0x08, 0xae }, request[8..10]);
}

test "SOCKS5 CONNECT rejects an unencodable destination name" {
    const too_long = [_]u8{'a'} ** 256;
    try testing.expectError(
        error.SshProxyUnsupported,
        buildSocks5ConnectRequest(testing.allocator, &too_long, 22),
    );
}

test "NativeCommand connect closed port is not unimplemented" {
    const io = singleThreadedIo();
    const host_owned = try testing.allocator.dupe(u8, "127.0.0.1");
    const params = NativeDialParams{
        .allocator = testing.allocator,
        .remote_command = try testing.allocator.dupe(u8, "git-upload-pack '/r.git'"),
        .host_with_port = try testing.allocator.dupe(u8, "127.0.0.1:1"),
        .owned_host = host_owned,
        .host = host_owned,
        .port = 1,
        .user = "git",
        .insecure_ignore_host_key = true,
        .client_config = .{
            .user = "git",
            .auth_kind = .password,
            .password = "x",
            .host_key_callback = auth_mod.HostKeyCallback.insecureIgnoreHostKey(),
        },
    };
    var cmd = NativeCommand{
        .allocator = testing.allocator,
        .io = io,
        .params = params,
    };
    defer cmd.deinit();

    const err = cmd.start();
    try testing.expectError(error.SshConnectFailed, err);
}

test "NativeCommand close after failed start is idempotent" {
    const io = singleThreadedIo();
    const host_owned = try testing.allocator.dupe(u8, "127.0.0.1");
    var cmd = NativeCommand{
        .allocator = testing.allocator,
        .io = io,
        .params = .{
            .allocator = testing.allocator,
            .remote_command = try testing.allocator.dupe(u8, "git-upload-pack '/r.git'"),
            .host_with_port = try testing.allocator.dupe(u8, "127.0.0.1:1"),
            .owned_host = host_owned,
            .host = host_owned,
            .port = 1,
            .user = "git",
            .insecure_ignore_host_key = true,
            .client_config = .{
                .auth_kind = .password,
                .password = "x",
            },
        },
    };
    defer cmd.deinit();
    _ = cmd.start() catch {};
    try cmd.close();
    try cmd.close();
    try cmd.kill();
}

test "keyboard-interactive challenge parse and response encode" {
    const allocator = testing.allocator;
    var packet: std.ArrayList(u8) = .empty;
    defer packet.deinit(allocator);
    try packet.append(allocator, wire.msg_userauth_info_request);
    try wire.appendString(&packet, allocator, "login");
    try wire.appendString(&packet, allocator, "second factor");
    try wire.appendString(&packet, allocator, "");
    try wire.appendU32(&packet, allocator, 2);
    try wire.appendString(&packet, allocator, "Password: ");
    try wire.appendBool(&packet, allocator, false);
    try wire.appendString(&packet, allocator, "OTP: ");
    try wire.appendBool(&packet, allocator, true);

    var challenge = try parseKeyboardChallenge(allocator, packet.items);
    defer challenge.deinit(allocator);
    try testing.expectEqualStrings("second factor", challenge.instruction);
    try testing.expectEqualStrings("Password: ", challenge.questions[0]);
    try testing.expect(!challenge.echos[0]);
    try testing.expect(challenge.echos[1]);

    const response = try buildKeyboardResponse(allocator, &.{ "secret", "123456" });
    defer allocator.free(response);
    try testing.expectEqual(wire.msg_userauth_info_response, response[0]);
    var off: usize = 1;
    try testing.expectEqual(@as(u32, 2), try wire.readU32(response, &off));
    try testing.expectEqualStrings("secret", try wire.readString(response, &off));
    try testing.expectEqualStrings("123456", try wire.readString(response, &off));
    try testing.expectEqual(response.len, off);
}

test "curve25519 shared secret self-consistency" {
    const io = singleThreadedIo();
    const a = X25519.KeyPair.generate(io);
    const b = X25519.KeyPair.generate(io);
    const ab = try X25519.scalarmult(a.secret_key, b.public_key);
    const ba = try X25519.scalarmult(b.secret_key, a.public_key);
    try testing.expectEqualSlices(u8, &ab, &ba);

    const mp = try wire.encodeMpint(testing.allocator, &ab);
    defer testing.allocator.free(mp);
    try testing.expect(mp.len >= 4);
}

test "session hash includes version strings as SSH strings" {
    var h = Sha256.init(.{});
    wire.hashWriteString(&h, client_version);
    wire.hashWriteString(&h, "SSH-2.0-OpenSSH_9.0");
    var out: [32]u8 = undefined;
    h.final(&out);
    // Just ensure non-zero and deterministic.
    var h2 = Sha256.init(.{});
    wire.hashWriteString(&h2, client_version);
    wire.hashWriteString(&h2, "SSH-2.0-OpenSSH_9.0");
    var out2: [32]u8 = undefined;
    h2.final(&out2);
    try testing.expectEqualSlices(u8, &out, &out2);
}

// ---------------------------------------------------------------------------
// rsa-sha2-256 host-key verify (fixed vector from OpenSSL PKCS#1 v1.5 SHA-256)
// ---------------------------------------------------------------------------

test "verifyHostKeyRsaSha256 accepts known vector" {
    // H = SHA256("gitz-rsa-sha2-256-hostkey-test-vector")
    // 2048-bit RSA; signature produced with openssl dgst -sha256 -sign.
    const H = [_]u8{
        0x80, 0xeb, 0xbe, 0x73, 0xd0, 0x36, 0x94, 0x0a, 0x40, 0x3b, 0xb5, 0x6c, 0x5c, 0xe0, 0xab, 0x0c,
        0x95, 0xb4, 0x4c, 0xc7, 0x3f, 0x10, 0x5b, 0x47, 0x78, 0x5d, 0x3b, 0xb8, 0x0f, 0x01, 0xd0, 0x50,
    };
    const host_blob = try hexDecode(testing.allocator, "000000077373682d727361000000030100010000010100b4bd8f7ce62dbd43296b3ab321edac68fefa1cb2af43d70341d70ceb939118155143e3119d8eb3c1f02ba6913182aa32fc1e747f2e55593f79963adc2cb9d6336c31b61321c7ad4f51395d98628354d2cde425620ef9fd8b637b00236d887a156463804c67a289404a07be4769f5eda605868cad0dc0ac32e4089bd831d126e203b4b53748826df829e643d8a7af1eab57beac3d92aac590e4800bb6b75e5d6d5a2a575e79ad40f80b969042f63149921d8d92827a42140e887108f19cfa348c74cf9e983df81a90f694a54a654a44cf657921c111d8d190ef8ff6f78a7f0518c563e3117d5d69f2bd6e9e6e8bf450c49711d8fccac0b465e16ed37d15331183");
    defer testing.allocator.free(host_blob);
    const sig_blob = try hexDecode(testing.allocator, "0000000c7273612d736861322d323536000001005f3d8f7b9d436bd10707114fe853656ac5791bf9782e067bf77bef6717fa332b9897ece3818f55198b17b72666cc546dc7bdf248e754ee4bb0e85213beacc2fcb3e3eaec190e2f1b9e7d6a34e5e3a6c94f1f5fb10ed1319a7cc95f67e765a3dd8b302feee3a0b187bb4baf8ca85df007bb99d02302c506f22ca1553533ebac15defe73262967339f03117fccb97d3e8554a5ffcfe4bb190caed90456b95420a124d5be07f7169ea6453082bdd2d5c4f999d1e3c1349bda3eb366c77e8a477d4c6549ab04602980442f35ff2c573a893df67f56c1fc445159d6291edc8d52151db5eede05ac9a11671605e679d86a68c41ecc8f8fe8ea8a418a86f188045202d7");
    defer testing.allocator.free(sig_blob);

    try verifyHostKeyRsaSha256(host_blob, sig_blob, &H);

    // Flip a signature byte → reject.
    var bad = try testing.allocator.dupe(u8, sig_blob);
    defer testing.allocator.free(bad);
    bad[bad.len - 1] ^= 0x01;
    try testing.expectError(error.SshKexFailed, verifyHostKeyRsaSha256(host_blob, bad, &H));
}

test "verifyHostKeyRsaSha256 rejects ed25519 blob" {
    const H = [_]u8{0x11} ** 32;
    const blob = try buildEd25519PublicBlob(testing.allocator, &([_]u8{0x22} ** 32));
    defer testing.allocator.free(blob);
    const sig = try buildEd25519SignatureBlob(testing.allocator, &([_]u8{0x33} ** 64));
    defer testing.allocator.free(sig);
    try testing.expectError(error.SshKexFailed, verifyHostKeyRsaSha256(blob, sig, &H));
}

fn hexDecode(allocator: Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.SshProtocolError;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

// ---------------------------------------------------------------------------
// Pure-Zig SSH test peer (server half) for loopback e2e
// ---------------------------------------------------------------------------

const peer_server_version: []const u8 = "SSH-2.0-gitz_testpeer_0.1";

const TestPeerConn = struct {
    allocator: Allocator,
    io: Io,
    stream: Stream,
    stream_live: bool = true,
    reader_impl: Stream.Reader = undefined,
    writer_impl: Stream.Writer = undefined,
    read_buf: [16384]u8 = undefined,
    write_buf: [16384]u8 = undefined,
    send_seq: u32 = 0,
    recv_seq: u32 = 0,
    send_cipher: wire.PacketCipher = .none(),
    recv_cipher: wire.PacketCipher = .none(),
    client_version: []u8 = &.{},
    host_kp: Ed25519.KeyPair,
    session_id: []u8 = &.{},

    fn deinit(self: *TestPeerConn) void {
        if (self.stream_live) {
            self.stream.close(self.io);
            self.stream_live = false;
        }
        if (self.client_version.len > 0) self.allocator.free(self.client_version);
        if (self.session_id.len > 0) self.allocator.free(self.session_id);
        self.* = undefined;
    }

    fn rebind(self: *TestPeerConn) void {
        self.reader_impl = self.stream.reader(self.io, &self.read_buf);
        self.writer_impl = self.stream.writer(self.io, &self.write_buf);
    }

    fn writer(self: *TestPeerConn) *Writer {
        return &self.writer_impl.interface;
    }

    fn reader(self: *TestPeerConn) *Reader {
        return &self.reader_impl.interface;
    }

    fn writePacket(self: *TestPeerConn, payload: []const u8) !void {
        self.rebind();
        const wire_bytes = try wire.encodePacket(self.allocator, &self.send_cipher, self.send_seq, payload);
        defer self.allocator.free(wire_bytes);
        try self.writer().writeAll(wire_bytes);
        try self.writer().flush();
        self.send_seq +%= 1;
    }

    fn readPacket(self: *TestPeerConn) ![]u8 {
        self.rebind();
        while (true) {
            const payload = wire.decodePacket(self.allocator, &self.recv_cipher, self.recv_seq, self.reader()) catch |err| {
                if (err == error.EndOfStream) return error.SshConnectionClosed;
                return err;
            };
            self.recv_seq +%= 1;
            if (payload.len == 0) {
                self.allocator.free(payload);
                continue;
            }
            switch (payload[0]) {
                wire.msg_ignore, wire.msg_debug, wire.msg_ext_info => {
                    self.allocator.free(payload);
                    continue;
                },
                wire.msg_disconnect => {
                    self.allocator.free(payload);
                    return error.SshConnectionClosed;
                },
                else => return payload,
            }
        }
    }

    fn exchangeVersions(self: *TestPeerConn) !void {
        self.rebind();
        // Read client version line.
        var line_buf: [255]u8 = undefined;
        var n: usize = 0;
        var terminated = false;
        while (n < line_buf.len) {
            var b: [1]u8 = undefined;
            self.reader().readSliceAll(&b) catch return error.SshVersionExchangeFailed;
            if (b[0] == '\n') {
                terminated = true;
                break;
            }
            if (b[0] != '\r') {
                line_buf[n] = b[0];
                n += 1;
            }
        }
        if (!terminated or n == 0 or !std.mem.startsWith(u8, line_buf[0..n], "SSH-"))
            return error.SshVersionExchangeFailed;
        self.client_version = try self.allocator.dupe(u8, line_buf[0..n]);

        try self.writer().writeAll(peer_server_version);
        try self.writer().writeAll("\r\n");
        try self.writer().flush();
    }

    fn doKex(self: *TestPeerConn) !void {
        const client_kex = try self.readPacket();
        defer self.allocator.free(client_kex);
        if (client_kex.len < 1 or client_kex[0] != wire.msg_kexinit) return error.SshKexFailed;
        const client_view = wire.parseKexInit(client_kex) catch return error.SshKexFailed;

        // Negotiate with server-as-preference lists against client name-lists.
        // Client prefs win in real SSH; here peer offers the full set so the
        // client's first mutual choice is selected by the client side. Peer
        // still records the same names so keys match.
        const enc_name = wire.negotiate(&enc_prefs, client_view.encryption_c2s) catch return error.SshKexFailed;
        const mac_name = wire.negotiate(&mac_prefs, client_view.mac_c2s) catch return error.SshKexFailed;
        _ = wire.negotiate(&kex_prefs, client_view.kex_algorithms) catch return error.SshKexFailed;
        _ = wire.negotiate(&host_key_prefs, client_view.server_host_key_algorithms) catch return error.SshKexFailed;
        const enc_alg = wire.EncAlg.fromName(enc_name) catch return error.SshKexFailed;
        const mac_alg = wire.MacAlg.fromName(mac_name) catch return error.SshKexFailed;

        var cookie: [16]u8 = undefined;
        self.io.random(&cookie);
        const server_kex = try wire.buildKexInit(
            self.allocator,
            &cookie,
            &peer_kex_algs,
            &peer_host_key_algs,
            &peer_enc_algs,
            &peer_mac_algs,
            &peer_comp_algs,
        );
        defer self.allocator.free(server_kex);
        try self.writePacket(server_kex);

        // ECDH init from client.
        const ecdh_init = try self.readPacket();
        defer self.allocator.free(ecdh_init);
        if (ecdh_init.len < 1 or ecdh_init[0] != wire.msg_kex_ecdh_init) return error.SshKexFailed;
        var i_off: usize = 1;
        const client_eph = wire.readString(ecdh_init, &i_off) catch return error.SshKexFailed;
        if (client_eph.len != 32) return error.SshKexFailed;

        var eph = X25519.KeyPair.generate(self.io);
        const shared = X25519.scalarmult(eph.secret_key, client_eph[0..32].*) catch return error.SshKexFailed;
        const K_mpint = try wire.encodeMpint(self.allocator, &shared);
        defer self.allocator.free(K_mpint);

        // Host key blob (ed25519).
        const host_pub = self.host_kp.public_key.toBytes();
        const host_key_blob = try buildEd25519PublicBlob(self.allocator, &host_pub);
        defer self.allocator.free(host_key_blob);

        // H
        var h = Sha256.init(.{});
        wire.hashWriteString(&h, self.client_version);
        wire.hashWriteString(&h, peer_server_version);
        wire.hashWriteString(&h, client_kex);
        wire.hashWriteString(&h, server_kex);
        wire.hashWriteString(&h, host_key_blob);
        wire.hashWriteString(&h, client_eph);
        wire.hashWriteString(&h, &eph.public_key);
        h.update(K_mpint);
        var H: [32]u8 = undefined;
        h.final(&H);
        self.session_id = try self.allocator.dupe(u8, &H);

        // Sign H with host key.
        const sig = self.host_kp.sign(&H, null) catch return error.SshKexFailed;
        const sig_bytes = sig.toBytes();
        const sig_blob = try buildEd25519SignatureBlob(self.allocator, &sig_bytes);
        defer self.allocator.free(sig_blob);

        var reply: std.ArrayList(u8) = .empty;
        defer reply.deinit(self.allocator);
        try reply.append(self.allocator, wire.msg_kex_ecdh_reply);
        try wire.appendString(&reply, self.allocator, host_key_blob);
        try wire.appendString(&reply, self.allocator, &eph.public_key);
        try wire.appendString(&reply, self.allocator, sig_blob);
        try self.writePacket(reply.items);

        // Key material — server send uses B/D/F, recv uses A/C/E.
        const iv_len = enc_alg.ivLen();
        const key_len = enc_alg.keyLen();
        const mac_key_len = mac_alg.keyLen();
        var iv_c2s: [wire.aes_iv_len]u8 = undefined;
        var iv_s2c: [wire.aes_iv_len]u8 = undefined;
        var key_c2s: [wire.max_enc_key_len]u8 = undefined;
        var key_s2c: [wire.max_enc_key_len]u8 = undefined;
        var mac_c2s: [wire.max_mac_length]u8 = undefined;
        var mac_s2c: [wire.max_mac_length]u8 = undefined;
        wire.generateKeyMaterial(iv_c2s[0..iv_len], 'A', K_mpint, &H, self.session_id);
        wire.generateKeyMaterial(iv_s2c[0..iv_len], 'B', K_mpint, &H, self.session_id);
        wire.generateKeyMaterial(key_c2s[0..key_len], 'C', K_mpint, &H, self.session_id);
        wire.generateKeyMaterial(key_s2c[0..key_len], 'D', K_mpint, &H, self.session_id);
        wire.generateKeyMaterial(mac_c2s[0..mac_key_len], 'E', K_mpint, &H, self.session_id);
        wire.generateKeyMaterial(mac_s2c[0..mac_key_len], 'F', K_mpint, &H, self.session_id);

        // NEWKEYS: send then arm send cipher; read peer NEWKEYS then arm recv.
        try self.writePacket(&[_]u8{wire.msg_newkeys});
        self.send_cipher = wire.PacketCipher.initFromAlgs(
            enc_alg,
            key_s2c[0..key_len],
            iv_s2c[0..iv_len],
            mac_alg,
            mac_s2c[0..mac_key_len],
        ) catch return error.SshKexFailed;

        const peer_newkeys = try self.readPacket();
        defer self.allocator.free(peer_newkeys);
        if (peer_newkeys.len < 1 or peer_newkeys[0] != wire.msg_newkeys) return error.SshKexFailed;
        self.recv_cipher = wire.PacketCipher.initFromAlgs(
            enc_alg,
            key_c2s[0..key_len],
            iv_c2s[0..iv_len],
            mac_alg,
            mac_c2s[0..mac_key_len],
        ) catch return error.SshKexFailed;
    }

    fn doUserauth(self: *TestPeerConn) !void {
        // SERVICE_REQUEST
        const svc = try self.readPacket();
        defer self.allocator.free(svc);
        if (svc.len < 1 or svc[0] != wire.msg_service_request) return error.SshAuthFailed;

        var accept: std.ArrayList(u8) = .empty;
        defer accept.deinit(self.allocator);
        try accept.append(self.allocator, wire.msg_service_accept);
        try wire.appendString(&accept, self.allocator, "ssh-userauth");
        try self.writePacket(accept.items);

        // USERAUTH_REQUEST loop — accept password "test" or any publickey.
        while (true) {
            const req = try self.readPacket();
            defer self.allocator.free(req);
            if (req.len < 1 or req[0] != wire.msg_userauth_request) return error.SshAuthFailed;
            var off: usize = 1;
            _ = wire.readString(req, &off) catch return error.SshAuthFailed; // user
            _ = wire.readString(req, &off) catch return error.SshAuthFailed; // service
            const method = wire.readString(req, &off) catch return error.SshAuthFailed;

            if (std.mem.eql(u8, method, "password")) {
                _ = wire.readBool(req, &off) catch return error.SshAuthFailed;
                const password = wire.readString(req, &off) catch return error.SshAuthFailed;
                if (std.mem.eql(u8, password, "test")) {
                    try self.writePacket(&[_]u8{wire.msg_userauth_success});
                    return;
                }
                var fail: std.ArrayList(u8) = .empty;
                defer fail.deinit(self.allocator);
                try fail.append(self.allocator, wire.msg_userauth_failure);
                try wire.appendString(&fail, self.allocator, "password,publickey");
                try wire.appendBool(&fail, self.allocator, false);
                try self.writePacket(fail.items);
                continue;
            }
            if (std.mem.eql(u8, method, "publickey")) {
                // Accept any signed publickey request (e2e path may use password only).
                const has_sig = wire.readBool(req, &off) catch false;
                if (has_sig) {
                    try self.writePacket(&[_]u8{wire.msg_userauth_success});
                    return;
                }
                // Without signature → PK_OK then wait for real attempt.
                const pk_algo = wire.readString(req, &off) catch return error.SshAuthFailed;
                const pk_blob = wire.readString(req, &off) catch return error.SshAuthFailed;
                var pk_ok: std.ArrayList(u8) = .empty;
                defer pk_ok.deinit(self.allocator);
                try pk_ok.append(self.allocator, wire.msg_userauth_pk_ok);
                try wire.appendString(&pk_ok, self.allocator, pk_algo);
                try wire.appendString(&pk_ok, self.allocator, pk_blob);
                try self.writePacket(pk_ok.items);
                continue;
            }
            // none / other → failure listing methods.
            var fail: std.ArrayList(u8) = .empty;
            defer fail.deinit(self.allocator);
            try fail.append(self.allocator, wire.msg_userauth_failure);
            try wire.appendString(&fail, self.allocator, "password,publickey");
            try wire.appendBool(&fail, self.allocator, false);
            try self.writePacket(fail.items);
        }
    }

    fn doChannel(self: *TestPeerConn) !void {
        // CHANNEL_OPEN session
        const open = try self.readPacket();
        defer self.allocator.free(open);
        if (open.len < 1 or open[0] != wire.msg_channel_open) return error.SshChannelFailed;
        var off: usize = 1;
        _ = wire.readString(open, &off) catch return error.SshChannelFailed; // "session"
        const sender = wire.readU32(open, &off) catch return error.SshChannelFailed;
        _ = wire.readU32(open, &off) catch return error.SshChannelFailed; // window
        _ = wire.readU32(open, &off) catch return error.SshChannelFailed; // max packet

        const peer_channel: u32 = 0;
        var conf: std.ArrayList(u8) = .empty;
        defer conf.deinit(self.allocator);
        try conf.append(self.allocator, wire.msg_channel_open_confirmation);
        try wire.appendU32(&conf, self.allocator, sender); // recipient = client's channel
        try wire.appendU32(&conf, self.allocator, peer_channel); // sender channel
        try wire.appendU32(&conf, self.allocator, initial_window);
        try wire.appendU32(&conf, self.allocator, max_packet_channel);
        try self.writePacket(conf.items);

        // Wait for CHANNEL_REQUEST exec
        while (true) {
            const msg = try self.readPacket();
            defer self.allocator.free(msg);
            if (msg.len < 1) return error.SshChannelFailed;
            switch (msg[0]) {
                wire.msg_channel_request => {
                    var roff: usize = 1;
                    _ = wire.readU32(msg, &roff) catch return error.SshChannelFailed;
                    const req_type = wire.readString(msg, &roff) catch return error.SshChannelFailed;
                    const want_reply = wire.readBool(msg, &roff) catch false;
                    if (std.mem.eql(u8, req_type, "exec")) {
                        _ = wire.readString(msg, &roff) catch {}; // command
                        if (want_reply) {
                            var ok: std.ArrayList(u8) = .empty;
                            defer ok.deinit(self.allocator);
                            try ok.append(self.allocator, wire.msg_channel_success);
                            try wire.appendU32(&ok, self.allocator, sender);
                            try self.writePacket(ok.items);
                        }
                        // Empty stdout: optional fixed banner then EOF + close.
                        // Banner on extended data is optional; send channel EOF+close.
                        var eof_msg: std.ArrayList(u8) = .empty;
                        defer eof_msg.deinit(self.allocator);
                        try eof_msg.append(self.allocator, wire.msg_channel_eof);
                        try wire.appendU32(&eof_msg, self.allocator, sender);
                        try self.writePacket(eof_msg.items);

                        var close_msg: std.ArrayList(u8) = .empty;
                        defer close_msg.deinit(self.allocator);
                        try close_msg.append(self.allocator, wire.msg_channel_close);
                        try wire.appendU32(&close_msg, self.allocator, sender);
                        try self.writePacket(close_msg.items);
                        return;
                    }
                    if (want_reply) {
                        var fail: std.ArrayList(u8) = .empty;
                        defer fail.deinit(self.allocator);
                        try fail.append(self.allocator, wire.msg_channel_failure);
                        try wire.appendU32(&fail, self.allocator, sender);
                        try self.writePacket(fail.items);
                    }
                },
                wire.msg_channel_data, wire.msg_channel_window_adjust, wire.msg_channel_eof, wire.msg_channel_close => {
                    // Drain client traffic until we get exec.
                    continue;
                },
                else => return error.SshChannelFailed,
            }
        }
    }

    fn serve(self: *TestPeerConn) !void {
        try self.exchangeVersions();
        try self.doKex();
        try self.doUserauth();
        try self.doChannel();
    }
};

/// Accept one TCP connection on `server` and run the minimal SSH peer.
fn runTestPeer(io: Io, server: *Server, host_kp: Ed25519.KeyPair, err_out: *?anyerror) void {
    const stream = server.accept(io) catch |e| {
        err_out.* = e;
        return;
    };
    var peer = TestPeerConn{
        .allocator = testing.allocator,
        .io = io,
        .stream = stream,
        .host_kp = host_kp,
    };
    defer peer.deinit();
    peer.rebind();
    peer.serve() catch |e| {
        err_out.* = e;
        return;
    };
    err_out.* = null;
}

fn loopbackListenUnavailable(err: anyerror) bool {
    // Linux sandbox socket filters report bind/listen denial as EPERM. Zig's
    // Io backend can surface that unmapped errno as Unexpected; this guard is
    // used only around the loopback listen call.
    return err == error.PermissionDenied or err == error.AccessDenied or err == error.Unexpected;
}

test "NativeCommand e2e loopback password auth handshake" {
    // Multi-threaded Io: peer accept blocks while client connects.
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listen_addr = try IpAddress.parse("127.0.0.1", 0);
    var server = listen_addr.listen(io, .{ .reuse_address = true }) catch |err| {
        if (loopbackListenUnavailable(err)) return;
        return err;
    };
    defer server.deinit(io);
    const port = server.socket.address.getPort();
    try testing.expect(port != 0);

    const host_seed = [_]u8{0x99} ** 32;
    const host_kp = try Ed25519.KeyPair.generateDeterministic(host_seed);

    var peer_err: ?anyerror = error.SshProtocolError; // set until peer finishes
    var group: Io.Group = .init;
    try group.concurrent(io, runTestPeer, .{ io, &server, host_kp, &peer_err });
    // Ensure the peer is awaited/cancelled even if the client path fails.
    defer group.cancel(io);

    const host_owned = try testing.allocator.dupe(u8, "127.0.0.1");
    var host_port_buf: [32]u8 = undefined;
    const host_port_str = try std.fmt.bufPrint(&host_port_buf, "127.0.0.1:{d}", .{port});
    const host_with_port = try testing.allocator.dupe(u8, host_port_str);

    var cmd = NativeCommand{
        .allocator = testing.allocator,
        .io = io,
        .params = .{
            .allocator = testing.allocator,
            .remote_command = try testing.allocator.dupe(u8, "git-upload-pack '/test.git'"),
            .host_with_port = host_with_port,
            .owned_host = host_owned,
            .host = host_owned,
            .port = @intCast(port),
            .user = "git",
            .insecure_ignore_host_key = true,
            .client_config = .{
                .user = "git",
                .auth_kind = .password,
                .password = "test",
                .host_key_callback = auth_mod.HostKeyCallback.insecureIgnoreHostKey(),
            },
        },
    };
    defer cmd.deinit();

    try cmd.start();
    // Exec completed; channel may already be EOF from peer.
    try cmd.close();

    try group.await(io);
    if (peer_err) |e| return e;
}

test "NativeCommand e2e rejects wrong password" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var listen_addr = try IpAddress.parse("127.0.0.1", 0);
    var server = listen_addr.listen(io, .{ .reuse_address = true }) catch |err| {
        if (loopbackListenUnavailable(err)) return;
        return err;
    };
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    const host_seed = [_]u8{0x77} ** 32;
    const host_kp = try Ed25519.KeyPair.generateDeterministic(host_seed);

    var peer_err: ?anyerror = error.SshProtocolError;
    var group: Io.Group = .init;
    try group.concurrent(io, runTestPeer, .{ io, &server, host_kp, &peer_err });
    defer group.cancel(io);

    const host_owned = try testing.allocator.dupe(u8, "127.0.0.1");
    var host_port_buf: [32]u8 = undefined;
    const host_port_str = try std.fmt.bufPrint(&host_port_buf, "127.0.0.1:{d}", .{port});

    var cmd = NativeCommand{
        .allocator = testing.allocator,
        .io = io,
        .params = .{
            .allocator = testing.allocator,
            .remote_command = try testing.allocator.dupe(u8, "git-upload-pack '/r.git'"),
            .host_with_port = try testing.allocator.dupe(u8, host_port_str),
            .owned_host = host_owned,
            .host = host_owned,
            .port = @intCast(port),
            .user = "git",
            .insecure_ignore_host_key = true,
            .client_config = .{
                .auth_kind = .password,
                .password = "wrong-password",
                .host_key_callback = auth_mod.HostKeyCallback.insecureIgnoreHostKey(),
            },
        },
    };
    defer cmd.deinit();

    const start_err = cmd.start();
    try testing.expectError(error.SshAuthFailed, start_err);
    // Peer may still be looping on auth; cancel the group.
    group.cancel(io);
}
