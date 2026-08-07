//! Owned string helpers for config package values.
//!
//! Empty string is represented as `""` (not an allocated zero-length slice), so
//! `free` is only called when `len > 0`.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Replace `dest` with a copy of `value` (or `""` when empty). Frees prior content.
pub fn setOwned(allocator: Allocator, dest: *[]const u8, value: []const u8) Allocator.Error!void {
    if (dest.*.len > 0) allocator.free(dest.*);
    if (value.len == 0) {
        dest.* = "";
        return;
    }
    dest.* = try allocator.dupe(u8, value);
}

/// Free an owned string field and reset to `""`.
pub fn freeOwned(allocator: Allocator, s: *[]const u8) void {
    if (s.*.len > 0) allocator.free(s.*);
    s.* = "";
}

/// Free each string then the slice itself; set to empty slice.
pub fn freeStringList(allocator: Allocator, list: *[]const []const u8) void {
    if (list.*.len == 0) {
        list.* = &.{};
        return;
    }
    for (list.*) |s| {
        if (s.len > 0) allocator.free(s);
    }
    allocator.free(list.*);
    list.* = &.{};
}

/// Deep-copy a list of strings. Caller owns the result.
pub fn dupeStringList(allocator: Allocator, src: []const []const u8) Allocator.Error![]const []const u8 {
    if (src.len == 0) return &.{};
    const out = try allocator.alloc([]const u8, src.len);
    errdefer {
        for (out) |s| {
            if (s.len > 0) allocator.free(s);
        }
        allocator.free(out);
    }
    var i: usize = 0;
    errdefer {
        for (out[0..i]) |s| {
            if (s.len > 0) allocator.free(s);
        }
    }
    for (src) |s| {
        out[i] = if (s.len == 0) "" else try allocator.dupe(u8, s);
        i += 1;
    }
    return out;
}
