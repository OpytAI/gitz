//! Armored detached sign: selectSigningKey, buildV4SignaturePacket, armoredDetachSign.

const std = @import("std");
const builtin = @import("builtin");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;

const err_mod = @import("error.zig");
const armor_mod = @import("armor.zig");
const packet_mod = @import("packet.zig");
const rsa_mod = @import("rsa.zig");
const entity_mod = @import("entity.zig");
const verify_mod = @import("verify.zig");

const Error = err_mod.Error;
const Entity = entity_mod.Entity;
const KeyMaterial = entity_mod.KeyMaterial;
const encodeArmor = armor_mod.encodeArmor;
const appendPacket = packet_mod.appendPacket;
const appendMpi = packet_mod.appendMpi;
const appendSubpacket = packet_mod.appendSubpacket;
const rsaSign = rsa_mod.rsaSign;
const Signature = verify_mod.Signature;
const hashDocument = verify_mod.hashDocument;
const hashDigestLen = verify_mod.hashDigestLen;

const tag_signature = err_mod.tag_signature;
const pk_rsa = err_mod.pk_rsa;
const pk_rsa_encrypt = err_mod.pk_rsa_encrypt;
const pk_rsa_sign = err_mod.pk_rsa_sign;
const pk_eddsa = err_mod.pk_eddsa;
const hash_sha256 = err_mod.hash_sha256;
const key_flag_sign = err_mod.key_flag_sign;

/// Selected signing material (primary or subkey view).
pub const SigningSelection = struct {
    algo: u8,
    fingerprint: [20]u8,
    n: []const u8 = &.{},
    d: []const u8 = &.{},
    ed25519_seed: ?[32]u8 = null,

    pub fn keyId(self: *const SigningSelection) [8]u8 {
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
pub fn selectSigningKey(entity: *const Entity) Error!SigningSelection {
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

    if (entity.primary.encrypted) return error.EncryptedKey;
    if (!entity.primary.hasPrivateMaterial()) return error.NoPrivateKey;
    if (!entity.primary.canSign()) return error.NoPrivateKey;
    return signingSelectionFromKeyMaterial(&entity.primary);
}

pub fn buildV4SignaturePacket(
    allocator: Allocator,
    entity: *const Entity,
    message: []const u8,
    hash_algo: u8,
) (Allocator.Error || Error)![]u8 {
    const created_at = try systemUnixSeconds();
    return buildV4SignaturePacketAt(allocator, entity, message, hash_algo, created_at);
}

/// Deterministic v4 signature packet construction with caller-supplied time.
pub fn buildV4SignaturePacketAt(
    allocator: Allocator,
    entity: *const Entity,
    message: []const u8,
    hash_algo: u8,
    created_at: u32,
) (Allocator.Error || Error)![]u8 {
    const sk = try selectSigningKey(entity);

    // Hashed subpackets: creation time (critical) + issuer key id of selected key.
    var hashed: std.ArrayList(u8) = .empty;
    defer hashed.deinit(allocator);

    var ctime: [4]u8 = undefined;
    std.mem.writeInt(u32, &ctime, created_at, .big);
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
    const created_at = try systemUnixSeconds();
    return armoredDetachSignAt(allocator, entity, message, created_at);
}

/// Deterministic detached signature with caller-supplied creation time.
pub fn armoredDetachSignAt(
    allocator: Allocator,
    entity: *const Entity,
    message: []const u8,
    created_at: u32,
) (Allocator.Error || Error)![]u8 {
    const bin = try buildV4SignaturePacketAt(allocator, entity, message, hash_sha256, created_at);
    defer allocator.free(bin);
    return encodeArmor(allocator, "PGP SIGNATURE", bin);
}

fn systemUnixSeconds() Error!u32 {
    if (comptime builtin.os.tag == .freestanding) return error.ClockUnavailable;
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return std.math.cast(u32, ts.sec) orelse error.ClockUnavailable;
}
