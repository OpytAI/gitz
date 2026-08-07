//! In-memory encoded object (go-git `MemoryObject`).
//!
//! Optional `DeltaMeta` carries go-git `plumbing.DeltaObject` fields when a
//! storer returns an unresolved pack delta (filesystem `deltaObject` path).
//! Pure `MemoryObject` content remains the delta payload; metadata is additive.

const std = @import("std");
const hash_mod = @import("hash.zig");
const object = @import("object.zig");

const Hash = hash_mod.Hash;
const ZeroHash = hash_mod.ZeroHash;
const ObjectType = object.ObjectType;

/// go-git `plumbing.DeltaObject` fields on an encoded object.
///
/// Present when the object is an OFS/REF delta that knows its base and the
/// post-apply target identity (ActualHash / ActualSize). Used by pack write
/// (`ObjectToPack.Hash` / `Size`, `deltaSelector.fixAndBreakChains`).
pub const DeltaMeta = struct {
    /// Hash of the base object (go-git `BaseHash`).
    base_hash: Hash = ZeroHash,
    /// Hash of the fully resolved target (go-git `ActualHash`).
    actual_hash: Hash = ZeroHash,
    /// Size of the fully resolved target (go-git `ActualSize`).
    actual_size: i64 = 0,
};

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
    /// Optional DeltaObject metadata (null for ordinary objects).
    delta: ?DeltaMeta = null,

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

    /// go-git `(*MemoryObject).SetType`.
    pub fn setType(self: *MemoryObject, t: ObjectType) void {
        self.object_type = t;
    }

    /// go-git `(*MemoryObject).SetSize` — declared size only; does not resize content.
    pub fn setSize(self: *MemoryObject, n: i64) void {
        self.size = n;
    }

    /// Attach DeltaObject metadata (go-git filesystem `deltaObject` shape).
    pub fn setDeltaMeta(self: *MemoryObject, meta: DeltaMeta) void {
        self.delta = meta;
    }

    /// True when this object carries go-git `DeltaObject` metadata.
    pub fn isDeltaObject(self: *const MemoryObject) bool {
        return self.delta != null;
    }

    /// go-git `DeltaObject.BaseHash` — null when not a delta object.
    pub fn baseHash(self: *const MemoryObject) ?Hash {
        return if (self.delta) |d| d.base_hash else null;
    }

    /// go-git `DeltaObject.ActualHash` — null when not a delta object.
    pub fn actualHash(self: *const MemoryObject) ?Hash {
        return if (self.delta) |d| d.actual_hash else null;
    }

    /// go-git `DeltaObject.ActualSize` — null when not a delta object.
    pub fn actualSize(self: *const MemoryObject) ?i64 {
        return if (self.delta) |d| d.actual_size else null;
    }

    /// Append bytes; updates `size` to content length (go-git `Write`).
    pub fn write(self: *MemoryObject, p: []const u8) std.mem.Allocator.Error!usize {
        try self.content.appendSlice(self.allocator, p);
        self.size = @intCast(self.content.items.len);
        return p.len;
    }

    /// Replace content, set size, clear cached hash (pack inflate / ApplyDelta).
    pub fn setContent(self: *MemoryObject, data: []const u8) std.mem.Allocator.Error!void {
        self.content.clearRetainingCapacity();
        try self.content.appendSlice(self.allocator, data);
        self.size = @intCast(data.len);
        self.cached_hash = ZeroHash;
    }

    /// Content bytes (go-git reader over the object buffer).
    pub fn readerBytes(self: *const MemoryObject) []const u8 {
        return self.content.items;
    }
};
