//! Package ioutil implements some I/O utility functions.
//!
//! Port of go-git v5.19.2 `utils/ioutil`.

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

/// Writer plus close callback (go-git `NewWriteCloser`).
pub const WriteCloser = struct {
    writer: *std.Io.Writer,
    close_fn: *const fn (ctx: *anyopaque) anyerror!void,
    ctx: *anyopaque,

    pub fn close(self: *const WriteCloser) anyerror!void {
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

pub fn newWriteCloser(writer: *std.Io.Writer, closer: anytype) WriteCloser {
    const CloserPtr = @TypeOf(closer);
    const gen = struct {
        fn closeFn(ctx: *anyopaque) anyerror!void {
            const c: CloserPtr = @ptrCast(@alignCast(ctx));
            return c.close();
        }
    };
    return .{ .writer = writer, .close_fn = gen.closeFn, .ctx = @ptrCast(closer) };
}

/// A read closer with a second cleanup callback. Both closers always run; the
/// first error wins, matching go-git `NewReadCloserWithCloser`.
pub const ChainedReadCloser = struct {
    inner: *ReadCloser,
    close_fn: *const fn (ctx: *anyopaque) anyerror!void,
    ctx: *anyopaque,

    pub fn close(self: *const ChainedReadCloser) anyerror!void {
        self.inner.close() catch |first| {
            self.close_fn(self.ctx) catch {};
            return first;
        };
        return self.close_fn(self.ctx);
    }
};

pub fn newReadCloserWithCloser(inner: *ReadCloser, closer: anytype) ChainedReadCloser {
    const CloserPtr = @TypeOf(closer);
    const gen = struct {
        fn closeFn(ctx: *anyopaque) anyerror!void {
            const c: CloserPtr = @ptrCast(@alignCast(ctx));
            return c.close();
        }
    };
    return .{ .inner = inner, .close_fn = gen.closeFn, .ctx = @ptrCast(closer) };
}

/// go-git `WriteNopCloser`.
pub fn writeNopCloser(writer: *std.Io.Writer, closer: *NopCloser) WriteCloser {
    return newWriteCloser(writer, closer);
}

/// Cancellation-aware reader/writer adapters. Zig has no goroutine capable of
/// interrupting an already-blocked std.Io operation, so cancellation is
/// checked immediately before each operation. This is exact for nonblocking
/// and cooperatively polled I/O.
pub const ContextReader = struct {
    reader: *std.Io.Reader,
    cancelled: *const bool,
    pub fn read(self: *ContextReader, buf: []u8) anyerror!usize {
        if (self.cancelled.*) return error.Canceled;
        return self.reader.readSliceShort(buf);
    }
};

pub const ContextWriter = struct {
    writer: *std.Io.Writer,
    cancelled: *const bool,
    pub fn write(self: *ContextWriter, data: []const u8) anyerror!usize {
        if (self.cancelled.*) return error.Canceled;
        try self.writer.writeAll(data);
        return data.len;
    }
};

pub fn newContextReader(cancelled: *const bool, reader: *std.Io.Reader) ContextReader {
    return .{ .reader = reader, .cancelled = cancelled };
}

pub fn newContextWriter(cancelled: *const bool, writer: *std.Io.Writer) ContextWriter {
    return .{ .writer = writer, .cancelled = cancelled };
}

pub const ContextReadCloser = struct {
    context: ContextReader,
    closer: *ReadCloser,
    pub fn read(self: *@This(), buf: []u8) anyerror!usize { return self.context.read(buf); }
    pub fn close(self: *@This()) anyerror!void { return self.closer.close(); }
};

pub const ContextWriteCloser = struct {
    context: ContextWriter,
    closer: *WriteCloser,
    pub fn write(self: *@This(), data: []const u8) anyerror!usize { return self.context.write(data); }
    pub fn close(self: *@This()) anyerror!void { return self.closer.close(); }
};

pub fn newContextReadCloser(cancelled: *const bool, closer: *ReadCloser) ContextReadCloser {
    return .{ .context = newContextReader(cancelled, closer.reader), .closer = closer };
}

pub fn newContextWriteCloser(cancelled: *const bool, closer: *WriteCloser) ContextWriteCloser {
    return .{ .context = newContextWriter(cancelled, closer.writer), .closer = closer };
}

pub const ReaderAt = struct {
    ptr: *anyopaque,
    read_at_fn: *const fn (*anyopaque, []u8, i64) anyerror!usize,

    pub fn from(comptime T: type, value: *T) ReaderAt {
        return .{ .ptr = value, .read_at_fn = struct {
            fn call(ptr: *anyopaque, buf: []u8, offset: i64) anyerror!usize {
                return (@as(*T, @ptrCast(@alignCast(ptr)))).readAt(buf, offset);
            }
        }.call };
    }
};

/// go-git `NewReaderUsingReaderAt`, represented as a sequential adapter.
pub const ReaderUsingReaderAt = struct {
    source: ReaderAt,
    offset: i64,
    pub fn read(self: *ReaderUsingReaderAt, buf: []u8) anyerror!usize {
        const n = try self.source.read_at_fn(self.source.ptr, buf, self.offset);
        self.offset += @intCast(n);
        return n;
    }
};

pub fn newReaderUsingReaderAt(source: ReaderAt, offset: i64) ReaderUsingReaderAt {
    return .{ .source = source, .offset = offset };
}

pub const NotifyError = *const fn (ctx: *anyopaque, err: anyerror) void;
pub const ReaderOnError = struct {
    reader: *std.Io.Reader,
    notify_ctx: *anyopaque,
    notify: NotifyError,
    pub fn read(self: *ReaderOnError, buf: []u8) anyerror!usize {
        return self.reader.readSliceShort(buf) catch |err| {
            if (err != error.EndOfStream) self.notify(self.notify_ctx, err);
            return err;
        };
    }
};

pub const WriterOnError = struct {
    writer: *std.Io.Writer,
    notify_ctx: *anyopaque,
    notify: NotifyError,
    pub fn write(self: *WriterOnError, data: []const u8) anyerror!usize {
        self.writer.writeAll(data) catch |err| {
            if (err != error.EndOfStream) self.notify(self.notify_ctx, err);
            return err;
        };
        return data.len;
    }
};

pub fn newReaderOnError(reader: *std.Io.Reader, ctx: *anyopaque, notify: NotifyError) ReaderOnError {
    return .{ .reader = reader, .notify_ctx = ctx, .notify = notify };
}

pub fn newWriterOnError(writer: *std.Io.Writer, ctx: *anyopaque, notify: NotifyError) WriterOnError {
    return .{ .writer = writer, .notify_ctx = ctx, .notify = notify };
}

pub const ReadCloserOnError = struct {
    adapter: ReaderOnError,
    closer: *ReadCloser,
    pub fn read(self: *@This(), buf: []u8) anyerror!usize { return self.adapter.read(buf); }
    pub fn close(self: *@This()) anyerror!void { return self.closer.close(); }
};

pub const WriteCloserOnError = struct {
    adapter: WriterOnError,
    closer: *WriteCloser,
    pub fn write(self: *@This(), data: []const u8) anyerror!usize { return self.adapter.write(data); }
    pub fn close(self: *@This()) anyerror!void { return self.closer.close(); }
};

pub fn newReadCloserOnError(closer: *ReadCloser, ctx: *anyopaque, notify: NotifyError) ReadCloserOnError {
    return .{ .adapter = newReaderOnError(closer.reader, ctx, notify), .closer = closer };
}

pub fn newWriteCloserOnError(closer: *WriteCloser, ctx: *anyopaque, notify: NotifyError) WriteCloserOnError {
    return .{ .adapter = newWriterOnError(closer.writer, ctx, notify), .closer = closer };
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

test "write closer wraps writer and chained read closer runs both" {
    var storage: [8]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    var wc_state = CountingCloser{};
    const wc = newWriteCloser(&writer, &wc_state);
    try wc.writer.writeAll("ok");
    try wc.close();
    try testing.expectEqual(@as(usize, 1), wc_state.calls);

    var reader = newReaderFromBuf("x");
    var first = CountingCloser{};
    var second = CountingCloser{};
    var rc = newReadCloser(&reader, &first);
    const chained = newReadCloserWithCloser(&rc, &second);
    try chained.close();
    try testing.expectEqual(@as(usize, 1), first.calls);
    try testing.expectEqual(@as(usize, 1), second.calls);
}

test "context and ReaderAt adapters preserve cancellation and offset" {
    var cancelled = true;
    var fixed = newReaderFromBuf("abc");
    var context = newContextReader(&cancelled, &fixed);
    var byte: [1]u8 = undefined;
    try testing.expectError(error.Canceled, context.read(&byte));

    const Source = struct {
        data: []const u8,
        fn readAt(self: *@This(), out: []u8, offset: i64) anyerror!usize {
            const start: usize = @intCast(offset);
            if (start >= self.data.len) return 0;
            const n = @min(out.len, self.data.len - start);
            @memcpy(out[0..n], self.data[start..][0..n]);
            return n;
        }
    };
    var source = Source{ .data = "abcdef" };
    var sequential = newReaderUsingReaderAt(ReaderAt.from(Source, &source), 2);
    var out: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try sequential.read(&out));
    try testing.expectEqualStrings("cd", &out);
    try testing.expectEqual(@as(i64, 4), sequential.offset);
}

test "writer on-error adapter notifies unexpected failure" {
    const Counter = struct {
        count: usize = 0,
        fn notify(ctx: *anyopaque, _: anyerror) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += 1;
        }
    };
    var byte: [1]u8 = undefined;
    var writer = std.Io.Writer.fixed(&byte);
    var counter = Counter{};
    var adapter = newWriterOnError(&writer, &counter, Counter.notify);
    try testing.expectError(error.WriteFailed, adapter.write("too long"));
    try testing.expectEqual(@as(usize, 1), counter.count);
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
