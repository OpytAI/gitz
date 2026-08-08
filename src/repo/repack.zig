//! Repository.RepackObjects / RepackConfig (go-git `repository.go`).
//!
//! Full path requires a storer with:
//! - **PackedObjectStorer** — `objectPacks`, `deleteOldObjectPackAndIndex`
//! - **PackfileWriter** — `packfileWriter()` (filesystem; not memory)
//! - optional **LooseObjectStorer** — `forEachObjectHash` + `deleteLooseObject`
//!
//! Memory storage implements pack listing as empty and has no PackfileWriter,
//! so `repackObjects` returns `error.PackfileWriterNotSupported` (go-git fails
//! the PackfileWriter type assert after PackedObjectStorer succeeds).

const std = @import("std");
const plumbing = @import("plumbing");
const packfile = @import("packfile");
const gitconfig = @import("gitconfig");
const prune = @import("prune");
const filesystem = @import("filesystem");
const fs_pkg = @import("fs");
const memory = @import("memory");
const sync = @import("utils/sync");
const dotgit = @import("dotgit");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const StorageMem = filesystem.StorageMem;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// go-git `RepackConfig`.
pub const RepackConfig = struct {
    /// When true, pack encoder uses REF deltas; default is OFS deltas
    /// (go-git `UseRefDeltas`).
    use_ref_deltas: bool = false,
    /// When non-null, only delete existing packs whose mtime is **strictly
    /// before** this unix second (go-git `OnlyDeletePacksOlderThan`).
    /// Null / omitted means always delete old packs (go-git zero `time.Time`).
    only_delete_packs_older_than: ?i64 = null,
};

/// Errors specific to repack beyond storer / encode failures.
pub const Error = error{
    /// go-git `ErrPackedObjectsNotSupported` — storer lacks `objectPacks`.
    PackedObjectsNotSupported,
    /// Storer is not a PackfileWriter (go-git createNewObjectPack type assert).
    PackfileWriterNotSupported,
};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// go-git `Repository.RepackObjects` over a generic storer pointer.
///
/// Steps (go-git):
/// 1. List existing packs (`objectPacks`).
/// 2. Walk all refs, encode reachable objects into a new pack via PackfileWriter.
/// 3. Delete packed loose objects when LooseObjectStorer is present.
/// 4. Delete old packs (subject to `only_delete_packs_older_than`).
pub fn repackObjects(allocator: Allocator, sto: anytype, cfg: *const RepackConfig) anyerror!void {
    const Sto = @TypeOf(sto.*);

    if (comptime !@hasDecl(Sto, "objectPacks")) {
        return error.PackedObjectsNotSupported;
    }
    if (comptime !@hasDecl(Sto, "packfileWriter")) {
        return error.PackfileWriterNotSupported;
    }
    if (comptime !@hasDecl(Sto, "deleteOldObjectPackAndIndex")) {
        return error.PackedObjectsNotSupported;
    }

    const packs = try callObjectPacks(sto);
    defer freeObjectPacks(allocator, sto, packs);

    const nh = try createNewObjectPack(allocator, sto, cfg);

    for (packs) |h| {
        if (h.eql(nh)) continue;
        const cutoff: i64 = cfg.only_delete_packs_older_than orelse 0;
        try callDeleteOldPack(sto, h, cutoff);
    }
}

/// go-git `Repository.RepackObjects` free function over filesystem Mem storage.
pub fn repackObjectsFs(allocator: Allocator, sto: *StorageMem, cfg: *const RepackConfig) anyerror!void {
    return repackObjects(allocator, sto, cfg);
}

// ---------------------------------------------------------------------------
// createNewObjectPack
// ---------------------------------------------------------------------------

/// go-git `createNewObjectPack` — walk refs, encode pack, delete packed loose.
fn createNewObjectPack(allocator: Allocator, sto: anytype, cfg: *const RepackConfig) anyerror!Hash {
    const Sto = @TypeOf(sto.*);
    const Walker = prune.ObjectWalkerFor(Sto);

    var walker = Walker.init(allocator, sto);
    defer walker.deinit();
    try walker.walkAllRefs();

    var objs: std.ArrayList(Hash) = .empty;
    defer objs.deinit(allocator);
    var kit = walker.seen.keyIterator();
    while (kit.next()) |h| {
        try objs.append(allocator, h.*);
    }

    // Encode pack image (Encoder needs *Io.Writer; PackWriter is write+close).
    // Same end state as go-git streaming into PackfileWriter: idx built on close.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var store_adapter = StoreAdapter(Sto){ .inner = sto };
    var enc = packfile.Encoder.initFrom(
        allocator,
        &aw.writer,
        StoreAdapter(Sto),
        &store_adapter,
        cfg.use_ref_deltas,
    );
    // Delta selector may use zlib pools; always drain before return.
    defer sync.deinitPools(allocator);

    const pack_window = gitconfig.default_pack_window;
    const nh = try enc.encode(objs.items, pack_window);

    var pw = try sto.packfileWriter();
    const pack_bytes = aw.written();
    if (pack_bytes.len > 0) {
        _ = try pw.write(pack_bytes);
    }
    try pw.close();

    // Prefer packwriter checksum when available (should match encoder trailer).
    const closed_hash = pw.packChecksum();
    const result_hash = if (!closed_hash.isZero()) closed_hash else nh;

    // Delete packed loose objects when LooseObjectStorer methods exist.
    if (comptime @hasDecl(Sto, "forEachObjectHash") and @hasDecl(Sto, "deleteLooseObject")) {
        const DeleteCtx = struct {
            walker: *const Walker,
            sto: *Sto,
            fn cb(self: *@This(), hash: Hash) anyerror!void {
                if (!self.walker.isSeen(hash)) return;
                try self.sto.deleteLooseObject(hash);
            }
        };
        var ctx = DeleteCtx{ .walker = &walker, .sto = sto };
        try sto.forEachObjectHash(&ctx, DeleteCtx.cb);
    }

    return result_hash;
}

// ---------------------------------------------------------------------------
// Store adapter for packfile.Encoder (encodedObject vtable)
// ---------------------------------------------------------------------------

fn StoreAdapter(comptime Sto: type) type {
    return struct {
        inner: *Sto,
        pub fn encodedObject(
            self: *@This(),
            t: plumbing.ObjectType,
            h: Hash,
        ) anyerror!*plumbing.MemoryObject {
            return self.inner.encodedObject(t, h);
        }
    };
}

// ---------------------------------------------------------------------------
// Helpers (objectPacks / delete ownership — mirror serverinfo)
// ---------------------------------------------------------------------------

fn callObjectPacks(s: anytype) ![]const Hash {
    const result = s.objectPacks();
    if (comptime @typeInfo(@TypeOf(result)) == .error_union) {
        return try result;
    }
    return result;
}

fn freeObjectPacks(allocator: Allocator, s: anytype, packs: []const Hash) void {
    if (packs.len == 0) return;
    const a = if (comptime @hasField(@TypeOf(s.*), "allocator"))
        s.allocator
    else
        allocator;
    a.free(@constCast(packs));
}

fn callDeleteOldPack(s: anytype, h: Hash, t: i64) !void {
    const result = s.deleteOldObjectPackAndIndex(h, t);
    if (comptime @typeInfo(@TypeOf(result)) == .error_union) {
        try result;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn storeBlob(s: *StorageMem, content: []const u8) !Hash {
    const obj = try s.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write(content);
    return s.setEncodedObject(obj);
}

fn appendTreeEntry(
    buf: *std.ArrayList(u8),
    allocator: Allocator,
    mode_octal: []const u8,
    name: []const u8,
    hash: Hash,
) !void {
    try buf.appendSlice(allocator, mode_octal);
    try buf.append(allocator, ' ');
    try buf.appendSlice(allocator, name);
    try buf.append(allocator, 0);
    try buf.appendSlice(allocator, hash.slice());
}

fn storeTree(s: *StorageMem, allocator: Allocator, entries: []const struct {
    mode: []const u8,
    name: []const u8,
    hash: Hash,
}) !Hash {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (entries) |e| {
        try appendTreeEntry(&buf, allocator, e.mode, e.name, e.hash);
    }
    const obj = try s.newEncodedObject();
    obj.setType(.tree);
    _ = try obj.write(buf.items);
    return s.setEncodedObject(obj);
}

fn storeCommit(
    s: *StorageMem,
    allocator: Allocator,
    tree: Hash,
    parents: []const Hash,
    message: []const u8,
) !Hash {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var tree_hex: [plumbing.MaxHexSize]u8 = undefined;
    try buf.appendSlice(allocator, "tree ");
    try buf.appendSlice(allocator, tree.string(&tree_hex));
    try buf.append(allocator, '\n');

    for (parents) |p| {
        var p_hex: [plumbing.MaxHexSize]u8 = undefined;
        try buf.appendSlice(allocator, "parent ");
        try buf.appendSlice(allocator, p.string(&p_hex));
        try buf.append(allocator, '\n');
    }

    try buf.appendSlice(allocator, "author Test <test@example.com> 1000000000 +0000\n");
    try buf.appendSlice(allocator, "committer Test <test@example.com> 1000000000 +0000\n");
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, message);

    const obj = try s.newEncodedObject();
    obj.setType(.commit);
    _ = try obj.write(buf.items);
    return s.setEncodedObject(obj);
}

fn countLoose(s: *StorageMem) !usize {
    const Count = struct {
        n: usize = 0,
        fn cb(self: *@This(), _: Hash) anyerror!void {
            self.n += 1;
        }
    };
    var c = Count{};
    try s.forEachObjectHash(&c, Count.cb);
    return c.n;
}

fn countPacks(s: *StorageMem) !usize {
    const packs = try s.objectPacks();
    defer dotgit.freeHashes(s.allocator, packs);
    return packs.len;
}

/// Build a small FS repo with one commit and return (blob, tree, commit) hashes.
fn seedRepo(allocator: Allocator, s: *StorageMem, blob_content: []const u8, msg: []const u8) !struct {
    blob: Hash,
    tree: Hash,
    commit: Hash,
} {
    const blob = try storeBlob(s, blob_content);
    const tree = try storeTree(s, allocator, &.{
        .{ .mode = "100644", .name = "f.txt", .hash = blob },
    });
    const commit = try storeCommit(s, allocator, tree, &.{}, msg);
    try s.setReference(plumbing.Reference.newHashReference(plumbing.master, commit));
    return .{ .blob = blob, .tree = tree, .commit = commit };
}

test "repackObjects packs loose and leaves one pack" {
    const gpa = std.testing.allocator;
    defer sync.deinitPools(gpa);

    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    const s = try filesystem.newStorage(gpa, &mem, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    const seeded = try seedRepo(gpa, s, "repack-loose-a", "first");
    try std.testing.expect((try countLoose(s)) >= 3);
    try std.testing.expectEqual(@as(usize, 0), try countPacks(s));

    const cfg = RepackConfig{};
    try repackObjectsFs(gpa, s, &cfg);

    try std.testing.expectEqual(@as(usize, 0), try countLoose(s));
    try std.testing.expectEqual(@as(usize, 1), try countPacks(s));

    // Objects still readable from the new pack.
    try s.hasEncodedObject(seeded.commit);
    try s.hasEncodedObject(seeded.tree);
    try s.hasEncodedObject(seeded.blob);
    const got = try s.encodedObject(.blob, seeded.blob);
    try std.testing.expectEqualStrings("repack-loose-a", got.readerBytes());
}

test "repackObjects collapses multiple packs when deleting all old" {
    const gpa = std.testing.allocator;
    defer sync.deinitPools(gpa);

    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    const s = try filesystem.newStorage(gpa, &mem, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    // First generation: pack reachable set.
    _ = try seedRepo(gpa, s, "gen-1", "c1");
    try repackObjectsFs(gpa, s, &RepackConfig{});
    try std.testing.expectEqual(@as(usize, 1), try countPacks(s));

    // Second generation: new tip objects as loose, then write a second pack
    // via packfileWriter without deleting the first (simulate multi-pack repo).
    const blob2 = try storeBlob(s, "gen-2");
    const tree2 = try storeTree(s, gpa, &.{
        .{ .mode = "100644", .name = "f.txt", .hash = blob2 },
    });
    const parent = blk: {
        const ref = try s.reference(plumbing.master);
        defer dotgit.freeRef(s.allocator, ref);
        break :blk ref.hash;
    };
    const commit2 = try storeCommit(s, gpa, tree2, &.{parent}, "c2");
    try s.setReference(plumbing.Reference.newHashReference(plumbing.master, commit2));

    // Encode only the new objects into a second pack (old pack remains).
    var store_adapter = StoreAdapter(StorageMem){ .inner = s };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = packfile.Encoder.initFrom(gpa, &aw.writer, StoreAdapter(StorageMem), &store_adapter, false);
    _ = try enc.encode(&.{ blob2, tree2, commit2 }, 0);
    var pw = try s.packfileWriter();
    _ = try pw.write(aw.written());
    try pw.close();
    try s.deleteLooseObject(blob2);
    try s.deleteLooseObject(tree2);
    try s.deleteLooseObject(commit2);

    try std.testing.expectEqual(@as(usize, 2), try countPacks(s));
    try std.testing.expectEqual(@as(usize, 0), try countLoose(s));

    // Full repack: delete all old → single pack with full reachable set.
    try repackObjectsFs(gpa, s, &RepackConfig{});
    try std.testing.expectEqual(@as(usize, 1), try countPacks(s));
    try std.testing.expectEqual(@as(usize, 0), try countLoose(s));
    try s.hasEncodedObject(commit2);
    try s.hasEncodedObject(blob2);
    try s.hasEncodedObject(parent);
}

test "repackObjects memory storage returns PackfileWriterNotSupported" {
    const gpa = std.testing.allocator;
    const s = try memory.newStorage(gpa);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    const cfg = RepackConfig{};
    try std.testing.expectError(error.PackfileWriterNotSupported, repackObjects(gpa, s, &cfg));
}

test "RepackConfig defaults" {
    const cfg = RepackConfig{};
    try std.testing.expect(!cfg.use_ref_deltas);
    try std.testing.expect(cfg.only_delete_packs_older_than == null);
}
