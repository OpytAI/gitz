//! OpenPGP detached-signature verify **and** sign for Git.
//!
//! Mirrors go-git / ProtonMail go-crypto for the algorithms Git signing uses:
//! - ASCII armor (PUBLIC KEY BLOCK / PRIVATE KEY BLOCK / SIGNATURE)
//! - v4 public/secret key packets (RSA; EdDSA/Ed25519) + secret/public subkeys
//! - S2K simple / salted / iterated+salted (SHA-1 / SHA-256 / SHA-512)
//! - AES-128/192/256-CFB secret-key decrypt (usage 254 SHA-1 checksum, 255 sum16)
//! - v4 signature packets (SHA-1 / SHA-256 / SHA-512)
//! - RSA PKCS#1 v1.5 and Ed25519 (EdDSA) sign/verify over OpenPGP hash trailer
//! - Signing-key selection prefers a decrypted sign-capable subkey (go-crypto)
//! - `ArmoredDetachSign` for tag/commit signing (`CreateTagOptions.sign_key`)

const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const Managed = std.math.big.int.Managed;

pub const Error = error{
    InvalidArmor,
    InvalidPacket,
    UnsupportedAlgorithm,
    KeyNotFound,
    InvalidSignature,
    MultipleSignatures,
    /// Private key is still passphrase-encrypted (go-git: "signing key is encrypted").
    EncryptedKey,
    /// Wrong passphrase or corrupt secret-key material.
    DecryptFailed,
    /// Entity has no private key material (public-only ring).
    NoPrivateKey,
};

// Packet tags
const tag_public_key: u8 = 6;
const tag_public_subkey: u8 = 14;
const tag_secret_key: u8 = 5;
const tag_secret_subkey: u8 = 7;
const tag_user_id: u8 = 13;
const tag_signature: u8 = 2;

// Public-key algorithms
const pk_rsa: u8 = 1;
const pk_rsa_encrypt: u8 = 2;
const pk_rsa_sign: u8 = 3;
const pk_eddsa: u8 = 22;

// Hash algorithms
const hash_sha1: u8 = 2;
const hash_sha256: u8 = 8;
const hash_sha512: u8 = 10;

// Symmetric ciphers (OpenPGP IDs)
const cipher_aes128: u8 = 7;
const cipher_aes192: u8 = 8;
const cipher_aes256: u8 = 9;

// S2K specifier types (RFC 4880 §3.7)
const s2k_simple: u8 = 0;
const s2k_salted: u8 = 1;
const s2k_iterated: u8 = 3;

// Key flags subpacket (type 27): bit 0 certify, 1 sign, 2 encrypt comm, 3 encrypt storage
const key_flag_certify: u8 = 0x01;
const key_flag_sign: u8 = 0x02;

// ---------------------------------------------------------------------------
// Armor
// ---------------------------------------------------------------------------

pub fn decodeArmor(allocator: Allocator, armored: []const u8) (Allocator.Error || Error)![]u8 {
    var it = std.mem.splitScalar(u8, armored, '\n');
    var in_body = false;
    var b64: std.ArrayList(u8) = .empty;
    defer b64.deinit(allocator);

    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "-----BEGIN ")) {
            in_body = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "-----END ")) break;
        if (!in_body) continue;
        if (std.mem.indexOfScalar(u8, line, ':') != null) continue; // header
        if (line[0] == '=') continue; // CRC24
        try b64.appendSlice(allocator, line);
    }
    if (b64.items.len == 0) return error.InvalidArmor;

    const dec_len = std.base64.standard.Decoder.calcSizeForSlice(b64.items) catch return error.InvalidArmor;
    const out = try allocator.alloc(u8, dec_len);
    errdefer allocator.free(out);
    std.base64.standard.Decoder.decode(out, b64.items) catch return error.InvalidArmor;
    return out;
}

// ---------------------------------------------------------------------------
// Packets / MPI
// ---------------------------------------------------------------------------

const Packet = struct {
    tag: u8,
    body: []const u8,
};

fn nextPacket(data: []const u8, pos: *usize) Error!Packet {
    if (pos.* >= data.len) return error.InvalidPacket;
    const b0 = data[pos.*];
    pos.* += 1;
    if ((b0 & 0x80) == 0) return error.InvalidPacket;

    var tag: u8 = undefined;
    var body_len: usize = undefined;

    if ((b0 & 0x40) != 0) {
        // New-format header
        tag = b0 & 0x3f;
        if (pos.* >= data.len) return error.InvalidPacket;
        const l0 = data[pos.*];
        pos.* += 1;
        if (l0 < 192) {
            body_len = l0;
        } else if (l0 < 224) {
            if (pos.* >= data.len) return error.InvalidPacket;
            const l1 = data[pos.*];
            pos.* += 1;
            body_len = @as(usize, (@as(u16, l0) - 192) << 8) + l1 + 192;
        } else if (l0 == 255) {
            if (pos.* + 4 > data.len) return error.InvalidPacket;
            body_len = std.mem.readInt(u32, data[pos.*..][0..4], .big);
            pos.* += 4;
        } else {
            return error.UnsupportedAlgorithm; // partial body lengths
        }
    } else {
        // Old-format header
        tag = (b0 >> 2) & 0x0f;
        switch (b0 & 0x03) {
            0 => {
                if (pos.* >= data.len) return error.InvalidPacket;
                body_len = data[pos.*];
                pos.* += 1;
            },
            1 => {
                if (pos.* + 2 > data.len) return error.InvalidPacket;
                body_len = std.mem.readInt(u16, data[pos.*..][0..2], .big);
                pos.* += 2;
            },
            2 => {
                if (pos.* + 4 > data.len) return error.InvalidPacket;
                body_len = std.mem.readInt(u32, data[pos.*..][0..4], .big);
                pos.* += 4;
            },
            else => body_len = data.len - pos.*,
        }
    }
    if (pos.* + body_len > data.len) return error.InvalidPacket;
    const body = data[pos.* .. pos.* + body_len];
    pos.* += body_len;
    return .{ .tag = tag, .body = body };
}

fn readMpi(data: []const u8, pos: *usize) Error![]const u8 {
    if (pos.* + 2 > data.len) return error.InvalidPacket;
    const bitlen = std.mem.readInt(u16, data[pos.*..][0..2], .big);
    pos.* += 2;
    const bytelen = (@as(usize, bitlen) + 7) / 8;
    if (pos.* + bytelen > data.len) return error.InvalidPacket;
    const mpi = data[pos.* .. pos.* + bytelen];
    pos.* += bytelen;
    return mpi;
}

fn fingerprintV4(packet_body: []const u8) [20]u8 {
    var h = crypto.hash.Sha1.init(.{});
    var hdr: [3]u8 = .{
        0x99,
        @intCast((packet_body.len >> 8) & 0xff),
        @intCast(packet_body.len & 0xff),
    };
    h.update(&hdr);
    h.update(packet_body);
    var out: [20]u8 = undefined;
    h.final(&out);
    return out;
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

const PublicKey = struct {
    algo: u8,
    fingerprint: [20]u8,
    n: []const u8 = &.{},
    e: []const u8 = &.{},
    ed25519: ?[32]u8 = null,
    owned: []u8 = &.{},

    fn deinit(self: *PublicKey, allocator: Allocator) void {
        if (self.owned.len > 0) allocator.free(self.owned);
        self.* = .{
            .algo = 0,
            .fingerprint = .{0} ** 20,
        };
    }
};

fn parsePublicKey(allocator: Allocator, body: []const u8) (Allocator.Error || Error)!PublicKey {
    if (body.len < 6 or body[0] != 4) return error.UnsupportedAlgorithm;
    const algo = body[5];
    const owned = try allocator.dupe(u8, body);
    errdefer allocator.free(owned);

    var pos: usize = 6;
    var pk: PublicKey = .{
        .algo = algo,
        .fingerprint = fingerprintV4(body),
        .owned = owned,
    };

    switch (algo) {
        pk_rsa, pk_rsa_encrypt, pk_rsa_sign => {
            pk.n = try readMpi(owned, &pos);
            pk.e = try readMpi(owned, &pos);
        },
        pk_eddsa => {
            if (pos >= owned.len) return error.InvalidPacket;
            const oid_len = owned[pos];
            pos += 1;
            if (pos + oid_len > owned.len) return error.InvalidPacket;
            pos += oid_len;
            const point_mpi = try readMpi(owned, &pos);
            var k: [32]u8 = undefined;
            if (point_mpi.len == 33 and point_mpi[0] == 0x40) {
                @memcpy(&k, point_mpi[1..33]);
            } else if (point_mpi.len == 32) {
                @memcpy(&k, point_mpi[0..32]);
            } else return error.UnsupportedAlgorithm;
            pk.ed25519 = k;
        },
        else => return error.UnsupportedAlgorithm,
    }
    return pk;
}

// ---------------------------------------------------------------------------
// Signatures
// ---------------------------------------------------------------------------

const Signature = struct {
    pub_algo: u8,
    hash_algo: u8,
    key_id: [8]u8 = .{0} ** 8,
    hashed: []const u8 = &.{},
    left16: [2]u8 = .{ 0, 0 },
    mpis: []const u8 = &.{},
    owned: []u8 = &.{},

    fn deinit(self: *Signature, allocator: Allocator) void {
        if (self.owned.len > 0) allocator.free(self.owned);
        self.* = .{
            .pub_algo = 0,
            .hash_algo = 0,
        };
    }

    /// Bytes hashed in the OpenPGP trailer (version…end of hashed subpackets).
    fn hashedData(self: *const Signature) []const u8 {
        return self.owned[0 .. 6 + self.hashed.len];
    }
};

fn parseSignature(allocator: Allocator, body: []const u8) (Allocator.Error || Error)!Signature {
    if (body.len < 10 or body[0] != 4) return error.UnsupportedAlgorithm;
    const pub_algo = body[2];
    const hash_algo = body[3];
    const hashed_len = std.mem.readInt(u16, body[4..6], .big);
    if (6 + hashed_len + 2 > body.len) return error.InvalidPacket;
    const after_hashed = 6 + hashed_len;
    const unhashed_len = std.mem.readInt(u16, body[after_hashed..][0..2], .big);
    if (after_hashed + 2 + unhashed_len + 2 > body.len) return error.InvalidPacket;
    const left_off = after_hashed + 2 + unhashed_len;

    const owned = try allocator.dupe(u8, body);
    errdefer allocator.free(owned);

    var sig: Signature = .{
        .pub_algo = pub_algo,
        .hash_algo = hash_algo,
        .hashed = owned[6 .. 6 + hashed_len],
        .left16 = owned[left_off .. left_off + 2][0..2].*,
        .mpis = owned[left_off + 2 ..],
        .owned = owned,
    };

    extractKeyId(sig.hashed, &sig.key_id);
    if (isZeroKeyId(&sig.key_id)) {
        const unhashed = owned[after_hashed + 2 .. after_hashed + 2 + unhashed_len];
        extractKeyId(unhashed, &sig.key_id);
    }
    return sig;
}

fn isZeroKeyId(id: *const [8]u8) bool {
    return std.mem.eql(u8, id, &(.{0} ** 8));
}

fn walkSubpackets(subpackets: []const u8, comptime callback: anytype, ctx: anytype) void {
    var pos: usize = 0;
    while (pos < subpackets.len) {
        var hdr: usize = undefined;
        var len: usize = undefined;
        if (subpackets[pos] < 192) {
            len = subpackets[pos];
            hdr = 1;
        } else if (subpackets[pos] < 255) {
            if (pos + 1 >= subpackets.len) return;
            len = (@as(usize, subpackets[pos] - 192) << 8) + subpackets[pos + 1] + 192;
            hdr = 2;
        } else {
            if (pos + 5 > subpackets.len) return;
            len = std.mem.readInt(u32, subpackets[pos + 1 ..][0..4], .big);
            hdr = 5;
        }
        const body_start = pos + hdr;
        if (body_start + len > subpackets.len or len == 0) return;
        const typ = subpackets[body_start] & 0x7f; // strip critical bit
        const data = subpackets[body_start + 1 .. body_start + len];
        callback(ctx, typ, data);
        pos = body_start + len;
    }
}

fn extractKeyId(subpackets: []const u8, out: *[8]u8) void {
    const Ctx = struct {
        out: *[8]u8,
        found: bool = false,
        fn cb(self: *@This(), typ: u8, data: []const u8) void {
            if (self.found) return;
            if (typ == 16 and data.len >= 8) {
                @memcpy(self.out, data[0..8]);
                self.found = true;
            } else if (typ == 33 and data.len >= 21) {
                @memcpy(self.out, data[data.len - 8 ..][0..8]);
                self.found = true;
            }
        }
    };
    var ctx: Ctx = .{ .out = out };
    walkSubpackets(subpackets, Ctx.cb, &ctx);
}

/// Extract key-flags subpacket (type 27). Returns null if absent.
fn extractKeyFlags(subpackets: []const u8) ?u8 {
    const Ctx = struct {
        flags: ?u8 = null,
        fn cb(self: *@This(), typ: u8, data: []const u8) void {
            if (typ == 27 and data.len >= 1 and self.flags == null) {
                self.flags = data[0];
            }
        }
    };
    var ctx: Ctx = .{};
    walkSubpackets(subpackets, Ctx.cb, &ctx);
    return ctx.flags;
}

fn hashDocument(hash_algo: u8, message: []const u8, sig: *const Signature) Error![64]u8 {
    const hashed_data = sig.hashedData();
    var trailer: [6]u8 = .{ 0x04, 0xff, 0, 0, 0, 0 };
    std.mem.writeInt(u32, trailer[2..6], @intCast(hashed_data.len), .big);

    var out: [64]u8 = .{0} ** 64;
    switch (hash_algo) {
        hash_sha1 => {
            var h = crypto.hash.Sha1.init(.{});
            h.update(message);
            h.update(hashed_data);
            h.update(&trailer);
            var d: [20]u8 = undefined;
            h.final(&d);
            @memcpy(out[0..20], &d);
        },
        hash_sha256 => {
            var h = crypto.hash.sha2.Sha256.init(.{});
            h.update(message);
            h.update(hashed_data);
            h.update(&trailer);
            var d: [32]u8 = undefined;
            h.final(&d);
            @memcpy(out[0..32], &d);
        },
        hash_sha512 => {
            var h = crypto.hash.sha2.Sha512.init(.{});
            h.update(message);
            h.update(hashed_data);
            h.update(&trailer);
            h.final(out[0..64]);
        },
        else => return error.UnsupportedAlgorithm,
    }
    return out;
}

fn hashDigestLen(hash_algo: u8) Error!usize {
    return switch (hash_algo) {
        hash_sha1 => 20,
        hash_sha256 => 32,
        hash_sha512 => 64,
        else => error.UnsupportedAlgorithm,
    };
}

// ---------------------------------------------------------------------------
// RSA PKCS#1 v1.5
// ---------------------------------------------------------------------------

fn setBytesBe(v: *Managed, bytes: []const u8) Allocator.Error!void {
    // Skip leading zero bytes (MPI may include a high 0x00).
    var start: usize = 0;
    while (start < bytes.len and bytes[start] == 0) : (start += 1) {}
    try v.set(0);
    for (bytes[start..]) |b| {
        try v.shiftLeft(v, 8);
        try v.addScalar(v, b);
    }
}

fn writeBytesBe(v: *const Managed, out: []u8) (Allocator.Error || Error)!void {
    @memset(out, 0);
    if (v.eqlZero()) return;

    var tmp = try Managed.initSet(v.allocator, 0);
    defer tmp.deinit();
    try tmp.copy(v.toConst());

    // Write little-endian limbs into the end of `out` (big-endian layout).
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const limb0: u8 = if (tmp.len() > 0) @truncate(tmp.limbs[0]) else 0;
        out[out.len - 1 - i] = limb0;
        try tmp.shiftRight(&tmp, 8);
        if (tmp.eqlZero()) break;
    }
}

fn modPow(result: *Managed, base: *Managed, exp: *Managed, mod: *Managed) Allocator.Error!void {
    const allocator = result.allocator;
    try result.set(1);

    var b = try Managed.initSet(allocator, 0);
    defer b.deinit();
    var q = try Managed.initSet(allocator, 0);
    defer q.deinit();
    var r = try Managed.initSet(allocator, 0);
    defer r.deinit();
    try q.divFloor(&r, base, mod);
    try b.copy(r.toConst());

    var e = try Managed.initSet(allocator, 0);
    defer e.deinit();
    try e.copy(exp.toConst());

    var tmp = try Managed.initSet(allocator, 0);
    defer tmp.deinit();

    while (!e.eqlZero()) {
        if ((e.limbs[0] & 1) == 1) {
            try tmp.mul(result, &b);
            try q.divFloor(&r, &tmp, mod);
            try result.copy(r.toConst());
        }
        try tmp.mul(&b, &b);
        try q.divFloor(&r, &tmp, mod);
        try b.copy(r.toConst());
        try e.shiftRight(&e, 1);
    }
}

fn digestInfoPrefix(hash_algo: u8) Error![]const u8 {
    return switch (hash_algo) {
        hash_sha1 => &[_]u8{ 0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14 },
        hash_sha256 => &[_]u8{ 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 },
        hash_sha512 => &[_]u8{ 0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40 },
        else => error.UnsupportedAlgorithm,
    };
}

fn rsaVerify(
    allocator: Allocator,
    n_bytes: []const u8,
    e_bytes: []const u8,
    sig_mpi: []const u8,
    digest: []const u8,
    hash_algo: u8,
) (Allocator.Error || Error)!void {
    if (n_bytes.len == 0 or e_bytes.len == 0 or sig_mpi.len == 0) return error.InvalidSignature;

    var n = try Managed.initSet(allocator, 0);
    defer n.deinit();
    var e = try Managed.initSet(allocator, 0);
    defer e.deinit();
    var s = try Managed.initSet(allocator, 0);
    defer s.deinit();
    var m = try Managed.initSet(allocator, 0);
    defer m.deinit();

    try setBytesBe(&n, n_bytes);
    try setBytesBe(&e, e_bytes);
    try setBytesBe(&s, sig_mpi);
    try modPow(&m, &s, &e, &n);

    const em = try allocator.alloc(u8, n_bytes.len);
    defer allocator.free(em);
    try writeBytesBe(&m, em);

    const prefix = try digestInfoPrefix(hash_algo);
    const di_len = prefix.len + digest.len;
    if (em.len < di_len + 11) return error.InvalidSignature;
    if (em[0] != 0x00 or em[1] != 0x01) return error.InvalidSignature;

    var i: usize = 2;
    while (i < em.len and em[i] == 0xff) : (i += 1) {}
    // PKCS#1 requires PS length ≥ 8 → at least 10 bytes before the 0x00 separator.
    if (i < 10 or i >= em.len or em[i] != 0x00) return error.InvalidSignature;
    i += 1;
    if (em.len - i != di_len) return error.InvalidSignature;
    if (!std.mem.eql(u8, em[i .. i + prefix.len], prefix)) return error.InvalidSignature;
    if (!std.mem.eql(u8, em[i + prefix.len ..], digest)) return error.InvalidSignature;
}

fn mpiToFixed(mpi: []const u8, out: []u8) Error!void {
    @memset(out, 0);
    if (mpi.len > out.len) return error.InvalidPacket;
    @memcpy(out[out.len - mpi.len ..], mpi);
}

fn ed25519Verify(pub_key: [32]u8, sig_mpis: []const u8, digest: []const u8) Error!void {
    var pos: usize = 0;
    const r_mpi = try readMpi(sig_mpis, &pos);
    const s_mpi = try readMpi(sig_mpis, &pos);
    var sig_bytes: [64]u8 = .{0} ** 64;
    try mpiToFixed(r_mpi, sig_bytes[0..32]);
    try mpiToFixed(s_mpi, sig_bytes[32..64]);

    const pk = crypto.sign.Ed25519.PublicKey.fromBytes(pub_key) catch return error.InvalidSignature;
    const sig = crypto.sign.Ed25519.Signature.fromBytes(sig_bytes);
    sig.verify(digest, pk) catch return error.InvalidSignature;
}

// ---------------------------------------------------------------------------
// Keyring + public API
// ---------------------------------------------------------------------------

const Keyring = struct {
    keys: std.ArrayList(PublicKey) = .empty,
    allocator: Allocator,

    fn deinit(self: *Keyring) void {
        for (self.keys.items) |*k| k.deinit(self.allocator);
        self.keys.deinit(self.allocator);
    }

    fn findByKeyId(self: *const Keyring, key_id: *const [8]u8) ?*const PublicKey {
        for (self.keys.items) |*k| {
            if (std.mem.eql(u8, k.fingerprint[12..20], key_id)) return k;
        }
        // Single-key rings: allow missing issuer subpacket.
        if (self.keys.items.len == 1) return &self.keys.items[0];
        return null;
    }
};

fn parseKeyring(allocator: Allocator, binary: []const u8) (Allocator.Error || Error)!Keyring {
    var kr: Keyring = .{ .allocator = allocator };
    errdefer kr.deinit();
    var pos: usize = 0;
    while (pos < binary.len) {
        const pkt = nextPacket(binary, &pos) catch break;
        if (pkt.tag == tag_public_key or pkt.tag == tag_public_subkey) {
            const pk = parsePublicKey(allocator, pkt.body) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue, // skip unsupported key types
            };
            try kr.keys.append(allocator, pk);
        }
    }
    if (kr.keys.items.len == 0) return error.KeyNotFound;
    return kr;
}

fn parseDetachedSignature(allocator: Allocator, binary: []const u8) (Allocator.Error || Error)!Signature {
    var pos: usize = 0;
    while (pos < binary.len) {
        const pkt = try nextPacket(binary, &pos);
        if (pkt.tag == tag_signature) return try parseSignature(allocator, pkt.body);
    }
    return error.InvalidPacket;
}

/// Check an armored detached OpenPGP signature against an armored keyring.
pub fn checkArmoredDetachedSignature(
    allocator: Allocator,
    armored_keyring: []const u8,
    message: []const u8,
    armored_signature: []const u8,
) (Allocator.Error || Error)!void {
    const key_bin = try decodeArmor(allocator, armored_keyring);
    defer allocator.free(key_bin);
    const sig_bin = try decodeArmor(allocator, armored_signature);
    defer allocator.free(sig_bin);

    var kr = try parseKeyring(allocator, key_bin);
    defer kr.deinit();

    var sig = try parseDetachedSignature(allocator, sig_bin);
    defer sig.deinit(allocator);

    const pk = kr.findByKeyId(&sig.key_id) orelse return error.KeyNotFound;

    const digest_buf = try hashDocument(sig.hash_algo, message, &sig);
    const dlen = try hashDigestLen(sig.hash_algo);
    const digest = digest_buf[0..dlen];

    if (digest.len >= 2 and (digest[0] != sig.left16[0] or digest[1] != sig.left16[1])) {
        return error.InvalidSignature;
    }

    switch (sig.pub_algo) {
        pk_rsa, pk_rsa_sign, pk_rsa_encrypt => {
            if (pk.n.len == 0) return error.KeyNotFound;
            var mpi_pos: usize = 0;
            const s_mpi = try readMpi(sig.mpis, &mpi_pos);
            try rsaVerify(allocator, pk.n, pk.e, s_mpi, digest, sig.hash_algo);
        },
        pk_eddsa => {
            const ed = pk.ed25519 orelse return error.KeyNotFound;
            try ed25519Verify(ed, sig.mpis, digest);
        },
        else => return error.UnsupportedAlgorithm,
    }
}

// ---------------------------------------------------------------------------
// Armor encode
// ---------------------------------------------------------------------------

fn crc24(data: []const u8) u32 {
    var crc: u32 = 0xb704ce;
    for (data) |b| {
        crc ^= @as(u32, b) << 16;
        var i: u4 = 0;
        while (i < 8) : (i += 1) {
            crc <<= 1;
            if ((crc & 0x1000000) != 0) crc ^= 0x1864cfb;
        }
    }
    return crc & 0xffffff;
}

/// Encode binary OpenPGP data as an ASCII-armored block (`PGP SIGNATURE`, etc.).
pub fn encodeArmor(allocator: Allocator, block_type: []const u8, binary: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "-----BEGIN ");
    try out.appendSlice(allocator, block_type);
    try out.appendSlice(allocator, "-----\n\n");

    const enc_len = std.base64.standard.Encoder.calcSize(binary.len);
    const b64 = try allocator.alloc(u8, enc_len);
    defer allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, binary);

    // 64-char lines (OpenPGP armor convention).
    var off: usize = 0;
    while (off < b64.len) {
        const n = @min(64, b64.len - off);
        try out.appendSlice(allocator, b64[off .. off + n]);
        try out.append(allocator, '\n');
        off += n;
    }

    const crc = crc24(binary);
    var crc_bytes: [3]u8 = .{
        @intCast((crc >> 16) & 0xff),
        @intCast((crc >> 8) & 0xff),
        @intCast(crc & 0xff),
    };
    var crc_b64: [4]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&crc_b64, &crc_bytes);
    try out.append(allocator, '=');
    try out.appendSlice(allocator, &crc_b64);
    try out.append(allocator, '\n');

    try out.appendSlice(allocator, "-----END ");
    try out.appendSlice(allocator, block_type);
    try out.appendSlice(allocator, "-----\n");

    return try out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Packet / MPI writers
// ---------------------------------------------------------------------------

fn appendPacket(list: *std.ArrayList(u8), allocator: Allocator, tag: u8, body: []const u8) Allocator.Error!void {
    try list.append(allocator, 0xc0 | (tag & 0x3f));
    if (body.len < 192) {
        try list.append(allocator, @intCast(body.len));
    } else if (body.len < 8384) {
        const adj = body.len - 192;
        try list.append(allocator, @intCast((adj >> 8) + 192));
        try list.append(allocator, @intCast(adj & 0xff));
    } else {
        try list.append(allocator, 255);
        var lenb: [4]u8 = undefined;
        std.mem.writeInt(u32, &lenb, @intCast(body.len), .big);
        try list.appendSlice(allocator, &lenb);
    }
    try list.appendSlice(allocator, body);
}

fn appendMpi(list: *std.ArrayList(u8), allocator: Allocator, bytes: []const u8) Allocator.Error!void {
    var start: usize = 0;
    while (start < bytes.len and bytes[start] == 0) : (start += 1) {}
    if (start == bytes.len) {
        // Zero MPI: bit length 0, no body.
        try list.appendSlice(allocator, &[_]u8{ 0, 0 });
        return;
    }
    const sig = bytes[start..];
    const high_zeros: u16 = @clz(sig[0]);
    const bitlen: u16 = @intCast(sig.len * 8 - high_zeros);
    var hdr: [2]u8 = undefined;
    std.mem.writeInt(u16, &hdr, bitlen, .big);
    try list.appendSlice(allocator, &hdr);
    try list.appendSlice(allocator, sig);
}

fn appendSubpacket(list: *std.ArrayList(u8), allocator: Allocator, typ: u8, data: []const u8, critical: bool) Allocator.Error!void {
    const body_len = 1 + data.len; // type + data
    if (body_len < 192) {
        try list.append(allocator, @intCast(body_len));
    } else if (body_len < 8384) {
        const adj = body_len - 192;
        try list.append(allocator, @intCast((adj >> 8) + 192));
        try list.append(allocator, @intCast(adj & 0xff));
    } else {
        try list.append(allocator, 255);
        var lenb: [4]u8 = undefined;
        std.mem.writeInt(u32, &lenb, @intCast(body_len), .big);
        try list.appendSlice(allocator, &lenb);
    }
    const t: u8 = if (critical) typ | 0x80 else typ;
    try list.append(allocator, t);
    try list.appendSlice(allocator, data);
}

// ---------------------------------------------------------------------------
// S2K (RFC 4880 §3.7) + AES-CFB secret-key decrypt
// ---------------------------------------------------------------------------

fn s2kCount(count_octet: u8) usize {
    return (@as(usize, 16) + (count_octet & 15)) << @as(u6, @intCast((count_octet >> 4) + 6));
}

fn cipherKeyLen(cipher_algo: u8) Error!usize {
    return switch (cipher_algo) {
        cipher_aes128 => 16,
        cipher_aes192 => 24,
        cipher_aes256 => 32,
        else => error.UnsupportedAlgorithm,
    };
}

fn cipherBlockLen(cipher_algo: u8) Error!usize {
    return switch (cipher_algo) {
        cipher_aes128, cipher_aes192, cipher_aes256 => 16,
        else => error.UnsupportedAlgorithm,
    };
}

fn hashDigestSize(hash_algo: u8) Error!usize {
    return switch (hash_algo) {
        hash_sha1 => 20,
        hash_sha256 => 32,
        hash_sha512 => 64,
        else => error.UnsupportedAlgorithm,
    };
}

/// OpenPGP S2K key derivation filling `out` (may span multiple hash iterations).
///
/// - type 0 Simple: hash(passphrase) with zero preload
/// - type 1 Salted: hash(salt||passphrase)
/// - type 3 Iterated+Salted: hash repeated over salt||passphrase to `count` bytes
pub fn s2kDerive(
    out: []u8,
    passphrase: []const u8,
    salt: []const u8,
    count: usize,
    s2k_type: u8,
    hash_algo: u8,
) Error!void {
    switch (s2k_type) {
        s2k_simple => try s2kHashFill(out, passphrase, &.{}, 0, false, hash_algo),
        s2k_salted => try s2kHashFill(out, passphrase, salt, 0, false, hash_algo),
        s2k_iterated => try s2kHashFill(out, passphrase, salt, count, true, hash_algo),
        else => return error.UnsupportedAlgorithm,
    }
}

fn s2kHashFill(
    out: []u8,
    passphrase: []const u8,
    salt: []const u8,
    count: usize,
    iterated: bool,
    hash_algo: u8,
) Error!void {
    const dig_len = try hashDigestSize(hash_algo);
    const combined_len = salt.len + passphrase.len;
    const eff_count: usize = if (!iterated)
        combined_len // Salted/Simple: single salt||pass (or just pass)
    else if (count < combined_len)
        combined_len
    else
        count;

    var done: usize = 0;
    var i: usize = 0;
    while (done < out.len) : (i += 1) {
        var dig_buf: [64]u8 = undefined;
        const dig = dig_buf[0..dig_len];
        switch (hash_algo) {
            hash_sha1 => {
                var h = crypto.hash.Sha1.init(.{});
                var z: usize = 0;
                while (z < i) : (z += 1) h.update(&[_]u8{0});
                s2kUpdateHash(&h, salt, passphrase, combined_len, eff_count, iterated);
                var d: [20]u8 = undefined;
                h.final(&d);
                @memcpy(dig, &d);
            },
            hash_sha256 => {
                var h = crypto.hash.sha2.Sha256.init(.{});
                var z: usize = 0;
                while (z < i) : (z += 1) h.update(&[_]u8{0});
                s2kUpdateHash(&h, salt, passphrase, combined_len, eff_count, iterated);
                var d: [32]u8 = undefined;
                h.final(&d);
                @memcpy(dig, &d);
            },
            hash_sha512 => {
                var h = crypto.hash.sha2.Sha512.init(.{});
                var z: usize = 0;
                while (z < i) : (z += 1) h.update(&[_]u8{0});
                s2kUpdateHash(&h, salt, passphrase, combined_len, eff_count, iterated);
                h.final(dig[0..64]);
            },
            else => return error.UnsupportedAlgorithm,
        }
        const n = @min(dig_len, out.len - done);
        @memcpy(out[done..][0..n], dig[0..n]);
        done += n;
    }
}

fn s2kUpdateHash(h: anytype, salt: []const u8, passphrase: []const u8, combined_len: usize, eff_count: usize, iterated: bool) void {
    if (!iterated) {
        // Simple: salt empty; Salted: salt then passphrase once.
        h.update(salt);
        h.update(passphrase);
        return;
    }
    var written: usize = 0;
    while (written < eff_count) {
        const remaining = eff_count - written;
        if (remaining >= combined_len) {
            h.update(salt);
            h.update(passphrase);
            written += combined_len;
        } else {
            if (remaining <= salt.len) {
                h.update(salt[0..remaining]);
            } else {
                h.update(salt);
                h.update(passphrase[0 .. remaining - salt.len]);
            }
            written = eff_count;
        }
    }
}

// ---------------------------------------------------------------------------
// AES-192 block encrypt (Zig std only ships Aes128 / Aes256)
// ---------------------------------------------------------------------------

/// Compact AES-192 encrypt (12 rounds). Used only for OpenPGP CFB.
const Aes192 = struct {
    const rounds = 12;
    round_keys: [rounds + 1][16]u8,

    fn initEnc(key: *const [24]u8) Aes192 {
        // Key expansion (FIPS-197) for Nk=6, Nr=12.
        var w: [52]u32 = undefined;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            w[i] = std.mem.readInt(u32, key[4 * i ..][0..4], .big);
        }
        while (i < 52) : (i += 1) {
            var temp = w[i - 1];
            if (i % 6 == 0) {
                temp = subWord(rotWord(temp)) ^ (@as(u32, rcon[i / 6]) << 24);
            }
            w[i] = w[i - 6] ^ temp;
        }
        var rk: [rounds + 1][16]u8 = undefined;
        i = 0;
        while (i < rounds + 1) : (i += 1) {
            var j: usize = 0;
            while (j < 4) : (j += 1) {
                std.mem.writeInt(u32, rk[i][4 * j ..][0..4], w[i * 4 + j], .big);
            }
        }
        return .{ .round_keys = rk };
    }

    fn encrypt(self: *const Aes192, dst: *[16]u8, src: *const [16]u8) void {
        var s: [16]u8 = src.*;
        xorBlock(&s, &self.round_keys[0]);
        var r: usize = 1;
        while (r < rounds) : (r += 1) {
            subBytes(&s);
            shiftRows(&s);
            mixColumns(&s);
            xorBlock(&s, &self.round_keys[r]);
        }
        subBytes(&s);
        shiftRows(&s);
        xorBlock(&s, &self.round_keys[rounds]);
        dst.* = s;
    }

    fn rotWord(x: u32) u32 {
        return (x << 8) | (x >> 24);
    }
    fn subWord(x: u32) u32 {
        return (@as(u32, sbox[(x >> 24) & 0xff]) << 24) |
            (@as(u32, sbox[(x >> 16) & 0xff]) << 16) |
            (@as(u32, sbox[(x >> 8) & 0xff]) << 8) |
            @as(u32, sbox[x & 0xff]);
    }
    fn xorBlock(s: *[16]u8, rk: *const [16]u8) void {
        for (s, rk) |*a, b| a.* ^= b;
    }
    fn subBytes(s: *[16]u8) void {
        for (s) |*b| b.* = sbox[b.*];
    }
    fn shiftRows(s: *[16]u8) void {
        // row 1
        const t1 = s[1];
        s[1] = s[5];
        s[5] = s[9];
        s[9] = s[13];
        s[13] = t1;
        // row 2
        const t2a = s[2];
        const t2b = s[6];
        s[2] = s[10];
        s[6] = s[14];
        s[10] = t2a;
        s[14] = t2b;
        // row 3
        const t3 = s[15];
        s[15] = s[11];
        s[11] = s[7];
        s[7] = s[3];
        s[3] = t3;
    }
    fn xtime(a: u8) u8 {
        return (a << 1) ^ (0x1b & -%(@as(u8, @intFromBool((a & 0x80) != 0))));
    }
    fn mixColumns(s: *[16]u8) void {
        var c: usize = 0;
        while (c < 4) : (c += 1) {
            const i = c * 4;
            const a0 = s[i];
            const a1 = s[i + 1];
            const a2 = s[i + 2];
            const a3 = s[i + 3];
            const t = a0 ^ a1 ^ a2 ^ a3;
            s[i] ^= t ^ xtime(a0 ^ a1);
            s[i + 1] ^= t ^ xtime(a1 ^ a2);
            s[i + 2] ^= t ^ xtime(a2 ^ a3);
            s[i + 3] ^= t ^ xtime(a3 ^ a0);
        }
    }

    const rcon = [_]u8{ 0, 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36 };
    const sbox = [_]u8{
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
    };
};

fn aesBlockEncrypt(key: []const u8, dst: *[16]u8, src: *const [16]u8) Error!void {
    switch (key.len) {
        16 => {
            const ctx = crypto.core.aes.Aes128.initEnc(key[0..16].*);
            ctx.encrypt(dst, src);
        },
        24 => {
            const ctx = Aes192.initEnc(key[0..24]);
            ctx.encrypt(dst, src);
        },
        32 => {
            const ctx = crypto.core.aes.Aes256.initEnc(key[0..32].*);
            ctx.encrypt(dst, src);
        },
        else => return error.UnsupportedAlgorithm,
    }
}

/// AES-CFB-128 decrypt (OpenPGP secret-key encryption; fre starts as IV).
fn aesCfbDecrypt(key: []const u8, iv: *const [16]u8, ciphertext: []const u8, plaintext: []u8) Error!void {
    std.debug.assert(plaintext.len >= ciphertext.len);
    var fre: [16]u8 = iv.*;
    var off: usize = 0;
    while (off < ciphertext.len) {
        var keystream: [16]u8 = undefined;
        try aesBlockEncrypt(key, &keystream, &fre);
        const n = @min(16, ciphertext.len - off);
        var j: usize = 0;
        while (j < n) : (j += 1) {
            plaintext[off + j] = ciphertext[off + j] ^ keystream[j];
        }
        if (n == 16) {
            @memcpy(&fre, ciphertext[off..][0..16]);
        }
        off += n;
    }
}

/// AES-CFB-128 encrypt (test helper / seal path).
fn aesCfbEncrypt(key: []const u8, iv: *const [16]u8, plaintext: []const u8, ciphertext: []u8) Error!void {
    std.debug.assert(ciphertext.len >= plaintext.len);
    var fre: [16]u8 = iv.*;
    var off: usize = 0;
    while (off < plaintext.len) {
        var keystream: [16]u8 = undefined;
        try aesBlockEncrypt(key, &keystream, &fre);
        const n = @min(16, plaintext.len - off);
        var j: usize = 0;
        while (j < n) : (j += 1) {
            ciphertext[off + j] = plaintext[off + j] ^ keystream[j];
        }
        if (n == 16) {
            @memcpy(&fre, ciphertext[off..][0..16]);
        }
        off += n;
    }
}

// ---------------------------------------------------------------------------
// Key material (primary or subkey) + Entity
// ---------------------------------------------------------------------------

/// Secret/public key material shared by primary keys and subkeys.
pub const KeyMaterial = struct {
    algo: u8 = 0,
    fingerprint: [20]u8 = .{0} ** 20,
    /// Public RSA modulus (owned).
    n: []u8 = &.{},
    /// Public RSA exponent (owned).
    e: []u8 = &.{},
    ed25519_pub: ?[32]u8 = null,
    /// Ed25519 secret seed (32 bytes) after decrypt / generate.
    ed25519_seed: ?[32]u8 = null,
    /// True while secret material is still encrypted.
    encrypted: bool = false,
    /// RSA private exponent after decrypt (owned).
    d: []u8 = &.{},
    /// Public-key packet body (v4, owned) for fingerprint / serialize.
    public_body: []u8 = &.{},
    // Encrypted secret state (cleared after successful decrypt).
    s2k_usage: u8 = 0,
    cipher_algo: u8 = 0,
    s2k_type: u8 = 0,
    s2k_hash: u8 = 0,
    salt: [8]u8 = .{0} ** 8,
    count_octet: u8 = 0,
    iv: []u8 = &.{},
    encrypted_data: []u8 = &.{},
    /// Key flags from self-signature type-27 subpacket; null if absent.
    key_flags: ?u8 = null,

    fn deinit(self: *KeyMaterial, allocator: Allocator) void {
        if (self.n.len > 0) allocator.free(self.n);
        if (self.e.len > 0) allocator.free(self.e);
        if (self.d.len > 0) allocator.free(self.d);
        if (self.public_body.len > 0) allocator.free(self.public_body);
        if (self.iv.len > 0) allocator.free(self.iv);
        if (self.encrypted_data.len > 0) allocator.free(self.encrypted_data);
        self.* = .{};
    }

    /// Key id = last 8 bytes of v4 fingerprint.
    pub fn keyId(self: *const KeyMaterial) [8]u8 {
        var id: [8]u8 = undefined;
        @memcpy(&id, self.fingerprint[12..20]);
        return id;
    }

    fn hasPrivateMaterial(self: *const KeyMaterial) bool {
        return switch (self.algo) {
            pk_rsa, pk_rsa_sign, pk_rsa_encrypt => self.d.len > 0,
            pk_eddsa => self.ed25519_seed != null,
            else => false,
        };
    }

    /// Sign-capable: RSA/EdDSA and (no flags | sign flag set).
    fn canSign(self: *const KeyMaterial) bool {
        const algo_ok = switch (self.algo) {
            pk_rsa, pk_rsa_sign, pk_eddsa => true,
            else => false,
        };
        if (!algo_ok) return false;
        if (self.key_flags) |f| return (f & key_flag_sign) != 0;
        // Flags absent: allow RSA/EdDSA (older keys / constructed test keys).
        return true;
    }

    /// Decrypt secret MPIs with passphrase (OpenPGP S2K + AES-CFB).
    pub fn decrypt(self: *KeyMaterial, allocator: Allocator, passphrase: []const u8) (Allocator.Error || Error)!void {
        if (!self.encrypted) return;
        if (self.encrypted_data.len == 0) return error.DecryptFailed;
        if (self.s2k_usage != 254 and self.s2k_usage != 255) return error.UnsupportedAlgorithm;

        const key_len = try cipherKeyLen(self.cipher_algo);
        const block_len = try cipherBlockLen(self.cipher_algo);
        if (self.iv.len != block_len) return error.InvalidPacket;

        var key_buf: [32]u8 = undefined;
        const key = key_buf[0..key_len];
        const count: usize = if (self.s2k_type == s2k_iterated) s2kCount(self.count_octet) else 0;
        const salt_slice: []const u8 = if (self.s2k_type == s2k_simple) &.{} else self.salt[0..];
        try s2kDerive(key, passphrase, salt_slice, count, self.s2k_type, self.s2k_hash);

        const plain = try allocator.alloc(u8, self.encrypted_data.len);
        defer allocator.free(plain);
        try aesCfbDecrypt(key, self.iv[0..16], self.encrypted_data, plain);

        if (self.s2k_usage == 254) {
            if (plain.len < 20) return error.DecryptFailed;
            var h = crypto.hash.Sha1.init(.{});
            h.update(plain[0 .. plain.len - 20]);
            var sum: [20]u8 = undefined;
            h.final(&sum);
            if (!std.mem.eql(u8, &sum, plain[plain.len - 20 ..])) return error.DecryptFailed;
            try self.parseSecretMpIs(allocator, plain[0 .. plain.len - 20]);
        } else {
            if (plain.len < 2) return error.DecryptFailed;
            var sum: u16 = 0;
            for (plain[0 .. plain.len - 2]) |b| sum +%= b;
            const got = std.mem.readInt(u16, plain[plain.len - 2 ..][0..2], .big);
            if (got != sum) return error.DecryptFailed;
            try self.parseSecretMpIs(allocator, plain[0 .. plain.len - 2]);
        }

        self.encrypted = false;
        if (self.encrypted_data.len > 0) {
            allocator.free(self.encrypted_data);
            self.encrypted_data = &.{};
        }
        if (self.iv.len > 0) {
            allocator.free(self.iv);
            self.iv = &.{};
        }
    }

    fn parseSecretMpIs(self: *KeyMaterial, allocator: Allocator, data: []const u8) (Allocator.Error || Error)!void {
        switch (self.algo) {
            pk_rsa, pk_rsa_sign, pk_rsa_encrypt => {
                var pos: usize = 0;
                const d_mpi = try readMpi(data, &pos);
                _ = readMpi(data, &pos) catch {};
                _ = readMpi(data, &pos) catch {};
                if (self.d.len > 0) allocator.free(self.d);
                self.d = try allocator.dupe(u8, d_mpi);
            },
            pk_eddsa => {
                var pos: usize = 0;
                const seed_mpi = try readMpi(data, &pos);
                var seed: [32]u8 = .{0} ** 32;
                if (seed_mpi.len > 32) return error.InvalidPacket;
                @memcpy(seed[32 - seed_mpi.len ..], seed_mpi);
                self.ed25519_seed = seed;
            },
            else => return error.UnsupportedAlgorithm,
        }
    }
};

/// Subkey is key material attached to an Entity (go-crypto `openpgp.Subkey`).
pub const Subkey = KeyMaterial;

/// OpenPGP signing entity (subset of go-crypto `openpgp.Entity` / `packet.PrivateKey`).
pub const Entity = struct {
    allocator: Allocator,
    algo: u8 = 0,
    fingerprint: [20]u8 = .{0} ** 20,
    /// Public RSA modulus (owned).
    n: []u8 = &.{},
    /// Public RSA exponent (owned).
    e: []u8 = &.{},
    ed25519_pub: ?[32]u8 = null,
    /// Ed25519 secret seed (32 bytes) after decrypt / generate.
    ed25519_seed: ?[32]u8 = null,
    /// True while primary secret material is still encrypted.
    encrypted: bool = false,
    /// RSA private exponent after decrypt (owned).
    d: []u8 = &.{},
    /// Optional identity string (owned, e.g. "foo bar <foo@foo.foo>").
    identity: []u8 = &.{},
    /// Public-key packet body (v4, owned) for fingerprint / serialize.
    public_body: []u8 = &.{},
    // Encrypted secret state (cleared after successful decrypt).
    s2k_usage: u8 = 0,
    cipher_algo: u8 = 0,
    s2k_type: u8 = 0,
    s2k_hash: u8 = 0,
    salt: [8]u8 = .{0} ** 8,
    count_octet: u8 = 0,
    iv: []u8 = &.{},
    encrypted_data: []u8 = &.{},
    /// Key flags from primary self-signature; null if absent.
    key_flags: ?u8 = null,
    /// Owned subkeys (secret and/or public).
    subkeys: []Subkey = &.{},

    pub fn deinit(self: *Entity) void {
        const a = self.allocator;
        if (self.n.len > 0) a.free(self.n);
        if (self.e.len > 0) a.free(self.e);
        if (self.d.len > 0) a.free(self.d);
        if (self.identity.len > 0) a.free(self.identity);
        if (self.public_body.len > 0) a.free(self.public_body);
        if (self.iv.len > 0) a.free(self.iv);
        if (self.encrypted_data.len > 0) a.free(self.encrypted_data);
        for (self.subkeys) |*sk| sk.deinit(a);
        if (self.subkeys.len > 0) a.free(self.subkeys);
        self.* = .{ .allocator = a };
    }

    /// Key id = last 8 bytes of primary v4 fingerprint.
    pub fn keyId(self: *const Entity) [8]u8 {
        var id: [8]u8 = undefined;
        @memcpy(&id, self.fingerprint[12..20]);
        return id;
    }

    fn primaryAsKeyMaterial(self: *Entity) KeyMaterial {
        return .{
            .algo = self.algo,
            .fingerprint = self.fingerprint,
            .n = self.n,
            .e = self.e,
            .ed25519_pub = self.ed25519_pub,
            .ed25519_seed = self.ed25519_seed,
            .encrypted = self.encrypted,
            .d = self.d,
            .public_body = self.public_body,
            .s2k_usage = self.s2k_usage,
            .cipher_algo = self.cipher_algo,
            .s2k_type = self.s2k_type,
            .s2k_hash = self.s2k_hash,
            .salt = self.salt,
            .count_octet = self.count_octet,
            .iv = self.iv,
            .encrypted_data = self.encrypted_data,
            .key_flags = self.key_flags,
        };
    }

    fn storePrimaryFromKeyMaterial(self: *Entity, km: KeyMaterial) void {
        self.algo = km.algo;
        self.fingerprint = km.fingerprint;
        self.n = km.n;
        self.e = km.e;
        self.ed25519_pub = km.ed25519_pub;
        self.ed25519_seed = km.ed25519_seed;
        self.encrypted = km.encrypted;
        self.d = km.d;
        self.public_body = km.public_body;
        self.s2k_usage = km.s2k_usage;
        self.cipher_algo = km.cipher_algo;
        self.s2k_type = km.s2k_type;
        self.s2k_hash = km.s2k_hash;
        self.salt = km.salt;
        self.count_octet = km.count_octet;
        self.iv = km.iv;
        self.encrypted_data = km.encrypted_data;
        self.key_flags = km.key_flags;
    }

    /// Decrypt primary and all encrypted subkeys with the same passphrase.
    ///
    /// Matches go-crypto `Entity.DecryptPrivateKeys` for Git signing use.
    pub fn decrypt(self: *Entity, passphrase: []const u8) (Allocator.Error || Error)!void {
        var primary = self.primaryAsKeyMaterial();
        // Decrypt primary if encrypted; leave already-clear keys alone.
        if (primary.encrypted) {
            try primary.decrypt(self.allocator, passphrase);
            self.storePrimaryFromKeyMaterial(primary);
        }
        // Decrypt subkeys; first failure aborts (wrong passphrase).
        for (self.subkeys) |*sk| {
            if (sk.encrypted) try sk.decrypt(self.allocator, passphrase);
        }
    }

    fn hasPrivateMaterial(self: *const Entity) bool {
        return switch (self.algo) {
            pk_rsa, pk_rsa_sign, pk_rsa_encrypt => self.d.len > 0,
            pk_eddsa => self.ed25519_seed != null,
            else => false,
        };
    }

    fn canSignPrimary(self: *const Entity) bool {
        const algo_ok = switch (self.algo) {
            pk_rsa, pk_rsa_sign, pk_eddsa => true,
            else => false,
        };
        if (!algo_ok) return false;
        if (self.key_flags) |f| return (f & key_flag_sign) != 0;
        return true;
    }

    /// Armored public key block for `Tag.verify` / `checkArmoredDetachedSignature`.
    /// Includes primary public packet, identity, and subkey public packets.
    pub fn serializePublicArmored(self: *const Entity, allocator: Allocator) (Allocator.Error || Error)![]u8 {
        if (self.public_body.len == 0) return error.InvalidPacket;
        var bin: std.ArrayList(u8) = .empty;
        defer bin.deinit(allocator);
        try appendPacket(&bin, allocator, tag_public_key, self.public_body);
        if (self.identity.len > 0) {
            try appendPacket(&bin, allocator, tag_user_id, self.identity);
        }
        for (self.subkeys) |sk| {
            if (sk.public_body.len > 0) {
                try appendPacket(&bin, allocator, tag_public_subkey, sk.public_body);
            }
        }
        return encodeArmor(allocator, "PGP PUBLIC KEY BLOCK", bin.items);
    }
};

/// Selected signing material (primary or subkey view).
const SigningSelection = struct {
    algo: u8,
    fingerprint: [20]u8,
    n: []const u8 = &.{},
    d: []const u8 = &.{},
    ed25519_seed: ?[32]u8 = null,

    fn keyId(self: *const SigningSelection) [8]u8 {
        var id: [8]u8 = undefined;
        @memcpy(&id, self.fingerprint[12..20]);
        return id;
    }
};

fn signingSelectionFromKeyMaterial(km: *const KeyMaterial) SigningSelection {
    return .{
        .algo = km.algo,
        .fingerprint = km.fingerprint,
        .n = km.n,
        .d = km.d,
        .ed25519_seed = km.ed25519_seed,
    };
}

/// Select signing key (go-crypto `Entity.SigningKey` intent).
///
/// Preference:
/// 1. Last decrypted subkey with **explicit** sign flag (type 27 bit 1)
/// 2. Last decrypted subkey that can sign without flags (legacy keys)
/// 3. Primary if decrypted, has private material, and can sign
///
/// "Last" matches typical keyring order (newer subkeys appended) when
/// multiple signing subkeys exist.
fn selectSigningKey(entity: *const Entity) Error!SigningSelection {
    var best_flagged: ?*const KeyMaterial = null;
    var best_unflagged: ?*const KeyMaterial = null;
    for (entity.subkeys) |*sk| {
        if (sk.encrypted) continue;
        if (!sk.hasPrivateMaterial()) continue;
        if (!sk.canSign()) continue;
        if (sk.key_flags) |f| {
            if ((f & key_flag_sign) != 0) best_flagged = sk;
        } else {
            best_unflagged = sk;
        }
    }
    if (best_flagged) |sk| return signingSelectionFromKeyMaterial(sk);
    if (best_unflagged) |sk| return signingSelectionFromKeyMaterial(sk);

    if (entity.encrypted) return error.EncryptedKey;
    if (!entity.hasPrivateMaterial()) return error.NoPrivateKey;
    if (!entity.canSignPrimary()) return error.NoPrivateKey;
    return .{
        .algo = entity.algo,
        .fingerprint = entity.fingerprint,
        .n = entity.n,
        .d = entity.d,
        .ed25519_seed = entity.ed25519_seed,
    };
}

/// Free a slice returned by `readArmoredKeyRing`.
pub fn freeEntities(allocator: Allocator, entities: []Entity) void {
    for (entities) |*e| e.deinit();
    allocator.free(entities);
}

fn publicMaterialEnd(body: []const u8) Error!usize {
    if (body.len < 6 or body[0] != 4) return error.UnsupportedAlgorithm;
    const algo = body[5];
    var pos: usize = 6;
    switch (algo) {
        pk_rsa, pk_rsa_encrypt, pk_rsa_sign => {
            _ = try readMpi(body, &pos);
            _ = try readMpi(body, &pos);
        },
        pk_eddsa => {
            if (pos >= body.len) return error.InvalidPacket;
            const oid_len = body[pos];
            pos += 1;
            if (pos + oid_len > body.len) return error.InvalidPacket;
            pos += oid_len;
            _ = try readMpi(body, &pos);
        },
        else => return error.UnsupportedAlgorithm,
    }
    return pos;
}

fn parseSecretKeyMaterial(allocator: Allocator, body: []const u8) (Allocator.Error || Error)!KeyMaterial {
    const pub_end = try publicMaterialEnd(body);
    const public_body = try allocator.dupe(u8, body[0..pub_end]);
    errdefer allocator.free(public_body);

    var pk = try parsePublicKey(allocator, public_body);
    defer pk.deinit(allocator);

    var km: KeyMaterial = .{
        .algo = pk.algo,
        .fingerprint = pk.fingerprint,
        .public_body = public_body,
        .ed25519_pub = pk.ed25519,
    };
    errdefer km.deinit(allocator);

    if (pk.n.len > 0) km.n = try allocator.dupe(u8, pk.n);
    if (pk.e.len > 0) km.e = try allocator.dupe(u8, pk.e);

    var pos = pub_end;
    if (pos >= body.len) return error.InvalidPacket;
    const s2k_usage = body[pos];
    pos += 1;
    km.s2k_usage = s2k_usage;

    if (s2k_usage == 0) {
        // Unencrypted secret MPIs + 2-byte checksum.
        if (pos + 2 > body.len) return error.InvalidPacket;
        const secret = body[pos .. body.len - 2];
        try km.parseSecretMpIs(allocator, secret);
        km.encrypted = false;
        return km;
    }

    if (s2k_usage == 254 or s2k_usage == 255) {
        if (pos >= body.len) return error.InvalidPacket;
        km.cipher_algo = body[pos];
        pos += 1;
        if (pos >= body.len) return error.InvalidPacket;
        km.s2k_type = body[pos];
        pos += 1;
        if (pos >= body.len) return error.InvalidPacket;
        km.s2k_hash = body[pos];
        pos += 1;
        if (km.s2k_type == s2k_salted or km.s2k_type == s2k_iterated) {
            if (pos + 8 > body.len) return error.InvalidPacket;
            @memcpy(km.salt[0..8], body[pos .. pos + 8]);
            pos += 8;
        } else if (km.s2k_type != s2k_simple) {
            return error.UnsupportedAlgorithm;
        }
        if (km.s2k_type == s2k_iterated) {
            if (pos >= body.len) return error.InvalidPacket;
            km.count_octet = body[pos];
            pos += 1;
        }
        const iv_len = try cipherBlockLen(km.cipher_algo);
        if (pos + iv_len > body.len) return error.InvalidPacket;
        km.iv = try allocator.dupe(u8, body[pos .. pos + iv_len]);
        pos += iv_len;
        km.encrypted_data = try allocator.dupe(u8, body[pos..]);
        km.encrypted = true;
        return km;
    }

    // s2k_usage 1–253: cipher id, no S2K string — unsupported.
    return error.UnsupportedAlgorithm;
}

fn entityFromKeyMaterial(allocator: Allocator, km: KeyMaterial) Entity {
    return .{
        .allocator = allocator,
        .algo = km.algo,
        .fingerprint = km.fingerprint,
        .n = km.n,
        .e = km.e,
        .ed25519_pub = km.ed25519_pub,
        .ed25519_seed = km.ed25519_seed,
        .encrypted = km.encrypted,
        .d = km.d,
        .public_body = km.public_body,
        .s2k_usage = km.s2k_usage,
        .cipher_algo = km.cipher_algo,
        .s2k_type = km.s2k_type,
        .s2k_hash = km.s2k_hash,
        .salt = km.salt,
        .count_octet = km.count_octet,
        .iv = km.iv,
        .encrypted_data = km.encrypted_data,
        .key_flags = km.key_flags,
    };
}

fn parsePublicKeyMaterial(allocator: Allocator, body: []const u8) (Allocator.Error || Error)!KeyMaterial {
    var pk = try parsePublicKey(allocator, body);
    defer pk.deinit(allocator);
    var km: KeyMaterial = .{
        .algo = pk.algo,
        .fingerprint = pk.fingerprint,
        .ed25519_pub = pk.ed25519,
        .encrypted = false,
        .public_body = try allocator.dupe(u8, body),
    };
    errdefer km.deinit(allocator);
    if (pk.n.len > 0) km.n = try allocator.dupe(u8, pk.n);
    if (pk.e.len > 0) km.e = try allocator.dupe(u8, pk.e);
    return km;
}

fn applySignatureKeyFlags(entity: *Entity, body: []const u8, target_is_subkey: bool) void {
    // Best-effort: pull type-27 flags from hashed subpackets of a v4 signature.
    if (body.len < 6 or body[0] != 4) return;
    const hashed_len = std.mem.readInt(u16, body[4..6], .big);
    if (6 + hashed_len > body.len) return;
    const hashed = body[6 .. 6 + hashed_len];
    const flags = extractKeyFlags(hashed) orelse return;
    if (target_is_subkey) {
        if (entity.subkeys.len > 0) {
            entity.subkeys[entity.subkeys.len - 1].key_flags = flags;
        }
    } else {
        entity.key_flags = flags;
    }
}

/// Parse an armored private or public key ring into entities.
///
/// Caller frees with `freeEntities`. Primary secret/public keys become entities;
/// secret/public subkeys are attached to the current entity.
pub fn readArmoredKeyRing(allocator: Allocator, armored: []const u8) (Allocator.Error || Error)![]Entity {
    const bin = try decodeArmor(allocator, armored);
    defer allocator.free(bin);

    var list: std.ArrayList(Entity) = .empty;
    errdefer {
        for (list.items) |*e| e.deinit();
        list.deinit(allocator);
    }

    var pos: usize = 0;
    var current: ?usize = null;
    // Track whether the last key-like packet was a subkey (for flag application).
    var last_was_subkey = false;
    while (pos < bin.len) {
        const pkt = nextPacket(bin, &pos) catch break;
        switch (pkt.tag) {
            tag_secret_key => {
                const km = try parseSecretKeyMaterial(allocator, pkt.body);
                try list.append(allocator, entityFromKeyMaterial(allocator, km));
                current = list.items.len - 1;
                last_was_subkey = false;
            },
            tag_public_key => {
                const km = parsePublicKeyMaterial(allocator, pkt.body) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => continue,
                };
                try list.append(allocator, entityFromKeyMaterial(allocator, km));
                current = list.items.len - 1;
                last_was_subkey = false;
            },
            tag_secret_subkey => {
                if (current) |ci| {
                    const km = parseSecretKeyMaterial(allocator, pkt.body) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => continue,
                    };
                    const sks = list.items[ci].subkeys;
                    // Grow subkeys slice.
                    const new_sks = try allocator.alloc(Subkey, sks.len + 1);
                    if (sks.len > 0) {
                        @memcpy(new_sks[0..sks.len], sks);
                        allocator.free(sks);
                    }
                    new_sks[sks.len] = km;
                    list.items[ci].subkeys = new_sks;
                    last_was_subkey = true;
                }
            },
            tag_public_subkey => {
                if (current) |ci| {
                    const km = parsePublicKeyMaterial(allocator, pkt.body) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => continue,
                    };
                    const sks = list.items[ci].subkeys;
                    const new_sks = try allocator.alloc(Subkey, sks.len + 1);
                    if (sks.len > 0) {
                        @memcpy(new_sks[0..sks.len], sks);
                        allocator.free(sks);
                    }
                    new_sks[sks.len] = km;
                    list.items[ci].subkeys = new_sks;
                    last_was_subkey = true;
                }
            },
            tag_user_id => {
                if (current) |ci| {
                    if (list.items[ci].identity.len > 0) allocator.free(list.items[ci].identity);
                    list.items[ci].identity = try allocator.dupe(u8, pkt.body);
                    last_was_subkey = false; // following self-sig binds primary / UID
                }
            },
            tag_signature => {
                if (current) |ci| {
                    applySignatureKeyFlags(&list.items[ci], pkt.body, last_was_subkey);
                }
            },
            else => {},
        }
    }
    if (list.items.len == 0) return error.KeyNotFound;
    return try list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// RSA sign + armored detached signature
// ---------------------------------------------------------------------------

fn rsaSign(
    allocator: Allocator,
    n_bytes: []const u8,
    d_bytes: []const u8,
    digest: []const u8,
    hash_algo: u8,
) (Allocator.Error || Error)![]u8 {
    if (n_bytes.len == 0 or d_bytes.len == 0) return error.NoPrivateKey;
    const prefix = try digestInfoPrefix(hash_algo);
    const k = n_bytes.len;
    const di_len = prefix.len + digest.len;
    if (k < di_len + 11) return error.InvalidSignature;

    const em = try allocator.alloc(u8, k);
    defer allocator.free(em);
    @memset(em, 0xff);
    em[0] = 0x00;
    em[1] = 0x01;
    const sep = k - di_len - 1;
    em[sep] = 0x00;
    @memcpy(em[sep + 1 ..][0..prefix.len], prefix);
    @memcpy(em[sep + 1 + prefix.len ..][0..digest.len], digest);

    var n = try Managed.initSet(allocator, 0);
    defer n.deinit();
    var d = try Managed.initSet(allocator, 0);
    defer d.deinit();
    var m = try Managed.initSet(allocator, 0);
    defer m.deinit();
    var s = try Managed.initSet(allocator, 0);
    defer s.deinit();

    try setBytesBe(&n, n_bytes);
    try setBytesBe(&d, d_bytes);
    try setBytesBe(&m, em);
    try modPow(&s, &m, &d, &n);

    const out = try allocator.alloc(u8, k);
    errdefer allocator.free(out);
    try writeBytesBe(&s, out);
    return out;
}

fn buildV4SignaturePacket(
    allocator: Allocator,
    entity: *const Entity,
    message: []const u8,
    hash_algo: u8,
) (Allocator.Error || Error)![]u8 {
    const sk = try selectSigningKey(entity);

    // Hashed subpackets: creation time (critical) + issuer key id of selected key.
    var hashed: std.ArrayList(u8) = .empty;
    defer hashed.deinit(allocator);

    var ctime: [4]u8 = undefined;
    // Zig 0.16: no std.time.timestamp; wall-clock via posix.
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    std.mem.writeInt(u32, &ctime, @intCast(ts.sec), .big);
    try appendSubpacket(&hashed, allocator, 2, &ctime, true);
    const kid = sk.keyId();
    try appendSubpacket(&hashed, allocator, 16, &kid, false);

    // Signature fields hashed as trailer prefix: ver | type | pub | hash | len | hashed
    var prefix: std.ArrayList(u8) = .empty;
    defer prefix.deinit(allocator);
    try prefix.append(allocator, 4); // version
    try prefix.append(allocator, 0x00); // binary
    try prefix.append(allocator, sk.algo);
    try prefix.append(allocator, hash_algo);
    var hlen: [2]u8 = undefined;
    std.mem.writeInt(u16, &hlen, @intCast(hashed.items.len), .big);
    try prefix.appendSlice(allocator, &hlen);
    try prefix.appendSlice(allocator, hashed.items);

    // Temporary Signature view for hashDocument.
    var sig_view: Signature = .{
        .pub_algo = sk.algo,
        .hash_algo = hash_algo,
        .hashed = hashed.items,
        .owned = prefix.items, // hashedData uses owned[0..6+hashed.len]
    };

    const digest_buf = try hashDocument(hash_algo, message, &sig_view);
    const dlen = try hashDigestLen(hash_algo);
    const digest = digest_buf[0..dlen];

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, prefix.items);
    // unhashed length = 0
    try body.appendSlice(allocator, &[_]u8{ 0, 0 });
    // left 16 bits of hash
    try body.append(allocator, digest[0]);
    try body.append(allocator, digest[1]);

    switch (sk.algo) {
        pk_rsa, pk_rsa_sign, pk_rsa_encrypt => {
            const sig_bytes = try rsaSign(allocator, sk.n, sk.d, digest, hash_algo);
            defer allocator.free(sig_bytes);
            try appendMpi(&body, allocator, sig_bytes);
        },
        pk_eddsa => {
            const seed = sk.ed25519_seed orelse return error.NoPrivateKey;
            // OpenPGP EdDSA: sign the hash digest; store R||S as two MPIs.
            const kp = crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch return error.InvalidSignature;
            const sig = kp.sign(digest, null) catch return error.InvalidSignature;
            const sig_bytes = sig.toBytes();
            try appendMpi(&body, allocator, sig_bytes[0..32]);
            try appendMpi(&body, allocator, sig_bytes[32..64]);
        },
        else => return error.UnsupportedAlgorithm,
    }

    var packet: std.ArrayList(u8) = .empty;
    errdefer packet.deinit(allocator);
    try appendPacket(&packet, allocator, tag_signature, body.items);
    return try packet.toOwnedSlice(allocator);
}

/// go-git / go-crypto `openpgp.ArmoredDetachSign` (binary document signature).
///
/// Uses the selected signing key (prefer decrypted sign-capable subkey, else primary).
/// Entity keys used for signing must be decrypted. Default hash is SHA-256.
/// Caller frees the result.
pub fn armoredDetachSign(
    allocator: Allocator,
    entity: *const Entity,
    message: []const u8,
) (Allocator.Error || Error)![]u8 {
    // selectSigningKey runs inside buildV4SignaturePacket (EncryptedKey / NoPrivateKey).
    const bin = try buildV4SignaturePacket(allocator, entity, message, hash_sha256);
    defer allocator.free(bin);
    return encodeArmor(allocator, "PGP SIGNATURE", bin);
}

fn buildEd25519PublicBody(allocator: Allocator, pub_bytes: *const [32]u8) Allocator.Error![]u8 {
    // v4 public key body: ver | ctime | algo | oid_len | oid | MPI(0x40||point)
    // Ed25519 OID: 1.3.6.1.4.1.11591.15.1
    const oid = [_]u8{ 0x2b, 0x06, 0x01, 0x04, 0x01, 0xda, 0x47, 0x0f, 0x01 };
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    try body.append(allocator, 4);
    try body.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 }); // ctime
    try body.append(allocator, pk_eddsa);
    try body.append(allocator, @intCast(oid.len));
    try body.appendSlice(allocator, &oid);
    var point: [33]u8 = undefined;
    point[0] = 0x40;
    @memcpy(point[1..], pub_bytes);
    try appendMpi(&body, allocator, &point);
    return try body.toOwnedSlice(allocator);
}

/// Build an unencrypted Ed25519 Entity for tests (algo 22 / EdDSA).
///
/// `seed` is the 32-byte Ed25519 seed. Caller owns the Entity (`deinit`).
pub fn generateEd25519Entity(allocator: Allocator, seed: [32]u8) (Allocator.Error || Error)!Entity {
    const kp = crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch return error.InvalidSignature;
    const pub_bytes = kp.public_key.bytes;
    const public_body = try buildEd25519PublicBody(allocator, &pub_bytes);
    errdefer allocator.free(public_body);
    const fp = fingerprintV4(public_body);

    return .{
        .allocator = allocator,
        .algo = pk_eddsa,
        .fingerprint = fp,
        .ed25519_pub = pub_bytes,
        .ed25519_seed = seed,
        .encrypted = false,
        .public_body = public_body,
    };
}

/// Build unencrypted Ed25519 subkey material (for tests / in-memory attachment).
pub fn generateEd25519Subkey(allocator: Allocator, seed: [32]u8) (Allocator.Error || Error)!Subkey {
    const kp = crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch return error.InvalidSignature;
    const pub_bytes = kp.public_key.bytes;
    const public_body = try buildEd25519PublicBody(allocator, &pub_bytes);
    errdefer allocator.free(public_body);
    return .{
        .algo = pk_eddsa,
        .fingerprint = fingerprintV4(public_body),
        .ed25519_pub = pub_bytes,
        .ed25519_seed = seed,
        .encrypted = false,
        .public_body = public_body,
        .key_flags = key_flag_sign, // signing subkey
    };
}

/// Attach a subkey to an entity (takes ownership of `sub`).
pub fn entityAttachSubkey(entity: *Entity, sub: Subkey) Allocator.Error!void {
    const a = entity.allocator;
    const old = entity.subkeys;
    const new_sks = try a.alloc(Subkey, old.len + 1);
    if (old.len > 0) {
        @memcpy(new_sks[0..old.len], old);
        a.free(old);
    }
    new_sks[old.len] = sub;
    entity.subkeys = new_sks;
}

/// Seal secret MPI bytes with usage-254 AES-CFB (test helper).
fn sealSecretUsage254(
    allocator: Allocator,
    secret_mpis: []const u8,
    passphrase: []const u8,
    salt: *const [8]u8,
    count_octet: u8,
    iv: *const [16]u8,
    cipher_algo: u8,
    s2k_type: u8,
    s2k_hash: u8,
) (Allocator.Error || Error)!struct { iv: []u8, data: []u8 } {
    // plaintext = secret || SHA1(secret)
    var h = crypto.hash.Sha1.init(.{});
    h.update(secret_mpis);
    var sum: [20]u8 = undefined;
    h.final(&sum);
    const plain = try allocator.alloc(u8, secret_mpis.len + 20);
    defer allocator.free(plain);
    @memcpy(plain[0..secret_mpis.len], secret_mpis);
    @memcpy(plain[secret_mpis.len..], &sum);

    const key_len = try cipherKeyLen(cipher_algo);
    var key_buf: [32]u8 = undefined;
    const key = key_buf[0..key_len];
    const count: usize = if (s2k_type == s2k_iterated) s2kCount(count_octet) else 0;
    const salt_slice: []const u8 = if (s2k_type == s2k_simple) &.{} else salt[0..];
    try s2kDerive(key, passphrase, salt_slice, count, s2k_type, s2k_hash);

    const ct = try allocator.alloc(u8, plain.len);
    errdefer allocator.free(ct);
    try aesCfbEncrypt(key, iv, plain, ct);
    const iv_owned = try allocator.dupe(u8, iv);
    return .{ .iv = iv_owned, .data = ct };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// go-git `worktree_commit_test.go` armoredKeyRing (RSA-4096, passphrase below).
const go_git_armored_private_key =
    \\-----BEGIN PGP PRIVATE KEY BLOCK-----
    \\
    \\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
    \\=gIM9
    \\-----END PGP PRIVATE KEY BLOCK-----
;

const go_git_key_passphrase = "abcdef0123456789";

test "decodeArmor rejects garbage" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidArmor, decodeArmor(gpa, "not armor"));
}

test "fingerprintV4 runs" {
    const body = [_]u8{ 4, 0, 0, 0, 0, 1 };
    const fp = fingerprintV4(&body);
    try std.testing.expectEqual(@as(usize, 20), fp.len);
}

test "contentSimilarity independent of openpgp" {
    // Sanity: module loads under testing.allocator with no leaks on armor reject.
    const gpa = std.testing.allocator;
    const r = decodeArmor(gpa, "-----BEGIN PGP SIGNATURE-----\n\n-----END PGP SIGNATURE-----\n");
    try std.testing.expectError(error.InvalidArmor, r);
}

test "readArmoredKeyRing + decrypt go-git fixture" {
    const gpa = std.testing.allocator;
    const ents = try readArmoredKeyRing(gpa, go_git_armored_private_key);
    defer freeEntities(gpa, ents);
    try std.testing.expectEqual(@as(usize, 1), ents.len);
    try std.testing.expect(ents[0].encrypted);
    try std.testing.expectEqual(@as(u8, 1), ents[0].algo);
    try std.testing.expectEqual(@as(usize, 512), ents[0].n.len);
    try std.testing.expectEqualStrings("foo bar <foo@foo.foo>", ents[0].identity);

    // Expected fingerprint from go-crypto.
    const exp_fp = [_]u8{
        0x93, 0xa1, 0x7f, 0xf0, 0x1e, 0x54, 0x32, 0x85, 0x46, 0x08,
        0x7c, 0x8e, 0x02, 0x93, 0x95, 0x40, 0x2e, 0xfc, 0xcd, 0x53,
    };
    try std.testing.expectEqualSlices(u8, &exp_fp, &ents[0].fingerprint);

    try ents[0].decrypt(go_git_key_passphrase);
    try std.testing.expect(!ents[0].encrypted);
    try std.testing.expectEqual(@as(usize, 512), ents[0].d.len);
}

test "decrypt wrong passphrase fails" {
    const gpa = std.testing.allocator;
    const ents = try readArmoredKeyRing(gpa, go_git_armored_private_key);
    defer freeEntities(gpa, ents);
    try std.testing.expectError(error.DecryptFailed, ents[0].decrypt("wrong-passphrase"));
    try std.testing.expect(ents[0].encrypted);
}

test "armoredDetachSign encrypted key fails" {
    const gpa = std.testing.allocator;
    const ents = try readArmoredKeyRing(gpa, go_git_armored_private_key);
    defer freeEntities(gpa, ents);
    try std.testing.expectError(error.EncryptedKey, armoredDetachSign(gpa, &ents[0], "hello world"));
}

test "armoredDetachSign hello world round-trip verify" {
    const gpa = std.testing.allocator;
    const ents = try readArmoredKeyRing(gpa, go_git_armored_private_key);
    defer freeEntities(gpa, ents);
    try ents[0].decrypt(go_git_key_passphrase);

    const sig = try armoredDetachSign(gpa, &ents[0], "hello world");
    defer gpa.free(sig);
    try std.testing.expect(std.mem.indexOf(u8, sig, "BEGIN PGP SIGNATURE") != null);

    const pub_armor = try ents[0].serializePublicArmored(gpa);
    defer gpa.free(pub_armor);
    try checkArmoredDetachedSignature(gpa, pub_armor, "hello world", sig);
}

test "encodeArmor round-trip" {
    const gpa = std.testing.allocator;
    const bin = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const arm = try encodeArmor(gpa, "PGP SIGNATURE", &bin);
    defer gpa.free(arm);
    const back = try decodeArmor(gpa, arm);
    defer gpa.free(back);
    try std.testing.expectEqualSlices(u8, &bin, back);
}

test "Ed25519 armoredDetachSign round-trip verify" {
    const gpa = std.testing.allocator;
    var seed: [32]u8 = undefined;
    @memset(&seed, 0x42);
    var ent = try generateEd25519Entity(gpa, seed);
    defer ent.deinit();
    try std.testing.expectEqual(@as(u8, pk_eddsa), ent.algo);
    try std.testing.expect(!ent.encrypted);

    const msg = "ed25519 openpgp detached";
    const sig = try armoredDetachSign(gpa, &ent, msg);
    defer gpa.free(sig);
    const pub_armor = try ent.serializePublicArmored(gpa);
    defer gpa.free(pub_armor);
    try checkArmoredDetachedSignature(gpa, pub_armor, msg, sig);
}

// ---------------------------------------------------------------------------
// S2K / AES-CFB unit tests
// ---------------------------------------------------------------------------

test "s2kDerive simple salted iterated SHA-1 and SHA-256 goldens" {
    const pw = "hello";
    const salt = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const count_octet: u8 = 96;
    const count = s2kCount(count_octet);
    try std.testing.expectEqual(@as(usize, 65536), count);

    var out16: [16]u8 = undefined;
    var out32: [32]u8 = undefined;

    // SHA-1 simple
    try s2kDerive(&out16, pw, &.{}, 0, s2k_simple, hash_sha1);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xaa, 0xf4, 0xc6, 0x1d, 0xdc, 0xc5, 0xe8, 0xa2, 0xda, 0xbe, 0xde, 0x0f, 0x3b, 0x48, 0x2c, 0xd9,
    }, &out16);

    // SHA-1 salted
    try s2kDerive(&out16, pw, &salt, 0, s2k_salted, hash_sha1);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xf4, 0xf7, 0xd6, 0x7e, 0xf8, 0x5a, 0x8a, 0xc0, 0x7f, 0xed, 0xfd, 0x03, 0x67, 0x02, 0x74, 0x8a,
    }, &out16);

    // SHA-1 iterated
    try s2kDerive(&out16, pw, &salt, count, s2k_iterated, hash_sha1);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x67, 0x18, 0x09, 0x6f, 0xf5, 0x4f, 0xe0, 0x7b, 0xe0, 0xa8, 0x09, 0x52, 0x1d, 0xd7, 0x1a, 0xb7,
    }, &out16);

    // SHA-1 simple 32 bytes (two digest iterations)
    try s2kDerive(&out32, pw, &.{}, 0, s2k_simple, hash_sha1);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xaa, 0xf4, 0xc6, 0x1d, 0xdc, 0xc5, 0xe8, 0xa2, 0xda, 0xbe, 0xde, 0x0f, 0x3b, 0x48, 0x2c, 0xd9,
        0xae, 0xa9, 0x43, 0x4d, 0x1f, 0x0d, 0x8a, 0x55, 0x89, 0xa2, 0x1b, 0x73, 0x23, 0xfd, 0x15, 0x4e,
    }, &out32);

    // SHA-256 simple
    try s2kDerive(&out16, pw, &.{}, 0, s2k_simple, hash_sha256);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x2c, 0xf2, 0x4d, 0xba, 0x5f, 0xb0, 0xa3, 0x0e, 0x26, 0xe8, 0x3b, 0x2a, 0xc5, 0xb9, 0xe2, 0x9e,
    }, &out16);

    // SHA-256 salted
    try s2kDerive(&out16, pw, &salt, 0, s2k_salted, hash_sha256);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xef, 0x1d, 0xa4, 0x4b, 0x3e, 0x46, 0x01, 0xa0, 0x5d, 0x00, 0x90, 0x2a, 0x4f, 0x73, 0xab, 0xfc,
    }, &out16);

    // SHA-256 iterated
    try s2kDerive(&out16, pw, &salt, count, s2k_iterated, hash_sha256);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xee, 0x34, 0xc3, 0x52, 0x35, 0x81, 0x1e, 0xb5, 0xd0, 0xf3, 0xfd, 0x58, 0x3d, 0x1e, 0x48, 0x19,
    }, &out16);

    // SHA-256 iterated 32-byte key
    try s2kDerive(&out32, pw, &salt, count, s2k_iterated, hash_sha256);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xee, 0x34, 0xc3, 0x52, 0x35, 0x81, 0x1e, 0xb5, 0xd0, 0xf3, 0xfd, 0x58, 0x3d, 0x1e, 0x48, 0x19,
        0xe0, 0x30, 0xd0, 0x4f, 0x77, 0x89, 0xbb, 0x5b, 0x5c, 0x21, 0xd7, 0x2f, 0x8b, 0xbd, 0xa5, 0xc0,
    }, &out32);
}

test "AES-128/192/256-CFB encrypt decrypt round-trip and goldens" {
    const pt = "secret-mpi-bytes-for-openpgp!!"; // 30 bytes
    var iv: [16]u8 = undefined;
    for (&iv, 0..) |*b, i| b.* = @intCast(i);

    // AES-128
    {
        var key: [16]u8 = undefined;
        for (&key, 0..) |*b, i| b.* = @intCast(i);
        var ct: [30]u8 = undefined;
        var rt: [30]u8 = undefined;
        try aesCfbEncrypt(&key, &iv, pt, &ct);
        try std.testing.expectEqualSlices(u8, &[_]u8{
            0x79, 0xf1, 0x68, 0xc7, 0x24, 0x1a, 0xdd, 0x28, 0x81, 0xaa, 0xb9, 0x3a, 0xbf, 0x27, 0x8f, 0x29,
            0x0c, 0xde, 0xef, 0xb7, 0xc6, 0x71, 0xe3, 0x70, 0xa0, 0xab, 0x74, 0xe1, 0x55, 0x51,
        }, &ct);
        try aesCfbDecrypt(&key, &iv, &ct, &rt);
        try std.testing.expectEqualSlices(u8, pt, &rt);
    }
    // AES-192
    {
        var key: [24]u8 = undefined;
        for (&key, 0..) |*b, i| b.* = @intCast(i);
        var ct: [30]u8 = undefined;
        var rt: [30]u8 = undefined;
        try aesCfbEncrypt(&key, &iv, pt, &ct);
        try std.testing.expectEqualSlices(u8, &[_]u8{
            0x73, 0x05, 0xdc, 0x8c, 0x23, 0xf7, 0x66, 0xd5, 0xaa, 0x35, 0xd4, 0xc4, 0x66, 0x86, 0x45, 0xdd,
            0xef, 0x88, 0x21, 0xbf, 0x35, 0xfd, 0xea, 0x0a, 0xd9, 0x39, 0xb5, 0xe1, 0xfc, 0xe6,
        }, &ct);
        try aesCfbDecrypt(&key, &iv, &ct, &rt);
        try std.testing.expectEqualSlices(u8, pt, &rt);
    }
    // AES-256
    {
        var key: [32]u8 = undefined;
        for (&key, 0..) |*b, i| b.* = @intCast(i);
        var ct: [30]u8 = undefined;
        var rt: [30]u8 = undefined;
        try aesCfbEncrypt(&key, &iv, pt, &ct);
        try std.testing.expectEqualSlices(u8, &[_]u8{
            0x29, 0x0b, 0x67, 0x25, 0x6d, 0x8f, 0x5c, 0xfb, 0x80, 0x47, 0x78, 0x5f, 0x7b, 0xb7, 0xc3, 0xe1,
            0xbd, 0xfe, 0xcf, 0x35, 0xf1, 0xed, 0x83, 0xc2, 0xc2, 0x52, 0x64, 0x37, 0xa6, 0x8f,
        }, &ct);
        try aesCfbDecrypt(&key, &iv, &ct, &rt);
        try std.testing.expectEqualSlices(u8, pt, &rt);
    }
}

test "Entity.decrypt AES-256 S2K type3 SHA-256 usage 254" {
    const gpa = std.testing.allocator;
    var seed: [32]u8 = undefined;
    @memset(&seed, 0x11);
    var ent = try generateEd25519Entity(gpa, seed);
    defer ent.deinit();

    // Build secret MPI (EdDSA seed as MPI).
    var secret_list: std.ArrayList(u8) = .empty;
    defer secret_list.deinit(gpa);
    try appendMpi(&secret_list, gpa, &seed);

    const passphrase = "test-pass-aes256";
    const salt = [_]u8{ 9, 8, 7, 6, 5, 4, 3, 2 };
    const count_octet: u8 = 96;
    var iv: [16]u8 = undefined;
    @memset(&iv, 0xab);

    // Clear cleartext seed; seal and re-decrypt.
    ent.ed25519_seed = null;
    ent.encrypted = true;
    ent.s2k_usage = 254;
    ent.cipher_algo = cipher_aes256;
    ent.s2k_type = s2k_iterated;
    ent.s2k_hash = hash_sha256;
    ent.salt = salt;
    ent.count_octet = count_octet;
    const sealed = try sealSecretUsage254(
        gpa,
        secret_list.items,
        passphrase,
        &salt,
        count_octet,
        &iv,
        cipher_aes256,
        s2k_iterated,
        hash_sha256,
    );
    ent.iv = sealed.iv;
    ent.encrypted_data = sealed.data;

    try ent.decrypt(passphrase);
    try std.testing.expect(!ent.encrypted);
    try std.testing.expectEqualSlices(u8, &seed, &ent.ed25519_seed.?);

    // Round-trip sign after decrypt.
    const msg = "sealed ed25519";
    const sig = try armoredDetachSign(gpa, &ent, msg);
    defer gpa.free(sig);
    const pub_armor = try ent.serializePublicArmored(gpa);
    defer gpa.free(pub_armor);
    try checkArmoredDetachedSignature(gpa, pub_armor, msg, sig);
}

test "subkey preferred for armoredDetachSign issuer" {
    const gpa = std.testing.allocator;
    var seed_primary: [32]u8 = undefined;
    @memset(&seed_primary, 0x42);
    var seed_sub: [32]u8 = undefined;
    @memset(&seed_sub, 0x99);

    var ent = try generateEd25519Entity(gpa, seed_primary);
    defer ent.deinit();
    // Primary can sign but subkey should be preferred.
    ent.key_flags = key_flag_certify | key_flag_sign;

    const sub = try generateEd25519Subkey(gpa, seed_sub);
    const sub_fp = sub.fingerprint;
    try entityAttachSubkey(&ent, sub);

    const msg = "sign with subkey";
    const sig = try armoredDetachSign(gpa, &ent, msg);
    defer gpa.free(sig);

    // Issuer in signature must be the subkey key id.
    const sig_bin = try decodeArmor(gpa, sig);
    defer gpa.free(sig_bin);
    var sig_pkt = try parseDetachedSignature(gpa, sig_bin);
    defer sig_pkt.deinit(gpa);
    try std.testing.expectEqualSlices(u8, sub_fp[12..20], &sig_pkt.key_id);

    // Public ring with subkey verifies the signature.
    const pub_armor = try ent.serializePublicArmored(gpa);
    defer gpa.free(pub_armor);
    try checkArmoredDetachedSignature(gpa, pub_armor, msg, sig);
}

test "primary-only entity still signs with primary" {
    const gpa = std.testing.allocator;
    const ents = try readArmoredKeyRing(gpa, go_git_armored_private_key);
    defer freeEntities(gpa, ents);
    try ents[0].decrypt(go_git_key_passphrase);
    try std.testing.expectEqual(@as(usize, 0), ents[0].subkeys.len);

    const sig = try armoredDetachSign(gpa, &ents[0], "primary only");
    defer gpa.free(sig);
    const sig_bin = try decodeArmor(gpa, sig);
    defer gpa.free(sig_bin);
    var sig_pkt = try parseDetachedSignature(gpa, sig_bin);
    defer sig_pkt.deinit(gpa);
    try std.testing.expectEqualSlices(u8, ents[0].fingerprint[12..20], &sig_pkt.key_id);
}

test "s2k simple decrypt path on KeyMaterial" {
    const gpa = std.testing.allocator;
    var seed: [32]u8 = undefined;
    @memset(&seed, 0x33);
    const kp = try crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    const pub_bytes = kp.public_key.bytes;
    const public_body = try buildEd25519PublicBody(gpa, &pub_bytes);
    errdefer gpa.free(public_body);

    var secret_list: std.ArrayList(u8) = .empty;
    defer secret_list.deinit(gpa);
    try appendMpi(&secret_list, gpa, &seed);

    const passphrase = "simple-s2k";
    var iv: [16]u8 = undefined;
    @memset(&iv, 0x5a);
    const salt = [_]u8{0} ** 8; // unused for simple
    const sealed = try sealSecretUsage254(
        gpa,
        secret_list.items,
        passphrase,
        &salt,
        0,
        &iv,
        cipher_aes128,
        s2k_simple,
        hash_sha1,
    );

    var km: KeyMaterial = .{
        .algo = pk_eddsa,
        .fingerprint = fingerprintV4(public_body),
        .ed25519_pub = pub_bytes,
        .public_body = public_body,
        .encrypted = true,
        .s2k_usage = 254,
        .cipher_algo = cipher_aes128,
        .s2k_type = s2k_simple,
        .s2k_hash = hash_sha1,
        .iv = sealed.iv,
        .encrypted_data = sealed.data,
    };
    defer km.deinit(gpa);

    try km.decrypt(gpa, passphrase);
    try std.testing.expect(!km.encrypted);
    try std.testing.expectEqualSlices(u8, &seed, &km.ed25519_seed.?);
}
