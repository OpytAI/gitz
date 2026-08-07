//! Packfile random-access Get (go-git `plumbing/format/packfile/packfile.go`).
//!
//! Always returns heap-owned `MemoryObject` values (go-git when `fs == nil`).
//! FSObject / billy paths wait for the filesystem phase.
//!
//! Construction is in-memory only for this phase: pass the full pack image
//! bytes. The internal scanner is always `Scanner.initSeekable` so CRC and
//! pack SHA-1 follow the accurate mem hashing path (no streaming-tee drift).

const std = @import("std");
const plumbing = @import("plumbing");
const idxfile = @import("idxfile");

const scanner_mod = @import("scanner.zig");
const patch_delta = @import("patch_delta.zig");
const pack_error = @import("error.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const ObjectType = plumbing.ObjectType;
const MemoryObject = plumbing.MemoryObject;
const Size = plumbing.Size;

const Scanner = scanner_mod.Scanner;
const ObjectHeader = scanner_mod.ObjectHeader;
const Error = pack_error.Error;
const MemoryIndex = idxfile.MemoryIndex;

const HashKey = [Size]u8;

/// Explicit error set for Get (avoids inferred-error dependency cycles).
const GetError = Error || Allocator.Error || std.Io.Reader.Error || std.Io.Writer.Error || error{IntegerOverflow};

/// Random-access reader over a pack image + idx (go-git `Packfile`).
///
/// Objects from `get` / `getByOffset` are owned by this Packfile's cache and
/// freed in `close`. Do not `deinit` returned pointers.
///
/// Call `init` on a stable `*Packfile` address (the scanner references the
/// pack image slice stored on the same struct).
pub const Packfile = struct {
    allocator: Allocator,
    index: *MemoryIndex,
    /// Full pack bytes (header + objects + 20-byte trailer). Not owned.
    pack_data: []const u8,
    scanner: Scanner,
    /// Resolved objects keyed by hash (go-git `deltaBaseCache`).
    cache: std.AutoHashMapUnmanaged(HashKey, *MemoryObject) = .empty,

    /// go-git `NewPackfile` / `NewPackfileWithCache` with `fs == nil`.
    ///
    /// ```zig
    /// var pf: Packfile = undefined;
    /// pf.init(allocator, &idx, pack_bytes);
    /// defer pf.close();
    /// ```
    pub fn init(self: *Packfile, allocator: Allocator, index: *MemoryIndex, pack_data: []const u8) void {
        self.* = .{
            .allocator = allocator,
            .index = index,
            .pack_data = pack_data,
            .scanner = Scanner.initSeekable(pack_data),
        };
    }

    /// go-git `Close` — free cached objects. Pack bytes and index are not owned.
    pub fn close(self: *Packfile) void {
        var it = self.cache.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            self.allocator.destroy(e.value_ptr.*);
        }
        self.cache.deinit(self.allocator);
        self.* = undefined;
    }

    /// go-git `Get` — object by hash via the pack index.
    pub fn get(self: *Packfile, h: Hash) GetError!*MemoryObject {
        const offset = self.index.findOffset(h) catch return error.ObjectNotFound;
        return self.objectAtOffset(offset, h);
    }

    /// go-git `GetByOffset` — object at pack offset (hash from index).
    pub fn getByOffset(self: *Packfile, o: i64) GetError!*MemoryObject {
        const h = self.index.findHash(o) catch return error.ObjectNotFound;
        return self.objectAtOffset(o, h);
    }

    /// go-git `ID` — pack checksum (last 20 bytes of the pack image).
    pub fn id(self: *const Packfile) Error!Hash {
        if (self.pack_data.len < Size) return error.MalformedPackFile;
        const start = self.pack_data.len - Size;
        var h: Hash = undefined;
        @memcpy(h.bytes[0..], self.pack_data[start..][0..Size]);
        return h;
    }

    fn objectAtOffset(self: *Packfile, offset: i64, hash: Hash) GetError!*MemoryObject {
        if (self.cacheGet(hash)) |obj| return obj;

        const h = self.objectHeaderAtOffset(offset) catch |err| switch (err) {
            error.EndOfStream => return error.ObjectNotFound,
            else => |e| return e,
        };

        return self.getNextMemoryObject(&h);
    }

    fn objectHeaderAtOffset(self: *Packfile, offset: i64) GetError!ObjectHeader {
        return self.scanner.seekObjectHeader(offset);
    }

    fn getNextMemoryObject(self: *Packfile, h: *const ObjectHeader) GetError!*MemoryObject {
        const obj = try self.allocator.create(MemoryObject);
        errdefer {
            obj.deinit();
            self.allocator.destroy(obj);
        }
        obj.* = MemoryObject.init(self.allocator);
        obj.setType(h.object_type);
        obj.setSize(h.length);

        switch (h.object_type) {
            .commit, .tree, .blob, .tag => try self.fillRegularObjectContent(obj),
            .ref_delta => try self.fillREFDeltaObjectContent(obj, h.reference),
            .ofs_delta => try self.fillOFSDeltaObjectContent(obj, h.offset_reference),
            else => return error.InvalidObject,
        }

        self.cachePut(obj);
        return obj;
    }

    fn fillRegularObjectContent(self: *Packfile, obj: *MemoryObject) GetError!void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        _ = try self.scanner.nextObject(&aw.writer);
        try obj.setContent(aw.written());
    }

    fn fillREFDeltaObjectContent(self: *Packfile, obj: *MemoryObject, ref: Hash) GetError!void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        _ = try self.scanner.nextObject(&aw.writer);
        try self.applyDeltaOnto(obj, ref, null, aw.written());
    }

    fn fillOFSDeltaObjectContent(self: *Packfile, obj: *MemoryObject, base_offset: i64) GetError!void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        _ = try self.scanner.nextObject(&aw.writer);
        try self.applyDeltaOnto(obj, null, base_offset, aw.written());
    }

    /// Resolve REF (`ref`) or OFS (`base_offset`) delta onto `obj`.
    fn applyDeltaOnto(
        self: *Packfile,
        obj: *MemoryObject,
        ref: ?Hash,
        base_offset: ?i64,
        delta: []const u8,
    ) GetError!void {
        const base: *MemoryObject = if (ref) |r|
            (if (self.cacheGet(r)) |b| b else self.get(r) catch return error.ReferenceDeltaNotFound)
        else blk: {
            const off = base_offset.?;
            const h = self.index.findHash(off) catch return error.ObjectNotFound;
            break :blk try self.objectAtOffset(off, h);
        };

        obj.setType(base.object_type);
        try patch_delta.applyDelta(self.allocator, obj, base, delta);
    }

    fn cacheGet(self: *Packfile, h: Hash) ?*MemoryObject {
        return self.cache.get(h.bytes);
    }

    fn cachePut(self: *Packfile, obj: *MemoryObject) void {
        const h = obj.hash();
        if (h.isZero()) return;
        const gop = self.cache.getOrPut(self.allocator, h.bytes) catch return;
        if (gop.found_existing) return;
        gop.value_ptr.* = obj;
    }
};

// ---------------------------------------------------------------------------
// Tests — go-git packfile_test.go (basic pack vectors)
// ---------------------------------------------------------------------------

const basic_pack_checksum_hex = "a3fed42da1e8189a077c0e6846c040dcf73fc9dd";
const basic_probe_hash_hex = "1669dce138d9b841a518c64b10914d88f5e488ea";
const basic_probe_offset: i64 = 615;

/// go-git `expectedEntries` (packfile_test.go) — full 31-object basic pack.
const expected_entries = [_]struct { hex: []const u8, offset: i64 }{
    .{ .hex = "1669dce138d9b841a518c64b10914d88f5e488ea", .offset = 615 },
    .{ .hex = "32858aad3c383ed1ff0a0f9bdf231d54a00c9e88", .offset = 1524 },
    .{ .hex = "35e85108805c84807bc66a02d91535e1e24b38b9", .offset = 1063 },
    .{ .hex = "6ecf0ef2c2dffb796033e5a02219af86ec6584e5", .offset = 186 },
    .{ .hex = "918c48b83bd081e863dbe1b80f8998f058cd8294", .offset = 286 },
    .{ .hex = "a5b8b09e2f8fcb0bb99d3ccb0958157b40890d69", .offset = 838 },
    .{ .hex = "af2d6a6954d532f8ffb47615169c8fdf9d383a1a", .offset = 449 },
    .{ .hex = "b029517f6300c2da0f4b651b8642506cd6aaf45d", .offset = 1392 },
    .{ .hex = "b8e471f58bcbca63b07bda20e428190409c2db47", .offset = 1230 },
    .{ .hex = "c192bd6a24ea1ab01d78686e417c8bdc7c3d197f", .offset = 1713 },
    .{ .hex = "d3ff53e0564a9f87d8e84b6e28e5060e517008aa", .offset = 1685 },
    .{ .hex = "e8d3ffab552895c19b9fcf7aa264d277cde33881", .offset = 12 },
    .{ .hex = "49c6bb89b17060d7b4deacb7b338fcc6ea2352a9", .offset = 78882 },
    .{ .hex = "4d081c50e250fa32ea8b1313cf8bb7c2ad7627fd", .offset = 84688 },
    .{ .hex = "586af567d0bb5e771e49bdd9434f5e0fb76d25fa", .offset = 84559 },
    .{ .hex = "5a877e6a906a2743ad6e45d99c1793642aaf8eda", .offset = 84479 },
    .{ .hex = "7e59600739c96546163833214c36459e324bad0a", .offset = 84653 },
    .{ .hex = "880cd14280f4b9b6ed3986d6671f907d7cc2a198", .offset = 78050 },
    .{ .hex = "8dcef98b1d52143e1e2dbc458ffe38f925786bf2", .offset = 84741 },
    .{ .hex = "9a48f23120e880dfbe41f7c9b7b708e9ee62a492", .offset = 80998 },
    .{ .hex = "9dea2395f5403188298c1dabe8bdafe562c491e3", .offset = 84032 },
    .{ .hex = "a39771a7651f97faf5c72e08224d857fc35133db", .offset = 84430 },
    .{ .hex = "a8d315b2b1c615d43042c3a62402b8a54288cf5c", .offset = 84375 },
    .{ .hex = "aa9b383c260e1d05fbbf6b30a02914555e20c725", .offset = 84760 },
    .{ .hex = "c2d30fa8ef288618f65f6eed6e168e0d514886f4", .offset = 84725 },
    .{ .hex = "c8f1d8c61f9da76f4cb49fd86322b6e685dba956", .offset = 80725 },
    .{ .hex = "cf4aa3b38974fb7d81f367c0830f7d78d65ab86b", .offset = 84608 },
    .{ .hex = "d5c0f4ab811897cadf03aec358ae60d21f91c50d", .offset = 2351 },
    .{ .hex = "dbd3641b371024f44d0e469a9c8f5457b0660de1", .offset = 84115 },
    .{ .hex = "eba74343e2f15d62adedfd8c883ee0262b5c8021", .offset = 84708 },
    .{ .hex = "fb72698cab7617ac416264415f13224dfd7a165e", .offset = 84671 },
};

fn finishTestIndex(w: *idxfile.Writer) !*MemoryIndex {
    try w.onHeader(@intCast(expected_entries.len));
    for (expected_entries) |e| {
        try w.onInflatedObjectContent(plumbing.newHash(e.hex), e.offset, 0, &.{});
    }
    try w.onFooter(plumbing.newHash(basic_pack_checksum_hex));
    return try w.getIndex();
}

fn openBasicPackfile(allocator: Allocator, index: *MemoryIndex) Packfile {
    var pf: Packfile = undefined;
    pf.init(allocator, index, @import("basic_pack.zig").data);
    return pf;
}

test "Packfile.id matches basic pack trailer" {
    var idx = MemoryIndex.init(std.testing.allocator);
    defer idx.deinit();
    var pf = openBasicPackfile(std.testing.allocator, &idx);
    defer pf.close();

    const pack_id = try pf.id();
    var hex: [plumbing.HexSize]u8 = undefined;
    try std.testing.expectEqualStrings(basic_pack_checksum_hex, pack_id.string(&hex));
}

test "Packfile.get probe hash 1669dce1 at offset 615" {
    const allocator = std.testing.allocator;
    var w = idxfile.Writer.init(allocator);
    defer w.deinit();
    const index = try finishTestIndex(&w);

    var pf = openBasicPackfile(allocator, index);
    defer pf.close();

    const probe = plumbing.newHash(basic_probe_hash_hex);
    const obj = try pf.get(probe);
    try std.testing.expect(obj.hash().eql(probe));
    try std.testing.expect(obj.object_type == .commit);
    try std.testing.expectEqual(@as(i64, 333), obj.size);
}

test "Packfile.getByOffset probe 615" {
    const allocator = std.testing.allocator;
    var w = idxfile.Writer.init(allocator);
    defer w.deinit();
    const index = try finishTestIndex(&w);

    var pf = openBasicPackfile(allocator, index);
    defer pf.close();

    const obj = try pf.getByOffset(basic_probe_offset);
    try std.testing.expect(obj.hash().eql(plumbing.newHash(basic_probe_hash_hex)));
}

test "Packfile.get ObjectNotFound for missing hash and offset" {
    const allocator = std.testing.allocator;
    var w = idxfile.Writer.init(allocator);
    defer w.deinit();
    const index = try finishTestIndex(&w);

    var pf = openBasicPackfile(allocator, index);
    defer pf.close();

    try std.testing.expectError(error.ObjectNotFound, pf.get(ZeroHash));
    try std.testing.expectError(error.ObjectNotFound, pf.getByOffset(std.math.maxInt(i64)));
}

test "Packfile.get all expected basic pack entries" {
    const allocator = std.testing.allocator;
    var w = idxfile.Writer.init(allocator);
    defer w.deinit();
    const index = try finishTestIndex(&w);

    var pf = openBasicPackfile(allocator, index);
    defer pf.close();

    try std.testing.expectEqual(@as(usize, 31), expected_entries.len);

    for (expected_entries) |e| {
        const h = plumbing.newHash(e.hex);
        const by_hash = try pf.get(h);
        try std.testing.expect(by_hash.hash().eql(h));
        const by_off = try pf.getByOffset(e.offset);
        try std.testing.expect(by_off.hash().eql(h));
    }
}

test "Packfile.get cache returns same MemoryObject pointer" {
    const allocator = std.testing.allocator;
    var w = idxfile.Writer.init(allocator);
    defer w.deinit();
    const index = try finishTestIndex(&w);

    var pf = openBasicPackfile(allocator, index);
    defer pf.close();

    const probe = plumbing.newHash(basic_probe_hash_hex);
    const a = try pf.get(probe);
    const b = try pf.get(probe);
    try std.testing.expect(a == b);
}
