//! Object IDs and git object content hashing (go-git `plumbing/hash.go`).
//!
//! # Design
//! - Storage is always `MaxSize` (32) bytes with **zero padding** (invariant).
//! - `eql` / AutoHashMap keys compare the full 32-byte buffer so map identity
//!   does not depend on process-global format.
//! - `slice` / `formatHex` use process `digestSize()` for *display / wire width*
//!   of the active repo format. Storage operations select the format for the
//!   calling thread; use `FormatScope` around direct codec calls.
//! - `parseHash` / `isHash` require the **active** hex width; use `parseHashAny` /
//!   `isHashAny` for fixtures that mix widths.
//! - Public construction: `fromBytes` / `fromHex` paths / `ZeroHash` / `Hasher.sum`.
//!   `fromBytes` copies only active `digestSize()` so dirty pad under SHA-1 is cleared.
//! - Dual-format: a full SHA-256 OID (non-zero bytes[20..]) is only valid while the
//!   active process format is SHA-256 (or inside `FormatScope(.sha256)`). Safety
//!   builds assert pad-under-active-width on `eql`/`isZero`; re-canonicalize paths
//!   that call `fromBytes(h.slice())` under the wrong format truncate.

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

/// Thread-local format helpers (see `//src/plumbing/hash`).
pub const digestSize = hash_algo.digestSize;
pub const hexSize = hash_algo.hexSize;
pub const setObjectFormat = hash_algo.setObjectFormat;
pub const objectFormat = hash_algo.objectFormat;
pub const supportsObjectFormat = hash_algo.supportsObjectFormat;
pub const Algorithm = hash_algo.Algorithm;

/// RAII: temporarily set the calling thread's object format; restores it on `deinit`.
/// Use when switching repos on a thread before wire codecs (pack/index/tree).
pub const FormatScope = struct {
    previous: Algorithm,

    pub fn enter(algo: Algorithm) FormatScope {
        const prev = hash_algo.objectFormat();
        hash_algo.setObjectFormat(algo);
        return .{ .previous = prev };
    }

    pub fn deinit(self: *FormatScope) void {
        hash_algo.setObjectFormat(self.previous);
        self.* = undefined;
    }
};

/// Object id (go-git `plumbing.Hash`). Zero-padded to `MaxSize`.
pub const Hash = struct {
    bytes: [MaxSize]u8 = .{0} ** MaxSize,

    /// True if every storage byte is zero.
    pub fn isZero(self: Hash) bool {
        self.debugAssertCanonical();
        return std.mem.allEqual(u8, &self.bytes, 0);
    }

    /// Full-buffer equality (pad must be zero — constructor invariant).
    /// Independent of process-global object format → safe as map keys.
    pub fn eql(self: Hash, other: Hash) bool {
        self.debugAssertCanonical();
        other.debugAssertCanonical();
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// Debug-only: pad beyond active `digestSize()` is zero.
    /// Uses process TLS format — SHA-256 OIDs must only be used under SHA-256
    /// active format (or `FormatScope`); otherwise safety builds assert.
    pub fn debugAssertCanonical(self: Hash) void {
        if (comptime !std.debug.runtime_safety) return;
        const n = hash_algo.digestSize();
        std.debug.assert(std.mem.allEqual(u8, self.bytes[n..], 0));
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

    /// Build from raw digest bytes. Copies only the active `digestSize()`;
    /// remainder stays zero (pad invariant). Longer buffers under SHA-1 do not
    /// retain dirty pad bytes.
    pub fn fromBytes(raw: []const u8) Hash {
        var h = ZeroHash;
        const n = @min(raw.len, hash_algo.digestSize());
        if (n > 0) @memcpy(h.bytes[0..n], raw[0..n]);
        return h;
    }

    /// Active-format OID slice (`digestSize()` bytes).
    pub fn slice(self: *const Hash) []const u8 {
        return self.bytes[0..hash_algo.digestSize()];
    }
};

/// go-git `HashSlice`: a sortable view over object ids.
///
/// Zig slices do not support attaching methods directly, so the port uses a
/// small non-owning wrapper. Ordering compares the complete, zero-padded hash
/// storage and therefore stays stable when the active object format changes.
pub const HashSlice = struct {
    items: []Hash,

    pub fn init(items: []Hash) HashSlice {
        return .{ .items = items };
    }

    pub fn len(self: HashSlice) usize {
        return self.items.len;
    }

    pub fn less(self: HashSlice, i: usize, j: usize) bool {
        return std.mem.order(u8, &self.items[i].bytes, &self.items[j].bytes) == .lt;
    }

    pub fn swap(self: HashSlice, i: usize, j: usize) void {
        std.mem.swap(Hash, &self.items[i], &self.items[j]);
    }
};

/// go-git `HashesSort`: sort object ids in increasing byte order.
pub fn hashesSort(items: []Hash) void {
    std.mem.sort(Hash, items, {}, struct {
        fn lessThan(_: void, a: Hash, b: Hash) bool {
            return std.mem.order(u8, &a.bytes, &b.bytes) == .lt;
        }
    }.lessThan);
}

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
        // Canonicalize at this hasher's width (`initAlgo` may differ from process format).
        var scope = FormatScope.enter(self.inner.algo());
        defer scope.deinit();
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

test "HashSlice and hashesSort use increasing full hash order" {
    var values = [_]Hash{
        Hash.fromBytes(&.{ 0x02 }),
        Hash.fromBytes(&.{ 0x01, 0xff }),
        Hash.fromBytes(&.{ 0x01, 0x01 }),
    };
    var view = HashSlice.init(&values);
    try std.testing.expectEqual(@as(usize, 3), view.len());
    try std.testing.expect(view.less(1, 0));
    view.swap(0, 2);
    try std.testing.expectEqual(@as(u8, 0x01), values[0].bytes[0]);

    hashesSort(&values);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x01 }, values[0].bytes[0..2]);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0xff }, values[1].bytes[0..2]);
    try std.testing.expectEqual(@as(u8, 0x02), values[2].bytes[0]);
}

test "parseHashAny accepts 40 and 64 hex" {
    defer hash_algo.setObjectFormat(.sha1);
    const h1 = try parseHashAny("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    try std.testing.expect(!h1.isZero());
    try std.testing.expect(isHashAny("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"));
    try std.testing.expect(isHashAny("473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813"));
    try std.testing.expect(!isHashAny("deadbeef"));
    // Full 32-byte OID requires SHA-256 active format for fromBytes pad rule.
    hash_algo.setObjectFormat(.sha256);
    const h2 = try parseHashAny("473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813");
    try std.testing.expectEqual(@as(u8, 0x47), h2.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x13), h2.bytes[31]);
}

test "fromBytes under SHA-1 clears dirty pad beyond digestSize" {
    defer hash_algo.setObjectFormat(.sha1);
    hash_algo.setObjectFormat(.sha1);

    var dirty: [MaxSize]u8 = undefined;
    @memset(&dirty, 0xab);
    // Real 20-byte digest with garbage in bytes[20..32].
    const digest = [_]u8{
        0xe6, 0x9d, 0xe2, 0x9b, 0xb2, 0xd1, 0xd6, 0x43,
        0x4b, 0x8b, 0x29, 0xae, 0x77, 0x5a, 0xd8, 0xc2,
        0xe4, 0x8c, 0x53, 0x91,
    };
    @memcpy(dirty[0..20], &digest);

    const from_dirty = Hash.fromBytes(&dirty);
    const from_clean = Hash.fromBytes(digest[0..]);
    try std.testing.expect(from_dirty.eql(from_clean));
    try std.testing.expect(std.mem.allEqual(u8, from_dirty.bytes[20..], 0));
    try std.testing.expectEqualSlices(u8, digest[0..], from_dirty.bytes[0..20]);
}

test "Hasher.sum initAlgo width is independent of process format" {
    defer hash_algo.setObjectFormat(.sha1);
    hash_algo.setObjectFormat(.sha1);

    // SHA-256 hasher while process format is SHA-1: full 32-byte OID, pad unused.
    var h256 = Hasher.initAlgo(.sha256, .blob, 0);
    const sum256 = h256.sum();
    try std.testing.expectEqual(@as(u8, 0x47), sum256.bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x13), sum256.bytes[31]);
    // Process format is still SHA-1 (FormatScope restored after sum).
    try std.testing.expect(objectFormat() == .sha1);
    try std.testing.expectEqual(@as(usize, 20), digestSize());

    // Reverse: SHA-1 hasher under process SHA-256 still pads zeros beyond 20.
    hash_algo.setObjectFormat(.sha256);
    var h1 = Hasher.initAlgo(.sha1, .blob, 0);
    const sum1 = h1.sum();
    try std.testing.expect(std.mem.allEqual(u8, sum1.bytes[20..], 0));
    try std.testing.expect(!sum1.isZero());
    // Empty-blob SHA-1 under active SHA-256: eql/isZero ok (pad zeros).
    try std.testing.expect(sum1.eql(sum1));
}

test "FormatScope restores previous object format" {
    defer setObjectFormat(.sha1);
    setObjectFormat(.sha1);
    {
        var scope = FormatScope.enter(.sha256);
        defer scope.deinit();
        try std.testing.expect(objectFormat() == .sha256);
        try std.testing.expectEqual(@as(usize, 32), digestSize());
    }
    try std.testing.expect(objectFormat() == .sha1);
    try std.testing.expectEqual(@as(usize, 20), digestSize());
}
