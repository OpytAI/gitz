//! Sideband multiplexer.
//!
//! Port of go-git v5.19.2 `plumbing/protocol/packp/sideband/muxer.go`.

const std = @import("std");
const Writer = std.Io.Writer;

const pktline = @import("pktline");
const common = @import("common.zig");

const Type = common.Type;
const Channel = common.Channel;
const MaxPackedSize = common.MaxPackedSize;
const MaxPackedSize64k = common.MaxPackedSize64k;

const ch_len: usize = 1;

/// Multiplexes packfile data with progress and error messages using pkt-line.
///
/// go-git `Muxer`.
pub const Muxer = struct {
    max: usize,
    e: pktline.Encoder,
    /// Scratch buffer for channel byte + payload (size ≤ MaxPackedSize64k).
    line_buf: [MaxPackedSize64k]u8 = undefined,

    /// go-git `NewMuxer`.
    ///
    /// If `t` is `.sideband`, max pack payload is `MaxPackedSize - 1`;
    /// otherwise `MaxPackedSize64k - 1`.
    pub fn init(t: Type, w: *Writer) Muxer {
        const max: usize = if (t == .sideband) MaxPackedSize else MaxPackedSize64k;
        return .{
            .max = max - ch_len,
            .e = pktline.Encoder.init(w),
        };
    }

    /// Writes `p` on the PackData channel (go-git `(*Muxer).Write`).
    pub fn write(self: *Muxer, p: []const u8) WriteError!usize {
        return self.writeChannel(.packData, p);
    }

    /// Writes `p` on channel `ch` (go-git `(*Muxer).WriteChannel`).
    ///
    /// Prefer `write` for PackData; use this for ProgressMessage / ErrorMessage.
    pub fn writeChannel(self: *Muxer, ch: Channel, p: []const u8) WriteError!usize {
        var wrote: usize = 0;
        while (wrote < p.len) {
            const n = try self.doWrite(ch, p[wrote..]);
            wrote += n;
        }
        return wrote;
    }

    pub const WriteError = pktline.Error || Writer.Error;

    fn doWrite(self: *Muxer, ch: Channel, p: []const u8) WriteError!usize {
        var sz = p.len;
        if (sz > self.max) sz = self.max;

        self.line_buf[0] = @intFromEnum(ch);
        @memcpy(self.line_buf[1 .. 1 + sz], p[0..sz]);
        try self.e.encodeLine(self.line_buf[0 .. 1 + sz]);
        return sz;
    }
};
