//! Packfile random-access Get (go-git `plumbing/format/packfile/packfile.go`).
//!
//! Always returns heap-owned `MemoryObject` values (go-git when `fs == nil`).
//! Filesystem-backed objects use the corresponding storage adapter.
//!
//! In-memory construction accepts the full pack image
//! bytes. The internal scanner is always `Scanner.initSeekable` so CRC and
//! pack SHA-1 follow the accurate mem hashing path (no streaming-tee drift).
//!
//! Also: `getAll` / `getByType` iterators and `getSizeByOffset` (inflated size
//! without always materializing non-delta objects).

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
const OffsetEntryIterator = idxfile.OffsetEntryIterator;

const HashKey = Hash;

/// Explicit error set for Get (avoids inferred-error dependency cycles).
const GetError = Error || idxfile.Error || Allocator.Error || std.Io.Reader.Error || std.Io.Writer.Error || error{ IntegerOverflow, InvalidType };

/// Random-access reader over a pack image + idx (go-git `Packfile`).
///
/// Objects from `get` / `getByOffset` / iterators are owned by this Packfile's
/// cache and freed in `close`. Do not `deinit` returned pointers.
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
    /// Resolved type at pack offset (go-git `offsetToType`).
    offset_to_type: std.AutoHashMapUnmanaged(i64, ObjectType) = .empty,

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
        self.offset_to_type.deinit(self.allocator);
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

    /// go-git `GetSizeByOffset` — inflated object size at pack offset.
    /// Non-delta: header length. Delta: target size from the delta header (LEB128)
    /// after inflate; does not fully materialize the resolved object.
    pub fn getSizeByOffset(self: *Packfile, o: i64) GetError!i64 {
        const h = self.objectHeaderAtOffset(o) catch |err| switch (err) {
            error.EndOfStream, error.SeekNotSupported => return error.ObjectNotFound,
            else => |e| return e,
        };
        return self.getObjectSize(&h);
    }

    /// go-git `GetAll` — iterator over every object in offset order.
    pub fn getAll(self: *Packfile) GetError!ObjectIterator {
        return self.getByType(.any);
    }

    /// go-git `GetByType` — objects of `typ` (`.any` = all). Invalid types error.
    pub fn getByType(self: *Packfile, typ: ObjectType) GetError!ObjectIterator {
        switch (typ) {
            .any, .blob, .tree, .commit, .tag => {
                const entries = try self.index.entriesByOffset();
                return .{
                    .p = self,
                    .typ = typ,
                    .iter = entries,
                };
            },
            else => return error.InvalidType,
        }
    }

    /// go-git `ID` — pack checksum (last `digestSize()` bytes of the pack image).
    pub fn id(self: *const Packfile) Error!Hash {
        const n = plumbing.digestSize();
        if (self.pack_data.len < n) return error.MalformedPackFile;
        const start = self.pack_data.len - n;
        return Hash.fromBytes(self.pack_data[start .. start + n]);
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

    fn getObjectSize(self: *Packfile, h: *const ObjectHeader) GetError!i64 {
        switch (h.object_type) {
            .commit, .tree, .blob, .tag => return h.length,
            .ref_delta, .ofs_delta => {
                var aw: std.Io.Writer.Allocating = .init(self.allocator);
                defer aw.deinit();
                _ = try self.scanner.nextObject(&aw.writer);
                return getDeltaObjectSize(aw.written());
            },
            else => return error.InvalidObject,
        }
    }

    /// Resolve the non-delta type of the object described by `h` (go-git `getObjectType`).
    fn getObjectType(self: *Packfile, h: ObjectHeader) GetError!ObjectType {
        var header = h;
        const typ: ObjectType = switch (header.object_type) {
            .commit, .tree, .blob, .tag => return header.object_type,
            .ref_delta, .ofs_delta => blk: {
                const base_offset: i64 = if (header.object_type == .ref_delta)
                    (self.index.findOffset(header.reference) catch return error.ObjectNotFound)
                else
                    header.offset_reference;

                if (self.offset_to_type.get(base_offset)) |base_typ| {
                    break :blk base_typ;
                } else {
                    // go-git reassigns `h` to the base header before recurse.
                    header = try self.objectHeaderAtOffset(base_offset);
                    break :blk try self.getObjectType(header);
                }
            },
            else => return error.InvalidObject,
        };
        // go-git: `p.offsetToType[h.Offset] = typ` (after reassignment, may be base).
        try self.offset_to_type.put(self.allocator, header.offset, typ);
        return typ;
    }

    fn getNextMemoryObject(self: *Packfile, h: *const ObjectHeader) GetError!*MemoryObject {
        const obj = try self.allocator.create(MemoryObject);
        // Cleared once cachePut takes ownership or frees a duplicate.
        var cache_settled = false;
        errdefer if (!cache_settled) {
            obj.deinit();
            self.allocator.destroy(obj);
        };
        obj.* = MemoryObject.init(self.allocator);
        obj.setType(h.object_type);
        obj.setSize(h.length);

        switch (h.object_type) {
            .commit, .tree, .blob, .tag => try self.fillRegularObjectContent(obj),
            .ref_delta => try self.fillREFDeltaObjectContent(obj, h.reference),
            .ofs_delta => try self.fillOFSDeltaObjectContent(obj, h.offset_reference),
            else => return error.InvalidObject,
        }

        const cached = try self.cachePut(obj);
        cache_settled = true;
        // Type map for GetByType filters (resolved final type).
        self.offset_to_type.put(self.allocator, h.offset, cached.object_type) catch {};
        return cached;
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
        return self.cache.get(h);
    }

    /// Insert `obj` into the cache and return the cache-owned pointer.
    ///
    /// Ownership:
    /// - New key: cache takes `obj` and returns it.
    /// - `found_existing`: keep the existing entry, **destroy** `obj`, return existing.
    /// - Zero hash: do not insert; return `error.InvalidObject` so the caller retains
    ///   `obj` (never return a pointer that is neither cache-owned nor caller-owned).
    /// - OOM on insert: caller retains `obj`.
    fn cachePut(self: *Packfile, obj: *MemoryObject) GetError!*MemoryObject {
        const h = obj.hash();
        if (h.isZero()) return error.InvalidObject;
        const gop = try self.cache.getOrPut(self.allocator, h);
        if (gop.found_existing) {
            obj.deinit();
            self.allocator.destroy(obj);
            return gop.value_ptr.*;
        }
        gop.value_ptr.* = obj;
        return obj;
    }
};

/// go-git `objectIter` — walks index entries by offset, optionally type-filtered.
///
/// Not thread-safe; use on the same thread as the parent `Packfile`.
///
/// Ownership: each `next()` yield is a **borrow** of a `*MemoryObject` owned by
/// the parent `Packfile` object cache. Do not `deinit`/`destroy` yielded objects.
/// `deinit` / close frees only iterator-local state (the sorted offset-entry list);
/// cached objects are released by `Packfile.close`.
pub const ObjectIterator = struct {
    p: *Packfile,
    typ: ObjectType,
    iter: OffsetEntryIterator,

    /// Next matching object, or `null` at end (go-git returns `io.EOF`).
    /// Returned pointer is cache-owned — see struct ownership docs.
    pub fn next(self: *ObjectIterator) GetError!?*MemoryObject {
        while (true) {
            const e = self.iter.next() orelse return null;
            const offset: i64 = @intCast(e.offset);

            if (self.typ != .any) {
                if (self.p.offset_to_type.get(offset)) |cached_typ| {
                    if (cached_typ != self.typ) continue;
                } else if (self.p.cacheGet(e.hash)) |obj| {
                    if (obj.object_type != self.typ) {
                        try self.p.offset_to_type.put(self.p.allocator, offset, obj.object_type);
                        continue;
                    }
                    return obj;
                } else {
                    const h = try self.p.objectHeaderAtOffset(offset);
                    if (h.object_type == .ref_delta or h.object_type == .ofs_delta) {
                        const resolved = try self.p.getObjectType(h);
                        if (resolved != self.typ) {
                            try self.p.offset_to_type.put(self.p.allocator, offset, resolved);
                            continue;
                        }
                        // getObjectType seeks; cannot use getNextMemoryObject safely.
                        return try self.p.objectAtOffset(offset, e.hash);
                    } else {
                        if (h.object_type != self.typ) {
                            try self.p.offset_to_type.put(self.p.allocator, offset, h.object_type);
                            continue;
                        }
                        if (self.p.cacheGet(e.hash)) |obj| return obj;
                        return try self.p.getNextMemoryObject(&h);
                    }
                }
            }

            return try self.p.objectAtOffset(offset, e.hash);
        }
    }

    /// go-git `Close` — free iterator-local allocations only (sorted entry list
    /// from `entriesByOffset`). Does **not** free yielded objects; those remain
    /// owned by the parent `Packfile` cache until `Packfile.close`.
    pub fn deinit(self: *ObjectIterator) void {
        self.iter.deinit();
        self.* = undefined;
    }
};

/// Target size from a pack delta payload (skip src LEB128, read target LEB128).
/// go-git `getDeltaObjectSize`.
fn getDeltaObjectSize(delta: []const u8) GetError!i64 {
    const after_src = try patch_delta.decodeLEB128(delta);
    const target = try patch_delta.decodeLEB128(after_src.rest);
    return @intCast(target.num);
}

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
    pf.init(allocator, index, @import("basic_pack.zig").data());
    return pf;
}

test "Packfile.id matches basic pack trailer" {
    var idx = MemoryIndex.init(std.testing.allocator);
    defer idx.deinit();
    var pf = openBasicPackfile(std.testing.allocator, &idx);
    defer pf.close();

    const pack_id = try pf.id();
    var hex: [plumbing.MaxHexSize]u8 = undefined;
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

// go-git packfile_test.go TestGetAll — 31 objects, every hash in expected_entries.
test "Packfile.getAll count 31 and hashes match expected_entries" {
    const allocator = std.testing.allocator;
    var w = idxfile.Writer.init(allocator);
    defer w.deinit();
    const index = try finishTestIndex(&w);

    var pf = openBasicPackfile(allocator, index);
    defer pf.close();

    var iter = try pf.getAll();
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |obj| {
        count += 1;
        const h = obj.hash();
        var found = false;
        for (expected_entries) |e| {
            if (h.eql(plumbing.newHash(e.hex))) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
    try std.testing.expectEqual(@as(usize, 31), count);
    try std.testing.expectEqual(expected_entries.len, count);
}

// go-git TestDecodeByType — basic OFS pack: 9 commits (8 base + 1 OFS-delta).
// Header inventory: commits at 12,286,449,615,838,1063,1230,1392 + delta@186→12.
const basic_commit_count: usize = 9;

test "Packfile.getByType commit count matches go-git basic pack" {
    const allocator = std.testing.allocator;
    var w = idxfile.Writer.init(allocator);
    defer w.deinit();
    const index = try finishTestIndex(&w);

    var pf = openBasicPackfile(allocator, index);
    defer pf.close();

    var iter = try pf.getByType(.commit);
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |obj| {
        try std.testing.expect(obj.object_type == .commit);
        count += 1;
    }
    try std.testing.expectEqual(basic_commit_count, count);
}

test "Packfile.getByType each base type returns only that type" {
    const allocator = std.testing.allocator;
    var w = idxfile.Writer.init(allocator);
    defer w.deinit();
    const index = try finishTestIndex(&w);

    var pf = openBasicPackfile(allocator, index);
    defer pf.close();

    const types = [_]ObjectType{ .commit, .tree, .blob, .tag };
    for (types) |t| {
        var iter = try pf.getByType(t);
        while (try iter.next()) |obj| {
            try std.testing.expect(obj.object_type == t);
        }
        iter.deinit();
    }
}

test "Packfile.getByType rejects invalid types" {
    const allocator = std.testing.allocator;
    var w = idxfile.Writer.init(allocator);
    defer w.deinit();
    const index = try finishTestIndex(&w);

    var pf = openBasicPackfile(allocator, index);
    defer pf.close();

    try std.testing.expectError(error.InvalidType, pf.getByType(.ofs_delta));
    try std.testing.expectError(error.InvalidType, pf.getByType(.ref_delta));
    try std.testing.expectError(error.InvalidType, pf.getByType(.invalid));
}

// go-git-ish size probe: offset 615 is non-delta commit length 333.
test "Packfile.getSizeByOffset 615 equals 333" {
    const allocator = std.testing.allocator;
    var w = idxfile.Writer.init(allocator);
    defer w.deinit();
    const index = try finishTestIndex(&w);

    var pf = openBasicPackfile(allocator, index);
    defer pf.close();

    const size = try pf.getSizeByOffset(basic_probe_offset);
    try std.testing.expectEqual(@as(i64, 333), size);
}

// go-git TestSize on ref-delta pack: binary.jpg and fixture Head sizes.
test "Packfile.getSizeByOffset ref-delta pack blob and commit" {
    const allocator = std.testing.allocator;
    var idx = try decodeRefDeltaIndex(allocator);
    defer idx.deinit();

    var pf: Packfile = undefined;
    pf.init(allocator, &idx, @import("ref_delta_pack.zig").data());
    defer pf.close();

    // binary.jpg (non-delta blob).
    const blob_off = try idx.findOffset(plumbing.newHash("d5c0f4ab811897cadf03aec358ae60d21f91c50d"));
    try std.testing.expectEqual(@as(i64, 76110), try pf.getSizeByOffset(blob_off));

    // Fixture HEAD (6ecf0ef2…) is REF-delta encoded; inflated size 245.
    const head_off = try idx.findOffset(plumbing.newHash("6ecf0ef2c2dffb796033e5a02219af86ec6584e5"));
    try std.testing.expectEqual(@as(i64, 245), try pf.getSizeByOffset(head_off));
}

// go-git TestDecodeByTypeRefDelta — commits only, count > 0.
test "Packfile.getByType commit on ref-delta pack" {
    const allocator = std.testing.allocator;
    var idx = try decodeRefDeltaIndex(allocator);
    defer idx.deinit();

    var pf: Packfile = undefined;
    pf.init(allocator, &idx, @import("ref_delta_pack.zig").data());
    defer pf.close();

    var iter = try pf.getByType(.commit);
    defer iter.deinit();

    var count: usize = 0;
    while (try iter.next()) |obj| {
        try std.testing.expect(obj.object_type == .commit);
        count += 1;
    }
    try std.testing.expect(count > 0);
}

fn decodeRefDeltaIndex(allocator: Allocator) !MemoryIndex {
    var idx = MemoryIndex.init(allocator);
    errdefer idx.deinit();
    var r = std.Io.Reader.fixed(@import("ref_delta_idx.zig").data);
    var d = idxfile.Decoder.init(&r);
    try d.decode(&idx);
    return idx;
}

// --- WP-D cachePut ownership (found_existing / zero-hash) ---

test "Packfile.cachePut found_existing keeps existing destroys new" {
    const allocator = std.testing.allocator;
    var idx = MemoryIndex.init(allocator);
    defer idx.deinit();
    var pf: Packfile = undefined;
    pf.init(allocator, &idx, &.{});
    defer pf.close();

    const existing = try allocator.create(MemoryObject);
    existing.* = MemoryObject.init(allocator);
    existing.setType(.blob);
    try existing.setContent("cache-put-a");
    const kept = try pf.cachePut(existing);

    const dup = try allocator.create(MemoryObject);
    dup.* = MemoryObject.init(allocator);
    dup.setType(.blob);
    try dup.setContent("cache-put-a"); // same content → same hash
    const returned = try pf.cachePut(dup);
    try std.testing.expect(returned == kept);
    try std.testing.expect(returned == existing);
    // `dup` was destroyed inside cachePut; only `existing` remains until close.
}

test "Packfile.cachePut zero hash does not insert leaves caller ownership" {
    const allocator = std.testing.allocator;
    var idx = MemoryIndex.init(allocator);
    defer idx.deinit();
    var pf: Packfile = undefined;
    pf.init(allocator, &idx, &.{});
    defer pf.close();

    const obj = try allocator.create(MemoryObject);
    defer {
        obj.deinit();
        allocator.destroy(obj);
    }
    obj.* = MemoryObject.init(allocator);
    obj.setType(.blob);
    // size/content mismatch → MemoryObject.hash() returns ZeroHash.
    obj.setSize(99);
    try std.testing.expect(obj.hash().isZero());
    try std.testing.expectError(error.InvalidObject, pf.cachePut(obj));
    try std.testing.expect(pf.cache.count() == 0);
}

test "Packfile.ObjectIterator deinit does not free cache-owned objects" {
    const allocator = std.testing.allocator;
    var w = idxfile.Writer.init(allocator);
    defer w.deinit();
    const index = try finishTestIndex(&w);

    var pf = openBasicPackfile(allocator, index);
    defer pf.close();

    var iter = try pf.getAll();
    const first = (try iter.next()).?;
    const cache_before = pf.cache.count();
    iter.deinit();
    try std.testing.expectEqual(cache_before, pf.cache.count());
    // Object remains valid via packfile cache after iterator close.
    const again = try pf.get(first.hash());
    try std.testing.expect(again == first);
}
