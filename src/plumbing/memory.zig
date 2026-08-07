//! In-memory encoded object (go-git `MemoryObject`).

const std = @import("std");
const hash_mod = @import("hash.zig");
const object = @import("object.zig");

const Hash = hash_mod.Hash;
const ZeroHash = hash_mod.ZeroHash;
const ObjectType = object.ObjectType;

/// Buffered encoded object. Hash is computed on first successful `hash()` when
/// `content.len == size`, then cached (go-git semantics: later mutations do not
/// recompute).
pub const MemoryObject = struct {
    allocator: std.mem.Allocator,
    object_type: ObjectType = .invalid,
    cached_hash: Hash = ZeroHash,
    content: std.ArrayList(u8) = .empty,
    /// Declared size; `write` keeps this equal to content length.
    size: i64 = 0,

    pub fn init(allocator: std.mem.Allocator) MemoryObject {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryObject) void {
        self.content.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn hash(self: *MemoryObject) Hash {
        if (!self.cached_hash.isZero()) return self.cached_hash;
        if (self.size < 0) return ZeroHash;
        const len: usize = @intCast(self.size);
        if (self.content.items.len != len) return ZeroHash;
        self.cached_hash = hash_mod.computeHash(self.object_type, self.content.items);
        return self.cached_hash;
    }

    /// Append bytes; updates size to content length (go-git `Write`).
    pub fn write(self: *MemoryObject, p: []const u8) std.mem.Allocator.Error!usize {
        try self.content.appendSlice(self.allocator, p);
        self.size = @intCast(self.content.items.len);
        return p.len;
    }

    /// Current content bytes (go-git reader over the object buffer).
    pub fn readerBytes(self: *const MemoryObject) []const u8 {
        return self.content.items;
    }
};
