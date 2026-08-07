//! Packfile package errors (go-git `plumbing/format/packfile` error values).

/// Package-level errors matching go-git names where practical.
pub const Error = error{
    /// empty packfile (`ErrEmptyPackfile`)
    EmptyPackfile,
    /// bad PACK signature (`ErrBadSignature`)
    BadSignature,
    /// unsupported pack version (`ErrUnsupportedVersion`)
    UnsupportedVersion,
    /// seek not supported on source (`ErrSeekNotSupported`)
    SeekNotSupported,
    /// malformed pack (`ErrMalformedPackFile`)
    MalformedPackFile,
    /// variable-length integer overflow (`ErrLengthOverflow`)
    LengthOverflow,
    /// inflated object exceeds declared size (`ErrInflatedSizeMismatch`)
    InflatedSizeMismatch,
    /// zlib inflate failure (`ErrZLib`)
    ZLib,
    /// invalid git object (`ErrInvalidObject`)
    InvalidObject,
    /// invalid delta (`ErrInvalidDelta`)
    InvalidDelta,
    /// wrong delta command (`ErrDeltaCmd`)
    DeltaCmd,
    /// reference delta base not found (`ErrReferenceDeltaNotFound`)
    ReferenceDeltaNotFound,
    /// parser source not seekable and no storage (`ErrNotSeekableSource`)
    NotSeekableSource,
    /// delta not in cache (`ErrDeltaNotCached`)
    DeltaNotCached,
    /// object not found in pack index
    ObjectNotFound,
};
