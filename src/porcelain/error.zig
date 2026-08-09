//! Porcelain package errors (clone / plain helpers).

/// Errors for PlainClone / Clone helpers.
pub const Error = error{
    /// go-git `ErrMissingURL` — CloneOptions.URL empty after validate.
    MissingURL,
    /// go-git `ErrFetching` — empty packfile / unable to fetch.
    Fetching,
    /// go-git `ErrUnableToResolveCommit` — peel to commit failed.
    UnableToResolveCommit,
    /// Worktree FS is null when a non-bare operation needs it.
    IsBareRepository,
    /// Shared clone was requested through a non-shared-only entry point.
    SharedCloneRequired,
    /// Filesystem shared clone cannot yet feed the memory-only checkout engine.
    SharedCheckoutNotSupported,
    /// The storage-only shared path cannot preserve this clone option exactly.
    SharedCloneOptionNotSupported,
};
