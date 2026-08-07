//! Pack index builder — port of go-git
//! `plumbing/format/idxfile/writer.go` (v5.19.2).
//!
//! Implements the packfile Observer callbacks used while scanning a pack.

const std = @import("std");
const plumbing = @import("plumbing");

const idxfile = @import("idxfile.zig");

const Allocator = std.mem.Allocator;
const Error = idxfile.Error;
const Entry = idxfile.Entry;
const MemoryIndex = idxfile.MemoryIndex;
const noMapping = idxfile.noMapping;
const VersionSupported = idxfile.VersionSupported;

/// Builds a `MemoryIndex` from object observations (go-git `Writer`).
pub const Writer = struct {
    allocator: Allocator,
    count: u32 = 0,
    checksum: plumbing.Hash = plumbing.ZeroHash,
    objects: std.ArrayListUnmanaged(Entry) = .empty,
    offset64_count: u32 = 0,
    finished: bool = false,
    cached_index: ?*MemoryIndex = null,
    /// Owned index when created by this writer.
    owned_index: ?MemoryIndex = null,
    added: std.AutoHashMapUnmanaged(HashKey, void) = .empty,

    const HashKey = [plumbing.Size]u8;

    pub fn init(allocator: Allocator) Writer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Writer) void {
        self.objects.deinit(self.allocator);
        self.added.deinit(self.allocator);
        if (self.owned_index) |*idx| idx.deinit();
        self.* = undefined;
    }

    /// go-git `Index` — create or return the finished index.
    pub fn getIndex(self: *Writer) (Error || Allocator.Error)!*MemoryIndex {
        if (self.cached_index) |idx| return idx;
        return self.createIndex();
    }

    /// go-git `Add` — append object data if hash not yet seen.
    pub fn add(self: *Writer, h: plumbing.Hash, pos: u64, crc: u32) Allocator.Error!void {
        const gop = try self.added.getOrPut(self.allocator, h.bytes);
        if (gop.found_existing) return;
        gop.value_ptr.* = {};
        try self.objects.append(self.allocator, .{
            .hash = h,
            .crc32 = crc,
            .offset = pos,
        });
    }

    /// go-git `Finished`.
    pub fn isFinished(self: *const Writer) bool {
        return self.finished;
    }

    /// go-git `OnHeader`.
    pub fn onHeader(self: *Writer, object_count: u32) Allocator.Error!void {
        self.count = object_count;
        try self.objects.ensureTotalCapacity(self.allocator, object_count);
    }

    /// go-git `OnInflatedObjectHeader` (no-op).
    pub fn onInflatedObjectHeader(
        self: *Writer,
        t: plumbing.ObjectType,
        obj_size: i64,
        pos: i64,
    ) error{}!void {
        _ = self;
        _ = t;
        _ = obj_size;
        _ = pos;
    }

    /// go-git `OnInflatedObjectContent`.
    pub fn onInflatedObjectContent(
        self: *Writer,
        h: plumbing.Hash,
        pos: i64,
        crc: u32,
        content: []const u8,
    ) Allocator.Error!void {
        _ = content;
        try self.add(h, @intCast(pos), crc);
    }

    /// go-git `OnFooter`.
    pub fn onFooter(self: *Writer, h: plumbing.Hash) (Error || Allocator.Error)!void {
        self.checksum = h;
        self.finished = true;
        _ = try self.createIndex();
    }

    fn createIndex(self: *Writer) (Error || Allocator.Error)!*MemoryIndex {
        if (!self.finished) return Error.IndexNotFinished;

        if (self.owned_index) |*old| {
            old.deinit();
            self.owned_index = null;
            self.cached_index = null;
        }
        self.owned_index = MemoryIndex.init(self.allocator);
        const idx = &self.owned_index.?;
        self.cached_index = idx;
        self.offset64_count = 0;

        std.mem.sort(Entry, self.objects.items, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return std.mem.order(u8, a.hash.bytes[0..], b.hash.bytes[0..]) == .lt;
            }
        }.less);

        for (&idx.fanout_mapping) |*m| m.* = noMapping;

        var last: i32 = -1;
        var bucket: i32 = -1;
        for (self.objects.items, 0..) |o, i| {
            const fan: usize = o.hash.bytes[0];

            // Fill gaps between fan buckets.
            var j: i32 = last + 1;
            while (j < @as(i32, @intCast(fan))) : (j += 1) {
                idx.fanout[@intCast(j)] = @intCast(i);
            }

            idx.fanout[fan] = @intCast(i + 1);

            if (last != @as(i32, @intCast(fan))) {
                bucket += 1;
                idx.fanout_mapping[fan] = bucket;
                last = @intCast(fan);

                try idx.names.append(idx.allocator, &.{});
                try idx.offset32.append(idx.allocator, &.{});
                try idx.crc32.append(idx.allocator, &.{});
            }

            const b: usize = @intCast(bucket);
            idx.names.items[b] = try appendBytes(idx.allocator, idx.names.items[b], o.hash.bytes[0..]);

            var offset = o.offset;
            if (offset > std.math.maxInt(i32)) {
                offset = try self.addOffset64(idx, offset);
            }

            var o32buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &o32buf, @intCast(offset), .big);
            idx.offset32.items[b] = try appendBytes(idx.allocator, idx.offset32.items[b], &o32buf);

            var crcbuf: [4]u8 = undefined;
            std.mem.writeInt(u32, &crcbuf, o.crc32, .big);
            idx.crc32.items[b] = try appendBytes(idx.allocator, idx.crc32.items[b], &crcbuf);
        }

        var j: i32 = last + 1;
        while (j < 256) : (j += 1) {
            idx.fanout[@intCast(j)] = @intCast(self.objects.items.len);
        }

        idx.version = VersionSupported;
        idx.packfile_checksum = self.checksum;
        return idx;
    }

    fn addOffset64(self: *Writer, idx: *MemoryIndex, pos: u64) Allocator.Error!u64 {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, pos, .big);
        idx.offset64 = try appendBytes(idx.allocator, idx.offset64, &buf);
        const index_val: u64 = @as(u64, self.offset64_count) | (@as(u64, 1) << 31);
        self.offset64_count += 1;
        return index_val;
    }
};

fn appendBytes(allocator: Allocator, old: []const u8, extra: []const u8) Allocator.Error![]u8 {
    const new_len = old.len + extra.len;
    const out = try allocator.alloc(u8, new_len);
    if (old.len != 0) {
        @memcpy(out[0..old.len], old);
        allocator.free(old);
    }
    @memcpy(out[old.len..], extra);
    return out;
}
