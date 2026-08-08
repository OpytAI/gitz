//! Package worktree — go-git root Worktree + status types.
//!
//! Import as `@import("worktree")`.

const error_mod = @import("error.zig");
const status_types = @import("status_types.zig");
const options_mod = @import("options.zig");
const worktree_mod = @import("worktree.zig");
const platform_mod = @import("platform.zig");
const status_mod = @import("status.zig");
const add_mod = @import("add.zig");
const commit_mod = @import("commit.zig");
const checkout_mod = @import("checkout.zig");
const reset_mod = @import("reset.zig");
const pull_mod = @import("pull.zig");
const clean_mod = @import("clean.zig");
const grep_mod = @import("grep.zig");

pub const Error = error_mod.Error;

pub const StatusCode = status_types.StatusCode;
pub const FileStatus = status_types.FileStatus;
pub const Status = status_types.Status;
pub const StatusStrategy = status_types.StatusStrategy;
pub const StatusOptions = status_types.StatusOptions;
pub const default_status_strategy = status_types.default_status_strategy;

pub const CheckoutOptions = options_mod.CheckoutOptions;
pub const ResetMode = options_mod.ResetMode;
pub const ResetOptions = options_mod.ResetOptions;
pub const AddOptions = options_mod.AddOptions;
pub const CommitOptions = options_mod.CommitOptions;
pub const PullOptions = options_mod.PullOptions;
pub const CloneOptions = options_mod.CloneOptions;
pub const CleanOptions = options_mod.CleanOptions;
pub const RestoreOptions = options_mod.RestoreOptions;
pub const GrepOptions = options_mod.GrepOptions;
pub const GrepResult = grep_mod.GrepResult;
pub const freeGrepResults = grep_mod.freeGrepResults;

pub const Worktree = worktree_mod.Worktree;
pub const newWorktree = worktree_mod.newWorktree;
pub const newWorktreeEmbedded = worktree_mod.newWorktreeEmbedded;

// Package-level free functions (also available as Worktree methods).
pub const status = status_mod.status;
pub const add = add_mod.add;
pub const addWithOptions = add_mod.addWithOptions;
pub const addGlob = add_mod.addGlob;
pub const remove = add_mod.remove;
pub const removeGlob = add_mod.removeGlob;
pub const move = add_mod.move;
pub const commit = commit_mod.commit;
pub const checkout = checkout_mod.checkout;
pub const reset = reset_mod.reset;
pub const resetSparsely = reset_mod.resetSparsely;
pub const pull = pull_mod.pull;
pub const clean = clean_mod.clean;
pub const restore = reset_mod.restore;
pub const grep = grep_mod.grep;

// Platform index stat fill (go-git worktree_linux.go / worktree_windows.go).
pub const fillSystemInfo = platform_mod.fillSystemInfo;
pub const fillSystemInfoLinux = platform_mod.fillSystemInfoLinux;
pub const fillSystemInfoWindows = platform_mod.fillSystemInfoWindows;
pub const isSymlinkWindowsNonAdmin = platform_mod.isSymlinkWindowsNonAdmin;

test {
    _ = @import("error.zig");
    _ = @import("status_types.zig");
    _ = @import("options.zig");
    _ = @import("util.zig");
    _ = @import("platform.zig");
    _ = @import("platform_linux.zig");
    _ = @import("platform_windows.zig");
    _ = @import("status.zig");
    _ = @import("add.zig");
    _ = @import("commit.zig");
    _ = @import("checkout.zig");
    _ = @import("reset.zig");
    _ = @import("pull.zig");
    _ = @import("clean.zig");
    _ = @import("regex.zig");
    _ = @import("grep.zig");
    _ = @import("worktree.zig");
}
