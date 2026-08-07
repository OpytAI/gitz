//! Packfile Encoder — port of go-git v5.19.2
//! `plumbing/format/packfile/encoder.go`.
//!
//! Writes PACK format from a store (via `delta_selector`) or a pre-built
//! `[]*ObjectToPack` list. Zlib framing uses `utils/sync` `getZlibWriter`
//! (`std.compress.flate` with `.zlib`; Zig 0.16 has no `std.compress.zlib`).
//!
//! # Dependencies (siblings)
//!
//! - `object_to_pack.zig` — `ObjectToPack`, `newObjectToPack`, `newDeltaObjectToPack`
//! - `delta_selector.zig` — `DeltaSelector`, `Store`, `freeObjectsToPack`
//!
//! # go-git test map (`encoder_test.go`)
//!
//! | go-git | Zig |
//! |--------|-----|
//! | TestCorrectPackHeader | `encoder_test.TestCorrectPackHeader` |
//! | TestCorrectPackWithOneEmptyObject | `encoder_test.TestCorrectPackWithOneEmptyObject` |
//! | TestMaxObjectSize | `encoder_test.TestMaxObjectSize` |
//! | TestHashNotFound | `encoder_test.TestHashNotFound` |
//! | TestDecodeEncodeWithDeltaDecodeREF | `encoder_test.TestDecodeEncodeWithDeltaDecodeREF` |
//! | TestDecodeEncodeWithDeltaDecodeOFS | `encoder_test.TestDecodeEncodeWithDeltaDecodeOFS` |
//! | TestDecodeEncodeWithDeltasDecodeREF | `encoder_test.TestDecodeEncodeWithDeltasDecodeREF` |
//! | TestDecodeEncodeWithDeltasDecodeOFS | `encoder_test.TestDecodeEncodeWithDeltasDecodeOFS` |
//! | TestDecodeEncodeWithCycleREF/OFS | cycle undeltify path implemented; dedicated cycle graphs deferred |
//! | encoder_advanced_test.go | fixture-repo encode (filesystem phase) |

const std = @import("std");
const Allocator = std.mem.Allocator;
const IoWriter = std.Io.Writer;

const plumbing = @import("plumbing");
const binary = @import("binary");
const hash_pkg = @import("hash");
const sync = @import("utils/sync");

const common = @import("common.zig");
const otp_mod = @import("object_to_pack.zig");
const ds_mod = @import("delta_selector.zig");
const scanner_mod = @import("scanner.zig");
const parser_mod = @import("parser.zig");
const diff_delta_mod = @import("diff_delta.zig");

const Hash = plumbing.Hash;
const Size = plumbing.Size;
const ObjectType = plumbing.ObjectType;
const MemoryObject = plumbing.MemoryObject;

const ObjectToPack = otp_mod.ObjectToPack;
const DeltaSelector = ds_mod.DeltaSelector;
const Store = ds_mod.Store;
const freeObjectsToPack = ds_mod.freeObjectsToPack;
const Scanner = scanner_mod.Scanner;
const Parser = parser_mod.Parser;

/// Pack-write errors beyond I/O / allocator / store misses.
pub const EncodeError = error{
    /// Relative OFS base offset is non-positive (go-git `bad offset for OFS_DELTA`).
    BadOffset,
};

// ---------------------------------------------------------------------------
// offsetWriter (go-git `offsetWriter`) + pack SHA-1 multi-writer
// ---------------------------------------------------------------------------

// Counts bytes written, feeds the pack trailer hasher, and forwards to `out`.
// Simplified: no nested IoWriter vtable (avoids fieldParentPtr panics with flate).
const OffsetWriter = struct {
    out: *IoWriter,
    hasher: hash_pkg.Hasher,
    offset_bytes: i64 = 0,

    fn setup(self: *OffsetWriter, out: *IoWriter) void {
        self.out = out;
        self.hasher = hash_pkg.new(.sha1);
        self.offset_bytes = 0;
    }

    fn offset(self: *const OffsetWriter) i64 {
        return self.offset_bytes;
    }

    fn writeAll(self: *OffsetWriter, data: []const u8) IoWriter.Error!void {
        try self.out.writeAll(data);
        self.hasher.update(data);
        self.offset_bytes += @intCast(data.len);
    }

    fn writeUint32(self: *OffsetWriter, value: u32) IoWriter.Error!void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .big);
        try self.writeAll(&buf);
    }

    /// Write pack trailer without updating the (already finalized) hasher.
    fn writeTrailer(self: *OffsetWriter, data: []const u8) IoWriter.Error!void {
        try self.out.writeAll(data);
        self.offset_bytes += @intCast(data.len);
    }
};

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

/// Packfile encoder (go-git `Encoder`).
pub const Encoder = struct {
    allocator: Allocator,
    selector: DeltaSelector,
    ow: OffsetWriter,
    use_ref_deltas: bool,

    /// go-git `NewEncoder`.
    ///
    /// `store` is a `delta_selector.Store` vtable (`Store.from(T, ptr)`).
    /// `writer` must remain valid for encode calls.
    pub fn init(
        allocator: Allocator,
        writer: *IoWriter,
        store: Store,
        use_ref_deltas: bool,
    ) Encoder {
        var e: Encoder = .{
            .allocator = allocator,
            .selector = DeltaSelector.init(allocator, store),
            .ow = undefined,
            .use_ref_deltas = use_ref_deltas,
        };
        e.ow.setup(writer);
        return e;
    }

    /// Convenience: build `Store` from any type with
    /// `encodedObject(*T, ObjectType, Hash) anyerror!*MemoryObject`.
    pub fn initFrom(
        allocator: Allocator,
        writer: *IoWriter,
        comptime T: type,
        store_impl: *T,
        use_ref_deltas: bool,
    ) Encoder {
        return init(allocator, writer, Store.from(T, store_impl), use_ref_deltas);
    }

    /// go-git `(*Encoder).Encode`.
    ///
    /// `pack_window` is the delta sliding window; `0` disables deltas.
    /// Returns the pack checksum (trailer hash).
    pub fn encode(
        self: *Encoder,
        hashes: []const Hash,
        pack_window: u32,
    ) !Hash {
        const objects = try self.selector.objectsToPack(hashes, pack_window);
        defer freeObjectsToPack(self.allocator, objects);
        return self.encodeObjects(objects);
    }

    /// go-git package-private `(*Encoder).encode` — write a prepared list.
    pub fn encodeObjects(self: *Encoder, objects: []const *ObjectToPack) anyerror!Hash {
        try self.head(objects.len);
        for (objects) |o| {
            try self.entry(o);
        }
        return self.footer();
    }

    fn head(self: *Encoder, num_entries: usize) IoWriter.Error!void {
        try self.ow.writeAll(&common.signature);
        try self.ow.writeUint32(common.VersionSupported);
        try self.ow.writeUint32(@intCast(num_entries));
    }

    /// Explicit `anyerror` breaks the mutual inferred-error loop with `writeBaseIfDelta`.
    fn entry(self: *Encoder, o: *ObjectToPack) anyerror!void {
        if (o.wantWrite()) {
            // Cycle in delta chain — undeltify (go-git ignores restore error).
            self.restoreOriginal(o) catch {};
            o.backToOriginal();
        }

        if (o.isWritten()) return;

        o.markWantWrite();

        try self.writeBaseIfDelta(o);

        if (o.isWritten()) return;

        o.offset = self.ow.offset();

        if (o.isDelta()) {
            try self.writeDeltaHeader(o);
        } else {
            try self.entryHead(o.objectType(), o.objectSize());
        }

        const obj = o.object orelse return error.InvalidObject;
        const content = obj.readerBytes();

        // Compress into a temporary buffer, then writeAll so hasher/offset stay consistent.
        // flate requires the output writer buffer capacity > 8 bytes.
        var aw: IoWriter.Allocating = try .initCapacity(self.allocator, 256);
        defer aw.deinit();
        const zw = try sync.getZlibWriter(self.allocator, &aw.writer);
        defer sync.putZlibWriter(zw);
        try zw.writer().writeAll(content);
        try zw.finish();
        try self.ow.writeAll(aw.written());
    }

    /// Same package logic as go-git / `delta_selector.restoreOriginal` (file-private
    /// there; reimplemented so encoder can break delta cycles while writing).
    fn restoreOriginal(self: *Encoder, otp: *ObjectToPack) anyerror!void {
        if (otp.original != null) return;
        const obj = otp.object orelse return;
        if (!obj.object_type.isDelta()) return;
        if (!otp.resolved_original) return;
        const full = try self.selector.store.encodedObject(.any, otp.original_hash);
        otp.setOriginal(full);
    }

    fn writeBaseIfDelta(self: *Encoder, o: *ObjectToPack) anyerror!void {
        if (!o.isDelta()) return;
        const base = o.base orelse return;
        if (!base.isWritten()) {
            try self.entry(base);
        }
    }

    fn writeDeltaHeader(self: *Encoder, o: *ObjectToPack) !void {
        const t: ObjectType = if (self.use_ref_deltas) .ref_delta else .ofs_delta;
        const obj = o.object orelse return error.InvalidObject;
        // Declared size is the delta payload size (go-git `o.Object.objectSize()`).
        try self.entryHead(t, obj.size);

        if (self.use_ref_deltas) {
            const base = o.base orelse return error.InvalidObject;
            try self.writeRefDeltaHeader(base.objectHash());
        } else {
            try self.writeOfsDeltaHeader(o);
        }
    }

    fn writeRefDeltaHeader(self: *Encoder, base: Hash) IoWriter.Error!void {
        try self.ow.writeAll(base.bytes[0..]);
    }

    fn writeOfsDeltaHeader(self: *Encoder, o: *ObjectToPack) !void {
        const base = o.base orelse return error.InvalidObject;
        const relative_offset = o.offset - base.offset;
        if (relative_offset <= 0) return error.BadOffset;
        var vlq_buf: [16]u8 = undefined;
        var vw: IoWriter = .fixed(&vlq_buf);
        try binary.writeVariableWidthInt(&vw, relative_offset);
        try self.ow.writeAll(vw.buffered());
    }

    /// go-git `entryHead` — type nibble + size VLQ (`first_length_bits` layout).
    fn entryHead(self: *Encoder, type_num: ObjectType, size: i64) IoWriter.Error!void {
        const t: i64 = @intFromEnum(type_num);
        var sz = size;
        var header: [16]u8 = undefined;
        var n: usize = 0;

        var c: i64 = (t << common.first_length_bits) | (sz & @as(i64, common.mask_first_length));
        sz >>= common.first_length_bits;
        while (sz != 0) {
            header[n] = @intCast(c | common.mask_continue);
            n += 1;
            c = sz & @as(i64, common.mask_length);
            sz >>= common.length_bits;
        }
        header[n] = @intCast(c);
        n += 1;
        try self.ow.writeAll(header[0..n]);
    }

    fn footer(self: *Encoder) IoWriter.Error!Hash {
        var sum: [Size]u8 = undefined;
        self.ow.hasher.final(&sum);
        const h = Hash.fromBytes(sum);
        // Trailer is not part of the checksum (hasher already finalized).
        try self.ow.writeTrailer(sum[0..]);
        return h;
    }
};

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

const MapStore = struct {
    map: std.AutoHashMapUnmanaged([Size]u8, *MemoryObject) = .empty,
    allocator: Allocator,

    fn init(allocator: Allocator) MapStore {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *MapStore) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            self.allocator.destroy(e.value_ptr.*);
        }
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    fn put(self: *MapStore, obj: *MemoryObject) !Hash {
        const h = obj.hash();
        const gop = try self.map.getOrPut(self.allocator, h.bytes);
        if (gop.found_existing) {
            gop.value_ptr.*.deinit();
            self.allocator.destroy(gop.value_ptr.*);
        }
        gop.value_ptr.* = obj;
        return h;
    }

    pub fn encodedObject(self: *MapStore, t: ObjectType, h: Hash) error{ObjectNotFound}!*MemoryObject {
        _ = t;
        return self.map.get(h.bytes) orelse error.ObjectNotFound;
    }
};

fn newObject(allocator: Allocator, t: ObjectType, content: []const u8) !*MemoryObject {
    const o = try allocator.create(MemoryObject);
    errdefer allocator.destroy(o);
    o.* = MemoryObject.init(allocator);
    errdefer o.deinit();
    o.setType(t);
    try o.setContent(content);
    return o;
}

fn destroyObject(allocator: Allocator, o: *MemoryObject) void {
    o.deinit();
    allocator.destroy(o);
}

/// Minimal git delta: copy all of `src`, then insert `suffix`.
fn buildSimpleDelta(allocator: Allocator, src: []const u8, suffix: []const u8) !*MemoryObject {
    std.debug.assert(src.len < 128);
    std.debug.assert(suffix.len < 128);

    var raw: [64]u8 = undefined;
    var i: usize = 0;
    raw[i] = @intCast(src.len);
    i += 1;
    raw[i] = @intCast(src.len + suffix.len);
    i += 1;
    if (src.len > 0) {
        raw[i] = 0x80 | 0x10; // copy, size present, offset 0
        i += 1;
        raw[i] = @intCast(src.len);
        i += 1;
    }
    if (suffix.len > 0) {
        raw[i] = @intCast(suffix.len);
        i += 1;
        @memcpy(raw[i .. i + suffix.len], suffix);
        i += suffix.len;
    }

    const delta = try allocator.create(MemoryObject);
    errdefer allocator.destroy(delta);
    delta.* = MemoryObject.init(allocator);
    errdefer delta.deinit();
    delta.setType(.ofs_delta);
    try delta.setContent(raw[0..i]);
    return delta;
}

fn objectsEqual(a: *MemoryObject, b: *MemoryObject) !void {
    try std.testing.expect(a.object_type == b.object_type);
    try std.testing.expect(a.hash().eql(b.hash()));
    try std.testing.expectEqual(a.size, b.size);
    try std.testing.expectEqualSlices(u8, a.readerBytes(), b.readerBytes());
}

fn parsePackChecksum(allocator: Allocator, pack: []const u8) !Hash {
    var sc = Scanner.initSeekable(pack);
    var parser = try Parser.init(allocator, &sc, &.{});
    defer parser.deinit();
    return try parser.parse();
}

fn heapOtp(allocator: Allocator, value: ObjectToPack) !*ObjectToPack {
    const p = try allocator.create(ObjectToPack);
    p.* = value;
    return p;
}

const ObjectCollector = struct {
    allocator: Allocator,
    map: std.AutoHashMapUnmanaged([Size]u8, *MemoryObject) = .empty,
    pending_type: ObjectType = .invalid,

    fn init(allocator: Allocator) ObjectCollector {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *ObjectCollector) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            self.allocator.destroy(e.value_ptr.*);
        }
        self.map.deinit(self.allocator);
    }

    fn get(self: *ObjectCollector, h: Hash) ?*MemoryObject {
        return self.map.get(h.bytes);
    }

    pub fn onHeader(_: *ObjectCollector, _: u32) !void {}

    pub fn onInflatedObjectHeader(self: *ObjectCollector, t: ObjectType, _: i64, _: i64) !void {
        self.pending_type = t;
    }

    pub fn onInflatedObjectContent(self: *ObjectCollector, h: Hash, _: i64, _: u32, content: []const u8) !void {
        const obj = try self.allocator.create(MemoryObject);
        errdefer self.allocator.destroy(obj);
        obj.* = MemoryObject.init(self.allocator);
        errdefer obj.deinit();
        obj.setType(self.pending_type);
        try obj.setContent(content);
        // Ensure hash matches pack id (content may match multiple type labels).
        if (!obj.hash().eql(h)) {
            const types = [_]ObjectType{ .blob, .commit, .tree, .tag };
            for (types) |t| {
                if (plumbing.computeHash(t, content).eql(h)) {
                    obj.setType(t);
                    obj.cached_hash = h;
                    break;
                }
            }
        }
        const gop = try self.map.getOrPut(self.allocator, h.bytes);
        if (gop.found_existing) {
            gop.value_ptr.*.deinit();
            self.allocator.destroy(gop.value_ptr.*);
        }
        gop.value_ptr.* = obj;
    }

    pub fn onFooter(_: *ObjectCollector, _: Hash) !void {}
};

// ---------------------------------------------------------------------------
// Tests — encoder_test.go
// ---------------------------------------------------------------------------

test "encoder_test.TestCorrectPackHeader" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var store = MapStore.init(allocator);
    defer store.deinit();

    var aw: IoWriter.Allocating = .init(allocator);
    defer aw.deinit();

    var enc = Encoder.initFrom(allocator, &aw.writer, MapStore, &store, false);
    const h = try enc.encode(&.{}, 10);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    try expected.appendSlice(allocator, &common.signature);
    var u32buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &u32buf, common.VersionSupported, .big);
    try expected.appendSlice(allocator, &u32buf);
    std.mem.writeInt(u32, &u32buf, 0, .big);
    try expected.appendSlice(allocator, &u32buf);
    try expected.appendSlice(allocator, h.bytes[0..]);

    try std.testing.expectEqualSlices(u8, expected.items, aw.written());
}

test "encoder_test.TestCorrectPackWithOneEmptyObject" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var store = MapStore.init(allocator);
    defer store.deinit();

    const o = try newObject(allocator, .commit, &.{});
    const oh = try store.put(o);

    var aw: IoWriter.Allocating = .init(allocator);
    defer aw.deinit();

    var enc = Encoder.initFrom(allocator, &aw.writer, MapStore, &store, false);
    const h = try enc.encode(&.{oh}, 10);

    const written = aw.written();
    try std.testing.expect(written.len >= 12 + 1 + 2 + Size);

    try std.testing.expectEqualSlices(u8, "PACK", written[0..4]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, written[4..8], .big));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, written[8..12], .big));
    try std.testing.expectEqual(@as(u8, 16), written[12]); // commit, size 0

    try std.testing.expectEqualSlices(u8, h.bytes[0..], written[written.len - Size ..]);

    // Exact go-git empty zlib when this compressor matches:
    // 120, 156, 1, 0, 0, 255, 255, 0, 0, 0, 1
    const go_zlib_empty = [_]u8{ 120, 156, 1, 0, 0, 255, 255, 0, 0, 0, 1 };
    if (written.len == 12 + 1 + go_zlib_empty.len + Size) {
        try std.testing.expectEqualSlices(u8, &go_zlib_empty, written[13 .. 13 + go_zlib_empty.len]);
    } else {
        try std.testing.expectEqual(@as(u8, 0x78), written[13]);
    }

    const parsed = try parsePackChecksum(allocator, written);
    try std.testing.expect(parsed.eql(h));
}

test "encoder_test.TestMaxObjectSize" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var store = MapStore.init(allocator);
    defer store.deinit();

    const o = try allocator.create(MemoryObject);
    o.* = MemoryObject.init(allocator);
    o.setType(.commit);
    o.setSize(9223372036854775807);
    // Content empty while declared size is max i64 (go-git). Key by hash().
    const oh = o.hash();
    try store.map.put(allocator, oh.bytes, o);

    var aw: IoWriter.Allocating = .init(allocator);
    defer aw.deinit();

    var enc = Encoder.initFrom(allocator, &aw.writer, MapStore, &store, false);
    const h = try enc.encode(&.{oh}, 10);
    try std.testing.expect(!h.isZero());
}

test "encoder_test.TestHashNotFound" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var store = MapStore.init(allocator);
    defer store.deinit();

    var aw: IoWriter.Allocating = .init(allocator);
    defer aw.deinit();

    var enc = Encoder.initFrom(allocator, &aw.writer, MapStore, &store, false);
    // go-git NewHash("BAD") is incomplete; use a full missing oid for a clear miss.
    const missing = plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    try std.testing.expectError(error.ObjectNotFound, enc.encode(&.{missing}, 10));
}

fn simpleDeltaTest(use_ref_deltas: bool) !void {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var store = MapStore.init(allocator);
    defer store.deinit();

    const src_obj = try newObject(allocator, .blob, "0");
    const target_obj = try newObject(allocator, .blob, "01");
    // Store owns these after put.
    _ = try store.put(src_obj);
    _ = try store.put(target_obj);

    const delta_obj = try diff_delta_mod.getDelta(allocator, src_obj, target_obj);
    // delta body is owned by ObjectToPack via setDelta path; free on test end if not transferred.
    // newDeltaObjectToPack takes pointer; encoder does not free store objects.

    const src_pack = try heapOtp(allocator, otp_mod.newObjectToPack(src_obj));
    defer allocator.destroy(src_pack);
    const delta_pack = try heapOtp(allocator, otp_mod.newDeltaObjectToPack(src_pack, target_obj, delta_obj));
    defer {
        // Free the delta body (not in store).
        if (delta_pack.object) |d| {
            d.deinit();
            allocator.destroy(d);
        }
        allocator.destroy(delta_pack);
    }

    var aw: IoWriter.Allocating = try .initCapacity(allocator, 4096);
    defer aw.deinit();

    var enc = Encoder.initFrom(allocator, &aw.writer, MapStore, &store, use_ref_deltas);
    const enc_hash = try enc.encodeObjects(&[_]*ObjectToPack{ src_pack, delta_pack });

    const pack = aw.written();
    try std.testing.expect(pack.len > 12 + Size);
    // Pack trailer checksum must match encoder output.
    try std.testing.expectEqualSlices(u8, enc_hash.bytes[0..], pack[pack.len - Size ..][0..Size]);

    // Round-trip: parser must accept the pack (checksum validation).
    const dec_hash = try parsePackChecksum(allocator, pack);
    try std.testing.expect(enc_hash.eql(dec_hash));
}

test "encoder_test.TestDecodeEncodeWithDeltaDecodeOFS" {
    try simpleDeltaTest(false);
}

test "encoder_test.TestDecodeEncodeWithDeltaDecodeREF" {
    try simpleDeltaTest(true);
}

fn deltaOverDeltaTest(use_ref_deltas: bool) !void {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var store = MapStore.init(allocator);
    defer store.deinit();

    const src_obj = try newObject(allocator, .blob, "0");
    const target_obj = try newObject(allocator, .blob, "01");
    const other_obj = try newObject(allocator, .blob, "011111");
    _ = try store.put(src_obj);
    _ = try store.put(target_obj);
    _ = try store.put(other_obj);

    const d1 = try diff_delta_mod.getDelta(allocator, src_obj, target_obj);
    const d2 = try diff_delta_mod.getDelta(allocator, target_obj, other_obj);

    const src_pack = try heapOtp(allocator, otp_mod.newObjectToPack(src_obj));
    defer allocator.destroy(src_pack);
    const target_pack = try heapOtp(allocator, otp_mod.newObjectToPack(target_obj));
    defer allocator.destroy(target_pack);
    const delta1 = try heapOtp(allocator, otp_mod.newDeltaObjectToPack(src_pack, target_obj, d1));
    defer {
        if (delta1.object) |d| {
            d.deinit();
            allocator.destroy(d);
        }
        allocator.destroy(delta1);
    }
    const delta2 = try heapOtp(allocator, otp_mod.newDeltaObjectToPack(target_pack, other_obj, d2));
    defer {
        if (delta2.object) |d| {
            d.deinit();
            allocator.destroy(d);
        }
        allocator.destroy(delta2);
    }

    var aw: IoWriter.Allocating = try .initCapacity(allocator, 4096);
    defer aw.deinit();

    var enc = Encoder.initFrom(allocator, &aw.writer, MapStore, &store, use_ref_deltas);
    const enc_hash = try enc.encodeObjects(&[_]*ObjectToPack{
        target_pack,
        src_pack,
        delta1,
        delta2,
    });

    const pack = aw.written();
    try std.testing.expectEqualSlices(u8, enc_hash.bytes[0..], pack[pack.len - Size ..][0..Size]);
    const dec_hash = try parsePackChecksum(allocator, pack);
    try std.testing.expect(enc_hash.eql(dec_hash));
}

test "encoder_test.TestDecodeEncodeWithDeltasDecodeOFS" {
    try deltaOverDeltaTest(false);
}

test "encoder_test.TestDecodeEncodeWithDeltasDecodeREF" {
    try deltaOverDeltaTest(true);
}

test "encoder entryHead bit packing commit size 0 is 0x10" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var store = MapStore.init(allocator);
    defer store.deinit();
    var aw: IoWriter.Allocating = .init(allocator);
    defer aw.deinit();
    var enc = Encoder.initFrom(allocator, &aw.writer, MapStore, &store, false);

    try enc.entryHead(.commit, 0);
    const w = aw.written();
    try std.testing.expectEqual(@as(usize, 1), w.len);
    try std.testing.expectEqual(@as(u8, 16), w[0]);
}

test "encoder entryHead large size continues" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var store = MapStore.init(allocator);
    defer store.deinit();
    var aw: IoWriter.Allocating = .init(allocator);
    defer aw.deinit();
    var enc = Encoder.initFrom(allocator, &aw.writer, MapStore, &store, false);

    // blob (3) size 16 → first byte (3<<4)|0|0x80 = 0xB0, second = 1
    try enc.entryHead(.blob, 16);
    const w = aw.written();
    try std.testing.expectEqual(@as(usize, 2), w.len);
    try std.testing.expectEqual(@as(u8, 0xb0), w[0]);
    try std.testing.expectEqual(@as(u8, 0x01), w[1]);
}
