//! Detached signature verify: keyring parse, PublicKey/Signature parse, hash trailer.

const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;

const err_mod = @import("error.zig");
const armor_mod = @import("armor.zig");
const packet_mod = @import("packet.zig");
const rsa_mod = @import("rsa.zig");

const Error = err_mod.Error;
const decodeArmor = armor_mod.decodeArmor;
const nextPacket = packet_mod.nextPacket;
const readMpi = packet_mod.readMpi;
const fingerprintV4 = packet_mod.fingerprintV4;
const rsaVerify = rsa_mod.rsaVerify;

const tag_public_key = err_mod.tag_public_key;
const tag_public_subkey = err_mod.tag_public_subkey;
const tag_signature = err_mod.tag_signature;
const pk_rsa = err_mod.pk_rsa;
const pk_rsa_encrypt = err_mod.pk_rsa_encrypt;
const pk_rsa_sign = err_mod.pk_rsa_sign;
const pk_eddsa = err_mod.pk_eddsa;
const hash_sha1 = err_mod.hash_sha1;
const hash_sha256 = err_mod.hash_sha256;
const hash_sha512 = err_mod.hash_sha512;

pub const PublicKey = struct {
    algo: u8,
    fingerprint: [20]u8,
    n: []const u8 = &.{},
    e: []const u8 = &.{},
    ed25519: ?[32]u8 = null,
    owned: []u8 = &.{},

    pub fn deinit(self: *PublicKey, allocator: Allocator) void {
        if (self.owned.len > 0) allocator.free(self.owned);
        self.* = .{
            .algo = 0,
            .fingerprint = .{0} ** 20,
        };
    }
};

pub fn parsePublicKey(allocator: Allocator, body: []const u8) (Allocator.Error || Error)!PublicKey {
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

pub const Signature = struct {
    pub_algo: u8,
    hash_algo: u8,
    key_id: [8]u8 = .{0} ** 8,
    hashed: []const u8 = &.{},
    left16: [2]u8 = .{ 0, 0 },
    mpis: []const u8 = &.{},
    owned: []u8 = &.{},

    pub fn deinit(self: *Signature, allocator: Allocator) void {
        if (self.owned.len > 0) allocator.free(self.owned);
        self.* = .{
            .pub_algo = 0,
            .hash_algo = 0,
        };
    }

    /// Bytes hashed in the OpenPGP trailer (version…end of hashed subpackets).
    pub fn hashedData(self: *const Signature) []const u8 {
        return self.owned[0 .. 6 + self.hashed.len];
    }
};

pub fn parseSignature(allocator: Allocator, body: []const u8) (Allocator.Error || Error)!Signature {
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

pub fn walkSubpackets(subpackets: []const u8, comptime callback: anytype, ctx: anytype) void {
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
pub fn extractKeyFlags(subpackets: []const u8) ?u8 {
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

pub fn hashDocument(hash_algo: u8, message: []const u8, sig: *const Signature) Error![64]u8 {
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

pub fn hashDigestLen(hash_algo: u8) Error!usize {
    return switch (hash_algo) {
        hash_sha1 => 20,
        hash_sha256 => 32,
        hash_sha512 => 64,
        else => error.UnsupportedAlgorithm,
    };
}

fn mpiToFixed(mpi: []const u8, out: []u8) Error!void {
    @memset(out, 0);
    if (mpi.len > out.len) return error.InvalidPacket;
    @memcpy(out[out.len - mpi.len ..], mpi);
}

pub fn ed25519Verify(pub_key: [32]u8, sig_mpis: []const u8, digest: []const u8) Error!void {
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

pub fn parseKeyring(allocator: Allocator, binary: []const u8) (Allocator.Error || Error)!Keyring {
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

pub fn parseDetachedSignature(allocator: Allocator, binary: []const u8) (Allocator.Error || Error)!Signature {
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
