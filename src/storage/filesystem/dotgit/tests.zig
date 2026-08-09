//! Unit tests for `storage/filesystem/dotgit` (kept out of the package root).
const std = @import("std");
const fs_mod = @import("fs");
const plumbing = @import("plumbing");
const sync = @import("utils/sync");
const dotgit = @import("root.zig");

const Error = dotgit.Error;
const DotGitFor = dotgit.DotGitFor;
const DotGitMem = dotgit.DotGitMem;
const DotGitOs = dotgit.DotGitOs;
const DotGit = dotgit.DotGit;
const Options = dotgit.Options;
const ObjectWriter = dotgit.ObjectWriter;
const ObjectWriterOs = dotgit.ObjectWriterOs;
const ObjectWriterFor = dotgit.ObjectWriterFor;
const PackWriter = dotgit.PackWriter;
const PackWriterOs = dotgit.PackWriterOs;
const PackWriterFor = dotgit.PackWriterFor;
const EncodedObject = dotgit.EncodedObject;
const EncodedObjectOs = dotgit.EncodedObjectOs;
const EncodedObjectReader = dotgit.EncodedObjectReader;
const EncodedObjectFor = dotgit.EncodedObjectFor;
const newEncodedObject = dotgit.newEncodedObject;
const newEncodedObjectOs = dotgit.newEncodedObjectOs;
const newEncodedObjectFor = dotgit.newEncodedObjectFor;
const freeRef = dotgit.freeRef;
const freeRefs = dotgit.freeRefs;
const freeHashes = dotgit.freeHashes;
const freeAlternates = dotgit.freeAlternates;
const freeAlternatesOs = dotgit.freeAlternatesOs;
const readFileAll = dotgit.readFileAll;
const RepositoryFilesystem = dotgit.RepositoryFilesystem;
const RepositoryFilesystemFor = dotgit.RepositoryFilesystemFor;
const RepositoryFilesystemOs = dotgit.RepositoryFilesystemOs;
const newRepositoryFilesystem = dotgit.newRepositoryFilesystem;

// Pull package-root module tests (writers/reader/repo_fs unit tests).
test {
    _ = dotgit;
}

// Unit tests (Mem) — // comments only immediately before test blocks
// ---------------------------------------------------------------------------

// go-git TestInitialize
test "Initialize layout" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    try std.testing.expect((try mem.stat("objects/info")).isDir());
    try std.testing.expect((try mem.stat("objects/pack")).isDir());
    try std.testing.expect((try mem.stat("refs/heads")).isDir());
    try std.testing.expect((try mem.stat("refs/tags")).isDir());
}

// objectPacks on empty pack dir
test "objectPacks empty" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    const packs = try dg.objectPacks();
    defer freeHashes(gpa, packs);
    try std.testing.expectEqual(@as(usize, 0), packs.len);
}

// SetRef / Ref hash + symbolic
test "setRef and ref round-trip" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    const hash_hex = "e8d3ffab552895c19b9fcf7aa264d277cde33881";
    const foo = plumbing.Reference.fromStrings("refs/heads/foo", hash_hex);
    try dg.setRef(foo, null);

    const got = try dg.ref(plumbing.ReferenceName.init("refs/heads/foo"));
    defer freeRef(gpa, got);
    var buf: [plumbing.MaxHexSize]u8 = undefined;
    try std.testing.expectEqualStrings(hash_hex, got.hash.string(&buf));

    const sym = plumbing.Reference.fromStrings("refs/heads/symbolic", "ref: refs/heads/foo");
    try dg.setRef(sym, null);
    const got_sym = try dg.ref(plumbing.ReferenceName.init("refs/heads/symbolic"));
    defer freeRef(gpa, got_sym);
    try std.testing.expect(got_sym.type == .symbolic);
    try std.testing.expectEqualStrings("refs/heads/foo", got_sym.target.string());
}

// Refs lists loose refs
test "refs lists set refs" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    try dg.setRef(plumbing.Reference.fromStrings(
        "refs/heads/foo",
        "e8d3ffab552895c19b9fcf7aa264d277cde33881",
    ), null);
    try dg.setRef(plumbing.Reference.fromStrings(
        "refs/heads/feature/baz",
        "e8d3ffab552895c19b9fcf7aa264d277cde33881",
    ), null);

    const all = try dg.refs();
    defer freeRefs(gpa, all);
    try std.testing.expectEqual(@as(usize, 2), all.len);

    const n = try dg.countLooseRefs();
    try std.testing.expectEqual(@as(usize, 2), n);
}

// Reject escaping / unsafe reference names
test "setRef rejects unsafe names" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    const bad = plumbing.Reference.fromStrings(
        "refs/heads/../../config",
        "e8d3ffab552895c19b9fcf7aa264d277cde33881",
    );
    try std.testing.expectError(error.ReferenceNameEscape, dg.setRef(bad, null));

    const bar = plumbing.Reference.fromStrings(
        "bar",
        "e8d3ffab552895c19b9fcf7aa264d277cde33881",
    );
    try std.testing.expectError(error.ReferenceNameEscape, dg.setRef(bar, null));

    const lock_name = plumbing.Reference.fromStrings(
        "refs/heads/main.lock",
        "e8d3ffab552895c19b9fcf7aa264d277cde33881",
    );
    try std.testing.expectError(error.ReferenceNameEscape, dg.setRef(lock_name, null));

    const unsafe_target = plumbing.Reference.newSymbolicReference(
        plumbing.HEAD,
        plumbing.ReferenceName.init("refs/heads/../../config"),
    );
    try std.testing.expectError(error.ReferenceNameEscape, dg.setRef(unsafe_target, null));
}

test "ref rejects malformed loose object id" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    var f = try mem.create("refs/heads/bad");
    _ = try f.write("not-an-object-id\n");
    try f.close();

    try std.testing.expectError(
        error.MalformedRefFile,
        dg.ref(plumbing.ReferenceName.init("refs/heads/bad")),
    );
}

test "ref rejects oversized loose metadata before allocation" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    const body: [4097]u8 = .{'a'} ** 4097;
    var f = try mem.create("refs/heads/oversized");
    _ = try f.write(&body);
    try f.close();

    try std.testing.expectError(
        error.MalformedRefFile,
        dg.ref(plumbing.ReferenceName.init("refs/heads/oversized")),
    );
}

test "addAlternate rejects line injection" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    try std.testing.expectError(error.InvalidAlternate, dg.addAlternate("../safe\n/escape"));
    try std.testing.expectError(error.InvalidAlternate, dg.addAlternate(""));
}

// check-and-set SetRef
test "setRef old hash check" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    const first = plumbing.Reference.fromStrings(
        "refs/heads/foo",
        "e8d3ffab552895c19b9fcf7aa264d277cde33881",
    );
    try dg.setRef(first, null);

    const next = plumbing.Reference.fromStrings(
        "refs/heads/foo",
        "6ecf0ef2c2dffb796033e5a02219af86ec6584e5",
    );
    try dg.setRef(next, first);

    // stale old must fail
    try std.testing.expectError(error.ReferenceHasChanged, dg.setRef(next, first));
}

// packed-refs round-trip via PackRefs
test "packRefs round-trip" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    const hash_hex = "e8d3ffab552895c19b9fcf7aa264d277cde33881";
    try dg.setRef(plumbing.Reference.fromStrings("refs/heads/foo", hash_hex), null);
    try dg.setRef(plumbing.Reference.fromStrings("refs/tags/v1", hash_hex), null);

    try std.testing.expectEqual(@as(usize, 2), try dg.countLooseRefs());
    try dg.packRefs();
    try std.testing.expectEqual(@as(usize, 0), try dg.countLooseRefs());

    const got = try dg.ref(plumbing.ReferenceName.init("refs/heads/foo"));
    defer freeRef(gpa, got);
    var buf: [plumbing.MaxHexSize]u8 = undefined;
    try std.testing.expectEqualStrings(hash_hex, got.hash.string(&buf));

    // packed-refs file exists and is non-empty
    var pr = try mem.open("packed-refs");
    defer pr.close() catch {};
    var tmp: [256]u8 = undefined;
    const n = try pr.read(&tmp);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, tmp[0..n], "refs/heads/foo") != null);
}

// RemoveRef from packed-refs
test "removeRef from packed" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    const hash_hex = "e8d3ffab552895c19b9fcf7aa264d277cde33881";
    try dg.setRef(plumbing.Reference.fromStrings("refs/heads/foo", hash_hex), null);
    try dg.setRef(plumbing.Reference.fromStrings("refs/heads/bar", hash_hex), null);
    try dg.packRefs();

    try dg.removeRef(plumbing.ReferenceName.init("refs/heads/foo"));
    try std.testing.expectError(
        error.ReferenceNotFound,
        dg.ref(plumbing.ReferenceName.init("refs/heads/foo")),
    );
    const bar = try dg.ref(plumbing.ReferenceName.init("refs/heads/bar"));
    defer freeRef(gpa, bar);
    try std.testing.expect(bar.type == .hash);
}

// newObject loose object path
test "newObject write loose object" {
    const gpa = std.testing.allocator;
    defer sync.deinitPools(std.testing.allocator);

    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    const content = "hello";
    var w = try dg.newObject();
    try w.writeHeader(.blob, @intCast(content.len));
    _ = try w.write(content);
    const h = w.hash();
    try w.close();

    const expect = plumbing.computeHash(.blob, content);
    try std.testing.expect(h.eql(expect));

    var f = try dg.object(h);
    defer f.close() catch {};
    try std.testing.expect((try mem.stat(f.fileName())).size > 0);

    const path = try dg.objectPath(h);
    defer gpa.free(path);
    try std.testing.expect(std.mem.indexOf(u8, path, "objects/") != null);
}

// config / index / shallow helpers
test "config index shallow writers" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    {
        var cw = try dg.configWriter();
        defer cw.close() catch {};
        _ = try cw.write("[core]\n\trepositoryformatversion = 0\n");
    }
    {
        var cr = try dg.config();
        defer cr.close() catch {};
        var buf: [64]u8 = undefined;
        const n = try cr.read(&buf);
        try std.testing.expect(n > 0);
    }

    {
        var iw = try dg.indexWriter();
        defer iw.close() catch {};
        _ = try iw.write("DIRC");
    }
    {
        var ir = try dg.index();
        defer ir.close() catch {};
        var buf: [4]u8 = undefined;
        _ = try ir.read(&buf);
        try std.testing.expectEqualStrings("DIRC", &buf);
    }

    try std.testing.expect((try dg.shallow()) == null);
    {
        var sw = try dg.shallowWriter();
        defer sw.close() catch {};
        _ = try sw.write("e8d3ffab552895c19b9fcf7aa264d277cde33881\n");
    }
    {
        var sh = try dg.shallow();
        try std.testing.expect(sh != null);
        defer sh.?.close() catch {};
    }

    try std.testing.expect(dg.fsPtr() == &mem);
    try std.testing.expect(dg.filesystem() == &mem);
}

// write packed-refs manually then read
test "packed-refs manual round-trip" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    {
        var f = try mem.create("packed-refs");
        defer f.close() catch {};
        _ = try f.write(
            \\# pack-refs with: peeled fully-peeled sorted
            \\e8d3ffab552895c19b9fcf7aa264d277cde33881 refs/heads/master
            \\6ecf0ef2c2dffb796033e5a02219af86ec6584e5 refs/tags/v1
            \\
        );
    }

    const master = try dg.ref(plumbing.ReferenceName.init("refs/heads/master"));
    defer freeRef(gpa, master);
    var buf: [plumbing.MaxHexSize]u8 = undefined;
    try std.testing.expectEqualStrings(
        "e8d3ffab552895c19b9fcf7aa264d277cde33881",
        master.hash.string(&buf),
    );

    const all = try dg.refs();
    defer freeRefs(gpa, all);
    try std.testing.expectEqual(@as(usize, 2), all.len);
}

// module escape rejection
test "module rejects escape" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();

    try std.testing.expectError(error.ModuleNameEscape, dg.module(".."));
    try std.testing.expectError(error.ModuleNameEscape, dg.module("../x"));

    var mod = try dg.module("foo");
    defer mod.deinit();
    try std.testing.expect(std.mem.indexOf(u8, mod.root(), "modules") != null);
}

// objectPacks lists pack files
test "objectPacks lists pack-HASH.pack" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    const hex = "e8d3ffab552895c19b9fcf7aa264d277cde33881";
    {
        const name = try std.fmt.allocPrint(gpa, "objects/pack/pack-{s}.pack", .{hex});
        defer gpa.free(name);
        var f = try mem.create(name);
        defer f.close() catch {};
        _ = try f.write("PACK");
    }
    {
        const name = try std.fmt.allocPrint(gpa, "objects/pack/pack-{s}.idx", .{hex});
        defer gpa.free(name);
        var f = try mem.create(name);
        defer f.close() catch {};
        _ = try f.write("IDX");
    }

    const packs = try dg.objectPacks();
    defer freeHashes(gpa, packs);
    try std.testing.expectEqual(@as(usize, 1), packs.len);
    try std.testing.expect(packs[0].eql(plumbing.newHash(hex)));

    var pf = try dg.objectPack(packs[0]);
    defer pf.close() catch {};
    var pidx = try dg.objectPackIdx(packs[0]);
    defer pidx.close() catch {};
}

// Nested ref creates intermediate directory (go-git ErrIsDir on that path).
test "feature parent is directory after nested setRef" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    try dg.setRef(plumbing.Reference.fromStrings(
        "refs/heads/feature/baz",
        "e8d3ffab552895c19b9fcf7aa264d277cde33881",
    ), null);
    const path_stat = try mem.stat("refs/heads/feature");
    try std.testing.expect(path_stat.isDir());

    const got = try dg.ref(plumbing.ReferenceName.init("refs/heads/feature/baz"));
    defer freeRef(gpa, got);
    try std.testing.expect(got.type == .hash);
}

// objectStat after newObject
test "objectStat on loose object" {
    const gpa = std.testing.allocator;
    defer sync.deinitPools(gpa);

    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    const content = "stat-me";
    var w = try dg.newObject();
    try w.writeHeader(.blob, @intCast(content.len));
    _ = try w.write(content);
    const h = w.hash();
    try w.close();

    const st = try dg.objectStat(h);
    try std.testing.expect(st.isRegular());
    try std.testing.expect(st.size > 0);
}

// objectsWithPrefix filters by raw hash prefix bytes
test "objectsWithPrefix matches prefix" {
    const gpa = std.testing.allocator;
    defer sync.deinitPools(gpa);

    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    const content = "prefix-test";
    var w = try dg.newObject();
    try w.writeHeader(.blob, @intCast(content.len));
    _ = try w.write(content);
    const h = w.hash();
    try w.close();

    // Full list via empty prefix.
    const all = try dg.objectsWithPrefix(&.{});
    defer freeHashes(gpa, all);
    try std.testing.expectEqual(@as(usize, 1), all.len);

    // First byte of the hash as prefix.
    const prefix = h.bytes[0..1];
    const matched = try dg.objectsWithPrefix(prefix);
    defer freeHashes(gpa, matched);
    try std.testing.expectEqual(@as(usize, 1), matched.len);
    try std.testing.expect(matched[0].eql(h));

    // Flipped first byte cannot match this single object.
    const bad_prefix = [_]u8{h.bytes[0] ^ 0xff};
    const none = try dg.objectsWithPrefix(&bad_prefix);
    defer freeHashes(gpa, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    // Prefix longer than hash size → empty.
    const too_long = try dg.objectsWithPrefix(&[_]u8{0} ** (plumbing.Size + 1));
    defer freeHashes(gpa, too_long);
    try std.testing.expectEqual(@as(usize, 0), too_long.len);
}

// deleteOldObjectPackAndIndex with t=0 always deletes pack+idx
test "deleteOldObjectPackAndIndex removes pack and idx" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    const hex = "e8d3ffab552895c19b9fcf7aa264d277cde33881";
    const h = plumbing.newHash(hex);
    {
        const name = try std.fmt.allocPrint(gpa, "objects/pack/pack-{s}.pack", .{hex});
        defer gpa.free(name);
        var f = try mem.create(name);
        defer f.close() catch {};
        _ = try f.write("PACK");
    }
    {
        const name = try std.fmt.allocPrint(gpa, "objects/pack/pack-{s}.idx", .{hex});
        defer gpa.free(name);
        var f = try mem.create(name);
        defer f.close() catch {};
        _ = try f.write("IDX");
    }

    // t=0 → always delete.
    try dg.deleteOldObjectPackAndIndex(h, 0);

    const packs = try dg.objectPacks();
    defer freeHashes(gpa, packs);
    try std.testing.expectEqual(@as(usize, 0), packs.len);
}

// deleteOldObjectPackAndIndex with future threshold skips (Mem mtime is 0)
test "deleteOldObjectPackAndIndex skips when too new" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    const hex = "6ecf0ef2c2dffb796033e5a02219af86ec6584e5";
    const h = plumbing.newHash(hex);
    {
        const name = try std.fmt.allocPrint(gpa, "objects/pack/pack-{s}.pack", .{hex});
        defer gpa.free(name);
        var f = try mem.create(name);
        defer f.close() catch {};
        _ = try f.write("PACK");
    }
    {
        const name = try std.fmt.allocPrint(gpa, "objects/pack/pack-{s}.idx", .{hex});
        defer gpa.free(name);
        var f = try mem.create(name);
        defer f.close() catch {};
        _ = try f.write("IDX");
    }

    // Mem mtime_sec defaults to 0; threshold -1 means 0 is not older → skip.
    try dg.deleteOldObjectPackAndIndex(h, -1);

    const packs = try dg.objectPacks();
    defer freeHashes(gpa, packs);
    try std.testing.expectEqual(@as(usize, 1), packs.len);
}

// newObjectPack via DotGit: unused writer leaves no packs
test "newObjectPack unused cleans temp" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    var w = try dg.newObjectPack();
    try w.close();

    const packs = try dg.objectPacks();
    defer freeHashes(gpa, packs);
    try std.testing.expectEqual(@as(usize, 0), packs.len);
}

// go-git Alternates: missing file is NotExist (Open failure)
test "alternates missing file is NotExist" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    try std.testing.expectError(error.NotExist, dg.alternates());
}

// go-git Alternates: nested alt under `alt/` with loose blob reachable via alternate DotGit
test "alternates nested alt resolves loose object" {
    const gpa = std.testing.allocator;
    defer sync.deinitPools(gpa);

    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    // Main repo at FS root.
    var main = DotGit.new(&mem);
    defer main.deinit();
    try main.initialize();

    // Nested alternate repo under `alt/`.
    try mem.mkdirAll("alt", fs_mod.Mode.dir);
    var alt_fs = try mem.chroot("alt");
    defer alt_fs.deinit();
    var alt_dg = DotGit.new(&alt_fs);
    defer alt_dg.deinit();
    try alt_dg.initialize();

    const content = "hello-from-alternate";
    var w = try alt_dg.newObject();
    try w.writeHeader(.blob, @intCast(content.len));
    _ = try w.write(content);
    const h = w.hash();
    try w.close();

    // Loose object must be visible on the root Mem under /alt/objects/...
    const loose_path = try alt_dg.objectPath(h);
    defer gpa.free(loose_path);
    // objectPath is relative to alt chroot; verify via alt_fs.
    _ = try alt_fs.stat(loose_path);

    // Register alternate (writes `alt/objects` into objects/info/alternates).
    try main.addAlternate("alt");

    const alts = try main.alternates();
    defer freeAlternates(gpa, alts);
    try std.testing.expectEqual(@as(usize, 1), alts.len);

    // Alternate DotGit can open the loose object by hash.
    var f = try alts[0].object(h);
    defer f.close() catch {};
    const st = try alts[0].objectStat(h);
    try std.testing.expect(st.isRegular());
    try std.testing.expect(st.size > 0);

    // Main alone still lacks the object.
    try std.testing.expectError(error.NotExist, main.object(h));
}

// go-git Alternates: duplicate paths collapse to one DotGit
test "alternates dedupes paths" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var main = DotGit.new(&mem);
    defer main.deinit();
    try main.initialize();

    try mem.mkdirAll("alt/objects", fs_mod.Mode.dir);
    try main.addAlternate("alt");
    try main.addAlternate("alt");

    const alts = try main.alternates();
    defer freeAlternates(gpa, alts);
    try std.testing.expectEqual(@as(usize, 1), alts.len);
}

// go-git Alternates: absolute path under same Mem root
test "alternates absolute path" {
    const gpa = std.testing.allocator;
    defer sync.deinitPools(gpa);

    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var main = DotGit.new(&mem);
    defer main.deinit();
    try main.initialize();

    try mem.mkdirAll("other/objects/info", fs_mod.Mode.dir);
    try mem.mkdirAll("other/objects/pack", fs_mod.Mode.dir);
    var other_fs = try mem.chroot("other");
    defer other_fs.deinit();
    var other_dg = DotGit.new(&other_fs);
    defer other_dg.deinit();
    try other_dg.initialize();

    const content = "abs-alt-blob";
    var w = try other_dg.newObject();
    try w.writeHeader(.blob, @intCast(content.len));
    _ = try w.write(content);
    const h = w.hash();
    try w.close();

    // Manual alternates file with absolute objects path.
    {
        var f = try mem.create("objects/info/alternates");
        defer f.close() catch {};
        _ = try f.write("/other/objects\n");
    }

    const alts = try main.alternates();
    defer freeAlternates(gpa, alts);
    try std.testing.expectEqual(@as(usize, 1), alts.len);

    var obj = try alts[0].object(h);
    defer obj.close() catch {};
}

// ---------------------------------------------------------------------------
// Os + std.Io integration (on-disk .git layout)
// ---------------------------------------------------------------------------

// DotGit(Os) initialize + setRef + read-back via pure Os I/O.
test "Os DotGit initialize setRef and read back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var os_fs = try fs_mod.Os.initFromDir(gpa, io, tmp.dir, "tmp", false);
    defer os_fs.deinit();

    var dg = DotGitOs.new(&os_fs);
    defer dg.deinit();
    try dg.initialize();

    try std.testing.expect((try os_fs.stat("objects/info")).isDir());
    try std.testing.expect((try os_fs.stat("objects/pack")).isDir());
    try std.testing.expect((try os_fs.stat("refs/heads")).isDir());
    try std.testing.expect((try os_fs.stat("refs/tags")).isDir());

    const hash_hex = "e8d3ffab552895c19b9fcf7aa264d277cde33881";
    try dg.setRef(plumbing.Reference.fromStrings("refs/heads/main", hash_hex), null);

    const got = try dg.ref(plumbing.ReferenceName.init("refs/heads/main"));
    defer freeRef(gpa, got);
    var buf: [plumbing.MaxHexSize]u8 = undefined;
    try std.testing.expectEqualStrings(hash_hex, got.hash.string(&buf));

    // Pure Os open of the loose ref path proves bytes hit disk.
    var f = try os_fs.open("refs/heads/main");
    defer f.close() catch {};
    var body: [64]u8 = undefined;
    const n = try f.read(&body);
    try std.testing.expect(std.mem.indexOf(u8, body[0..n], hash_hex) != null);
}

// Write a loose object through DotGit(Os) / ObjectWriter and read it back.
test "Os DotGit newObject write and open loose object" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    defer sync.deinitPools(gpa);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var os_fs = try fs_mod.Os.initFromDir(gpa, io, tmp.dir, "tmp", false);
    defer os_fs.deinit();

    var dg = DotGitOs.new(&os_fs);
    defer dg.deinit();
    try dg.initialize();

    const content = "hello-on-disk";
    var w = try dg.newObject();
    try w.writeHeader(.blob, @intCast(content.len));
    _ = try w.write(content);
    const h = w.hash();
    try w.close();

    const expect = plumbing.computeHash(.blob, content);
    try std.testing.expect(h.eql(expect));

    var f = try dg.object(h);
    defer f.close() catch {};
    // File must exist and be non-empty on the real filesystem.
    const path = try dg.objectPath(h);
    defer gpa.free(path);
    const st = try os_fs.stat(path);
    try std.testing.expect(st.isRegular());
    try std.testing.expect(st.size > 0);

    // Read via Os open (independent of DotGit.object handle).
    var raw = try os_fs.open(path);
    defer raw.close() catch {};
    var buf: [8]u8 = undefined;
    const n = try raw.read(&buf);
    try std.testing.expect(n > 0);
}

// freeAlternates no-op on empty static slice (empty alternates file).
test "freeAlternates empty list" {
    const gpa = std.testing.allocator;
    var mem = try fs_mod.Mem.init(gpa);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    // Empty alternates file (blank) → empty slice.
    try mem.mkdirAll("objects/info", fs_mod.Mode.dir);
    {
        var f = try mem.create("objects/info/alternates");
        defer f.close() catch {};
    }
    const alts = try dg.alternates();
    freeAlternates(gpa, alts);
    try std.testing.expectEqual(@as(usize, 0), alts.len);
}

// EncodedObjectOs / freeAlternates / *Os writers are package-root exports.
test "EncodedObjectOs surface export" {
    try std.testing.expect(@TypeOf(EncodedObjectOs) != void);
    try std.testing.expect(@TypeOf(newEncodedObjectOs) != void);
    try std.testing.expect(@TypeOf(EncodedObjectFor) != void);
    try std.testing.expect(@TypeOf(freeAlternates) != void);
    try std.testing.expect(@TypeOf(freeAlternatesOs) != void);
    try std.testing.expect(@TypeOf(PackWriterOs) != void);
    try std.testing.expect(@TypeOf(ObjectWriterOs) != void);
    try std.testing.expect(@TypeOf(DotGitFor) != void);
    try std.testing.expect(@TypeOf(DotGitMem) != void);
    try std.testing.expect(@TypeOf(RepositoryFilesystemFor) != void);
    try std.testing.expect(@TypeOf(RepositoryFilesystemOs) != void);
}

// Open a minimal hand-written .git structure created purely via Os
// (HEAD + refs + loose empty-blob path), then resolve with DotGit(Os).
test "Os open minimal hand-written .git structure" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var os_fs = try fs_mod.Os.initFromDir(gpa, io, tmp.dir, "tmp", false);
    defer os_fs.deinit();

    // Scaffolding without DotGit.initialize — hand-written layout.
    try os_fs.mkdirAll("objects/info", fs_mod.Mode.dir);
    try os_fs.mkdirAll("objects/pack", fs_mod.Mode.dir);
    try os_fs.mkdirAll("refs/heads", fs_mod.Mode.dir);
    try os_fs.mkdirAll("refs/tags", fs_mod.Mode.dir);

    // Empty blob OID e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
    // Write a tiny placeholder at the loose path (content need not be zlib for path test).
    const empty_blob = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    {
        try os_fs.mkdirAll("objects/e6", fs_mod.Mode.dir);
        var obj = try os_fs.create("objects/e6/9de29bb2d1d6434b8b29ae775ad8c2e48c5391");
        defer obj.close() catch {};
        // Minimal non-empty payload so stat size > 0.
        _ = try obj.write("x");
    }

    {
        var head = try os_fs.create("HEAD");
        defer head.close() catch {};
        _ = try head.write("ref: refs/heads/master\n");
    }
    {
        var master = try os_fs.create("refs/heads/master");
        defer master.close() catch {};
        _ = try master.write(empty_blob ++ "\n");
    }

    var dg = DotGitOs.new(&os_fs);
    defer dg.deinit();

    // Resolve HEAD → symbolic, master → hash.
    const head_ref = try dg.ref(plumbing.ReferenceName.init("HEAD"));
    defer freeRef(gpa, head_ref);
    try std.testing.expect(head_ref.type == .symbolic);
    try std.testing.expectEqualStrings("refs/heads/master", head_ref.target.string());

    const master = try dg.ref(plumbing.ReferenceName.init("refs/heads/master"));
    defer freeRef(gpa, master);
    var hex_buf: [plumbing.MaxHexSize]u8 = undefined;
    try std.testing.expectEqualStrings(empty_blob, master.hash.string(&hex_buf));

    // Loose object path is openable.
    const h = plumbing.newHash(empty_blob);
    var loose = try dg.object(h);
    defer loose.close() catch {};
    const st = try os_fs.stat(loose.fileName());
    try std.testing.expect(st.isRegular());
}
