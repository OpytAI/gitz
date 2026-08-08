//! Worktree handle (go-git `Worktree`).
//!
//! Method bodies: status, add, commit, checkout, reset, pull, clean, grep.
//! Shared path/ignore helpers: util.zig.

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");
const fs_pkg = @import("fs");
const gitignore = @import("gitignore");
const server = @import("server");

const status_types = @import("status_types.zig");
const options_mod = @import("options.zig");
const status_mod = @import("status.zig");
const add_mod = @import("add.zig");
const commit_mod = @import("commit.zig");
const checkout_mod = @import("checkout.zig");
const reset_mod = @import("reset.zig");
const pull_mod = @import("pull.zig");
const clean_mod = @import("clean.zig");
const grep_mod = @import("grep.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Status = status_types.Status;

/// go-git `Worktree`.
///
/// Does **not** own `storer` or `filesystem`. Optional `embedded` server for
/// in-process Pull (same pattern as Remote).
pub const Worktree = struct {
    allocator: Allocator,
    storer: *memory.Storage,
    filesystem: *fs_pkg.Mem,
    /// External excludes (go-git `Excludes`). Not owned.
    excludes: []const gitignore.Pattern = &.{},
    /// In-process transport for Pull tests.
    embedded: ?*server.Server = null,

    pub fn status(self: *Worktree) !Status {
        return status_mod.status(self, .{});
    }

    pub fn statusWithOptions(self: *Worktree, o: options_mod.StatusOptions) !Status {
        return status_mod.status(self, o);
    }

    pub fn add(self: *Worktree, path: []const u8) !Hash {
        return add_mod.add(self, path);
    }

    pub fn addWithOptions(self: *Worktree, o: options_mod.AddOptions) !void {
        return add_mod.addWithOptions(self, o);
    }

    pub fn remove(self: *Worktree, path: []const u8) !Hash {
        return add_mod.remove(self, path);
    }

    pub fn removeGlob(self: *Worktree, pattern: []const u8) !void {
        return add_mod.removeGlob(self, pattern);
    }

    pub fn addGlob(self: *Worktree, pattern: []const u8) !void {
        return add_mod.addGlob(self, pattern);
    }

    pub fn move(self: *Worktree, from: []const u8, to: []const u8) !Hash {
        return add_mod.move(self, from, to);
    }

    pub fn commit(self: *Worktree, msg: []const u8, o: options_mod.CommitOptions) !Hash {
        return commit_mod.commit(self, msg, o);
    }

    pub fn checkout(self: *Worktree, o: options_mod.CheckoutOptions) !void {
        return checkout_mod.checkout(self, o);
    }

    pub fn reset(self: *Worktree, o: options_mod.ResetOptions) !void {
        return reset_mod.reset(self, o);
    }

    pub fn resetSparsely(self: *Worktree, o: options_mod.ResetOptions, dirs: []const []const u8) !void {
        return reset_mod.resetSparsely(self, o, dirs);
    }

    pub fn pull(self: *Worktree, o: *options_mod.PullOptions) !void {
        return pull_mod.pull(self, o);
    }

    pub fn clean(self: *Worktree, o: options_mod.CleanOptions) !void {
        return clean_mod.clean(self, o);
    }

    pub fn restore(self: *Worktree, o: options_mod.RestoreOptions) !void {
        return reset_mod.restore(self, o);
    }

    pub fn grep(self: *Worktree, o: options_mod.GrepOptions) ![]grep_mod.GrepResult {
        return grep_mod.grep(self, o);
    }
};

/// Construct a Worktree over memory storage + Mem FS.
pub fn newWorktree(allocator: Allocator, sto: *memory.Storage, filesystem: *fs_pkg.Mem) Worktree {
    return .{
        .allocator = allocator,
        .storer = sto,
        .filesystem = filesystem,
        .excludes = &.{},
        .embedded = null,
    };
}

pub fn newWorktreeEmbedded(
    allocator: Allocator,
    sto: *memory.Storage,
    filesystem: *fs_pkg.Mem,
    srv: *server.Server,
) Worktree {
    return .{
        .allocator = allocator,
        .storer = sto,
        .filesystem = filesystem,
        .excludes = &.{},
        .embedded = srv,
    };
}
