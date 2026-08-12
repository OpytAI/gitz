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
const storer = @import("storer");

const Allocator = std.mem.Allocator;
const Endpoint = transport.Endpoint;
const Hash = plumbing.Hash;
const MemoryObject = plumbing.MemoryObject;
const ObjectType = plumbing.ObjectType;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;

/// Invoke a method that returns either `void` or `!void` (memory vs filesystem).
fn callMaybeError(result: anytype) !void {
    if (comptime @typeInfo(@TypeOf(result)) == .error_union) {
        return try result;
    }
}

fn referenceReturnsOwned(comptime T: type) bool {
    return @hasDecl(T, "reference_returns_owned") and T.reference_returns_owned;
}

/// Deep-copy a reference so name/target strings are allocator-owned.
fn dupeReference(allocator: Allocator, r: Reference) Allocator.Error!Reference {
    const name = try allocator.dupe(u8, r.name.raw);
    errdefer allocator.free(name);
    switch (r.type) {
        .hash => return Reference.newHashReference(ReferenceName.init(name), r.hash),
        .symbolic => {
            const target = try allocator.dupe(u8, r.target.raw);
            errdefer allocator.free(target);
            return Reference.newSymbolicReference(
                ReferenceName.init(name),
                ReferenceName.init(target),
            );
        },
        .invalid => {
            allocator.free(name);
            return r;
        },
    }
}

/// Free name/target strings of a caller-owned reference.
fn freeOwnedReference(allocator: Allocator, r: Reference) void {
    if (r.name.raw.len > 0) allocator.free(r.name.raw);
    if (r.type == .symbolic and r.target.raw.len > 0) allocator.free(r.target.raw);
}

// ---------------------------------------------------------------------------
// RepoStorer — type-erased storer.Storer subset used by server sessions
// ---------------------------------------------------------------------------

/// Callback for each hash reference (name is valid for the duration of the call).
pub const HashRefCallback = *const fn (ctx: *anyopaque, name: []const u8, hash: Hash) anyerror!void;

/// Type-erased repository storer (go-git `storer.Storer` subset for server).
///
/// # Reference ownership (uniform)
///
/// `reference` / `resolveReference` always return a **caller-owned** `Reference`:
/// both `name.raw` and symbolic `target.raw` are heap slices. Free exactly once
/// with `freeReference`. This erases the memory (borrowed) vs filesystem (owned)
/// backend difference at the vtable boundary.
pub const RepoStorer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        encodedObject: *const fn (ptr: *anyopaque, t: ObjectType, h: Hash) anyerror!*MemoryObject,
        newEncodedObject: *const fn (ptr: *anyopaque) anyerror!*MemoryObject,
        setEncodedObject: *const fn (ptr: *anyopaque, obj: *MemoryObject) anyerror!Hash,
        discardEncodedObject: *const fn (ptr: *anyopaque, obj: *MemoryObject) void,
        setReference: *const fn (ptr: *anyopaque, ref: Reference) anyerror!void,
        reference: *const fn (ptr: *anyopaque, name: ReferenceName) anyerror!Reference,
        freeReference: *const fn (ptr: *anyopaque, ref: Reference) void,
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

    /// Abandon a caller-owned create that was never successfully set.
    pub fn discardEncodedObject(self: RepoStorer, obj: *MemoryObject) void {
        self.vtable.discardEncodedObject(self.ptr, obj);
    }

    pub fn setReference(self: RepoStorer, ref: Reference) anyerror!void {
        return self.vtable.setReference(self.ptr, ref);
    }

    /// Lookup; returned reference is always caller-owned — `freeReference` it.
    pub fn reference(self: RepoStorer, name: ReferenceName) anyerror!Reference {
        return self.vtable.reference(self.ptr, name);
    }

    /// Free a reference returned by `reference` or `resolveReference`.
    pub fn freeReference(self: RepoStorer, ref: Reference) void {
        self.vtable.freeReference(self.ptr, ref);
    }

    pub fn removeReference(self: RepoStorer, name: ReferenceName) anyerror!void {
        return self.vtable.removeReference(self.ptr, name);
    }

    pub fn forEachHashRef(self: RepoStorer, ctx: *anyopaque, cb: HashRefCallback) anyerror!void {
        return self.vtable.forEachHashRef(self.ptr, ctx, cb);
    }

    /// True if a reference exists (does not leak on success).
    pub fn hasReference(self: RepoStorer, name: ReferenceName) anyerror!bool {
        const r = self.reference(name) catch |err| {
            if (err == error.ReferenceNotFound) return false;
            return err;
        };
        self.freeReference(r);
        return true;
    }

    /// Resolve symbolic refs to a hash ref. Intermediate hops are freed.
    /// Caller owns the returned reference — `freeReference` it.
    pub fn resolveReference(self: RepoStorer, name: ReferenceName) anyerror!Reference {
        var current = try self.reference(name);
        var depth: usize = 0;
        while (current.type == .symbolic) {
            if (depth >= storer.MaxResolveRecursion) {
                self.freeReference(current);
                return error.MaxResolveRecursion;
            }
            depth += 1;
            const next = self.reference(current.target) catch |err| {
                self.freeReference(current);
                return err;
            };
            self.freeReference(current);
            current = next;
        }
        return current;
    }

    /// Build from a concrete EncodedObjectStorer + ReferenceStorer type.
    ///
    /// `T` must expose `.allocator`, `discardEncodedObject`, and the usual storage
    /// methods. If `T.reference_returns_owned` is true (filesystem), values from
    /// `reference` are already owned; otherwise they are duplicated so the
    /// free contract is uniform.
    pub fn from(comptime T: type, impl: *T) RepoStorer {
        if (comptime !@hasDecl(T, "discardEncodedObject")) {
            @compileError(@typeName(T) ++ " must implement discardEncodedObject for RepoStorer");
        }
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
            fn discardEncodedObjectFn(ptr: *anyopaque, obj: *MemoryObject) void {
                const s: *T = @ptrCast(@alignCast(ptr));
                s.discardEncodedObject(obj);
            }
            fn setReferenceFn(ptr: *anyopaque, ref: Reference) anyerror!void {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.setReference(ref);
            }
            fn referenceFn(ptr: *anyopaque, name: ReferenceName) anyerror!Reference {
                const s: *T = @ptrCast(@alignCast(ptr));
                const r = try s.reference(name);
                if (comptime referenceReturnsOwned(T)) return r;
                return try dupeReference(s.allocator, r);
            }
            fn freeReferenceFn(ptr: *anyopaque, ref: Reference) void {
                const s: *T = @ptrCast(@alignCast(ptr));
                freeOwnedReference(s.allocator, ref);
            }
            fn removeReferenceFn(ptr: *anyopaque, name: ReferenceName) anyerror!void {
                const s: *T = @ptrCast(@alignCast(ptr));
                return callMaybeError(s.removeReference(name));
            }
            fn forEachHashRefFn(ptr: *anyopaque, ctx: *anyopaque, cb: HashRefCallback) anyerror!void {
                const s: *T = @ptrCast(@alignCast(ptr));
                var it = try s.iterReferences();
                // Iter deinit frees FS-owned snapshot refs; memory frees the slice only.
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
                .discardEncodedObject = discardEncodedObjectFn,
                .setReference = setReferenceFn,
                .reference = referenceFn,
                .freeReference = freeReferenceFn,
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

        /// go-git `(*fsLoader).Load`, with a robust non-bare fix:
        /// go-git leaves the worktree FS as the storage root (DotGit then cannot
        /// see `config`/`objects` under `.git/`). We chroot into `.git` so the
        /// filesystem storer is usable for both bare and non-bare layouts.
        pub fn load(self: *Self, ep: *const Endpoint) anyerror!RepoStorer {
            const path = endpointPath(ep);

            // Resolve first so a miss never touches heap-owned Fs state.
            var git_fs = try resolveGitDir(Fs, self.base, path);

            const fs_ptr = self.allocator.create(Fs) catch |err| {
                git_fs.deinit();
                return err;
            };
            fs_ptr.* = git_fs;

            // Initialized heap values; free on error until transferred to `owned_*`.
            var pending_fs: ?*Fs = fs_ptr;
            var pending_cache: ?*cache_pkg.ObjectLru = null;
            var pending_sto: ?*StorageT = null;
            errdefer {
                if (pending_sto) |s| {
                    s.deinit();
                    self.allocator.destroy(s);
                }
                if (pending_cache) |c| {
                    c.deinit();
                    self.allocator.destroy(c);
                }
                if (pending_fs) |f| {
                    f.deinit();
                    self.allocator.destroy(f);
                }
            }

            const cache_ptr = try self.allocator.create(cache_pkg.ObjectLru);
            cache_ptr.* = cache_pkg.ObjectLru.initDefault(self.allocator);
            pending_cache = cache_ptr;

            const sto = try filesystem.newStorageWithOptionsFor(Fs, self.allocator, fs_ptr, cache_ptr, .{});
            pending_sto = sto;

            try self.owned_fs.append(self.allocator, fs_ptr);
            pending_fs = null;
            try self.owned_caches.append(self.allocator, cache_ptr);
            pending_cache = null;
            try self.owned_storages.append(self.allocator, sto);
            pending_sto = null;

            return RepoStorer.from(StorageT, sto);
        }
    };
}

/// Open `base` at `path` and return a FS rooted at the git directory.
///
/// - Bare: top-level `config` exists → use that root.
/// - Non-bare: `.git` exists → chroot into `.git` (usable DotGit layout).
/// - Otherwise → `RepositoryNotFound`.
fn resolveGitDir(comptime Fs: type, base: *Fs, path: []const u8) !Fs {
    var root = base.chroot(path) catch return transport.Error.RepositoryNotFound;

    const bare = blk: {
        _ = root.stat("config") catch break :blk false;
        break :blk true;
    };
    if (bare) return root;

    _ = root.stat(".git") catch {
        root.deinit();
        return transport.Error.RepositoryNotFound;
    };

    const git_dir = root.chroot(".git") catch {
        root.deinit();
        return transport.Error.RepositoryNotFound;
    };
    // Worktree view only held the path prefix; free it after nesting into `.git`.
    root.deinit();
    return git_dir;
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
