//! Loose-object Reader (go-git `plumbing/format/objfile/reader.go`).
//!
//! Inflates a zlib stream, parses the `type SP size NUL` header, then yields
//! object content. Streaming content is hashed with `plumbing.Hasher`.
//!
//! Zlib inflate uses `std.compress.flate.Decompress` with container `.zlib`
//! (Zig 0.16 has no `std.compress.zlib`). There is no pooled zlib reader in
//! `//src/utils/sync` yet — only `getZlibWriter` — so the window is owned here.

const std = @import("std");
const flate = std.compress.flate;
const Allocator = std.mem.Allocator;
const IoReader = std.Io.Reader;

const plumbing = @import("plumbing");

const ObjectType = plumbing.ObjectType;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const Hasher = plumbing.Hasher;
const Error = @import("error.zig").Error;

/// Reads and decodes compressed objfile data from a provided `*std.Io.Reader`.
/// Close does not close the underlying reader.
pub const Reader = struct {
    allocator: Allocator,
    decompress: flate.Decompress,
    /// History window for inflate (`flate.max_window_len`). Freed in `close`.
    window: []u8,
    hasher: Hasher = undefined,
    /// True after a successful `header` call (go-git: `multi != nil`).
    header_ready: bool = false,
    closed: bool = false,

    /// Reads type and size, then prepares for content reads.
    /// go-git `(*Reader).Header`.
    pub fn header(self: *Reader) Error!struct { t: ObjectType, size: i64 } {
        var type_buf: [32]u8 = undefined;
        const type_raw = self.readUntil(' ', &type_buf) catch return error.Header;
        const t = ObjectType.parse(type_raw) catch return error.Header;

        var size_buf: [32]u8 = undefined;
        const size_raw = self.readUntil(0, &size_buf) catch return error.Header;
        const size = std.fmt.parseInt(i64, size_raw, 10) catch return error.Header;

        self.prepareForRead(t, size);
        return .{ .t = t, .size = size };
    }

    /// Reads content bytes into `p`. Returns `error.HeaderNotRead` if `header`
    /// has not succeeded. Returns `error.EndOfStream` at end of content.
    /// go-git `(*Reader).Read`.
    pub fn read(self: *Reader, p: []u8) (Error || error{EndOfStream})!usize {
        if (!self.header_ready) return error.HeaderNotRead;
        if (p.len == 0) return 0;

        const n = self.decompress.reader.readSliceShort(p) catch return error.ZLib;
        if (n == 0) return error.EndOfStream;
        self.hasher.update(p[0..n]);
        return n;
    }

    /// Hash of object data read so far. ZeroHash before successful `header`.
    /// go-git `(*Reader).Hash`.
    pub fn hash(self: *const Reader) Hash {
        if (!self.header_ready) return ZeroHash;
        // plumbing.Hasher.sum finalises; copy so further reads still hash.
        var h = self.hasher;
        return h.sum();
    }

    /// Releases the inflate window. Does not close the underlying reader.
    /// go-git `(*Reader).Close`.
    pub fn close(self: *Reader) void {
        if (self.closed) return;
        self.closed = true;
        if (self.window.len != 0) {
            self.allocator.free(self.window);
            self.window = &.{};
        }
    }

    fn prepareForRead(self: *Reader, t: ObjectType, size: i64) void {
        self.hasher = Hasher.init(t, size);
        self.header_ready = true;
    }

    /// Read bytes until `delim` (exclusive). go-git `readUntil`.
    fn readUntil(self: *Reader, delim: u8, buf: []u8) Error![]u8 {
        var n: usize = 0;
        while (true) {
            // Map any inflate/IO failure to Header (go-git returns generic header/zlib errors).
            const b = self.decompress.reader.takeByte() catch return error.Header;
            if (b == delim) return buf[0..n];
            if (n >= buf.len) return error.Header;
            buf[n] = b;
            n += 1;
        }
    }

    /// Open a loose-object reader on `r` (go-git `NewReader`).
    ///
    /// Validates the zlib framing eagerly so empty/garbage input fails here
    /// (go-git `zlib.Reset` behaviour).
    pub fn open(allocator: Allocator, r: *IoReader) (Error || error{OutOfMemory})!Reader {
        const window = try allocator.alloc(u8, flate.max_window_len);
        errdefer allocator.free(window);

        var reader: Reader = .{
            .allocator = allocator,
            .decompress = flate.Decompress.init(r, .zlib, window),
            .window = window,
        };

        // Force zlib header (and first content byte) so open fails on empty
        // or garbage streams.
        _ = reader.decompress.reader.peekByte() catch return error.ZLib;

        return reader;
    }
};
