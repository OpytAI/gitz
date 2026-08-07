//! Package-level errors for the Git index (dircache) format.
//!
//! Port of go-git v5.19.2 `plumbing/format/index` `Err*` values
//! (index.go, decoder.go, encoder.go) plus match BadPattern.

/// Errors for index types, match/glob, and the codec (decoder/encoder).
pub const Error = error{
    /// go-git `ErrUnsupportedVersion` — index version not 2/3/4.
    UnsupportedVersion,
    /// go-git `ErrEntryNotFound` — Index.Entry / Index.Remove miss.
    EntryNotFound,
    /// go-git `ErrInvalidTimestamp` — encoder rejects negative times.
    InvalidTimestamp,
    /// go-git `ErrMalformedSignature` — header magic is not `DIRC`.
    MalformedSignature,
    /// go-git `ErrInvalidChecksum` — trailing SHA-1 mismatch.
    InvalidChecksum,
    /// go-git `ErrUnknownExtension` — mandatory extension not understood.
    UnknownExtension,
    /// go-git `ErrMalformedIndexFile` — corrupt entry/extension payload.
    MalformedIndexFile,
    /// `filepath.ErrBadPattern` from match/Glob.
    BadPattern,
};
