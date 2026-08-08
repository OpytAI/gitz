//! Worktree handle (go-git `Worktree`).
//!
//! Method bodies live in status.zig / add.zig / commit.zig / checkout.zig /
//! reset.zig / pull.zig / clean.zig.

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

    pub fn commit(self: *Worktree, msg: []const u8, o: options_mod.CommitOptions) !Hash {
        return commit_mod.commit(self, msg, o);
    }

    pub fn checkout(self: *Worktree, o: options_mod.CheckoutOptions) !void {
        return checkout_mod.checkout(self, o);
    }

    pub fn reset(self: *Worktree, o: options_mod.ResetOptions) !void {
        return reset_mod.reset(self, o);
    }

    pub fn pull(self: *Worktree, o: *options_mod.PullOptions) !void {
        return pull_mod.pull(self, o);
    }

    pub fn clean(self: *Worktree, o: options_mod.CleanOptions) !void {
        return clean_mod.clean(self, o);
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
