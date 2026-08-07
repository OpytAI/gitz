//! Repository loaders for the in-process git server (go-git `transport/server/loader.go`).
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `Loader` | `Loader` (vtable) |
//! | `NewFilesystemLoader` | `FilesystemLoader(Fs).init` |
//! | `DefaultLoader` | `newDefaultLoader` (needs allocator + `std.Io`) |
//! | `MapLoader` | `MapLoader` |

const std = @import("std");
const plumbing = @import("plumbing");
const transport = @import("transport");
const memory = @import("memory");
const filesystem = @import("filesystem");
const cache_pkg = @import("cache");
const fs_pkg = @import("fs");

const Allocator = std.mem.Allocator;
const Endpoint = transport.Endpoint;
const Hash = plumbing.Hash;
const MemoryObject = plumbing.MemoryObject;
const ObjectType = plumbing.ObjectType;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;

// ---------------------------------------------------------------------------
// RepoStorer — type-erased storer.Storer subset used by server sessions
// ---------------------------------------------------------------------------

/// Callback for each hash reference (name is valid for the duration of the call).
pub const HashRefCallback = *const fn (ctx: *anyopaque, name: []const u8, hash: Hash) anyerror!void;

/// Type-erased repository storer (go-git `storer.Storer` subset for server).
pub const RepoStorer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        encodedObject: *const fn (ptr: *anyopaque, t: ObjectType, h: Hash) anyerror!*MemoryObject,
        newEncodedObject: *const fn (ptr: *anyopaque) anyerror!*MemoryObject,
        setEncodedObject: *const fn (ptr: *anyopaque, obj: *MemoryObject) anyerror!Hash,
        setReference: *const fn (ptr: *anyopaque, ref: Reference) anyerror!void,
        reference: *const fn (ptr: *anyopaque, name: ReferenceName) anyerror!Reference,
        removeReference: *const fn (ptr: *anyopaque, name: ReferenceName) anyerror!void,
        forEachHashRef: *const fn (ptr: *anyopaque, ctx: *anyopaque, cb: HashRefCallback) anyerror!void,
    };

    pub fn encodedObject(self: RepoStorer, t: ObjectType, h: Hash) anyerror!*MemoryObject {
        return self.vtable.encodedObject(self.ptr, t, h);
    }

    pub fn newEncodedObject(self: RepoStorer) anyerror!*MemoryObject {
        return self.vtable.newEncodedObject(self.ptr);
    }

    pub fn setEncodedObject(self: RepoStorer, obj: *MemoryObject) anyerror!Hash {
        return self.vtable.setEncodedObject(self.ptr, obj);
    }

    pub fn setReference(self: RepoStorer, ref: Reference) anyerror!void {
        return self.vtable.setReference(self.ptr, ref);
    }

    pub fn reference(self: RepoStorer, name: ReferenceName) anyerror!Reference {
        return self.vtable.reference(self.ptr, name);
    }

    pub fn removeReference(self: RepoStorer, name: ReferenceName) anyerror!void {
        return self.vtable.removeReference(self.ptr, name);
    }

    pub fn forEachHashRef(self: RepoStorer, ctx: *anyopaque, cb: HashRefCallback) anyerror!void {
        return self.vtable.forEachHashRef(self.ptr, ctx, cb);
    }

    /// Build from a concrete EncodedObjectStorer + ReferenceStorer type.
    pub fn from(comptime T: type, impl: *T) RepoStorer {
        const gen = struct {
            fn encodedObjectFn(ptr: *anyopaque, t: ObjectType, h: Hash) anyerror!*MemoryObject {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.encodedObject(t, h);
            }
            fn newEncodedObjectFn(ptr: *anyopaque) anyerror!*MemoryObject {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.newEncodedObject();
            }
            fn setEncodedObjectFn(ptr: *anyopaque, obj: *MemoryObject) anyerror!Hash {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.setEncodedObject(obj);
            }
            fn setReferenceFn(ptr: *anyopaque, ref: Reference) anyerror!void {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.setReference(ref);
            }
            fn referenceFn(ptr: *anyopaque, name: ReferenceName) anyerror!Reference {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.reference(name);
            }
            fn removeReferenceFn(ptr: *anyopaque, name: ReferenceName) anyerror!void {
                const s: *T = @ptrCast(@alignCast(ptr));
                // memory.Storage.removeReference is void; filesystem/transactional return !void.
                const result = s.removeReference(name);
                if (comptime @typeInfo(@TypeOf(result)) == .error_union) {
                    return try result;
                }
            }
            fn forEachHashRefFn(ptr: *anyopaque, ctx: *anyopaque, cb: HashRefCallback) anyerror!void {
                const s: *T = @ptrCast(@alignCast(ptr));
                var it = try s.iterReferences();
                // ReferenceSliceIter (memory) owns a snapshot array — must free.
                defer it.deinit();
                while (true) {
                    const ref = it.next() catch |err| {
                        if (err == error.EndOfStream) break;
                        return err;
                    };
                    if (ref.type != .hash) continue;
                    try cb(ctx, ref.name.raw, ref.hash);
                }
            }
            const vtable = VTable{
                .encodedObject = encodedObjectFn,
                .newEncodedObject = newEncodedObjectFn,
                .setEncodedObject = setEncodedObjectFn,
                .setReference = setReferenceFn,
                .reference = referenceFn,
                .removeReference = removeReferenceFn,
                .forEachHashRef = forEachHashRefFn,
            };
        };
        return .{
            .ptr = impl,
            .vtable = &gen.vtable,
        };
    }
};

// ---------------------------------------------------------------------------
// Loader interface
// ---------------------------------------------------------------------------

/// Loads a repository storer for an endpoint (go-git `Loader`).
pub const Loader = struct {
    ptr: *anyopaque,
    load_fn: *const fn (ptr: *anyopaque, ep: *const Endpoint) anyerror!RepoStorer,

    pub fn load(self: Loader, ep: *const Endpoint) anyerror!RepoStorer {
        return self.load_fn(self.ptr, ep);
    }

    pub fn from(comptime T: type, impl: *T) Loader {
        const gen = struct {
            fn loadFn(ptr: *anyopaque, ep: *const Endpoint) anyerror!RepoStorer {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.load(ep);
            }
        };
        return .{ .ptr = impl, .load_fn = gen.loadFn };
    }
};

// ---------------------------------------------------------------------------
// FilesystemLoader
// ---------------------------------------------------------------------------

/// Filesystem loader: ignore host, resolve `ep.path` under a base billy FS.
pub fn FilesystemLoader(comptime Fs: type) type {
    return struct {
        const Self = @This();
        const StorageT = filesystem.StorageFor(Fs);

        allocator: Allocator,
        base: *Fs,
        owned_storages: std.ArrayListUnmanaged(*StorageT) = .empty,
        owned_fs: std.ArrayListUnmanaged(*Fs) = .empty,
        owned_caches: std.ArrayListUnmanaged(*cache_pkg.ObjectLru) = .empty,

        pub fn init(allocator: Allocator, base: *Fs) Self {
            return .{ .allocator = allocator, .base = base };
        }

        pub fn deinit(self: *Self) void {
            for (self.owned_storages.items) |s| {
                s.deinit();
                self.allocator.destroy(s);
            }
            self.owned_storages.deinit(self.allocator);
            for (self.owned_caches.items) |c| {
                c.deinit();
                self.allocator.destroy(c);
            }
            self.owned_caches.deinit(self.allocator);
            for (self.owned_fs.items) |f| {
                f.deinit();
                self.allocator.destroy(f);
            }
            self.owned_fs.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn asLoader(self: *Self) Loader {
            return Loader.from(Self, self);
        }

        /// go-git `(*fsLoader).Load`.
        pub fn load(self: *Self, ep: *const Endpoint) anyerror!RepoStorer {
            const path = endpointPath(ep);
            const chrooted = self.base.chroot(path) catch {
                return transport.Error.RepositoryNotFound;
            };

            // Track whether ownership transferred to `owned_*` lists so errdefer
            // does not double-free after a successful append.
            var fs_owned = false;
            var cache_owned = false;

            const fs_ptr = try self.allocator.create(Fs);
            errdefer if (!fs_owned) {
                fs_ptr.deinit();
                self.allocator.destroy(fs_ptr);
            };
            fs_ptr.* = chrooted;

            // Bare repo has top-level `config`; non-bare has `.git`.
            var bare = true;
            _ = fs_ptr.stat("config") catch {
                bare = false;
            };
            if (!bare) {
                _ = fs_ptr.stat(".git") catch {
                    return transport.Error.RepositoryNotFound;
                };
            }

            try self.owned_fs.append(self.allocator, fs_ptr);
            fs_owned = true;

            const cache_ptr = try self.allocator.create(cache_pkg.ObjectLru);
            errdefer if (!cache_owned) {
                cache_ptr.deinit();
                self.allocator.destroy(cache_ptr);
            };
            cache_ptr.* = cache_pkg.ObjectLru.initDefault(self.allocator);
            try self.owned_caches.append(self.allocator, cache_ptr);
            cache_owned = true;

            const sto = try filesystem.newStorageWithOptionsFor(Fs, self.allocator, fs_ptr, cache_ptr, .{});
            errdefer {
                // Storage owns nothing of fs/cache beyond pointers; free on failure
                // before it is recorded in owned_storages.
                sto.deinit();
                self.allocator.destroy(sto);
            }
            try self.owned_storages.append(self.allocator, sto);
            return RepoStorer.from(StorageT, sto);
        }
    };
}

pub const FilesystemLoaderMem = FilesystemLoader(fs_pkg.Mem);
pub const FilesystemLoaderOs = FilesystemLoader(fs_pkg.Os);

/// go-git `NewFilesystemLoader` for Os.
pub fn newFilesystemLoaderOs(allocator: Allocator, base: *fs_pkg.Os) FilesystemLoaderOs {
    return FilesystemLoaderOs.init(allocator, base);
}

/// go-git `NewFilesystemLoader` for Mem (hermetic tests).
pub fn newFilesystemLoaderMem(allocator: Allocator, base: *fs_pkg.Mem) FilesystemLoaderMem {
    return FilesystemLoaderMem.init(allocator, base);
}

/// Approximate go-git `DefaultLoader` — host FS rooted at `/`.
/// Caller owns `base_out` and must `deinit` it after the loader is freed.
pub fn newDefaultLoader(allocator: Allocator, io: std.Io, base_out: *fs_pkg.Os) !FilesystemLoaderOs {
    base_out.* = try fs_pkg.Os.init(allocator, io, "/");
    return FilesystemLoaderOs.init(allocator, base_out);
}

// ---------------------------------------------------------------------------
// MapLoader
// ---------------------------------------------------------------------------

/// Map of endpoint string → storer (go-git `MapLoader`).
///
/// Keys are owned endpoint strings. Values are type-erased; typically
/// `*memory.Storage` for in-process server tests.
pub const MapLoader = struct {
    allocator: Allocator,
    map: std.StringHashMapUnmanaged(RepoStorer) = .empty,
    keys: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn init(allocator: Allocator) MapLoader {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MapLoader) void {
        for (self.keys.items) |k| self.allocator.free(k);
        self.keys.deinit(self.allocator);
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn asLoader(self: *MapLoader) Loader {
        return Loader.from(MapLoader, self);
    }

    /// Register a memory storage under `ep` (go-git map assign).
    pub fn put(self: *MapLoader, ep: *const Endpoint, sto: *memory.Storage) !void {
        try self.putStorer(ep, RepoStorer.from(memory.Storage, sto));
    }

    /// Register a type-erased storer under `ep`.
    pub fn putStorer(self: *MapLoader, ep: *const Endpoint, sto: RepoStorer) !void {
        const key = try endpointKey(self.allocator, ep);
        errdefer self.allocator.free(key);
        const gop = try self.map.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(key);
            gop.value_ptr.* = sto;
            return;
        }
        try self.keys.append(self.allocator, key);
        gop.value_ptr.* = sto;
    }

    /// go-git `MapLoader.Load`.
    pub fn load(self: *MapLoader, ep: *const Endpoint) anyerror!RepoStorer {
        const key = try endpointKey(self.allocator, ep);
        defer self.allocator.free(key);
        return self.map.get(key) orelse transport.Error.RepositoryNotFound;
    }
};

// ---------------------------------------------------------------------------
// Endpoint helpers
// ---------------------------------------------------------------------------

fn endpointPath(ep: *const Endpoint) []const u8 {
    return ep.path;
}

/// Format endpoint for MapLoader keys (go-git `Endpoint.String`).
pub fn endpointKey(allocator: Allocator, ep: *const Endpoint) ![]u8 {
    return ep.string(allocator);
}
