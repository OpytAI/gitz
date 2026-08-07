//! Sideband demultiplexer.
//!
//! Port of go-git v5.19.2 `plumbing/protocol/packp/sideband/demux.go`.

const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const pktline = @import("pktline");
const common = @import("common.zig");

const Type = common.Type;
const Channel = common.Channel;
const MaxPackedSize = common.MaxPackedSize;
const MaxPackedSize64k = common.MaxPackedSize64k;

/// Demuxer-local errors (go-git `ErrMaxPackedExceeded` and sideband message errors).
pub const Error = error{
    /// go-git `ErrMaxPackedExceeded`.
    MaxPackedExceeded,
    /// go-git `fmt.Errorf("unexpected error: %s", ...)`.
    UnexpectedSidebandError,
    /// go-git `fmt.Errorf("unknown channel %s", ...)`.
    UnknownChannel,
};

/// Demultiplexes progress reports and error info interleaved with packfile data.
///
/// go-git `Demuxer`. `read` fills from the PackData channel. ProgressMessage
/// bytes are written to `progress` when set. ErrorMessage returns an error.
///
/// Zig cannot return `(n, err)` like Go. On error, `last_n` holds the number of
/// bytes successfully written to the caller's buffer (go-git's `n`).
pub const Demuxer = struct {
    t: Type,
    max: usize,
    s: pktline.Scanner,

    /// Where progress messages are written (go-git `Progress`). Optional.
    progress: ?*Writer = null,

    /// Bytes written into the caller's buffer by the last `read` call before
    /// an error (or the full count on success). Mirrors Go's `(n, err)` pair.
    last_n: usize = 0,

    /// Leftover PackData from a prior partial `doRead` (go-git `pending`).
    pending_buf: [MaxPackedSize64k]u8 = undefined,
    pending_len: usize = 0,

    /// Current pkt-line PackData payload (separate from `pending_buf` so a
    /// partial consume can copy the remainder without overlapping the slice
    /// still being read).
    pack_buf: [MaxPackedSize64k]u8 = undefined,
    pack_len: usize = 0,

    /// Last detail string for `UnexpectedSidebandError` / `UnknownChannel`.
    err_detail_buf: [512]u8 = undefined,
    err_detail_len: usize = 0,

    /// go-git `NewDemuxer`.
    pub fn init(t: Type, r: *Reader) Demuxer {
        const max: usize = if (t == .sideband) MaxPackedSize else MaxPackedSize64k;
        return .{
            .t = t,
            .max = max,
            .s = pktline.Scanner.init(r),
        };
    }

    /// Detail text for the last sideband error (message body of go-git errors).
    pub fn errDetail(self: *const Demuxer) []const u8 {
        return self.err_detail_buf[0..self.err_detail_len];
    }

    /// Reads up to `b.len` bytes from the PackData channel into `b`.
    ///
    /// Fills the full buffer or returns an error (go-git `(*Demuxer).Read`).
    /// On error, `last_n` is the number of bytes written (Go's `n`).
    /// ProgressMessage traffic is not copied into `b`; it is written to
    /// `progress` when set. ErrorMessage yields `error.UnexpectedSidebandError`.
    pub fn read(self: *Demuxer, b: []u8) ReadError!usize {
        self.last_n = 0;
        var nread: usize = 0;
        while (nread < b.len) {
            const n = self.doRead(b[nread..]) catch |err| {
                self.last_n = nread;
                return err;
            };
            nread += n;
            self.last_n = nread;
        }
        return nread;
    }

    pub const ReadError = Error || pktline.Error || Reader.Error || Writer.Error;

    fn doRead(self: *Demuxer, b: []u8) ReadError!usize {
        const chunk = try self.nextPackData();
        const size = chunk.len;
        var wanted = b.len;
        if (wanted > size) wanted = size;

        // Copy out first — `chunk` may alias `pack_buf` / a temp view of pending.
        if (wanted > 0) {
            @memcpy(b[0..wanted], chunk[0..wanted]);
        }

        if (size > wanted) {
            const rem = size - wanted;
            std.mem.copyForwards(u8, self.pending_buf[0..rem], chunk[wanted..]);
            self.pending_len = rem;
        }
        return wanted;
    }

    fn nextPackData(self: *Demuxer) ReadError![]const u8 {
        if (self.pending_len != 0) {
            // Move pending into pack_buf so a subsequent partial read can write
            // a new remainder back into pending_buf without aliasing the live slice.
            const n = self.pending_len;
            @memcpy(self.pack_buf[0..n], self.pending_buf[0..n]);
            self.pending_len = 0;
            self.pack_len = n;
            return self.pack_buf[0..n];
        }

        if (!self.s.scan()) {
            if (self.s.err()) |e| return e;
            return error.EndOfStream;
        }

        const content = self.s.bytes();
        const size = content.len;
        if (size == 0) {
            return error.EndOfStream;
        } else if (size > self.max) {
            return error.MaxPackedExceeded;
        }

        const ch_byte = content[0];
        if (ch_byte == @intFromEnum(Channel.packData)) {
            const payload = content[1..];
            @memcpy(self.pack_buf[0..payload.len], payload);
            self.pack_len = payload.len;
            return self.pack_buf[0..payload.len];
        } else if (ch_byte == @intFromEnum(Channel.progressMessage)) {
            if (self.progress) |w| {
                try w.writeAll(content[1..]);
            }
            // Drop progress (or after writing) and fetch the next PackData frame.
            // Returning empty would spin `read` forever when the caller's buffer is large.
            return self.nextPackData();
        } else if (ch_byte == @intFromEnum(Channel.errorMessage)) {
            self.setErrDetail("unexpected error: {s}", .{content[1..]});
            return error.UnexpectedSidebandError;
        } else {
            self.setErrDetail("unknown channel {s}", .{content});
            return error.UnknownChannel;
        }
    }

    fn setErrDetail(self: *Demuxer, comptime fmt: []const u8, args: anytype) void {
        if (std.fmt.bufPrint(&self.err_detail_buf, fmt, args)) |msg| {
            self.err_detail_len = msg.len;
        } else |_| {
            self.err_detail_len = 0;
        }
    }
};
