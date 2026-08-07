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
    /// go-git `ErrWorktreeNotProvided` (phase 12 Worktree surface).
    WorktreeNotProvided,
    /// go-git `ErrIsBareRepository` (phase 12 Worktree surface).
    IsBareRepository,
    /// Thin Log only supports default/DFS preorder.
    InvalidLogOrder,
    /// ResolveRevision `^{/pattern}` found no matching commit message.
    NoCommitMessageMatch,
};
