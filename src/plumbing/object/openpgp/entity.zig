//! KeyMaterial, Subkey, Entity (composed primary), keyring parse, generate helpers.

const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;

const err_mod = @import("error.zig");
const armor_mod = @import("armor.zig");
const packet_mod = @import("packet.zig");
const s2k_mod = @import("s2k.zig");
const verify_mod = @import("verify.zig");

const Error = err_mod.Error;
const decodeArmor = armor_mod.decodeArmor;
const encodeArmor = armor_mod.encodeArmor;
const nextPacket = packet_mod.nextPacket;
const readMpi = packet_mod.readMpi;
const fingerprintV4 = packet_mod.fingerprintV4;
const appendPacket = packet_mod.appendPacket;
const appendMpi = packet_mod.appendMpi;
const s2kDerive = s2k_mod.s2kDerive;
const s2kCount = s2k_mod.s2kCount;
const cipherKeyLen = s2k_mod.cipherKeyLen;
const cipherBlockLen = s2k_mod.cipherBlockLen;
const aesCfbDecrypt = s2k_mod.aesCfbDecrypt;
const parsePublicKey = verify_mod.parsePublicKey;
const extractKeyFlags = verify_mod.extractKeyFlags;

const tag_public_key = err_mod.tag_public_key;
const tag_public_subkey = err_mod.tag_public_subkey;
const tag_secret_key = err_mod.tag_secret_key;
const tag_secret_subkey = err_mod.tag_secret_subkey;
const tag_user_id = err_mod.tag_user_id;
const tag_signature = err_mod.tag_signature;
const pk_rsa = err_mod.pk_rsa;
const pk_rsa_encrypt = err_mod.pk_rsa_encrypt;
const pk_rsa_sign = err_mod.pk_rsa_sign;
const pk_eddsa = err_mod.pk_eddsa;
const s2k_simple = err_mod.s2k_simple;
const s2k_salted = err_mod.s2k_salted;
const s2k_iterated = err_mod.s2k_iterated;
const key_flag_sign = err_mod.key_flag_sign;

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

    pub fn deinit(self: *KeyMaterial, allocator: Allocator) void {
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

    pub fn hasPrivateMaterial(self: *const KeyMaterial) bool {
        return switch (self.algo) {
            pk_rsa, pk_rsa_sign, pk_rsa_encrypt => self.d.len > 0,
            pk_eddsa => self.ed25519_seed != null,
            else => false,
        };
    }

    /// Sign-capable: RSA/EdDSA and (no flags | sign flag set).
    pub fn canSign(self: *const KeyMaterial) bool {
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

    pub fn parseSecretMpIs(self: *KeyMaterial, allocator: Allocator, data: []const u8) (Allocator.Error || Error)!void {
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
///
/// Crypto fields live only on `primary` (and `subkeys`); no duplicated key material.
pub const Entity = struct {
    allocator: Allocator,
    primary: KeyMaterial = .{},
    /// Optional identity string (owned, e.g. "foo bar <foo@foo.foo>").
    identity: []u8 = &.{},
    /// Owned subkeys (secret and/or public).
    subkeys: []Subkey = &.{},

    pub fn deinit(self: *Entity) void {
        const a = self.allocator;
        self.primary.deinit(a);
        if (self.identity.len > 0) a.free(self.identity);
        for (self.subkeys) |*sk| sk.deinit(a);
        if (self.subkeys.len > 0) a.free(self.subkeys);
        self.* = .{ .allocator = a };
    }

    /// Key id = last 8 bytes of primary v4 fingerprint.
    pub fn keyId(self: *const Entity) [8]u8 {
        return self.primary.keyId();
    }

    /// Decrypt primary and all encrypted subkeys with the same passphrase.
    ///
    /// Matches go-crypto `Entity.DecryptPrivateKeys` for Git signing use.
    pub fn decrypt(self: *Entity, passphrase: []const u8) (Allocator.Error || Error)!void {
        if (self.primary.encrypted) {
            try self.primary.decrypt(self.allocator, passphrase);
        }
        for (self.subkeys) |*sk| {
            if (sk.encrypted) try sk.decrypt(self.allocator, passphrase);
        }
    }

    /// Armored public key block for `Tag.verify` / `checkArmoredDetachedSignature`.
    /// Includes primary public packet, identity, and subkey public packets.
    pub fn serializePublicArmored(self: *const Entity, allocator: Allocator) (Allocator.Error || Error)![]u8 {
        if (self.primary.public_body.len == 0) return error.InvalidPacket;
        var bin: std.ArrayList(u8) = .empty;
        defer bin.deinit(allocator);
        try appendPacket(&bin, allocator, tag_public_key, self.primary.public_body);
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

/// Free a slice returned by `readArmoredKeyRing`.
pub fn freeEntities(allocator: Allocator, entities: []Entity) void {
    for (entities) |*e| e.deinit();
    allocator.free(entities);
}

/// Parse the keyring and transfer ownership of the entity containing the
/// verified primary key or signing subkey. Caller must call `Entity.deinit`.
pub fn entityForFingerprint(allocator: Allocator, armored: []const u8, fingerprint: [20]u8) (Allocator.Error || Error)!Entity {
    const entities = try readArmoredKeyRing(allocator, armored);
    var selected: ?usize = null;
    for (entities, 0..) |*entity, i| {
        if (std.mem.eql(u8, &entity.primary.fingerprint, &fingerprint)) {
            selected = i;
            break;
        }
        for (entity.subkeys) |*subkey| {
            if (std.mem.eql(u8, &subkey.fingerprint, &fingerprint)) {
                selected = i;
                break;
            }
        }
        if (selected != null) break;
    }
    const index = selected orelse {
        freeEntities(allocator, entities);
        return error.KeyNotFound;
    };
    const result = entities[index];
    for (entities, 0..) |*entity, i| if (i != index) entity.deinit();
    allocator.free(entities);
    return result;
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
        .primary = km,
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
        entity.primary.key_flags = flags;
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

pub fn buildEd25519PublicBody(allocator: Allocator, pub_bytes: *const [32]u8) Allocator.Error![]u8 {
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
        .primary = .{
            .algo = pk_eddsa,
            .fingerprint = fp,
            .ed25519_pub = pub_bytes,
            .ed25519_seed = seed,
            .encrypted = false,
            .public_body = public_body,
        },
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
