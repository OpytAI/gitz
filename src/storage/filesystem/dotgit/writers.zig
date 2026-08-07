//! Loose-object and pack writers for DotGit
//! (go-git `storage/filesystem/dotgit/writers.go`).
//!
//! - `ObjectWriter(Fs)` — zlib loose objects under `objects/xx/yyyy…`
//! - `PackWriter(Fs)` — sequential pack + idx (Zig design: no concurrent syncedReader)
//!
//! Parameterised over a billy-style filesystem type (`Mem`, `Os`) with
//! `pub const File = …` and matching open/mkdir/rename methods.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fs_mod = @import("fs");
const plumbing = @import("plumbing");
const objfile = @import("objfile");
const packfile = @import("packfile");
const idxfile = @import("idxfile");

const Hash = plumbing.Hash;
const HexSize = plumbing.HexSize;
const ObjectType = plumbing.ObjectType;

const objects_path = "objects";

// ---------------------------------------------------------------------------
// ObjectWriter
// ---------------------------------------------------------------------------

/// Writes a new loose object (go-git `ObjectWriter`).
///
/// The allocating `Io.Writer` is heap-pinned so the value may be moved after
/// `open`. Call `close` (or `abandon`) exactly once when finished.
///
/// `Fs` must expose `File`, `allocator`, `mkdirAll`, `tempFile`, `joinPath`,
/// `lstat`, `remove`, and `rename` with the same shapes as `fs.Mem` / `fs.Os`.
pub fn ObjectWriter(comptime Fs: type) type {
    return struct {
        const Self = @This();
        pub const File = Fs.File;

        allocator: Allocator,
        fs: *Fs,
        file: File,
        /// Owned copy of the temp path; valid after `file.close`.
        temp_name: []u8,
        /// Heap-allocated so `objfile.Writer` can hold a stable `*Io.Writer`.
        aw: *std.Io.Writer.Allocating,
        obj: objfile.Writer,
        closed: bool = false,
        /// True after `file` has been closed (name freed on the backend).
        file_closed: bool = false,

        /// go-git `newObjectWriter`.
        pub fn open(backend: *Fs) (Allocator.Error || fs_mod.Error || std.Io.Writer.Error)!Self {
            const allocator = backend.allocator;
            // Temp lives under objects/pack (same as go-git).
            try backend.mkdirAll("objects/pack", fs_mod.Mode.dir);

            var file = try backend.tempFile("objects/pack", "tmp_obj_");
            errdefer file.close() catch {};

            const temp_name = try allocator.dupe(u8, file.fileName());
            errdefer allocator.free(temp_name);

            const aw = try allocator.create(std.Io.Writer.Allocating);
            errdefer allocator.destroy(aw);
            aw.* = try std.Io.Writer.Allocating.initCapacity(allocator, 8192);
            errdefer aw.deinit();

            const obj = try objfile.Writer.open(allocator, &aw.writer);
            return .{
                .allocator = allocator,
                .fs = backend,
                .file = file,
                .temp_name = temp_name,
                .aw = aw,
                .obj = obj,
            };
        }

        /// go-git embedded `objfile.Writer.WriteHeader`.
        pub fn writeHeader(self: *Self, t: ObjectType, size: i64) !void {
            try self.obj.writeHeader(t, size);
        }

        /// go-git embedded `objfile.Writer.Write`.
        pub fn write(self: *Self, p: []const u8) !usize {
            return try self.obj.write(p);
        }

        /// Hash of object data so far (go-git `ObjectWriter.Hash` / embedded Writer).
        pub fn hash(self: *const Self) Hash {
            return self.obj.hash();
        }

        /// Finish zlib, write temp file, rename into `objects/xx/yyyy…` (go-git `Close`).
        pub fn close(self: *Self) !void {
            if (self.closed) return error.Closed;
            self.closed = true;

            // Always release pooled zlib + allocating buffer.
            defer {
                self.aw.deinit();
                self.allocator.destroy(self.aw);
                self.allocator.free(self.temp_name);
                self.temp_name = &.{};
                if (!self.file_closed) {
                    self.file.close() catch {};
                    self.file_closed = true;
                }
            }

            try self.obj.close();

            const data = self.aw.written();
            if (data.len > 0) {
                _ = try self.file.write(data);
            }
            try self.file.close();
            self.file_closed = true;

            try self.save();
        }

        /// Drop without saving (error path).
        pub fn abandon(self: *Self) void {
            if (self.closed) return;
            self.closed = true;
            self.obj.close() catch {};
            self.aw.deinit();
            self.allocator.destroy(self.aw);
            if (!self.file_closed) {
                self.file.close() catch {};
                self.file_closed = true;
            }
            self.fs.remove(self.temp_name) catch {};
            self.allocator.free(self.temp_name);
            self.temp_name = &.{};
        }

        fn save(self: *Self) !void {
            var hex_buf: [HexSize]u8 = undefined;
            const hex = self.hash().string(&hex_buf);

            const dir2 = hex[0..2];
            const rest = hex[2..];
            const final_path = try self.fs.joinPath(&.{ objects_path, dir2, rest });
            defer self.allocator.free(final_path);

            // Content-addressable: if already present, drop the temp file.
            if (self.fs.lstat(final_path)) |_| {
                self.fs.remove(self.temp_name) catch {};
                return;
            } else |err| switch (err) {
                error.NotExist => {},
                else => |e| return e,
            }

            // Ensure fan-out directory exists (rename/create also does this).
            const fanout = try self.fs.joinPath(&.{ objects_path, dir2 });
            defer self.allocator.free(fanout);
            try self.fs.mkdirAll(fanout, fs_mod.Mode.dir);

            try self.fs.rename(self.temp_name, final_path);
        }
    };
}

// ---------------------------------------------------------------------------
// PackWriter (sequential — no concurrent syncedReader)
// ---------------------------------------------------------------------------

/// Writes a new packfile and its idx (go-git `PackWriter`).
///
/// Zig design is sequential (not a concurrent goroutine sync):
/// 1. open temp pack under `objects/pack`
/// 2. `write` accumulates bytes to the temp file
/// 3. `close` re-reads the full pack, runs Scanner/Parser + idxfile.Writer,
///    writes `pack-HASH.idx`, renames temp to `pack-HASH.pack`
///
/// Call `close` or `abandon` exactly once when finished.
pub fn PackWriter(comptime Fs: type) type {
    return struct {
        const Self = @This();
        pub const File = Fs.File;

        allocator: Allocator,
        fs: *Fs,
        file: File,
        /// Owned copy of the temp path; valid after `file.close`.
        temp_name: []u8,
        closed: bool = false,
        file_closed: bool = false,
        bytes_written: u64 = 0,
        checksum: Hash = plumbing.ZeroHash,
        /// Optional notify (go-git `PackWriter.Notify`) after successful save.
        /// Context + fn pointer — no thread-local; caller owns ctx lifetime until close.
        notify_ctx: ?*anyopaque = null,
        notify_fn: ?*const fn (ctx: ?*anyopaque, h: Hash, writer: *idxfile.Writer) void = null,

        /// go-git `newPackWrite`.
        pub fn open(backend: *Fs) (Allocator.Error || fs_mod.Error)!Self {
            const allocator = backend.allocator;
            try backend.mkdirAll("objects/pack", fs_mod.Mode.dir);

            var file = try backend.tempFile("objects/pack", "tmp_pack_");
            errdefer file.close() catch {};

            const temp_name = try allocator.dupe(u8, file.fileName());
            errdefer allocator.free(temp_name);

            return .{
                .allocator = allocator,
                .fs = backend,
                .file = file,
                .temp_name = temp_name,
            };
        }

        /// go-git `PackWriter.Write`.
        pub fn write(self: *Self, p: []const u8) (Allocator.Error || fs_mod.Error)!usize {
            if (self.closed) return error.Closed;
            const n = try self.file.write(p);
            self.bytes_written += n;
            return n;
        }

        /// Finish pack, build idx, rename into place (go-git `Close`).
        /// Empty write cleans the temp file and writes nothing.
        pub fn close(self: *Self) !void {
            if (self.closed) return error.Closed;
            self.closed = true;

            defer {
                self.allocator.free(self.temp_name);
                self.temp_name = &.{};
                if (!self.file_closed) {
                    self.file.close() catch {};
                    self.file_closed = true;
                }
            }

            // Close the write handle so the full content is visible for re-read.
            if (!self.file_closed) {
                try self.file.close();
                self.file_closed = true;
            }

            // Nothing written → clean temp (go-git EmptyPackfile / !Finished path).
            if (self.bytes_written == 0) {
                self.fs.remove(self.temp_name) catch {};
                return;
            }

            // Re-open and read the full pack image.
            const pack_data = try self.readTempPack();
            defer self.allocator.free(pack_data);

            var idx_writer = idxfile.Writer.init(self.allocator);
            defer idx_writer.deinit();

            const checksum = try self.buildIndex(pack_data, &idx_writer);
            self.checksum = checksum;

            if (!idx_writer.isFinished()) {
                self.fs.remove(self.temp_name) catch {};
                return;
            }

            try self.save(&idx_writer);

            if (self.notify_fn) |cb| {
                cb(self.notify_ctx, self.checksum, &idx_writer);
            }
        }

        /// Drop without saving (error path).
        pub fn abandon(self: *Self) void {
            if (self.closed) return;
            self.closed = true;
            if (!self.file_closed) {
                self.file.close() catch {};
                self.file_closed = true;
            }
            self.fs.remove(self.temp_name) catch {};
            self.allocator.free(self.temp_name);
            self.temp_name = &.{};
        }

        /// Pack checksum after a successful `close` (go-git `checksum`).
        pub fn packChecksum(self: *const Self) Hash {
            return self.checksum;
        }

        fn readTempPack(self: *Self) (Allocator.Error || fs_mod.Error)![]u8 {
            var fr = try self.fs.open(self.temp_name);
            defer fr.close() catch {};
            var list: std.ArrayList(u8) = .empty;
            errdefer list.deinit(self.allocator);
            var buf: [8192]u8 = undefined;
            while (true) {
                const n = try fr.read(&buf);
                if (n == 0) break;
                try list.appendSlice(self.allocator, buf[0..n]);
            }
            return try list.toOwnedSlice(self.allocator);
        }

        /// Scanner + Parser + idxfile.Writer observer over the full pack image.
        fn buildIndex(self: *Self, pack_data: []const u8, idx_writer: *idxfile.Writer) !Hash {
            var sc = packfile.Scanner.initSeekable(pack_data);
            var observers = [_]packfile.Observer{
                packfile.Observer.from(idxfile.Writer, idx_writer),
            };
            var parser = try packfile.Parser.init(self.allocator, &sc, observers[0..]);
            defer parser.deinit();

            return parser.parse() catch |err| {
                // go-git waitBuildIndex ignores EmptyPackfile.
                if (err == error.EmptyPackfile) return plumbing.ZeroHash;
                return err;
            };
        }

        fn save(self: *Self, idx_writer: *idxfile.Writer) !void {
            var hex_buf: [HexSize]u8 = undefined;
            const hex = self.checksum.string(&hex_buf);

            const idx_rel = try std.fmt.allocPrint(self.allocator, "objects/pack/pack-{s}.idx", .{hex});
            defer self.allocator.free(idx_rel);
            const pack_rel = try std.fmt.allocPrint(self.allocator, "objects/pack/pack-{s}.pack", .{hex});
            defer self.allocator.free(pack_rel);

            // Content-addressable: skip creating files that already exist.
            if (!(try fileExists(self.fs, idx_rel))) {
                try self.encodeIdx(idx_writer, idx_rel);
            }

            if (!(try fileExists(self.fs, pack_rel))) {
                try self.fs.rename(self.temp_name, pack_rel);
            } else {
                // Pack already exists; drop temp.
                self.fs.remove(self.temp_name) catch {};
            }
        }

        fn encodeIdx(self: *Self, idx_writer: *idxfile.Writer, idx_path: []const u8) !void {
            const idx = try idx_writer.getIndex();
            var aw: std.Io.Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            var enc = idxfile.Encoder.init(&aw.writer);
            _ = try enc.encode(idx);

            var f = try self.fs.create(idx_path);
            defer f.close() catch {};
            const data = aw.written();
            if (data.len > 0) {
                _ = try f.write(data);
            }
        }
    };
}

/// Regular-file existence (go-git `fileExists`).
fn fileExists(backend: anytype, path: []const u8) (Allocator.Error || fs_mod.Error)!bool {
    const fi = backend.lstat(path) catch |err| switch (err) {
        error.NotExist => return false,
        else => |e| return e,
    };
    if (!fi.isRegular()) return error.IsDir; // non-regular: surface as layout error
    return true;
}

// ---------------------------------------------------------------------------
// Tests (// comments only before test blocks — Zig 0.16)
// ---------------------------------------------------------------------------

// go-git ObjectWriter: empty blob lands at objects/e6/9de29b…
test "ObjectWriter empty blob path" {
    const allocator = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(allocator);

    const Mem = fs_mod.Mem;
    const OW = ObjectWriter(Mem);

    var mem = try Mem.init(allocator);
    defer mem.deinit();
    try mem.mkdirAll("objects/pack", fs_mod.Mode.dir);

    var w = try OW.open(&mem);
    try w.writeHeader(.blob, 0);
    try w.close();

    const want = plumbing.newHash("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    var hex_buf: [HexSize]u8 = undefined;
    const hex = want.string(&hex_buf);
    const path = try mem.joinPath(&.{ "objects", hex[0..2], hex[2..] });
    defer allocator.free(path);
    const st = try mem.stat(path);
    try std.testing.expect(st.isRegular());
    try std.testing.expect(st.size > 0);
}

// go-git ObjectWriter: content blob hash + path
test "ObjectWriter content blob" {
    const allocator = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(allocator);

    const Mem = fs_mod.Mem;
    const OW = ObjectWriter(Mem);

    var mem = try Mem.init(allocator);
    defer mem.deinit();
    try mem.mkdirAll("objects/pack", fs_mod.Mode.dir);

    const content = "hello";
    var w = try OW.open(&mem);
    try w.writeHeader(.blob, @intCast(content.len));
    _ = try w.write(content);
    const h = w.hash();
    try w.close();

    const expect = plumbing.computeHash(.blob, content);
    try std.testing.expect(h.eql(expect));

    var hex_buf: [HexSize]u8 = undefined;
    const hex = h.string(&hex_buf);
    const path = try mem.joinPath(&.{ "objects", hex[0..2], hex[2..] });
    defer allocator.free(path);
    _ = try mem.stat(path);
}

// go-git TestNewObjectPackUnused: close without write leaves no pack files
test "PackWriter unused cleans temp" {
    const allocator = std.testing.allocator;

    const Mem = fs_mod.Mem;
    const PW = PackWriter(Mem);

    var mem = try Mem.init(allocator);
    defer mem.deinit();
    try mem.mkdirAll("objects/pack", fs_mod.Mode.dir);

    var w = try PW.open(&mem);
    try w.close();

    const entries = try mem.readDir("objects/pack");
    defer mem.freeReadDir(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}

// PackWriter: write a one-object pack via Encoder, then verify pack+idx on disk
test "PackWriter writes pack and idx" {
    const allocator = std.testing.allocator;
    const sync = @import("utils/sync");
    defer sync.deinitPools(allocator);

    // Build a minimal one-object pack in memory (empty commit).
    const pack_bytes = try encodeOneEmptyCommitPack(allocator);
    defer allocator.free(pack_bytes);

    const Mem = fs_mod.Mem;
    const PW = PackWriter(Mem);

    var mem = try Mem.init(allocator);
    defer mem.deinit();
    try mem.mkdirAll("objects/pack", fs_mod.Mode.dir);

    var w = try PW.open(&mem);
    _ = try w.write(pack_bytes);
    try w.close();

    const checksum = w.packChecksum();
    try std.testing.expect(!checksum.isZero());

    var hex_buf: [HexSize]u8 = undefined;
    const hex = checksum.string(&hex_buf);

    const pack_path = try std.fmt.allocPrint(allocator, "objects/pack/pack-{s}.pack", .{hex});
    defer allocator.free(pack_path);
    const idx_path = try std.fmt.allocPrint(allocator, "objects/pack/pack-{s}.idx", .{hex});
    defer allocator.free(idx_path);

    const pst = try mem.stat(pack_path);
    try std.testing.expect(pst.isRegular());
    try std.testing.expectEqual(@as(i64, @intCast(pack_bytes.len)), pst.size);

    const ist = try mem.stat(idx_path);
    try std.testing.expect(ist.isRegular());
    try std.testing.expect(ist.size > 0);

    // Temp pack should be gone.
    const entries = try mem.readDir("objects/pack");
    defer mem.freeReadDir(entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Minimal object store for Encoder tests.
const OneObjStore = struct {
    obj: *plumbing.MemoryObject,

    pub fn encodedObject(self: *OneObjStore, t: plumbing.ObjectType, h: Hash) error{ObjectNotFound}!*plumbing.MemoryObject {
        _ = t;
        if (!self.obj.hash().eql(h)) return error.ObjectNotFound;
        return self.obj;
    }
};

fn encodeOneEmptyCommitPack(allocator: Allocator) ![]u8 {
    const o = try allocator.create(plumbing.MemoryObject);
    errdefer allocator.destroy(o);
    o.* = plumbing.MemoryObject.init(allocator);
    errdefer o.deinit();
    o.setType(.commit);
    try o.setContent(&.{});
    const oh = o.hash();

    var store = OneObjStore{ .obj = o };
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    var enc = packfile.Encoder.initFrom(allocator, &aw.writer, OneObjStore, &store, false);
    _ = try enc.encode(&.{oh}, 0);

    // Free the MemoryObject (store is stack-local).
    o.deinit();
    allocator.destroy(o);

    return try allocator.dupe(u8, aw.written());
}
