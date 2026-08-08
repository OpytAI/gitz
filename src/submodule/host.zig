//! Host linking memory storage + Mem FS for submodule ops.
//!
//! go-git binds Submodule to `*Worktree` and persists Init into
//! `Repository.Config().Submodules`. gitz memory `Config` has no submodule map,
//! so this Host holds the initialized-submodule registry and the storer/FS pair.
//!
//! # Ownership
//!
//! - Does **not** own `storer` or `filesystem` (borrowed from caller).
//! - Owns `initialized` map: keys and `*SubmoduleConfig` values are freed in
//!   `deinit`. `putInitialized` always copies name/path/url/branch.

const std = @import("std");
const memory = @import("memory");
const fs_pkg = @import("fs");
const gitconfig = @import("gitconfig");
const worktree = @import("worktree");

const error_mod = @import("error.zig");

const Allocator = std.mem.Allocator;
const SubmoduleConfig = gitconfig.Submodule;

/// Runtime host for submodule operations (storer + worktree FS + init registry).
///
/// Call `deinit` to free the init registry. Storer and filesystem outlive Host.
pub const Host = struct {
    allocator: Allocator,
    /// Borrowed superproject storage (not owned).
    storer: *memory.Storage,
    /// Borrowed worktree FS (not owned).
    filesystem: *fs_pkg.Mem,
    /// Initialized submodule configs (go-git `Config.Submodules`). Owned by Host.
    initialized: std.StringHashMapUnmanaged(*SubmoduleConfig) = .empty,

    pub fn init(allocator: Allocator, storer: *memory.Storage, filesystem: *fs_pkg.Mem) Host {
        return .{
            .allocator = allocator,
            .storer = storer,
            .filesystem = filesystem,
        };
    }

    /// Build a Host from a worktree package Worktree (does not take ownership).
    pub fn fromWorktree(w: *worktree.Worktree) Host {
        return init(w.allocator, w.storer, w.filesystem);
    }

    pub fn deinit(self: *Host) void {
        var it = self.initialized.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            self.allocator.destroy(e.value_ptr.*);
            self.allocator.free(e.key_ptr.*);
        }
        self.initialized.deinit(self.allocator);
        self.* = undefined;
    }

    /// Whether a submodule name is recorded as initialized.
    pub fn isInitialized(self: *const Host, name: []const u8) bool {
        return self.initialized.contains(name);
    }

    /// Borrow the stored config for an initialized submodule, if any.
    pub fn getInitialized(self: *const Host, name: []const u8) ?*SubmoduleConfig {
        return self.initialized.get(name);
    }

    /// Record a submodule as initialized (copies name/path/url/branch).
    /// Returns `SubmoduleAlreadyInitialized` when the name is present.
    pub fn putInitialized(self: *Host, src: *const SubmoduleConfig) (error_mod.Error || Allocator.Error)!void {
        if (self.initialized.contains(src.name)) return error.SubmoduleAlreadyInitialized;

        const m = try self.allocator.create(SubmoduleConfig);
        errdefer self.allocator.destroy(m);
        m.* = SubmoduleConfig.init(self.allocator);
        errdefer m.deinit();
        try setOwned(self.allocator, &m.name, src.name);
        try setOwned(self.allocator, &m.path, src.path);
        try setOwned(self.allocator, &m.url, src.url);
        try setOwned(self.allocator, &m.branch, src.branch);

        const key = try self.allocator.dupe(u8, src.name);
        errdefer self.allocator.free(key);
        try self.initialized.put(self.allocator, key, m);
    }
};

fn setOwned(allocator: Allocator, dest: *[]const u8, value: []const u8) Allocator.Error!void {
    if (dest.*.len > 0) allocator.free(dest.*);
    if (value.len == 0) {
        dest.* = "";
        return;
    }
    dest.* = try allocator.dupe(u8, value);
}
