//! Package ioutil implements some I/O utility functions.
//!
//! Port of go-git v5.19.2 `utils/ioutil` — minimal surface for phase 1:
//! fixed-buffer readers, empty-stream peek, and defer-friendly close.
//! Context-cancel wrappers are deferred (no go-context dependency yet).

const std = @import("std");
const testing = std.testing;

/// go-git `ErrEmptyReader` (also the error value name for inventory).
pub const EmptyReader = error{EmptyReader};

/// Construct a fixed `std.Io.Reader` over `buf` (go-git `NewReaderFromBuf`).
/// After the buffer is consumed the reader ends.
pub fn newReaderFromBuf(buf: []const u8) std.Io.Reader {
    return std.Io.Reader.fixed(buf);
}

/// Peek one byte of `r` without consuming it (go-git `NonEmptyReader`).
///
/// Returns `error.EmptyReader` when the stream is empty (EOF on first peek).
/// Propagates `error.ReadFailed` from the underlying reader.
/// On success returns the same `*std.Io.Reader` so subsequent reads see all data.
pub fn nonEmptyReader(r: *std.Io.Reader) (EmptyReader || error{ReadFailed})!*std.Io.Reader {
    if (r.bufferedLen() > 0) return r;
    _ = r.peekByte() catch |e| switch (e) {
        error.EndOfStream => return error.EmptyReader,
        error.ReadFailed => return error.ReadFailed,
    };
    return r;
}

/// checkClose calls `closer.close()`.
///
/// If `err` is null and close fails, stores the close error in `err`.
/// If `err` already holds a value, the close error is ignored.
/// Mirrors go-git `ioutil.CheckClose` for defer-style cleanup:
///
/// ```zig
/// var err: ?anyerror = null;
/// defer checkClose(&file, &err);
/// // ... work; on failure set err = e;
/// if (err) |e| return e;
/// ```
///
/// `closer` must provide `close` (value or pointer receiver) returning
/// `anyerror!void` or a compatible error union.
pub fn checkClose(closer: anytype, err: *?anyerror) void {
    closer.close() catch |cerr| {
        if (err.* == null) err.* = cerr;
    };
}

/// ReadCloser pairs a `*std.Io.Reader` with a close callback.
/// Compose readers (e.g. zlib over a pack slice) without context cancel.
pub const ReadCloser = struct {
    reader: *std.Io.Reader,
    close_fn: *const fn (ctx: *anyopaque) anyerror!void,
    ctx: *anyopaque,

    pub fn close(self: *const ReadCloser) anyerror!void {
        return self.close_fn(self.ctx);
    }
};

/// newReadCloser builds a ReadCloser from `reader` and a typed closer pointer.
///
/// `CloserPtr` must be a pointer type whose child has
/// `close(self: CloserPtr) anyerror!void` (or compatible).
pub fn newReadCloser(reader: *std.Io.Reader, closer: anytype) ReadCloser {
    const CloserPtr = @TypeOf(closer);
    const gen = struct {
        fn closeFn(ctx: *anyopaque) anyerror!void {
            const c: CloserPtr = @ptrCast(@alignCast(ctx));
            return c.close();
        }
    };
    return .{
        .reader = reader,
        .close_fn = gen.closeFn,
        .ctx = @ptrCast(closer),
    };
}

/// NopCloser is a closer whose Close always succeeds (go-git WriteNopCloser idea).
pub const NopCloser = struct {
    pub fn close(_: *NopCloser) anyerror!void {
        return;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "newReaderFromBuf reads full buffer then ends" {
    var r = newReaderFromBuf("hello");
    try testing.expectEqual(@as(u8, 'h'), try r.takeByte());
    try testing.expectEqualStrings("ello", try r.take(4));
    try testing.expectError(error.EndOfStream, r.takeByte());
}

test "newReaderFromBuf empty ends immediately" {
    var r = newReaderFromBuf(&.{});
    try testing.expectError(error.EndOfStream, r.takeByte());
}

test "nonEmptyReader empty" {
    var r = newReaderFromBuf(&.{});
    try testing.expectError(error.EmptyReader, nonEmptyReader(&r));
}

test "nonEmptyReader non-empty preserves data" {
    var r = newReaderFromBuf("1");
    const out = try nonEmptyReader(&r);
    try testing.expect(out == &r);
    try testing.expectEqualStrings("1", try r.take(1));
}

test "nonEmptyReader multi-byte" {
    var r = newReaderFromBuf("abc");
    _ = try nonEmptyReader(&r);
    try testing.expectEqualStrings("abc", try r.take(3));
}

test "checkClose stores close error when err is null" {
    var c = FailingCloser{};
    var err: ?anyerror = null;
    checkClose(&c, &err);
    try testing.expect(err != null);
    try testing.expect(err.? == error.CloseFailed);
    try testing.expectEqual(@as(usize, 1), c.calls);
}

test "checkClose ignores close error when err already set" {
    var c = FailingCloser{};
    var err: ?anyerror = error.PriorFailure;
    checkClose(&c, &err);
    try testing.expect(err.? == error.PriorFailure);
    try testing.expectEqual(@as(usize, 1), c.calls);
}

test "checkClose leaves null when close succeeds" {
    var c = NopCloser{};
    var err: ?anyerror = null;
    checkClose(&c, &err);
    try testing.expect(err == null);
}

test "newReadCloser closes underlying" {
    var buf_reader = newReaderFromBuf("x");
    var c = CountingCloser{};
    const rc = newReadCloser(&buf_reader, &c);
    try testing.expectEqual(@as(u8, 'x'), try rc.reader.takeByte());
    try rc.close();
    try testing.expectEqual(@as(usize, 1), c.calls);
}

const FailingCloser = struct {
    calls: usize = 0,
    pub fn close(self: *FailingCloser) anyerror!void {
        self.calls += 1;
        return error.CloseFailed;
    }
};

const CountingCloser = struct {
    calls: usize = 0,
    pub fn close(self: *CountingCloser) anyerror!void {
        self.calls += 1;
    }
};
