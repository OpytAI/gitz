//! Minimal config storage for memory backend (go-git `ConfigStorage`).
//!
//! Storer-shaped config: `is_bare` + remotes map for BaseStorageSuite.
//! High-level remotes/branches/URLs live in `//src/config` (`gitconfig`).

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Validation / config storage errors (go-git config package subset).
pub const Error = error{
    /// Remote map key does not match remote name (go-git `ErrInvalid`).
    Invalid,
    /// Remote has empty name (go-git `ErrRemoteConfigEmptyName`).
    RemoteConfigEmptyName,
    /// Remote has no URLs (go-git `ErrRemoteConfigEmptyURL`).
    RemoteConfigEmptyURL,
};

/// Minimal remote config (go-git `RemoteConfig` subset: Name + URLs).
pub const RemoteConfig = struct {
    name: []u8 = &.{},
    urls: [][]u8 = &.{},

    pub fn deinit(self: *RemoteConfig, allocator: Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        for (self.urls) |u| allocator.free(u);
        if (self.urls.len > 0) allocator.free(self.urls);
        self.* = .{};
    }

    /// Validate name and URLs (go-git `RemoteConfig.Validate` subset).
    pub fn validate(self: *const RemoteConfig) Error!void {
        if (self.name.len == 0) return error.RemoteConfigEmptyName;
        if (self.urls.len == 0) return error.RemoteConfigEmptyURL;
    }
};

/// Minimal repository config (go-git `Config` subset for the storage suite).
pub const Config = struct {
    allocator: Allocator,
    is_bare: bool = false,
    remotes: std.StringHashMapUnmanaged(RemoteConfig) = .empty,

    pub fn init(allocator: Allocator) Config {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Config) void {
        var it = self.remotes.iterator();
        while (it.next()) |e| {
            var rc = e.value_ptr.*;
            rc.deinit(self.allocator);
            self.allocator.free(e.key_ptr.*);
        }
        self.remotes.deinit(self.allocator);
        self.* = undefined;
    }

    /// go-git `Config.Validate` subset: remotes key/name match, then remote Validate.
    /// Key mismatch → `error.Invalid` before empty-name checks (go-git order).
    pub fn validate(self: *const Config) Error!void {
        var it = self.remotes.iterator();
        while (it.next()) |e| {
            if (!std.mem.eql(u8, e.key_ptr.*, e.value_ptr.name)) return error.Invalid;
            try e.value_ptr.validate();
        }
    }

    /// Insert or replace a remote (copies name and urls).
    pub fn putRemote(self: *Config, name: []const u8, urls: []const []const u8) Allocator.Error!void {
        if (self.remotes.fetchRemove(name)) |old| {
            var rc = old.value;
            rc.deinit(self.allocator);
            self.allocator.free(old.key);
        }
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);
        var url_owned = try self.allocator.alloc([]u8, urls.len);
        errdefer self.allocator.free(url_owned);
        var i: usize = 0;
        errdefer {
            for (url_owned[0..i]) |u| self.allocator.free(u);
        }
        while (i < urls.len) : (i += 1) {
            url_owned[i] = try self.allocator.dupe(u8, urls[i]);
        }
        try self.remotes.put(self.allocator, key, .{
            .name = name_owned,
            .urls = url_owned,
        });
    }
};

/// go-git `ConfigStorage`.
pub const ConfigStorage = struct {
    allocator: Allocator,
    /// Stored config pointer (field cannot be named `config` — clashes with method).
    stored: ?*Config = null,

    pub fn init(allocator: Allocator) ConfigStorage {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ConfigStorage) void {
        if (self.stored) |c| {
            c.deinit();
            self.allocator.destroy(c);
            self.stored = null;
        }
    }

    /// go-git `SetConfig` — validates then stores pointer (takes ownership of `cfg`).
    /// On validation failure the caller's config is not stored and not freed.
    pub fn setConfig(self: *ConfigStorage, cfg: *Config) (Allocator.Error || Error)!void {
        try cfg.validate();
        if (self.stored) |old| {
            if (old != cfg) {
                old.deinit();
                self.allocator.destroy(old);
            }
        }
        self.stored = cfg;
    }

    /// go-git `Config` — returns stored config or a default empty config.
    pub fn config(self: *ConfigStorage) Allocator.Error!*Config {
        if (self.stored) |c| return c;
        const c = try self.allocator.create(Config);
        c.* = Config.init(self.allocator);
        self.stored = c;
        return c;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "RemoteConfig validate empty name" {
    const rc = RemoteConfig{};
    try std.testing.expectError(error.RemoteConfigEmptyName, rc.validate());
}

test "RemoteConfig validate empty urls" {
    const name = try std.testing.allocator.dupe(u8, "origin");
    defer std.testing.allocator.free(name);
    const rc = RemoteConfig{ .name = name };
    try std.testing.expectError(error.RemoteConfigEmptyURL, rc.validate());
}

test "Config validate key name mismatch is Invalid" {
    const allocator = std.testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit();

    const key = try allocator.dupe(u8, "foo");
    try cfg.remotes.put(allocator, key, .{});
    try std.testing.expectError(error.Invalid, cfg.validate());
}

test "Config validate empty remote name under matching key" {
    const allocator = std.testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit();

    // Empty name under empty key → RemoteConfigEmptyName (key matches name).
    const key = try allocator.dupe(u8, "");
    try cfg.remotes.put(allocator, key, .{});
    try std.testing.expectError(error.RemoteConfigEmptyName, cfg.validate());
}

test "ConfigStorage setConfig rejects invalid and get default" {
    const allocator = std.testing.allocator;
    var store = ConfigStorage.init(allocator);
    defer store.deinit();

    const bad = try allocator.create(Config);
    bad.* = Config.init(allocator);
    const key = try allocator.dupe(u8, "foo");
    try bad.remotes.put(allocator, key, .{});
    try std.testing.expectError(error.Invalid, store.setConfig(bad));
    // Not stored — caller still owns bad.
    bad.deinit();
    allocator.destroy(bad);

    const got = try store.config();
    try std.testing.expect(!got.is_bare);
    try std.testing.expectEqual(@as(usize, 0), got.remotes.count());
}

test "ConfigStorage setConfig and config round-trip" {
    const allocator = std.testing.allocator;
    var store = ConfigStorage.init(allocator);
    defer store.deinit();

    const cfg = try allocator.create(Config);
    cfg.* = Config.init(allocator);
    cfg.is_bare = true;
    try cfg.putRemote("origin", &[_][]const u8{"http://example.com/r.git"});
    try store.setConfig(cfg);

    const got = try store.config();
    try std.testing.expect(got.is_bare);
    const remote = got.remotes.get("origin") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("origin", remote.name);
    try std.testing.expectEqual(@as(usize, 1), remote.urls.len);
}
