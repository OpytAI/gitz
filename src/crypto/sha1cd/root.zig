//! Collision-detecting SHA-1 (sha1cd) — pure Zig.
//!
//! Algorithm: Marc Stevens / Dan Shumow (MIT), structured after the pure-Go
//! reference github.com/pjbgf/sha1cd (Apache-2.0). No C; freestanding-safe (wasm).
//!
//! Near-collision blocks are compressed three times so the final digest is not
//! the attacker's colliding hash. Ordinary inputs match FIPS SHA-1.

const std = @import("std");
const block = @import("block.zig");

pub const digest_length: usize = 20;
pub const block_length: usize = block.block_size;
/// go-git / pjbgf name for digest length.
pub const Size = digest_length;
/// go-git / pjbgf name for compression block size.
pub const BlockSize = block_length;

const Init0: u32 = 0x67452301;
const Init1: u32 = 0xEFCDAB89;
const Init2: u32 = 0x98BADCFE;
const Init3: u32 = 0x10325476;
const Init4: u32 = 0xC3D2E1F0;

/// Options reserved for API parity with `std.crypto.hash` constructors.
pub const Options = struct {};

/// Streaming collision-detecting SHA-1 (go-git / pjbgf `sha1cd.New`).
pub const Sha1cd = struct {
    h: [block.word_buffers]u32 = undefined,
    x: [BlockSize]u8 = undefined,
    nx: usize = 0,
    len: u64 = 0,
    /// True after a near-collision block was detected (and mitigated).
    col: bool = false,

    pub fn init(_: Options) Sha1cd {
        var d: Sha1cd = .{};
        d.reset();
        return d;
    }

    pub fn reset(self: *Sha1cd) void {
        self.h = .{ Init0, Init1, Init2, Init3, Init4 };
        self.nx = 0;
        self.len = 0;
        self.col = false;
        @memset(&self.x, 0);
    }

    pub fn update(self: *Sha1cd, data: []const u8) void {
        if (data.len == 0) return;
        var p = data;
        self.len +%= p.len;

        if (self.nx > 0) {
            const n = @min(BlockSize - self.nx, p.len);
            @memcpy(self.x[self.nx..][0..n], p[0..n]);
            self.nx += n;
            if (self.nx == BlockSize) {
                block.blockGeneric(&self.h, &self.col, self.x[0..]);
                self.nx = 0;
            }
            p = p[n..];
        }
        if (p.len >= BlockSize) {
            const n = p.len & ~(BlockSize - 1);
            block.blockGeneric(&self.h, &self.col, p[0..n]);
            p = p[n..];
        }
        if (p.len > 0) {
            @memcpy(self.x[0..p.len], p);
            self.nx = p.len;
        }
    }

    /// Finalize into `out`. Hasher is consumed; call `reset` to reuse.
    pub fn final(self: *Sha1cd, out: *[Size]u8) void {
        out.* = self.checkSum();
    }

    /// Finalize and report whether a collision was mitigated.
    pub fn finalCollisionAware(self: *Sha1cd, out: *[Size]u8) bool {
        out.* = self.checkSum();
        return self.col;
    }

    pub fn collisionDetected(self: *const Sha1cd) bool {
        return self.col;
    }

    fn checkSum(self: *Sha1cd) [Size]u8 {
        const bit_len = self.len;
        var tmp: [64]u8 = .{0} ** 64;
        tmp[0] = 0x80;
        const block_offset: usize = @intCast(bit_len % BlockSize);
        const padding_len: usize = if (block_offset < 56)
            56 - block_offset
        else
            BlockSize + 56 - block_offset;
        self.update(tmp[0..padding_len]);

        const len_bits = bit_len << 3;
        var len_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_buf, len_bits, .big);
        self.update(&len_buf);
        std.debug.assert(self.nx == 0);

        var digest: [Size]u8 = undefined;
        inline for (0..5) |i| {
            std.mem.writeInt(u32, digest[i * 4 ..][0..4], self.h[i], .big);
        }
        return digest;
    }
};

/// One-shot hash; second value is true if a collision was mitigated.
pub fn sum(data: []const u8) struct { [Size]u8, bool } {
    var d = Sha1cd.init(.{});
    d.update(data);
    var out: [Size]u8 = undefined;
    const col = d.finalCollisionAware(&out);
    return .{ out, col };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn expectHex(digest: [Size]u8, hex: []const u8) !void {
    var expected: [Size]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, hex);
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "sha1cd empty" {
    const d, const col = sum("");
    try expectHex(d, "da39a3ee5e6b4b0d3255bfef95601890afd80709");
    try std.testing.expect(!col);
}

test "sha1cd abc" {
    const d, const col = sum("abc");
    try expectHex(d, "a9993e364706816aba3e25717850c26c9cd0d89d");
    try std.testing.expect(!col);
}

test "sha1cd hello" {
    const d, const col = sum("hello");
    try expectHex(d, "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d");
    try std.testing.expect(!col);
}

test "sha1cd matches std.crypto.Sha1 on ordinary input" {
    const samples = [_][]const u8{
        "",
        "a",
        "abc",
        "message digest",
        "abcdefghijklmnopqrstuvwxyz",
        "blob 0\x00",
        "The quick brown fox jumps over the lazy dog",
    };
    for (samples) |s| {
        var cd = Sha1cd.init(.{});
        cd.update(s);
        var out_cd: [Size]u8 = undefined;
        cd.final(&out_cd);

        var stdh = std.crypto.hash.Sha1.init(.{});
        stdh.update(s);
        var out_std: [Size]u8 = undefined;
        stdh.final(&out_std);

        try std.testing.expectEqualSlices(u8, &out_std, &out_cd);
        try std.testing.expect(!cd.collisionDetected());
    }
}

test "sha1cd streaming matches one-shot" {
    var h = Sha1cd.init(.{});
    h.update("hel");
    h.update("lo");
    var a: [Size]u8 = undefined;
    h.final(&a);
    const b, _ = sum("hello");
    try std.testing.expectEqualSlices(u8, &b, &a);
}

test "sha1cd reset reuses hasher" {
    var h = Sha1cd.init(.{});
    h.update("hello");
    var a: [Size]u8 = undefined;
    h.final(&a);
    h.reset();
    h.update("hello");
    var b: [Size]u8 = undefined;
    h.final(&b);
    try std.testing.expectEqualSlices(u8, &a, &b);
}

// Vectors from data/fixtures/sha1cd (encoded in collision_vectors.zig).
test "sha1cd detects sha-mbles-1 collision" {
    const payload = @import("collision_vectors.zig").sha_mbles_1;
    const d, const col = sum(&payload);
    try std.testing.expect(col);
    try expectHex(d, "4f3d9be4a472c4dae83c6314aa6c36a064c1fd14");
}

test "sha1cd detects sha-mbles-2 collision" {
    const payload = @import("collision_vectors.zig").sha_mbles_2;
    const d, const col = sum(&payload);
    try std.testing.expect(col);
    try expectHex(d, "9ed5d77a4f48be1dbf3e9e15650733eb850897f2");
}
