//! Storer package errors (go-git `plumbing/storer` package-level `Err*`).
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `ErrStop` | `Error.Stop` / `error.Stop` |
//! | `ErrMaxResolveRecursion` | `Error.MaxResolveRecursion` / `error.MaxResolveRecursion` |
//!
//! Object/reference not-found use `plumbing.Error` (`ObjectNotFound`,
//! `ReferenceNotFound`), not this set.

/// Errors local to the storer helpers package.
pub const Error = error{
    /// Stop a ForEach callback without treating it as failure (go-git `ErrStop`).
    Stop,
    /// Symbolic-ref resolve exceeded max depth (go-git `ErrMaxResolveRecursion`).
    MaxResolveRecursion,
};

const std = @import("std");

test "Error set matches go-git ErrStop and ErrMaxResolveRecursion" {
    try std.testing.expect(Error.Stop == error.Stop);
    try std.testing.expect(Error.MaxResolveRecursion == error.MaxResolveRecursion);
}
