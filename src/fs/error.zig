//! Filesystem errors (go-billy subset + host I/O).

/// Errors for `fs` operations (billy / OS equivalents).
///
/// Host backends map `std.Io` failures into this set. Prefer a specific member
/// over `Unexpected` when the mapping is clear; use `NotSupported` only for
/// intentionally unavailable features (not “I don’t know what happened”).
pub const Error = error{
    /// Path does not exist (os.ErrNotExist).
    NotExist,
    /// Path already exists (os.ErrExist / O_EXCL).
    Exist,
    /// Feature not supported (billy.ErrNotSupported).
    NotSupported,
    /// Read-only filesystem or permission denied for write.
    ReadOnly,
    /// Chroot boundary crossed (billy.ErrCrossedBoundary).
    CrossedBoundary,
    /// Path is a directory where a file was required.
    IsDir,
    /// Path is not a directory.
    NotDir,
    /// File is closed.
    Closed,
    /// Open mode does not allow the requested operation.
    InvalidMode,
    /// Not a symbolic link.
    NotLink,
    /// Disk full / quota (mapped from host).
    NoSpace,
    /// Process or system resource limits.
    SystemResources,
    /// Host error with no billy analogue (do not use for intentional stubs).
    Unexpected,
};
