//! Path security helpers for tree / worktree materialisation.
//!
//! Port of go-git v5.19.2 `internal/pathutil` — NTFS 8.3 / ADS / reserved
//! devices, HFS+ ignored code points, `.git` name checks, and
//! `ValidTreePath`.

const dotgit = @import("dotgit.zig");
const hfs = @import("hfs.zig");
const ntfs = @import("ntfs.zig");
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

/// go-git `ErrInvalidPath` — error set returned by `validTreePath`.
pub const ErrInvalidPath = tree.ErrInvalidPath;
pub const validTreePath = tree.validTreePath;

test {
    _ = @import("dotgit.zig");
    _ = @import("hfs.zig");
    _ = @import("ntfs.zig");
    _ = @import("tree.zig");
}
