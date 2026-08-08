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
    /// Empty branch name on CreateBranch.
    BranchEmptyName,
    /// go-git `ErrTagNotFound`.
    TagNotFound,
    /// go-git `ErrTagExists`.
    TagExists,
    /// Annotated tag requires a tagger (go-git `ErrMissingTagger`).
    MissingTagger,
    /// Annotated tag requires a message (go-git `ErrMissingMessage`).
    MissingMessage,
    /// go-git `ErrSHA256NotSupported` — returned only if `supportsObjectFormat(.sha256)` is false.
    /// Default gitz builds always support both SHA-1 and SHA-256 (runtime dual).
    SHA256NotSupported,
    /// `object_format` is not empty/sha1/sha256.
    InvalidObjectFormat,
    /// `.git` file is not a valid `gitdir: ` pointer.
    InvalidGitDirFile,
};
