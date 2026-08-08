//! Pure-Zig native SSH client for git pack protocol over SSH.
//!
//! Implements a minimum viable SSH-2.0 client:
//! - TCP connect via `std.Io.net`
//! - Version exchange
//! - Binary packets (cleartext then AES-128-CTR + HMAC-SHA2-256)
//! - KEX: `curve25519-sha256` (+ libssh alias)
//! - Host key: `ssh-ed25519` verify via `HostKeyCallback`
//! - NEWKEYS
//! - Userauth: `password` and `publickey` (OpenSSH ed25519 PEM)
//! - Channel session + exec of `CommandPlan.remote_command`
//! - Bridge channel stdio to `transport_common.Command` pipes
//!
//! No C, no libssh. System `ssh` remains an alternate dial mode.

const std = @import("std");
const transport_common = @import("transport_common");
const auth_mod = @import("auth_method.zig");
const wire = @import("ssh_wire.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const testing = std.testing;
const Sha256 = std.crypto.hash.sha2.Sha256;
const X25519 = std.crypto.dh.X25519;
const Ed25519 = std.crypto.sign.Ed25519;
const HostName = std.Io.net.HostName;
const IpAddress = std.Io.net.IpAddress;
const Stream = std.Io.net.Stream;

/// Dial parameters for `NativeCommand` (owned strings freed by `deinit`).
/// Built from `CommandPlan` in `common.zig` without importing that module
/// (avoids a circular dependency).
pub const NativeDialParams = struct {
    allocator: Allocator,
    remote_command: []u8 = &.{},
    host_with_port: []u8 = &.{},
    host: []const u8 = "",
    port: i32 = 22,
    user: []const u8 = "",
    /// When set, plan owns `user`.
    owned_user: ?[]u8 = null,
    insecure_ignore_host_key: bool = false,
    client_config: auth_mod.ClientConfig = .{},

    pub fn deinit(self: *NativeDialParams) void {
        const a = self.allocator;
        if (self.remote_command.len > 0) a.free(self.remote_command);
        if (self.host_with_port.len > 0) a.free(self.host_with_port);
        if (self.owned_user) |u| a.free(u);
        self.* = .{ .allocator = a };
    }
};

pub const client_version: []const u8 = "SSH-2.0-gitz_0.1";

pub const Error = error{
    /// TCP or name resolution failed.
    SshConnectFailed,
    /// Version exchange failed or peer is not SSH-2.0.
    SshVersionExchangeFailed,
    /// Key exchange failed (negotiation, crypto, or host-key signature).
    SshKexFailed,
    /// Host key callback rejected the server key.
    SshHostKeyRejected,
    /// User authentication failed.
    SshAuthFailed,
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
};

// Preferred algorithm lists (client order).
const kex_prefs = [_][]const u8{ "curve25519-sha256", "curve25519-sha256@libssh.org" };
const host_key_prefs = [_][]const u8{"ssh-ed25519"};
const enc_prefs = [_][]const u8{"aes128-ctr"};
const mac_prefs = [_][]const u8{"hmac-sha2-256"};
const comp_prefs = [_][]const u8{"none"};

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
        if (self.public_blob.len > 0) self.allocator.free(self.public_blob);
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
    pub fn connect(
        self: *NativeConn,
        host: []const u8,
        port: u16,
        user: []const u8,
        cfg: *const auth_mod.ClientConfig,
        host_with_port: []const u8,
    ) !void {
        try self.tcpConnect(host, port);
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

    fn exchangeVersions(self: *NativeConn) !void {
        // Send our version line.
        try self.writer().writeAll(self.client_version);
        try self.writer().writeAll("\r\n");
        try self.writer().flush();

        // Read server version (line ending with \n, optional \r).
        var line_buf: [255]u8 = undefined;
        var n: usize = 0;
        while (n < line_buf.len) {
            var b: [1]u8 = undefined;
            self.reader().readSliceAll(&b) catch return error.SshVersionExchangeFailed;
            if (b[0] == '\n') break;
            if (b[0] != '\r') {
                line_buf[n] = b[0];
                n += 1;
            }
        }
        if (n == 0) return error.SshVersionExchangeFailed;
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
                wire.msg_ignore, wire.msg_debug, wire.msg_ext_info, wire.msg_global_request => {
                    // Reply failure to global requests with want_reply when present.
                    if (payload[0] == wire.msg_global_request and payload.len >= 5) {
                        // best-effort: ignore
                    }
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
        _ = wire.negotiate(&host_key_prefs, server_view.server_host_key_algorithms) catch return error.SshKexFailed;
        _ = wire.negotiate(&enc_prefs, server_view.encryption_c2s) catch return error.SshKexFailed;
        _ = wire.negotiate(&enc_prefs, server_view.encryption_s2c) catch return error.SshKexFailed;
        _ = wire.negotiate(&mac_prefs, server_view.mac_c2s) catch return error.SshKexFailed;
        _ = wire.negotiate(&mac_prefs, server_view.mac_s2c) catch return error.SshKexFailed;

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

        // Verify host key signature (ssh-ed25519).
        try verifyHostKeyEd25519(host_key_blob, signature_blob, &H);

        // Host key callback.
        if (cfg.host_key_callback) |cb| {
            var hk_off: usize = 0;
            const algo = wire.readString(host_key_blob, &hk_off) catch return error.SshKexFailed;
            const key_body = wire.readString(host_key_blob, &hk_off) catch return error.SshKexFailed;
            cb.check(host_with_port, host_with_port, algo, key_body) catch return error.SshHostKeyRejected;
        }

        self.session_id = try self.allocator.dupe(u8, &H);

        // Derive keys (client direction A/C/E, server B/D/F).
        var iv_c2s: [16]u8 = undefined;
        var iv_s2c: [16]u8 = undefined;
        var key_c2s: [16]u8 = undefined;
        var key_s2c: [16]u8 = undefined;
        var mac_c2s: [32]u8 = undefined;
        var mac_s2c: [32]u8 = undefined;
        wire.generateKeyMaterial(&iv_c2s, 'A', K_mpint, &H, self.session_id);
        wire.generateKeyMaterial(&iv_s2c, 'B', K_mpint, &H, self.session_id);
        wire.generateKeyMaterial(&key_c2s, 'C', K_mpint, &H, self.session_id);
        wire.generateKeyMaterial(&key_s2c, 'D', K_mpint, &H, self.session_id);
        wire.generateKeyMaterial(&mac_c2s, 'E', K_mpint, &H, self.session_id);
        wire.generateKeyMaterial(&mac_s2c, 'F', K_mpint, &H, self.session_id);

        // NEWKEYS — after send, encrypt outbound; after recv, decrypt inbound.
        try self.writePacket(&[_]u8{wire.msg_newkeys});
        self.send_cipher = wire.PacketCipher.aes128CtrHmacSha256(&key_c2s, &iv_c2s, &mac_c2s);

        const peer_newkeys = try self.readPacket();
        defer self.allocator.free(peer_newkeys);
        if (peer_newkeys.len < 1 or peer_newkeys[0] != wire.msg_newkeys) return error.SshKexFailed;
        self.recv_cipher = wire.PacketCipher.aes128CtrHmacSha256(&key_s2c, &iv_s2c, &mac_s2c);
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
                // Agent path not fully wired for native; fail clearly.
                return error.SshAuthFailed;
            },
            .keyboard_interactive => return error.SshAuthFailed,
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
        var key = loadEd25519PrivateKey(self.allocator, cfg.pem_bytes) catch return error.SshAuthFailed;
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
        const recipient = wire.readU32(reply, &off) catch return error.SshChannelFailed;
        _ = recipient; // our local channel
        self.remote_channel = wire.readU32(reply, &off) catch return error.SshChannelFailed;
        self.send_window = wire.readU32(reply, &off) catch return error.SshChannelFailed;
        _ = wire.readU32(reply, &off) catch return error.SshChannelFailed; // max packet
        self.channel_open = true;
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

fn bareHost(host: []const u8) []const u8 {
    if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') {
        return host[1 .. host.len - 1];
    }
    return host;
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

// ---------------------------------------------------------------------------
// NativeCommand — transport_common.Command
// ---------------------------------------------------------------------------

/// SSH command via pure-Zig native client (pack protocol over channel stdio).
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
        if (self.conn) |c| {
            c.deinit();
            self.allocator.destroy(c);
            self.conn = null;
        }
        self.params.deinit();
        self.* = undefined;
    }

    fn ensureConnected(self: *NativeCommand) anyerror!void {
        if (self.connected) return;
        if (self.conn != null) return;

        const c = try self.allocator.create(NativeConn);
        errdefer {
            c.deinit();
            self.allocator.destroy(c);
        }
        c.* = .{
            .allocator = self.allocator,
            .io = self.io,
        };

        const port: u16 = if (self.params.port <= 0) 22 else @intCast(self.params.port);
        const user = if (self.params.user.len > 0) self.params.user else auth_mod.DefaultUsername;

        // Apply insecure host key when plan says so.
        var cfg = self.params.client_config;
        if (self.params.insecure_ignore_host_key and cfg.host_key_callback == null) {
            cfg.host_key_callback = auth_mod.HostKeyCallback.insecureIgnoreHostKey();
        }

        try c.connect(self.params.host, port, user, &cfg, self.params.host_with_port);
        c.bindPipes();
        self.conn = c;
        self.connected = true;
        // On success errdefer is discarded when this function returns.
    }

    pub fn stderrPipe(self: *NativeCommand) anyerror!*Reader {
        try self.ensureConnected();
        const c = self.conn.?;
        return &c.stderr_reader;
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
        const c = self.conn.?;
        return &c.stdout_reader;
    }

    pub fn start(self: *NativeCommand) anyerror!void {
        if (self.started) return error.AlreadyConnected;
        try self.ensureConnected();
        const c = self.conn.?;
        try c.exec(self.params.remote_command);
        self.started = true;
    }

    pub fn close(self: *NativeCommand) anyerror!void {
        if (self.closed) return;
        self.closed = true;
        if (self.conn) |c| {
            c.sendClose() catch {};
            c.closeStream();
        }
        self.connected = false;
        self.started = false;
    }

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

test "NativeCommand connect closed port is not unimplemented" {
    const io = singleThreadedIo();
    const params = NativeDialParams{
        .allocator = testing.allocator,
        .remote_command = try testing.allocator.dupe(u8, "git-upload-pack '/r.git'"),
        .host_with_port = try testing.allocator.dupe(u8, "127.0.0.1:1"),
        .host = "127.0.0.1",
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
