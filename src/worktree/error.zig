//! Worktree package errors (go-git worktree / status package vars).

/// Errors for Worktree Status / Add / Commit / Checkout / Reset / Pull / Clean.
pub const Error = error{
    /// go-git `ErrWorktreeNotClean`.
    WorktreeNotClean,
    /// go-git `ErrUnstagedChanges`.
    UnstagedChanges,
    /// go-git `ErrSubmoduleNotFound`.
    SubmoduleNotFound,
    /// go-git `ErrGitModulesSymlink`.
    GitModulesSymlink,
    /// go-git `ErrNonFastForwardUpdate` (pull).
    NonFastForwardUpdate,
    /// go-git `ErrRestoreWorktreeOnlyNotSupported`.
    RestoreWorktreeOnlyNotSupported,
    /// go-git `ErrDestinationExists` (Move).
    DestinationExists,
    /// go-git `ErrGlobNoMatches`.
    GlobNoMatches,
    /// go-git `ErrUnsupportedStatusStrategy`.
    UnsupportedStatusStrategy,
    /// go-git `ErrEmptyCommit`.
    EmptyCommit,
    /// go-git `ErrMissingAuthor`.
    MissingAuthor,
    /// go-git `ErrBranchHashExclusive`.
    BranchHashExclusive,
    /// go-git `ErrCreateRequiresBranch`.
    CreateRequiresBranch,
    /// go-git `ErrMissingURL` (clone).
    MissingURL,
    /// Worktree filesystem is null / bare repo.
    IsBareRepository,
    /// Path/Glob mutually exclusive on AddOptions.
    AddPathGlobExclusive,
    /// All + Amend mutually exclusive on CommitOptions.
    CommitAllAmendExclusive,
    /// Parents cannot be used with Amend.
    CommitParentsAmendExclusive,
    /// Force and Keep mutually exclusive on CheckoutOptions.
    CheckoutForceKeepExclusive,
    /// go-git `ErrNoRestorePaths` — Restore with empty Files.
    NoRestorePaths,
    /// go-git `ErrHashOrReference` — GrepOptions CommitHash and ReferenceName both set.
    HashOrReference,
    /// Grep pattern failed to compile (pure-Zig regex; go-git panics on MustCompile).
    InvalidRegex,
};
