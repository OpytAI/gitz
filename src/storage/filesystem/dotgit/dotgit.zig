//! DotGit — local `.git` directory layout (go-git `storage/filesystem/dotgit`).
//!
//! Parameterised over a billy-style filesystem type (`Mem`, `Os`). Methods match
//! go-git behaviour. Call sites that only need the in-memory backend use
//! `DotGit(Mem)` (re-exported as `DotGit` / `DotGitMem` from the package root).

const std = @import("std");
const Allocator = std.mem.Allocator;

const fs_mod = @import("fs");
const plumbing = @import("plumbing");

const error_mod = @import("error.zig");
const writers_mod = @import("writers.zig");

pub const Error = error_mod.Error;

const O = fs_mod.O;
const Mode = fs_mod.Mode;

const Hash = plumbing.Hash;
const HexSize = plumbing.HexSize;
const MaxHexSize = plumbing.MaxHexSize;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;

const packed_refs_path = "packed-refs";
const config_path = "config";
const index_path = "index";
const shallow_path = "shallow";
const module_path = "modules";
const objects_path = "objects";
const pack_dir = "pack";
const refs_path = "refs";
const tmp_packed_refs_prefix = "._packed-refs";
const max_loose_ref_size: i64 = 4096;
const pack_prefix = "pack-";
const pack_ext = ".pack";
const symref_prefix = "ref: ";
/// Quarantine dir prefix used by receive-pack (Git ≥ 2.35).
const incoming_prefix = "tmp_objdir-incoming-";
/// Pre-2.35 quarantine dir prefix.
const incoming_prefix_legacy = "incoming-";

const HashMapCtx = struct {
    pub fn hash(_: HashMapCtx, k: Hash) u64 {
        return std.hash.Wyhash.hash(0, &k.bytes);
    }
    pub fn eql(_: HashMapCtx, a: Hash, b: Hash) bool {
        return a.eql(b);
    }
};
const HashSet = std.HashMapUnmanaged(Hash, void, HashMapCtx, std.hash_map.default_max_load_percentage);

/// Local git repository directory on a billy-style filesystem (go-git `DotGit`).
///
/// `Fs` must expose `File`, `allocator`, and the Mem/Os method set
/// (`create`, `open`, `openFile`, `stat`, `lstat`, `mkdirAll`, `readDir`,
/// `freeReadDir`, `remove`, `rename`, `tempFile`, `joinPath`, `chroot`, …).
pub fn DotGit(comptime Fs: type) type {
    return struct {
        const Self = @This();
        pub const File = Fs.File;
        pub const ObjectWriter = writers_mod.ObjectWriter(Fs);
        pub const PackWriter = writers_mod.PackWriter(Fs);

        /// Options for DotGit (go-git `Options`; subset).
        pub const Options = struct {
            /// When true, pack and object lists are cached for exclusive use.
            exclusive_access: bool = false,
            /// Reserved (go-git `KeepDescriptors`); not used for Mem.
            keep_descriptors: bool = false,
            /// Filesystem used to resolve alternate object-db paths (go-git
            /// `AlternatesFS`). When null, `alternates` uses `self.fs`.
            /// For absolute paths on Mem, the same root FS is typical; for
            /// paths outside a chroot, pass the parent/root FS.
            alternates_fs: ?*Fs = null,
        };

        options: Options = .{},
        fs: *Fs,

        /// Incoming (quarantine) object directory discovery (go-git `incomingChecked` / `incomingDirName`).
        incoming_checked: bool = false,
        /// Owned base name under `objects/` when an incoming dir was found; null if none.
        incoming_dir_name: ?[]u8 = null,

        object_list: ?[]Hash = null,
        object_map: ?HashSet = null,
        pack_list: ?[]Hash = null,
        pack_map: ?HashSet = null,

        /// go-git `NewWithOptions`. `allocator` is accepted for API parity with the
        /// filesystem façade; backends use `fs.allocator`.
        pub fn init(gpa: Allocator, backend: *Fs, options: Options) Self {
            _ = gpa;
            return .{
                .options = options,
                .fs = backend,
            };
        }

        /// go-git `New(fs)` with default options.
        pub fn new(backend: *Fs) Self {
            return init(backend.allocator, backend, .{});
        }

        pub fn deinit(self: *Self) void {
            self.cleanObjectList();
            self.cleanPackList();
            self.cleanIncoming();
            self.* = undefined;
        }

        /// Create layout scaffolding (go-git `Initialize`).
        pub fn initialize(self: *Self) (Allocator.Error || fs_mod.Error)!void {
            const must = [_][]const u8{
                "objects/info",
                "objects/pack",
                "refs/heads",
                "refs/tags",
            };
            for (must) |path| {
                if (self.fs.stat(path)) |_| {
                    continue;
                } else |err| switch (err) {
                    error.NotExist => try self.fs.mkdirAll(path, Mode.dir),
                    else => |e| return e,
                }
            }
        }

        /// Close cached resources (go-git `Close`).
        pub fn close(self: *Self) void {
            self.cleanObjectList();
            self.cleanPackList();
        }

        /// Underlying filesystem (go-git `Fs`).
        pub fn fsPtr(self: *const Self) *Fs {
            return self.fs;
        }

        /// Alias of `fsPtr` (filesystem package façade name).
        pub fn filesystem(self: *const Self) *Fs {
            return self.fs;
        }

        // --- config / index / shallow ------------------------------------------------

        /// go-git `ConfigWriter`.
        pub fn configWriter(self: *Self) (Allocator.Error || fs_mod.Error)!File {
            return try self.fs.create(config_path);
        }

        /// go-git `Config`. Maps missing file to `ConfigNotFound`.
        pub fn config(self: *Self) (Allocator.Error || fs_mod.Error || Error)!File {
            return self.fs.open(config_path) catch |err| switch (err) {
                error.NotExist => error.ConfigNotFound,
                else => |e| e,
            };
        }

        /// go-git `IndexWriter`.
        pub fn indexWriter(self: *Self) (Allocator.Error || fs_mod.Error)!File {
            return try self.fs.create(index_path);
        }

        /// go-git `Index`.
        pub fn index(self: *Self) (Allocator.Error || fs_mod.Error)!File {
            return try self.fs.open(index_path);
        }

        /// go-git `ShallowWriter`.
        pub fn shallowWriter(self: *Self) (Allocator.Error || fs_mod.Error)!File {
            return try self.fs.create(shallow_path);
        }

        /// go-git `Shallow`. Missing file returns `null` (no error).
        pub fn shallow(self: *Self) (Allocator.Error || fs_mod.Error)!?File {
            return self.fs.open(shallow_path) catch |err| switch (err) {
                error.NotExist => null,
                else => |e| e,
            };
        }

        // --- packs -------------------------------------------------------------------

        /// Start a new pack writer (go-git `NewObjectPack`).
        pub fn newObjectPack(self: *Self) (Allocator.Error || fs_mod.Error)!PackWriter {
            self.cleanPackList();
            return try PackWriter.open(self.fs);
        }

        /// Delete pack + idx when pack mtime is older than `t` unix seconds.
        /// `t == 0` means always delete (go-git `DeleteOldObjectPackAndIndex` zero time).
        pub fn deleteOldObjectPackAndIndex(self: *Self, h: Hash, t: i64) (Allocator.Error || fs_mod.Error)!void {
            self.cleanPackList();

            const pack_path = try self.objectPackPath(h, "pack");
            defer self.allocator().free(pack_path);
            const idx_path = try self.objectPackPath(h, "idx");
            defer self.allocator().free(idx_path);

            if (t != 0) {
                const fi = try self.fs.stat(pack_path);
                // Too new: skip (mtime not strictly before t).
                if (fi.mtime_sec >= t) return;
            }
            try self.fs.remove(pack_path);
            try self.fs.remove(idx_path);
        }

        /// List pack hashes from `objects/pack/pack-*.pack` (go-git `ObjectPacks`).
        /// Caller frees with `freeHashes`.
        pub fn objectPacks(self: *Self) (Allocator.Error || fs_mod.Error)![]Hash {
            if (!self.options.exclusive_access) {
                return try self.objectPacksScan();
            }
            try self.genPackList();
            const list = self.pack_list orelse return &.{};
            if (list.len == 0) return &.{};
            return try self.allocator().dupe(Hash, list);
        }

        fn objectPacksScan(self: *Self) (Allocator.Error || fs_mod.Error)![]Hash {
            const pack_dir_path = try self.fs.joinPath(&.{ objects_path, pack_dir });
            defer self.allocator().free(pack_dir_path);

            const entries = self.fs.readDir(pack_dir_path) catch |err| switch (err) {
                error.NotExist => return &.{},
                else => |e| return e,
            };
            defer self.fs.freeReadDir(entries);

            var list: std.ArrayList(Hash) = .empty;
            errdefer list.deinit(self.allocator());

            for (entries) |e| {
                const n = e.name;
                if (!std.mem.startsWith(u8, n, pack_prefix)) continue;
                if (!std.mem.endsWith(u8, n, pack_ext)) continue;
                if (n.len <= pack_prefix.len + pack_ext.len) continue;
                const hex = n[pack_prefix.len .. n.len - pack_ext.len];
                const h = plumbing.newHash(hex);
                if (h.isZero()) continue;
                try list.append(self.allocator(), h);
            }
            if (list.items.len == 0) {
                list.deinit(self.allocator());
                return &.{};
            }
            return try list.toOwnedSlice(self.allocator());
        }

        /// Open packfile (go-git `ObjectPack`).
        pub fn objectPack(self: *Self, h: Hash) (Allocator.Error || fs_mod.Error || Error)!File {
            try self.hasPack(h);
            return self.objectPackOpen(h, "pack") catch |err| switch (err) {
                error.NotExist => error.PackfileNotFound,
                else => |e| e,
            };
        }

        /// Open pack index (go-git `ObjectPackIdx`).
        pub fn objectPackIdx(self: *Self, h: Hash) (Allocator.Error || fs_mod.Error || Error)!File {
            try self.hasPack(h);
            return self.objectPackOpen(h, "idx") catch |err| switch (err) {
                error.NotExist => error.PackfileNotFound,
                else => |e| e,
            };
        }

        fn objectPackOpen(self: *Self, h: Hash, extension: []const u8) (Allocator.Error || fs_mod.Error)!File {
            const path = try self.objectPackPath(h, extension);
            defer self.allocator().free(path);
            return try self.fs.open(path);
        }

        fn objectPackPath(self: *Self, h: Hash, extension: []const u8) Allocator.Error![]u8 {
            var hex_buf: [MaxHexSize]u8 = undefined;
            const hex = h.string(&hex_buf);
            const name = try std.fmt.allocPrint(self.allocator(), "pack-{s}.{s}", .{ hex, extension });
            defer self.allocator().free(name);
            return try self.fs.joinPath(&.{ objects_path, pack_dir, name });
        }

        // --- loose objects -----------------------------------------------------------

        /// Start a new loose object writer (go-git `NewObject`).
        pub fn newObject(self: *Self) (Allocator.Error || fs_mod.Error || std.Io.Writer.Error)!ObjectWriter {
            self.cleanObjectList();
            return try ObjectWriter.open(self.fs);
        }

        /// Path of a loose object (go-git `objectPath`). Caller frees.
        pub fn objectPath(self: *Self, h: Hash) Allocator.Error![]u8 {
            var hex_buf: [MaxHexSize]u8 = undefined;
            const hex = h.string(&hex_buf);
            return try self.fs.joinPath(&.{ objects_path, hex[0..2], hex[2..] });
        }

        /// Path under the receive-pack quarantine / incoming dir (go-git `incomingObjectPath`).
        /// Caller frees. When no incoming dir is recorded, matches `objectPath`.
        fn incomingObjectPath(self: *Self, h: Hash) Allocator.Error![]u8 {
            var hex_buf: [MaxHexSize]u8 = undefined;
            const hex = h.string(&hex_buf);
            if (self.incoming_dir_name) |dir| {
                if (dir.len > 0) {
                    return try self.fs.joinPath(&.{ objects_path, dir, hex[0..2], hex[2..] });
                }
            }
            return try self.fs.joinPath(&.{ objects_path, hex[0..2], hex[2..] });
        }

        /// Discover and cache an incoming objects directory (go-git `hasIncomingObjects`).
        /// Looks for `tmp_objdir-incoming-*` (Git ≥ 2.35) or `incoming-*` (older).
        fn hasIncomingObjects(self: *Self) Allocator.Error!bool {
            if (!self.incoming_checked) {
                if (self.fs.readDir(objects_path)) |entries| {
                    defer self.fs.freeReadDir(entries);
                    for (entries) |file| {
                        if (!file.isDir()) continue;
                        if (std.mem.startsWith(u8, file.name, incoming_prefix) or
                            std.mem.startsWith(u8, file.name, incoming_prefix_legacy))
                        {
                            // Last match wins (go-git overwrites without break).
                            // Dupe first so OOM does not free the previous name.
                            const owned = try self.allocator().dupe(u8, file.name);
                            if (self.incoming_dir_name) |old| self.allocator().free(old);
                            self.incoming_dir_name = owned;
                        }
                    }
                } else |_| {
                    // go-git ignores ReadDir errors and leaves no incoming dir.
                }
                self.incoming_checked = true;
            }
            return if (self.incoming_dir_name) |n| n.len > 0 else false;
        }

        /// Open a loose object file (go-git `Object`).
        /// Falls back to the receive-pack incoming/quarantine directory when present.
        pub fn object(self: *Self, h: Hash) (Allocator.Error || fs_mod.Error || plumbing.Error)!File {
            try self.hasObject(h);
            const path = try self.objectPath(h);
            defer self.allocator().free(path);
            return self.fs.open(path) catch |err1| switch (err1) {
                error.NotExist => {
                    if (!(try self.hasIncomingObjects())) return error.NotExist;
                    const inc = try self.incomingObjectPath(h);
                    defer self.allocator().free(inc);
                    return self.fs.open(inc) catch return error.NotExist;
                },
                else => |e| return e,
            };
        }

        /// Stat a loose object file (go-git `ObjectStat`). Returns `fs.FileInfo`.
        /// Falls back to the receive-pack incoming/quarantine directory when present.
        pub fn objectStat(self: *Self, h: Hash) (Allocator.Error || fs_mod.Error || plumbing.Error)!fs_mod.FileInfo {
            try self.hasObject(h);
            const path = try self.objectPath(h);
            defer self.allocator().free(path);
            return self.fs.stat(path) catch |err1| switch (err1) {
                error.NotExist => {
                    if (!(try self.hasIncomingObjects())) return error.NotExist;
                    const inc = try self.incomingObjectPath(h);
                    defer self.allocator().free(inc);
                    return self.fs.stat(inc) catch return error.NotExist;
                },
                else => |e| return e,
            };
        }

        /// Remove a loose object file (go-git `ObjectDelete`).
        /// Falls back to the receive-pack incoming/quarantine path when the loose path is missing.
        pub fn objectDelete(self: *Self, h: Hash) (Allocator.Error || fs_mod.Error)!void {
            self.cleanObjectList();
            const path = try self.objectPath(h);
            defer self.allocator().free(path);
            self.fs.remove(path) catch |err1| switch (err1) {
                error.NotExist => {
                    if (!(try self.hasIncomingObjects())) return error.NotExist;
                    const inc = try self.incomingObjectPath(h);
                    defer self.allocator().free(inc);
                    self.fs.remove(inc) catch return error.NotExist;
                },
                else => |e| return e,
            };
        }

        /// Hashes of loose objects whose raw hash bytes start with `prefix`
        /// (go-git `ObjectsWithPrefix`). Caller frees with `freeHashes`.
        /// Empty prefix → all objects. Prefix longer than hash size → empty.
        pub fn objectsWithPrefix(self: *Self, prefix: []const u8) (Allocator.Error || fs_mod.Error)![]Hash {
            if (prefix.len < 1) return try self.objects();
            if (prefix.len > plumbing.digestSize()) return &.{};

            if (self.options.exclusive_access) {
                try self.genObjectList();
                const list = self.object_list orelse return &.{};
                // Binary search half-open interval over sorted object_list.
                const first = lowerBoundHashPrefix(list, prefix);
                var lim = list.len;
                if (try incBytesAlloc(self.allocator(), prefix)) |lim_prefix| {
                    defer self.allocator().free(lim_prefix);
                    lim = lowerBoundHashPrefix(list, lim_prefix);
                }
                if (first >= lim) return &.{};
                return try self.allocator().dupe(Hash, list[first..lim]);
            }

            // Slow path: scan all loose objects.
            var list: std.ArrayList(Hash) = .empty;
            errdefer list.deinit(self.allocator());
            const all = try self.objects();
            defer freeHashes(self.allocator(), all);
            for (all) |h| {
                if (std.mem.startsWith(u8, h.bytes[0..], prefix)) {
                    try list.append(self.allocator(), h);
                }
            }
            if (list.items.len == 0) {
                list.deinit(self.allocator());
                return &.{};
            }
            return try list.toOwnedSlice(self.allocator());
        }

        /// List loose object hashes (go-git `Objects`). Caller frees with `freeHashes`.
        pub fn objects(self: *Self) (Allocator.Error || fs_mod.Error)![]Hash {
            if (self.options.exclusive_access) {
                try self.genObjectList();
                const list = self.object_list orelse return &.{};
                if (list.len == 0) return &.{};
                return try self.allocator().dupe(Hash, list);
            }
            var list: std.ArrayList(Hash) = .empty;
            errdefer list.deinit(self.allocator());
            try self.collectLooseObjects(&list);
            if (list.items.len == 0) {
                list.deinit(self.allocator());
                return &.{};
            }
            return try list.toOwnedSlice(self.allocator());
        }

        /// Iterate loose object hashes (go-git `ForEachObjectHash`).
        ///
        /// Context-aware: `fun(ctx, hash)`. Stack context is passed explicitly
        /// (no process-local statics). Concurrent-safe for distinct DotGit /
        /// filesystem instances; a single store is not thread-safe for concurrent
        /// mutation. Callback may return `error.Stop` to end early with success.
        pub fn forEachObjectHash(
            self: *Self,
            ctx: anytype,
            comptime fun: *const fn (@TypeOf(ctx), Hash) anyerror!void,
        ) anyerror!void {
            const all = try self.objects();
            defer freeHashes(self.allocator(), all);
            for (all) |h| {
                fun(ctx, h) catch |err| {
                    const any: anyerror = err;
                    if (any == error.Stop) return;
                    return any;
                };
            }
        }

        fn collectLooseObjects(self: *Self, list: *std.ArrayList(Hash)) (Allocator.Error || fs_mod.Error)!void {
            const entries = self.fs.readDir(objects_path) catch |err| switch (err) {
                error.NotExist => return,
                else => |e| return e,
            };
            defer self.fs.freeReadDir(entries);

            for (entries) |e| {
                if (!e.isDir() or e.name.len != 2 or !isHex(e.name)) continue;
                const sub = try self.fs.joinPath(&.{ objects_path, e.name });
                defer self.allocator().free(sub);
                const objs = self.fs.readDir(sub) catch continue;
                defer self.fs.freeReadDir(objs);
                for (objs) |o| {
                    const total = e.name.len + o.name.len;
                    if (total != HexSize and total != MaxHexSize) continue;
                    var hex_buf: [MaxHexSize]u8 = undefined;
                    @memcpy(hex_buf[0..2], e.name);
                    @memcpy(hex_buf[2..total], o.name);
                    const h = plumbing.newHash(hex_buf[0..total]);
                    if (h.isZero()) continue;
                    try list.append(self.allocator(), h);
                }
            }
        }

        // --- references --------------------------------------------------------------

        /// Write a reference (go-git `SetRef`). `old` enables check-and-set.
        pub fn setRef(self: *Self, r: Reference, old: ?Reference) !void {
            try validReferenceName(r.name);
            if (r.type == .symbolic) try validReferenceName(r.target);

            const content = try formatRefContent(self.allocator(), r);
            defer self.allocator().free(content);

            try self.setRefFile(r.name.string(), content, old);
        }

        /// Resolve one reference (go-git `Ref`). Caller frees with `freeRef`.
        pub fn ref(self: *Self, name: ReferenceName) !Reference {
            try validReferenceName(name);
            if (self.readReferenceFile(".", name.string())) |r| {
                return r;
            } else |err| switch (err) {
                error.NotExist => {},
                else => |e| return e,
            }
            return try self.packedRef(name);
        }

        /// Collect all references (go-git `Refs`). Caller frees with `freeRefs`.
        pub fn refs(self: *Self) ![]Reference {
            var list: std.ArrayList(Reference) = .empty;
            errdefer {
                for (list.items) |r| freeRef(self.allocator(), r);
                list.deinit(self.allocator());
            }
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer deinitSeen(self.allocator(), &seen);

            try self.addRefFromHEAD(&list);
            try self.addRefsFromRefDir(&list, &seen);
            try self.addRefsFromPackedRefs(&list, &seen);
            if (list.items.len == 0) {
                list.deinit(self.allocator());
                return &.{};
            }
            return try list.toOwnedSlice(self.allocator());
        }

        /// Remove a reference from loose and packed-refs (go-git `RemoveRef`).
        pub fn removeRef(self: *Self, name: ReferenceName) !void {
            try validReferenceName(name);
            const path = try self.fs.joinPath(&.{ ".", name.string() });
            defer self.allocator().free(path);

            if (self.fs.stat(path)) |_| {
                try self.fs.remove(path);
            } else |err| switch (err) {
                error.NotExist => {},
                else => |e| return e,
            }
            try self.rewritePackedRefsWithoutRef(name);
        }

        /// Count loose refs under `refs/` (go-git `CountLooseRefs`).
        pub fn countLooseRefs(self: *Self) !usize {
            return try self.countRefFiles(refs_path);
        }

        fn countRefFiles(self: *Self, rel: []const u8) !usize {
            const entries = self.fs.readDir(rel) catch |err| switch (err) {
                error.NotExist => return 0,
                else => |e| return e,
            };
            defer self.fs.freeReadDir(entries);
            var n: usize = 0;
            for (entries) |e| {
                const child = try self.fs.joinPath(&.{ rel, e.name });
                defer self.allocator().free(child);
                if (e.isDir()) {
                    n += try self.countRefFiles(child);
                } else {
                    n += 1;
                }
            }
            return n;
        }

        /// Pack all loose refs into `packed-refs` and delete loose files (go-git `PackRefs`).
        pub fn packRefs(self: *Self) !void {
            var pr = try self.fs.openFile(packed_refs_path, O.RDWR | O.CREATE, 0o600);
            defer pr.close() catch {};
            try pr.lock();

            var list: std.ArrayList(Reference) = .empty;
            defer {
                for (list.items) |r| freeRef(self.allocator(), r);
                list.deinit(self.allocator());
            }
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer deinitSeen(self.allocator(), &seen);

            try self.addRefsFromRefDir(&list, &seen);
            if (list.items.len == 0) return;
            const num_loose = list.items.len;
            try self.addRefsFromPackedRefsFile(&list, &pr, &seen);

            var tmp = try self.fs.tempFile("", tmp_packed_refs_prefix);
            const tmp_name = try self.allocator().dupe(u8, tmp.fileName());
            defer self.allocator().free(tmp_name);

            for (list.items) |r| {
                const line = try formatRefLineAlloc(self.allocator(), r);
                defer self.allocator().free(line);
                _ = try tmp.write(line);
                _ = try tmp.write("\n");
            }
            try tmp.close();

            try self.rewritePackedRefsWhileLocked(tmp_name, packed_refs_path);
            // temp may already be renamed away
            self.fs.remove(tmp_name) catch {};

            // packed-refs lock file closed by defer

            for (list.items[0..num_loose]) |r| {
                const path = try self.fs.joinPath(&.{ ".", r.name.string() });
                defer self.allocator().free(path);
                self.fs.remove(path) catch |err| switch (err) {
                    error.NotExist => {},
                    else => |e| return e,
                };
            }
        }

        /// Module subdirectory chroot (go-git `Module`).
        pub fn module(self: *Self, name: []const u8) (Allocator.Error || fs_mod.Error || Error)!Fs {
            const p = try self.fs.joinPath(&.{ module_path, name });
            defer self.allocator().free(p);
            if (!pathUnderModules(p)) return error.ModuleNameEscape;
            try self.fs.mkdirAll(p, Mode.dir);
            return try self.fs.chroot(p);
        }

        /// Append an alternate objects path (go-git `AddAlternate`).
        pub fn addAlternate(self: *Self, remote: []const u8) (Allocator.Error || fs_mod.Error || Error)!void {
            if (remote.len == 0 or std.mem.indexOfAny(u8, remote, "\r\n\x00") != null) {
                return error.InvalidAlternate;
            }
            try self.fs.mkdirAll("objects/info", Mode.dir);
            var f = try self.fs.openFile("objects/info/alternates", O.RDWR | O.CREATE | O.APPEND, 0o640);
            defer f.close() catch {};
            const line = try std.fmt.allocPrint(self.allocator(), "{s}/objects\n", .{remote});
            defer self.allocator().free(line);
            _ = try f.write(line);
        }

        /// Return DotGit instances for each path in `objects/info/alternates`
        /// (go-git `Alternates`).
        ///
        /// Missing file → `error.NotExist` (same as go-git `Open` failure).
        /// Each entry is a heap-allocated `*Self` whose `fs` is a heap-allocated
        /// chroot of the alternate objects parent directory. Free with
        /// `freeAlternates`.
        pub fn alternates(self: *Self) (Allocator.Error || fs_mod.Error)![]*Self {
            const gpa = self.allocator();
            var f = try self.fs.open("objects/info/alternates");
            defer f.close() catch {};

            const content = try readAll(gpa, &f);
            defer gpa.free(content);

            const alt_fs: *Fs = self.options.alternates_fs orelse self.fs;

            // Owned keys for dedupe (not views into content).
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer {
                var it = seen.keyIterator();
                while (it.next()) |k| gpa.free(k.*);
                seen.deinit(gpa);
            }

            var out: std.ArrayList(*Self) = .empty;
            errdefer {
                for (out.items) |dg| {
                    const fs_owned = dg.fs;
                    dg.deinit();
                    gpa.destroy(dg);
                    fs_owned.deinit();
                    gpa.destroy(fs_owned);
                }
                out.deinit(gpa);
            }

            var line_it = std.mem.splitScalar(u8, content, '\n');
            while (line_it.next()) |raw_line| {
                const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
                if (line.len == 0) continue;

                const key = try gpa.dupe(u8, line);
                {
                    const gop = try seen.getOrPut(gpa, key);
                    if (gop.found_existing) {
                        gpa.free(key);
                        continue;
                    }
                    gop.key_ptr.* = key;
                    gop.value_ptr.* = {};
                }

                // Resolve objects-dir path under alt_fs.
                const path = if (isAbsPath(line))
                    try gpa.dupe(u8, line)
                else
                    try alt_fs.joinPath(&.{ "/", line });
                defer gpa.free(path);

                const fi = try alt_fs.stat(path);
                if (!fi.isDir()) return error.NotDir;

                // Path is the objects dir; chroot to parent (repo root).
                const parent = pathDir(path);
                // Dupe parent so chroot's toAbs can complete before path is freed... 
                // path still live for this iteration; pathDir is a view into path.
                const chrooted = try alt_fs.chroot(parent);

                const fs_ptr = try gpa.create(Fs);
                fs_ptr.* = chrooted;

                const dg = try gpa.create(Self);
                dg.* = Self.init(gpa, fs_ptr, .{});
                try out.append(gpa, dg);
            }

            if (out.items.len == 0) {
                out.deinit(gpa);
                return &.{};
            }
            const slice = try out.toOwnedSlice(gpa);
            // Ownership transferred; prevent errdefer from freeing slice elements.
            out = .empty;
            return slice;
        }

        /// Free a slice returned by `alternates`. Deinits each DotGit and the
        /// owned chrooted `Fs`, then frees the slice.
        pub fn freeAlternates(gpa: Allocator, list: []*Self) void {
            for (list) |dg| {
                const fs_owned = dg.fs;
                dg.deinit();
                gpa.destroy(dg);
                fs_owned.deinit();
                gpa.destroy(fs_owned);
            }
            if (list.len > 0) gpa.free(list);
        }

        // --- internals ---------------------------------------------------------------

        fn allocator(self: *const Self) Allocator {
            return self.fs.allocator;
        }

        fn setRefFile(self: *Self, file_name: []const u8, content: []const u8, old: ?Reference) !void {
            var mode: u32 = O.RDWR | O.CREATE;
            if (old == null) mode |= O.TRUNC;

            var f = try self.fs.openFile(file_name, mode, 0o666);
            defer f.close() catch {};
            try f.lock();

            try self.checkReferenceAndTruncate(&f, old);
            _ = try f.write(content);
        }

        fn checkReferenceAndTruncate(self: *Self, f: *File, old: ?Reference) !void {
            const o = old orelse return;

            const data = try readAll(self.allocator(), f);
            defer self.allocator().free(data);

            var current: ?Reference = null;
            defer if (current) |cr| freeRef(self.allocator(), cr);

            if (data.len == 0) {
                current = self.packedRef(o.name) catch |err| switch (err) {
                    error.ReferenceNotFound => null,
                    else => |e| return e,
                };
            } else {
                current = try self.readReferenceFrom(data, o.name.string());
            }

            if (current) |c| {
                if (!c.hash.eql(o.hash)) return error.ReferenceHasChanged;
            }

            _ = try f.seek(0, .start);
            try f.truncate(0);
        }

        fn readReferenceFrom(self: *Self, data: []const u8, name: []const u8) !Reference {
            if (data.len == 0) return error.EmptyRefFile;
            const line = std.mem.trim(u8, data, &std.ascii.whitespace);
            if (line.len == 0) return error.EmptyRefFile;
            try validReferenceName(ReferenceName.init(name));
            if (std.mem.startsWith(u8, line, symref_prefix)) {
                const target = line[symref_prefix.len..];
                try validReferenceName(ReferenceName.init(target));
            } else if (!isValidHashText(line)) {
                return error.MalformedRefFile;
            }
            return try ownedReferenceFromStrings(self.allocator(), name, line);
        }

        fn readReferenceFile(self: *Self, base: []const u8, name: []const u8) !Reference {
            const path = try joinRefPath(self.fs, base, name);
            defer self.allocator().free(path);

            const st = try self.fs.stat(path);
            if (st.isDir()) return error.IsDir;
            if (st.size < 0 or st.size > max_loose_ref_size) return error.MalformedRefFile;

            var f = try self.fs.open(path);
            defer f.close() catch {};
            const data = try readAll(self.allocator(), &f);
            defer self.allocator().free(data);
            return try self.readReferenceFrom(data, name);
        }

        fn packedRef(self: *Self, name: ReferenceName) !Reference {
            const data = self.readPackedRefsFile() catch |err| switch (err) {
                error.NotExist => return error.ReferenceNotFound,
                else => |e| return e,
            };
            defer self.allocator().free(data);

            var it = std.mem.splitScalar(u8, data, '\n');
            while (it.next()) |raw_line| {
                const line = std.mem.trimEnd(u8, raw_line, "\r");
                const ref_opt = try self.processLine(line);
                if (ref_opt) |r| {
                    if (r.name.eql(name)) return r;
                    freeRef(self.allocator(), r);
                }
            }
            return error.ReferenceNotFound;
        }

        fn readPackedRefsFile(self: *Self) (Allocator.Error || fs_mod.Error)![]u8 {
            var f = try self.fs.open(packed_refs_path);
            defer f.close() catch {};
            return try readAll(self.allocator(), &f);
        }

        fn processLine(self: *Self, line: []const u8) !?Reference {
            if (line.len == 0) return null;
            switch (line[0]) {
                '#', '^' => return null,
                else => {
                    var parts = std.mem.splitScalar(u8, line, ' ');
                    const hash_s = parts.next() orelse return error.PackedRefsBadFormat;
                    const name_s = parts.next() orelse return error.PackedRefsBadFormat;
                    if (parts.next() != null) return error.PackedRefsBadFormat;
                    if (!isValidHashText(hash_s)) return error.PackedRefsBadFormat;
                    validReferenceName(ReferenceName.init(name_s)) catch
                        return error.PackedRefsBadFormat;
                    return try ownedReferenceFromStrings(self.allocator(), name_s, hash_s);
                },
            }
        }

        fn addRefFromHEAD(self: *Self, list: *std.ArrayList(Reference)) !void {
            const r = self.readReferenceFile(".", "HEAD") catch |err| switch (err) {
                error.NotExist => return,
                else => |e| return e,
            };
            try list.append(self.allocator(), r);
        }

        fn addRefsFromRefDir(self: *Self, list: *std.ArrayList(Reference), seen: *std.StringHashMapUnmanaged(void)) !void {
            try self.walkReferencesTree(list, refs_path, seen);
        }

        fn walkReferencesTree(
            self: *Self,
            list: *std.ArrayList(Reference),
            rel: []const u8,
            seen: *std.StringHashMapUnmanaged(void),
        ) !void {
            const entries = self.fs.readDir(rel) catch |err| switch (err) {
                error.NotExist => return,
                else => |e| return e,
            };
            defer self.fs.freeReadDir(entries);

            for (entries) |e| {
                const child = try self.fs.joinPath(&.{ rel, e.name });
                defer self.allocator().free(child);
                if (e.isDir()) {
                    try self.walkReferencesTree(list, child, seen);
                    continue;
                }
                const r = self.readReferenceFile(".", child) catch |err| switch (err) {
                    error.NotExist => continue,
                    else => |er| return er,
                };
                if (try markSeen(self.allocator(), seen, r.name.string())) {
                    try list.append(self.allocator(), r);
                } else {
                    freeRef(self.allocator(), r);
                }
            }
        }

        fn addRefsFromPackedRefs(self: *Self, list: *std.ArrayList(Reference), seen: *std.StringHashMapUnmanaged(void)) !void {
            const data = self.readPackedRefsFile() catch |err| switch (err) {
                error.NotExist => return,
                else => |e| return e,
            };
            defer self.allocator().free(data);
            try self.consumePackedRefsData(data, list, seen);
        }

        fn addRefsFromPackedRefsFile(
            self: *Self,
            list: *std.ArrayList(Reference),
            f: *File,
            seen: *std.StringHashMapUnmanaged(void),
        ) !void {
            // Rewind for re-read after other ops may have moved the cursor.
            _ = try f.seek(0, .start);
            const data = try readAll(self.allocator(), f);
            defer self.allocator().free(data);
            try self.consumePackedRefsData(data, list, seen);
        }

        fn consumePackedRefsData(
            self: *Self,
            data: []const u8,
            list: *std.ArrayList(Reference),
            seen: *std.StringHashMapUnmanaged(void),
        ) !void {
            var it = std.mem.splitScalar(u8, data, '\n');
            while (it.next()) |raw_line| {
                const line = std.mem.trimEnd(u8, raw_line, "\r");
                const ref_opt = try self.processLine(line);
                if (ref_opt) |r| {
                    if (try markSeen(self.allocator(), seen, r.name.string())) {
                        try list.append(self.allocator(), r);
                    } else {
                        freeRef(self.allocator(), r);
                    }
                }
            }
        }

        fn rewritePackedRefsWithoutRef(self: *Self, name: ReferenceName) !void {
            var pr = self.fs.openFile(packed_refs_path, O.RDWR, 0o600) catch |err| switch (err) {
                error.NotExist => return,
                else => |e| return e,
            };
            defer pr.close() catch {};
            try pr.lock();

            const data = try readAll(self.allocator(), &pr);
            defer self.allocator().free(data);

            var tmp = try self.fs.tempFile("", tmp_packed_refs_prefix);
            const tmp_name = try self.allocator().dupe(u8, tmp.fileName());
            defer self.allocator().free(tmp_name);

            var found = false;
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(self.allocator());

            var it = std.mem.splitScalar(u8, data, '\n');
            while (it.next()) |raw_line| {
                const line = std.mem.trimEnd(u8, raw_line, "\r");
                // Detect matching ref; always parse for format errors on data lines.
                if (line.len > 0 and line[0] != '#' and line[0] != '^') {
                    const ref_opt = try self.processLine(line);
                    if (ref_opt) |r| {
                        defer freeRef(self.allocator(), r);
                        if (r.name.eql(name)) {
                            found = true;
                            continue;
                        }
                    }
                }
                if (out.items.len > 0) try out.append(self.allocator(), '\n');
                try out.appendSlice(self.allocator(), line);
            }
            if (data.len > 0 and out.items.len > 0) {
                // Match go-git Fprintln trailing newline on last kept line.
                try out.append(self.allocator(), '\n');
            }

            _ = try tmp.write(out.items);
            try tmp.close();

            if (!found) {
                self.fs.remove(tmp_name) catch {};
                return;
            }
            try self.rewritePackedRefsWhileLocked(tmp_name, packed_refs_path);
            self.fs.remove(tmp_name) catch {};
        }

        fn rewritePackedRefsWhileLocked(self: *Self, tmp_name: []const u8, pr_name: []const u8) !void {
            self.fs.rename(tmp_name, pr_name) catch |err| switch (err) {
                error.NotSupported => {
                    var src = try self.fs.open(tmp_name);
                    defer src.close() catch {};
                    const body = try readAll(self.allocator(), &src);
                    defer self.allocator().free(body);
                    var dst = try self.fs.create(pr_name);
                    defer dst.close() catch {};
                    _ = try dst.write(body);
                },
                else => |e| return e,
            };
        }

        fn cleanIncoming(self: *Self) void {
            if (self.incoming_dir_name) |name| {
                self.allocator().free(name);
                self.incoming_dir_name = null;
            }
            self.incoming_checked = false;
        }

        fn cleanObjectList(self: *Self) void {
            if (self.object_list) |list| {
                freeHashes(self.allocator(), list);
                self.object_list = null;
            }
            if (self.object_map) |*m| {
                m.deinit(self.allocator());
                self.object_map = null;
            }
        }

        fn cleanPackList(self: *Self) void {
            if (self.pack_list) |list| {
                freeHashes(self.allocator(), list);
                self.pack_list = null;
            }
            if (self.pack_map) |*m| {
                m.deinit(self.allocator());
                self.pack_map = null;
            }
        }

        fn genPackList(self: *Self) !void {
            if (self.pack_map != null) return;
            const op = try self.objectPacksScan();
            errdefer freeHashes(self.allocator(), op);

            var map: HashSet = .empty;
            errdefer map.deinit(self.allocator());
            for (op) |h| try map.put(self.allocator(), h, {});

            self.pack_list = op;
            self.pack_map = map;
        }

        fn hasPack(self: *Self, h: Hash) Error!void {
            if (!self.options.exclusive_access) return;
            self.genPackList() catch return error.PackfileNotFound;
            const map = self.pack_map orelse return error.PackfileNotFound;
            if (!map.contains(h)) return error.PackfileNotFound;
        }

        fn hasObject(self: *Self, h: Hash) (Allocator.Error || fs_mod.Error || plumbing.Error)!void {
            if (!self.options.exclusive_access) return;
            try self.genObjectList();
            const map = self.object_map orelse return error.ObjectNotFound;
            if (!map.contains(h)) return error.ObjectNotFound;
        }

        fn genObjectList(self: *Self) (Allocator.Error || fs_mod.Error)!void {
            if (self.object_map != null) return;

            var list: std.ArrayList(Hash) = .empty;
            errdefer list.deinit(self.allocator());
            try self.collectLooseObjects(&list);

            var map: HashSet = .empty;
            errdefer map.deinit(self.allocator());
            for (list.items) |h| try map.put(self.allocator(), h, {});

            std.mem.sort(Hash, list.items, {}, struct {
                fn less(_: void, a: Hash, b: Hash) bool {
                    return std.mem.order(u8, &a.bytes, &b.bytes) == .lt;
                }
            }.less);

            self.object_list = if (list.items.len == 0) blk: {
                list.deinit(self.allocator());
                break :blk &.{};
            } else try list.toOwnedSlice(self.allocator());
            self.object_map = map;
        }
    };
}

// --- path helpers for Alternates -------------------------------------------------

fn isAbsPath(path: []const u8) bool {
    return path.len > 0 and path[0] == '/';
}

/// Parent directory of a `/`-separated path (go-git `filepath.Dir`).
fn pathDir(path: []const u8) []const u8 {
    if (path.len == 0) return ".";
    // Trim trailing slashes (except root).
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') : (end -= 1) {}
    const p = path[0..end];
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| {
        if (i == 0) return "/";
        return p[0..i];
    }
    return ".";
}

// --- free helpers ----------------------------------------------------------------

/// Free a reference returned by `ref` / `refs` (owned name/target strings).
pub fn freeRef(allocator: Allocator, r: Reference) void {
    if (r.name.raw.len > 0) allocator.free(r.name.raw);
    if (r.type == .symbolic and r.target.raw.len > 0) allocator.free(r.target.raw);
}

/// Free a slice from `refs`.
pub fn freeRefs(allocator: Allocator, list: []Reference) void {
    for (list) |r| freeRef(allocator, r);
    if (list.len > 0) allocator.free(list);
}

/// Free a slice from `objectPacks` / `objects` / `objectsWithPrefix`.
///
/// Safe on static empty slices (`&.{}` / `list.len == 0`): never frees a
/// zero-length slice, matching `freeRefs` / `freeAlternates` / `freeReadDir`.
pub fn freeHashes(allocator: Allocator, list: []Hash) void {
    if (list.len > 0) allocator.free(list);
}

/// Lower-bound index of first hash whose bytes are >= prefix (lexicographic).
fn lowerBoundHashPrefix(list: []const Hash, prefix: []const u8) usize {
    var lo: usize = 0;
    var hi: usize = list.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u8, list[mid].bytes[0..], prefix) == .lt) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

/// Increment a byte slice with carry (go-git `incBytes`). Returns owned copy,
/// or `null` on overflow (e.g. all 0xff). Caller frees non-null result.
fn incBytesAlloc(allocator: Allocator, in: []const u8) Allocator.Error!?[]u8 {
    const out = try allocator.dupe(u8, in);
    errdefer allocator.free(out);
    var i: isize = @intCast(out.len);
    i -= 1;
    while (i >= 0) : (i -= 1) {
        const ui: usize = @intCast(i);
        out[ui] +%= 1;
        if (out[ui] != 0) return out;
    }
    allocator.free(out);
    return null;
}

/// Read entire file into owned buffer (caller frees). Used by filesystem storage.
/// Accepts `*MemFile` / `*OsFile` (any file with `read`).
pub fn readFileAll(allocator: Allocator, f: anytype) (Allocator.Error || fs_mod.Error)![]u8 {
    return try readAll(allocator, f);
}

// --- validation / formatting -----------------------------------------------------

fn validReferenceName(name: ReferenceName) Error!void {
    if (!name.isSafe()) return error.ReferenceNameEscape;
    const s = name.string();
    if (std.mem.startsWith(u8, s, "refs/")) {
        name.validate() catch return error.ReferenceNameEscape;
    }
    for (s) |c| {
        if (c < 0x20 or c == 0x7f) return error.ReferenceNameEscape;
    }
    var it = std.mem.splitAny(u8, s, "/\\");
    while (it.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) {
            return error.ReferenceNameEscape;
        }
        if (std.mem.endsWith(u8, part, ".") or std.mem.endsWith(u8, part, " ")) {
            return error.ReferenceNameEscape;
        }
        if (std.mem.indexOfScalar(u8, part, ':') != null) return error.ReferenceNameEscape;
    }
}

fn isValidHashText(text: []const u8) bool {
    return text.len == plumbing.digestSize() * 2 and isHex(text);
}

fn ownedReferenceFromStrings(allocator: Allocator, name: []const u8, target: []const u8) !Reference {
    const name_owned = try allocator.dupe(u8, name);
    errdefer allocator.free(name_owned);
    if (std.mem.startsWith(u8, target, symref_prefix)) {
        const t = try allocator.dupe(u8, target[symref_prefix.len..]);
        return Reference.newSymbolicReference(
            ReferenceName.init(name_owned),
            ReferenceName.init(t),
        );
    }
    return Reference.newHashReference(
        ReferenceName.init(name_owned),
        plumbing.newHash(target),
    );
}

fn formatRefContent(allocator: Allocator, r: Reference) Allocator.Error![]u8 {
    switch (r.type) {
        .symbolic => return try std.fmt.allocPrint(allocator, "ref: {s}\n", .{r.target.string()}),
        .hash => {
            var hex_buf: [MaxHexSize]u8 = undefined;
            const hex = r.hash.string(&hex_buf);
            return try std.fmt.allocPrint(allocator, "{s}\n", .{hex});
        },
        .invalid => return try allocator.dupe(u8, ""),
    }
}

fn formatRefLineAlloc(allocator: Allocator, r: Reference) Allocator.Error![]u8 {
    // go-git Reference.String: "<target> <name>"
    switch (r.type) {
        .hash => {
            var hex_buf: [MaxHexSize]u8 = undefined;
            const hex = r.hash.string(&hex_buf);
            return try std.fmt.allocPrint(allocator, "{s} {s}", .{ hex, r.name.string() });
        },
        .symbolic => {
            return try std.fmt.allocPrint(allocator, "ref: {s} {s}", .{ r.target.string(), r.name.string() });
        },
        .invalid => return try allocator.dupe(u8, ""),
    }
}

fn joinRefPath(backend: anytype, base: []const u8, name: []const u8) Allocator.Error![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(backend.allocator);
    try parts.append(backend.allocator, base);
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |p| {
        if (p.len == 0) continue;
        try parts.append(backend.allocator, p);
    }
    return try backend.joinPath(parts.items);
}

fn pathUnderModules(p: []const u8) bool {
    if (std.mem.eql(u8, p, module_path) or std.mem.eql(u8, p, "/" ++ module_path)) return true;
    if (std.mem.startsWith(u8, p, module_path ++ "/") or std.mem.startsWith(u8, p, "/" ++ module_path ++ "/")) {
        return std.mem.indexOf(u8, p, "..") == null;
    }
    return false;
}

fn isHex(s: []const u8) bool {
    for (s) |b| {
        const ok = (b >= '0' and b <= '9') or
            (b >= 'a' and b <= 'f') or
            (b >= 'A' and b <= 'F');
        if (!ok) return false;
    }
    return true;
}

fn readAll(allocator: Allocator, f: anytype) (Allocator.Error || fs_mod.Error)![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
    }
    return try list.toOwnedSlice(allocator);
}

/// Insert name into seen set. Returns true if newly inserted.
fn markSeen(allocator: Allocator, seen: *std.StringHashMapUnmanaged(void), name: []const u8) Allocator.Error!bool {
    const key = try allocator.dupe(u8, name);
    const gop = try seen.getOrPut(allocator, key);
    if (gop.found_existing) {
        allocator.free(key);
        return false;
    }
    return true;
}

fn deinitSeen(allocator: Allocator, seen: *std.StringHashMapUnmanaged(void)) void {
    var it = seen.keyIterator();
    while (it.next()) |k| allocator.free(k.*);
    seen.deinit(allocator);
}

// ---------------------------------------------------------------------------
// Incoming / quarantine object paths (go-git TestObject / TestObjectStat / …)
// ---------------------------------------------------------------------------

/// Place a placeholder file at `objects/<incoming_dir>/<aa>/<rest>` (caller closes nothing).
fn placeIncomingObject(backend: anytype, incoming_dir: []const u8, hex: []const u8) !void {
    std.debug.assert(hex.len == HexSize);
    const sub = try backend.joinPath(&.{ objects_path, incoming_dir, hex[0..2] });
    defer backend.allocator.free(sub);
    try backend.mkdirAll(sub, Mode.dir);
    const path = try backend.joinPath(&.{ objects_path, incoming_dir, hex[0..2], hex[2..] });
    defer backend.allocator.free(path);
    var f = try backend.create(path);
    defer f.close() catch {};
    _ = try f.write("incoming-placeholder");
}

test "object finds tmp_objdir-incoming object" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit(fs_mod.Mem).new(&mem);
    defer dg.deinit();
    try dg.initialize();

    // Also place a normal loose object so Object still works for non-incoming.
    const loose_hex = "03db8e1fbe133a480f2867aac478fd866686d69e";
    {
        try mem.mkdirAll("objects/03", Mode.dir);
        var f = try mem.create("objects/03/db8e1fbe133a480f2867aac478fd866686d69e");
        defer f.close() catch {};
        _ = try f.write("loose");
    }
    {
        var f = try dg.object(plumbing.newHash(loose_hex));
        defer f.close() catch {};
    }

    const incoming_hex = "9d25e0f9bde9f82882b49fe29117b9411cb157b7";
    try placeIncomingObject(&mem, "tmp_objdir-incoming-123456", incoming_hex);

    var f = try dg.object(plumbing.newHash(incoming_hex));
    defer f.close() catch {};
    const st = try mem.stat(f.fileName());
    try std.testing.expect(st.isRegular());
    try std.testing.expect(st.size > 0);
}

test "object finds pre-2.35 incoming- dir" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit(fs_mod.Mem).new(&mem);
    defer dg.deinit();
    try dg.initialize();

    const incoming_hex = "9d25e0f9bde9f82882b49fe29117b9411cb157b7";
    try placeIncomingObject(&mem, "incoming-123456", incoming_hex);

    var f = try dg.object(plumbing.newHash(incoming_hex));
    defer f.close() catch {};
}

test "objectStat on incoming object" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit(fs_mod.Mem).new(&mem);
    defer dg.deinit();
    try dg.initialize();

    const incoming_hex = "9d25e0f9bde9f82882b49fe29117b9411cb157b7";
    try placeIncomingObject(&mem, "tmp_objdir-incoming-123456", incoming_hex);

    const st = try dg.objectStat(plumbing.newHash(incoming_hex));
    try std.testing.expect(st.isRegular());
    try std.testing.expect(st.size > 0);
}

test "objectDelete removes incoming object" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit(fs_mod.Mem).new(&mem);
    defer dg.deinit();
    try dg.initialize();

    const incoming_hex = "9d25e0f9bde9f82882b49fe29117b9411cb157b7";
    try placeIncomingObject(&mem, "tmp_objdir-incoming-123456", incoming_hex);
    const h = plumbing.newHash(incoming_hex);

    // Ensure object is findable before delete.
    _ = try dg.objectStat(h);

    try dg.objectDelete(h);
    try std.testing.expectError(error.NotExist, dg.objectStat(h));
}

test "object missing without incoming returns NotExist" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit(fs_mod.Mem).new(&mem);
    defer dg.deinit();
    try dg.initialize();

    try std.testing.expectError(
        error.NotExist,
        dg.object(plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")),
    );
}

test "freeHashes is safe on empty and static slices" {
    const gpa = std.testing.allocator;
    freeHashes(gpa, &.{});
    freeHashes(gpa, @as([]Hash, &.{}));
    const owned = try gpa.alloc(Hash, 1);
    owned[0] = .{};
    freeHashes(gpa, owned);
}
