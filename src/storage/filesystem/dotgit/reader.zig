//! Loose EncodedObject for DotGit (go-git `storage/filesystem/dotgit/reader.go`).
//!
//! Large objects can be returned as this type instead of buffering full content
//! into `MemoryObject`. `reader` opens the loose object via DotGit, validates
//! the objfile header against stored type/size, then streams content.
//!
//! Default specialisation is over `DotGit(Mem)`. Use `EncodedObjectFor(DG)` for
//! other DotGit backends (e.g. Os).

const std = @import("std");
const Allocator = std.mem.Allocator;

const fs_mod = @import("fs");
const plumbing = @import("plumbing");
const objfile = @import("objfile");

const dotgit_mod = @import("dotgit.zig");

const Hash = plumbing.Hash;
const ObjectType = plumbing.ObjectType;

/// Content stream after header validation (go-git `EncodedObject.Reader` result).
///
/// Owns compressed file bytes and an `objfile.Reader`. Call `close` exactly
/// once when finished.
pub const EncodedObjectReader = struct {
    allocator: Allocator,
    /// Owned compressed loose-object bytes.
    data: []u8,
    /// Heap-pinned fixed `std.Io.Reader` over `data` (stable for `obj`).
    src: *std.Io.Reader,
    obj: objfile.Reader,
    closed: bool = false,

    /// Read content bytes (go-git `io.ReadCloser.Read` after Header).
    pub fn read(self: *EncodedObjectReader, p: []u8) (objfile.Error || error{EndOfStream})!usize {
        return try self.obj.read(p);
    }

    /// Hash of object data read so far (go-git embedded objfile `Reader.Hash`).
    pub fn hash(self: *const EncodedObjectReader) Hash {
        return self.obj.hash();
    }

    /// Release inflate window, fixed reader, and compressed buffer.
    pub fn close(self: *EncodedObjectReader) void {
        if (self.closed) return;
        self.closed = true;
        self.obj.close();
        self.allocator.destroy(self.src);
        self.allocator.free(self.data);
        self.data = &.{};
    }
};

/// Filesystem-backed encoded object (go-git `dotgit.EncodedObject`).
///
/// `DG` is a monomorphised DotGit type (`DotGit(Mem)`, `DotGit(Os)`, …).
/// Does not buffer content until `reader` is called. `setType` / `setSize` are
/// no-ops; type and size are fixed at construction. `writer` is not supported.
pub fn EncodedObjectFor(comptime DG: type) type {
    return struct {
        const Self = @This();

        dir: *DG,
        h: Hash,
        t: ObjectType,
        sz: i64,

        /// go-git `(*EncodedObject).Hash`.
        pub fn hash(self: *const Self) Hash {
            return self.h;
        }

        /// go-git `(*EncodedObject).Type`.
        pub fn objectType(self: *const Self) ObjectType {
            return self.t;
        }

        /// go-git `(*EncodedObject).Size`.
        pub fn size(self: *const Self) i64 {
            return self.sz;
        }

        /// go-git `(*EncodedObject).SetType` — no-op (type fixed at construction).
        pub fn setType(_: *Self, _: ObjectType) void {}

        /// go-git `(*EncodedObject).SetSize` — no-op (size fixed at construction).
        pub fn setSize(_: *Self, _: i64) void {}

        /// go-git `(*EncodedObject).Writer` — always fails.
        pub fn writer(_: *Self) error{NotSupported}!void {
            return error.NotSupported;
        }

        /// Open loose object and return a content reader (go-git `Reader`).
        ///
        /// Maps missing object to `error.ObjectNotFound`. Validates objfile header
        /// type/size against this object; mismatch → `error.Header`.
        pub fn reader(
            self: *const Self,
            allocator: Allocator,
        ) (Allocator.Error || fs_mod.Error || plumbing.Error || objfile.Error || error{InvalidType})!EncodedObjectReader {
            var f = self.dir.object(self.h) catch |err| switch (err) {
                error.NotExist => return error.ObjectNotFound,
                else => |e| return e,
            };
            defer f.close() catch {};

            const data = try dotgit_mod.readFileAll(allocator, &f);
            errdefer allocator.free(data);

            const src = try allocator.create(std.Io.Reader);
            errdefer allocator.destroy(src);
            src.* = .fixed(data);

            var obj = try objfile.Reader.open(allocator, src);
            errdefer obj.close();

            const hdr = try obj.header();
            if (hdr.t != self.t or hdr.size != self.sz) return error.Header;

            return .{
                .allocator = allocator,
                .data = data,
                .src = src,
                .obj = obj,
            };
        }
    };
}

/// Default EncodedObject over Mem DotGit.
pub const EncodedObject = EncodedObjectFor(dotgit_mod.DotGit(fs_mod.Mem));
/// EncodedObject over Os DotGit (`DotGitOs`).
pub const EncodedObjectOs = EncodedObjectFor(dotgit_mod.DotGit(fs_mod.Os));

/// go-git `NewEncodedObject` (Mem specialisation).
pub fn newEncodedObject(dir: *dotgit_mod.DotGit(fs_mod.Mem), h: Hash, t: ObjectType, size: i64) EncodedObject {
    return .{
        .dir = dir,
        .h = h,
        .t = t,
        .sz = size,
    };
}

/// Construct EncodedObject for an arbitrary DotGit backend.
pub fn newEncodedObjectFor(comptime DG: type, dir: *DG, h: Hash, t: ObjectType, size: i64) EncodedObjectFor(DG) {
    return .{
        .dir = dir,
        .h = h,
        .t = t,
        .sz = size,
    };
}

/// go-git `NewEncodedObject` over Os DotGit.
pub fn newEncodedObjectOs(dir: *dotgit_mod.DotGit(fs_mod.Os), h: Hash, t: ObjectType, size: i64) EncodedObjectOs {
    return newEncodedObjectFor(dotgit_mod.DotGit(fs_mod.Os), dir, h, t, size);
}

// ---------------------------------------------------------------------------
// Tests (// comments only before test blocks — Zig 0.16)
// ---------------------------------------------------------------------------

// go-git EncodedObject: write via ObjectWriter, open EncodedObject, read content
test "EncodedObject reader round-trip content blob" {
    const allocator = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(allocator);

    const DotGit = dotgit_mod.DotGit(fs_mod.Mem);

    var mem = try fs_mod.Mem.init(allocator);
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

    var enc = newEncodedObject(&dg, h, .blob, @intCast(content.len));
    try std.testing.expect(enc.hash().eql(h));
    try std.testing.expect(enc.objectType() == .blob);
    try std.testing.expectEqual(@as(i64, content.len), enc.size());

    // setType / setSize are no-ops
    enc.setType(.commit);
    enc.setSize(999);
    try std.testing.expect(enc.objectType() == .blob);
    try std.testing.expectEqual(@as(i64, content.len), enc.size());

    try std.testing.expectError(error.NotSupported, enc.writer());

    var r = try enc.reader(allocator);
    defer r.close();

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(allocator);
    var tmp: [64]u8 = undefined;
    while (true) {
        const n = r.read(&tmp) catch |e| switch (e) {
            error.EndOfStream => break,
            else => |err| return err,
        };
        try got.appendSlice(allocator, tmp[0..n]);
    }
    try std.testing.expectEqualSlices(u8, content, got.items);
    try std.testing.expect(r.hash().eql(h));
}

// empty blob via EncodedObject
test "EncodedObject reader empty blob" {
    const allocator = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(allocator);

    const DotGit = dotgit_mod.DotGit(fs_mod.Mem);

    var mem = try fs_mod.Mem.init(allocator);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    var w = try dg.newObject();
    try w.writeHeader(.blob, 0);
    const h = w.hash();
    try w.close();

    const want = plumbing.newHash("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    try std.testing.expect(h.eql(want));

    const enc = newEncodedObject(&dg, h, .blob, 0);
    var r = try enc.reader(allocator);
    defer r.close();

    var buf: [8]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, r.read(&buf));
    try std.testing.expect(r.hash().eql(want));
}

// missing object → ObjectNotFound
test "EncodedObject reader missing object" {
    const allocator = std.testing.allocator;

    const DotGit = dotgit_mod.DotGit(fs_mod.Mem);

    var mem = try fs_mod.Mem.init(allocator);
    defer mem.deinit();

    var dg = DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    const missing = plumbing.newHash("e8d3ffab552895c19b9fcf7aa264d277cde33881");
    const enc = newEncodedObject(&dg, missing, .blob, 0);
    try std.testing.expectError(error.ObjectNotFound, enc.reader(allocator));
}

// wrong type/size in EncodedObject metadata → Header
test "EncodedObject reader header mismatch" {
    const allocator = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(allocator);

    const DotGit = dotgit_mod.DotGit(fs_mod.Mem);

    var mem = try fs_mod.Mem.init(allocator);
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

    // Wrong type
    const wrong_type = newEncodedObject(&dg, h, .commit, @intCast(content.len));
    try std.testing.expectError(error.Header, wrong_type.reader(allocator));

    // Wrong size
    const wrong_size = newEncodedObject(&dg, h, .blob, 999);
    try std.testing.expectError(error.Header, wrong_size.reader(allocator));
}

// ---------------------------------------------------------------------------
// Os EncodedObject (DotGitOs) — same surface as Mem via EncodedObjectFor
// ---------------------------------------------------------------------------

// EncodedObjectOs: write loose object on host FS, stream content via reader
test "Os EncodedObject reader round-trip content blob" {
    const allocator = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(allocator);

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var os_fs = try fs_mod.Os.initFromDir(allocator, io, tmp.dir, "tmp", false);
    defer os_fs.deinit();

    var dg = dotgit_mod.DotGit(fs_mod.Os).new(&os_fs);
    defer dg.deinit();
    try dg.initialize();

    const content = "hello-os-encoded";
    var w = try dg.newObject();
    try w.writeHeader(.blob, @intCast(content.len));
    _ = try w.write(content);
    const h = w.hash();
    try w.close();

    var enc = newEncodedObjectOs(&dg, h, .blob, @intCast(content.len));
    try std.testing.expect(enc.hash().eql(h));
    try std.testing.expect(enc.objectType() == .blob);
    try std.testing.expectEqual(@as(i64, content.len), enc.size());
    try std.testing.expectError(error.NotSupported, enc.writer());

    var r = try enc.reader(allocator);
    defer r.close();

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(allocator);
    var tmp_buf: [64]u8 = undefined;
    while (true) {
        const n = r.read(&tmp_buf) catch |e| switch (e) {
            error.EndOfStream => break,
            else => |err| return err,
        };
        try got.appendSlice(allocator, tmp_buf[0..n]);
    }
    try std.testing.expectEqualSlices(u8, content, got.items);
    try std.testing.expect(r.hash().eql(h));
}

// EncodedObjectOs missing object → ObjectNotFound
test "Os EncodedObject reader missing object" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var os_fs = try fs_mod.Os.initFromDir(allocator, io, tmp.dir, "tmp", false);
    defer os_fs.deinit();

    var dg = dotgit_mod.DotGit(fs_mod.Os).new(&os_fs);
    defer dg.deinit();
    try dg.initialize();

    const missing = plumbing.newHash("e8d3ffab552895c19b9fcf7aa264d277cde33881");
    const enc = newEncodedObjectOs(&dg, missing, .blob, 0);
    try std.testing.expectError(error.ObjectNotFound, enc.reader(allocator));
}

// EncodedObjectFor(DotGitOs) via newEncodedObjectFor matches EncodedObjectOs
test "Os EncodedObjectFor newEncodedObjectFor alias" {
    const allocator = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(allocator);

    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var os_fs = try fs_mod.Os.initFromDir(allocator, io, tmp.dir, "tmp", false);
    defer os_fs.deinit();

    const DotGitOs = dotgit_mod.DotGit(fs_mod.Os);
    var dg = DotGitOs.new(&os_fs);
    defer dg.deinit();
    try dg.initialize();

    var w = try dg.newObject();
    try w.writeHeader(.blob, 0);
    const h = w.hash();
    try w.close();

    const enc = newEncodedObjectFor(DotGitOs, &dg, h, .blob, 0);
    try std.testing.expect(@TypeOf(enc) == EncodedObjectOs);
    var r = try enc.reader(allocator);
    defer r.close();
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, r.read(&buf));
}
