//! SSH binary wire encoding and packet framing (RFC 4253).
//!
//! Pure Zig — no C, no libssh. Used by `native_ssh.zig` for the in-process
//! SSH client that drives git-upload-pack / git-receive-pack.
//!
//! Packet encryption: AES-128-CTR and AES-256-CTR (non-EtM).
//! Packet MAC: HMAC-SHA2-256 and HMAC-SHA2-512 (RFC 6668).

const std = @import("std");
const testing = std.testing;

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const HmacSha512 = std.crypto.auth.hmac.sha2.HmacSha512;
const Aes128 = std.crypto.core.aes.Aes128;
const Aes256 = std.crypto.core.aes.Aes256;
const AesEncryptCtx = std.crypto.core.aes.AesEncryptCtx;

// ---------------------------------------------------------------------------
// Message numbers (RFC 4253 / 4252 / 4254)
// ---------------------------------------------------------------------------

pub const msg_disconnect: u8 = 1;
pub const msg_ignore: u8 = 2;
pub const msg_unimplemented: u8 = 3;
pub const msg_debug: u8 = 4;
pub const msg_service_request: u8 = 5;
pub const msg_service_accept: u8 = 6;
pub const msg_ext_info: u8 = 7;
pub const msg_kexinit: u8 = 20;
pub const msg_newkeys: u8 = 21;
pub const msg_kex_ecdh_init: u8 = 30;
pub const msg_kex_ecdh_reply: u8 = 31;
pub const msg_userauth_request: u8 = 50;
pub const msg_userauth_failure: u8 = 51;
pub const msg_userauth_success: u8 = 52;
pub const msg_userauth_banner: u8 = 53;
pub const msg_userauth_pk_ok: u8 = 60;
/// Method-specific keyboard-interactive messages (RFC 4256). Message 60 is
/// shared with public-key PK_OK and is disambiguated by the active method.
pub const msg_userauth_info_request: u8 = 60;
pub const msg_userauth_info_response: u8 = 61;
pub const msg_global_request: u8 = 80;
pub const msg_request_success: u8 = 81;
pub const msg_request_failure: u8 = 82;
pub const msg_channel_open: u8 = 90;
pub const msg_channel_open_confirmation: u8 = 91;
pub const msg_channel_open_failure: u8 = 92;
pub const msg_channel_window_adjust: u8 = 93;
pub const msg_channel_data: u8 = 94;
pub const msg_channel_extended_data: u8 = 95;
pub const msg_channel_eof: u8 = 96;
pub const msg_channel_close: u8 = 97;
pub const msg_channel_request: u8 = 98;
pub const msg_channel_success: u8 = 99;
pub const msg_channel_failure: u8 = 100;

pub const max_packet: usize = 256 * 1024;
pub const packet_block: usize = 16;
pub const max_mac_length: usize = 64; // hmac-sha2-512
pub const max_enc_key_len: usize = 32; // aes256-ctr
pub const aes_iv_len: usize = 16;
pub const aes128_key_len: usize = 16;
pub const aes256_key_len: usize = 32;
pub const hmac_sha256_key_len: usize = 32;
pub const hmac_sha512_key_len: usize = 64;

/// Legacy alias (hmac-sha2-256 digest size). Prefer `MacAlg.digestLen`.
pub const mac_length: usize = 32;
pub const aes128_iv_len: usize = 16;
pub const hmac_key_len: usize = 32;

pub const Error = error{
    /// Packet framing invalid (length, padding, or MAC).
    SshPacketCorrupt,
    /// Packet larger than allowed max.
    SshPacketTooLarge,
    /// MAC verification failed.
    SshMacFailure,
    /// Unexpected or unsupported message type.
    SshProtocolError,
    /// Name-list negotiation found no common algorithm.
    SshNoCommonAlgorithm,
    /// Negotiated algorithm name is not implemented.
    SshUnsupportedAlgorithm,
};

// ---------------------------------------------------------------------------
// Algorithm enums (client + peer)
// ---------------------------------------------------------------------------

pub const EncAlg = enum {
    none,
    aes128_ctr,
    aes256_ctr,

    pub fn fromName(alg_name: []const u8) Error!EncAlg {
        if (std.mem.eql(u8, alg_name, "aes128-ctr")) return .aes128_ctr;
        if (std.mem.eql(u8, alg_name, "aes256-ctr")) return .aes256_ctr;
        return error.SshUnsupportedAlgorithm;
    }

    pub fn name(self: EncAlg) []const u8 {
        return switch (self) {
            .none => "none",
            .aes128_ctr => "aes128-ctr",
            .aes256_ctr => "aes256-ctr",
        };
    }

    pub fn keyLen(self: EncAlg) usize {
        return switch (self) {
            .none => 0,
            .aes128_ctr => aes128_key_len,
            .aes256_ctr => aes256_key_len,
        };
    }

    pub fn ivLen(self: EncAlg) usize {
        return switch (self) {
            .none => 0,
            .aes128_ctr, .aes256_ctr => aes_iv_len,
        };
    }
};

pub const MacAlg = enum {
    none,
    hmac_sha2_256,
    hmac_sha2_512,

    pub fn fromName(alg_name: []const u8) Error!MacAlg {
        if (std.mem.eql(u8, alg_name, "hmac-sha2-256")) return .hmac_sha2_256;
        if (std.mem.eql(u8, alg_name, "hmac-sha2-512")) return .hmac_sha2_512;
        return error.SshUnsupportedAlgorithm;
    }

    pub fn name(self: MacAlg) []const u8 {
        return switch (self) {
            .none => "none",
            .hmac_sha2_256 => "hmac-sha2-256",
            .hmac_sha2_512 => "hmac-sha2-512",
        };
    }

    pub fn keyLen(self: MacAlg) usize {
        return switch (self) {
            .none => 0,
            .hmac_sha2_256 => hmac_sha256_key_len,
            .hmac_sha2_512 => hmac_sha512_key_len,
        };
    }

    pub fn digestLen(self: MacAlg) usize {
        return self.keyLen();
    }
};

// ---------------------------------------------------------------------------
// SSH string / name-list / uint helpers
// ---------------------------------------------------------------------------

/// Append a uint32 big-endian.
pub fn appendU32(list: *std.ArrayList(u8), allocator: Allocator, v: u32) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .big);
    try list.appendSlice(allocator, &buf);
}

/// Append an SSH string (uint32 length + bytes).
pub fn appendString(list: *std.ArrayList(u8), allocator: Allocator, s: []const u8) Allocator.Error!void {
    try appendU32(list, allocator, @intCast(s.len));
    try list.appendSlice(allocator, s);
}

/// Append a boolean (1 byte: 0 or 1).
pub fn appendBool(list: *std.ArrayList(u8), allocator: Allocator, v: bool) Allocator.Error!void {
    try list.append(allocator, if (v) 1 else 0);
}

/// Append a name-list (comma-separated names as one SSH string).
pub fn appendNameList(list: *std.ArrayList(u8), allocator: Allocator, names: []const []const u8) Allocator.Error!void {
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(allocator);
    for (names, 0..) |n, i| {
        if (i > 0) try tmp.append(allocator, ',');
        try tmp.appendSlice(allocator, n);
    }
    try appendString(list, allocator, tmp.items);
}

/// Read uint32 big-endian; advances `off`.
pub fn readU32(buf: []const u8, off: *usize) Error!u32 {
    if (off.* + 4 > buf.len) return error.SshPacketCorrupt;
    const v = std.mem.readInt(u32, buf[off.*..][0..4], .big);
    off.* += 4;
    return v;
}

/// Read SSH string; advances `off`. Returns a slice into `buf`.
pub fn readString(buf: []const u8, off: *usize) Error![]const u8 {
    const n = try readU32(buf, off);
    if (off.* + n > buf.len) return error.SshPacketCorrupt;
    const s = buf[off.* .. off.* + n];
    off.* += n;
    return s;
}

/// Read boolean; advances `off`.
pub fn readBool(buf: []const u8, off: *usize) Error!bool {
    if (off.* >= buf.len) return error.SshPacketCorrupt;
    const b = buf[off.*];
    off.* += 1;
    return b != 0;
}

/// Encode a positive integer as SSH mpint (RFC 4251 §5).
///
/// `be_bytes` is the big-endian magnitude (may have leading zeros stripped
/// by the caller; zeros are stripped again here).
pub fn encodeMpint(allocator: Allocator, be_bytes: []const u8) Allocator.Error![]u8 {
    // Strip leading zeros.
    var start: usize = 0;
    while (start < be_bytes.len and be_bytes[start] == 0) : (start += 1) {}
    const body = be_bytes[start..];
    // Zero → empty mpint body.
    if (body.len == 0) {
        const out = try allocator.alloc(u8, 4);
        @memset(out, 0);
        return out;
    }
    // If high bit set, prepend 0x00 so the value is positive.
    const need_pad = (body[0] & 0x80) != 0;
    const body_len = body.len + @as(usize, if (need_pad) 1 else 0);
    var out = try allocator.alloc(u8, 4 + body_len);
    std.mem.writeInt(u32, out[0..4], @intCast(body_len), .big);
    if (need_pad) {
        out[4] = 0;
        @memcpy(out[5 .. 5 + body.len], body);
    } else {
        @memcpy(out[4 .. 4 + body.len], body);
    }
    return out;
}

/// Strip leading zero bytes from an SSH mpint body (for RSA e/n).
pub fn stripMpintLeadingZeros(raw: []const u8) []const u8 {
    var start: usize = 0;
    while (start + 1 < raw.len and raw[start] == 0) : (start += 1) {}
    return raw[start..];
}

/// Write an SSH string into a hash (length-prefixed).
pub fn hashWriteString(h: *Sha256, s: []const u8) void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(s.len), .big);
    h.update(&len_buf);
    h.update(s);
}

/// First common name from client preference list that appears in server list.
pub fn negotiate(
    client_prefs: []const []const u8,
    server_list: []const u8,
) Error![]const u8 {
    for (client_prefs) |pref| {
        if (nameListContains(server_list, pref)) return pref;
    }
    return error.SshNoCommonAlgorithm;
}

/// True if `name` appears as a comma-separated token in `list`.
pub fn nameListContains(list: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, name)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// AES-CTR stream (stateful across packets) — AES-128 and AES-256
// ---------------------------------------------------------------------------

fn AesCtrImpl(comptime Aes: type) type {
    return struct {
        const Self = @This();
        ctx: AesEncryptCtx(Aes),
        counter: [16]u8,
        ks: [16]u8 = undefined,
        ks_off: usize = 16,

        pub fn init(key: *const [Aes.key_bits / 8]u8, iv: *const [16]u8) Self {
            return .{
                .ctx = Aes.initEnc(key.*),
                .counter = iv.*,
                .ks_off = 16,
            };
        }

        fn refill(self: *Self) void {
            self.ctx.encrypt(&self.ks, &self.counter);
            var i: usize = 16;
            while (i > 0) {
                i -= 1;
                const sum = @as(u16, self.counter[i]) + 1;
                self.counter[i] = @truncate(sum);
                if (sum < 256) break;
            }
            self.ks_off = 0;
        }

        pub fn xor(self: *Self, data: []u8) void {
            var i: usize = 0;
            while (i < data.len) {
                if (self.ks_off >= 16) self.refill();
                const n = @min(16 - self.ks_off, data.len - i);
                for (0..n) |j| {
                    data[i + j] ^= self.ks[self.ks_off + j];
                }
                self.ks_off += n;
                i += n;
            }
        }
    };
}

/// Stateful AES-128-CTR matching Go `cipher.NewCTR` (full-block big-endian counter).
pub const Aes128Ctr = AesCtrImpl(Aes128);
/// Stateful AES-256-CTR (same counter convention as AES-128-CTR).
pub const Aes256Ctr = AesCtrImpl(Aes256);

/// Encryption engine for SSH packets (CTR modes).
pub const AesCtr = union(enum) {
    aes128: Aes128Ctr,
    aes256: Aes256Ctr,

    pub fn xor(self: *AesCtr, data: []u8) void {
        switch (self.*) {
            .aes128 => |*c| c.xor(data),
            .aes256 => |*c| c.xor(data),
        }
    }
};

// ---------------------------------------------------------------------------
// Packet codec (cleartext + AES-CTR + HMAC-SHA2-*)
// ---------------------------------------------------------------------------

pub const PacketCipher = struct {
    enc: ?AesCtr = null,
    mac_alg: MacAlg = .none,
    mac_key: [max_mac_length]u8 = undefined,

    pub fn none() PacketCipher {
        return .{};
    }

    pub fn macEnabled(self: *const PacketCipher) bool {
        return self.mac_alg != .none;
    }

    pub fn macLength(self: *const PacketCipher) usize {
        return self.mac_alg.digestLen();
    }

    /// Build a cipher from negotiated encryption + MAC names and key material.
    pub fn initFromAlgs(
        enc_alg: EncAlg,
        key: []const u8,
        iv: []const u8,
        mac_alg: MacAlg,
        mac_key: []const u8,
    ) Error!PacketCipher {
        var c: PacketCipher = .{ .mac_alg = mac_alg };
        if (mac_alg != .none) {
            const mk_len = mac_alg.keyLen();
            if (mac_key.len < mk_len) return error.SshUnsupportedAlgorithm;
            @memcpy(c.mac_key[0..mk_len], mac_key[0..mk_len]);
        }
        switch (enc_alg) {
            .none => {},
            .aes128_ctr => {
                if (key.len < 16 or iv.len < 16) return error.SshUnsupportedAlgorithm;
                c.enc = .{ .aes128 = Aes128Ctr.init(key[0..16], iv[0..16]) };
            },
            .aes256_ctr => {
                if (key.len < 32 or iv.len < 16) return error.SshUnsupportedAlgorithm;
                c.enc = .{ .aes256 = Aes256Ctr.init(key[0..32], iv[0..16]) };
            },
        }
        return c;
    }

    pub fn aes128CtrHmacSha256(key: *const [16]u8, iv: *const [16]u8, mac_key: *const [32]u8) PacketCipher {
        return initFromAlgs(.aes128_ctr, key, iv, .hmac_sha2_256, mac_key) catch unreachable;
    }

    pub fn aes256CtrHmacSha256(key: *const [32]u8, iv: *const [16]u8, mac_key: *const [32]u8) PacketCipher {
        return initFromAlgs(.aes256_ctr, key, iv, .hmac_sha2_256, mac_key) catch unreachable;
    }

    pub fn aes128CtrHmacSha512(key: *const [16]u8, iv: *const [16]u8, mac_key: *const [64]u8) PacketCipher {
        return initFromAlgs(.aes128_ctr, key, iv, .hmac_sha2_512, mac_key) catch unreachable;
    }

    pub fn aes256CtrHmacSha512(key: *const [32]u8, iv: *const [16]u8, mac_key: *const [64]u8) PacketCipher {
        return initFromAlgs(.aes256_ctr, key, iv, .hmac_sha2_512, mac_key) catch unreachable;
    }

    fn computeMac(self: *const PacketCipher, seq: u32, packet_body: []const u8, out: []u8) void {
        var seq_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &seq_buf, seq, .big);
        switch (self.mac_alg) {
            .none => {},
            .hmac_sha2_256 => {
                var hmac = HmacSha256.init(self.mac_key[0..hmac_sha256_key_len]);
                hmac.update(&seq_buf);
                hmac.update(packet_body);
                hmac.final(out[0..32]);
            },
            .hmac_sha2_512 => {
                var hmac = HmacSha512.init(self.mac_key[0..hmac_sha512_key_len]);
                hmac.update(&seq_buf);
                hmac.update(packet_body);
                hmac.final(out[0..64]);
            },
        }
    }

    fn macEqual(self: *const PacketCipher, expected: []const u8, got: []const u8) bool {
        const n = self.macLength();
        if (expected.len < n or got.len < n) return false;
        // Constant-time for fixed digest sizes we support.
        return switch (self.mac_alg) {
            .none => true,
            .hmac_sha2_256 => blk: {
                var a: [32]u8 = undefined;
                var b: [32]u8 = undefined;
                @memcpy(&a, expected[0..32]);
                @memcpy(&b, got[0..32]);
                break :blk std.crypto.timing_safe.eql([32]u8, a, b);
            },
            .hmac_sha2_512 => blk: {
                var a: [64]u8 = undefined;
                var b: [64]u8 = undefined;
                @memcpy(&a, expected[0..64]);
                @memcpy(&b, got[0..64]);
                break :blk std.crypto.timing_safe.eql([64]u8, a, b);
            },
        };
    }
};

/// Encode one SSH binary packet into `out` (owned). Payload is message body
/// including the message type byte.
///
/// When MAC is enabled, appends HMAC over seq||unencrypted packet (non-EtM).
/// CTR state advances only over the encrypted packet body.
pub fn encodePacket(
    allocator: Allocator,
    cipher: *PacketCipher,
    seq: u32,
    payload: []const u8,
) (Allocator.Error || Error)![]u8 {
    if (payload.len > max_packet) return error.SshPacketTooLarge;

    // padding_length so (4 + 1 + payload + pad) % block == 0, with pad >= 4.
    var padding_length: usize = packet_block - ((5 + payload.len) % packet_block);
    if (padding_length < 4) padding_length += packet_block;

    const length: u32 = @intCast(payload.len + 1 + padding_length);
    const packet_body_len: usize = 4 + 1 + payload.len + padding_length;
    const mac_len = cipher.macLength();
    const total = packet_body_len + mac_len;

    var out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);

    std.mem.writeInt(u32, out[0..4], length, .big);
    out[4] = @intCast(padding_length);
    @memcpy(out[5 .. 5 + payload.len], payload);
    for (out[5 + payload.len .. 5 + payload.len + padding_length], 0..) |*b, i| {
        b.* = @truncate(i + 1);
    }

    if (cipher.macEnabled()) {
        cipher.computeMac(seq, out[0..packet_body_len], out[packet_body_len..][0..mac_len]);
    }

    if (cipher.enc) |*enc| {
        enc.xor(out[0..packet_body_len]);
    }

    return out;
}

/// Decode one SSH binary packet from `reader`. Returns owned payload (message type + body).
pub fn decodePacket(
    allocator: Allocator,
    cipher: *PacketCipher,
    seq: u32,
    reader: *std.Io.Reader,
) (Allocator.Error || Error || anyerror)![]u8 {
    var prefix: [5]u8 = undefined;
    try reader.readSliceAll(&prefix);

    if (cipher.enc) |*enc| {
        enc.xor(&prefix);
    }

    const length = std.mem.readInt(u32, prefix[0..4], .big);
    const padding_length: u32 = prefix[4];

    if (length < 5) return error.SshPacketCorrupt;
    if (padding_length < 4) return error.SshPacketCorrupt;
    if (length < padding_length + 1) return error.SshPacketCorrupt;
    if (length > max_packet) return error.SshPacketTooLarge;

    const payload_len: usize = length - padding_length - 1;
    const rest_len: usize = length - 1;
    if (payload_len > rest_len) return error.SshPacketCorrupt;

    const mac_len = cipher.macLength();
    const rest = try allocator.alloc(u8, rest_len + mac_len);
    defer allocator.free(rest);
    try reader.readSliceAll(rest);

    const data = rest[0..rest_len];
    const mac_bytes = rest[rest_len .. rest_len + mac_len];

    if (cipher.enc) |*enc| {
        enc.xor(data);
    }

    if (cipher.macEnabled()) {
        // Reconstruct unencrypted packet for MAC: prefix + data.
        var expected: [max_mac_length]u8 = undefined;
        var mac_input: std.ArrayList(u8) = .empty;
        defer mac_input.deinit(allocator);
        try mac_input.appendSlice(allocator, &prefix);
        try mac_input.appendSlice(allocator, data);
        cipher.computeMac(seq, mac_input.items, expected[0..mac_len]);
        if (!cipher.macEqual(expected[0..mac_len], mac_bytes)) {
            return error.SshMacFailure;
        }
    }

    return try allocator.dupe(u8, data[0..payload_len]);
}

/// Build KEXINIT payload (without outer packet framing). Returns owned bytes.
pub fn buildKexInit(
    allocator: Allocator,
    cookie: *const [16]u8,
    kex: []const []const u8,
    host_key: []const []const u8,
    enc: []const []const u8,
    mac: []const []const u8,
    comp: []const []const u8,
) Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    try list.append(allocator, msg_kexinit);
    try list.appendSlice(allocator, cookie);
    try appendNameList(&list, allocator, kex);
    try appendNameList(&list, allocator, host_key);
    try appendNameList(&list, allocator, enc); // c2s
    try appendNameList(&list, allocator, enc); // s2c
    try appendNameList(&list, allocator, mac); // c2s
    try appendNameList(&list, allocator, mac); // s2c
    try appendNameList(&list, allocator, comp); // c2s
    try appendNameList(&list, allocator, comp); // s2c
    try appendNameList(&list, allocator, &.{}); // lang c2s
    try appendNameList(&list, allocator, &.{}); // lang s2c
    try appendBool(&list, allocator, false); // first_kex_packet_follows
    try appendU32(&list, allocator, 0); // reserved

    return try list.toOwnedSlice(allocator);
}

/// Parsed KEXINIT fields needed for negotiation and session hash.
pub const KexInitView = struct {
    raw: []const u8,
    kex_algorithms: []const u8,
    server_host_key_algorithms: []const u8,
    encryption_c2s: []const u8,
    encryption_s2c: []const u8,
    mac_c2s: []const u8,
    mac_s2c: []const u8,
    compression_c2s: []const u8,
    compression_s2c: []const u8,
};

pub fn parseKexInit(payload: []const u8) Error!KexInitView {
    if (payload.len < 17 or payload[0] != msg_kexinit) return error.SshProtocolError;
    var off: usize = 1 + 16; // type + cookie
    const kex = try readString(payload, &off);
    const host = try readString(payload, &off);
    const enc_c2s = try readString(payload, &off);
    const enc_s2c = try readString(payload, &off);
    const mac_c2s = try readString(payload, &off);
    const mac_s2c = try readString(payload, &off);
    const comp_c2s = try readString(payload, &off);
    const comp_s2c = try readString(payload, &off);
    _ = try readString(payload, &off); // lang c2s
    _ = try readString(payload, &off); // lang s2c
    _ = try readBool(payload, &off);
    if (off + 4 > payload.len) return error.SshPacketCorrupt;
    return .{
        .raw = payload,
        .kex_algorithms = kex,
        .server_host_key_algorithms = host,
        .encryption_c2s = enc_c2s,
        .encryption_s2c = enc_s2c,
        .mac_c2s = mac_c2s,
        .mac_s2c = mac_s2c,
        .compression_c2s = comp_c2s,
        .compression_s2c = comp_s2c,
    };
}

// ---------------------------------------------------------------------------
// Key derivation (RFC 4253 §7.2)
// ---------------------------------------------------------------------------

/// Fill `out` with key material: HASH(K || H || tag || session_id) then extend.
pub fn generateKeyMaterial(out: []u8, tag: u8, K: []const u8, H: []const u8, session_id: []const u8) void {
    var digests_so_far: [256]u8 = undefined;
    var digests_len: usize = 0;
    var filled: usize = 0;
    while (filled < out.len) {
        var h = Sha256.init(.{});
        h.update(K);
        h.update(H);
        if (digests_len == 0) {
            h.update(&.{tag});
            h.update(session_id);
        } else {
            h.update(digests_so_far[0..digests_len]);
        }
        var digest: [32]u8 = undefined;
        h.final(&digest);
        const n = @min(32, out.len - filled);
        @memcpy(out[filled .. filled + n], digest[0..n]);
        filled += n;
        if (filled < out.len) {
            if (digests_len + 32 > digests_so_far.len) {
                @memcpy(digests_so_far[0..32], digest[0..]);
                digests_len = 32;
            } else {
                @memcpy(digests_so_far[digests_len .. digests_len + 32], &digest);
                digests_len += 32;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "append and read SSH string" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try appendString(&list, testing.allocator, "hello");
    try testing.expectEqual(@as(usize, 9), list.items.len);
    var off: usize = 0;
    const s = try readString(list.items, &off);
    try testing.expectEqualStrings("hello", s);
    try testing.expectEqual(@as(usize, 9), off);
}

test "name list negotiate first mutual" {
    const server = "diffie-hellman-group14-sha256,curve25519-sha256,ecdh-sha2-nistp256";
    const prefs = [_][]const u8{ "curve25519-sha256", "diffie-hellman-group14-sha256" };
    const n = try negotiate(&prefs, server);
    try testing.expectEqualStrings("curve25519-sha256", n);
}

test "name list negotiate expanded enc and mac prefs" {
    // Client prefers stronger first; server offers both — first mutual wins.
    const server_enc = "aes128-ctr,aes256-ctr";
    const enc_prefs = [_][]const u8{ "aes256-ctr", "aes128-ctr" };
    try testing.expectEqualStrings("aes256-ctr", try negotiate(&enc_prefs, server_enc));

    const server_mac = "hmac-sha2-256,hmac-sha2-512";
    const mac_prefs = [_][]const u8{ "hmac-sha2-512", "hmac-sha2-256" };
    try testing.expectEqualStrings("hmac-sha2-512", try negotiate(&mac_prefs, server_mac));

    // Server only offers weaker — client falls through.
    try testing.expectEqualStrings("aes128-ctr", try negotiate(&enc_prefs, "aes128-ctr"));
    try testing.expectEqualStrings("hmac-sha2-256", try negotiate(&mac_prefs, "hmac-sha2-256"));
}

test "name list negotiate miss" {
    const server = "diffie-hellman-group1-sha1";
    const prefs = [_][]const u8{"curve25519-sha256"};
    try testing.expectError(error.SshNoCommonAlgorithm, negotiate(&prefs, server));
}

test "encode mpint high bit pad" {
    const m = try encodeMpint(testing.allocator, &[_]u8{0x80});
    defer testing.allocator.free(m);
    try testing.expectEqual(@as(usize, 6), m.len);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, m[0..4], .big));
    try testing.expectEqual(@as(u8, 0x00), m[4]);
    try testing.expectEqual(@as(u8, 0x80), m[5]);
}

test "encode mpint zero" {
    const m = try encodeMpint(testing.allocator, &[_]u8{ 0, 0, 0 });
    defer testing.allocator.free(m);
    try testing.expectEqual(@as(usize, 4), m.len);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, m[0..4], .big));
}

test "encode/decode cleartext packet roundtrip" {
    var cipher = PacketCipher.none();
    const payload = [_]u8{msg_newkeys};
    const enc = try encodePacket(testing.allocator, &cipher, 0, &payload);
    defer testing.allocator.free(enc);

    const length = std.mem.readInt(u32, enc[0..4], .big);
    try testing.expect(length >= 5);
    try testing.expectEqual(@as(u8, msg_newkeys), enc[5]);

    var reader = std.Io.Reader.fixed(enc);
    var dec_cipher = PacketCipher.none();
    const got = try decodePacket(testing.allocator, &dec_cipher, 0, &reader);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &payload, got);
}

test "encode/decode aes128-ctr hmac-sha2-256 packet" {
    const key = [_]u8{0x01} ** 16;
    const iv = [_]u8{0x02} ** 16;
    const mac = [_]u8{0x03} ** 32;

    var enc_c = PacketCipher.aes128CtrHmacSha256(&key, &iv, &mac);
    var dec_c = PacketCipher.aes128CtrHmacSha256(&key, &iv, &mac);

    var pl: std.ArrayList(u8) = .empty;
    defer pl.deinit(testing.allocator);
    try pl.append(testing.allocator, msg_service_request);
    try appendString(&pl, testing.allocator, "ssh-userauth");

    const wire = try encodePacket(testing.allocator, &enc_c, 3, pl.items);
    defer testing.allocator.free(wire);

    var reader = std.Io.Reader.fixed(wire);
    const got = try decodePacket(testing.allocator, &dec_c, 3, &reader);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, pl.items, got);
}

test "encode/decode aes256-ctr hmac-sha2-512 packet" {
    const key = [_]u8{0x11} ** 32;
    const iv = [_]u8{0x22} ** 16;
    const mac = [_]u8{0x33} ** 64;

    var enc_c = PacketCipher.aes256CtrHmacSha512(&key, &iv, &mac);
    var dec_c = PacketCipher.aes256CtrHmacSha512(&key, &iv, &mac);

    var pl: std.ArrayList(u8) = .empty;
    defer pl.deinit(testing.allocator);
    try pl.append(testing.allocator, msg_service_request);
    try appendString(&pl, testing.allocator, "ssh-userauth");

    const wire_bytes = try encodePacket(testing.allocator, &enc_c, 7, pl.items);
    defer testing.allocator.free(wire_bytes);
    // MAC is 64 bytes.
    try testing.expect(wire_bytes.len >= 64 + 16);

    var reader = std.Io.Reader.fixed(wire_bytes);
    const got = try decodePacket(testing.allocator, &dec_c, 7, &reader);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, pl.items, got);
}

test "encode/decode aes256-ctr hmac-sha2-256 multi-packet stream" {
    const key = [_]u8{0xaa} ** 32;
    const iv = [_]u8{0xbb} ** 16;
    const mac = [_]u8{0xcc} ** 32;
    var enc_c = PacketCipher.aes256CtrHmacSha256(&key, &iv, &mac);
    var dec_c = PacketCipher.aes256CtrHmacSha256(&key, &iv, &mac);

    const p1 = [_]u8{msg_newkeys};
    const p2 = [_]u8{ msg_service_accept, 0, 0, 0, 4, 't', 'e', 's', 't' };

    const w1 = try encodePacket(testing.allocator, &enc_c, 0, &p1);
    defer testing.allocator.free(w1);
    const w2 = try encodePacket(testing.allocator, &enc_c, 1, &p2);
    defer testing.allocator.free(w2);

    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(testing.allocator);
    try combined.appendSlice(testing.allocator, w1);
    try combined.appendSlice(testing.allocator, w2);

    var reader = std.Io.Reader.fixed(combined.items);
    const g1 = try decodePacket(testing.allocator, &dec_c, 0, &reader);
    defer testing.allocator.free(g1);
    const g2 = try decodePacket(testing.allocator, &dec_c, 1, &reader);
    defer testing.allocator.free(g2);
    try testing.expectEqualSlices(u8, &p1, g1);
    try testing.expectEqualSlices(u8, &p2, g2);
}

test "build and parse KEXINIT" {
    const cookie = [_]u8{0xab} ** 16;
    const raw = try buildKexInit(
        testing.allocator,
        &cookie,
        &.{"curve25519-sha256"},
        &.{ "ssh-ed25519", "rsa-sha2-256" },
        &.{ "aes256-ctr", "aes128-ctr" },
        &.{ "hmac-sha2-512", "hmac-sha2-256" },
        &.{"none"},
    );
    defer testing.allocator.free(raw);
    try testing.expectEqual(@as(u8, msg_kexinit), raw[0]);
    const view = try parseKexInit(raw);
    try testing.expectEqualStrings("curve25519-sha256", view.kex_algorithms);
    try testing.expectEqualStrings("ssh-ed25519,rsa-sha2-256", view.server_host_key_algorithms);
    try testing.expectEqualStrings("aes256-ctr,aes128-ctr", view.encryption_c2s);
    try testing.expectEqualStrings("hmac-sha2-512,hmac-sha2-256", view.mac_c2s);
}

test "Aes128Ctr self-inverse" {
    const key = [_]u8{0x11} ** 16;
    const iv = [_]u8{0x22} ** 16;
    var a = Aes128Ctr.init(&key, &iv);
    var b = Aes128Ctr.init(&key, &iv);
    var data = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 };
    var copy = data;
    a.xor(&data);
    try testing.expect(!std.mem.eql(u8, &data, &copy));
    b.xor(&data);
    try testing.expectEqualSlices(u8, &copy, &data);
}

test "Aes256Ctr leftover keystream across calls" {
    const key = [_]u8{0x55} ** 32;
    const iv = [_]u8{0x66} ** 16;
    var a = Aes256Ctr.init(&key, &iv);
    var b = Aes256Ctr.init(&key, &iv);
    var data = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 };
    var copy = data;
    a.xor(data[0..3]);
    a.xor(data[3..10]);
    a.xor(data[10..]);
    b.xor(&copy);
    try testing.expectEqualSlices(u8, &copy, &data);
}

test "Aes128Ctr leftover keystream across calls" {
    const key = [_]u8{0x33} ** 16;
    const iv = [_]u8{0x44} ** 16;
    var a = Aes128Ctr.init(&key, &iv);
    var b = Aes128Ctr.init(&key, &iv);
    var data = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 };
    var copy = data;
    a.xor(data[0..3]);
    a.xor(data[3..10]);
    a.xor(data[10..]);
    b.xor(&copy);
    try testing.expectEqualSlices(u8, &copy, &data);
}

test "decodePacket rejects short padding" {
    var wire_buf: [5 + 1 + 2]u8 = undefined;
    const length: u32 = 1 + 1 + 2;
    std.mem.writeInt(u32, wire_buf[0..4], length, .big);
    wire_buf[4] = 2;
    wire_buf[5] = msg_newkeys;
    wire_buf[6] = 0;
    wire_buf[7] = 0;

    var cipher = PacketCipher.none();
    var reader = std.Io.Reader.fixed(&wire_buf);
    try testing.expectError(error.SshPacketCorrupt, decodePacket(testing.allocator, &cipher, 0, &reader));
}

test "decodePacket rejects MAC failure hmac-sha2-512" {
    const key = [_]u8{0x01} ** 32;
    const iv = [_]u8{0x02} ** 16;
    const mac = [_]u8{0x03} ** 64;
    var enc_c = PacketCipher.aes256CtrHmacSha512(&key, &iv, &mac);
    const payload = [_]u8{msg_newkeys};
    const wire_bytes = try encodePacket(testing.allocator, &enc_c, 0, &payload);
    defer testing.allocator.free(wire_bytes);

    var mangled = try testing.allocator.dupe(u8, wire_bytes);
    defer testing.allocator.free(mangled);
    mangled[mangled.len - 1] ^= 0xff;

    var dec_c = PacketCipher.aes256CtrHmacSha512(&key, &iv, &mac);
    var reader = std.Io.Reader.fixed(mangled);
    try testing.expectError(error.SshMacFailure, decodePacket(testing.allocator, &dec_c, 0, &reader));
}

test "generateKeyMaterial deterministic and extends for aes256" {
    const K = "\x00\x01\x02\x03" ++ ("\x00" ** 28);
    const H = [_]u8{0xaa} ** 32;
    const sid = [_]u8{0xbb} ** 32;
    var out1: [32]u8 = undefined;
    var out2: [32]u8 = undefined;
    generateKeyMaterial(&out1, 'C', K, &H, &sid);
    generateKeyMaterial(&out2, 'C', K, &H, &sid);
    try testing.expectEqualSlices(u8, &out1, &out2);
    var outB: [32]u8 = undefined;
    generateKeyMaterial(&outB, 'D', K, &H, &sid);
    try testing.expect(!std.mem.eql(u8, &out1, &outB));
}

test "EncAlg MacAlg fromName" {
    try testing.expectEqual(EncAlg.aes256_ctr, try EncAlg.fromName("aes256-ctr"));
    try testing.expectEqual(EncAlg.aes128_ctr, try EncAlg.fromName("aes128-ctr"));
    try testing.expectEqual(MacAlg.hmac_sha2_512, try MacAlg.fromName("hmac-sha2-512"));
    try testing.expectEqual(MacAlg.hmac_sha2_256, try MacAlg.fromName("hmac-sha2-256"));
    try testing.expectError(error.SshUnsupportedAlgorithm, EncAlg.fromName("3des-cbc"));
}
