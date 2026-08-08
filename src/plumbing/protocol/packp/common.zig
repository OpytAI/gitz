//! Common constants and errors for pack-protocol messages.
//! Port of go-git `plumbing/protocol/packp/common.go` (v5.19.2).

const std = @import("std");
const testing = std.testing;

// ---------------------------------------------------------------------------
// Constants (go-git package-level)
// ---------------------------------------------------------------------------

const plumbing = @import("plumbing");

/// Hex OID length used in packp line framing (go-git `hashSize`).
/// Follows the active object format (40 for SHA-1, 64 for SHA-256).
pub fn hashSize() usize {
    return plumbing.hexSize();
}

/// Advertised HEAD ref name (go-git `head`).
pub const head: []const u8 = "HEAD";

/// Capability-only first ref marker when HEAD is missing (go-git `noHead`).
pub const no_head: []const u8 = "capabilities^{}";

/// Space separator bytes (go-git `sp`).
pub const sp: []const u8 = " ";

/// End-of-line bytes (go-git `eol`).
pub const eol: []const u8 = "\n";

/// NUL separator (go-git `null`).
pub const null_byte: []const u8 = "\x00";

/// Peeled-ref suffix (go-git `peeled`).
pub const peeled: []const u8 = "^{}";

/// First-line mark when there is no HEAD (go-git `noHeadMark`).
pub const no_head_mark: []const u8 = " capabilities^{}\x00";

/// Upload-request want prefix (go-git `want`).
pub const want: []const u8 = "want ";

/// Shallow prefix with trailing space (go-git `shallow`).
pub const shallow: []const u8 = "shallow ";

/// Deepen keyword without space (go-git `deepen`).
pub const deepen: []const u8 = "deepen";

/// Deepen-commits prefix (go-git `deepenCommits`).
pub const deepen_commits: []const u8 = "deepen ";

/// Deepen-since prefix (go-git `deepenSince`).
pub const deepen_since: []const u8 = "deepen-since ";

/// Deepen-not prefix (go-git `deepenReference`).
pub const deepen_reference: []const u8 = "deepen-not ";

/// Unshallow prefix (go-git `unshallow`).
pub const unshallow: []const u8 = "unshallow ";

/// ACK token (go-git `ack`).
pub const ack: []const u8 = "ACK";

/// NAK token (go-git `nak`).
pub const nak: []const u8 = "NAK";

/// Shallow keyword without trailing space (go-git `shallowNoSp`).
pub const shallow_no_sp: []const u8 = "shallow";

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Package-level errors for packp core messages.
pub const Error = error{
    /// Nil writer passed to an encoder (go-git `ErrNilWriter`).
    NilWriter,
    /// Unexpected data while decoding a message (go-git `ErrUnexpectedData`).
    UnexpectedData,
    /// Invalid git protocol request (go-git `ErrInvalidGitProtoRequest`).
    InvalidGitProtoRequest,
    /// Unsupported object type for filter (go-git `ErrUnsupportedObjectFilterType`).
    UnsupportedObjectFilterType,
    /// Unexpected flush pkt-line (go-git server-response).
    UnexpectedFlush,
    /// Unexpected content in a server-response line.
    UnexpectedContent,
    /// Malformed ACK line.
    MalformedAck,
    /// multi_ack / multi_ack_detailed are not supported.
    MultiAckNotSupported,
    /// Malformed shallow/unshallow line.
    MalformedShallowLine,
    /// Report-status missing terminating flush.
    MissingFlush,
    /// Report-status started with a flush.
    PrematureFlush,
    /// Malformed unpack status line.
    MalformedUnpackStatus,
    /// Malformed command status line.
    MalformedCommandStatus,
    /// Unexpected end of stream while decoding (go-git `io.ErrUnexpectedEOF`).
    UnexpectedEof,
};

/// Structured unexpected-data error (go-git `ErrUnexpectedData`).
///
/// Use with `error.UnexpectedData` when only the error set is needed; keep
/// this value when the message/data payload must be inspected.
pub const UnexpectedData = struct {
    msg: []const u8,
    data: []const u8 = &.{},

    /// go-git `NewErrUnexpectedData`.
    pub fn init(msg: []const u8, data: []const u8) UnexpectedData {
        return .{ .msg = msg, .data = data };
    }

    /// go-git `(*ErrUnexpectedData).Error` — `msg` or `msg (data)`.
    pub fn errorMessage(self: *const UnexpectedData, buf: []u8) []const u8 {
        if (self.data.len == 0) return self.msg;
        return std.fmt.bufPrint(buf, "{s} ({s})", .{ self.msg, self.data }) catch self.msg;
    }
};

/// go-git `NewErrUnexpectedData` — builds a structured value.
pub fn newErrUnexpectedData(msg: []const u8, data: []const u8) UnexpectedData {
    return UnexpectedData.init(msg, data);
}

/// True when `payload` is a flush-pkt payload (empty). go-git `isFlush`.
pub fn isFlush(payload: []const u8) bool {
    return payload.len == 0;
}

// ---------------------------------------------------------------------------
// Tests (common_test.go helpers + isFlush)
// ---------------------------------------------------------------------------

test "isFlush empty and non-empty" {
    try testing.expect(isFlush(&.{}));
    try testing.expect(isFlush(""));
    try testing.expect(!isFlush("ACK"));
    try testing.expect(!isFlush("\n"));
}

test "UnexpectedData error message without data" {
    const e = newErrUnexpectedData("boom", &.{});
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("boom", e.errorMessage(&buf));
}

test "UnexpectedData error message with data" {
    const e = newErrUnexpectedData("boom", "xyz");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("boom (xyz)", e.errorMessage(&buf));
}
