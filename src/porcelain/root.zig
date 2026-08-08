//! Package porcelain — go-git root clone / plain-clone helpers.
//!
//! Import as `@import("porcelain")`.
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `Clone` / `CloneContext` | `clone` / `cloneEmbedded` |
//! | `PlainClone` / `PlainCloneContext` | `plainClone` / `plainCloneEmbedded` |
//! | `(*Repository).clone` | `cloneInto` |
//! | `CloneOptions` | re-export from `worktree` |

const error_mod = @import("error.zig");
const clone_mod = @import("clone.zig");
const worktree = @import("worktree");

pub const Error = error_mod.Error;

pub const CloneOptions = worktree.CloneOptions;
pub const OwnedRepository = clone_mod.OwnedRepository;

pub const clone = clone_mod.clone;
pub const cloneEmbedded = clone_mod.cloneEmbedded;
pub const plainClone = clone_mod.plainClone;
pub const plainCloneEmbedded = clone_mod.plainCloneEmbedded;
pub const cloneInto = clone_mod.cloneInto;

test {
    _ = @import("error.zig");
    _ = @import("clone.zig");
}
