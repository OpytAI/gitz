//! Unit tests for `storage/filesystem` (kept out of the package root).
const std = @import("std");
const plumbing = @import("plumbing");
const cache_pkg = @import("cache");
const fs_pkg = @import("fs");
const filesystem = @import("root.zig");
const storage_suite = @import("storage_suite");

const newStorage = filesystem.newStorage;
const newStorageWithOptions = filesystem.newStorageWithOptions;
const newStorageOs = filesystem.newStorageOs;
const newStorageOsWithOptions = filesystem.newStorageOsWithOptions;
const newObjectStorage = filesystem.newObjectStorage;
const newObjectStorageWithOptions = filesystem.newObjectStorageWithOptions;
const Storage = filesystem.Storage;
const StorageMem = filesystem.StorageMem;
const StorageOs = filesystem.StorageOs;
const StorageFor = filesystem.StorageFor;
const ObjectStorage = filesystem.ObjectStorage;
const ObjectStorageMem = filesystem.ObjectStorageMem;
const ObjectStorageOs = filesystem.ObjectStorageOs;
const ObjectStorageFor = filesystem.ObjectStorageFor;
const Options = filesystem.Options;
const Index = filesystem.Index;
const implements_packfile_writer = filesystem.implements_packfile_writer;
const implements_delta_object_storer = filesystem.implements_delta_object_storer;
const implements_transactioner = filesystem.implements_transactioner;
const LazyWriter = filesystem.LazyWriter;
const DotGit = filesystem.DotGit;
const DotGitOs = filesystem.DotGitOs;
const DotGitFor = filesystem.DotGitFor;
const freeHashes = @import("dotgit").freeHashes;
const freeRef = @import("dotgit").freeRef;
const freeRefs = @import("dotgit").freeRefs;
const freeAlternates = @import("dotgit").freeAlternates;
const readFileAll = @import("dotgit").readFileAll;
const newDeltaObject = filesystem.newDeltaObject;

// Pull package-root module tests (submodule unit tests).
test {
    _ = filesystem;
}

// ---------------------------------------------------------------------------
// Core Mem backend tests.
// ---------------------------------------------------------------------------

test "Init scaffolding creates layout dirs" {
    const gpa = std.testing.allocator;
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    const s = try newStorage(gpa, &mem, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    try s.initLayout();
    try std.testing.expect((try mem.stat("objects/pack")).isDir());
    try std.testing.expect((try mem.stat("objects/info")).isDir());
    try std.testing.expect((try mem.stat("refs/heads")).isDir());
    try std.testing.expect((try mem.stat("refs/tags")).isDir());
    try std.testing.expect(s.filesystem() == &mem);
}

test "Storage Options wires AlternatesFS into DotGit" {
    const gpa = std.testing.allocator;
    var primary = try fs_pkg.Mem.init(gpa);
    defer primary.deinit();
    var alternates = try fs_pkg.Mem.init(gpa);
    defer alternates.deinit();

    const s = try newStorageWithOptions(gpa, &primary, null, .{
        .alternates_fs = &alternates,
    });
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    try std.testing.expect(s.dir.options.alternates_fs == &alternates);
}

test "type-erased ConfigStorer adapts filesystem storage" {
    const gpa = std.testing.allocator;
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    const storage = try newStorage(gpa, &mem, null);
    defer {
        storage.deinit();
        gpa.destroy(storage);
    }
    const erased = filesystem.configStorerFor(fs_pkg.Mem, storage);
    const cfg = try erased.config();
    try std.testing.expect(!cfg.is_bare);
}

test "setEncodedObject empty blob round-trip" {
    const gpa = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(std.testing.allocator);
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    const s = try newStorage(gpa, &mem, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    const obj = try s.newEncodedObject();
    obj.setType(.blob);
    const h = try s.setEncodedObject(obj);
    var buf: [plumbing.MaxHexSize]u8 = undefined;
    try std.testing.expectEqualStrings(
        "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
        h.string(&buf),
    );

    try s.hasEncodedObject(h);
    const size = try s.encodedObjectSize(h);
    try std.testing.expectEqual(@as(i64, 0), size);

    const got = try s.encodedObject(.blob, h);
    try std.testing.expect(got.hash().eql(h));
    try std.testing.expect(got.object_type == .blob);
}

test "setEncodedObject blob with content round-trip" {
    const gpa = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(std.testing.allocator);
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    const s = try newStorage(gpa, &mem, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    const obj = try s.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write("hello");
    const h = try s.setEncodedObject(obj);

    const got = try s.encodedObject(.blob, h);
    try std.testing.expectEqualStrings("hello", got.readerBytes());
    try std.testing.expect(got.hash().eql(h));
}

test "set/get reference" {
    const gpa = std.testing.allocator;
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    const s = try newStorage(gpa, &mem, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    const target = plumbing.newHash("c3f4688a08fd86f1bf8e055724c84b7a40a09733");
    try s.setReference(plumbing.Reference.fromStrings(
        "refs/heads/main",
        "c3f4688a08fd86f1bf8e055724c84b7a40a09733",
    ));

    const got = try s.reference(plumbing.ReferenceName.init("refs/heads/main"));
    defer {
        // free owned name from disk read
        if (got.name.raw.len > 0) gpa.free(got.name.raw);
        if (got.type == .symbolic and got.target.raw.len > 0) gpa.free(got.target.raw);
    }
    try std.testing.expect(got.hash.eql(target));
    try std.testing.expect(got.type == .hash);
}

test "set/get empty index" {
    const gpa = std.testing.allocator;
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    const s = try newStorage(gpa, &mem, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    // Default empty index when missing.
    const empty = try s.index();
    try std.testing.expectEqual(@as(u32, 2), empty.version);
    try std.testing.expectEqual(@as(usize, 0), empty.entries.items.len);

    // Write empty index and read back (caller owns `idx`).
    var idx_val = Index.init(gpa);
    defer idx_val.deinit();
    idx_val.version = 2;
    try s.setIndex(&idx_val);

    const got = try s.index();
    try std.testing.expectEqual(@as(u32, 2), got.version);
    try std.testing.expectEqual(@as(usize, 0), got.entries.items.len);
}

test "capability flags match go-git filesystem" {
    try std.testing.expect(!implements_transactioner);
    try std.testing.expect(implements_packfile_writer);
    try std.testing.expect(implements_delta_object_storer);
}

test "NewStorageWithOptions exclusive_access" {
    const gpa = std.testing.allocator;
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    var cache = cache_pkg.ObjectLru.initDefault(gpa);
    defer cache.deinit();

    const s = try newStorageWithOptions(gpa, &mem, &cache, .{
        .exclusive_access = true,
        .large_object_threshold = 1024,
    });
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();
    try std.testing.expect(s.object_storage.options.exclusive_access);
    try std.testing.expectEqual(@as(i64, 1024), s.object_storage.options.large_object_threshold);
    // External cache: Storage must not deinit caller's cache (owns_cache false).
    try std.testing.expect(!s.owns_cache);
}

// go-git TestGetFromUnpackedDoesNotCacheLargeObjects
test "large_object_threshold skips object cache" {
    const gpa = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(std.testing.allocator);

    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    var cache = cache_pkg.ObjectLru.initDefault(gpa);
    defer cache.deinit();

    const s = try newStorageWithOptions(gpa, &mem, &cache, .{
        .large_object_threshold = 1, // any non-empty blob is "large"
    });
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    const obj = try s.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write("hello"); // size 5 > 1
    const h = try s.setEncodedObject(obj);

    const got = try s.encodedObject(.blob, h);
    try std.testing.expect(got.hash().eql(h));
    // Large object must not land in the shared cache.
    try std.testing.expect(cache.get(h) == null);

    // Empty blob (size 0) is under threshold and is cache-eligible.
    const empty = try s.newEncodedObject();
    empty.setType(.blob);
    const eh = try s.setEncodedObject(empty);
    _ = try s.encodedObject(.blob, eh);
    try std.testing.expect(cache.get(eh) != null);
}

test "shallow set and get" {
    const gpa = std.testing.allocator;
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    const s = try newStorage(gpa, &mem, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    const h = plumbing.newHash("b66c08ba28aa1f81eb06a1127aa3936ff77e5e2c");
    try s.setShallow(&.{h});
    const got = try s.shallow();
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expect(got[0].eql(h));
}

// ---------------------------------------------------------------------------
// BaseStorageSuite on filesystem.Storage over Mem (go-git storage_test.go)
// ---------------------------------------------------------------------------


/// Factory: fresh Mem + Storage + initLayout per suite case (go-git SetUpTest).
const FilesystemSuiteFactory = struct {
    pub const Storage = StorageMem;

    pub fn create(allocator: std.mem.Allocator) !*StorageMem {
        const mem = try allocator.create(fs_pkg.Mem);
        errdefer allocator.destroy(mem);
        mem.* = try fs_pkg.Mem.init(allocator);
        errdefer mem.deinit();

        const s = try newStorage(allocator, mem, null);
        errdefer {
            s.deinit();
            allocator.destroy(s);
        }
        try s.initLayout();
        return s;
    }

    pub fn destroy(allocator: std.mem.Allocator, s: *StorageMem) void {
        const mem = s.fs;
        s.deinit();
        allocator.destroy(s);
        mem.deinit();
        allocator.destroy(mem);
    }
};

test "BaseStorageSuite (filesystem Mem)" {
    const sync = @import("utils/sync");
    defer sync.deinitPools(std.testing.allocator);
    try storage_suite.runAllWithFactory(std.testing.allocator, FilesystemSuiteFactory);
}

// looseObjectTime / deleteLooseObject / hashesWithPrefix on Mem
test "looseObjectTime deleteLooseObject hashesWithPrefix" {
    const gpa = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(std.testing.allocator);
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    const s = try newStorage(gpa, &mem, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    const a = try s.newEncodedObject();
    a.setType(.blob);
    _ = try a.write("alpha");
    const ha = try s.setEncodedObject(a);

    const b = try s.newEncodedObject();
    b.setType(.blob);
    _ = try b.write("beta");
    const hb = try s.setEncodedObject(b);

    // mtime is 0 on Mem; still a successful stat.
    const t = try s.looseObjectTime(ha);
    try std.testing.expectEqual(@as(i64, 0), t);

    // Prefix of first byte of ha.
    const prefix = ha.bytes[0..1];
    const with_pref = try s.hashesWithPrefix(prefix);
    defer if (with_pref.len > 0) gpa.free(with_pref);
    try std.testing.expect(with_pref.len >= 1);
    var found_a = false;
    for (with_pref) |h| {
        if (h.eql(ha)) found_a = true;
    }
    try std.testing.expect(found_a);

    try s.deleteLooseObject(ha);
    try std.testing.expectError(error.ObjectNotFound, s.hasEncodedObject(ha));
    try std.testing.expectError(error.ObjectNotFound, s.looseObjectTime(ha));

    // Other object still present.
    try s.hasEncodedObject(hb);
}

// Two loose objects, encode a pack, plant pack+idx, delete loose, read via pack
test "encodedObject from planted pack after loose delete" {
    const gpa = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(std.testing.allocator);
    const packfile = @import("packfile");
    const idxfile = @import("idxfile");

    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    const s = try newStorage(gpa, &mem, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    const o1 = try s.newEncodedObject();
    o1.setType(.blob);
    _ = try o1.write("pack-blob-one");
    const h1 = try s.setEncodedObject(o1);

    const o2 = try s.newEncodedObject();
    o2.setType(.blob);
    _ = try o2.write("pack-blob-two");
    const h2 = try s.setEncodedObject(o2);

    // Encode a pack of the two objects (no deltas).
    var store = TestMapStore.init(gpa);
    defer store.deinit();
    try store.put(o1);
    try store.put(o2);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = packfile.Encoder.initFrom(gpa, &aw.writer, TestMapStore, &store, false);
    const checksum = try enc.encode(&.{ h1, h2 }, 0);
    const pack_bytes = aw.written();
    try std.testing.expect(!checksum.isZero());

    // Build idx via Parser + idxfile.Writer observer.
    var idx_writer = idxfile.Writer.init(gpa);
    defer idx_writer.deinit();
    {
        var sc = packfile.Scanner.initSeekable(pack_bytes);
        const observers = [_]packfile.Observer{
            packfile.Observer.from(idxfile.Writer, &idx_writer),
        };
        var parser = try packfile.Parser.init(gpa, &sc, observers[0..]);
        defer parser.deinit();
        _ = try parser.parse();
    }
    const idx = try idx_writer.getIndex();

    var idx_aw: std.Io.Writer.Allocating = .init(gpa);
    defer idx_aw.deinit();
    var idx_enc = idxfile.Encoder.init(&idx_aw.writer);
    _ = try idx_enc.encode(idx);
    const idx_bytes = idx_aw.written();

    // Plant pack + idx under objects/pack/.
    var hex_buf: [plumbing.MaxHexSize]u8 = undefined;
    const hex = checksum.string(&hex_buf);
    {
        const path = try std.fmt.allocPrint(gpa, "objects/pack/pack-{s}.pack", .{hex});
        defer gpa.free(path);
        var f = try mem.create(path);
        defer f.close() catch {};
        _ = try f.write(pack_bytes);
    }
    {
        const path = try std.fmt.allocPrint(gpa, "objects/pack/pack-{s}.idx", .{hex});
        defer gpa.free(path);
        var f = try mem.create(path);
        defer f.close() catch {};
        _ = try f.write(idx_bytes);
    }

    // Remove loose copies so lookup must use the pack.
    try s.deleteLooseObject(h1);
    try s.deleteLooseObject(h2);
    s.reindex();

    try s.hasEncodedObject(h1);
    try s.hasEncodedObject(h2);

    const got1 = try s.encodedObject(.blob, h1);
    try std.testing.expectEqualStrings("pack-blob-one", got1.readerBytes());
    try std.testing.expect(got1.hash().eql(h1));

    const got2 = try s.encodedObject(.any, h2);
    try std.testing.expectEqualStrings("pack-blob-two", got2.readerBytes());

    const sz = try s.encodedObjectSize(h1);
    try std.testing.expectEqual(@as(i64, "pack-blob-one".len), sz);

    // hashesWithPrefix sees pack entries.
    const pref = h1.bytes[0..2];
    const hits = try s.hashesWithPrefix(pref);
    defer if (hits.len > 0) gpa.free(hits);
    var saw = false;
    for (hits) |h| {
        if (h.eql(h1)) saw = true;
    }
    try std.testing.expect(saw);

    // deleteOldObjectPackAndIndex removes pack files.
    try s.deleteOldObjectPackAndIndex(checksum, 0);
    s.reindex();
    try std.testing.expectError(error.ObjectNotFound, s.hasEncodedObject(h1));
}

// newObjectStorage free function
test "newObjectStorage free function" {
    const gpa = std.testing.allocator;
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    var os = newObjectStorage(gpa, &dg, null);
    defer os.deinit();
    try std.testing.expect(os.dir == &dg);
}

// packfileWriter + encode pack of two loose objects, read back via pack path
test "packfileWriter write pack and encodedObject read back" {
    const gpa = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(std.testing.allocator);
    const packfile = @import("packfile");

    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    const s = try newStorage(gpa, &mem, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    const o1 = try s.newEncodedObject();
    o1.setType(.blob);
    _ = try o1.write("via-packfile-writer-a");
    const h1 = try s.setEncodedObject(o1);

    const o2 = try s.newEncodedObject();
    o2.setType(.blob);
    _ = try o2.write("via-packfile-writer-b");
    const h2 = try s.setEncodedObject(o2);

    // Encode pack image of the two objects.
    var store = TestMapStore.init(gpa);
    defer store.deinit();
    try store.put(o1);
    try store.put(o2);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = packfile.Encoder.initFrom(gpa, &aw.writer, TestMapStore, &store, false);
    _ = try enc.encode(&.{ h1, h2 }, 0);
    const pack_bytes = aw.written();

    // Write pack through PackfileWriter (builds idx + renames into place).
    var pw = try s.packfileWriter();
    _ = try pw.write(pack_bytes);
    try pw.close();

    // Remove loose so lookup must use pack.
    try s.deleteLooseObject(h1);
    try s.deleteLooseObject(h2);

    try s.hasEncodedObject(h1);
    const got = try s.encodedObject(.blob, h1);
    try std.testing.expectEqualStrings("via-packfile-writer-a", got.readerBytes());
    try std.testing.expect(got.hash().eql(h1));

    const got2 = try s.encodedObject(.blob, h2);
    try std.testing.expectEqualStrings("via-packfile-writer-b", got2.readerBytes());
}

// PackfileWriter Notify injects live idx: encodedObject works after .idx is deleted.
test "packfileWriter Notify injects idx without disk reload" {
    const gpa = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(std.testing.allocator);
    const packfile = @import("packfile");

    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    const s = try newStorage(gpa, &mem, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    const o1 = try s.newEncodedObject();
    o1.setType(.blob);
    _ = try o1.write("notify-inject-blob");
    const h1 = try s.setEncodedObject(o1);

    var store = TestMapStore.init(gpa);
    defer store.deinit();
    try store.put(o1);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = packfile.Encoder.initFrom(gpa, &aw.writer, TestMapStore, &store, false);
    _ = try enc.encode(&.{h1}, 0);
    const pack_bytes = aw.written();

    var pw = try s.packfileWriter();
    _ = try pw.write(pack_bytes);
    try pw.close();
    const pack_hash = pw.packChecksum();
    try std.testing.expect(!pack_hash.isZero());

    // Notify must have installed the idx under the pack checksum.
    try std.testing.expect(s.object_storage.index != null);
    try std.testing.expect(s.object_storage.index.?.contains(pack_hash));

    // Remove loose + on-disk idx so lookup cannot reload from disk.
    try s.deleteLooseObject(h1);
    {
        var hex_buf: [plumbing.MaxHexSize]u8 = undefined;
        const hex = pack_hash.string(&hex_buf);
        const idx_path = try std.fmt.allocPrint(gpa, "objects/pack/pack-{s}.idx", .{hex});
        defer gpa.free(idx_path);
        try mem.remove(idx_path);
    }

    // Still resolvable via injected in-memory index (would fail if Notify only clearIndex).
    const got = try s.encodedObject(.blob, h1);
    try std.testing.expectEqualStrings("notify-inject-blob", got.readerBytes());
    try std.testing.expect(got.hash().eql(h1));
}

// KeepDescriptors retains pack image; second encodedObject reuses cache entry.
test "keep_descriptors reuses cached pack for second encodedObject" {
    const gpa = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(std.testing.allocator);
    const packfile = @import("packfile");

    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    const s = try newStorageWithOptions(gpa, &mem, null, .{
        .keep_descriptors = true,
    });
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();
    try std.testing.expect(s.object_storage.options.keep_descriptors);

    const o1 = try s.newEncodedObject();
    o1.setType(.blob);
    _ = try o1.write("keep-desc-blob-a");
    const h1 = try s.setEncodedObject(o1);

    const o2 = try s.newEncodedObject();
    o2.setType(.blob);
    _ = try o2.write("keep-desc-blob-b");
    const h2 = try s.setEncodedObject(o2);

    var store = TestMapStore.init(gpa);
    defer store.deinit();
    try store.put(o1);
    try store.put(o2);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = packfile.Encoder.initFrom(gpa, &aw.writer, TestMapStore, &store, false);
    _ = try enc.encode(&.{ h1, h2 }, 0);
    const pack_bytes = aw.written();

    var pw = try s.packfileWriter();
    _ = try pw.write(pack_bytes);
    try pw.close();
    const pack_hash = pw.packChecksum();

    try s.deleteLooseObject(h1);
    try s.deleteLooseObject(h2);

    const got1 = try s.encodedObject(.blob, h1);
    try std.testing.expectEqualStrings("keep-desc-blob-a", got1.readerBytes());

    // Pack image must be retained after first open.
    try std.testing.expect(s.object_storage.packfiles != null);
    try std.testing.expect(s.object_storage.packfiles.?.contains(pack_hash));
    const entry_ptr = s.object_storage.packfiles.?.get(pack_hash).?;

    const got2 = try s.encodedObject(.blob, h2);
    try std.testing.expectEqualStrings("keep-desc-blob-b", got2.readerBytes());

    // Same cache entry reused (pointer stable across second open).
    try std.testing.expect(s.object_storage.packfiles.?.get(pack_hash).? == entry_ptr);

    // close frees cached packs.
    s.object_storage.close();
    try std.testing.expect(s.object_storage.packfiles == null);
}

// Loose blob + distinct packed object: IterEncodedObjects(.any) yields both.
test "iterEncodedObjects loose and pack" {
    const gpa = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(std.testing.allocator);
    const packfile = @import("packfile");

    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    const s = try newStorage(gpa, &mem, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    // Loose-only blob (not placed in the pack).
    const loose_obj = try s.newEncodedObject();
    loose_obj.setType(.blob);
    _ = try loose_obj.write("iter-loose-only");
    const h_loose = try s.setEncodedObject(loose_obj);

    // Object that will exist only in the pack after we delete the loose copy.
    const pack_obj = try s.newEncodedObject();
    pack_obj.setType(.blob);
    _ = try pack_obj.write("iter-pack-only");
    const h_pack = try s.setEncodedObject(pack_obj);

    var store = TestMapStore.init(gpa);
    defer store.deinit();
    try store.put(pack_obj);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = packfile.Encoder.initFrom(gpa, &aw.writer, TestMapStore, &store, false);
    _ = try enc.encode(&.{h_pack}, 0);
    const pack_bytes = aw.written();

    var pw = try s.packfileWriter();
    _ = try pw.write(pack_bytes);
    try pw.close();

    try s.deleteLooseObject(h_pack);

    // Sanity: loose + pack paths resolve independently.
    try s.hasEncodedObject(h_loose);
    try s.hasEncodedObject(h_pack);

    var iter = try s.iterEncodedObjects(.any);
    defer iter.deinit();

    var count: usize = 0;
    var saw_loose = false;
    var saw_pack = false;
    while (iter.next()) |obj| {
        count += 1;
        if (obj.hash().eql(h_loose)) saw_loose = true;
        if (obj.hash().eql(h_pack)) saw_pack = true;
    } else |err| switch (err) {
        error.EndOfStream => {},
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(saw_loose);
    try std.testing.expect(saw_pack);
}

// Type filter: loose blob + packed tree; .blob / .tree / .any / .commit.
test "iterEncodedObjects type filter loose and pack" {
    const gpa = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(std.testing.allocator);
    const packfile = @import("packfile");

    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    const s = try newStorage(gpa, &mem, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    const blob = try s.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write("iter-filter-blob");
    const h_blob = try s.setEncodedObject(blob);

    // Empty tree object (type-only filter; content not parsed).
    const tree = try s.newEncodedObject();
    tree.setType(.tree);
    const h_tree = try s.setEncodedObject(tree);

    var store = TestMapStore.init(gpa);
    defer store.deinit();
    try store.put(tree);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = packfile.Encoder.initFrom(gpa, &aw.writer, TestMapStore, &store, false);
    _ = try enc.encode(&.{h_tree}, 0);

    var pw = try s.packfileWriter();
    _ = try pw.write(aw.written());
    try pw.close();

    try s.deleteLooseObject(h_tree);

    // .blob → only loose blob
    {
        var iter = try s.iterEncodedObjects(.blob);
        defer iter.deinit();
        const o = try iter.next();
        try std.testing.expect(o.object_type == .blob);
        try std.testing.expect(o.hash().eql(h_blob));
        try std.testing.expectError(error.EndOfStream, iter.next());
    }

    // .tree → only packed tree
    {
        var iter = try s.iterEncodedObjects(.tree);
        defer iter.deinit();
        const o = try iter.next();
        try std.testing.expect(o.object_type == .tree);
        try std.testing.expect(o.hash().eql(h_tree));
        try std.testing.expectError(error.EndOfStream, iter.next());
    }

    // .any → both
    {
        var iter = try s.iterEncodedObjects(.any);
        defer iter.deinit();
        var count: usize = 0;
        while (iter.next()) |_| {
            count += 1;
        } else |err| switch (err) {
            error.EndOfStream => {},
        }
        try std.testing.expectEqual(@as(usize, 2), count);
    }

    // .commit → none
    {
        var iter = try s.iterEncodedObjects(.commit);
        defer iter.deinit();
        try std.testing.expectError(error.EndOfStream, iter.next());
    }
}

// ---------------------------------------------------------------------------
// StorageOs over Os.initFromDir + tmpDir (real disk path).
// ---------------------------------------------------------------------------

test "StorageOs initLayout setEncodedObject encodedObject" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const sync = @import("utils/sync");
    defer sync.deinitPools(gpa);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var os_fs = try fs_pkg.Os.initFromDir(gpa, io, tmp.dir, "tmp", false);
    defer os_fs.deinit();

    const s = try newStorageOs(gpa, &os_fs, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }

    try s.initLayout();
    try std.testing.expect((try os_fs.stat("objects/pack")).isDir());
    try std.testing.expect((try os_fs.stat("refs/heads")).isDir());
    try std.testing.expect(s.filesystem() == &os_fs);

    const obj = try s.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write("hello-os-storage");
    const h = try s.setEncodedObject(obj);

    try s.hasEncodedObject(h);
    const got = try s.encodedObject(.blob, h);
    try std.testing.expectEqualStrings("hello-os-storage", got.readerBytes());
    try std.testing.expect(got.hash().eql(h));
}

test "StorageOs setReference and reference" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var os_fs = try fs_pkg.Os.initFromDir(gpa, io, tmp.dir, "tmp", false);
    defer os_fs.deinit();

    const s = try newStorageOs(gpa, &os_fs, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    const target = plumbing.newHash("c3f4688a08fd86f1bf8e055724c84b7a40a09733");
    try s.setReference(plumbing.Reference.fromStrings(
        "refs/heads/main",
        "c3f4688a08fd86f1bf8e055724c84b7a40a09733",
    ));

    const got = try s.reference(plumbing.ReferenceName.init("refs/heads/main"));
    defer {
        if (got.name.raw.len > 0) gpa.free(got.name.raw);
        if (got.type == .symbolic and got.target.raw.len > 0) gpa.free(got.target.raw);
    }
    try std.testing.expect(got.hash.eql(target));
    try std.testing.expect(got.type == .hash);

    // Pure Os open proves bytes hit disk.
    var f = try os_fs.open("refs/heads/main");
    defer f.close() catch {};
    var body: [64]u8 = undefined;
    const n = try f.read(&body);
    try std.testing.expect(std.mem.indexOf(u8, body[0..n], "c3f4688a08fd86f1bf8e055724c84b7a40a09733") != null);
}

test "StorageOs setIndex and index" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var os_fs = try fs_pkg.Os.initFromDir(gpa, io, tmp.dir, "tmp", false);
    defer os_fs.deinit();

    const s = try newStorageOs(gpa, &os_fs, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    // Default empty index when missing.
    const empty = try s.index();
    try std.testing.expectEqual(@as(u32, 2), empty.version);
    try std.testing.expectEqual(@as(usize, 0), empty.entries.items.len);

    var idx_val = Index.init(gpa);
    defer idx_val.deinit();
    idx_val.version = 2;
    try s.setIndex(&idx_val);

    const got = try s.index();
    try std.testing.expectEqual(@as(u32, 2), got.version);
    try std.testing.expectEqual(@as(usize, 0), got.entries.items.len);

    // Index file exists on disk.
    const st = try os_fs.stat("index");
    try std.testing.expect(st.isRegular());
    try std.testing.expect(st.size > 0);
}

test "StorageOs aliases match StorageFor monomorphisation" {
    try std.testing.expect(Storage == StorageMem);
    try std.testing.expect(StorageOs == StorageFor(fs_pkg.Os));
    try std.testing.expect(ObjectStorage == ObjectStorageMem);
    try std.testing.expect(ObjectStorageOs == ObjectStorageFor(fs_pkg.Os));
}

// Main Mem repo + nested alternate under alt/.git; object only in alternate.
// objects/info/alternates points at alt/.git/objects; main finds via EncodedObject.
test "encodedObject finds loose object via DotGit alternates" {
    const gpa = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(gpa);

    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    // Main storage at Mem root.
    const main = try newStorage(gpa, &mem, null);
    defer {
        main.deinit();
        gpa.destroy(main);
    }
    try main.initLayout();

    // Nested alternate repo under alt/.git (same Mem tree, chroot view).
    try mem.mkdirAll("alt/.git", fs_pkg.Mode.dir);
    const alt_fs = try gpa.create(fs_pkg.Mem);
    {
        errdefer gpa.destroy(alt_fs);
        alt_fs.* = try mem.chroot("alt/.git");
    }
    defer {
        alt_fs.deinit();
        gpa.destroy(alt_fs);
    }

    var alt_dg = DotGit.new(alt_fs);
    defer alt_dg.deinit();
    try alt_dg.initialize();

    var alt_os = newObjectStorage(gpa, &alt_dg, null);
    defer alt_os.deinit();

    const blob = try alt_os.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write("only-in-alternate");
    const h = try alt_os.setEncodedObject(blob);

    // Main must not have the object before alternates are registered.
    try std.testing.expectError(error.ObjectNotFound, main.hasEncodedObject(h));
    try std.testing.expectError(error.ObjectNotFound, main.encodedObject(.blob, h));

    // Write objects/info/alternates via AddAlternate (remote + "/objects").
    try main.addAlternate("alt/.git");

    // has / size / encodedObject all consult alternates after local miss.
    try main.hasEncodedObject(h);
    try std.testing.expectEqual(@as(i64, "only-in-alternate".len), try main.encodedObjectSize(h));

    const got = try main.encodedObject(.blob, h);
    try std.testing.expectEqualStrings("only-in-alternate", got.readerBytes());
    try std.testing.expect(got.hash().eql(h));

    // deltaObject miss path also walks alternates.
    const got_delta = try main.deltaObject(.blob, h);
    try std.testing.expectEqualStrings("only-in-alternate", got_delta.readerBytes());
}

// go-git LazyWriter: writeHeader then content without buffering a MemoryObject first
test "lazyWriter writeHeader and content to loose object" {
    const gpa = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(std.testing.allocator);

    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    const s = try newStorage(gpa, &mem, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    const content = "lazy-writer-payload";
    var lw = try s.lazyWriter();
    errdefer lw.abandon();
    try lw.writeHeader(.blob, @intCast(content.len));
    _ = try lw.write(content);
    try lw.close();

    const h = lw.hash();
    try std.testing.expect(!h.isZero());
    try s.hasEncodedObject(h);

    const got = try s.encodedObject(.blob, h);
    try std.testing.expectEqualStrings(content, got.readerBytes());
    try std.testing.expect(got.hash().eql(h));

    // Size path also sees the loose object.
    try std.testing.expectEqual(@as(i64, content.len), try s.encodedObjectSize(h));
}

// deltaObject for loose non-delta objects (same content as encodedObject)
test "deltaObject loose blob round-trip" {
    const gpa = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(std.testing.allocator);

    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    const s = try newStorage(gpa, &mem, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    const obj = try s.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write("delta-object-loose");
    const h = try s.setEncodedObject(obj);

    const got = try s.deltaObject(.blob, h);
    try std.testing.expectEqualStrings("delta-object-loose", got.readerBytes());
    try std.testing.expect(got.hash().eql(h));
    try std.testing.expect(got.object_type == .blob);
    try std.testing.expect(!got.isDeltaObject());

    try std.testing.expectError(error.ObjectNotFound, s.deltaObject(.tree, h));
}

// OFS delta in pack: deltaObject(can_be_delta) returns unresolved ofs_delta
test "deltaObject OFS delta from packfileWriter pack" {
    const gpa = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(std.testing.allocator);
    const packfile = @import("packfile");

    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    const s = try newStorage(gpa, &mem, null);
    defer {
        s.deinit();
        gpa.destroy(s);
    }
    try s.initLayout();

    // Related blobs so OFS delta is worthwhile.
    const base = try s.newEncodedObject();
    base.setType(.blob);
    _ = try base.write("0123456789abcdefghij");
    const h_base = try s.setEncodedObject(base);

    const target = try s.newEncodedObject();
    target.setType(.blob);
    _ = try target.write("0123456789abcdefghijXYZ");
    const h_target = try s.setEncodedObject(target);

    // Build pack with an explicit OFS delta (use_ref_deltas=false).
    const delta_body = try packfile.getDelta(gpa, base, target);
    defer {
        delta_body.deinit();
        gpa.destroy(delta_body);
    }

    const base_otp = try gpa.create(packfile.ObjectToPack);
    defer gpa.destroy(base_otp);
    base_otp.* = packfile.newObjectToPack(base);

    const delta_otp = try gpa.create(packfile.ObjectToPack);
    defer gpa.destroy(delta_otp);
    delta_otp.* = packfile.newDeltaObjectToPack(base_otp, target, delta_body);

    var store = TestMapStore.init(gpa);
    defer store.deinit();
    try store.put(base);
    try store.put(target);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = packfile.Encoder.initFrom(gpa, &aw.writer, TestMapStore, &store, false);
    _ = try enc.encodeObjects(&.{ base_otp, delta_otp });
    const pack_bytes = aw.written();

    var pw = try s.packfileWriter();
    _ = try pw.write(pack_bytes);
    try pw.close();

    // Force pack path only.
    try s.deleteLooseObject(h_base);
    try s.deleteLooseObject(h_target);
    // Drop LRU so DeltaObject/EncodedObject hit the pack, not cached loose blobs.
    if (s.owns_cache) s.cache_storage.clear() else if (s.external_cache) |c| c.clear();

    // Unresolved path first: target is stored as OFS delta in the pack.
    // (Calling encodedObject first would populate the object cache with a
    // resolved blob and shadow the pack delta on subsequent deltaObject.)
    const delta_obj = try s.deltaObject(.any, h_target);
    try std.testing.expect(delta_obj.object_type == .ofs_delta);
    try std.testing.expect(delta_obj.isDeltaObject());
    try std.testing.expect(delta_obj.baseHash().?.eql(h_base));
    try std.testing.expect(delta_obj.actualHash().?.eql(h_target));
    try std.testing.expect(delta_obj.readerBytes().len > 0);

    // Resolved path returns full blobs.
    const resolved = try s.encodedObject(.blob, h_target);
    try std.testing.expectEqualStrings("0123456789abcdefghijXYZ", resolved.readerBytes());
    try std.testing.expect(resolved.object_type == .blob);

    // Base is a non-delta in the pack; deltaObject still returns a full blob.
    const base_got = try s.deltaObject(.blob, h_base);
    try std.testing.expect(base_got.object_type == .blob);
    try std.testing.expectEqualStrings("0123456789abcdefghij", base_got.readerBytes());
    try std.testing.expect(!base_got.isDeltaObject());
}

// Minimal map store for pack encode tests.
const TestMapStore = struct {
    map: std.AutoHashMapUnmanaged(plumbing.Hash, *plumbing.MemoryObject) = .empty,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) TestMapStore {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TestMapStore) void {
        // Objects are owned by ObjectStorage — do not free them here.
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    fn put(self: *TestMapStore, obj: *plumbing.MemoryObject) !void {
        try self.map.put(self.allocator, obj.hash(), obj);
    }

    pub fn encodedObject(self: *TestMapStore, t: plumbing.ObjectType, h: plumbing.Hash) error{ObjectNotFound}!*plumbing.MemoryObject {
        _ = t;
        return self.map.get(h) orelse error.ObjectNotFound;
    }
};
