//! Transactional config storer (go-git `storage/transactional` ConfigStorage).
//!
//! After `setConfig`, reads come from temporal. `commit` clones temporal → base.

const std = @import("std");
const memory = @import("memory");

const Allocator = std.mem.Allocator;
const Config = memory.Config;

/// go-git `transactional.ConfigStorage`.
pub const ConfigStorage = struct {
    base: *memory.Storage,
    temporal: *memory.Storage,
    /// True after a successful SetConfig (go-git `set`).
    set: bool = false,

    pub fn init(base: *memory.Storage, temporal: *memory.Storage) ConfigStorage {
        return .{ .base = base, .temporal = temporal };
    }

    /// go-git `SetConfig` — write temporal; mark set.
    pub fn setConfig(self: *ConfigStorage, cfg: *Config) (Allocator.Error || memory.ConfigError)!void {
        try self.temporal.setConfig(cfg);
        self.set = true;
    }

    /// go-git `Config` — temporal when set, else base.
    pub fn config(self: *ConfigStorage) Allocator.Error!*Config {
        if (!self.set) return self.base.config();
        return self.temporal.config();
    }

    /// go-git `Commit` — copy temporal config into base when set.
    pub fn commit(self: *ConfigStorage) (Allocator.Error || memory.ConfigError)!void {
        if (!self.set) return;

        const src = try self.temporal.config();
        const copy = try cloneConfig(self.base.allocator, src);
        // setConfig takes ownership on success; on validate failure caller keeps it.
        self.base.setConfig(copy) catch |err| {
            copy.deinit();
            self.base.allocator.destroy(copy);
            return err;
        };
    }
};

/// go-git `NewConfigStorage(base, temporal)`.
pub fn newConfigStorage(base: *memory.Storage, temporal: *memory.Storage) ConfigStorage {
    return ConfigStorage.init(base, temporal);
}

fn cloneConfig(allocator: Allocator, src: *const Config) Allocator.Error!*Config {
    const dst = try allocator.create(Config);
    dst.* = Config.init(allocator);
    errdefer {
        dst.deinit();
        allocator.destroy(dst);
    }
    dst.is_bare = src.is_bare;
    if (src.repository_format_version.len > 0) {
        try dst.setRepositoryFormatVersion(src.repository_format_version);
    }
    if (src.object_format.len > 0) {
        try dst.setObjectFormat(src.object_format);
    }
    if (src.user_name.len > 0 or src.user_email.len > 0) {
        try dst.setUser(src.user_name, src.user_email);
    }
    if (src.author_name.len > 0 or src.author_email.len > 0) {
        try dst.setAuthor(src.author_name, src.author_email);
    }
    if (src.committer_name.len > 0 or src.committer_email.len > 0) {
        try dst.setCommitter(src.committer_name, src.committer_email);
    }
    var rit = src.remotes.iterator();
    while (rit.next()) |e| {
        var urls_buf: std.ArrayList([]const u8) = .empty;
        defer urls_buf.deinit(allocator);
        for (e.value_ptr.urls) |u| {
            try urls_buf.append(allocator, u);
        }
        var fetch_buf: std.ArrayList([]const u8) = .empty;
        defer fetch_buf.deinit(allocator);
        for (e.value_ptr.fetch) |f| {
            try fetch_buf.append(allocator, f);
        }
        try dst.putRemoteFull(e.key_ptr.*, urls_buf.items, fetch_buf.items, e.value_ptr.mirror);
    }
    var bit = src.branches.iterator();
    while (bit.next()) |e| {
        try dst.putBranch(e.value_ptr.name, e.value_ptr.remote, e.value_ptr.merge);
    }
    return dst;
}

// ---------------------------------------------------------------------------
// Tests (go-git config_test.go — uses is_bare; memory Config has no Worktree yet)
// ---------------------------------------------------------------------------

test "Config reads base when not set" {
    const allocator = std.testing.allocator;
    const base = try memory.newStorage(allocator);
    defer {
        base.deinit();
        allocator.destroy(base);
    }
    const temporal = try memory.newStorage(allocator);
    defer {
        temporal.deinit();
        allocator.destroy(temporal);
    }

    const cfg = try allocator.create(Config);
    cfg.* = Config.init(allocator);
    cfg.is_bare = true;
    try base.setConfig(cfg);

    var cs = ConfigStorage.init(base, temporal);
    const got = try cs.config();
    try std.testing.expect(got.is_bare);
}

test "Config set goes to temporal not base" {
    const allocator = std.testing.allocator;
    const base = try memory.newStorage(allocator);
    defer {
        base.deinit();
        allocator.destroy(base);
    }
    const temporal = try memory.newStorage(allocator);
    defer {
        temporal.deinit();
        allocator.destroy(temporal);
    }

    const cfg_base = try allocator.create(Config);
    cfg_base.* = Config.init(allocator);
    cfg_base.is_bare = false;
    try base.setConfig(cfg_base);

    const cfg_tmp = try allocator.create(Config);
    cfg_tmp.* = Config.init(allocator);
    cfg_tmp.is_bare = true;

    var cs = ConfigStorage.init(base, temporal);
    try cs.setConfig(cfg_tmp);

    const base_cfg = try base.config();
    try std.testing.expect(!base_cfg.is_bare);

    const temporal_cfg = try temporal.config();
    try std.testing.expect(temporal_cfg.is_bare);

    const view = try cs.config();
    try std.testing.expect(view.is_bare);
}

test "Config Commit copies temporal to base" {
    const allocator = std.testing.allocator;
    const base = try memory.newStorage(allocator);
    defer {
        base.deinit();
        allocator.destroy(base);
    }
    const temporal = try memory.newStorage(allocator);
    defer {
        temporal.deinit();
        allocator.destroy(temporal);
    }

    const cfg_base = try allocator.create(Config);
    cfg_base.* = Config.init(allocator);
    cfg_base.is_bare = false;
    try base.setConfig(cfg_base);

    const cfg_tmp = try allocator.create(Config);
    cfg_tmp.* = Config.init(allocator);
    cfg_tmp.is_bare = true;

    var cs = ConfigStorage.init(base, temporal);
    try cs.setConfig(cfg_tmp);
    try cs.commit();

    const base_cfg = try base.config();
    try std.testing.expect(base_cfg.is_bare);
}
