//! Composite memory `Storage` (go-git `storage/memory.Storage`).
//!
//! Capability flags match go-git type-assert behavior:
//! - `implements_transactioner` = true (`begin` → `TxObjectStorage`)
//! - `implements_packfile_writer` = false (no PackfileWriter)
//! - `implements_delta_object_storer` = false (no DeltaObjectStorer)
//! Do not fake PackfileWriter or DeltaObjectStorer.

const std = @import("std");
const plumbing = @import("plumbing");

const object_mod = @import("object.zig");
const reference_mod = @import("reference.zig");
const config_mod = @import("config.zig");
const index_mod = @import("index.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ObjectType = plumbing.ObjectType;
const MemoryObject = plumbing.MemoryObject;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;

pub const ObjectStorage = object_mod.ObjectStorage;
pub const TxObjectStorage = object_mod.TxObjectStorage;
pub const ObjectSnapshotIter = object_mod.ObjectSnapshotIter;
/// Alias kept for older call sites; prefer `ObjectSnapshotIter`.
pub const EncodedObjectSliceIter = object_mod.ObjectSnapshotIter;
pub const ReferenceStorage = reference_mod.ReferenceStorage;
pub const ReferenceSliceIter = reference_mod.ReferenceSliceIter;
pub const ConfigStorage = config_mod.ConfigStorage;
pub const Config = config_mod.Config;
pub const RemoteConfig = config_mod.RemoteConfig;
pub const IndexStorage = index_mod.IndexStorage;
pub const Index = index_mod.Index;

pub const ObjectError = object_mod.Error;
pub const ConfigError = config_mod.Error;

/// go-git memory implements `storer.Transactioner` via `Begin`.
pub const implements_transactioner = true;
/// go-git memory does **not** implement `storer.PackfileWriter`.
pub const implements_packfile_writer = false;
/// go-git memory does **not** implement `storer.DeltaObjectStorer`.
pub const implements_delta_object_storer = false;

/// Shallow commit list (go-git `ShallowStorage`).
pub const ShallowStorage = struct {
    allocator: Allocator,
    commits: []Hash = &.{},

    pub fn init(allocator: Allocator) ShallowStorage {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ShallowStorage) void {
        if (self.commits.len > 0) self.allocator.free(self.commits);
        self.commits = &.{};
    }

    /// go-git `SetShallow` — replaces the shallow list (copies hashes).
    /// On allocation failure the previous list is left intact.
    pub fn setShallow(self: *ShallowStorage, commits: []const Hash) Allocator.Error!void {
        const copy = try self.allocator.dupe(Hash, commits);
        if (self.commits.len > 0) self.allocator.free(self.commits);
        self.commits = copy;
    }

    /// go-git `Shallow`.
    pub fn shallow(self: *const ShallowStorage) []const Hash {
        return self.commits;
    }
};

/// Module map name → nested Storage (go-git `ModuleStorage`).
pub const ModuleStorage = struct {
    allocator: Allocator,
    modules: std.StringHashMapUnmanaged(*Storage) = .empty,

    pub fn init(allocator: Allocator) ModuleStorage {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ModuleStorage) void {
        var it = self.modules.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            self.allocator.destroy(e.value_ptr.*);
            self.allocator.free(e.key_ptr.*);
        }
        self.modules.deinit(self.allocator);
        self.* = undefined;
    }

    /// go-git `Module` — existing or new empty memory storage.
    pub fn module(self: *ModuleStorage, name: []const u8) Allocator.Error!*Storage {
        if (self.modules.get(name)) |m| return m;

        const m = try newStorage(self.allocator);
        errdefer {
            m.deinit();
            self.allocator.destroy(m);
        }
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        try self.modules.put(self.allocator, key, m);
        return m;
    }
};

/// Ephemeral in-memory repository storage (go-git `memory.Storage`).
pub const Storage = struct {
    allocator: Allocator,
    config_storage: ConfigStorage,
    object_storage: ObjectStorage,
    shallow_storage: ShallowStorage,
    index_storage: IndexStorage,
    reference_storage: ReferenceStorage,
    module_storage: ModuleStorage,

    /// Same capability flags as package-level constants (per-type discovery).
    pub const implements_transactioner = true;
    pub const implements_packfile_writer = false;
    pub const implements_delta_object_storer = false;

    /// Initialize embedded storages (stack or heap). Prefer `newStorage` for heap.
    pub fn init(allocator: Allocator) Storage {
        return .{
            .allocator = allocator,
            .config_storage = ConfigStorage.init(allocator),
            .object_storage = ObjectStorage.init(allocator),
            .shallow_storage = ShallowStorage.init(allocator),
            .index_storage = IndexStorage.init(),
            .reference_storage = ReferenceStorage.init(allocator),
            .module_storage = ModuleStorage.init(allocator),
        };
    }

    pub fn deinit(self: *Storage) void {
        self.module_storage.deinit();
        self.reference_storage.deinit();
        self.index_storage.deinit();
        self.shallow_storage.deinit();
        self.object_storage.deinit();
        self.config_storage.deinit();
        self.* = undefined;
    }

    // --- EncodedObjectStorer ---

    pub fn newEncodedObject(self: *Storage) Allocator.Error!*MemoryObject {
        return self.object_storage.newEncodedObject();
    }

    pub fn setEncodedObject(self: *Storage, obj: *MemoryObject) (Allocator.Error || ObjectError)!Hash {
        return self.object_storage.setEncodedObject(obj);
    }

    pub fn hasEncodedObject(self: *const Storage, h: Hash) error{ObjectNotFound}!void {
        return self.object_storage.hasEncodedObject(h);
    }

    pub fn encodedObjectSize(self: *const Storage, h: Hash) error{ObjectNotFound}!i64 {
        return self.object_storage.encodedObjectSize(h);
    }

    pub fn encodedObject(self: *const Storage, t: ObjectType, h: Hash) error{ObjectNotFound}!*MemoryObject {
        return self.object_storage.encodedObject(t, h);
    }

    pub fn iterEncodedObjects(self: *const Storage, t: ObjectType) Allocator.Error!ObjectSnapshotIter {
        return self.object_storage.iterEncodedObjects(t);
    }

    /// go-git `Transactioner.Begin` → `TxObjectStorage`.
    pub fn begin(self: *Storage) TxObjectStorage {
        return self.object_storage.begin();
    }

    pub fn forEachObjectHash(self: *const Storage, fun: anytype) anyerror!void {
        return self.object_storage.forEachObjectHash(fun);
    }

    pub fn objectPacks(self: *const Storage) []const Hash {
        return self.object_storage.objectPacks();
    }

    pub fn deleteOldObjectPackAndIndex(self: *Storage, h: Hash, t: i64) void {
        self.object_storage.deleteOldObjectPackAndIndex(h, t);
    }

    pub fn looseObjectTime(self: *const Storage, h: Hash) ObjectError!i64 {
        return self.object_storage.looseObjectTime(h);
    }

    pub fn deleteLooseObject(self: *Storage, h: Hash) ObjectError!void {
        return self.object_storage.deleteLooseObject(h);
    }

    pub fn addAlternate(self: *Storage, remote: []const u8) ObjectError!void {
        return self.object_storage.addAlternate(remote);
    }

    // --- ReferenceStorer ---

    pub fn setReference(self: *Storage, ref: Reference) Allocator.Error!void {
        return self.reference_storage.setReference(ref);
    }

    pub fn checkAndSetReference(
        self: *Storage,
        ref: ?Reference,
        old: ?Reference,
    ) (Allocator.Error || error{ReferenceHasChanged})!void {
        return self.reference_storage.checkAndSetReference(ref, old);
    }

    pub fn reference(self: *const Storage, n: ReferenceName) plumbing.Error!Reference {
        return self.reference_storage.reference(n);
    }

    pub fn iterReferences(self: *const Storage) Allocator.Error!ReferenceSliceIter {
        return self.reference_storage.iterReferences();
    }

    pub fn removeReference(self: *Storage, n: ReferenceName) void {
        self.reference_storage.removeReference(n);
    }

    pub fn countLooseRefs(self: *const Storage) usize {
        return self.reference_storage.countLooseRefs();
    }

    pub fn packRefs(self: *Storage) void {
        self.reference_storage.packRefs();
    }

    // --- ShallowStorer ---

    pub fn setShallow(self: *Storage, commits: []const Hash) Allocator.Error!void {
        return self.shallow_storage.setShallow(commits);
    }

    pub fn shallow(self: *const Storage) []const Hash {
        return self.shallow_storage.shallow();
    }

    // --- IndexStorer ---

    pub fn setIndex(self: *Storage, idx: Index) void {
        self.index_storage.setIndex(idx);
    }

    /// go-git `Index` — returns default empty index when unset.
    pub fn index(self: *Storage) *Index {
        return self.index_storage.index();
    }

    // --- ConfigStorer ---

    pub fn setConfig(self: *Storage, cfg: *Config) (Allocator.Error || ConfigError)!void {
        return self.config_storage.setConfig(cfg);
    }

    /// go-git `Config` — returns stored config or a default empty config.
    pub fn config(self: *Storage) Allocator.Error!*Config {
        return self.config_storage.config();
    }

    // --- ModuleStorer ---

    pub fn module(self: *Storage, name: []const u8) Allocator.Error!*Storage {
        return self.module_storage.module(name);
    }
};

/// go-git `NewStorage` — heap-allocated storage; free with `deinit` + `destroy`.
pub fn newStorage(allocator: Allocator) Allocator.Error!*Storage {
    const s = try allocator.create(Storage);
    s.* = Storage.init(allocator);
    return s;
}

// ---------------------------------------------------------------------------
// Tests (composite surface + edge cases)
// ---------------------------------------------------------------------------

test "capability flags match go-git memory" {
    try std.testing.expect(implements_transactioner);
    try std.testing.expect(!implements_packfile_writer);
    try std.testing.expect(!implements_delta_object_storer);
    try std.testing.expect(Storage.implements_transactioner);
    try std.testing.expect(!Storage.implements_packfile_writer);
    try std.testing.expect(!Storage.implements_delta_object_storer);
}

test "Storage shallow set replace and empty" {
    const allocator = std.testing.allocator;
    var s = Storage.init(allocator);
    defer s.deinit();

    const a = [_]Hash{plumbing.newHash("b66c08ba28aa1f81eb06a1127aa3936ff77e5e2c")};
    try s.setShallow(&a);
    try std.testing.expectEqual(@as(usize, 1), s.shallow().len);

    try s.setShallow(&.{});
    try std.testing.expectEqual(@as(usize, 0), s.shallow().len);
}

test "Storage module nested independent and same name reuses" {
    const allocator = std.testing.allocator;
    const s = try newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const m1 = try s.module("sub");
    const m2 = try s.module("sub");
    try std.testing.expect(m1 == m2);

    const m3 = try s.module("other");
    try std.testing.expect(m3 != m1);

    // Nested storage is a full Storage (can hold objects independently).
    const obj = try m1.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write("nested");
    const h = try m1.setEncodedObject(obj);
    try m1.hasEncodedObject(h);
    try std.testing.expectError(error.ObjectNotFound, s.hasEncodedObject(h));
}

test "Storage index and config go-git method names" {
    const allocator = std.testing.allocator;
    var s = Storage.init(allocator);
    defer s.deinit();

    const idx = s.index();
    try std.testing.expectEqual(@as(u32, 2), idx.version);
    try std.testing.expect(idx.modTimeIsZero());

    s.setIndex(.{ .version = 2 });
    try std.testing.expect(!s.index().modTimeIsZero());

    const cfg = try s.config();
    try std.testing.expect(!cfg.is_bare);
}

test "Storage pack and loose no-ops" {
    const allocator = std.testing.allocator;
    var s = Storage.init(allocator);
    defer s.deinit();

    try std.testing.expectEqual(@as(usize, 0), s.objectPacks().len);
    s.deleteOldObjectPackAndIndex(plumbing.ZeroHash, 0);
    try std.testing.expectError(error.NotSupported, s.looseObjectTime(plumbing.ZeroHash));
    try std.testing.expectError(error.NotSupported, s.deleteLooseObject(plumbing.ZeroHash));
    try std.testing.expectError(error.NotSupported, s.addAlternate("/tmp/x"));
}

test "Storage begin transaction commit path" {
    const allocator = std.testing.allocator;
    var s = Storage.init(allocator);
    defer s.deinit();

    var tx = s.begin();
    defer tx.deinit();

    const obj = try s.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write("tx");
    const h = try tx.setEncodedObject(obj);
    try tx.commit();
    try s.hasEncodedObject(h);
}
