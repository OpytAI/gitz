//! BaseStorageSuite — port of go-git `storage/test/storage_suite.go`.
//!
//! Parameterized over memory `Storage`. Capability flags mirror go-git
//! type-assert + `c.Skip` (read from `Storage.implements_*`):
//! - PackfileWriter / DeltaObjectStorer — false on memory
//! - Transactioner — true on memory (`begin`); Tx tests always run
//!
//! Capability-gated tests stay suite members and early-return when unsupported.
//! Config checks use the minimal memory Config (is_bare + remotes name/urls).

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ObjectType = plumbing.ObjectType;
const MemoryObject = plumbing.MemoryObject;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const Storage = memory.Storage;
const Config = memory.Config;

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
pub const BaseStorageSuite = struct {
    allocator: Allocator,
    storer: *Storage,

    /// go-git type-assert `storer.PackfileWriter`. Memory: false.
    supports_packfile_writer: bool = false,
    /// go-git type-assert `storer.DeltaObjectStorer`. Memory: false.
    supports_delta_object_storer: bool = false,

    /// go-git `NewBaseStorageSuite` for memory storage.
    pub fn init(allocator: Allocator, storer: *Storage) BaseStorageSuite {
        return .{
            .allocator = allocator,
            .storer = storer,
            .supports_packfile_writer = Storage.implements_packfile_writer,
            .supports_delta_object_storer = Storage.implements_delta_object_storer,
        };
    }

    fn newTypedObject(self: *BaseStorageSuite, t: ObjectType) !*MemoryObject {
        const o = try self.storer.newEncodedObject();
        o.setType(t);
        return o;
    }
};

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

// ---------------------------------------------------------------------------
// Individual suite tests (go-git Test* methods)
// ---------------------------------------------------------------------------

pub fn testSetEncodedObjectAndEncodedObject(s: *BaseStorageSuite) !void {
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

pub fn testSetEncodedObjectInvalid(s: *BaseStorageSuite) !void {
    const o = try s.storer.newEncodedObject();
    o.setType(.ref_delta);
    // Stored in Objects map then rejected (go-git); storer owns the pointer.
    try testing.expectError(error.UnsupportedObjectType, s.storer.setEncodedObject(o));
}

pub fn testIterEncodedObjects(s: *BaseStorageSuite) !void {
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
/// Full body lands with filesystem storage (phase 6): write basic.pack (31 objs).
pub fn testPackfileWriter(s: *BaseStorageSuite) !void {
    if (!s.supports_packfile_writer) return;
    // Backend claimed PackfileWriter but suite path not wired yet.
    return error.PackfileWriterPathNotWired;
}

pub fn testObjectStorerTxSetEncodedObjectAndCommit(s: *BaseStorageSuite) !void {
    // go-git: type-assert Transactioner; memory implements Begin — always run.
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
    }
    try testing.expectEqual(@as(usize, 4), count);
}

pub fn testObjectStorerTxSetObjectAndGetObject(s: *BaseStorageSuite) !void {
    // go-git: type-assert Transactioner; memory implements Begin — always run.
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

pub fn testObjectStorerTxGetObjectNotFound(s: *BaseStorageSuite) !void {
    // go-git: type-assert Transactioner; memory implements Begin — always run.
    var tx = s.storer.begin();
    defer tx.deinit();
    try testing.expectError(
        error.ObjectNotFound,
        tx.encodedObject(.any, plumbing.ZeroHash),
    );
}

pub fn testObjectStorerTxSetObjectAndRollback(s: *BaseStorageSuite) !void {
    // go-git: type-assert Transactioner; memory implements Begin — always run.
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

pub fn testSetReferenceAndGetReference(s: *BaseStorageSuite) !void {
    try s.storer.setReference(Reference.fromStrings(
        "refs/foo",
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
    ));
    try s.storer.setReference(Reference.fromStrings(
        "refs/bar",
        "482e0eada5de4039e6f216b45b3c9b683b83bfa",
    ));

    const e = try s.storer.reference(ReferenceName.init("refs/foo"));
    var buf: [plumbing.HexSize]u8 = undefined;
    try testing.expectEqualStrings(
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
        hexOf(e.hash, &buf),
    );
}

pub fn testCheckAndSetReference(s: *BaseStorageSuite) !void {
    try s.storer.setReference(Reference.fromStrings(
        "refs/foo",
        "482e0eada5de4039e6f216b45b3c9b683b83bfa",
    ));
    try s.storer.checkAndSetReference(
        Reference.fromStrings("refs/foo", "bc9968d75e48de59f0870ffb71f5e160bbbdcf52"),
        Reference.fromStrings("refs/foo", "482e0eada5de4039e6f216b45b3c9b683b83bfa"),
    );
    const e = try s.storer.reference(ReferenceName.init("refs/foo"));
    var buf: [plumbing.HexSize]u8 = undefined;
    try testing.expectEqualStrings(
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
        hexOf(e.hash, &buf),
    );
}

pub fn testCheckAndSetReferenceNil(s: *BaseStorageSuite) !void {
    try s.storer.setReference(Reference.fromStrings(
        "refs/foo",
        "482e0eada5de4039e6f216b45b3c9b683b83bfa",
    ));
    try s.storer.checkAndSetReference(
        Reference.fromStrings("refs/foo", "bc9968d75e48de59f0870ffb71f5e160bbbdcf52"),
        null,
    );
    const e = try s.storer.reference(ReferenceName.init("refs/foo"));
    var buf: [plumbing.HexSize]u8 = undefined;
    try testing.expectEqualStrings(
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
        hexOf(e.hash, &buf),
    );
}

pub fn testCheckAndSetReferenceError(s: *BaseStorageSuite) !void {
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
    var buf: [plumbing.HexSize]u8 = undefined;
    try testing.expectEqualStrings(
        "c3f4688a08fd86f1bf8e055724c84b7a40a09733",
        hexOf(e.hash, &buf),
    );
}

pub fn testRemoveReference(s: *BaseStorageSuite) !void {
    try s.storer.setReference(Reference.fromStrings(
        "refs/foo",
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
    ));
    s.storer.removeReference(ReferenceName.init("refs/foo"));
    try testing.expectError(
        error.ReferenceNotFound,
        s.storer.reference(ReferenceName.init("refs/foo")),
    );
}

pub fn testRemoveReferenceNonExistent(s: *BaseStorageSuite) !void {
    try s.storer.setReference(Reference.fromStrings(
        "refs/foo",
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
    ));
    s.storer.removeReference(ReferenceName.init("refs/nonexistent"));
    const e = try s.storer.reference(ReferenceName.init("refs/foo"));
    var buf: [plumbing.HexSize]u8 = undefined;
    try testing.expectEqualStrings(
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
        hexOf(e.hash, &buf),
    );
}

pub fn testGetReferenceNotFound(s: *BaseStorageSuite) !void {
    try testing.expectError(
        error.ReferenceNotFound,
        s.storer.reference(ReferenceName.init("refs/bar")),
    );
}

pub fn testIterReferences(s: *BaseStorageSuite) !void {
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

pub fn testSetShallowAndShallow(s: *BaseStorageSuite) !void {
    const expected = [_]Hash{
        plumbing.newHash("b66c08ba28aa1f81eb06a1127aa3936ff77e5e2c"),
        plumbing.newHash("c3f4688a08fd86f1bf8e055724c84b7a40a09733"),
        plumbing.newHash("c78874f116be67ecf54df225a613162b84cc6ebf"),
    };
    try s.storer.setShallow(&expected);
    const result = s.storer.shallow();
    try testing.expectEqual(@as(usize, expected.len), result.len);
    for (expected, result) |e, r| {
        try testing.expect(e.eql(r));
    }
}

pub fn testSetConfigAndConfig(s: *BaseStorageSuite) !void {
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

pub fn testIndex(s: *BaseStorageSuite) !void {
    const idx = try s.storer.index();
    try testing.expectEqual(@as(u32, 2), idx.version);
    try testing.expect(idx.mod_time.isZero());
}

pub fn testSetIndexAndIndex(s: *BaseStorageSuite) !void {
    const fresh = try s.allocator.create(memory.Index);
    fresh.* = memory.Index.init(s.allocator);
    fresh.version = 2;
    s.storer.setIndex(fresh);
    const idx = try s.storer.index();
    try testing.expectEqual(@as(u32, 2), idx.version);
    try testing.expect(!idx.mod_time.isZero());
}

pub fn testSetConfigInvalid(s: *BaseStorageSuite) !void {
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

pub fn testModule(s: *BaseStorageSuite) !void {
    const m1 = try s.storer.module("foo");
    try testing.expect(@intFromPtr(m1) != 0);
    const m2 = try s.storer.module("foo");
    try testing.expect(m1 == m2);
}

/// go-git `TestDeltaObjectStorer` — needs DeltaObjectStorer + PackfileWriter.
/// Full body lands with filesystem storage (phase 6).
pub fn testDeltaObjectStorer(s: *BaseStorageSuite) !void {
    if (!s.supports_delta_object_storer) return;
    if (!s.supports_packfile_writer) return;
    return error.DeltaObjectStorerPathNotWired;
}

// ---------------------------------------------------------------------------
// Runner: each test gets a fresh Storage (go-git SetUpTest)
// ---------------------------------------------------------------------------

const SuiteCase = struct {
    name: []const u8,
    func: *const fn (*BaseStorageSuite) anyerror!void,
};

/// All go-git BaseStorageSuite tests (23). Capability-gated tests early-return
/// for memory when flags are false; they are still suite members.
const suite_cases = [_]SuiteCase{
    .{ .name = "TestSetEncodedObjectAndEncodedObject", .func = testSetEncodedObjectAndEncodedObject },
    .{ .name = "TestSetEncodedObjectInvalid", .func = testSetEncodedObjectInvalid },
    .{ .name = "TestIterEncodedObjects", .func = testIterEncodedObjects },
    .{ .name = "TestPackfileWriter", .func = testPackfileWriter },
    .{ .name = "TestObjectStorerTxSetEncodedObjectAndCommit", .func = testObjectStorerTxSetEncodedObjectAndCommit },
    .{ .name = "TestObjectStorerTxSetObjectAndGetObject", .func = testObjectStorerTxSetObjectAndGetObject },
    .{ .name = "TestObjectStorerTxGetObjectNotFound", .func = testObjectStorerTxGetObjectNotFound },
    .{ .name = "TestObjectStorerTxSetObjectAndRollback", .func = testObjectStorerTxSetObjectAndRollback },
    .{ .name = "TestSetReferenceAndGetReference", .func = testSetReferenceAndGetReference },
    .{ .name = "TestCheckAndSetReference", .func = testCheckAndSetReference },
    .{ .name = "TestCheckAndSetReferenceNil", .func = testCheckAndSetReferenceNil },
    .{ .name = "TestCheckAndSetReferenceError", .func = testCheckAndSetReferenceError },
    .{ .name = "TestRemoveReference", .func = testRemoveReference },
    .{ .name = "TestRemoveReferenceNonExistent", .func = testRemoveReferenceNonExistent },
    .{ .name = "TestGetReferenceNotFound", .func = testGetReferenceNotFound },
    .{ .name = "TestIterReferences", .func = testIterReferences },
    .{ .name = "TestSetShallowAndShallow", .func = testSetShallowAndShallow },
    .{ .name = "TestSetConfigAndConfig", .func = testSetConfigAndConfig },
    .{ .name = "TestIndex", .func = testIndex },
    .{ .name = "TestSetIndexAndIndex", .func = testSetIndexAndIndex },
    .{ .name = "TestSetConfigInvalid", .func = testSetConfigInvalid },
    .{ .name = "TestModule", .func = testModule },
    .{ .name = "TestDeltaObjectStorer", .func = testDeltaObjectStorer },
};

/// Run every BaseStorageSuite test against a fresh memory storage.
pub fn runAll(allocator: Allocator) !void {
    for (suite_cases) |tc| {
        const storer = try memory.newStorage(allocator);
        defer {
            storer.deinit();
            allocator.destroy(storer);
        }
        var suite = BaseStorageSuite.init(allocator, storer);
        tc.func(&suite) catch |err| {
            std.debug.print("FAIL {s}: {}\n", .{ tc.name, err });
            return err;
        };
    }
}

test "BaseStorageSuite (memory)" {
    try runAll(testing.allocator);
}

test "suite case count" {
    // All 23 go-git BaseStorageSuite methods (including capability-gated members).
    try testing.expectEqual(@as(usize, 23), suite_cases.len);
}
