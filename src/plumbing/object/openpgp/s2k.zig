//! S2K (RFC 4880 §3.7) + AES-CFB secret-key decrypt/encrypt.

const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const err_mod = @import("error.zig");
const Error = err_mod.Error;

const cipher_aes128 = err_mod.cipher_aes128;
const cipher_aes192 = err_mod.cipher_aes192;
const cipher_aes256 = err_mod.cipher_aes256;
const hash_sha1 = err_mod.hash_sha1;
const hash_sha256 = err_mod.hash_sha256;
const hash_sha512 = err_mod.hash_sha512;
const s2k_simple = err_mod.s2k_simple;
const s2k_salted = err_mod.s2k_salted;
const s2k_iterated = err_mod.s2k_iterated;

pub fn s2kCount(count_octet: u8) usize {
    return (@as(usize, 16) + (count_octet & 15)) << @as(u6, @intCast((count_octet >> 4) + 6));
}

pub fn cipherKeyLen(cipher_algo: u8) Error!usize {
    return switch (cipher_algo) {
        cipher_aes128 => 16,
        cipher_aes192 => 24,
        cipher_aes256 => 32,
        else => error.UnsupportedAlgorithm,
    };
}

pub fn cipherBlockLen(cipher_algo: u8) Error!usize {
    return switch (cipher_algo) {
        cipher_aes128, cipher_aes192, cipher_aes256 => 16,
        else => error.UnsupportedAlgorithm,
    };
}

pub fn hashDigestSize(hash_algo: u8) Error!usize {
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
pub const Aes192 = struct {
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

pub fn aesBlockEncrypt(key: []const u8, dst: *[16]u8, src: *const [16]u8) Error!void {
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
pub fn aesCfbDecrypt(key: []const u8, iv: *const [16]u8, ciphertext: []const u8, plaintext: []u8) Error!void {
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
pub fn aesCfbEncrypt(key: []const u8, iv: *const [16]u8, plaintext: []const u8, ciphertext: []u8) Error!void {
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

/// Seal secret MPI bytes with usage-254 AES-CFB (test helper).
pub fn sealSecretUsage254(
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

