//! RSA PKCS#1 v1.5 verify/sign and big-int helpers (modPow).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Managed = std.math.big.int.Managed;
const err_mod = @import("error.zig");
const Error = err_mod.Error;

const hash_sha1 = err_mod.hash_sha1;
const hash_sha256 = err_mod.hash_sha256;
const hash_sha512 = err_mod.hash_sha512;

pub fn setBytesBe(v: *Managed, bytes: []const u8) Allocator.Error!void {
    // Skip leading zero bytes (MPI may include a high 0x00).
    var start: usize = 0;
    while (start < bytes.len and bytes[start] == 0) : (start += 1) {}
    try v.set(0);
    for (bytes[start..]) |b| {
        try v.shiftLeft(v, 8);
        try v.addScalar(v, b);
    }
}

pub fn writeBytesBe(v: *const Managed, out: []u8) (Allocator.Error || Error)!void {
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

pub fn modPow(result: *Managed, base: *Managed, exp: *Managed, mod: *Managed) Allocator.Error!void {
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

pub fn digestInfoPrefix(hash_algo: u8) Error![]const u8 {
    return switch (hash_algo) {
        hash_sha1 => &[_]u8{ 0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14 },
        hash_sha256 => &[_]u8{ 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 },
        hash_sha512 => &[_]u8{ 0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40 },
        else => error.UnsupportedAlgorithm,
    };
}

pub fn rsaVerify(
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

pub fn rsaSign(
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
