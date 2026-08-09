//! Hash algorithm registry (go-git `plumbing/hash`).
//!
//! # Design
//! - Factories produce streaming digesters used by `plumbing` object hashing.
//! - Default SHA-1 is pure-Zig collision-detecting `sha1cd` (go-git / pjbgf).
//! - Only SHA-1 and SHA-256 may be registered (go-git restriction).
//! - gitz supports both formats in one binary via thread-local `objectFormat`
//!   (go-git uses compile tags for SHA-256).
//!
//! Inventory tokens: `new`, `registerHash`.

const std = @import("std");
const sha1cd = @import("sha1cd");

/// Maximum OID length (SHA-256). All Hash values use this storage size.
pub const MaxSize: usize = 32;

/// Maximum hex-encoded OID length (SHA-256).
pub const MaxHexSize: usize = 64;

/// Digest length for the default object format (SHA-1).
/// Kept for go-git default-tag docs and SHA-1 wire formats.
pub const Size: usize = 20;

/// Hex length for the default object format (SHA-1).
pub const HexSize: usize = 40;

/// Registerable algorithms (go-git: crypto.SHA1 / crypto.SHA256 only).
pub const Algorithm = enum {
    sha1,
    sha256,

    pub fn digestSize(self: Algorithm) usize {
        return switch (self) {
            .sha1 => sha1cd.digest_length,
            .sha256 => std.crypto.hash.sha2.Sha256.digest_length,
        };
    }
};

/// Default algorithm for object IDs (go-git without `sha256` build tag).
pub const CryptoType: Algorithm = .sha1;

/// Thread-local active object format (gitz dual extension; go-git uses build
/// tags). Thread-local state prevents concurrent SHA-1 and SHA-256 repository
/// operations from racing on the wire/object-id width. Callers that switch the
/// format on one thread must still restore it with `FormatScope`.
threadlocal var active_algo: Algorithm = .sha1;

/// Set the calling thread's object format (SHA-1 or SHA-256).
pub fn setObjectFormat(algo: Algorithm) void {
    active_algo = algo;
}

/// Current process-wide object format.
pub fn objectFormat() Algorithm {
    return active_algo;
}

/// Digest size of the active object format (20 or 32).
pub fn digestSize() usize {
    return active_algo.digestSize();
}

/// Hex size of the active object format (40 or 64).
pub fn hexSize() usize {
    return digestSize() * 2;
}

/// Whether this binary can use `algo` as an object format.
/// gitz always supports both (dual runtime); go-git is compile-tag gated.
pub fn supportsObjectFormat(algo: Algorithm) bool {
    return algo == .sha1 or algo == .sha256;
}

pub const RegisterError = error{
    /// go-git rejects a nil factory.
    NilFactory,
};

/// Constructs a streaming hasher.
pub const Factory = *const fn () Hasher;

/// Streaming hasher from `new`. State is a tagged union (Zig-safe).
pub const Hasher = struct {
    state: State,

    const State = union(Algorithm) {
        sha1: sha1cd.Sha1cd,
        sha256: std.crypto.hash.sha2.Sha256,
    };

    pub fn algo(self: *const Hasher) Algorithm {
        return self.state;
    }

    pub fn update(self: *Hasher, data: []const u8) void {
        switch (self.state) {
            inline else => |*h| h.update(data),
        }
    }

    /// Finalize into `out` (length ≥ `digestSize()`). Call `reset` to reuse.
    pub fn final(self: *Hasher, out: []u8) void {
        const n = self.digestSize();
        std.debug.assert(out.len >= n);
        switch (self.state) {
            .sha1 => |*h| h.final(out[0..sha1cd.digest_length]),
            .sha256 => |*h| h.final(out[0..std.crypto.hash.sha2.Sha256.digest_length]),
        }
    }

    /// True if the last SHA-1 compression path mitigated a near-collision.
    pub fn collisionDetected(self: *const Hasher) bool {
        return switch (self.state) {
            .sha1 => |h| h.collisionDetected(),
            .sha256 => false,
        };
    }

    pub fn reset(self: *Hasher) void {
        self.state = switch (self.state) {
            .sha1 => .{ .sha1 = sha1cd.Sha1cd.init(.{}) },
            .sha256 => .{ .sha256 = std.crypto.hash.sha2.Sha256.init(.{}) },
        };
    }

    pub fn digestSize(self: *const Hasher) usize {
        return @as(Algorithm, self.state).digestSize();
    }
};

fn defaultSha1() Hasher {
    return .{ .state = .{ .sha1 = sha1cd.Sha1cd.init(.{}) } };
}

fn defaultSha256() Hasher {
    return .{ .state = .{ .sha256 = std.crypto.hash.sha2.Sha256.init(.{}) } };
}

var algos: [2]Factory = .{ defaultSha1, defaultSha256 };

fn resetRegistry() void {
    algos = .{ defaultSha1, defaultSha256 };
}

/// Override the factory for `algo`. Pass `null` to get `NilFactory` (go-git parity).
pub fn registerHash(algo: Algorithm, factory: ?Factory) RegisterError!void {
    const f = factory orelse return RegisterError.NilFactory;
    switch (algo) {
        .sha1, .sha256 => algos[@intFromEnum(algo)] = f,
    }
}

/// Create a hasher for `algo` (go-git `New`).
pub fn new(algo: Algorithm) Hasher {
    return algos[@intFromEnum(algo)]();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Size and HexSize are SHA-1 defaults; MaxSize is SHA-256" {
    try std.testing.expectEqual(@as(usize, 20), Size);
    try std.testing.expectEqual(@as(usize, 40), HexSize);
    try std.testing.expectEqual(@as(usize, 32), MaxSize);
    try std.testing.expectEqual(@as(usize, 64), MaxHexSize);
    try std.testing.expect(CryptoType == .sha1);
    try std.testing.expect(objectFormat() == .sha1);
    try std.testing.expectEqual(@as(usize, 20), digestSize());
    try std.testing.expectEqual(@as(usize, 40), hexSize());
    try std.testing.expect(supportsObjectFormat(.sha1));
    try std.testing.expect(supportsObjectFormat(.sha256));
}

test "registerHash rejects nil factory" {
    defer resetRegistry();
    try std.testing.expectError(RegisterError.NilFactory, registerHash(.sha1, null));
}

test "new SHA-1 empty and hello digests" {
    defer resetRegistry();
    var h = new(.sha1);
    var empty: [Size]u8 = undefined;
    h.final(&empty);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xda, 0x39, 0xa3, 0xee, 0x5e, 0x6b, 0x4b, 0x0d,
        0x32, 0x55, 0xbf, 0xef, 0x95, 0x60, 0x18, 0x90,
        0xaf, 0xd8, 0x07, 0x09,
    }, &empty);

    h = new(.sha1);
    h.update("hello");
    var hello: [Size]u8 = undefined;
    h.final(&hello);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xaa, 0xf4, 0xc6, 0x1d, 0xdc, 0xc5, 0xe8, 0xa2,
        0xda, 0xbe, 0xde, 0x0f, 0x3b, 0x48, 0x2c, 0xd9,
        0xae, 0xa9, 0x43, 0x4d,
    }, &hello);
}

test "new SHA-1 git empty blob header" {
    defer resetRegistry();
    var h = new(.sha1);
    h.update("blob 0\x00");
    var out: [Size]u8 = undefined;
    h.final(&out);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xe6, 0x9d, 0xe2, 0x9b, 0xb2, 0xd1, 0xd6, 0x43,
        0x4b, 0x8b, 0x29, 0xae, 0x77, 0x5a, 0xd8, 0xc2,
        0xe4, 0x8c, 0x53, 0x91,
    }, &out);
}

test "new SHA-256 empty and hello digests" {
    defer resetRegistry();
    var h = new(.sha256);
    var empty: [MaxSize]u8 = undefined;
    h.final(empty[0..]);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    }, empty[0..32]);

    h = new(.sha256);
    h.update("hello");
    var hello: [MaxSize]u8 = undefined;
    h.final(hello[0..]);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x2c, 0xf2, 0x4d, 0xba, 0x5f, 0xb0, 0xa3, 0x0e,
        0x26, 0xe8, 0x3b, 0x2a, 0xc5, 0xb9, 0xe2, 0x9e,
        0x1b, 0x16, 0x1e, 0x5c, 0x1f, 0xa7, 0x42, 0x5e,
        0x73, 0x04, 0x33, 0x62, 0x93, 0x8b, 0x98, 0x24,
    }, hello[0..32]);
}

test "setObjectFormat SHA-256 git empty blob header" {
    defer setObjectFormat(.sha1);
    defer resetRegistry();
    setObjectFormat(.sha256);
    try std.testing.expectEqual(@as(usize, 32), digestSize());
    try std.testing.expectEqual(@as(usize, 64), hexSize());

    var h = new(objectFormat());
    h.update("blob 0\x00");
    var out: [MaxSize]u8 = undefined;
    h.final(out[0..]);
    // SHA-256 of "blob 0\0" (git empty-blob object bytes).
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x47, 0x3a, 0x0f, 0x4c, 0x3b, 0xe8, 0xa9, 0x36,
        0x81, 0xa2, 0x67, 0xe3, 0xb1, 0xe9, 0xa7, 0xdc,
        0xda, 0x11, 0x85, 0x43, 0x6f, 0xe1, 0x41, 0xf7,
        0x74, 0x91, 0x20, 0xa3, 0x03, 0x72, 0x18, 0x13,
    }, out[0..32]);
}

test "reset reuses hasher" {
    defer resetRegistry();
    var h = new(.sha1);
    h.update("hello");
    var a: [Size]u8 = undefined;
    h.final(&a);
    h.reset();
    h.update("hello");
    var b: [Size]u8 = undefined;
    h.final(&b);
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "registerHash override is used" {
    defer resetRegistry();
    const counter = struct {
        var calls: usize = 0;
        fn factory() Hasher {
            calls += 1;
            return defaultSha1();
        }
    };
    counter.calls = 0;
    try registerHash(.sha1, counter.factory);
    _ = new(.sha1);
    _ = new(.sha1);
    try std.testing.expectEqual(@as(usize, 2), counter.calls);
}
