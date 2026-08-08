//! Package submodule — go-git root `submodule.go` (Init / Status / list / Update).
//!
//! Import as `@import("submodule")`.
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `Submodule` / `Init` / `Status` / `Config` / `Update` | `Submodule` |
//! | `Submodules` / `Init` / `Status` / `Update` | `Submodules` |
//! | `SubmoduleStatus` / `SubmodulesStatus` | `status.zig` |
//! | `SubmoduleUpdateOptions` | `options.zig` |
//! | `ErrSubmoduleAlreadyInitialized` / … | `error.zig` |
//! | Worktree.Submodule / Submodules | `listSubmodules` / `getSubmodule` + `Host` |
//!
//! Update fetch uses `//src/remote` into module storage. Pass
//! `SubmoduleUpdateOptions.embedded` (MapLoader server) for hermetic tests.
//! Relative submodule URLs (`../X.git`) resolve against the superproject
//! default remote (go-git `defaultRemote` + path join).
//!
//! Nested recursion walks the object graph (`.gitmodules` + gitlinks at the
//! checked-out commit) and materializes nested trees under the parent module
//! path on the host worktree FS (chroot).

const error_mod = @import("error.zig");
const options_mod = @import("options.zig");
const status_mod = @import("status.zig");
const host_mod = @import("host.zig");
const relative_url_mod = @import("relative_url.zig");
const submodule_mod = @import("submodule.zig");

// --- error.zig ---
pub const Error = error_mod.Error;

// --- options.zig ---
pub const SubmoduleRecursivity = options_mod.SubmoduleRecursivity;
pub const no_recurse_submodules = options_mod.no_recurse_submodules;
pub const default_submodule_recursion_depth = options_mod.default_submodule_recursion_depth;
pub const SubmoduleUpdateOptions = options_mod.SubmoduleUpdateOptions;

// --- status.zig ---
pub const SubmoduleStatus = status_mod.SubmoduleStatus;
pub const SubmodulesStatus = status_mod.SubmodulesStatus;

// --- host.zig ---
pub const Host = host_mod.Host;

// --- relative_url.zig ---
pub const isRelativeSubmoduleURL = relative_url_mod.isRelativeSubmoduleURL;
pub const resolveSubmoduleURL = relative_url_mod.resolveSubmoduleURL;
pub const resolveRelativeURL = relative_url_mod.resolveRelativeURL;
pub const defaultRemote = relative_url_mod.defaultRemote;
pub const default_remote_name = relative_url_mod.default_remote_name;

// --- submodule.zig ---
pub const gitmodules_file = submodule_mod.gitmodules_file;
pub const Submodule = submodule_mod.Submodule;
pub const OwnedRepository = submodule_mod.OwnedRepository;
pub const Submodules = submodule_mod.Submodules;
pub const readGitmodulesFile = submodule_mod.readGitmodulesFile;
pub const listSubmodules = submodule_mod.listSubmodules;
pub const getSubmodule = submodule_mod.getSubmodule;
pub const listFromWorktree = submodule_mod.listFromWorktree;
pub const WorktreeSubmodules = submodule_mod.WorktreeSubmodules;
pub const submodulesForWorktree = submodule_mod.submodulesForWorktree;
pub const WorktreeSubmodule = submodule_mod.WorktreeSubmodule;
pub const submoduleForWorktree = submodule_mod.submoduleForWorktree;
pub const updateFromWorktreePull = submodule_mod.updateFromWorktreePull;
pub const bindPullOptions = submodule_mod.bindPullOptions;
pub const expectedFromEntry = submodule_mod.expectedFromEntry;

// Production root stays free of tests.zig so dependents do not pull fixtures.
test {
    _ = @import("error.zig");
    _ = @import("options.zig");
    _ = @import("status.zig");
    _ = @import("host.zig");
    _ = @import("relative_url.zig");
    _ = @import("submodule.zig");
}
