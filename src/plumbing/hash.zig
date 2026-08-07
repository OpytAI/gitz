//! Object IDs and git object content hashing (go-git `plumbing/hash.go`).
//!
//! Digest size is SHA-1 (20 bytes). Streaming digests come from `plumbing/hash`
//! (`//src/plumbing/hash`) so algorithm registration stays in one place.

const std = @import("std");
const err = @import("error.zig");
const object = @import("object.zig");
const hash_algo = @import("hash");

/// SHA-1 digest size in bytes (go-git `hash.Size` without sha256 tag).
pub const Size: usize = hash_algo.Size;

/// Hex-encoded OID length (go-git `hash.HexSize`).
pub const HexSize: usize = hash_algo.HexSize;

/// Object id (go-git `plumbing.Hash`).
pub const Hash = struct {
    bytes: [Size]u8 = .{0} ** Size,

    pub fn isZero(self: Hash) bool {
        return std.mem.eql(u8, &self.bytes, &ZeroHash.bytes);
    }

    pub fn eql(self: Hash, other: Hash) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// Write lowercase hex into `buf` (must be at least `HexSize`).
    pub fn formatHex(self: Hash, buf: *[HexSize]u8) []const u8 {
        const hex = std.fmt.bytesToHex(self.bytes, .lower);
        @memcpy(buf, &hex);
        return buf[0..HexSize];
    }

    /// go-git `Hash.String` — hex into caller buffer.
    pub fn string(self: Hash, buf: *[HexSize]u8) []const u8 {
        return self.formatHex(buf);
    }

    pub fn fromBytes(raw: [Size]u8) Hash {
        return .{ .bytes = raw };
    }

    pub fn slice(self: *const Hash) *const [Size]u8 {
        return &self.bytes;
    }
};

/// Zero OID (go-git `ZeroHash`).
pub const ZeroHash: Hash = .{};

/// Parse a full 40-char hex OID.
pub fn parseHash(s: []const u8) err.Error!Hash {
    if (s.len != HexSize) return error.InvalidHash;
    var out: [Size]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch return error.InvalidHash;
    return Hash.fromBytes(out);
}

/// go-git `NewHash`: best-effort hex decode; invalid input yields zero.
pub fn newHash(s: []const u8) Hash {
    var h = ZeroHash;
    var tmp: [Size]u8 = undefined;
    if (std.fmt.hexToBytes(&tmp, s)) |decoded| {
        @memcpy(h.bytes[0..decoded.len], decoded);
    } else |_| {}
    return h;
}

/// go-git `IsHash`.
pub fn isHash(s: []const u8) bool {
    if (s.len != HexSize) return false;
    var tmp: [Size]u8 = undefined;
    _ = std.fmt.hexToBytes(&tmp, s) catch return false;
    return true;
}

/// Incremental git object hasher: header `type SP size NUL` then content.
/// Uses the registered default SHA-1 factory from `plumbing/hash`.
pub const Hasher = struct {
    inner: hash_algo.Hasher,

    pub fn init(t: object.ObjectType, size: i64) Hasher {
        var h = Hasher{ .inner = hash_algo.new(.sha1) };
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
        var out: [Size]u8 = undefined;
        self.inner.final(&out);
        return Hash.fromBytes(out);
    }
};

/// go-git `ComputeHash`.
pub fn computeHash(t: object.ObjectType, content: []const u8) Hash {
    var h = Hasher.init(t, @intCast(content.len));
    h.update(content);
    return h.sum();
}
