//! Object IDs and git object content hashing (go-git `plumbing/hash.go`).
//!
//! # Design
//! - Storage is always `MaxSize` (32) bytes with **zero padding** (invariant).
//! - `eql` / AutoHashMap keys compare the full 32-byte buffer so map identity
//!   does not depend on process-global format.
//! - `slice` / `formatHex` use process `digestSize()` for *display / wire width*
//!   of the active repo format. Prefer one active format per process (or carefully
//!   ordered tests) until storages own format end-to-end.
//! - `parseHash` / `isHash` require the **active** hex width; use `parseHashAny` /
//!   `isHashAny` for fixtures that mix widths.

const std = @import("std");
const err = @import("error.zig");
const object = @import("object.zig");
const hash_algo = @import("hash");

/// SHA-1 digest size (go-git `hash.Size` without sha256 tag). Documentation constant.
pub const Size: usize = hash_algo.Size;

/// Hex length for default SHA-1 (go-git `hash.HexSize`). Documentation constant.
pub const HexSize: usize = hash_algo.HexSize;

/// Maximum OID / hex sizes (SHA-256 capacity).
pub const MaxSize: usize = hash_algo.MaxSize;
pub const MaxHexSize: usize = hash_algo.MaxHexSize;

/// Process-wide format helpers (see `//src/plumbing/hash`).
pub const digestSize = hash_algo.digestSize;
pub const hexSize = hash_algo.hexSize;
pub const setObjectFormat = hash_algo.setObjectFormat;
pub const objectFormat = hash_algo.objectFormat;
pub const supportsObjectFormat = hash_algo.supportsObjectFormat;
pub const Algorithm = hash_algo.Algorithm;

/// Object id (go-git `plumbing.Hash`). Zero-padded to `MaxSize`.
pub const Hash = struct {
    bytes: [MaxSize]u8 = .{0} ** MaxSize,

    /// True if every storage byte is zero.
    pub fn isZero(self: Hash) bool {
        return std.mem.allEqual(u8, &self.bytes, 0);
    }

    /// Full-buffer equality (pad must be zero — constructor invariant).
    /// Independent of process-global object format → safe as map keys.
    pub fn eql(self: Hash, other: Hash) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// Write lowercase hex of the **active** digest width into `buf`.
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

    /// go-git `Hash.String`.
    pub fn string(self: Hash, buf: []u8) []const u8 {
        return self.formatHex(buf);
    }

    /// Build from raw digest bytes. Pads with zeros to `MaxSize`.
    pub fn fromBytes(raw: []const u8) Hash {
        var h = ZeroHash;
        const n = @min(raw.len, MaxSize);
        if (n > 0) @memcpy(h.bytes[0..n], raw[0..n]);
        return h;
    }

    /// Active-format OID slice (`digestSize()` bytes).
    pub fn slice(self: *const Hash) []const u8 {
        return self.bytes[0..hash_algo.digestSize()];
    }
};

/// Zero OID (go-git `ZeroHash`).
pub const ZeroHash: Hash = .{};

/// Parse a full hex OID matching the **active** object format width.
pub fn parseHash(s: []const u8) err.Error!Hash {
    const want = hash_algo.hexSize();
    if (s.len != want) return error.InvalidHash;
    var out: [MaxSize]u8 = .{0} ** MaxSize;
    const n = s.len / 2;
    _ = std.fmt.hexToBytes(out[0..n], s) catch return error.InvalidHash;
    return Hash.fromBytes(out[0..n]);
}

/// Parse hex of either width (40 or 64). Prefer `parseHash` for repo-scoped work.
pub fn parseHashAny(s: []const u8) err.Error!Hash {
    if (s.len != HexSize and s.len != MaxHexSize) return error.InvalidHash;
    var out: [MaxSize]u8 = .{0} ** MaxSize;
    const n = s.len / 2;
    _ = std.fmt.hexToBytes(out[0..n], s) catch return error.InvalidHash;
    return Hash.fromBytes(out[0..n]);
}

/// go-git `NewHash`: best-effort hex decode; invalid input yields zero.
pub fn newHash(s: []const u8) Hash {
    if (s.len == 0 or s.len > MaxHexSize or (s.len % 2) != 0) return ZeroHash;
    if (s.len != HexSize and s.len != MaxHexSize) return ZeroHash;
    var tmp: [MaxSize]u8 = undefined;
    const n = s.len / 2;
    if (std.fmt.hexToBytes(tmp[0..n], s)) |decoded| {
        return Hash.fromBytes(decoded);
    } else |_| {
        return ZeroHash;
    }
}

/// go-git `IsHash` — true for full hex of the **active** format width.
pub fn isHash(s: []const u8) bool {
    if (s.len != hash_algo.hexSize()) return false;
    var tmp: [MaxSize]u8 = undefined;
    const n = s.len / 2;
    _ = std.fmt.hexToBytes(tmp[0..n], s) catch return false;
    return true;
}

/// True for 40- or 64-char hex (cross-format checks / fixtures).
pub fn isHashAny(s: []const u8) bool {
    if (s.len != HexSize and s.len != MaxHexSize) return false;
    var tmp: [MaxSize]u8 = undefined;
    const n = s.len / 2;
    _ = std.fmt.hexToBytes(tmp[0..n], s) catch return false;
    return true;
}

/// Incremental git object hasher: header `type SP size NUL` then content.
/// Uses the active process-wide object format.
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

    /// Explicit algorithm (for codecs that own a format).
    pub fn initAlgo(algo: Algorithm, t: object.ObjectType, size: i64) Hasher {
        var h = Hasher{ .inner = hash_algo.new(algo) };
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

/// go-git `ComputeHash` using the **process-wide** active format.
pub fn computeHash(t: object.ObjectType, content: []const u8) Hash {
    return computeHashAlgo(objectFormat(), t, content);
}

/// Compute object OID with an explicit algorithm (per-repo / per-object).
pub fn computeHashAlgo(algo: Algorithm, t: object.ObjectType, content: []const u8) Hash {
    var h = Hasher.initAlgo(algo, t, @intCast(content.len));
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

test "Hash eql is independent of process format" {
    defer hash_algo.setObjectFormat(.sha1);
    const raw = [_]u8{1} ** 20;
    const a = Hash.fromBytes(raw[0..]);
    hash_algo.setObjectFormat(.sha256);
    const b = Hash.fromBytes(raw[0..]);
    try std.testing.expect(a.eql(b));
    // Format flip must not change equality of already-built OIDs (full buffer).
    try std.testing.expect(a.eql(b));
}

test "parseHash requires active hex width" {
    defer hash_algo.setObjectFormat(.sha1);
    _ = try parseHash("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    try std.testing.expectError(
        error.InvalidHash,
        parseHash("473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813"),
    );
    hash_algo.setObjectFormat(.sha256);
    _ = try parseHash("473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813");
    try std.testing.expectError(
        error.InvalidHash,
        parseHash("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"),
    );
}

test "parseHashAny accepts 40 and 64 hex" {
    const h1 = try parseHashAny("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    try std.testing.expect(!h1.isZero());
    try std.testing.expect(isHashAny("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"));
    try std.testing.expect(isHashAny("473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813"));
    try std.testing.expect(!isHashAny("deadbeef"));
    const h2 = try parseHashAny("473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813");
    try std.testing.expectEqual(@as(u8, 0x47), h2.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x13), h2.bytes[31]);
}
