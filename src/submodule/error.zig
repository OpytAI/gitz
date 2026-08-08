//! Submodule package errors (go-git `submodule.go` / `worktree.go` package vars).

/// Errors for Submodule Init / Status / list / Update.
pub const Error = error{
    /// go-git `ErrSubmoduleAlreadyInitialized`.
    SubmoduleAlreadyInitialized,
    /// go-git `ErrSubmoduleNotInitialized`.
    SubmoduleNotInitialized,
    /// go-git `ErrSubmoduleNotFound` (worktree package var; used by list lookup).
    SubmoduleNotFound,
    /// go-git `ErrGitModulesSymlink` — `.gitmodules` is a symlink.
    GitModulesSymlink,
    /// Submodule URL is empty when Update needs to fetch missing objects.
    /// Spirit of go-git `ErrModuleEmptyURL` / remote empty-URL failures.
    SubmoduleEmptyURL,
    /// Relative submodule URL needs a parent remote that is not configured
    /// (go-git `resolving relative submodule URL: remote "…" not found`).
    ParentRemoteNotFound,
    /// Parent remote used for relative URL join has no URLs.
    ParentRemoteEmptyURL,
};
