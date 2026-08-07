//! BaseStorageSuite — port of go-git `storage/test/storage_suite.go`.
//!
//! Parameterized over any storage type that exposes the go-git storer method set
//! plus capability flags (`implements_*`). go-git type-assert + `c.Skip` maps to
//! early-return on those flags:
//! - PackfileWriter / DeltaObjectStorer — false on memory; true on filesystem
//! - Transactioner — true on memory (`begin`); false on filesystem
//!
//! Capability-gated tests stay suite members and early-return when unsupported.
//! Config checks use the minimal memory Config (is_bare + remotes + branches).
//!
//! Runners:
//! - `runAllMemory` — `//src/storage:suite_test`
//! - `runAllWithFactory` — any backend (filesystem Mem factory in filesystem tests)

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ObjectType = plumbing.ObjectType;
const MemoryObject = plumbing.MemoryObject;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const Config = memory.Config;
const Index = memory.Index;

const testing = std.testing;

const TestObjectMeta = struct {
    hash_hex: []const u8,
    typ: ObjectType,
};

const test_object_meta = [_]TestObjectMeta{
    .{ .hash_hex = "dcf5b16e76cce7425d0beaef62d79a7d10fce1f5", .typ = .commit },
    .{ .hash_hex = "4b825dc642cb6eb9a060e54bf8d69288fbee4904", .typ = .tree },
    .{ .hash_hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", .typ = .blob },
    .{ .hash_hex = "d994c6bb648123a17e8f70a966857c546b2a6f94", .typ = .tag },
};

const valid_types = [_]ObjectType{ .commit, .blob, .tag, .tree };

/// Fixture state for BaseStorageSuite (go-git `BaseStorageSuite`).
/// Parameterized: `StorageT` is the backend storage type.
pub fn BaseStorageSuite(comptime StorageT: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        storer: *StorageT,

        /// go-git type-assert `storer.PackfileWriter`.
        supports_packfile_writer: bool = false,
        /// go-git type-assert `storer.DeltaObjectStorer`.
        supports_delta_object_storer: bool = false,
        /// go-git type-assert `storer.Transactioner`.
        supports_transactioner: bool = false,

        /// go-git `NewBaseStorageSuite`.
        pub fn init(allocator: Allocator, storer: *StorageT) Self {
            return .{
                .allocator = allocator,
                .storer = storer,
                .supports_packfile_writer = StorageT.implements_packfile_writer,
                .supports_delta_object_storer = StorageT.implements_delta_object_storer,
                .supports_transactioner = StorageT.implements_transactioner,
            };
        }

        fn newTypedObject(self: *Self, t: ObjectType) !*MemoryObject {
            const o = try self.storer.newEncodedObject();
            o.setType(t);
            return o;
        }
    };
}

fn objectEquals(a: *MemoryObject, b: *MemoryObject) !void {
    if (!a.hash().eql(b.hash())) return error.TestExpectedEqual;
    if (!std.mem.eql(u8, a.readerBytes(), b.readerBytes())) return error.TestExpectedEqual;
}

fn hexOf(h: Hash, buf: *[plumbing.HexSize]u8) []const u8 {
    return h.string(buf);
}

fn metaFor(t: ObjectType) TestObjectMeta {
    for (test_object_meta) |m| {
        if (m.typ == t) return m;
    }
    unreachable;
}

fn isErrorUnion(comptime T: type) bool {
    return @typeInfo(T) == .error_union;
}

/// Call a method that may return void or an error union.
fn callMaybeError(result: anytype) !void {
    if (comptime isErrorUnion(@TypeOf(result))) {
        _ = try result;
    }
}

/// `shallow()` is either `[]const Hash` (memory) or `![]const Hash` (filesystem).
fn callShallow(storer: anytype) ![]const Hash {
    const result = storer.shallow();
    if (comptime isErrorUnion(@TypeOf(result))) {
        return try result;
    }
    return result;
}

/// Free a reference returned by backends that own name/target strings.
fn releaseRef(s: anytype, ref: Reference) void {
    const ST = @TypeOf(s.storer.*);
    if (!@hasDecl(ST, "reference_returns_owned") or !ST.reference_returns_owned) return;
    if (ref.name.raw.len > 0) s.allocator.free(ref.name.raw);
    if (ref.type == .symbolic and ref.target.raw.len > 0) s.allocator.free(ref.target.raw);
}

fn setIndexTakesOwnership(comptime ST: type) bool {
    if (@hasDecl(ST, "set_index_takes_ownership")) return ST.set_index_takes_ownership;
    // Memory historically took ownership; default false for other backends.
    return false;
}

// ---------------------------------------------------------------------------
// Individual suite tests (go-git Test* methods) — `s` is *BaseStorageSuite(T)
// ---------------------------------------------------------------------------

pub fn testSetEncodedObjectAndEncodedObject(s: anytype) !void {
    for (test_object_meta) |meta| {
        const obj = try s.newTypedObject(meta.typ);
        const h = try s.storer.setEncodedObject(obj);
        var buf: [plumbing.HexSize]u8 = undefined;
        try testing.expectEqualStrings(meta.hash_hex, hexOf(h, &buf));

        const o = try s.storer.encodedObject(meta.typ, h);
        try objectEquals(o, obj);

        const o_any = try s.storer.encodedObject(.any, h);
        try objectEquals(o_any, obj);

        for (valid_types) |t| {
            if (t == meta.typ) continue;
            try testing.expectError(error.ObjectNotFound, s.storer.encodedObject(t, h));
        }
    }
}

pub fn testSetEncodedObjectInvalid(s: anytype) !void {
    const o = try s.storer.newEncodedObject();
    o.setType(.ref_delta);
    // go-git asserts err != nil (memory: UnsupportedObjectType; filesystem: InvalidType).
    const result = s.storer.setEncodedObject(o);
    if (comptime isErrorUnion(@TypeOf(result))) {
        if (result) |_| return error.TestUnexpectedResult else |_| {}
    } else {
        return error.TestUnexpectedResult;
    }
}

pub fn testIterEncodedObjects(s: anytype) !void {
    var stored: [4]*MemoryObject = undefined;
    for (test_object_meta, 0..) |meta, i| {
        const obj = try s.newTypedObject(meta.typ);
        const h = try s.storer.setEncodedObject(obj);
        try testing.expect(h.eql(obj.hash()));
        stored[i] = obj;
    }

    for (valid_types) |t| {
        var iter = try s.storer.iterEncodedObjects(t);
        defer iter.deinit();

        const o = try iter.next();
        const expected = metaFor(t);
        try testing.expect(o.object_type == expected.typ);
        try objectEquals(o, stored[indexOfType(expected.typ)]);

        try testing.expectError(error.EndOfStream, iter.next());
    }

    var any_iter = try s.storer.iterEncodedObjects(.any);
    defer any_iter.deinit();

    var found: usize = 0;
    var hashes: [4]Hash = undefined;
    while (any_iter.next()) |o| {
        if (found >= hashes.len) return error.TestExpectedEqual;
        hashes[found] = o.hash();
        found += 1;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try testing.expectEqual(@as(usize, 4), found);

    for (test_object_meta) |meta| {
        var ok = false;
        const want = plumbing.newHash(meta.hash_hex);
        for (hashes[0..found]) |h| {
            if (h.eql(want)) {
                ok = true;
                break;
            }
        }
        try testing.expect(ok);
    }
}

fn indexOfType(t: ObjectType) usize {
    for (test_object_meta, 0..) |m, i| {
        if (m.typ == t) return i;
    }
    unreachable;
}

/// go-git `TestPackfileWriter` — type-assert skip when no PackfileWriter.
///
/// go-git writes fixtures.Basic().One() pack and counts 31 objects via
/// IterEncodedObjects. Pack-aware iteration is not in this suite slice;
/// filesystem root tests cover multi-object packfileWriter + Encoder.
/// Here: open PackWriter and close empty (valid unused-pack path).
pub fn testPackfileWriter(s: anytype) !void {
    if (!s.supports_packfile_writer) return;
    const ST = @TypeOf(s.storer.*);
    if (!@hasDecl(ST, "packfileWriter")) return;
    const Ret = @typeInfo(@TypeOf(ST.packfileWriter)).@"fn".return_type.?;
    const payload = if (comptime isErrorUnion(Ret))
        @typeInfo(Ret).error_union.payload
    else
        Ret;
    if (comptime payload == void) {
        // Method present (capability true) but no write handle yet.
        return;
    }
    // Smoke: open PackWriter and close with no bytes written.
    var pw = try s.storer.packfileWriter();
    if (comptime @hasDecl(@TypeOf(pw), "close")) {
        try pw.close();
    } else if (comptime @hasDecl(@TypeOf(pw), "abandon")) {
        pw.abandon();
    }
}

pub fn testObjectStorerTxSetEncodedObjectAndCommit(s: anytype) !void {
    // go-git: type-assert Transactioner; skip when unsupported.
    // Comptime `begin` gate so filesystem Storage (no Transactioner) type-checks.
    if (!s.supports_transactioner) return;
    const ST = @TypeOf(s.storer.*);
    if (comptime !@hasDecl(ST, "begin")) return;
    var tx = s.storer.begin();
    defer tx.deinit();

    for (test_object_meta) |meta| {
        const obj = try s.newTypedObject(meta.typ);
        const h = try tx.setEncodedObject(obj);
        var buf: [plumbing.HexSize]u8 = undefined;
        try testing.expectEqualStrings(meta.hash_hex, hexOf(h, &buf));
    }

    {
        var iter = try s.storer.iterEncodedObjects(.any);
        defer iter.deinit();
        try testing.expectError(error.EndOfStream, iter.next());
    }

    try tx.commit();

    var iter = try s.storer.iterEncodedObjects(.any);
    defer iter.deinit();
    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try testing.expectEqual(@as(usize, 4), count);
}

pub fn testObjectStorerTxSetObjectAndGetObject(s: anytype) !void {
    if (!s.supports_transactioner) return;
    const ST = @TypeOf(s.storer.*);
    if (comptime !@hasDecl(ST, "begin")) return;
    var tx = s.storer.begin();
    defer tx.deinit();

    for (test_object_meta) |meta| {
        const obj = try s.newTypedObject(meta.typ);
        const h = try tx.setEncodedObject(obj);
        var buf: [plumbing.HexSize]u8 = undefined;
        try testing.expectEqualStrings(meta.hash_hex, hexOf(h, &buf));

        const o = try tx.encodedObject(meta.typ, plumbing.newHash(meta.hash_hex));
        try testing.expectEqualStrings(meta.hash_hex, hexOf(o.hash(), &buf));
    }
}

pub fn testObjectStorerTxGetObjectNotFound(s: anytype) !void {
    if (!s.supports_transactioner) return;
    const ST = @TypeOf(s.storer.*);
    if (comptime !@hasDecl(ST, "begin")) return;
    var tx = s.storer.begin();
    defer tx.deinit();
    try testing.expectError(
        error.ObjectNotFound,
        tx.encodedObject(.any, plumbing.ZeroHash),
    );
}

pub fn testObjectStorerTxSetObjectAndRollback(s: anytype) !void {
    if (!s.supports_transactioner) return;
    const ST = @TypeOf(s.storer.*);
    if (comptime !@hasDecl(ST, "begin")) return;
    var tx = s.storer.begin();
    defer tx.deinit();

    for (test_object_meta) |meta| {
        const obj = try s.newTypedObject(meta.typ);
        const h = try tx.setEncodedObject(obj);
        var buf: [plumbing.HexSize]u8 = undefined;
        try testing.expectEqualStrings(meta.hash_hex, hexOf(h, &buf));
    }

    tx.rollback();

    var iter = try s.storer.iterEncodedObjects(.any);
    defer iter.deinit();
    try testing.expectError(error.EndOfStream, iter.next());
}

pub fn testSetReferenceAndGetReference(s: anytype) !void {
    try s.storer.setReference(Reference.fromStrings(
        "refs/foo",
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
    ));
    try s.storer.setReference(Reference.fromStrings(
        "refs/bar",
        "482e0eada5de4039e6f216b45b3c9b683b83bfa",
    ));

    const e = try s.storer.reference(ReferenceName.init("refs/foo"));
    defer releaseRef(s, e);
    var buf: [plumbing.HexSize]u8 = undefined;
    try testing.expectEqualStrings(
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
        hexOf(e.hash, &buf),
    );
}

pub fn testCheckAndSetReference(s: anytype) !void {
    try s.storer.setReference(Reference.fromStrings(
        "refs/foo",
        "482e0eada5de4039e6f216b45b3c9b683b83bfa",
    ));
    try s.storer.checkAndSetReference(
        Reference.fromStrings("refs/foo", "bc9968d75e48de59f0870ffb71f5e160bbbdcf52"),
        Reference.fromStrings("refs/foo", "482e0eada5de4039e6f216b45b3c9b683b83bfa"),
    );
    const e = try s.storer.reference(ReferenceName.init("refs/foo"));
    defer releaseRef(s, e);
    var buf: [plumbing.HexSize]u8 = undefined;
    try testing.expectEqualStrings(
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
        hexOf(e.hash, &buf),
    );
}

pub fn testCheckAndSetReferenceNil(s: anytype) !void {
    try s.storer.setReference(Reference.fromStrings(
        "refs/foo",
        "482e0eada5de4039e6f216b45b3c9b683b83bfa",
    ));
    try s.storer.checkAndSetReference(
        Reference.fromStrings("refs/foo", "bc9968d75e48de59f0870ffb71f5e160bbbdcf52"),
        null,
    );
    const e = try s.storer.reference(ReferenceName.init("refs/foo"));
    defer releaseRef(s, e);
    var buf: [plumbing.HexSize]u8 = undefined;
    try testing.expectEqualStrings(
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
        hexOf(e.hash, &buf),
    );
}

pub fn testCheckAndSetReferenceError(s: anytype) !void {
    try s.storer.setReference(Reference.fromStrings(
        "refs/foo",
        "c3f4688a08fd86f1bf8e055724c84b7a40a09733",
    ));
    try testing.expectError(
        error.ReferenceHasChanged,
        s.storer.checkAndSetReference(
            Reference.fromStrings("refs/foo", "bc9968d75e48de59f0870ffb71f5e160bbbdcf52"),
            Reference.fromStrings("refs/foo", "482e0eada5de4039e6f216b45b3c9b683b83bfa"),
        ),
    );
    const e = try s.storer.reference(ReferenceName.init("refs/foo"));
    defer releaseRef(s, e);
    var buf: [plumbing.HexSize]u8 = undefined;
    try testing.expectEqualStrings(
        "c3f4688a08fd86f1bf8e055724c84b7a40a09733",
        hexOf(e.hash, &buf),
    );
}

pub fn testRemoveReference(s: anytype) !void {
    try s.storer.setReference(Reference.fromStrings(
        "refs/foo",
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
    ));
    try callMaybeError(s.storer.removeReference(ReferenceName.init("refs/foo")));
    try testing.expectError(
        error.ReferenceNotFound,
        s.storer.reference(ReferenceName.init("refs/foo")),
    );
}

pub fn testRemoveReferenceNonExistent(s: anytype) !void {
    try s.storer.setReference(Reference.fromStrings(
        "refs/foo",
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
    ));
    try callMaybeError(s.storer.removeReference(ReferenceName.init("refs/nonexistent")));
    const e = try s.storer.reference(ReferenceName.init("refs/foo"));
    defer releaseRef(s, e);
    var buf: [plumbing.HexSize]u8 = undefined;
    try testing.expectEqualStrings(
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
        hexOf(e.hash, &buf),
    );
}

pub fn testGetReferenceNotFound(s: anytype) !void {
    try testing.expectError(
        error.ReferenceNotFound,
        s.storer.reference(ReferenceName.init("refs/bar")),
    );
}

pub fn testIterReferences(s: anytype) !void {
    try s.storer.setReference(Reference.fromStrings(
        "refs/foo",
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
    ));
    var i = try s.storer.iterReferences();
    defer i.deinit();
    const e = try i.next();
    var buf: [plumbing.HexSize]u8 = undefined;
    try testing.expectEqualStrings(
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
        hexOf(e.hash, &buf),
    );
    try testing.expectError(error.EndOfStream, i.next());
}

pub fn testSetShallowAndShallow(s: anytype) !void {
    const expected = [_]Hash{
        plumbing.newHash("b66c08ba28aa1f81eb06a1127aa3936ff77e5e2c"),
        plumbing.newHash("c3f4688a08fd86f1bf8e055724c84b7a40a09733"),
        plumbing.newHash("c78874f116be67ecf54df225a613162b84cc6ebf"),
    };
    try s.storer.setShallow(&expected);
    const result = try callShallow(s.storer);
    try testing.expectEqual(@as(usize, expected.len), result.len);
    for (expected, result) |e, r| {
        try testing.expect(e.eql(r));
    }
}

pub fn testSetConfigAndConfig(s: anytype) !void {
    const cfg = try s.allocator.create(Config);
    cfg.* = Config.init(s.allocator);
    cfg.is_bare = true;
    try cfg.putRemote("foo", &[_][]const u8{"http://foo/bar.git"});

    try s.storer.setConfig(cfg);

    const got = try s.storer.config();
    try testing.expect(got.is_bare);
    const remote = got.remotes.get("foo") orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("foo", remote.name);
    try testing.expectEqual(@as(usize, 1), remote.urls.len);
    try testing.expectEqualStrings("http://foo/bar.git", remote.urls[0]);
}

pub fn testIndex(s: anytype) !void {
    const idx = try s.storer.index();
    try testing.expectEqual(@as(u32, 2), idx.version);
    try testing.expect(idx.mod_time.isZero());
}

pub fn testSetIndexAndIndex(s: anytype) !void {
    const ST = @TypeOf(s.storer.*);
    const fresh = try s.allocator.create(Index);
    fresh.* = Index.init(s.allocator);
    fresh.version = 2;
    const takes_own = comptime setIndexTakesOwnership(ST);
    if (!takes_own) {
        defer {
            fresh.deinit();
            s.allocator.destroy(fresh);
        }
        try callMaybeError(s.storer.setIndex(fresh));
        const idx = try s.storer.index();
        try testing.expectEqual(@as(u32, 2), idx.version);
        try testing.expect(!idx.mod_time.isZero());
    } else {
        try callMaybeError(s.storer.setIndex(fresh));
        const idx = try s.storer.index();
        try testing.expectEqual(@as(u32, 2), idx.version);
        try testing.expect(!idx.mod_time.isZero());
    }
}

pub fn testSetConfigInvalid(s: anytype) !void {
    const cfg = try s.allocator.create(Config);
    cfg.* = Config.init(s.allocator);
    // Empty remote (no name, no urls) under key "foo".
    const key = try s.allocator.dupe(u8, "foo");
    try cfg.remotes.put(s.allocator, key, .{});

    // setConfig fails validation; suite still owns cfg.
    // go-git returns ErrInvalid when map key != remote.Name (before empty-name check).
    defer {
        cfg.deinit();
        s.allocator.destroy(cfg);
    }
    try testing.expectError(error.Invalid, s.storer.setConfig(cfg));
}

pub fn testModule(s: anytype) !void {
    const m1 = try s.storer.module("foo");
    try testing.expect(@intFromPtr(m1) != 0);
    const m2 = try s.storer.module("foo");
    try testing.expect(m1 == m2);
}

/// go-git `TestDeltaObjectStorer` — needs DeltaObjectStorer (+ PackfileWriter
/// for the full basic.pack OFS-delta body).
///
/// Suite-safe slice: loose objects via `deltaObject` (same as encodedObject for
/// non-deltas). OFS-delta pack path is covered in filesystem root tests.
pub fn testDeltaObjectStorer(s: anytype) !void {
    if (!s.supports_delta_object_storer) return;
    const ST = @TypeOf(s.storer.*);
    if (comptime !@hasDecl(ST, "deltaObject")) return;

    // Loose path: deltaObject returns the stored blob unchanged.
    const obj = try s.newTypedObject(.blob);
    const h = try s.storer.setEncodedObject(obj);
    const got = try s.storer.deltaObject(.blob, h);
    try objectEquals(got, obj);
    try testing.expect(got.object_type == .blob);
    try testing.expect(!got.isDeltaObject());

    // Type filter: wrong type → ObjectNotFound.
    try testing.expectError(error.ObjectNotFound, s.storer.deltaObject(.commit, h));

    // any type matches.
    const any = try s.storer.deltaObject(.any, h);
    try testing.expect(any.hash().eql(h));
}

// ---------------------------------------------------------------------------
// Runner: each test gets a fresh Storage (go-git SetUpTest)
// ---------------------------------------------------------------------------

/// All go-git BaseStorageSuite case names (23).
pub const Case = enum {
    set_encoded_object_and_encoded_object,
    set_encoded_object_invalid,
    iter_encoded_objects,
    packfile_writer,
    object_storer_tx_set_encoded_object_and_commit,
    object_storer_tx_set_object_and_get_object,
    object_storer_tx_get_object_not_found,
    object_storer_tx_set_object_and_rollback,
    set_reference_and_get_reference,
    check_and_set_reference,
    check_and_set_reference_nil,
    check_and_set_reference_error,
    remove_reference,
    remove_reference_non_existent,
    get_reference_not_found,
    iter_references,
    set_shallow_and_shallow,
    set_config_and_config,
    index,
    set_index_and_index,
    set_config_invalid,
    module,
    delta_object_storer,

    pub fn name(self: Case) []const u8 {
        return switch (self) {
            .set_encoded_object_and_encoded_object => "TestSetEncodedObjectAndEncodedObject",
            .set_encoded_object_invalid => "TestSetEncodedObjectInvalid",
            .iter_encoded_objects => "TestIterEncodedObjects",
            .packfile_writer => "TestPackfileWriter",
            .object_storer_tx_set_encoded_object_and_commit => "TestObjectStorerTxSetEncodedObjectAndCommit",
            .object_storer_tx_set_object_and_get_object => "TestObjectStorerTxSetObjectAndGetObject",
            .object_storer_tx_get_object_not_found => "TestObjectStorerTxGetObjectNotFound",
            .object_storer_tx_set_object_and_rollback => "TestObjectStorerTxSetObjectAndRollback",
            .set_reference_and_get_reference => "TestSetReferenceAndGetReference",
            .check_and_set_reference => "TestCheckAndSetReference",
            .check_and_set_reference_nil => "TestCheckAndSetReferenceNil",
            .check_and_set_reference_error => "TestCheckAndSetReferenceError",
            .remove_reference => "TestRemoveReference",
            .remove_reference_non_existent => "TestRemoveReferenceNonExistent",
            .get_reference_not_found => "TestGetReferenceNotFound",
            .iter_references => "TestIterReferences",
            .set_shallow_and_shallow => "TestSetShallowAndShallow",
            .set_config_and_config => "TestSetConfigAndConfig",
            .index => "TestIndex",
            .set_index_and_index => "TestSetIndexAndIndex",
            .set_config_invalid => "TestSetConfigInvalid",
            .module => "TestModule",
            .delta_object_storer => "TestDeltaObjectStorer",
        };
    }
};

/// Ordered suite cases matching go-git BaseStorageSuite (23).
pub const suite_cases = [_]Case{
    .set_encoded_object_and_encoded_object,
    .set_encoded_object_invalid,
    .iter_encoded_objects,
    .packfile_writer,
    .object_storer_tx_set_encoded_object_and_commit,
    .object_storer_tx_set_object_and_get_object,
    .object_storer_tx_get_object_not_found,
    .object_storer_tx_set_object_and_rollback,
    .set_reference_and_get_reference,
    .check_and_set_reference,
    .check_and_set_reference_nil,
    .check_and_set_reference_error,
    .remove_reference,
    .remove_reference_non_existent,
    .get_reference_not_found,
    .iter_references,
    .set_shallow_and_shallow,
    .set_config_and_config,
    .index,
    .set_index_and_index,
    .set_config_invalid,
    .module,
    .delta_object_storer,
};

/// Dispatch one suite case against fixture `s` (`*BaseStorageSuite(T)`).
pub fn runCase(s: anytype, case: Case) !void {
    switch (case) {
        .set_encoded_object_and_encoded_object => try testSetEncodedObjectAndEncodedObject(s),
        .set_encoded_object_invalid => try testSetEncodedObjectInvalid(s),
        .iter_encoded_objects => try testIterEncodedObjects(s),
        .packfile_writer => try testPackfileWriter(s),
        .object_storer_tx_set_encoded_object_and_commit => try testObjectStorerTxSetEncodedObjectAndCommit(s),
        .object_storer_tx_set_object_and_get_object => try testObjectStorerTxSetObjectAndGetObject(s),
        .object_storer_tx_get_object_not_found => try testObjectStorerTxGetObjectNotFound(s),
        .object_storer_tx_set_object_and_rollback => try testObjectStorerTxSetObjectAndRollback(s),
        .set_reference_and_get_reference => try testSetReferenceAndGetReference(s),
        .check_and_set_reference => try testCheckAndSetReference(s),
        .check_and_set_reference_nil => try testCheckAndSetReferenceNil(s),
        .check_and_set_reference_error => try testCheckAndSetReferenceError(s),
        .remove_reference => try testRemoveReference(s),
        .remove_reference_non_existent => try testRemoveReferenceNonExistent(s),
        .get_reference_not_found => try testGetReferenceNotFound(s),
        .iter_references => try testIterReferences(s),
        .set_shallow_and_shallow => try testSetShallowAndShallow(s),
        .set_config_and_config => try testSetConfigAndConfig(s),
        .index => try testIndex(s),
        .set_index_and_index => try testSetIndexAndIndex(s),
        .set_config_invalid => try testSetConfigInvalid(s),
        .module => try testModule(s),
        .delta_object_storer => try testDeltaObjectStorer(s),
    }
}

/// Run every BaseStorageSuite test with a per-case factory.
///
/// `Factory` must provide:
/// ```
/// pub fn create(allocator: Allocator) anyerror!*StorageT
/// pub fn destroy(allocator: Allocator, storer: *StorageT) void
/// ```
/// and `Factory.Storage` (or infer from create return).
pub fn runAllWithFactory(allocator: Allocator, comptime Factory: type) !void {
    const StorageT = blk: {
        if (@hasDecl(Factory, "Storage")) break :blk Factory.Storage;
        const CreateFn = @TypeOf(Factory.create);
        const info = @typeInfo(CreateFn).@"fn";
        const Ret = info.return_type.?;
        const ret_info = @typeInfo(Ret).error_union;
        break :blk @typeInfo(ret_info.payload).pointer.child;
    };

    for (suite_cases) |tc| {
        const storer = try Factory.create(allocator);
        defer Factory.destroy(allocator, storer);
        var suite = BaseStorageSuite(StorageT).init(allocator, storer);
        runCase(&suite, tc) catch |err| {
            std.debug.print("FAIL {s}: {}\n", .{ tc.name(), err });
            return err;
        };
    }
}

/// Memory backend factory for BaseStorageSuite.
pub const MemoryFactory = struct {
    pub const Storage = memory.Storage;

    pub fn create(allocator: Allocator) Allocator.Error!*memory.Storage {
        return try memory.newStorage(allocator);
    }

    pub fn destroy(allocator: Allocator, storer: *memory.Storage) void {
        storer.deinit();
        allocator.destroy(storer);
    }
};

/// Run every BaseStorageSuite test against a fresh memory storage.
pub fn runAll(allocator: Allocator) !void {
    try runAllWithFactory(allocator, MemoryFactory);
}

/// Alias used by filesystem / other backends.
pub const runAllMemory = runAll;

test "BaseStorageSuite (memory)" {
    try runAll(testing.allocator);
}

test "suite case count" {
    // All 23 go-git BaseStorageSuite methods (including capability-gated members).
    try testing.expectEqual(@as(usize, 23), suite_cases.len);
}
