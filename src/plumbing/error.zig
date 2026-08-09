//! Plumbing package errors (go-git plumbing/error.go + object/reference errors).

/// Error set for plumbing operations.
pub const Error = error{
    /// Object was not found in the store (go-git ErrObjectNotFound).
    ObjectNotFound,
    /// Invalid object type string or value (go-git ErrInvalidType).
    InvalidType,
    /// Reference was not found (go-git ErrReferenceNotFound).
    ReferenceNotFound,
    /// Reference name fails git-check-ref-format rules (go-git ErrInvalidReferenceName).
    InvalidReferenceName,
    /// Hex string is not a valid object id.
    InvalidHash,
};

/// go-git `PermanentError`.
///
/// Go wraps an `error` interface and returns `nil` for a nil input. Zig errors
/// are non-null values, so construction always returns a value. The original
/// error remains available in `err` for typed dispatch by callers.
pub const PermanentError = struct {
    err: anyerror,

    pub fn format(self: PermanentError, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("permanent client error: {s}", .{@errorName(self.err)});
    }
};

pub fn newPermanentError(err: anyerror) PermanentError {
    return .{ .err = err };
}

/// go-git `UnexpectedError`; see `PermanentError` for the Zig nil substitution.
pub const UnexpectedError = struct {
    err: anyerror,

    pub fn format(self: UnexpectedError, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("unexpected client error: {s}", .{@errorName(self.err)});
    }
};

pub fn newUnexpectedError(err: anyerror) UnexpectedError {
    return .{ .err = err };
}

const std = @import("std");

test "client error wrappers preserve cause and prefix" {
    var storage: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    const permanent = newPermanentError(error.AccessDenied);
    try permanent.format(&writer);
    try std.testing.expectEqualStrings("permanent client error: AccessDenied", writer.buffered());
    try std.testing.expect(permanent.err == error.AccessDenied);

    writer = std.Io.Writer.fixed(&storage);
    const unexpected = newUnexpectedError(error.ConnectionResetByPeer);
    try unexpected.format(&writer);
    try std.testing.expectEqualStrings("unexpected client error: ConnectionResetByPeer", writer.buffered());
    try std.testing.expect(unexpected.err == error.ConnectionResetByPeer);
}
