//! Host linking memory storage + Mem FS for submodule ops.
//!
//! go-git binds Submodule to `*Worktree` and persists Init into
//! `Repository.Config().Submodules` then `Storer.SetConfig`. gitz memory
//! `Config` holds a `submodules` map for the same purpose. This Host keeps a
//! runtime registry of `*SubmoduleConfig` (gitconfig types) and **persists**
//! each Init into `storer.config()` so nested recursive Update hosts for the
//! same module storage re-load initialized state (go-git-faithful).
//!
//! # Ownership
//!
//! - Does **not** own `storer` or `filesystem` (borrowed from caller).
//! - Owns `initialized` map: keys and `*SubmoduleConfig` values are freed in
//!   `deinit`. `putInitialized` always copies name/path/url/branch into both
//!   the Host map and memory `Config.submodules`.
//! - Nested recursion builds a Host with a chroot Mem view of the parent path
//!   and the nested module storage. That Host **loads** any previously
//!   persisted Init entries from `mod.config()` so Init survives across nested
//!   update frames for the same module path.

const std = @import("std");
const memory = @import("memory");
const fs_pkg = @import("fs");
const gitconfig = @import("gitconfig");

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
    /// Initialized submodule configs (go-git `Config.Submodules`). Owned by Host;
    /// mirrored into `storer.config().submodules` on put.
    initialized: std.StringHashMapUnmanaged(*SubmoduleConfig) = .empty,

    pub fn init(allocator: Allocator, storer: *memory.Storage, filesystem: *fs_pkg.Mem) Host {
        var h: Host = .{
            .allocator = allocator,
            .storer = storer,
            .filesystem = filesystem,
        };
        // Seed from storer config (go-git Config.Submodules). Failures leave
        // an empty registry; Init can still populate via putInitialized.
        h.loadFromStorer() catch {};
        return h;
    }

    /// Build a Host from any handle with `.allocator`, `.storer`, `.filesystem`
    /// (e.g. `worktree.Worktree`). Avoids a package dependency cycle on worktree.
    pub fn fromWorktree(w: anytype) Host {
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
    ///
    /// Persists into `storer.config().submodules` (go-git Init → Config.Submodules
    /// + SetConfig) so a later Host on the same storer still sees the entry.
    /// Returns `SubmoduleAlreadyInitialized` when the name is present.
    pub fn putInitialized(self: *Host, src: *const SubmoduleConfig) (error_mod.Error || Allocator.Error)!void {
        if (self.initialized.contains(src.name)) return error.SubmoduleAlreadyInitialized;

        // Storer may already have the entry (Host map rebuilt incompletely).
        const cfg = try self.storer.config();
        if (cfg.hasSubmodule(src.name)) return error.SubmoduleAlreadyInitialized;

        const m = try self.allocator.create(SubmoduleConfig);
        errdefer self.allocator.destroy(m);
        m.* = SubmoduleConfig.init(self.allocator);
        errdefer m.deinit();
        try setOwned(self.allocator, &m.name, src.name);
        try setOwned(self.allocator, &m.path, src.path);
        try setOwned(self.allocator, &m.url, src.url);
        try setOwned(self.allocator, &m.branch, src.branch);

        // Persist first (go-git SetConfig) so a partial Host put can be retried.
        try cfg.putSubmodule(src.name, src.path, src.url, src.branch);
        errdefer _ = cfg.removeSubmodule(src.name);

        const key = try self.allocator.dupe(u8, src.name);
        errdefer self.allocator.free(key);
        try self.initialized.put(self.allocator, key, m);
        // Success: map owns `key` and `m`; errdefers do not run.
    }

    /// Load initialized entries from `storer.config().submodules` into the Host map.
    /// Entries already present in the map are skipped.
    fn loadFromStorer(self: *Host) !void {
        const cfg = try self.storer.config();
        var it = cfg.submodules.iterator();
        while (it.next()) |e| {
            const entry = e.value_ptr.*;
            if (self.initialized.contains(entry.name)) continue;

            const m = try self.allocator.create(SubmoduleConfig);
            errdefer self.allocator.destroy(m);
            m.* = SubmoduleConfig.init(self.allocator);
            errdefer m.deinit();
            try setOwned(self.allocator, &m.name, entry.name);
            try setOwned(self.allocator, &m.path, entry.path);
            try setOwned(self.allocator, &m.url, entry.url);
            try setOwned(self.allocator, &m.branch, entry.branch);

            const key = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(key);
            try self.initialized.put(self.allocator, key, m);
        }
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
