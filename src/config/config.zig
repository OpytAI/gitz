//! Typed repository configuration (go-git `config/config.go`).
//!
//! Builds on `plumbing/format/config` (`@import("config")`) for encode/decode.
//! This package is imported as `gitconfig` to avoid clashing with the format module.

const std = @import("std");
const plumbing = @import("plumbing");
const format_config = @import("config");
const internal_url = @import("url");

const optbool_mod = @import("optbool.zig");
const refspec_mod = @import("refspec.zig");
const branch_mod = @import("branch.zig");
const url_mod = @import("url.zig");
const modules_mod = @import("modules.zig");
const owned_mod = @import("owned.zig");

const Allocator = std.mem.Allocator;
const OptBool = optbool_mod.OptBool;
const RefSpec = refspec_mod.RefSpec;
const Branch = branch_mod.Branch;
const URL = url_mod.URL;
const Submodule = modules_mod.Submodule;
const Subsection = format_config.Subsection;
const setOwned = owned_mod.setOwned;
const freeOwned = owned_mod.freeOwned;
const freeStringList = owned_mod.freeStringList;

/// Default fetch refspec template; `%s` is the remote name.
pub const default_fetch_ref_spec = "+refs/heads/*:refs/remotes/{s}/*";

/// Default push refspec (go-git `DefaultPushRefSpec`).
pub const default_push_ref_spec = "refs/heads/*:refs/heads/*";

/// Default pack window (go-git `DefaultPackWindow`).
pub const default_pack_window: u32 = 10;

// Section / key names (go-git package constants).
const remote_section = "remote";
const submodule_section = "submodule";
const branch_section = "branch";
const core_section = "core";
const pack_section = "pack";
const user_section = "user";
const author_section = "author";
const committer_section = "committer";
const init_section = "init";
const url_section = "url";
const extensions_section = "extensions";
const fetch_key = "fetch";
const url_key = "url";
const pushurl_key = "pushurl";
const bare_key = "bare";
const worktree_key = "worktree";
const comment_char_key = "commentChar";
const window_key = "window";
const name_key = "name";
const email_key = "email";
const default_branch_key = "defaultBranch";
const repository_format_version_key = "repositoryformatversion";
const object_format_key = "objectformat";
const mirror_key = "mirror";
const protect_ntfs_key = "protectNTFS";
const protect_hfs_key = "protectHFS";

/// Config / remote errors (go-git package vars).
pub const Error = error{
    /// go-git `ErrInvalid`.
    Invalid,
    /// go-git `ErrRemoteConfigNotFound`.
    RemoteConfigNotFound,
    /// go-git `ErrRemoteConfigEmptyURL`.
    RemoteConfigEmptyURL,
    /// go-git `ErrRemoteConfigEmptyName`.
    RemoteConfigEmptyName,
    /// LocalScope must be read from a ConfigStorer.
    LocalScopeNotSupported,
};

pub const ConfigError = Error ||
    Allocator.Error ||
    format_config.Error ||
    refspec_mod.Error ||
    branch_mod.Error ||
    url_mod.Error ||
    modules_mod.Error ||
    plumbing.Error ||
    std.Io.Writer.Error ||
    std.fmt.ParseIntError;

/// Config scope (go-git `Scope`).
pub const Scope = enum {
    local,
    global,
    system,
};

/// Core section (go-git `Config.Core`).
pub const Core = struct {
    is_bare: bool = false,
    worktree: []const u8 = "",
    comment_char: []const u8 = "",
    repository_format_version: []const u8 = "",
    protect_ntfs: OptBool = .unset,
    protect_hfs: OptBool = .unset,
};

/// User identity (go-git `Config.User` / Author / Committer).
pub const Identity = struct {
    name: []const u8 = "",
    email: []const u8 = "",
};

/// Pack section.
pub const Pack = struct {
    window: u32 = default_pack_window,
};

/// Init section.
pub const Init = struct {
    default_branch: []const u8 = "",
};

/// Extensions section.
pub const Extensions = struct {
    object_format: []const u8 = "",
};

/// Remote configuration (go-git `RemoteConfig`).
pub const RemoteConfig = struct {
    allocator: Allocator,
    name: []const u8 = "",
    urls: []const []const u8 = &.{},
    mirror: bool = false,
    instead_of_rules_applied: bool = false,
    original_urls: []const []const u8 = &.{},
    fetch: []const RefSpec = &.{},
    /// Borrowed subsection in Config.raw (not owned).
    raw: ?*Subsection = null,

    pub fn init(allocator: Allocator) RemoteConfig {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RemoteConfig) void {
        freeOwned(self.allocator, &self.name);
        freeStringList(self.allocator, &self.urls);
        freeStringList(self.allocator, &self.original_urls);
        freeFetch(self.allocator, &self.fetch);
        self.raw = null;
        self.* = undefined;
    }

    /// go-git `RemoteConfig.Validate` — may set default fetch.
    pub fn validate(self: *RemoteConfig) ConfigError!void {
        if (self.name.len == 0) return error.RemoteConfigEmptyName;
        if (self.urls.len == 0) return error.RemoteConfigEmptyURL;

        for (self.fetch) |rs| {
            try rs.validate();
        }

        if (self.fetch.len == 0) {
            const s = try std.fmt.allocPrint(self.allocator, default_fetch_ref_spec, .{self.name});
            errdefer self.allocator.free(s);
            const arr = try self.allocator.alloc(RefSpec, 1);
            arr[0] = RefSpec.init(s);
            self.fetch = arr;
        }

        var buf: [512]u8 = undefined;
        // Fixed-buffer format may yield `NoSpaceLeft`; map to invalid ref name.
        const head_ref = plumbing.newRemoteHEADReferenceName(self.name, &buf) catch return error.InvalidReferenceName;
        try head_ref.validate();
    }

    /// go-git `IsFirstURLLocal`.
    pub fn isFirstURLLocal(self: *const RemoteConfig) bool {
        if (self.urls.len == 0) return false;
        return internal_url.isLocalEndpoint(self.urls[0]);
    }

    fn unmarshal(self: *RemoteConfig, s: *Subsection) ConfigError!void {
        self.raw = s;
        try setOwned(self.allocator, &self.name, s.name);

        const url_vals = try s.optionAll(self.allocator, url_key);
        defer self.allocator.free(url_vals);
        const push_vals = try s.optionAll(self.allocator, pushurl_key);
        defer self.allocator.free(push_vals);

        freeStringList(self.allocator, &self.urls);
        const total = url_vals.len + push_vals.len;
        if (total == 0) {
            self.urls = &.{};
        } else {
            var list = try self.allocator.alloc([]const u8, total);
            errdefer {
                // free only filled
                self.allocator.free(list);
            }
            var i: usize = 0;
            errdefer {
                for (list[0..i]) |u| self.allocator.free(u);
            }
            for (url_vals) |u| {
                list[i] = try self.allocator.dupe(u8, u);
                i += 1;
            }
            for (push_vals) |u| {
                list[i] = try self.allocator.dupe(u8, u);
                i += 1;
            }
            self.urls = list;
        }

        const fetch_vals = try s.optionAll(self.allocator, fetch_key);
        defer self.allocator.free(fetch_vals);
        freeFetch(self.allocator, &self.fetch);
        if (fetch_vals.len == 0) {
            self.fetch = &.{};
        } else {
            var list = try self.allocator.alloc(RefSpec, fetch_vals.len);
            errdefer self.allocator.free(list);
            var i: usize = 0;
            errdefer {
                for (list[0..i]) |rs| self.allocator.free(rs.raw);
            }
            for (fetch_vals) |f| {
                const owned = try self.allocator.dupe(u8, f);
                const rs = RefSpec.init(owned);
                try rs.validate();
                list[i] = rs;
                i += 1;
            }
            self.fetch = list;
        }

        self.mirror = std.mem.eql(u8, s.option(mirror_key), "true");
    }

    fn marshal(self: *RemoteConfig) Allocator.Error!*Subsection {
        if (self.raw == null) {
            self.raw = try Subsection.create(self.allocator, self.name);
        }
        const r = self.raw.?;
        if (!std.mem.eql(u8, r.name, self.name)) {
            self.allocator.free(r.name);
            r.name = try self.allocator.dupe(u8, self.name);
        }

        if (self.urls.len == 0) {
            _ = r.removeOption(url_key);
        } else {
            const urls = if (self.instead_of_rules_applied) self.original_urls else self.urls;
            _ = try r.setOption(url_key, urls);
        }

        if (self.fetch.len == 0) {
            _ = r.removeOption(fetch_key);
        } else {
            var values = try self.allocator.alloc([]const u8, self.fetch.len);
            defer self.allocator.free(values);
            for (self.fetch, 0..) |rs, i| {
                values[i] = rs.raw;
            }
            _ = try r.setOption(fetch_key, values);
        }

        if (self.mirror) {
            const values = [_][]const u8{"true"};
            _ = try r.setOption(mirror_key, &values);
        }

        return r;
    }

    fn applyURLRules(self: *RemoteConfig, urls: *const std.StringHashMapUnmanaged(*URL)) Allocator.Error!void {
        if (self.urls.len == 0) return;

        var original = try self.allocator.alloc([]const u8, self.urls.len);
        errdefer {
            for (original) |u| self.allocator.free(u);
            self.allocator.free(original);
        }
        for (self.urls, 0..) |u, i| {
            original[i] = try self.allocator.dupe(u8, u);
        }

        var applied = false;
        var new_urls = try self.allocator.alloc([]const u8, self.urls.len);
        errdefer {
            for (new_urls) |u| self.allocator.free(u);
            self.allocator.free(new_urls);
        }
        // Track how many new_urls filled for errdefer — fill all or none via temps.
        for (self.urls, 0..) |u, i| {
            if (url_mod.findLongestInsteadOfMatch(u, urls)) |rule| {
                new_urls[i] = try rule.applyInsteadOf(self.allocator, u);
                applied = true;
            } else {
                new_urls[i] = try self.allocator.dupe(u8, u);
            }
        }

        freeStringList(self.allocator, &self.urls);
        self.urls = new_urls;

        if (applied) {
            freeStringList(self.allocator, &self.original_urls);
            self.original_urls = original;
            self.instead_of_rules_applied = true;
        } else {
            for (original) |u| self.allocator.free(u);
            self.allocator.free(original);
        }
    }
};

/// Repository configuration (go-git `Config`).
pub const Config = struct {
    allocator: Allocator,
    core: Core = .{},
    user: Identity = .{},
    author: Identity = .{},
    committer: Identity = .{},
    pack: Pack = .{},
    init: Init = .{},
    extensions: Extensions = .{},
    remotes: std.StringHashMapUnmanaged(*RemoteConfig) = .empty,
    submodules: std.StringHashMapUnmanaged(*Submodule) = .empty,
    branches: std.StringHashMapUnmanaged(*Branch) = .empty,
    urls: std.StringHashMapUnmanaged(*URL) = .empty,
    /// Raw format tree (owned).
    raw: *format_config.Config,

    /// go-git `NewConfig` — construct empty typed config (field `init` holds Init section).
    pub fn create(allocator: Allocator) Allocator.Error!Config {
        const raw = try allocator.create(format_config.Config);
        raw.* = format_config.Config.init(allocator);
        return .{
            .allocator = allocator,
            .pack = .{ .window = default_pack_window },
            .raw = raw,
        };
    }

    pub fn deinit(self: *Config) void {
        freeCoreStrings(self);
        freeIdentity(self.allocator, &self.user);
        freeIdentity(self.allocator, &self.author);
        freeIdentity(self.allocator, &self.committer);
        freeOwned(self.allocator, &self.init.default_branch);
        freeOwned(self.allocator, &self.extensions.object_format);

        clearMapRemote(self);
        self.remotes.deinit(self.allocator);
        clearMapSubmodule(self);
        self.submodules.deinit(self.allocator);
        clearMapBranch(self);
        self.branches.deinit(self.allocator);
        clearMapURL(self);
        self.urls.deinit(self.allocator);

        self.raw.deinit();
        self.allocator.destroy(self.raw);
        self.* = undefined;
    }

    /// go-git `Config.Validate`.
    pub fn validate(self: *Config) ConfigError!void {
        var rit = self.remotes.iterator();
        while (rit.next()) |e| {
            if (!std.mem.eql(u8, e.key_ptr.*, e.value_ptr.*.name)) return error.Invalid;
            try e.value_ptr.*.validate();
        }
        var bit = self.branches.iterator();
        while (bit.next()) |e| {
            if (!std.mem.eql(u8, e.key_ptr.*, e.value_ptr.*.name)) return error.Invalid;
            try e.value_ptr.*.validate();
        }
    }

    /// go-git `Config.Unmarshal`.
    pub fn unmarshal(self: *Config, data: []const u8) ConfigError!void {
        // Reset typed state.
        freeCoreStrings(self);
        freeIdentity(self.allocator, &self.user);
        freeIdentity(self.allocator, &self.author);
        freeIdentity(self.allocator, &self.committer);
        freeOwned(self.allocator, &self.init.default_branch);
        freeOwned(self.allocator, &self.extensions.object_format);
        self.core = .{};
        self.pack = .{ .window = default_pack_window };
        self.init = .{};
        self.extensions = .{};

        clearMapRemote(self);
        clearMapSubmodule(self);
        clearMapBranch(self);
        clearMapURL(self);

        self.raw.deinit();
        self.raw.* = format_config.Config.init(self.allocator);

        var r: std.Io.Reader = .fixed(data);
        var dec = format_config.Decoder.init(&r);
        try dec.decode(self.raw);

        try self.unmarshalCore();
        try self.unmarshalUser();
        try self.unmarshalInit();
        try self.unmarshalPack();
        try modules_mod.unmarshalSubmodules(self.allocator, self.raw, &self.submodules);
        try self.unmarshalBranches();
        try self.unmarshalURLs();
        try self.unmarshalRemotes();
    }

    /// go-git `Config.Marshal`.
    pub fn marshal(self: *Config) ConfigError![]u8 {
        try self.marshalCore();
        try self.marshalExtensions();
        try self.marshalUser();
        try self.marshalPack();
        try self.marshalRemotes();
        try self.marshalSubmodules();
        try self.marshalBranches();
        try self.marshalURLs();
        try self.marshalInit();

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        var enc = format_config.Encoder.init(&aw.writer);
        try enc.encode(self.raw);
        return try aw.toOwnedSlice();
    }

    fn unmarshalCore(self: *Config) Allocator.Error!void {
        const s = try self.raw.section(core_section);
        if (std.mem.eql(u8, s.option(bare_key), "true")) {
            self.core.is_bare = true;
        }
        try setOwned(self.allocator, &self.core.worktree, s.option(worktree_key));
        try setOwned(self.allocator, &self.core.comment_char, s.option(comment_char_key));

        const p_ntfs = optbool_mod.parseConfigBool(s.option(protect_ntfs_key));
        if (p_ntfs.isSet()) self.core.protect_ntfs = p_ntfs;
        const p_hfs = optbool_mod.parseConfigBool(s.option(protect_hfs_key));
        if (p_hfs.isSet()) self.core.protect_hfs = p_hfs;
    }

    fn unmarshalUser(self: *Config) Allocator.Error!void {
        {
            const s = try self.raw.section(user_section);
            try setOwned(self.allocator, &self.user.name, s.option(name_key));
            try setOwned(self.allocator, &self.user.email, s.option(email_key));
        }
        {
            const s = try self.raw.section(author_section);
            try setOwned(self.allocator, &self.author.name, s.option(name_key));
            try setOwned(self.allocator, &self.author.email, s.option(email_key));
        }
        {
            const s = try self.raw.section(committer_section);
            try setOwned(self.allocator, &self.committer.name, s.option(name_key));
            try setOwned(self.allocator, &self.committer.email, s.option(email_key));
        }
    }

    fn unmarshalPack(self: *Config) ConfigError!void {
        const s = try self.raw.section(pack_section);
        const window = s.option(window_key);
        if (window.len == 0) {
            self.pack.window = default_pack_window;
        } else {
            self.pack.window = try std.fmt.parseInt(u32, window, 10);
        }
    }

    fn unmarshalInit(self: *Config) Allocator.Error!void {
        const s = try self.raw.section(init_section);
        try setOwned(self.allocator, &self.init.default_branch, s.option(default_branch_key));
    }

    fn unmarshalRemotes(self: *Config) ConfigError!void {
        if (!self.raw.hasSection(remote_section)) {
            // still apply rules on empty
        } else {
            const s = try self.raw.section(remote_section);
            for (s.subsections.items) |sub| {
                const r = try self.allocator.create(RemoteConfig);
                errdefer self.allocator.destroy(r);
                r.* = RemoteConfig.init(self.allocator);
                errdefer r.deinit();
                try r.unmarshal(sub);
                const key = try self.allocator.dupe(u8, r.name);
                errdefer self.allocator.free(key);
                try self.remotes.put(self.allocator, key, r);
            }
        }

        var it = self.remotes.iterator();
        while (it.next()) |e| {
            try e.value_ptr.*.applyURLRules(&self.urls);
        }
    }

    fn unmarshalURLs(self: *Config) ConfigError!void {
        if (!self.raw.hasSection(url_section)) return;
        const s = try self.raw.section(url_section);
        for (s.subsections.items) |sub| {
            const u = try self.allocator.create(URL);
            errdefer self.allocator.destroy(u);
            u.* = URL.init(self.allocator);
            errdefer u.deinit();
            try u.unmarshal(sub);
            const key = try self.allocator.dupe(u8, u.name);
            errdefer self.allocator.free(key);
            try self.urls.put(self.allocator, key, u);
        }
    }

    fn unmarshalBranches(self: *Config) ConfigError!void {
        if (!self.raw.hasSection(branch_section)) return;
        const s = try self.raw.section(branch_section);
        for (s.subsections.items) |sub| {
            const b = try self.allocator.create(Branch);
            errdefer self.allocator.destroy(b);
            b.* = Branch.init(self.allocator);
            errdefer b.deinit();
            try b.unmarshal(sub);
            const key = try self.allocator.dupe(u8, b.name);
            errdefer self.allocator.free(key);
            try self.branches.put(self.allocator, key, b);
        }
    }

    fn marshalCore(self: *Config) Allocator.Error!void {
        const s = try self.raw.section(core_section);
        const bare = if (self.core.is_bare) "true" else "false";
        _ = try s.setOption(bare_key, bare);
        if (self.core.repository_format_version.len > 0) {
            _ = try s.setOption(repository_format_version_key, self.core.repository_format_version);
        }
        if (self.core.worktree.len > 0) {
            _ = try s.setOption(worktree_key, self.core.worktree);
        }
        if (self.core.protect_ntfs.isSet()) {
            _ = try s.setOption(protect_ntfs_key, self.core.protect_ntfs.formatBool());
        }
        if (self.core.protect_hfs.isSet()) {
            _ = try s.setOption(protect_hfs_key, self.core.protect_hfs.formatBool());
        }
    }

    fn marshalExtensions(self: *Config) Allocator.Error!void {
        if (std.mem.eql(u8, self.core.repository_format_version, format_config.Version1)) {
            const s = try self.raw.section(extensions_section);
            _ = try s.setOption(object_format_key, self.extensions.object_format);
        }
    }

    fn marshalUser(self: *Config) Allocator.Error!void {
        if (self.user.name.len > 0 or self.user.email.len > 0) {
            const s = try self.raw.section(user_section);
            if (self.user.name.len > 0) _ = try s.setOption(name_key, self.user.name);
            if (self.user.email.len > 0) _ = try s.setOption(email_key, self.user.email);
        }
        if (self.author.name.len > 0 or self.author.email.len > 0) {
            const s = try self.raw.section(author_section);
            if (self.author.name.len > 0) _ = try s.setOption(name_key, self.author.name);
            if (self.author.email.len > 0) _ = try s.setOption(email_key, self.author.email);
        }
        if (self.committer.name.len > 0 or self.committer.email.len > 0) {
            const s = try self.raw.section(committer_section);
            if (self.committer.name.len > 0) _ = try s.setOption(name_key, self.committer.name);
            if (self.committer.email.len > 0) _ = try s.setOption(email_key, self.committer.email);
        }
    }

    fn marshalPack(self: *Config) Allocator.Error!void {
        if (self.pack.window != default_pack_window) {
            const s = try self.raw.section(pack_section);
            var buf: [32]u8 = undefined;
            // u32 always fits in 32 bytes.
            const v = std.fmt.bufPrint(&buf, "{d}", .{self.pack.window}) catch unreachable;
            _ = try s.setOption(window_key, v);
        }
    }

    fn marshalRemotes(self: *Config) Allocator.Error!void {
        const s = try self.raw.section(remote_section);
        try rebuildSubsections(self.allocator, s, &self.remotes, RemoteConfig.marshal);
    }

    fn marshalSubmodules(self: *Config) Allocator.Error!void {
        const s = try self.raw.section(submodule_section);
        clearSectionSubsections(s, &self.submodules);

        var it = self.submodules.iterator();
        while (it.next()) |e| {
            const section = try e.value_ptr.*.marshal();
            // go-git Config.marshalSubmodules strips path from the written remote config.
            _ = section.removeOption(modules_mod.path_key);
            try s.subsections.append(self.allocator, section);
        }
    }

    fn marshalBranches(self: *Config) Allocator.Error!void {
        const s = try self.raw.section(branch_section);
        try rebuildSubsections(self.allocator, s, &self.branches, Branch.marshal);
    }

    fn marshalURLs(self: *Config) Allocator.Error!void {
        const s = try self.raw.section(url_section);
        clearSectionSubsections(s, &self.urls);

        var it = self.urls.iterator();
        while (it.next()) |e| {
            try s.subsections.append(self.allocator, try e.value_ptr.*.marshal());
        }
    }

    fn marshalInit(self: *Config) Allocator.Error!void {
        if (self.init.default_branch.len > 0) {
            const s = try self.raw.section(init_section);
            _ = try s.setOption(default_branch_key, self.init.default_branch);
        }
    }

    /// Insert a remote (takes ownership of heap `*RemoteConfig`).
    pub fn putRemote(self: *Config, remote: *RemoteConfig) Allocator.Error!void {
        if (self.remotes.fetchRemove(remote.name)) |old| {
            old.value.deinit();
            self.allocator.destroy(old.value);
            self.allocator.free(old.key);
        }
        const key = try self.allocator.dupe(u8, remote.name);
        errdefer self.allocator.free(key);
        try self.remotes.put(self.allocator, key, remote);
    }

    pub fn putBranch(self: *Config, branch: *Branch) Allocator.Error!void {
        if (self.branches.fetchRemove(branch.name)) |old| {
            old.value.deinit();
            self.allocator.destroy(old.value);
            self.allocator.free(old.key);
        }
        const key = try self.allocator.dupe(u8, branch.name);
        errdefer self.allocator.free(key);
        try self.branches.put(self.allocator, key, branch);
    }

    pub fn putSubmodule(self: *Config, m: *Submodule) Allocator.Error!void {
        if (self.submodules.fetchRemove(m.name)) |old| {
            old.value.deinit();
            self.allocator.destroy(old.value);
            self.allocator.free(old.key);
        }
        const key = try self.allocator.dupe(u8, m.name);
        errdefer self.allocator.free(key);
        try self.submodules.put(self.allocator, key, m);
    }

    pub fn putURL(self: *Config, u: *URL) Allocator.Error!void {
        if (self.urls.fetchRemove(u.name)) |old| {
            old.value.deinit();
            self.allocator.destroy(old.value);
            self.allocator.free(old.key);
        }
        const key = try self.allocator.dupe(u8, u.name);
        errdefer self.allocator.free(key);
        try self.urls.put(self.allocator, key, u);
    }
};

/// go-git `NewConfig`.
pub fn newConfig(allocator: Allocator) Allocator.Error!Config {
    return Config.create(allocator);
}

/// go-git `ReadConfig` from bytes.
pub fn readConfig(allocator: Allocator, data: []const u8) ConfigError!Config {
    var cfg = try Config.create(allocator);
    errdefer cfg.deinit();
    try cfg.unmarshal(data);
    return cfg;
}

/// go-git `Paths` for a scope.
///
/// `environ` supplies `XDG_CONFIG_HOME` / `HOME` (Zig 0.16 has no `std.posix.getenv`).
/// Caller owns the returned slice and each path string.
pub fn paths(scope: Scope, allocator: Allocator, environ: std.process.Environ) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }
    switch (scope) {
        .local => {},
        .global => {
            if (std.process.Environ.getPosix(environ, "XDG_CONFIG_HOME")) |xdg| {
                if (xdg.len > 0) {
                    try list.append(allocator, try std.fs.path.join(allocator, &.{ xdg, "git", "config" }));
                }
            }
            if (std.process.Environ.getPosix(environ, "HOME")) |home| {
                if (home.len > 0) {
                    try list.append(allocator, try std.fs.path.join(allocator, &.{ home, ".gitconfig" }));
                    try list.append(allocator, try std.fs.path.join(allocator, &.{ home, ".config", "git", "config" }));
                }
            }
        },
        .system => {
            try list.append(allocator, try allocator.dupe(u8, "/etc/gitconfig"));
        },
    }
    return try list.toOwnedSlice(allocator);
}

/// go-git `LoadConfig` — only global/system; local returns error.
///
/// Reads the first existing path from `paths`. Missing files are skipped.
/// When no file is found, returns an empty `NewConfig` (go-git behaviour).
///
/// `io` drives host file reads (Zig 0.16 `std.Io`); `environ` resolves path vars.
pub fn loadConfig(
    allocator: Allocator,
    scope: Scope,
    io: std.Io,
    environ: std.process.Environ,
) ConfigError!Config {
    if (scope == .local) return error.LocalScopeNotSupported;

    const file_list = try paths(scope, allocator, environ);
    defer {
        for (file_list) |p| allocator.free(p);
        allocator.free(file_list);
    }

    for (file_list) |file_path| {
        const data = readFileBytes(allocator, io, file_path) catch continue;
        defer allocator.free(data);
        return try readConfig(allocator, data);
    }

    return try Config.create(allocator);
}

fn readFileBytes(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    // Cap at 16 MiB to match prior go-git practical bound.
    return try file_reader.interface.allocRemaining(allocator, .limited(16 * 1024 * 1024));
}

// --- helpers ----------------------------------------------------------------

fn freeIdentity(allocator: Allocator, id: *Identity) void {
    freeOwned(allocator, &id.name);
    freeOwned(allocator, &id.email);
}

fn freeCoreStrings(self: *Config) void {
    freeOwned(self.allocator, &self.core.worktree);
    freeOwned(self.allocator, &self.core.comment_char);
    freeOwned(self.allocator, &self.core.repository_format_version);
}

fn freeFetch(allocator: Allocator, list: *[]const RefSpec) void {
    if (list.*.len == 0) {
        list.* = &.{};
        return;
    }
    for (list.*) |rs| {
        if (rs.raw.len > 0) allocator.free(rs.raw);
    }
    allocator.free(list.*);
    list.* = &.{};
}

fn clearOwnedMap(comptime V: type, allocator: Allocator, map: *std.StringHashMapUnmanaged(*V)) void {
    var it = map.iterator();
    while (it.next()) |e| {
        e.value_ptr.*.deinit();
        allocator.destroy(e.value_ptr.*);
        allocator.free(e.key_ptr.*);
    }
    map.clearRetainingCapacity();
}

fn clearMapRemote(self: *Config) void {
    clearOwnedMap(RemoteConfig, self.allocator, &self.remotes);
}
fn clearMapSubmodule(self: *Config) void {
    clearOwnedMap(Submodule, self.allocator, &self.submodules);
}
fn clearMapBranch(self: *Config) void {
    clearOwnedMap(Branch, self.allocator, &self.branches);
}
fn clearMapURL(self: *Config) void {
    clearOwnedMap(URL, self.allocator, &self.urls);
}

fn stringLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Has `name`, optional `raw: ?*Subsection`, and `marshal(*T) !*Subsection`.
fn rebuildSubsections(
    allocator: Allocator,
    section: *format_config.Section,
    map: anytype,
    comptime marshalFn: anytype,
) Allocator.Error!void {
    var new_list: std.ArrayList(*Subsection) = .empty;
    errdefer new_list.deinit(allocator);

    var added: std.StringHashMapUnmanaged(void) = .empty;
    defer added.deinit(allocator);

    const old = try allocator.alloc(*Subsection, section.subsections.items.len);
    defer allocator.free(old);
    @memcpy(old, section.subsections.items);
    section.subsections.clearRetainingCapacity();

    for (old) |sub| {
        if (map.get(sub.name)) |entry| {
            if (entry.raw == null) entry.raw = sub;
            const marshaled = try marshalFn(entry);
            try new_list.append(allocator, marshaled);
            try added.put(allocator, entry.name, {});
            if (marshaled != sub) sub.destroy();
        } else {
            var it = map.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.*.raw == sub) e.value_ptr.*.raw = null;
            }
            sub.destroy();
        }
    }

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    {
        var it = map.iterator();
        while (it.next()) |e| {
            if (added.get(e.value_ptr.*.name) == null) {
                try names.append(allocator, e.value_ptr.*.name);
            }
        }
    }
    std.mem.sort([]const u8, names.items, {}, stringLess);

    for (names.items) |name| {
        const entry = map.get(name).?;
        try new_list.append(allocator, try marshalFn(entry));
    }

    try section.subsections.appendSlice(allocator, new_list.items);
    new_list.deinit(allocator);
}

fn clearSectionSubsections(section: *format_config.Section, map: anytype) void {
    while (section.subsections.items.len > 0) {
        const removed = section.subsections.orderedRemove(section.subsections.items.len - 1);
        var it = map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*.raw == removed) e.value_ptr.*.raw = null;
        }
        removed.destroy();
    }
}

// ---------------------------------------------------------------------------
// Tests (go-git config_test.go ConfigSuite)
// ---------------------------------------------------------------------------

fn dupe(allocator: Allocator, s: []const u8) Allocator.Error![]u8 {
    return try allocator.dupe(u8, s);
}

test "Config default values" {
    // go-git TestRemoteConfigDefaultValues
    const gpa = std.testing.allocator;
    var cfg = try newConfig(gpa);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 0), cfg.remotes.count());
    try std.testing.expectEqual(@as(usize, 0), cfg.branches.count());
    try std.testing.expectEqual(@as(usize, 0), cfg.submodules.count());
    try std.testing.expectEqual(default_pack_window, cfg.pack.window);
}

test "Config.Unmarshal" {
    // go-git TestUnmarshal (raw fixture matches go-git config_test.go bytes).
    // win-local uses doubled backslashes so the decoder yields `X:\Git\`.
    // description uses doubled `\\n` so after unquote the value still has `\n`
    // two-char sequences for Branch.unquoteDescription.
    const gpa = std.testing.allocator;
    const input =
        "[core]\n" ++
        "\tbare = true\n" ++
        "\tworktree = foo\n" ++
        "\tcommentchar = bar\n" ++
        "[user]\n" ++
        "\tname = John Doe\n" ++
        "\temail = john@example.com\n" ++
        "[author]\n" ++
        "\tname = Jane Roe\n" ++
        "\temail = jane@example.com\n" ++
        "[committer]\n" ++
        "\tname = Richard Roe\n" ++
        "\temail = richard@example.com\n" ++
        "[pack]\n" ++
        "\twindow = 20\n" ++
        "[remote \"origin\"]\n" ++
        "\turl = git@github.com:mcuadros/go-git.git\n" ++
        "\tfetch = +refs/heads/*:refs/remotes/origin/*\n" ++
        "[remote \"alt\"]\n" ++
        "\turl = git@github.com:mcuadros/go-git.git\n" ++
        "\turl = git@github.com:src-d/go-git.git\n" ++
        "\tfetch = +refs/heads/*:refs/remotes/origin/*\n" ++
        "\tfetch = +refs/pull/*:refs/remotes/origin/pull/*\n" ++
        "[remote \"insteadOf\"]\n" ++
        "\turl = https://github.com/kostyay/go-git.git\n" ++
        "[remote \"win-local\"]\n" ++
        "\turl = X:\\\\Git\\\\\n" ++
        "[submodule \"qux\"]\n" ++
        "\tpath = qux\n" ++
        "\turl = https://github.com/foo/qux.git\n" ++
        "\tbranch = bar\n" ++
        "[branch \"master\"]\n" ++
        "\tremote = origin\n" ++
        "\tmerge = refs/heads/master\n" ++
        "\tdescription = \"Add support for branch description.\\\\n\\\\nEdit branch description: git branch --edit-description\\\\n\"\n" ++
        "[init]\n" ++
        "\tdefaultBranch = main\n" ++
        "[url \"ssh://git@github.com/\"]\n" ++
        "\tinsteadOf = https://github.com/\n";

    var cfg = try newConfig(gpa);
    defer cfg.deinit();
    try cfg.unmarshal(input);

    try std.testing.expect(cfg.core.is_bare);
    try std.testing.expectEqualStrings("foo", cfg.core.worktree);
    try std.testing.expectEqualStrings("bar", cfg.core.comment_char);
    try std.testing.expectEqualStrings("John Doe", cfg.user.name);
    try std.testing.expectEqualStrings("john@example.com", cfg.user.email);
    try std.testing.expectEqualStrings("Jane Roe", cfg.author.name);
    try std.testing.expectEqualStrings("jane@example.com", cfg.author.email);
    try std.testing.expectEqualStrings("Richard Roe", cfg.committer.name);
    try std.testing.expectEqualStrings("richard@example.com", cfg.committer.email);
    try std.testing.expectEqual(@as(u32, 20), cfg.pack.window);
    try std.testing.expectEqual(@as(usize, 4), cfg.remotes.count());

    const origin = cfg.remotes.get("origin").?;
    try std.testing.expectEqualStrings("origin", origin.name);
    try std.testing.expectEqual(@as(usize, 1), origin.urls.len);
    try std.testing.expectEqualStrings("git@github.com:mcuadros/go-git.git", origin.urls[0]);
    try std.testing.expectEqual(@as(usize, 1), origin.fetch.len);
    try std.testing.expectEqualStrings("+refs/heads/*:refs/remotes/origin/*", origin.fetch[0].raw);

    const alt = cfg.remotes.get("alt").?;
    try std.testing.expectEqual(@as(usize, 2), alt.urls.len);
    try std.testing.expectEqual(@as(usize, 2), alt.fetch.len);

    const win = cfg.remotes.get("win-local").?;
    try std.testing.expectEqualStrings("X:\\Git\\", win.urls[0]);

    const instead = cfg.remotes.get("insteadOf").?;
    try std.testing.expectEqualStrings("ssh://git@github.com/kostyay/go-git.git", instead.urls[0]);

    try std.testing.expectEqual(@as(usize, 1), cfg.submodules.count());
    const qux = cfg.submodules.get("qux").?;
    try std.testing.expectEqualStrings("qux", qux.name);
    try std.testing.expectEqualStrings("https://github.com/foo/qux.git", qux.url);
    try std.testing.expectEqualStrings("bar", qux.branch);

    const master = cfg.branches.get("master").?;
    try std.testing.expectEqualStrings("origin", master.remote);
    try std.testing.expectEqualStrings("refs/heads/master", master.merge.raw);
    try std.testing.expectEqualStrings(
        "Add support for branch description.\n\nEdit branch description: git branch --edit-description\n",
        master.description,
    );
    try std.testing.expectEqualStrings("main", cfg.init.default_branch);
}

test "Config.Marshal" {
    // go-git TestMarshal
    const gpa = std.testing.allocator;
    var cfg = try newConfig(gpa);
    defer cfg.deinit();

    cfg.core.is_bare = true;
    try setOwned(gpa, &cfg.core.worktree, "bar");
    cfg.pack.window = 20;
    try setOwned(gpa, &cfg.init.default_branch, "main");

    {
        const r = try gpa.create(RemoteConfig);
        r.* = RemoteConfig.init(gpa);
        try setOwned(gpa, &r.name, "origin");
        const urls = try gpa.alloc([]const u8, 1);
        urls[0] = try dupe(gpa, "git@github.com:mcuadros/go-git.git");
        r.urls = urls;
        try cfg.putRemote(r);
    }
    {
        const r = try gpa.create(RemoteConfig);
        r.* = RemoteConfig.init(gpa);
        try setOwned(gpa, &r.name, "alt");
        const urls = try gpa.alloc([]const u8, 2);
        urls[0] = try dupe(gpa, "git@github.com:mcuadros/go-git.git");
        urls[1] = try dupe(gpa, "git@github.com:src-d/go-git.git");
        r.urls = urls;
        const fetch = try gpa.alloc(RefSpec, 2);
        fetch[0] = RefSpec.init(try dupe(gpa, "+refs/heads/*:refs/remotes/origin/*"));
        fetch[1] = RefSpec.init(try dupe(gpa, "+refs/pull/*:refs/remotes/origin/pull/*"));
        r.fetch = fetch;
        try cfg.putRemote(r);
    }
    {
        const r = try gpa.create(RemoteConfig);
        r.* = RemoteConfig.init(gpa);
        try setOwned(gpa, &r.name, "win-local");
        const urls = try gpa.alloc([]const u8, 1);
        urls[0] = try dupe(gpa, "X:\\Git\\");
        r.urls = urls;
        try cfg.putRemote(r);
    }
    {
        const r = try gpa.create(RemoteConfig);
        r.* = RemoteConfig.init(gpa);
        try setOwned(gpa, &r.name, "insteadOf");
        const urls = try gpa.alloc([]const u8, 1);
        urls[0] = try dupe(gpa, "https://github.com/kostyay/go-git.git");
        r.urls = urls;
        try cfg.putRemote(r);
    }
    {
        const m = try gpa.create(Submodule);
        m.* = Submodule.init(gpa);
        try setOwned(gpa, &m.name, "qux");
        try setOwned(gpa, &m.url, "https://github.com/foo/qux.git");
        try cfg.putSubmodule(m);
    }
    {
        const b = try gpa.create(Branch);
        b.* = Branch.init(gpa);
        try setOwned(gpa, &b.name, "master");
        try setOwned(gpa, &b.remote, "origin");
        b.merge = .{ .raw = try dupe(gpa, "refs/heads/master") };
        b.merge_owned = true;
        try setOwned(gpa, &b.description, "Add support for branch description.\n\nEdit branch description: git branch --edit-description\n");
        try cfg.putBranch(b);
    }
    {
        const u = try gpa.create(URL);
        u.* = URL.init(gpa);
        try setOwned(gpa, &u.name, "ssh://git@github.com/");
        try setOwned(gpa, &u.instead_of, "https://github.com/");
        try cfg.putURL(u);
    }

    const out = try cfg.marshal();
    defer gpa.free(out);

    // Tab-indented; matches go-git format/config encoder + TestMarshal output.
    const expected =
        "[core]\n" ++
        "\tbare = true\n" ++
        "\tworktree = bar\n" ++
        "[pack]\n" ++
        "\twindow = 20\n" ++
        "[remote \"alt\"]\n" ++
        "\turl = git@github.com:mcuadros/go-git.git\n" ++
        "\turl = git@github.com:src-d/go-git.git\n" ++
        "\tfetch = +refs/heads/*:refs/remotes/origin/*\n" ++
        "\tfetch = +refs/pull/*:refs/remotes/origin/pull/*\n" ++
        "[remote \"insteadOf\"]\n" ++
        "\turl = https://github.com/kostyay/go-git.git\n" ++
        "[remote \"origin\"]\n" ++
        "\turl = git@github.com:mcuadros/go-git.git\n" ++
        "[remote \"win-local\"]\n" ++
        "\turl = \"X:\\\\Git\\\\\"\n" ++
        "[submodule \"qux\"]\n" ++
        "\turl = https://github.com/foo/qux.git\n" ++
        "[branch \"master\"]\n" ++
        "\tremote = origin\n" ++
        "\tmerge = refs/heads/master\n" ++
        "\tdescription = \"Add support for branch description.\\\\n\\\\nEdit branch description: git branch --edit-description\\\\n\"\n" ++
        "[url \"ssh://git@github.com/\"]\n" ++
        "\tinsteadOf = https://github.com/\n" ++
        "[init]\n" ++
        "\tdefaultBranch = main\n";
    try std.testing.expectEqualStrings(expected, out);
}

test "Config UnmarshalMarshal round-trip" {
    // go-git TestUnmarshalMarshal — tab indent; unknown options preserved on raw.
    const gpa = std.testing.allocator;
    const input =
        "[core]\n" ++
        "\tbare = true\n" ++
        "\tworktree = foo\n" ++
        "\tcustom = ignored\n" ++
        "[user]\n" ++
        "\tname = John Doe\n" ++
        "\temail = john@example.com\n" ++
        "[author]\n" ++
        "\tname = Jane Roe\n" ++
        "\temail = jane@example.com\n" ++
        "[committer]\n" ++
        "\tname = Richard Roe\n" ++
        "\temail = richard@example.co\n" ++
        "[pack]\n" ++
        "\twindow = 20\n" ++
        "[remote \"insteadOf\"]\n" ++
        "\turl = https://github.com/kostyay/go-git.git\n" ++
        "[remote \"origin\"]\n" ++
        "\turl = git@github.com:mcuadros/go-git.git\n" ++
        "\tfetch = +refs/heads/*:refs/remotes/origin/*\n" ++
        "\tmirror = true\n" ++
        "[remote \"win-local\"]\n" ++
        "\turl = \"X:\\\\Git\\\\\"\n" ++
        "[branch \"master\"]\n" ++
        "\tremote = origin\n" ++
        "\tmerge = refs/heads/master\n" ++
        "[url \"ssh://git@github.com/\"]\n" ++
        "\tinsteadOf = https://github.com/\n";

    var cfg = try newConfig(gpa);
    defer cfg.deinit();
    try cfg.unmarshal(input);
    const output = try cfg.marshal();
    defer gpa.free(output);
    try std.testing.expectEqualStrings(input, output);
}

test "Config.validate" {
    // go-git TestValidateConfig / InvalidRemote / InvalidRemoteKey / InvalidBranch*
    const gpa = std.testing.allocator;
    var cfg = try newConfig(gpa);
    defer cfg.deinit();

    {
        const r = try gpa.create(RemoteConfig);
        r.* = RemoteConfig.init(gpa);
        try setOwned(gpa, &r.name, "bar");
        const urls = try gpa.alloc([]const u8, 1);
        urls[0] = try dupe(gpa, "http://foo/bar");
        r.urls = urls;
        try cfg.putRemote(r);
    }
    {
        const b = try gpa.create(Branch);
        b.* = Branch.init(gpa);
        try setOwned(gpa, &b.name, "bar");
        try cfg.putBranch(b);
    }
    {
        const b = try gpa.create(Branch);
        b.* = Branch.init(gpa);
        try setOwned(gpa, &b.name, "foo");
        try setOwned(gpa, &b.remote, "origin");
        b.merge = .{ .raw = try dupe(gpa, "refs/heads/foo") };
        b.merge_owned = true;
        try cfg.putBranch(b);
    }
    try cfg.validate();
}

test "Config.validate invalid remote empty URL" {
    const gpa = std.testing.allocator;
    var cfg = try newConfig(gpa);
    defer cfg.deinit();
    const r = try gpa.create(RemoteConfig);
    r.* = RemoteConfig.init(gpa);
    try setOwned(gpa, &r.name, "foo");
    try cfg.putRemote(r);
    try std.testing.expectError(error.RemoteConfigEmptyURL, cfg.validate());
}

test "Config.validate invalid remote key" {
    const gpa = std.testing.allocator;
    var cfg = try newConfig(gpa);
    defer cfg.deinit();
    const r = try gpa.create(RemoteConfig);
    r.* = RemoteConfig.init(gpa);
    try setOwned(gpa, &r.name, "foo");
    const key = try dupe(gpa, "bar");
    try cfg.remotes.put(gpa, key, r);
    try std.testing.expectError(error.Invalid, cfg.validate());
}

test "RemoteConfig.validate" {
    const gpa = std.testing.allocator;
    {
        var r = RemoteConfig.init(gpa);
        defer r.deinit();
        try setOwned(gpa, &r.name, "foo");
        try std.testing.expectError(error.RemoteConfigEmptyURL, r.validate());
    }
    {
        var r = RemoteConfig.init(gpa);
        defer r.deinit();
        try std.testing.expectError(error.RemoteConfigEmptyName, r.validate());
    }
}

test "RemoteConfig default fetch after validate when fetch empty" {
    // go-git TestRemoteConfigValidateDefault
    const gpa = std.testing.allocator;
    var r = RemoteConfig.init(gpa);
    defer r.deinit();
    try setOwned(gpa, &r.name, "foo");
    const urls = try gpa.alloc([]const u8, 1);
    urls[0] = try dupe(gpa, "http://foo/bar");
    r.urls = urls;
    try std.testing.expectEqual(@as(usize, 0), r.fetch.len);
    try r.validate();
    try std.testing.expectEqual(@as(usize, 1), r.fetch.len);
    try std.testing.expectEqualStrings("+refs/heads/*:refs/remotes/foo/*", r.fetch[0].raw);
}

test "RemoteConfig.isFirstURLLocal" {
    const gpa = std.testing.allocator;
    {
        var r = RemoteConfig.init(gpa);
        defer r.deinit();
        const urls = try gpa.alloc([]const u8, 1);
        urls[0] = try dupe(gpa, "/home/user/src/go-git");
        r.urls = urls;
        try std.testing.expect(r.isFirstURLLocal());
    }
    {
        var r = RemoteConfig.init(gpa);
        defer r.deinit();
        const urls = try gpa.alloc([]const u8, 1);
        urls[0] = try dupe(gpa, "./relative/path");
        r.urls = urls;
        try std.testing.expect(r.isFirstURLLocal());
    }
    {
        var r = RemoteConfig.init(gpa);
        defer r.deinit();
        const urls = try gpa.alloc([]const u8, 1);
        urls[0] = try dupe(gpa, "https://github.com/src-d/go-git");
        r.urls = urls;
        try std.testing.expect(!r.isFirstURLLocal());
    }
    {
        var r = RemoteConfig.init(gpa);
        defer r.deinit();
        const urls = try gpa.alloc([]const u8, 1);
        urls[0] = try dupe(gpa, "git@github.com:james/bond");
        r.urls = urls;
        try std.testing.expect(!r.isFirstURLLocal());
    }
    {
        var r = RemoteConfig.init(gpa);
        defer r.deinit();
        try std.testing.expect(!r.isFirstURLLocal());
    }
}

test "paths GlobalScope with XDG_CONFIG_HOME and HOME" {
    // go-git Paths(GlobalScope) — Zig 0.16: build Environ from a map (no getenv).
    const gpa = std.testing.allocator;
    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();
    try map.put("XDG_CONFIG_HOME", "/tmp/xdg-test");
    try map.put("HOME", "/home/testuser");
    const environ: std.process.Environ = .{ .block = try map.createPosixBlock(gpa, .{}) };
    defer environ.block.deinit(gpa);

    const list = try paths(.global, gpa, environ);
    defer {
        for (list) |p| gpa.free(p);
        gpa.free(list);
    }
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("/tmp/xdg-test/git/config", list[0]);
    try std.testing.expectEqualStrings("/home/testuser/.gitconfig", list[1]);
    try std.testing.expectEqualStrings("/home/testuser/.config/git/config", list[2]);
}

test "paths GlobalScope HOME only" {
    const gpa = std.testing.allocator;
    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();
    try map.put("HOME", "/home/only");
    const environ: std.process.Environ = .{ .block = try map.createPosixBlock(gpa, .{}) };
    defer environ.block.deinit(gpa);

    const list = try paths(.global, gpa, environ);
    defer {
        for (list) |p| gpa.free(p);
        gpa.free(list);
    }
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("/home/only/.gitconfig", list[0]);
    try std.testing.expectEqualStrings("/home/only/.config/git/config", list[1]);
}

test "paths SystemScope" {
    const gpa = std.testing.allocator;
    const list = try paths(.system, gpa, std.process.Environ.empty);
    defer {
        for (list) |p| gpa.free(p);
        gpa.free(list);
    }
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("/etc/gitconfig", list[0]);
}

test "paths LocalScope empty" {
    const gpa = std.testing.allocator;
    const list = try paths(.local, gpa, std.process.Environ.empty);
    defer gpa.free(list);
    try std.testing.expectEqual(@as(usize, 0), list.len);
}

test "Config.validate invalid branch key" {
    const gpa = std.testing.allocator;
    var cfg = try newConfig(gpa);
    defer cfg.deinit();
    const b = try gpa.create(Branch);
    b.* = Branch.init(gpa);
    try setOwned(gpa, &b.name, "bar");
    try setOwned(gpa, &b.remote, "origin");
    b.merge = .{ .raw = try dupe(gpa, "refs/heads/bar") };
    b.merge_owned = true;
    const key = try dupe(gpa, "foo");
    try cfg.branches.put(gpa, key, b);
    try std.testing.expectError(error.Invalid, cfg.validate());
}

test "Config.validate invalid branch merge" {
    const gpa = std.testing.allocator;
    var cfg = try newConfig(gpa);
    defer cfg.deinit();
    {
        const b = try gpa.create(Branch);
        b.* = Branch.init(gpa);
        try setOwned(gpa, &b.name, "bar");
        try setOwned(gpa, &b.remote, "origin");
        b.merge = .{ .raw = try dupe(gpa, "refs/heads/bar") };
        b.merge_owned = true;
        try cfg.putBranch(b);
    }
    {
        const b = try gpa.create(Branch);
        b.* = Branch.init(gpa);
        try setOwned(gpa, &b.name, "foo");
        try setOwned(gpa, &b.remote, "origin");
        b.merge = .{ .raw = try dupe(gpa, "baz") };
        b.merge_owned = true;
        try cfg.putBranch(b);
    }
    try std.testing.expectError(error.BranchInvalidMerge, cfg.validate());
}

test "LoadConfig LocalScope" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        error.LocalScopeNotSupported,
        loadConfig(gpa, .local, std.testing.io, std.testing.environ),
    );
}

test "LoadConfig SystemScope empty or host file" {
    // go-git LoadConfig(SystemScope): empty NewConfig when no file, else first hit.
    // Soft: host may or may not have /etc/gitconfig; either outcome is valid.
    const gpa = std.testing.allocator;
    var cfg = try loadConfig(gpa, .system, std.testing.io, std.process.Environ.empty);
    defer cfg.deinit();
    // Success is enough; do not assert defaults (host file may override pack.window).
    _ = &cfg;
}

test "Remove URL options" {
    // go-git TestRemoveUrlOptions
    const gpa = std.testing.allocator;
    const buf =
        \\
        \\[remote "alt"]
        \\    url = git@github.com:mcuadros/go-git.git
        \\    url = git@github.com:src-d/go-git.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\    fetch = +refs/pull/*:refs/remotes/origin/pull/*
    ;
    var cfg = try newConfig(gpa);
    defer cfg.deinit();
    try cfg.unmarshal(buf);
    try std.testing.expectEqual(@as(usize, 1), cfg.remotes.count());
    freeStringList(gpa, &cfg.remotes.get("alt").?.urls);
    const out = try cfg.marshal();
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "url") == null);
}

test "Unmarshal remotes pushurl" {
    // go-git TestUnmarshalRemotes
    const gpa = std.testing.allocator;
    const input =
        \\[core]
        \\    bare = true
        \\    worktree = foo
        \\    custom = ignored
        \\[user]
        \\    name = John Doe
        \\    email = john@example.com
        \\[remote "origin"]
        \\    url = https://git.sr.ht/~mcepl/go-git
        \\    pushurl = git@git.sr.ht:~mcepl/go-git.git
        \\    fetch = +refs/heads/*:refs/remotes/origin/*
        \\    mirror = true
        \\
    ;
    var cfg = try newConfig(gpa);
    defer cfg.deinit();
    try cfg.unmarshal(input);
    const origin = cfg.remotes.get("origin").?;
    try std.testing.expectEqualStrings("https://git.sr.ht/~mcepl/go-git", origin.urls[0]);
    try std.testing.expectEqualStrings("git@git.sr.ht:~mcepl/go-git.git", origin.urls[1]);
}

test "Unmarshal protectNTFS protectHFS" {
    const gpa = std.testing.allocator;
    const body = "[core]\n\tprotectNTFS = true\n\tprotectHFS = false\n";
    var cfg = try newConfig(gpa);
    defer cfg.deinit();
    try cfg.unmarshal(body);
    try std.testing.expectEqual(OptBool.set_true, cfg.core.protect_ntfs);
    try std.testing.expectEqual(OptBool.set_false, cfg.core.protect_hfs);
}

test "Branch marshal unmarshal via Config" {
    // go-git branch_test TestMarshal / TestUnmarshal
    const gpa = std.testing.allocator;
    const expected =
        "[core]\n" ++
        "\tbare = false\n" ++
        "[branch \"branch-tracking-on-clone\"]\n" ++
        "\tremote = fork\n" ++
        "\tmerge = refs/heads/branch-tracking-on-clone\n" ++
        "\trebase = interactive\n";
    var cfg = try newConfig(gpa);
    defer cfg.deinit();
    const b = try gpa.create(Branch);
    b.* = Branch.init(gpa);
    try setOwned(gpa, &b.name, "branch-tracking-on-clone");
    try setOwned(gpa, &b.remote, "fork");
    b.merge = .{ .raw = try dupe(gpa, "refs/heads/branch-tracking-on-clone") };
    b.merge_owned = true;
    try setOwned(gpa, &b.rebase, "interactive");
    try cfg.putBranch(b);

    const actual = try cfg.marshal();
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);

    var cfg2 = try newConfig(gpa);
    defer cfg2.deinit();
    try cfg2.unmarshal(expected);
    const branch = cfg2.branches.get("branch-tracking-on-clone").?;
    try std.testing.expectEqualStrings("branch-tracking-on-clone", branch.name);
    try std.testing.expectEqualStrings("fork", branch.remote);
    try std.testing.expectEqualStrings("refs/heads/branch-tracking-on-clone", branch.merge.raw);
    try std.testing.expectEqualStrings("interactive", branch.rebase);
}
