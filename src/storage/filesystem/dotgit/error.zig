//! DotGit errors (go-git `storage/filesystem/dotgit`).

/// Errors for `.git` directory layout and reference packing.
pub const Error = error{
    /// Path not found (go-git `ErrNotFound`).
    NotFound,
    /// Pack index file not found (go-git `ErrIdxNotFound`).
    IdxNotFound,
    /// Packfile not found (go-git `ErrPackfileNotFound`).
    PackfileNotFound,
    /// Config file not found (go-git `ErrConfigNotFound`).
    ConfigNotFound,
    /// Duplicated ref in packed-refs (go-git `ErrPackedRefsDuplicatedRef`).
    PackedRefsDuplicatedRef,
    /// Malformed packed-refs line (go-git `ErrPackedRefsBadFormat`).
    PackedRefsBadFormat,
    /// Loose ref file is empty (go-git `ErrEmptyRefFile`).
    EmptyRefFile,
    /// Loose ref content is neither a valid object ID nor a safe symbolic ref.
    MalformedRefFile,
    /// Reference name escapes safe storage paths (go-git `ErrReferenceNameEscape`).
    ReferenceNameEscape,
    /// Submodule name escapes `modules/` (go-git `ErrModuleNameEscape`).
    ModuleNameEscape,
    /// Alternate object directory contains an invalid line delimiter or path.
    InvalidAlternate,
    /// Reference path is a directory (go-git `ErrIsDir`).
    IsDir,
    /// Concurrent reference update lost the race (go-git `storage.ErrReferenceHasChanged`).
    ReferenceHasChanged,
    /// Symbolic reference target missing (go-git `ErrSymRefTargetNotFound`).
    SymRefTargetNotFound,
};
