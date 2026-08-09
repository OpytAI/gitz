//! Composite filesystem `Storage` (go-git `storage/filesystem.Storage`).
//!
//! Monomorphised over billy-style `Fs` (`Mem` / `Os`):
//! - `Storage(Mem)` / `StorageMem` — hermetic suite tests (default)
//! - `Storage(Os)` / `StorageOs` — on-disk via `std.Io`
//!
//! Capability flags match go-git:
//! - PackfileWriter: true (`DotGit.newObjectPack` → sequential PackWriter)
//! - DeltaObjectStorer: true
//! - Transactioner: false

const std = @import("std");
const plumbing = @import("plumbing");
const cache_pkg = @import("cache");
const fs_pkg = @import("fs");
const memory = @import("memory");

const dotgit = @import("dotgit");
const object_mod = @import("object.zig");
const reference_mod = @import("reference.zig");
const index_mod = @import("index.zig");
const config_mod = @import("config.zig");
const shallow_mod = @import("shallow.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ObjectType = plumbing.ObjectType;
const MemoryObject = plumbing.MemoryObject;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const Algorithm = plumbing.Algorithm;
const ObjectLru = cache_pkg.ObjectLru;
const Mem = fs_pkg.Mem;
const Os = fs_pkg.Os;

/// go-git `filesystem.Options`, specialised to the backend filesystem type.
/// `alternates_fs` may point outside the primary backend's chroot.
pub fn OptionsFor(comptime Fs: type) type {
    return struct {
        exclusive_access: bool = false,
        keep_descriptors: bool = false,
        max_open_descriptors: i32 = 0,
        large_object_threshold: i64 = 0,
        alternates_fs: ?*Fs = null,
        /// Repository time authority. Callers that need deterministic or
        /// freestanding behavior supply a fixed or injected clock.
        clock: memory.Clock = memory.Clock.systemClock(),
    };
}

/// Default Mem options, retained for existing callers.
pub const Options = OptionsFor(Mem);
pub const OptionsOs = OptionsFor(Os);

pub const implements_transactioner = false;
pub const implements_packfile_writer = true;
pub const implements_delta_object_storer = true;

/// go-git `filesystem.Storage` monomorphised over billy-style `Fs`.
pub fn Storage(comptime Fs: type) type {
    const DotGit = dotgit.DotGitFor(Fs);
    const ObjectStorageT = object_mod.ObjectStorageFor(Fs);
    const ReferenceStorageT = reference_mod.ReferenceStorage(Fs);
    const IndexStorageT = index_mod.IndexStorage(Fs);
    const ShallowStorageT = shallow_mod.ShallowStorage(Fs);
    const ConfigStorageT = config_mod.ConfigStorage(Fs);
    const ObjectHashIterT = ObjectStorageT.ObjectHashIter;
    const PackWriterT = dotgit.PackWriterFor(Fs);

    return struct {
        const Self = @This();

        allocator: Allocator,
        fs: *Fs,
        dir: *DotGit,
        /// Owned ObjectLRU when `owns_cache` is true; otherwise unused.
        cache_storage: ObjectLru = undefined,
        /// External cache pointer when caller supplied one (not owned).
        external_cache: ?*ObjectLru = null,
        owns_cache: bool = true,

        object_storage: ObjectStorageT,
        reference_storage: ReferenceStorageT,
        index_storage: IndexStorageT,
        shallow_storage: ShallowStorageT,
        config_storage: ConfigStorageT,
        module_storage: Self.ModuleStorage,
        /// Per-repo object hash algorithm (SHA-1 / SHA-256).
        hash_algo: Algorithm = .sha1,
        clock: memory.Clock,

        pub const implements_transactioner = false;
        pub const implements_packfile_writer = true;
        pub const implements_delta_object_storer = true;
        /// go-git filesystem `SetIndex` does not take ownership of the argument.
        pub const set_index_takes_ownership = false;
        pub const set_index_can_fail = true;
        /// `reference()` returns owned name/target strings (free with freeRef pattern).
        pub const reference_returns_owned = true;

        pub const ObjectHashIter = ObjectHashIterT;
        pub const ReferenceIter = reference_mod.ReferenceSliceIter;
        pub const LazyWriter = ObjectStorageT.LazyWriter;
        pub const Index = index_mod.Index;
        pub const Config = config_mod.Config;

        /// Nested module map (go-git `ModuleStorage`) — lives here to avoid
        /// import / monomorphisation cycles with the composite Storage type.
        pub const ModuleStorage = struct {
            allocator: Allocator,
            dir: *DotGit,
            clock: memory.Clock,
            modules: std.StringHashMapUnmanaged(*Self) = .empty,
            chroots: std.ArrayListUnmanaged(*Fs) = .empty,

            pub fn init(allocator: Allocator, dir: *DotGit, clock: memory.Clock) Self.ModuleStorage {
                return .{ .allocator = allocator, .dir = dir, .clock = clock };
            }

            pub fn deinit(self: *Self.ModuleStorage) void {
                var it = self.modules.iterator();
                while (it.next()) |e| {
                    e.value_ptr.*.deinit();
                    self.allocator.destroy(e.value_ptr.*);
                    self.allocator.free(e.key_ptr.*);
                }
                self.modules.deinit(self.allocator);
                for (self.chroots.items) |m| {
                    m.deinit();
                    self.allocator.destroy(m);
                }
                self.chroots.deinit(self.allocator);
                self.* = undefined;
            }

            pub fn module(self: *Self.ModuleStorage, name: []const u8) (Allocator.Error || fs_pkg.Error || dotgit.Error)!*Self {
                if (self.modules.get(name)) |m| return m;

                const chrooted = try self.dir.module(name);
                const fs_ptr = try self.allocator.create(Fs);
                errdefer self.allocator.destroy(fs_ptr);
                fs_ptr.* = chrooted;
                try self.chroots.append(self.allocator, fs_ptr);

                const nested = try newStorageWithOptionsFor(Fs, self.allocator, fs_ptr, null, .{
                    .clock = self.clock,
                });
                errdefer {
                    nested.deinit();
                    self.allocator.destroy(nested);
                }
                const key = try self.allocator.dupe(u8, name);
                errdefer self.allocator.free(key);
                try self.modules.put(self.allocator, key, nested);
                return nested;
            }
        };

        pub fn deinit(self: *Self) void {
            self.module_storage.deinit();
            self.config_storage.deinit();
            self.shallow_storage.deinit();
            self.index_storage.deinit();
            self.reference_storage.deinit();
            self.object_storage.deinit();
            if (self.owns_cache) self.cache_storage.deinit();
            self.dir.deinit();
            self.allocator.destroy(self.dir);
            self.* = undefined;
        }

        /// go-git `Filesystem`.
        pub fn filesystem(self: *const Self) *Fs {
            return self.fs;
        }

        /// go-git `Init` — create .git scaffolding.
        pub fn initLayout(self: *Self) (Allocator.Error || fs_pkg.Error)!void {
            try self.dir.initialize();
        }

        /// go-git `AddAlternate`.
        pub fn addAlternate(self: *Self, remote: []const u8) (Allocator.Error || fs_pkg.Error || dotgit.Error)!void {
            try self.dir.addAlternate(remote);
        }

        pub fn hashAlgo(self: *const Self) Algorithm {
            return self.hash_algo;
        }

        pub fn now(self: *const Self) memory.Time {
            return self.clock.now();
        }

        pub fn setHashAlgo(self: *Self, algo: Algorithm) void {
            self.hash_algo = algo;
            self.activateFormat();
        }

        /// Publish this storage's format for process-wide wire codecs.
        pub fn activateFormat(self: *const Self) void {
            plumbing.setObjectFormat(self.hash_algo);
        }

        // --- EncodedObjectStorer ---

        pub fn newEncodedObject(self: *Self) Allocator.Error!*MemoryObject {
            const obj = try self.object_storage.newEncodedObject();
            obj.hash_algo = self.hash_algo;
            return obj;
        }

        pub fn setEncodedObject(self: *Self, obj: *MemoryObject) object_mod.Error!Hash {
            return self.object_storage.setEncodedObject(obj);
        }

        pub fn hasEncodedObject(self: *Self, h: Hash) object_mod.Error!void {
            return self.object_storage.hasEncodedObject(h);
        }

        pub fn encodedObjectSize(self: *Self, h: Hash) object_mod.Error!i64 {
            return self.object_storage.encodedObjectSize(h);
        }

        pub fn encodedObject(self: *Self, t: ObjectType, h: Hash) object_mod.Error!*MemoryObject {
            return self.object_storage.encodedObject(t, h);
        }

        pub fn deltaObject(self: *Self, t: ObjectType, h: Hash) object_mod.Error!*MemoryObject {
            return self.object_storage.deltaObject(t, h);
        }

        pub fn iterEncodedObjects(self: *Self, t: ObjectType) object_mod.Error!ObjectHashIterT {
            return self.object_storage.iterEncodedObjects(t);
        }

        pub fn packfileWriter(self: *Self) object_mod.Error!PackWriterT {
            return self.object_storage.packfileWriter();
        }

        pub fn looseObjectTime(self: *Self, h: Hash) object_mod.Error!i64 {
            return self.object_storage.looseObjectTime(h);
        }

        pub fn deleteLooseObject(self: *Self, h: Hash) object_mod.Error!void {
            return self.object_storage.deleteLooseObject(h);
        }

        pub fn hashesWithPrefix(self: *Self, prefix: []const u8) object_mod.Error![]Hash {
            return self.object_storage.hashesWithPrefix(prefix);
        }

        pub fn deleteOldObjectPackAndIndex(self: *Self, h: Hash, t: i64) object_mod.Error!void {
            return self.object_storage.deleteOldObjectPackAndIndex(h, t);
        }

        pub fn objectPacks(self: *Self) (Allocator.Error || fs_pkg.Error)![]Hash {
            return self.object_storage.objectPacks();
        }

        pub fn reindex(self: *Self) void {
            self.object_storage.reindex();
        }

        /// go-git `LazyWriter` — deferred header+content loose write.
        pub fn lazyWriter(self: *Self) object_mod.Error!LazyWriter {
            return self.object_storage.lazyWriter();
        }

        /// Context-aware `ForEachObjectHash` (see ObjectStorage.forEachObjectHash).
        pub fn forEachObjectHash(
            self: *Self,
            ctx: anytype,
            comptime fun: *const fn (@TypeOf(ctx), Hash) anyerror!void,
        ) anyerror!void {
            return self.object_storage.forEachObjectHash(ctx, fun);
        }

        /// go-git `Close` — release cached pack images / DotGit descriptors.
        pub fn close(self: *Self) void {
            self.object_storage.close();
        }

        // --- ReferenceStorer ---

        pub fn setReference(self: *Self, ref: Reference) reference_mod.Error!void {
            return self.reference_storage.setReference(ref);
        }

        pub fn checkAndSetReference(
            self: *Self,
            ref: ?Reference,
            old: ?Reference,
        ) reference_mod.Error!void {
            return self.reference_storage.checkAndSetReference(ref, old);
        }

        pub fn reference(self: *Self, n: ReferenceName) reference_mod.Error!Reference {
            return self.reference_storage.reference(n);
        }

        /// Release an owned reference returned by `reference`.
        pub fn freeReference(self: *const Self, ref: Reference) void {
            dotgit.freeRef(self.allocator, ref);
        }

        pub fn iterReferences(self: *Self) reference_mod.Error!reference_mod.ReferenceSliceIter {
            return self.reference_storage.iterReferences();
        }

        pub fn removeReference(self: *Self, n: ReferenceName) reference_mod.Error!void {
            return self.reference_storage.removeReference(n);
        }

        pub fn countLooseRefs(self: *Self) reference_mod.Error!usize {
            return self.reference_storage.countLooseRefs();
        }

        pub fn packRefs(self: *Self) reference_mod.Error!void {
            return self.reference_storage.packRefs();
        }

        pub fn prepareReferenceUpdates(
            self: *Self,
            updates: []const memory.ReferenceUpdate,
        ) !reference_mod.PreparedReferenceUpdates {
            return self.reference_storage.prepareUpdates(updates);
        }

        pub fn commitPreparedReferenceUpdates(
            self: *Self,
            updates: []const memory.ReferenceUpdate,
            prepared: *reference_mod.PreparedReferenceUpdates,
        ) !void {
            return self.reference_storage.commitPrepared(updates, prepared);
        }

        // --- ShallowStorer ---

        pub fn setShallow(self: *Self, commits: []const Hash) shallow_mod.Error!void {
            return self.shallow_storage.setShallow(commits);
        }

        pub fn shallow(self: *Self) shallow_mod.Error![]const Hash {
            return self.shallow_storage.shallow();
        }

        // --- IndexStorer ---

        pub fn setIndex(self: *Self, idx: *index_mod.Index) index_mod.Error!void {
            return self.index_storage.setIndex(idx);
        }

        /// Worktree write-back variant. It consumes a newly built index while
        /// preserving an index pointer already cached by this storage.
        pub fn setIndexOwned(self: *Self, idx: *index_mod.Index) index_mod.Error!void {
            const was_cached = self.index_storage.cached == idx;
            try self.index_storage.setIndex(idx);
            if (!was_cached) {
                idx.deinit();
                self.allocator.destroy(idx);
            }
        }

        pub fn index(self: *Self) index_mod.Error!*index_mod.Index {
            return self.index_storage.index();
        }

        // --- ConfigStorer ---

        pub fn setConfig(self: *Self, cfg: *config_mod.Config) config_mod.Error!void {
            return self.config_storage.setConfig(cfg);
        }

        pub fn config(self: *Self) config_mod.Error!*config_mod.Config {
            return self.config_storage.config();
        }

        // --- ModuleStorer ---

        pub fn module(self: *Self, name: []const u8) (Allocator.Error || fs_pkg.Error || dotgit.Error)!*Self {
            return self.module_storage.module(name);
        }
    };
}

/// Nested ModuleStorage for a given `Fs` (alias of `Storage(Fs).ModuleStorage`).
pub fn ModuleStorageFor(comptime Fs: type) type {
    return Storage(Fs).ModuleStorage;
}

/// Mem specialisation (default, all existing call sites).
pub const StorageMem = Storage(Mem);
/// Os specialisation (on-disk via `std.Io`).
pub const StorageOs = Storage(Os);
/// Mem module storage.
pub const ModuleStorageMem = ModuleStorageFor(Mem);
/// Os module storage.
pub const ModuleStorageOs = ModuleStorageFor(Os);

/// go-git `NewStorage` over Mem — heap Storage with optional external object cache.
/// When `object_cache` is null, a default ObjectLRU is owned by Storage.
pub fn newStorage(
    allocator: Allocator,
    mem_fs: *Mem,
    object_cache: ?*ObjectLru,
) Allocator.Error!*StorageMem {
    return newStorageWithOptions(allocator, mem_fs, object_cache, .{});
}

/// go-git `NewStorageWithOptions` over Mem.
pub fn newStorageWithOptions(
    allocator: Allocator,
    mem_fs: *Mem,
    object_cache: ?*ObjectLru,
    ops: Options,
) Allocator.Error!*StorageMem {
    return newStorageWithOptionsFor(Mem, allocator, mem_fs, object_cache, ops);
}

/// Heap `StorageOs` with optional external object cache.
pub fn newStorageOs(
    allocator: Allocator,
    os_fs: *Os,
    object_cache: ?*ObjectLru,
) Allocator.Error!*StorageOs {
    return newStorageOsWithOptions(allocator, os_fs, object_cache, .{});
}

/// Heap `StorageOs` with options.
pub fn newStorageOsWithOptions(
    allocator: Allocator,
    os_fs: *Os,
    object_cache: ?*ObjectLru,
    ops: OptionsFor(Os),
) Allocator.Error!*StorageOs {
    return newStorageWithOptionsFor(Os, allocator, os_fs, object_cache, ops);
}

/// Generic constructor for any billy-style `Fs`.
pub fn newStorageFor(
    comptime Fs: type,
    allocator: Allocator,
    backend: *Fs,
    object_cache: ?*ObjectLru,
) Allocator.Error!*Storage(Fs) {
    return newStorageWithOptionsFor(Fs, allocator, backend, object_cache, .{});
}

/// Generic constructor with options for any billy-style `Fs`.
pub fn newStorageWithOptionsFor(
    comptime Fs: type,
    allocator: Allocator,
    backend: *Fs,
    object_cache: ?*ObjectLru,
    ops: OptionsFor(Fs),
) Allocator.Error!*Storage(Fs) {
    const DotGit = dotgit.DotGitFor(Fs);
    const StorageT = Storage(Fs);
    const ObjectStorageT = object_mod.ObjectStorageFor(Fs);
    const ReferenceStorageT = reference_mod.ReferenceStorage(Fs);
    const IndexStorageT = index_mod.IndexStorage(Fs);
    const ShallowStorageT = shallow_mod.ShallowStorage(Fs);
    const ConfigStorageT = config_mod.ConfigStorage(Fs);

    const dir = try allocator.create(DotGit);
    dir.* = DotGit.init(allocator, backend, .{
        .exclusive_access = ops.exclusive_access,
        .keep_descriptors = ops.keep_descriptors,
        .alternates_fs = ops.alternates_fs,
    });
    errdefer {
        dir.deinit();
        allocator.destroy(dir);
    }

    const s = try allocator.create(StorageT);
    errdefer allocator.destroy(s);

    const owns_cache = object_cache == null;
    s.* = .{
        .allocator = allocator,
        .fs = backend,
        .dir = dir,
        .cache_storage = undefined,
        .external_cache = object_cache,
        .owns_cache = owns_cache,
        .object_storage = undefined,
        .reference_storage = undefined,
        .index_storage = undefined,
        .shallow_storage = undefined,
        .config_storage = undefined,
        .module_storage = undefined,
        .hash_algo = .sha1,
        .clock = ops.clock,
    };
    if (owns_cache) {
        s.cache_storage = ObjectLru.initDefault(allocator);
    }

    const cache_ptr: ?*ObjectLru = if (owns_cache) &s.cache_storage else object_cache;

    const obj_opts = object_mod.Options{
        .exclusive_access = ops.exclusive_access,
        .keep_descriptors = ops.keep_descriptors,
        .max_open_descriptors = ops.max_open_descriptors,
        .large_object_threshold = ops.large_object_threshold,
    };

    s.object_storage = ObjectStorageT.init(allocator, dir, cache_ptr, obj_opts);
    s.reference_storage = ReferenceStorageT.init(allocator, dir);
    s.index_storage = IndexStorageT.init(allocator, dir);
    s.shallow_storage = ShallowStorageT.init(allocator, dir);
    s.config_storage = ConfigStorageT.init(allocator, dir);
    s.module_storage = StorageT.ModuleStorage.init(allocator, dir, ops.clock);
    return s;
}
