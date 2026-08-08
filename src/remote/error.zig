//! Remote package errors (go-git `remote.go` package vars).

/// Errors for Remote Fetch / Push / List.
pub const Error = error{
    /// go-git `NoErrAlreadyUpToDate` — operation succeeded with no changes.
    /// Callers treat this as a non-fatal / success-with-noop outcome.
    AlreadyUpToDate,
    /// go-git `ErrDeleteRefNotSupported`.
    DeleteRefNotSupported,
    /// go-git `ErrForceNeeded`.
    ForceNeeded,
    /// go-git `ErrExactSHA1NotSupported`.
    ExactSHA1NotSupported,
    /// go-git `ErrEmptyUrls`.
    EmptyUrls,
    /// go-git `NoMatchingRefSpecError`.
    NoMatchingRefSpec,
    /// Remote name in options does not match this Remote.
    RemoteNameMismatch,
    /// Invalid ListOptions.Timeout (< 0).
    InvalidTimeout,
    /// Force-with-lease check failed.
    ForceWithLeaseRejected,
    /// Required remote ref does not match (RequireRemoteRefs).
    RequireRemoteRefsFailed,
};
