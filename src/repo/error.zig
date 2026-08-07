//! Repository package errors (go-git root `repository.go` error vars).
//!
//! `WorktreeNotProvided` / `IsBareRepository` match go-git package vars and are
//! reserved for phase-12 Worktree methods (go-git documents them; Open does not
//! always enforce WorktreeNotProvided).

/// Errors for repository open/init and related facades.
pub const Error = error{
    /// go-git `ErrRepositoryNotExists`.
    RepositoryNotExists,
    /// go-git `ErrRepositoryAlreadyExists`.
    RepositoryAlreadyExists,
    /// go-git `ErrWorktreeNotProvided`.
    WorktreeNotProvided,
    /// go-git `ErrIsBareRepository`.
    IsBareRepository,
    /// Log order unsupported (should not occur when all orders are wired).
    InvalidLogOrder,
    /// ResolveRevision `^{/pattern}` found no matching commit message.
    NoCommitMessageMatch,
    /// go-git `ErrRemoteNotFound`.
    RemoteNotFound,
    /// go-git `ErrRemoteExists`.
    RemoteExists,
    /// go-git `ErrAnonymousRemoteName`.
    AnonymousRemoteName,
    /// go-git `ErrBranchNotFound`.
    BranchNotFound,
    /// go-git `ErrBranchExists`.
    BranchExists,
    /// go-git `ErrTagNotFound`.
    TagNotFound,
    /// go-git `ErrTagExists`.
    TagExists,
    /// Annotated tag requires a tagger (go-git `CreateTagOptions.Validate`).
    MissingTagger,
};
