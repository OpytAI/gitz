//! Hash algorithm registry (go-git `plumbing/hash`).
//!
//! # Design
//! - Factories produce streaming digesters used by `plumbing` object hashing.
//! - Default SHA-1 is pure-Zig collision-detecting `sha1cd` (go-git / pjbgf).
//! - Only SHA-1 and SHA-256 may be registered (go-git restriction).
//!
//! Inventory tokens: `new`, `registerHash`.

const std = @import("std");
const sha1cd = @import("sha1cd");

/// Digest length for the default object format (SHA-1).
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

pub const RegisterError = error{
    /// go-git rejects a nil factory.
    NilFactory,
};

/// Constructs a streaming hasher.
pub const Factory = *const fn () Hasher;

/// Streaming hasher from `new`.
pub const Hasher = struct {
    algo: Algorithm,
    state: State,

    const State = union {
        sha1: sha1cd.Sha1cd,
        sha256: std.crypto.hash.sha2.Sha256,
    };

    pub fn update(self: *Hasher, data: []const u8) void {
        switch (self.algo) {
            .sha1 => self.state.sha1.update(data),
            .sha256 => self.state.sha256.update(data),
        }
    }

    /// Finalize into `out` (length ≥ `digestSize()`). Call `reset` to reuse.
    pub fn final(self: *Hasher, out: []u8) void {
        const n = self.digestSize();
        std.debug.assert(out.len >= n);
        switch (self.algo) {
            .sha1 => self.state.sha1.final(out[0..sha1cd.digest_length]),
            .sha256 => self.state.sha256.final(out[0..std.crypto.hash.sha2.Sha256.digest_length]),
        }
    }

    /// True if the last SHA-1 compression path mitigated a near-collision.
    pub fn collisionDetected(self: *const Hasher) bool {
        return switch (self.algo) {
            .sha1 => self.state.sha1.collisionDetected(),
            .sha256 => false,
        };
    }

    pub fn reset(self: *Hasher) void {
        switch (self.algo) {
            .sha1 => self.state.sha1 = sha1cd.Sha1cd.init(.{}),
            .sha256 => self.state.sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
        }
    }

    pub fn digestSize(self: *const Hasher) usize {
        return self.algo.digestSize();
    }
};

fn defaultSha1() Hasher {
    return .{ .algo = .sha1, .state = .{ .sha1 = sha1cd.Sha1cd.init(.{}) } };
}

fn defaultSha256() Hasher {
    return .{ .algo = .sha256, .state = .{ .sha256 = std.crypto.hash.sha2.Sha256.init(.{}) } };
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

test "Size and HexSize are SHA-1" {
    try std.testing.expectEqual(@as(usize, 20), Size);
    try std.testing.expectEqual(@as(usize, 40), HexSize);
    try std.testing.expect(CryptoType == .sha1);
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
