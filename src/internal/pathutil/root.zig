//! Internal path handling and path security helpers.
//!
//! This package contains home-relative path expansion, NTFS and HFS path
//! checks, `.git` name checks, and tree-path validation.

const dotgit = @import("dotgit.zig");
const hfs = @import("hfs.zig");
const ntfs = @import("ntfs.zig");
const tilde = @import("tilde.zig");
const tree = @import("tree.zig");

// --- Public API (camelCase; go-git: IsNTFSDotGit, WindowsValidPath, …) ---

pub const isDotGitName = dotgit.isDotGitName;

pub const isNTFSDotGit = ntfs.isNTFSDotGit;
pub const windowsValidPath = ntfs.windowsValidPath;
pub const isNTFSDot = ntfs.isNTFSDot;
pub const isNTFSDotGitmodules = ntfs.isNTFSDotGitmodules;

pub const isHFSDot = hfs.isHFSDot;
pub const isHFSDotGit = hfs.isHFSDotGit;
pub const isHFSDotGitmodules = hfs.isHFSDotGitmodules;

pub const TildeError = tilde.Error;
pub const replaceTildeWithHome = tilde.replaceTildeWithHome;

/// go-git `ErrInvalidPath` — error set returned by `validTreePath`.
pub const ErrInvalidPath = tree.ErrInvalidPath;
pub const validTreePath = tree.validTreePath;

test {
    _ = @import("dotgit.zig");
    _ = @import("hfs.zig");
    _ = @import("ntfs.zig");
    _ = @import("tilde.zig");
    _ = @import("tree.zig");
}
