//! Package-local helpers for owned submodule configuration strings.

const std = @import("std");

pub fn set(allocator: std.mem.Allocator, dest: *[]const u8, value: []const u8) std.mem.Allocator.Error!void {
    if (dest.*.len > 0) allocator.free(dest.*);
    if (value.len == 0) {
        dest.* = "";
        return;
    }
    dest.* = try allocator.dupe(u8, value);
}
