//! Loose-object Reader (go-git `plumbing/format/objfile/reader.go`).
//!
//! Inflates a zlib stream, parses the `type SP size NUL` header, then yields
//! object content. Streaming content is hashed with `plumbing.Hasher`.
//!
//! Zlib inflate uses the pooled reader in `//src/utils/sync`. The pool retains
//! the history window and resets the inflater for each loose object.

const std = @import("std");
const Allocator = std.mem.Allocator;
const IoReader = std.Io.Reader;

const plumbing = @import("plumbing");
const sync = @import("utils/sync");

const ObjectType = plumbing.ObjectType;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const Hasher = plumbing.Hasher;
const Error = @import("error.zig").Error;

/// Reads and decodes compressed objfile data from a provided `*std.Io.Reader`.
/// Close does not close the underlying reader.
///
/// go-git: `type Reader struct` / `NewReader` / methods on `*Reader`.
pub const Reader = struct {
    zlib: *sync.ZlibReader,
    hasher: Hasher = undefined,
    /// True after a successful `header` call (go-git: `multi != nil`).
    header_ready: bool = false,
    closed: bool = false,

    /// Open a loose-object reader on `r` (go-git `NewReader`).
    ///
    /// Validates the zlib framing eagerly so empty/garbage input fails here
    /// (go-git `zlib.NewReader` / `Reset` behaviour via `packfile.ErrZLib`).
    pub fn open(allocator: Allocator, r: *IoReader) (Error || error{OutOfMemory})!Reader {
        const zlib = try sync.getZlibReader(allocator, r);
        errdefer sync.putZlibReader(zlib);

        var reader: Reader = .{
            .zlib = zlib,
        };

        // Force zlib header (and first content byte) so open fails on empty
        // or garbage streams — matching go-git NewReader error path.
        _ = reader.zlib.reader().peekByte() catch return error.ZLib;

        return reader;
    }

    /// Reads type and size, then prepares for content reads.
    /// go-git `(*Reader).Header`.
    ///
    /// On invalid type name, returns `error.InvalidType` (go-git
    /// `plumbing.ErrInvalidType` from `ParseObjectType`). On non-integer size
    /// or truncated header, returns `error.Header` (`ErrHeader`).
    pub fn header(self: *Reader) (Error || error{InvalidType})!struct { t: ObjectType, size: i64 } {
        var type_buf: [32]u8 = undefined;
        const type_raw = try self.readUntil(' ', &type_buf);
        // go-git: ParseObjectType error is returned as-is (not ErrHeader).
        const t = ObjectType.parse(type_raw) catch return error.InvalidType;

        var size_buf: [32]u8 = undefined;
        const size_raw = try self.readUntil(0, &size_buf);
        // go-git maps strconv.ParseInt failure to ErrHeader.
        const size = std.fmt.parseInt(i64, size_raw, 10) catch return error.Header;

        self.prepareForRead(t, size);
        return .{ .t = t, .size = size };
    }

    /// Reads content bytes into `p`. Returns `error.HeaderNotRead` if `header`
    /// has not succeeded. Returns `error.EndOfStream` at end of content stream
    /// (go-git `io.EOF`).
    /// go-git `(*Reader).Read`.
    pub fn read(self: *Reader, p: []u8) (Error || error{EndOfStream})!usize {
        if (!self.header_ready) return error.HeaderNotRead;
        if (p.len == 0) return 0;

        const n = self.zlib.reader().readSliceShort(p) catch return error.ZLib;
        if (n == 0) return error.EndOfStream;
        self.hasher.update(p[0..n]);
        return n;
    }

    /// Hash of object data read so far. ZeroHash before successful `header`.
    /// go-git `(*Reader).Hash` (guards nil hasher when Header not ready).
    pub fn hash(self: *const Reader) Hash {
        if (!self.header_ready) return ZeroHash;
        // plumbing.Hasher.sum finalises; copy so further reads still hash.
        var h = self.hasher;
        return h.sum();
    }

    /// Returns the inflater and its history window to the pool. Does not close
    /// the underlying reader. Always succeeds.
    pub fn close(self: *Reader) void {
        if (self.closed) return;
        self.closed = true;
        sync.putZlibReader(self.zlib);
    }

    fn prepareForRead(self: *Reader, t: ObjectType, size: i64) void {
        self.hasher = Hasher.init(t, size);
        self.header_ready = true;
    }

    /// Read bytes until `delim` (exclusive). go-git `readUntil`.
    ///
    /// On EOF before delim, go-git returns `ErrHeader`. Other inflate errors
    /// are also mapped to `error.Header` for header parsing (corrupt streams
    /// surface as header failures in the go-git tests).
    fn readUntil(self: *Reader, delim: u8, buf: []u8) Error![]u8 {
        var n: usize = 0;
        while (true) {
            const b = self.zlib.reader().takeByte() catch return error.Header;
            if (b == delim) return buf[0..n];
            if (n >= buf.len) return error.Header;
            buf[n] = b;
            n += 1;
        }
    }
};
