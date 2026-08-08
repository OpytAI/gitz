//! Package-level errors for the commit-graph format.
//!
//! Port of go-git v5.19.2 `plumbing/format/commitgraph/v2` `Err*` values
//! (file.go) plus plumbing object-not-found used by Index lookups.

/// Errors for commit-graph open/encode and Index lookups.
pub const Error = error{
    /// go-git `ErrUnsupportedVersion` — file version is not 1.
    UnsupportedVersion,
    /// go-git `ErrUnsupportedHash` — hash version does not match active object format.
    UnsupportedHash,
    /// go-git `ErrMalformedCommitGraphFile` — corrupt signature/chunks/payload.
    MalformedCommitGraphFile,
    /// go-git `plumbing.ErrObjectNotFound` — hash/index miss.
    ObjectNotFound,
};
