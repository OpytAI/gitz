//! Object IDs and git object content hashing (go-git `plumbing/hash.go`).
//!
//! Storage is always `MaxSize` (32) bytes with zero padding. Active digest
//! length follows `plumbing/hash` process-wide object format (SHA-1 default).

const std = @import("std");
const err = @import("error.zig");
const object = @import("object.zig");
const hash_algo = @import("hash");

/// SHA-1 digest size in bytes (go-git `hash.Size` without sha256 tag).
pub const Size: usize = hash_algo.Size;

/// Hex-encoded OID length for default SHA-1 (go-git `hash.HexSize`).
pub const HexSize: usize = hash_algo.HexSize;

/// Maximum OID / hex sizes (SHA-256).
pub const MaxSize: usize = hash_algo.MaxSize;
pub const MaxHexSize: usize = hash_algo.MaxHexSize;

/// Active digest / hex length and format (runtime dual SHA-1 / SHA-256).
pub const digestSize = hash_algo.digestSize;
pub const hexSize = hash_algo.hexSize;
pub const setObjectFormat = hash_algo.setObjectFormat;
pub const objectFormat = hash_algo.objectFormat;
pub const supportsObjectFormat = hash_algo.supportsObjectFormat;

/// Object id (go-git `plumbing.Hash`). Always `MaxSize` bytes, zero-padded.
pub const Hash = struct {
    bytes: [MaxSize]u8 = .{0} ** MaxSize,

    pub fn isZero(self: Hash) bool {
        const n = hash_algo.digestSize();
        return std.mem.allEqual(u8, self.bytes[0..n], 0);
    }

    pub fn eql(self: Hash, other: Hash) bool {
        const n = hash_algo.digestSize();
        return std.mem.eql(u8, self.bytes[0..n], other.bytes[0..n]);
    }

    /// Write lowercase hex of the active digest into `buf`.
    /// `buf` must be at least `hash_algo.hexSize()` bytes (use `MaxHexSize` for dual).
    pub fn formatHex(self: Hash, buf: []u8) []const u8 {
        const n = hash_algo.digestSize();
        const hex_len = n * 2;
        std.debug.assert(buf.len >= hex_len);
        const charset = "0123456789abcdef";
        for (self.bytes[0..n], 0..) |b, i| {
            buf[i * 2] = charset[b >> 4];
            buf[i * 2 + 1] = charset[b & 15];
        }
        return buf[0..hex_len];
    }

    /// go-git `Hash.String` — hex into caller buffer.
    pub fn string(self: Hash, buf: []u8) []const u8 {
        return self.formatHex(buf);
    }

    /// Build a Hash from raw digest bytes (up to `MaxSize`; remainder stays zero).
    /// Accepts `[]const u8` / `[]u8` or fixed arrays (`[N]u8`).
    pub fn fromBytes(raw: anytype) Hash {
        const s: []const u8 = raw[0..];
        var h = ZeroHash;
        const n = @min(s.len, MaxSize);
        if (n > 0) @memcpy(h.bytes[0..n], s[0..n]);
        return h;
    }

    /// Active OID slice (`digestSize()` bytes).
    pub fn slice(self: *const Hash) []const u8 {
        return self.bytes[0..hash_algo.digestSize()];
    }
};

/// Zero OID (go-git `ZeroHash`).
pub const ZeroHash: Hash = .{};

/// Parse a full hex OID (40-char SHA-1 or 64-char SHA-256).
pub fn parseHash(s: []const u8) err.Error!Hash {
    if (s.len != HexSize and s.len != MaxHexSize) return error.InvalidHash;
    var out: [MaxSize]u8 = .{0} ** MaxSize;
    const n = s.len / 2;
    _ = std.fmt.hexToBytes(out[0..n], s) catch return error.InvalidHash;
    return Hash.fromBytes(out[0..n]);
}

/// go-git `NewHash`: best-effort hex decode; invalid input yields zero.
pub fn newHash(s: []const u8) Hash {
    var h = ZeroHash;
    if (s.len == 0 or s.len > MaxHexSize or (s.len % 2) != 0) return h;
    var tmp: [MaxSize]u8 = undefined;
    const n = s.len / 2;
    if (std.fmt.hexToBytes(tmp[0..n], s)) |decoded| {
        @memcpy(h.bytes[0..decoded.len], decoded);
    } else |_| {}
    return h;
}

/// go-git `IsHash` — accepts 40- or 64-char lowercase/uppercase hex.
pub fn isHash(s: []const u8) bool {
    if (s.len != HexSize and s.len != MaxHexSize) return false;
    var tmp: [MaxSize]u8 = undefined;
    const n = s.len / 2;
    _ = std.fmt.hexToBytes(tmp[0..n], s) catch return false;
    return true;
}

/// Incremental git object hasher: header `type SP size NUL` then content.
/// Uses the active process-wide object format from `plumbing/hash`.
pub const Hasher = struct {
    inner: hash_algo.Hasher,

    pub fn init(t: object.ObjectType, size: i64) Hasher {
        var h = Hasher{ .inner = hash_algo.new(hash_algo.objectFormat()) };
        h.inner.update(t.bytes());
        h.inner.update(" ");
        var size_buf: [32]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{size}) catch unreachable;
        h.inner.update(size_str);
        h.inner.update(&[_]u8{0});
        return h;
    }

    pub fn update(self: *Hasher, data: []const u8) void {
        self.inner.update(data);
    }

    pub fn sum(self: *Hasher) Hash {
        var out: [MaxSize]u8 = .{0} ** MaxSize;
        const n = self.inner.digestSize();
        self.inner.final(out[0..n]);
        return Hash.fromBytes(out[0..n]);
    }
};

/// go-git `ComputeHash`.
pub fn computeHash(t: object.ObjectType, content: []const u8) Hash {
    var h = Hasher.init(t, @intCast(content.len));
    h.update(content);
    return h.sum();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Hash SHA-256 empty blob via setObjectFormat" {
    defer hash_algo.setObjectFormat(.sha1);
    hash_algo.setObjectFormat(.sha256);

    const h = computeHash(.blob, "");
    try std.testing.expectEqual(@as(usize, 32), h.slice().len);
    var buf: [MaxHexSize]u8 = undefined;
    const hex = h.string(&buf);
    try std.testing.expectEqualStrings(
        "473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813",
        hex,
    );
}

test "parseHash accepts 40 and 64 hex" {
    const h1 = try parseHash("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    try std.testing.expect(!h1.isZero());
    try std.testing.expect(isHash("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"));
    try std.testing.expect(isHash("473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813"));
    try std.testing.expect(!isHash("deadbeef"));
    const h2 = try parseHash("473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813");
    try std.testing.expectEqual(@as(u8, 0x47), h2.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x13), h2.bytes[31]);
}
