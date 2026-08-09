//! Unit tests for the openpgp package.

const std = @import("std");
const crypto = std.crypto;

const err_mod = @import("error.zig");
const armor_mod = @import("armor.zig");
const packet_mod = @import("packet.zig");
const s2k_mod = @import("s2k.zig");
const entity_mod = @import("entity.zig");
const sign_mod = @import("sign.zig");
const verify_mod = @import("verify.zig");
const fixtures = @import("fixtures.zig");

const Error = err_mod.Error;
const decodeArmor = armor_mod.decodeArmor;
const encodeArmor = armor_mod.encodeArmor;
const fingerprintV4 = packet_mod.fingerprintV4;
const appendMpi = packet_mod.appendMpi;
const s2kCount = s2k_mod.s2kCount;
const s2kDerive = s2k_mod.s2kDerive;
const aesCfbEncrypt = s2k_mod.aesCfbEncrypt;
const aesCfbDecrypt = s2k_mod.aesCfbDecrypt;
const sealSecretUsage254 = s2k_mod.sealSecretUsage254;
const KeyMaterial = entity_mod.KeyMaterial;
const readArmoredKeyRing = entity_mod.readArmoredKeyRing;
const freeEntities = entity_mod.freeEntities;
const generateEd25519Entity = entity_mod.generateEd25519Entity;
const generateEd25519Subkey = entity_mod.generateEd25519Subkey;
const entityAttachSubkey = entity_mod.entityAttachSubkey;
const buildEd25519PublicBody = entity_mod.buildEd25519PublicBody;
const armoredDetachSign = sign_mod.armoredDetachSign;
const checkArmoredDetachedSignature = verify_mod.checkArmoredDetachedSignature;
const parseKeyring = verify_mod.parseKeyring;
const parseDetachedSignature = verify_mod.parseDetachedSignature;

const pk_eddsa = err_mod.pk_eddsa;
const hash_sha1 = err_mod.hash_sha1;
const hash_sha256 = err_mod.hash_sha256;
const cipher_aes128 = err_mod.cipher_aes128;
const cipher_aes256 = err_mod.cipher_aes256;
const s2k_simple = err_mod.s2k_simple;
const s2k_salted = err_mod.s2k_salted;
const s2k_iterated = err_mod.s2k_iterated;
const key_flag_certify = err_mod.key_flag_certify;
const key_flag_sign = err_mod.key_flag_sign;

const go_git_armored_private_key = fixtures.go_git_armored_private_key;
const go_git_key_passphrase = fixtures.go_git_key_passphrase;

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
    try std.testing.expect(ents[0].primary.encrypted);
    try std.testing.expectEqual(@as(u8, 1), ents[0].primary.algo);
    try std.testing.expectEqual(@as(usize, 512), ents[0].primary.n.len);
    try std.testing.expectEqualStrings("foo bar <foo@foo.foo>", ents[0].identity);

    // Expected fingerprint from go-crypto.
    const exp_fp = [_]u8{
        0x93, 0xa1, 0x7f, 0xf0, 0x1e, 0x54, 0x32, 0x85, 0x46, 0x08,
        0x7c, 0x8e, 0x02, 0x93, 0x95, 0x40, 0x2e, 0xfc, 0xcd, 0x53,
    };
    try std.testing.expectEqualSlices(u8, &exp_fp, &ents[0].primary.fingerprint);

    try ents[0].decrypt(go_git_key_passphrase);
    try std.testing.expect(!ents[0].primary.encrypted);
    try std.testing.expectEqual(@as(usize, 512), ents[0].primary.d.len);
}

test "decrypt wrong passphrase fails" {
    const gpa = std.testing.allocator;
    const ents = try readArmoredKeyRing(gpa, go_git_armored_private_key);
    defer freeEntities(gpa, ents);
    try std.testing.expectError(error.DecryptFailed, ents[0].decrypt("wrong-passphrase"));
    try std.testing.expect(ents[0].primary.encrypted);
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
    _ = try checkArmoredDetachedSignature(gpa, pub_armor, "hello world", sig);
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

test "decodeArmor rejects mismatched footer and corrupt CRC" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidArmor, decodeArmor(
        gpa,
        "-----BEGIN PGP SIGNATURE-----\n\nAQIDBA==\n=A5M2\n-----END PGP PUBLIC KEY BLOCK-----\n",
    ));

    const bin = [_]u8{ 1, 2, 3, 4 };
    const valid = try encodeArmor(gpa, "PGP SIGNATURE", &bin);
    defer gpa.free(valid);
    const crc_pos = std.mem.indexOf(u8, valid, "\n=") orelse unreachable;
    const corrupt = try gpa.dupe(u8, valid);
    defer gpa.free(corrupt);
    corrupt[crc_pos + 2] = if (corrupt[crc_pos + 2] == 'A') 'B' else 'A';
    try std.testing.expectError(error.InvalidArmor, decodeArmor(gpa, corrupt));
}

test "parseKeyring rejects malformed trailing packet" {
    const gpa = std.testing.allocator;
    var seed: [32]u8 = undefined;
    @memset(&seed, 0x42);
    var ent = try generateEd25519Entity(gpa, seed);
    defer ent.deinit();
    const armor = try ent.serializePublicArmored(gpa);
    defer gpa.free(armor);
    const binary = try decodeArmor(gpa, armor);
    defer gpa.free(binary);

    var malformed = try gpa.alloc(u8, binary.len + 1);
    defer gpa.free(malformed);
    @memcpy(malformed[0..binary.len], binary);
    malformed[binary.len] = 0x80; // old-format packet header without length
    try std.testing.expectError(error.InvalidPacket, parseKeyring(gpa, malformed));
}

test "Ed25519 armoredDetachSign round-trip verify" {
    const gpa = std.testing.allocator;
    var seed: [32]u8 = undefined;
    @memset(&seed, 0x42);
    var ent = try generateEd25519Entity(gpa, seed);
    defer ent.deinit();
    try std.testing.expectEqual(@as(u8, pk_eddsa), ent.primary.algo);
    try std.testing.expect(!ent.primary.encrypted);

    const msg = "ed25519 openpgp detached";
    const sig = try armoredDetachSign(gpa, &ent, msg);
    defer gpa.free(sig);
    const pub_armor = try ent.serializePublicArmored(gpa);
    defer gpa.free(pub_armor);
    _ = try checkArmoredDetachedSignature(gpa, pub_armor, msg, sig);
}

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
    ent.primary.ed25519_seed = null;
    ent.primary.encrypted = true;
    ent.primary.s2k_usage = 254;
    ent.primary.cipher_algo = cipher_aes256;
    ent.primary.s2k_type = s2k_iterated;
    ent.primary.s2k_hash = hash_sha256;
    ent.primary.salt = salt;
    ent.primary.count_octet = count_octet;
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
    ent.primary.iv = sealed.iv;
    ent.primary.encrypted_data = sealed.data;

    try ent.decrypt(passphrase);
    try std.testing.expect(!ent.primary.encrypted);
    try std.testing.expectEqualSlices(u8, &seed, &ent.primary.ed25519_seed.?);

    // Round-trip sign after decrypt.
    const msg = "sealed ed25519";
    const sig = try armoredDetachSign(gpa, &ent, msg);
    defer gpa.free(sig);
    const pub_armor = try ent.serializePublicArmored(gpa);
    defer gpa.free(pub_armor);
    _ = try checkArmoredDetachedSignature(gpa, pub_armor, msg, sig);
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
    ent.primary.key_flags = key_flag_certify | key_flag_sign;

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
    _ = try checkArmoredDetachedSignature(gpa, pub_armor, msg, sig);
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
    try std.testing.expectEqualSlices(u8, ents[0].primary.fingerprint[12..20], &sig_pkt.key_id);
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
