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
