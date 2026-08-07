//! Sideband types and channel helpers.
//!
//! Port of go-git v5.19.2 `plumbing/protocol/packp/sideband/common.go`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Sideband type: `"side-band"` or `"side-band-64k"` (go-git `Type`).
pub const Type = enum(i8) {
    /// Legacy sideband up to 1000-byte messages (go-git `Sideband`).
    sideband = 0,
    /// Sideband up to 65520-byte messages (go-git `Sideband64k`).
    sideband64k = 1,
};

/// Max packed size for `Type.sideband` (go-git `MaxPackedSize`).
pub const MaxPackedSize: usize = 1000;

/// Max packed size for `Type.sideband64k` (go-git `MaxPackedSize64k`).
pub const MaxPackedSize64k: usize = 65520;

/// Sideband channel stream code (go-git `Channel`).
pub const Channel = enum(u8) {
    /// Packfile content (go-git `PackData`).
    packData = 1,
    /// Progress messages (go-git `ProgressMessage`).
    progressMessage = 2,
    /// Fatal error message just before stream aborts (go-git `ErrorMessage`).
    errorMessage = 3,

    /// Encode the payload as a sideband message: channel byte + payload.
    /// Caller owns the returned slice (go-git `Channel.WithPayload`).
    pub fn withPayload(self: Channel, allocator: Allocator, payload: []const u8) Allocator.Error![]u8 {
        const out = try allocator.alloc(u8, 1 + payload.len);
        out[0] = @intFromEnum(self);
        @memcpy(out[1..], payload);
        return out;
    }
};

test "constants match go-git" {
    try std.testing.expectEqual(@as(usize, 1000), MaxPackedSize);
    try std.testing.expectEqual(@as(usize, 65520), MaxPackedSize64k);
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Channel.packData));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Channel.progressMessage));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(Channel.errorMessage));
    try std.testing.expectEqual(@as(i8, 0), @intFromEnum(Type.sideband));
    try std.testing.expectEqual(@as(i8, 1), @intFromEnum(Type.sideband64k));
}

test "Channel.withPayload prepends channel byte" {
    const gpa = std.testing.allocator;
    const msg = try Channel.packData.withPayload(gpa, "abcd");
    defer gpa.free(msg);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 'a', 'b', 'c', 'd' }, msg);
}
