//! Minimal config storage for memory backend (go-git `ConfigStorage`).
//!
//! Storer-shaped config: `is_bare` + remotes + branches for BaseStorageSuite and
//! repository CreateRemote/CreateBranch (without depending on `//src/config`).
//! High-level remotes/branches/URLs with full gitconfig live in `//src/config`.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Validation / config storage errors (go-git config package subset).
pub const Error = error{
    /// Remote/branch map key does not match entry name (go-git `ErrInvalid`).
    Invalid,
    /// Remote has empty name (go-git `ErrRemoteConfigEmptyName`).
    RemoteConfigEmptyName,
    /// Remote has no URLs (go-git `ErrRemoteConfigEmptyURL`).
    RemoteConfigEmptyURL,
};

/// Minimal remote config (go-git `RemoteConfig` subset: Name, URLs, Fetch, Mirror).
///
/// `fetch` holds refspec strings (not parsed). Empty means "unset" at storage level
/// (go-git fills a default on high-level Validate; we do not invent defaults here).
pub const RemoteConfig = struct {
    name: []u8 = &.{},
    urls: [][]u8 = &.{},
    /// Fetch refspec strings (optional; may be empty).
    fetch: [][]u8 = &.{},
    mirror: bool = false,

    pub fn deinit(self: *RemoteConfig, allocator: Allocator) void {
        freeOwned(allocator, self.name);
        freeStringSlice(allocator, self.urls);
        freeStringSlice(allocator, self.fetch);
        self.* = .{};
    }

    /// Validate name and URLs (go-git `RemoteConfig.Validate` subset).
    pub fn validate(self: *const RemoteConfig) Error!void {
        if (self.name.len == 0) return error.RemoteConfigEmptyName;
        if (self.urls.len == 0) return error.RemoteConfigEmptyURL;
    }
};

/// Minimal branch tracking config (go-git `Branch` subset: Name, Remote, Merge).
/// `merge` is a ref name string (e.g. `refs/heads/main`), not a plumbing type.
pub const BranchConfig = struct {
    name: []u8 = &.{},
    remote: []u8 = &.{},
    merge: []u8 = &.{},

    pub fn deinit(self: *BranchConfig, allocator: Allocator) void {
        freeOwned(allocator, self.name);
        freeOwned(allocator, self.remote);
        freeOwned(allocator, self.merge);
        self.* = .{};
    }
};

/// Minimal repository config (go-git `Config` subset for storage / CreateRemote / CreateBranch).
pub const Config = struct {
    allocator: Allocator,
    is_bare: bool = false,
    /// `core.repositoryformatversion` (owned; empty means unset / "0").
    repository_format_version: []u8 = &.{},
    /// `extensions.objectformat` (owned; empty / "sha1" / "sha256").
    object_format: []u8 = &.{},
    remotes: std.StringHashMapUnmanaged(RemoteConfig) = .empty,
    branches: std.StringHashMapUnmanaged(BranchConfig) = .empty,

    pub fn init(allocator: Allocator) Config {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Config) void {
        freeOwned(self.allocator, self.repository_format_version);
        freeOwned(self.allocator, self.object_format);

        var rit = self.remotes.iterator();
        while (rit.next()) |e| {
            var rc = e.value_ptr.*;
            rc.deinit(self.allocator);
            freeOwned(self.allocator, e.key_ptr.*);
        }
        self.remotes.deinit(self.allocator);

        var bit = self.branches.iterator();
        while (bit.next()) |e| {
            var bc = e.value_ptr.*;
            bc.deinit(self.allocator);
            freeOwned(self.allocator, e.key_ptr.*);
        }
        self.branches.deinit(self.allocator);

        self.* = undefined;
    }

    /// Set `core.repositoryformatversion` (copies `version`).
    pub fn setRepositoryFormatVersion(self: *Config, version: []const u8) Allocator.Error!void {
        freeOwned(self.allocator, self.repository_format_version);
        self.repository_format_version = try dupeOrEmpty(self.allocator, version);
    }

    /// Set `extensions.objectformat` (copies `format`).
    pub fn setObjectFormat(self: *Config, format: []const u8) Allocator.Error!void {
        freeOwned(self.allocator, self.object_format);
        self.object_format = try dupeOrEmpty(self.allocator, format);
    }

    /// go-git `Config.Validate` subset: remotes/branches key/name match, then remote Validate.
    /// Key mismatch → `error.Invalid` before empty-name checks (go-git order).
    pub fn validate(self: *const Config) Error!void {
        var rit = self.remotes.iterator();
        while (rit.next()) |e| {
            if (!std.mem.eql(u8, e.key_ptr.*, e.value_ptr.name)) return error.Invalid;
            try e.value_ptr.validate();
        }
        var bit = self.branches.iterator();
        while (bit.next()) |e| {
            if (!std.mem.eql(u8, e.key_ptr.*, e.value_ptr.name)) return error.Invalid;
        }
    }

    /// Insert or replace a remote (copies name and urls; fetch empty, mirror false).
    /// API stable for BaseStorageSuite: `putRemote(name, urls)`.
    pub fn putRemote(self: *Config, name: []const u8, urls: []const []const u8) Allocator.Error!void {
        return self.putRemoteFull(name, urls, &.{}, false);
    }

    /// Insert or replace a remote with fetch refspecs and mirror flag (copies all strings).
    /// Alias name `setRemote` kept for call sites that prefer that wording.
    pub fn putRemoteFull(
        self: *Config,
        name: []const u8,
        urls: []const []const u8,
        fetch: []const []const u8,
        mirror: bool,
    ) Allocator.Error!void {
        if (self.remotes.fetchRemove(name)) |old| {
            var rc = old.value;
            rc.deinit(self.allocator);
            freeOwned(self.allocator, old.key);
        }
        const key = try dupeOrEmpty(self.allocator, name);
        errdefer freeOwned(self.allocator, key);
        const name_owned = try dupeOrEmpty(self.allocator, name);
        errdefer freeOwned(self.allocator, name_owned);
        const url_owned = try dupeStringSlice(self.allocator, urls);
        errdefer freeStringSlice(self.allocator, url_owned);
        const fetch_owned = try dupeStringSlice(self.allocator, fetch);
        errdefer freeStringSlice(self.allocator, fetch_owned);
        try self.remotes.put(self.allocator, key, .{
            .name = name_owned,
            .urls = url_owned,
            .fetch = fetch_owned,
            .mirror = mirror,
        });
    }

    pub const setRemote = putRemoteFull;

    /// Remove a remote by name if present. Returns true when removed.
    pub fn removeRemote(self: *Config, name: []const u8) bool {
        if (self.remotes.fetchRemove(name)) |old| {
            var rc = old.value;
            rc.deinit(self.allocator);
            freeOwned(self.allocator, old.key);
            return true;
        }
        return false;
    }

    /// Insert or replace a branch tracking entry (copies name, remote, merge).
    pub fn putBranch(self: *Config, name: []const u8, remote: []const u8, merge: []const u8) Allocator.Error!void {
        if (self.branches.fetchRemove(name)) |old| {
            var bc = old.value;
            bc.deinit(self.allocator);
            freeOwned(self.allocator, old.key);
        }
        const key = try dupeOrEmpty(self.allocator, name);
        errdefer freeOwned(self.allocator, key);
        const name_owned = try dupeOrEmpty(self.allocator, name);
        errdefer freeOwned(self.allocator, name_owned);
        const remote_owned = try dupeOrEmpty(self.allocator, remote);
        errdefer freeOwned(self.allocator, remote_owned);
        const merge_owned = try dupeOrEmpty(self.allocator, merge);
        errdefer freeOwned(self.allocator, merge_owned);
        try self.branches.put(self.allocator, key, .{
            .name = name_owned,
            .remote = remote_owned,
            .merge = merge_owned,
        });
    }

    /// Remove a branch by name if present. Returns true when removed.
    pub fn removeBranch(self: *Config, name: []const u8) bool {
        if (self.branches.fetchRemove(name)) |old| {
            var bc = old.value;
            bc.deinit(self.allocator);
            freeOwned(self.allocator, old.key);
            return true;
        }
        return false;
    }
};

fn freeOwned(allocator: Allocator, s: []const u8) void {
    // HashMap keys are typed `[]const u8` but we always allocate them as owned.
    if (s.len > 0) allocator.free(@constCast(s));
}

fn dupeOrEmpty(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    if (s.len == 0) return &.{};
    return try allocator.dupe(u8, s);
}

fn freeStringSlice(allocator: Allocator, items: [][]u8) void {
    for (items) |s| freeOwned(allocator, s);
    if (items.len > 0) allocator.free(items);
}

fn dupeStringSlice(allocator: Allocator, src: []const []const u8) Allocator.Error![][]u8 {
    if (src.len == 0) return &.{};
    var owned = try allocator.alloc([]u8, src.len);
    errdefer allocator.free(owned);
    var i: usize = 0;
    errdefer {
        for (owned[0..i]) |s| freeOwned(allocator, s);
    }
    while (i < src.len) : (i += 1) {
        owned[i] = try dupeOrEmpty(allocator, src[i]);
    }
    return owned;
}

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

test "Config validate branch key name mismatch is Invalid" {
    const allocator = std.testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit();

    const key = try allocator.dupe(u8, "main");
    try cfg.branches.put(allocator, key, .{});
    try std.testing.expectError(error.Invalid, cfg.validate());
}

test "Config putBranch removeBranch" {
    const allocator = std.testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit();

    try cfg.putBranch("main", "origin", "refs/heads/main");
    try cfg.validate();
    const b = cfg.branches.get("main") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("main", b.name);
    try std.testing.expectEqualStrings("origin", b.remote);
    try std.testing.expectEqualStrings("refs/heads/main", b.merge);

    try cfg.putBranch("main", "upstream", "refs/heads/master");
    const b2 = cfg.branches.get("main") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("upstream", b2.remote);
    try std.testing.expectEqualStrings("refs/heads/master", b2.merge);

    try std.testing.expect(cfg.removeBranch("main"));
    try std.testing.expect(!cfg.removeBranch("main"));
    try std.testing.expect(cfg.branches.get("main") == null);
}

test "Config setRemote fetch and mirror; putRemote and removeRemote" {
    const allocator = std.testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit();

    try cfg.putRemoteFull(
        "origin",
        &[_][]const u8{"http://example.com/r.git"},
        &[_][]const u8{"+refs/heads/*:refs/remotes/origin/*"},
        true,
    );
    try cfg.validate();
    const r = cfg.remotes.get("origin") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), r.fetch.len);
    try std.testing.expectEqualStrings("+refs/heads/*:refs/remotes/origin/*", r.fetch[0]);
    try std.testing.expect(r.mirror);

    // putRemote replaces with empty fetch / mirror false (suite API).
    try cfg.putRemote("origin", &[_][]const u8{"http://other/r.git"});
    const r2 = cfg.remotes.get("origin") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("http://other/r.git", r2.urls[0]);
    try std.testing.expectEqual(@as(usize, 0), r2.fetch.len);
    try std.testing.expect(!r2.mirror);

    try std.testing.expect(cfg.removeRemote("origin"));
    try std.testing.expect(!cfg.removeRemote("origin"));
    try std.testing.expect(cfg.remotes.get("origin") == null);
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
    try std.testing.expectEqual(@as(usize, 0), got.branches.count());
}

test "ConfigStorage setConfig and config round-trip" {
    const allocator = std.testing.allocator;
    var store = ConfigStorage.init(allocator);
    defer store.deinit();

    const cfg = try allocator.create(Config);
    cfg.* = Config.init(allocator);
    cfg.is_bare = true;
    try cfg.putRemote("origin", &[_][]const u8{"http://example.com/r.git"});
    try cfg.putBranch("main", "origin", "refs/heads/main");
    try store.setConfig(cfg);

    const got = try store.config();
    try std.testing.expect(got.is_bare);
    const remote = got.remotes.get("origin") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("origin", remote.name);
    try std.testing.expectEqual(@as(usize, 1), remote.urls.len);
    const branch = got.branches.get("main") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("origin", branch.remote);
    try std.testing.expectEqualStrings("refs/heads/main", branch.merge);
}
