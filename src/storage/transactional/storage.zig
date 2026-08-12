//! Composite transactional Storage (go-git `storage/transactional` basic).
//!
//! Demuxes reads from `base` and writes to `temporal`. `commit` merges
//! temporal content into base for objects, refs, index, shallow, and config.
//!
//! PackfileWriter: go-git type-asserts temporal; when temporal implements
//! PackfileWriter, transactional Storage does too and writes go to temporal.
//! Memory temporal does not implement PackfileWriter (`implements_packfile_writer = false`).
//!
//! Does not own `base` or `temporal` (caller lifetime). `deinit` only frees
//! demux state (reference deleted map, nested module wrappers).

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");

const object_mod = @import("object.zig");
const reference_mod = @import("reference.zig");
const index_mod = @import("index.zig");
const shallow_mod = @import("shallow.zig");
const config_mod = @import("config.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ObjectType = plumbing.ObjectType;
const MemoryObject = plumbing.MemoryObject;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;

pub const ObjectStorage = object_mod.ObjectStorage;
pub const MultiObjectIter = object_mod.MultiObjectIter;
pub const newObjectStorage = object_mod.newObjectStorage;
pub const ReferenceStorage = reference_mod.ReferenceStorage;
pub const MultiReferenceIter = reference_mod.MultiReferenceIter;
pub const newReferenceStorage = reference_mod.newReferenceStorage;
pub const IndexStorage = index_mod.IndexStorage;
pub const newIndexStorage = index_mod.newIndexStorage;
pub const ShallowStorage = shallow_mod.ShallowStorage;
pub const newShallowStorage = shallow_mod.newShallowStorage;
pub const ConfigStorage = config_mod.ConfigStorage;
pub const newConfigStorage = config_mod.newConfigStorage;

/// go-git `transactional.Storage` over two memory storers.
pub const Storage = struct {
    allocator: Allocator,
    base: *memory.Storage,
    temporal: *memory.Storage,

    object_storage: ObjectStorage,
    reference_storage: ReferenceStorage,
    index_storage: IndexStorage,
    shallow_storage: ShallowStorage,
    config_storage: ConfigStorage,

    /// Nested transactional wrappers keyed by module name (one wrapper per name).
    modules: std.StringHashMapUnmanaged(*Storage) = .empty,

    /// go-git: PackfileWriter iff temporal supports it (memory: false).
    pub const implements_packfile_writer = memory.Storage.implements_packfile_writer;
    pub const set_encoded_object_takes_ownership = true;
    pub const new_encoded_object_storage_owned = false;

    /// go-git `NewStorage(base, temporal)`.
    ///
    /// Allocator is taken from `base.allocator` for demux maps / nested wrappers.
    pub fn init(base: *memory.Storage, temporal: *memory.Storage) Storage {
        return .{
            .allocator = base.allocator,
            .base = base,
            .temporal = temporal,
            .object_storage = newObjectStorage(base, temporal),
            .reference_storage = newReferenceStorage(base, temporal),
            .index_storage = newIndexStorage(base, temporal),
            .shallow_storage = newShallowStorage(base, temporal),
            .config_storage = newConfigStorage(base, temporal),
        };
    }

    pub fn deinit(self: *Storage) void {
        var it = self.modules.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            self.allocator.destroy(e.value_ptr.*);
            self.allocator.free(e.key_ptr.*);
        }
        self.modules.deinit(self.allocator);
        self.reference_storage.deinit();
        self.* = undefined;
    }

    // --- EncodedObjectStorer ---

    pub fn newEncodedObject(self: *Storage) Allocator.Error!*MemoryObject {
        return self.object_storage.newEncodedObject();
    }

    pub fn discardEncodedObject(self: *Storage, obj: *MemoryObject) void {
        self.object_storage.discardEncodedObject(obj);
    }

    pub fn setEncodedObject(self: *Storage, obj: *MemoryObject) (Allocator.Error || memory.ObjectError)!Hash {
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

    pub fn iterEncodedObjects(self: *const Storage, t: ObjectType) Allocator.Error!MultiObjectIter {
        return self.object_storage.iterEncodedObjects(t);
    }

    pub fn addAlternate(self: *Storage, remote: []const u8) memory.ObjectError!void {
        return self.object_storage.addAlternate(remote);
    }

    /// go-git `PackfileWriter` demux — writes go to temporal when temporal supports it.
    ///
    /// go-git `NewStorage` type-asserts temporal as `storer.PackfileWriter` and, if
    /// present, returns a wrapper whose `PackfileWriter()` delegates to temporal.
    /// Memory temporal does not implement PackfileWriter (`implements_packfile_writer`
    /// is false), so this is a compile-time dead path that returns `NotSupported`.
    /// Callers must check `implements_packfile_writer` before calling.
    pub fn packfileWriter(self: *Storage) memory.ObjectError!void {
        _ = self;
        // Memory storer has no PackfileWriter; keep a single intentional NotSupported
        // (not a stub for an unknown host error). When temporal gains the capability,
        // flip `implements_packfile_writer` and forward to `self.temporal.packfileWriter()`.
        return error.NotSupported;
    }

    // --- ReferenceStorer ---

    pub fn setReference(self: *Storage, ref: Reference) Allocator.Error!void {
        return self.reference_storage.setReference(ref);
    }

    pub fn checkAndSetReference(
        self: *Storage,
        ref: ?Reference,
        old: ?Reference,
    ) (Allocator.Error || error{ReferenceHasChanged} || plumbing.Error)!void {
        return try self.reference_storage.checkAndSetReference(ref, old);
    }

    pub fn reference(self: *const Storage, n: ReferenceName) plumbing.Error!Reference {
        return self.reference_storage.reference(n);
    }

    pub fn iterReferences(self: *const Storage) Allocator.Error!MultiReferenceIter {
        return self.reference_storage.iterReferences();
    }

    pub fn removeReference(self: *Storage, n: ReferenceName) Allocator.Error!void {
        return self.reference_storage.removeReference(n);
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

    pub fn setIndex(self: *Storage, idx: *memory.Index) void {
        self.index_storage.setIndex(idx);
    }

    pub fn index(self: *Storage) Allocator.Error!*memory.Index {
        return self.index_storage.index();
    }

    // --- ConfigStorer ---

    pub fn setConfig(self: *Storage, cfg: *memory.Config) (Allocator.Error || memory.ConfigError)!void {
        return self.config_storage.setConfig(cfg);
    }

    pub fn config(self: *Storage) Allocator.Error!*memory.Config {
        return self.config_storage.config();
    }

    // --- ModuleStorer ---

    /// go-git `Module` — nested transactional storage over base/temporal modules.
    /// Same name returns the same wrapper (cached like base `ModuleStorage`).
    pub fn module(self: *Storage, name: []const u8) Allocator.Error!*Storage {
        if (self.modules.get(name)) |m| return m;

        const base_m = try self.base.module(name);
        const temporal_m = try self.temporal.module(name);
        const child = try self.allocator.create(Storage);
        errdefer self.allocator.destroy(child);
        child.* = Storage.init(base_m, temporal_m);
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        try self.modules.put(self.allocator, key, child);
        return child;
    }

    /// go-git `Commit` — merge all sub-storers temporal → base.
    pub fn commit(self: *Storage) (Allocator.Error || memory.ObjectError || memory.ConfigError)!void {
        try self.object_storage.commit();
        try self.reference_storage.commit();
        try self.index_storage.commit();
        try self.shallow_storage.commit();
        try self.config_storage.commit();
    }
};

/// go-git `NewStorage` — stack/value form; free demux state with `deinit`.
pub fn newStorage(base: *memory.Storage, temporal: *memory.Storage) Storage {
    return Storage.init(base, temporal);
}

/// Package-level alias of `Storage.implements_packfile_writer` (temporal demux).
pub const implements_packfile_writer = Storage.implements_packfile_writer;

// ---------------------------------------------------------------------------
// Tests (go-git storage_test.go subset + assignment cases)
// ---------------------------------------------------------------------------

test "Storage Commit objects and refs" {
    const allocator = std.testing.allocator;
    const base = try memory.newStorage(allocator);
    defer {
        base.deinit();
        allocator.destroy(base);
    }
    const temporal = try memory.newStorage(allocator);
    defer {
        temporal.deinit();
        allocator.destroy(temporal);
    }

    var st = newStorage(base, temporal);
    defer st.deinit();

    const commit_obj = try st.newEncodedObject();
    commit_obj.setType(.commit);
    const h = try st.setEncodedObject(commit_obj);

    try std.testing.expectError(error.ObjectNotFound, base.hasEncodedObject(h));

    const ref = plumbing.Reference.newHashReference(
        ReferenceName.init("refs/a"),
        h,
    );
    try st.setReference(ref);

    try st.commit();

    const base_ref = try base.reference(ref.name);
    try std.testing.expect(base_ref.hash.eql(h));
    const base_obj = try base.encodedObject(.any, h);
    try std.testing.expect(base_obj.hash().eql(h));
}

test "Storage Commit objects refs config index shallow" {
    // Full merge of all sub-storers (extends go-git TestCommit).
    const allocator = std.testing.allocator;
    const base = try memory.newStorage(allocator);
    defer {
        base.deinit();
        allocator.destroy(base);
    }
    const temporal = try memory.newStorage(allocator);
    defer {
        temporal.deinit();
        allocator.destroy(temporal);
    }

    // Seed base with distinct values so post-commit can detect overwrite.
    {
        const cfg0 = try allocator.create(memory.Config);
        cfg0.* = memory.Config.init(allocator);
        cfg0.is_bare = false;
        try base.setConfig(cfg0);

        const idx0 = try allocator.create(memory.Index);
        idx0.* = memory.Index.init(allocator);
        idx0.version = 2;
        base.setIndex(idx0);

        const commit_a = plumbing.newHash("bc9968d75e48de59f0870ffb71f5e160bbbdcf52");
        try base.setShallow(&[_]Hash{commit_a});
    }

    var st = newStorage(base, temporal);
    defer st.deinit();

    // Object + ref
    const commit_obj = try st.newEncodedObject();
    commit_obj.setType(.commit);
    _ = try commit_obj.write("tx-full-commit");
    const h = try st.setEncodedObject(commit_obj);
    try std.testing.expectError(error.ObjectNotFound, base.hasEncodedObject(h));

    const ref = plumbing.Reference.newHashReference(
        ReferenceName.init("refs/heads/tx"),
        h,
    );
    try st.setReference(ref);

    // Config
    const cfg_tmp = try allocator.create(memory.Config);
    cfg_tmp.* = memory.Config.init(allocator);
    cfg_tmp.is_bare = true;
    try st.setConfig(cfg_tmp);

    // Index
    const idx_tmp = try allocator.create(memory.Index);
    idx_tmp.* = memory.Index.init(allocator);
    idx_tmp.version = 3;
    st.setIndex(idx_tmp);

    // Shallow
    const commit_b = plumbing.newHash("aa9968d75e48de59f0870ffb71f5e160bbbdcf52");
    try st.setShallow(&[_]Hash{commit_b});

    // Before commit: base still has old config/index/shallow; object/ref absent.
    try std.testing.expect(!(try base.config()).is_bare);
    try std.testing.expectEqual(@as(u32, 2), (try base.index()).version);
    try std.testing.expect(base.shallow()[0].eql(
        plumbing.newHash("bc9968d75e48de59f0870ffb71f5e160bbbdcf52"),
    ));

    try st.commit();

    // Objects + refs
    try base.hasEncodedObject(h);
    const base_ref = try base.reference(ref.name);
    try std.testing.expect(base_ref.hash.eql(h));

    // Config
    try std.testing.expect((try base.config()).is_bare);

    // Index
    try std.testing.expectEqual(@as(u32, 3), (try base.index()).version);

    // Shallow
    const base_shallow = base.shallow();
    try std.testing.expectEqual(@as(usize, 1), base_shallow.len);
    try std.testing.expect(base_shallow[0].eql(commit_b));
}

test "PackfileWriter capability matches temporal" {
    // go-git TestTransactionalPackfileWriter
    try std.testing.expectEqual(
        memory.Storage.implements_packfile_writer,
        Storage.implements_packfile_writer,
    );
    try std.testing.expectEqual(
        memory.Storage.implements_packfile_writer,
        implements_packfile_writer,
    );

    const allocator = std.testing.allocator;
    const base = try memory.newStorage(allocator);
    defer {
        base.deinit();
        allocator.destroy(base);
    }
    const temporal = try memory.newStorage(allocator);
    defer {
        temporal.deinit();
        allocator.destroy(temporal);
    }
    var st = newStorage(base, temporal);
    defer st.deinit();

    if (!implements_packfile_writer) {
        try std.testing.expectError(error.NotSupported, st.packfileWriter());
    }
}

test "sub-storer free constructors" {
    const allocator = std.testing.allocator;
    const base = try memory.newStorage(allocator);
    defer {
        base.deinit();
        allocator.destroy(base);
    }
    const temporal = try memory.newStorage(allocator);
    defer {
        temporal.deinit();
        allocator.destroy(temporal);
    }

    const os = newObjectStorage(base, temporal);
    try std.testing.expect(os.base == base);

    var rs = newReferenceStorage(base, temporal);
    defer rs.deinit();
    try std.testing.expect(rs.base == base);

    const is = newIndexStorage(base, temporal);
    try std.testing.expect(is.base == base);

    const ss = newShallowStorage(base, temporal);
    try std.testing.expect(ss.base == base);

    const cs = newConfigStorage(base, temporal);
    try std.testing.expect(cs.base == base);
}

test "Storage module nested transactional" {
    const allocator = std.testing.allocator;
    const base = try memory.newStorage(allocator);
    defer {
        base.deinit();
        allocator.destroy(base);
    }
    const temporal = try memory.newStorage(allocator);
    defer {
        temporal.deinit();
        allocator.destroy(temporal);
    }

    var st = newStorage(base, temporal);
    defer st.deinit();

    const m = try st.module("sub");
    const m2 = try st.module("sub");
    try std.testing.expect(m == m2);

    const obj = try m.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write("nested-tx");
    const h = try m.setEncodedObject(obj);

    try std.testing.expectError(error.ObjectNotFound, base.hasEncodedObject(h));
    try m.hasEncodedObject(h);
    try m.commit();

    const base_mod = try base.module("sub");
    try base_mod.hasEncodedObject(h);
}
