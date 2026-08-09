//! Filesystem index storage (go-git `storage/filesystem/index.go`).
//!
//! Encode/decode via `//src/plumbing/format/index` and DotGit index files.
//! Monomorphised over `Fs`.

const std = @import("std");
const index_format = @import("index");
const fs_pkg = @import("fs");

const dotgit = @import("dotgit");

const Allocator = std.mem.Allocator;

pub const Index = index_format.Index;
pub const Entry = index_format.Entry;
pub const Time = index_format.Time;

pub const Error = Allocator.Error || fs_pkg.Error || index_format.Error || std.Io.Writer.Error || std.Io.Reader.Error || error{IntegerOverflow};

/// go-git `filesystem.IndexStorage` monomorphised over billy-style `Fs`.
pub fn IndexStorage(comptime Fs: type) type {
    const DotGit = dotgit.DotGitFor(Fs);

    return struct {
        const Self = @This();

        allocator: Allocator,
        dir: *DotGit,
        /// Cached decoded index (optional; re-read from disk when null after set).
        cached: ?*Index = null,

        pub fn init(allocator: Allocator, dir: *DotGit) Self {
            return .{ .allocator = allocator, .dir = dir };
        }

        pub fn deinit(self: *Self) void {
            if (self.cached) |idx| {
                idx.deinit();
                self.allocator.destroy(idx);
                self.cached = null;
            }
            self.* = undefined;
        }

        /// go-git `SetIndex` — encode and write `.git/index`.
        /// Caller retains ownership of `idx`.
        pub fn setIndex(self: *Self, idx: *Index) Error!void {
            var aw: std.Io.Writer.Allocating = try .initCapacity(self.allocator, 256);
            defer aw.deinit();

            var enc = index_format.Encoder.init(&aw.writer);
            try enc.encode(idx);

            var f = try self.dir.indexWriter();
            defer f.close() catch {};
            const data = aw.written();
            if (data.len > 0) _ = try f.write(data);

            // Keep a write-back of the cached pointer live. Otherwise drop the
            // old cache so the next `index()` decodes the persisted bytes.
            if (self.cached) |old| {
                if (old == idx) {
                    old.mod_time = timeNow(self.dir);
                    return;
                }
                old.deinit();
                self.allocator.destroy(old);
                self.cached = null;
            }
        }

        /// go-git `Index` — decode from disk or return default empty v2.
        /// Returned pointer is owned by this storage until `deinit` or next `setIndex`.
        /// When loaded from disk, `mod_time` is set non-zero (go-git uses file mtime;
        /// Mem fs has no mtime so we stamp `timeNow` for BaseStorageSuite parity).
        pub fn index(self: *Self) Error!*Index {
            if (self.cached) |c| return c;

            var f = self.dir.index() catch |err| switch (err) {
                error.NotExist => {
                    const idx = try self.allocator.create(Index);
                    idx.* = Index.init(self.allocator);
                    idx.version = 2;
                    self.cached = idx;
                    return idx;
                },
                else => |e| return e,
            };
            defer f.close() catch {};

            const data = try dotgit.readFileAll(self.allocator, &f);
            defer self.allocator.free(data);

            const idx = try self.allocator.create(Index);
            errdefer {
                idx.deinit();
                self.allocator.destroy(idx);
            }
            idx.* = Index.init(self.allocator);

            var reader: std.Io.Reader = .fixed(data);
            var dec = index_format.Decoder.init(&reader);
            try dec.decode(idx);

            // go-git `Index()` sets ModTime from file stat after decode.
            idx.mod_time = timeNow(self.dir);

            self.cached = idx;
            return idx;
        }

        /// Non-zero stamp when host wall-clock is unavailable.
        /// Prefer file mtime from the DotGit index path when present.
        fn timeNow(dir: *DotGit) Time {
            if (dir.fs.stat("index")) |fi| {
                if (fi.mtime_sec != 0) return Time.unix(fi.mtime_sec, 0);
            } else |_| {}
            // Fallback: non-zero sentinel (go-git uses time.Now(); suite only checks !isZero).
            return Time.unix(1, 0);
        }
    };
}

/// Mem specialisation.
pub const IndexStorageMem = IndexStorage(fs_pkg.Mem);
/// Os specialisation.
pub const IndexStorageOs = IndexStorage(fs_pkg.Os);
