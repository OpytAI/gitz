const std = @import("std");

const allocator = std.heap.wasm_allocator;
const slot_count = 16;

const Result = struct {
    bytes: []const u8,
    owned: bool,
};

var results: [slot_count]?Result = .{null} ** slot_count;
var scratch: [4096]u8 = undefined;

pub fn scratchPtr() [*]u8 {
    return &scratch;
}

pub fn scratchCapacity() u32 {
    return scratch.len;
}

pub fn putOwned(bytes: []u8) u32 {
    for (&results, 0..) |*slot, i| {
        if (slot.* == null) {
            slot.* = .{ .bytes = bytes, .owned = true };
            return @intCast(i + 1);
        }
    }
    allocator.free(bytes);
    return 0;
}

pub fn putError(err: anyerror) u32 {
    // Keep error results borrowed. Zig 0.16 currently emits an invalid
    // indirect allocator call for this cold wasm32-freestanding error path.
    const bytes: []const u8 = switch (err) {
        error.ReferenceHasChanged => "{\"ok\":false,\"error\":\"ReferenceHasChanged\"}",
        error.MalformedPackFile => "{\"ok\":false,\"error\":\"MalformedPackFile\"}",
        error.InvalidObject => "{\"ok\":false,\"error\":\"InvalidObject\"}",
        error.InvalidSignature => "{\"ok\":false,\"error\":\"InvalidSignature\"}",
        error.EmptyPackfile => "{\"ok\":false,\"error\":\"EmptyPackfile\"}",
        error.EndOfStream => "{\"ok\":false,\"error\":\"EndOfStream\"}",
        error.PackTooLarge => "{\"ok\":false,\"error\":\"PackTooLarge\"}",
        error.TooManyObjects => "{\"ok\":false,\"error\":\"TooManyObjects\"}",
        else => "{\"ok\":false,\"error\":\"UnknownError\"}",
    };
    return putBorrowed(bytes);
}

pub fn len(handle: u32) u32 {
    const bytes = get(handle) orelse return 0;
    return @intCast(bytes.len);
}

pub fn read(handle: u32, out: [*]u8, capacity: u32) u32 {
    const bytes = get(handle) orelse return 0;
    const count = @min(bytes.len, @as(usize, capacity));
    @memcpy(out[0..count], bytes[0..count]);
    return @intCast(count);
}

pub fn readAt(handle: u32, offset: u32, out: [*]u8, capacity: u32) u32 {
    const bytes = get(handle) orelse return 0;
    const start: usize = offset;
    if (start >= bytes.len) return 0;
    const count = @min(bytes.len - start, @as(usize, capacity));
    @memcpy(out[0..count], bytes[start .. start + count]);
    return @intCast(count);
}

pub fn free(handle: u32) void {
    const index = indexOf(handle) orelse return;
    if (results[index]) |result| {
        if (result.owned) allocator.free(@constCast(result.bytes));
    }
    results[index] = null;
}

fn get(handle: u32) ?[]const u8 {
    const index = indexOf(handle) orelse return null;
    const result = results[index] orelse return null;
    return result.bytes;
}

fn putBorrowed(bytes: []const u8) u32 {
    for (&results, 0..) |*slot, i| {
        if (slot.* == null) {
            slot.* = .{ .bytes = bytes, .owned = false };
            return @intCast(i + 1);
        }
    }
    return 0;
}

fn indexOf(handle: u32) ?usize {
    if (handle == 0 or handle > slot_count) return null;
    return @as(usize, handle - 1);
}
