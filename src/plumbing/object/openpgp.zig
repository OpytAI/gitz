//! OpenPGP detached-signature verify for Git (`Commit.Verify` / `Tag.Verify`).
//!
//! Mirrors go-git's call into ProtonMail go-crypto
//! `openpgp.CheckArmoredDetachedSignature` for the algorithms Git signing uses:
//! - ASCII armor (PUBLIC KEY BLOCK / SIGNATURE)
//! - v4 public-key packets (RSA, EdDSA/Ed25519)
//! - v4 signature packets (SHA-1 / SHA-256 / SHA-512)
//! - RSA PKCS#1 v1.5 and Ed25519 over OpenPGP hash trailer

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
};

// Packet tags
const tag_public_key: u8 = 6;
const tag_public_subkey: u8 = 14;
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

fn extractKeyId(subpackets: []const u8, out: *[8]u8) void {
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
        const typ = subpackets[body_start];
        const data = subpackets[body_start + 1 .. body_start + len];
        // Issuer (16) or Issuer Fingerprint (33)
        if (typ == 16 and data.len >= 8) {
            @memcpy(out, data[0..8]);
            return;
        }
        if (typ == 33 and data.len >= 21) {
            @memcpy(out, data[data.len - 8 ..][0..8]);
            return;
        }
        pos = body_start + len;
    }
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
