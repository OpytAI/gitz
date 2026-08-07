//! Advanced pack encoder round-trip tests — spirit of go-git
//! `plumbing/format/packfile/encoder_advanced_test.go`.
//!
//! Loads resolved objects from embedded fixture packs (no filesystem storage,
//! no go-git-fixtures). Puts every object into a local `MapStore`, shuffles
//! hashes with a deterministic PRNG, encodes with `pack_window` 10 and 0,
//! then re-parses via `Parser` + `idxfile.Writer` and checks:
//! - encode hash == pack ID
//! - `Packfile.getAll` yields the same hash set as the input
//!
//! # go-git test map
//!
//! | go-git | Zig |
//! |--------|-----|
//! | TestEncodeDecode (packWindow 10) | `encoder_advanced.TestEncodeDecode pack_window 10` |
//! | TestEncodeDecodeNoDeltaCompression | `encoder_advanced.TestEncodeDecodeNoDeltaCompression pack_window 0` |
//! | (same flow on REF-delta fixture) | `encoder_advanced.TestEncodeDecode ref_delta …` |
//!
//! Wired into `BUILD.bazel` (`encoder_advanced.zig`) and `root.zig` test import.

const std = @import("std");
const Allocator = std.mem.Allocator;
const IoWriter = std.Io.Writer;

const plumbing = @import("plumbing");
const idxfile = @import("idxfile");
const sync = @import("utils/sync");

const parser_mod = @import("parser.zig");
const scanner_mod = @import("scanner.zig");
const packfile_mod = @import("packfile.zig");
const encoder_mod = @import("encoder.zig");

const Hash = plumbing.Hash;
const Size = plumbing.Size;
const ObjectType = plumbing.ObjectType;
const MemoryObject = plumbing.MemoryObject;

const Parser = parser_mod.Parser;
const Observer = parser_mod.Observer;
const ObjectStore = parser_mod.ObjectStore;
const Scanner = scanner_mod.Scanner;
const Packfile = packfile_mod.Packfile;
const Encoder = encoder_mod.Encoder;

// ---------------------------------------------------------------------------
// Local MapStore (same shape as encoder.zig test helper)
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
        // Overwrite frees the previous store-owned object; same pointer is a no-op
        // free (matches ObjectStorage / delta_selector MapStore).
        if (gop.found_existing) {
            if (gop.value_ptr.* != obj) {
                gop.value_ptr.*.deinit();
                self.allocator.destroy(gop.value_ptr.*);
            }
        }
        gop.value_ptr.* = obj;
        return h;
    }

    pub fn encodedObject(self: *MapStore, t: ObjectType, h: Hash) error{ObjectNotFound}!*MemoryObject {
        _ = t;
        return self.map.get(h.bytes) orelse error.ObjectNotFound;
    }
};

/// Collects object hashes from Parser Observer callbacks (content is empty there).
const HashCollector = struct {
    allocator: Allocator,
    hashes: std.ArrayList(Hash) = .empty,

    fn deinit(self: *HashCollector) void {
        self.hashes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn onHeader(_: *HashCollector, _: u32) !void {}

    pub fn onInflatedObjectHeader(_: *HashCollector, _: ObjectType, _: i64, _: i64) !void {}

    pub fn onInflatedObjectContent(self: *HashCollector, h: Hash, _: i64, _: u32, _: []const u8) !void {
        try self.hashes.append(self.allocator, h);
    }

    pub fn onFooter(_: *HashCollector, _: Hash) !void {}
};

/// Deterministic Fisher–Yates (go-git uses `rand.Perm`; we pin a seed).
fn shuffleHashes(hashes: []Hash, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var i = hashes.len;
    while (i > 1) {
        i -= 1;
        const j = random.intRangeLessThan(usize, 0, i + 1);
        const tmp = hashes[i];
        hashes[i] = hashes[j];
        hashes[j] = tmp;
    }
}

/// Parse `pack_data`: store resolved objects in `ObjectStore`, collect hashes.
fn loadFromPack(
    allocator: Allocator,
    pack_data: []const u8,
    os: *ObjectStore,
    collector: *HashCollector,
) !void {
    var sc = Scanner.initSeekable(pack_data);
    const observers = [_]Observer{Observer.from(HashCollector, collector)};
    var parser = try Parser.initWithStorage(allocator, &sc, os, &observers);
    defer parser.deinit();
    _ = try parser.parse();
}

/// Clone every collected object from `os` into `store`; fill expected set.
fn populateMapStore(
    allocator: Allocator,
    os: *ObjectStore,
    collected: []const Hash,
    store: *MapStore,
    hashes: *std.ArrayList(Hash),
    expected: *std.AutoHashMapUnmanaged([Size]u8, void),
) !void {
    for (collected) |want| {
        const src = try os.get(want);
        const o = try allocator.create(MemoryObject);
        o.* = MemoryObject.init(allocator);
        var transferred = false;
        errdefer if (!transferred) {
            o.deinit();
            allocator.destroy(o);
        };
        o.setType(src.object_type);
        try o.setContent(src.readerBytes());
        const h = try store.put(o);
        transferred = true;
        try std.testing.expect(h.eql(want));
        try expected.put(allocator, h.bytes, {});
        try hashes.append(allocator, h);
    }
}

/// go-git `testEncodeDecode` — encode then decode; assert hash set + pack ID.
fn testEncodeDecode(pack_window: u32, pack_data: []const u8) !void {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    var os = ObjectStore.init(allocator);
    defer os.deinit();

    var collector: HashCollector = .{ .allocator = allocator };
    defer collector.deinit();

    try loadFromPack(allocator, pack_data, &os, &collector);
    try std.testing.expect(collector.hashes.items.len > 0);

    var store = MapStore.init(allocator);
    defer store.deinit();

    var expected: std.AutoHashMapUnmanaged([Size]u8, void) = .empty;
    defer expected.deinit(allocator);

    var hashes: std.ArrayList(Hash) = .empty;
    defer hashes.deinit(allocator);

    try populateMapStore(allocator, &os, collector.hashes.items, &store, &hashes, &expected);
    try std.testing.expectEqual(collector.hashes.items.len, hashes.items.len);
    try std.testing.expectEqual(hashes.items.len, expected.count());

    // Shuffle so delta selection cannot rely on pack order alone.
    shuffleHashes(hashes.items, 0x61647661); // 'adva'

    var aw: IoWriter.Allocating = try .initCapacity(allocator, pack_data.len);
    defer aw.deinit();

    var enc = Encoder.initFrom(allocator, &aw.writer, MapStore, &store, false);
    const encode_hash = try enc.encode(hashes.items, pack_window);
    const pack_out = aw.written();
    try std.testing.expect(pack_out.len >= 12 + Size);
    try std.testing.expectEqualSlices(u8, encode_hash.bytes[0..], pack_out[pack_out.len - Size ..][0..Size]);

    // Parser + idx Writer (go-git: NewParser(NewScanner(f), w)).
    var w = idxfile.Writer.init(allocator);
    defer w.deinit();
    {
        var sc = Scanner.initSeekable(pack_out);
        const observers = [_]Observer{Observer.from(idxfile.Writer, &w)};
        var parser = try Parser.init(allocator, &sc, &observers);
        defer parser.deinit();
        _ = try parser.parse();
    }
    const index = try w.getIndex();

    var pf: Packfile = undefined;
    pf.init(allocator, index, pack_out);
    defer pf.close();

    const decode_hash = try pf.id();
    try std.testing.expect(encode_hash.eql(decode_hash));

    var obtained: std.AutoHashMapUnmanaged([Size]u8, void) = .empty;
    defer obtained.deinit(allocator);

    var iter = try pf.getAll();
    defer iter.deinit();
    while (try iter.next()) |obj| {
        try obtained.put(allocator, obj.hash().bytes, {});
    }

    try std.testing.expectEqual(expected.count(), obtained.count());

    var eit = expected.keyIterator();
    while (eit.next()) |k| {
        try std.testing.expect(obtained.contains(k.*));
    }

    var oit = obtained.keyIterator();
    while (oit.next()) |k| {
        try std.testing.expect(expected.contains(k.*));
    }
}

// ---------------------------------------------------------------------------
// Tests — basic OFS-delta pack (31 objects)
// ---------------------------------------------------------------------------

test "encoder_advanced.TestEncodeDecode pack_window 10" {
    try testEncodeDecode(10, @import("basic_pack.zig").data());
}

test "encoder_advanced.TestEncodeDecodeNoDeltaCompression pack_window 0" {
    try testEncodeDecode(0, @import("basic_pack.zig").data());
}

// ---------------------------------------------------------------------------
// Optional second fixture — REF-delta pack (same object set, different wire)
// ---------------------------------------------------------------------------

test "encoder_advanced.TestEncodeDecode ref_delta pack_window 10" {
    try testEncodeDecode(10, @import("ref_delta_pack.zig").data());
}

test "encoder_advanced.TestEncodeDecodeNoDeltaCompression ref_delta pack_window 0" {
    try testEncodeDecode(0, @import("ref_delta_pack.zig").data());
}
