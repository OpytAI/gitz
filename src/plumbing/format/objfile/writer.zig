//! Loose-object Writer (go-git `plumbing/format/objfile/writer.go`).
//!
//! Writes a zlib-compressed stream: header `type SP size NUL` then content.
//! Content is hashed with `plumbing.Hasher` as it is written.
//!
//! Compression uses `//src/utils/sync` `getZlibWriter` / `putZlibWriter`
//! (`std.compress.flate` with container `.zlib`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const IoWriter = std.Io.Writer;

const plumbing = @import("plumbing");
const sync = @import("utils/sync");

const ObjectType = plumbing.ObjectType;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const Hasher = plumbing.Hasher;
const Error = @import("error.zig").Error;

/// Writes and encodes data in compressed objfile format.
/// Close does not close the underlying writer.
///
/// go-git: `type Writer struct` / `NewWriter` / methods on `*Writer`.
pub const Writer = struct {
    zlib: *sync.ZlibWriter,
    hasher: Hasher = undefined,
    /// True after a successful `writeHeader` (go-git: multi non-nil).
    header_ready: bool = false,
    closed: bool = false,
    /// Bytes of content still expected after `writeHeader` (go-git `pending`).
    pending: i64 = 0,

    /// Open a loose-object writer on `w` (go-git `NewWriter`).
    ///
    /// `w` must remain valid until `close` and must have buffer capacity greater
    /// than 8 bytes (`flate.Compress` requirement via `getZlibWriter`).
    pub fn open(allocator: Allocator, w: *IoWriter) (error{OutOfMemory} || IoWriter.Error)!Writer {
        const zw = try sync.getZlibWriter(allocator, w);
        return .{
            .zlib = zw,
        };
    }

    /// Writes type and size, then prepares for content.
    /// go-git `(*Writer).WriteHeader`.
    ///
    /// Invalid type → `error.InvalidType` (`plumbing.ErrInvalidType`).
    /// Negative size → `error.NegativeSize` (`ErrNegativeSize`).
    ///
    /// After validation, `prepareForWrite` always runs (go-git `defer`), even
    /// if the zlib write of the header bytes fails.
    pub fn writeHeader(self: *Writer, t: ObjectType, size: i64) (Error || error{InvalidType} || IoWriter.Error)!void {
        if (!t.valid()) return error.InvalidType;
        if (size < 0) return error.NegativeSize;

        // go-git always runs prepareForWrite after a valid header, even if the
        // zlib write fails (defer before Write).
        defer self.prepareForWrite(t, size);

        const zw = self.zlib.writer();
        try zw.writeAll(t.bytes());
        try zw.writeAll(" ");
        var size_buf: [32]u8 = undefined;
        const size_str = std.fmt.bufPrint(&size_buf, "{d}", .{size}) catch unreachable;
        try zw.writeAll(size_str);
        try zw.writeAll(&[_]u8{0});
    }

    /// Writes object content. If `p` is longer than remaining declared size,
    /// performs a **truncated write** of the remaining `pending` bytes, then
    /// returns `error.Overflow`.
    ///
    /// # Overflow semantics vs go-git
    ///
    /// go-git `(*Writer).Write`:
    /// ```
    /// n, err = w.multi.Write(p[0:pending])  // truncated
    /// // returns n == bytes written, err == ErrOverflow
    /// ```
    /// Example from `TestWriteOverflow`: write `"56789"` with `pending==4`
    /// yields `(n=4, err=ErrOverflow)`.
    ///
    /// Zig error unions cannot carry both a success value and an error. On
    /// overflow this method still:
    /// 1. writes only `pending` bytes to zlib and the hasher,
    /// 2. sets `pending` to 0,
    /// 3. returns `error.Overflow` **without** an `n` value.
    ///
    /// Callers that need the truncated length should snapshot `pending` before
    /// the call — that value is the number of bytes that will be written (and
    /// matches go-git's `n` on overflow).
    ///
    /// go-git `(*Writer).Write`.
    pub fn write(self: *Writer, p: []const u8) (Error || IoWriter.Error)!usize {
        if (self.closed) return error.Closed;
        // go-git panics on nil multi if WriteHeader was never called; we
        // return HeaderNotRead instead of accessing uninitialised state.
        if (!self.header_ready) return error.HeaderNotRead;

        var data = p;
        var overflow = false;
        if (@as(i64, @intCast(data.len)) > self.pending) {
            data = data[0..@intCast(self.pending)];
            overflow = true;
        }

        if (data.len > 0) {
            try self.zlib.writer().writeAll(data);
            self.hasher.update(data);
        }
        self.pending -= @intCast(data.len);

        if (overflow) return error.Overflow;
        return data.len;
    }

    /// Hash of object data written so far. ZeroHash before `writeHeader`.
    /// Safe to call before or after `close`. go-git `(*Writer).Hash`.
    ///
    /// go-git calls `hasher.Sum()` even before WriteHeader (zero-value hasher).
    /// We return ZeroHash until header is prepared, matching Reader.Hash guard.
    pub fn hash(self: *const Writer) Hash {
        if (!self.header_ready) return ZeroHash;
        var h = self.hasher;
        return h.sum();
    }

    /// Finishes the zlib stream and returns the compressor to the free list.
    /// Does not close the underlying writer. go-git `(*Writer).Close`.
    pub fn close(self: *Writer) (Error || IoWriter.Error)!void {
        if (self.closed) return error.Closed;
        // Always put the pooled writer back, matching go-git defer PutZlibWriter.
        defer {
            sync.putZlibWriter(self.zlib);
            self.zlib = undefined;
            self.closed = true;
        }
        try self.zlib.finish();
    }

    fn prepareForWrite(self: *Writer, t: ObjectType, size: i64) void {
        self.pending = size;
        self.hasher = Hasher.init(t, size);
        self.header_ready = true;
    }
};
