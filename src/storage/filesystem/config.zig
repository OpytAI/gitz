//! Filesystem config storage (go-git `storage/filesystem/config.go`).
//!
//! On-disk form is real git-config text via `plumbing/format/config` encode/decode.
//! In-memory surface is the shared storage `memory.Config` (`is_bare` + remotes
//! name/urls/fetch/mirror + branches remote/merge + user/author/committer
//! identity) used by BaseStorageSuite and the memory backend.
//!
//! `config()` re-reads the file every call (go-git `Config()`). `setConfig`
//! validates, marshals, writes, and takes ownership of the heap `*Config`
//! (same as `memory.ConfigStorage` for suite ownership).

const std = @import("std");
const memory = @import("memory");
const fs_pkg = @import("fs");
const format_config = @import("config");

const dotgit = @import("dotgit");

const Allocator = std.mem.Allocator;

pub const Config = memory.Config;
pub const RemoteConfig = memory.RemoteConfig;
pub const BranchConfig = memory.BranchConfig;
pub const ConfigError = memory.ConfigError;

pub const Error = Allocator.Error || ConfigError || fs_pkg.Error || format_config.Error ||
    std.Io.Writer.Error || std.Io.Reader.Error ||
    dotgit.Error || error{IntegerOverflow};

/// go-git `filesystem.ConfigStorage` monomorphised over billy-style `Fs`.
pub fn ConfigStorage(comptime Fs: type) type {
    const DotGit = dotgit.DotGitFor(Fs);

    return struct {
        const Self = @This();

        allocator: Allocator,
        dir: *DotGit,
        /// Last returned config (freed on next `config()` / `setConfig` / `deinit`).
        stored: ?*Config = null,

        pub fn init(allocator: Allocator, dir: *DotGit) Self {
            return .{ .allocator = allocator, .dir = dir };
        }

        pub fn deinit(self: *Self) void {
            self.dropStored();
            self.* = undefined;
        }

        fn dropStored(self: *Self) void {
            if (self.stored) |c| {
                c.deinit();
                self.allocator.destroy(c);
                self.stored = null;
            }
        }

        /// go-git `Config` — always re-read from disk (or empty default when missing).
        pub fn config(self: *Self) Error!*Config {
            if (self.dir.config()) |file| {
                var f = file;
                defer f.close() catch {};
                const data = try dotgit.readFileAll(self.allocator, &f);
                defer self.allocator.free(data);

                const c = try decodeMemoryConfig(self.allocator, data);
                self.dropStored();
                self.stored = c;
                return c;
            } else |err| switch (err) {
                error.ConfigNotFound, error.NotExist => {},
                else => |e| return e,
            }

            self.dropStored();
            const c = try self.allocator.create(Config);
            c.* = Config.init(self.allocator);
            self.stored = c;
            return c;
        }

        /// go-git `SetConfig` — validate, marshal to git-config, write `.git/config`.
        /// Takes ownership of `cfg` on success (suite / memory parity).
        pub fn setConfig(self: *Self, cfg: *Config) Error!void {
            try cfg.validate();

            const bytes = try encodeMemoryConfig(self.allocator, cfg);
            defer self.allocator.free(bytes);

            var f = try self.dir.configWriter();
            defer f.close() catch {};
            if (bytes.len > 0) _ = try f.write(bytes);

            if (self.stored) |old| {
                if (old != cfg) {
                    old.deinit();
                    self.allocator.destroy(old);
                }
            }
            self.stored = cfg;
        }
    };
}

/// Mem specialisation.
pub const ConfigStorageMem = ConfigStorage(fs_pkg.Mem);
/// Os specialisation.
pub const ConfigStorageOs = ConfigStorage(fs_pkg.Os);

// --- memory.Config ↔ format.Config ↔ git-config text -------------------------

fn sortedMapKeys(allocator: Allocator, map: anytype) Allocator.Error![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(allocator);
    var it = map.keyIterator();
    while (it.next()) |k| try names.append(allocator, k.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    return try names.toOwnedSlice(allocator);
}

/// Encode `memory.Config` as git-config bytes (bare + format + identity + remotes + branches).
fn encodeMemoryConfig(allocator: Allocator, cfg: *const Config) Error![]u8 {
    var raw = format_config.Config.init(allocator);
    defer raw.deinit();

    const bare = if (cfg.is_bare) "true" else "false";
    _ = try raw.setOption("core", format_config.NoSubsection, "bare", bare);
    if (cfg.repository_format_version.len > 0) {
        _ = try raw.setOption(
            "core",
            format_config.NoSubsection,
            "repositoryformatversion",
            cfg.repository_format_version,
        );
    }
    if (cfg.object_format.len > 0) {
        _ = try raw.setOption(
            "extensions",
            format_config.NoSubsection,
            "objectformat",
            cfg.object_format,
        );
    }

    // [user] / [author] / [committer] — same keys as high-level gitconfig.
    if (cfg.user_name.len > 0 or cfg.user_email.len > 0) {
        if (cfg.user_name.len > 0) {
            _ = try raw.setOption("user", format_config.NoSubsection, "name", cfg.user_name);
        }
        if (cfg.user_email.len > 0) {
            _ = try raw.setOption("user", format_config.NoSubsection, "email", cfg.user_email);
        }
    }
    if (cfg.author_name.len > 0 or cfg.author_email.len > 0) {
        if (cfg.author_name.len > 0) {
            _ = try raw.setOption("author", format_config.NoSubsection, "name", cfg.author_name);
        }
        if (cfg.author_email.len > 0) {
            _ = try raw.setOption("author", format_config.NoSubsection, "email", cfg.author_email);
        }
    }
    if (cfg.committer_name.len > 0 or cfg.committer_email.len > 0) {
        if (cfg.committer_name.len > 0) {
            _ = try raw.setOption("committer", format_config.NoSubsection, "name", cfg.committer_name);
        }
        if (cfg.committer_email.len > 0) {
            _ = try raw.setOption("committer", format_config.NoSubsection, "email", cfg.committer_email);
        }
    }

    // Stable remote order for deterministic on-disk output (sorted by name).
    const remote_names = try sortedMapKeys(allocator, cfg.remotes);
    defer allocator.free(remote_names);

    for (remote_names) |name| {
        const remote = cfg.remotes.get(name) orelse continue;
        for (remote.urls) |url| {
            _ = try raw.addOption("remote", name, "url", url);
        }
        for (remote.fetch) |spec| {
            _ = try raw.addOption("remote", name, "fetch", spec);
        }
        if (remote.mirror) {
            _ = try raw.setOption("remote", name, "mirror", "true");
        }
    }

    const branch_names = try sortedMapKeys(allocator, cfg.branches);
    defer allocator.free(branch_names);

    for (branch_names) |name| {
        const branch = cfg.branches.get(name) orelse continue;
        if (branch.remote.len > 0) {
            _ = try raw.setOption("branch", name, "remote", branch.remote);
        }
        if (branch.merge.len > 0) {
            _ = try raw.setOption("branch", name, "merge", branch.merge);
        }
        // Ensure subsection exists even if remote/merge empty (name-only branch).
        if (branch.remote.len == 0 and branch.merge.len == 0) {
            _ = try (try raw.section("branch")).subsection(name);
        }
    }

    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 128);
    errdefer aw.deinit();
    var enc = format_config.Encoder.init(&aw.writer);
    try enc.encode(&raw);
    return try aw.toOwnedSlice();
}

/// Decode git-config bytes into a heap `memory.Config` (bare + identity + remotes + branches).
fn decodeMemoryConfig(allocator: Allocator, data: []const u8) Error!*Config {
    var raw = format_config.Config.init(allocator);
    defer raw.deinit();

    var r: std.Io.Reader = .fixed(data);
    var dec = format_config.Decoder.init(&r);
    try dec.decode(&raw);

    const c = try allocator.create(Config);
    errdefer {
        c.deinit();
        allocator.destroy(c);
    }
    c.* = Config.init(allocator);

    if (raw.hasSection("core")) {
        const core = try raw.section("core");
        const bare = core.option("bare");
        c.is_bare = std.mem.eql(u8, bare, "true");
        const rfv = core.option("repositoryformatversion");
        if (rfv.len > 0) try c.setRepositoryFormatVersion(rfv);
    }

    if (raw.hasSection("extensions")) {
        const ext = try raw.section("extensions");
        const ofmt = ext.option("objectformat");
        if (ofmt.len > 0) try c.setObjectFormat(ofmt);
    }

    if (raw.hasSection("user")) {
        const user = try raw.section("user");
        const name = user.option("name");
        const email = user.option("email");
        if (name.len > 0 or email.len > 0) try c.setUser(name, email);
    }
    if (raw.hasSection("author")) {
        const author = try raw.section("author");
        const name = author.option("name");
        const email = author.option("email");
        if (name.len > 0 or email.len > 0) try c.setAuthor(name, email);
    }
    if (raw.hasSection("committer")) {
        const committer = try raw.section("committer");
        const name = committer.option("name");
        const email = committer.option("email");
        if (name.len > 0 or email.len > 0) try c.setCommitter(name, email);
    }

    if (raw.hasSection("remote")) {
        const remote_sec = try raw.section("remote");
        for (remote_sec.subsections.items) |ss| {
            var urls: std.ArrayList([]const u8) = .empty;
            defer urls.deinit(allocator);
            var fetch: std.ArrayList([]const u8) = .empty;
            defer fetch.deinit(allocator);
            var mirror = false;
            for (ss.options.items) |opt| {
                if (std.ascii.eqlIgnoreCase(opt.key, "url") or
                    std.ascii.eqlIgnoreCase(opt.key, "pushurl"))
                {
                    try urls.append(allocator, opt.value);
                } else if (std.ascii.eqlIgnoreCase(opt.key, "fetch")) {
                    try fetch.append(allocator, opt.value);
                } else if (std.ascii.eqlIgnoreCase(opt.key, "mirror")) {
                    mirror = std.mem.eql(u8, opt.value, "true");
                }
            }
            try c.putRemoteFull(ss.name, urls.items, fetch.items, mirror);
        }
    }

    if (raw.hasSection("branch")) {
        const branch_sec = try raw.section("branch");
        for (branch_sec.subsections.items) |ss| {
            var remote: []const u8 = "";
            var merge: []const u8 = "";
            for (ss.options.items) |opt| {
                if (std.ascii.eqlIgnoreCase(opt.key, "remote")) {
                    remote = opt.value;
                } else if (std.ascii.eqlIgnoreCase(opt.key, "merge")) {
                    merge = opt.value;
                }
            }
            try c.putBranch(ss.name, remote, merge);
        }
    }

    return c;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "encode/decode memory Config bare and remotes" {
    const gpa = std.testing.allocator;

    const cfg = try gpa.create(Config);
    defer {
        cfg.deinit();
        gpa.destroy(cfg);
    }
    cfg.* = Config.init(gpa);
    cfg.is_bare = true;
    try cfg.putRemote("origin", &[_][]const u8{ "https://example.com/a.git", "https://example.com/b.git" });
    try cfg.putRemote("foo", &[_][]const u8{"http://foo/bar.git"});

    const bytes = try encodeMemoryConfig(gpa, cfg);
    defer gpa.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "[core]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "bare = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[remote \"foo\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[remote \"origin\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "http://foo/bar.git") != null);

    const got = try decodeMemoryConfig(gpa, bytes);
    defer {
        got.deinit();
        gpa.destroy(got);
    }
    try std.testing.expect(got.is_bare);
    const origin = got.remotes.get("origin") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 2), origin.urls.len);
    try std.testing.expectEqualStrings("https://example.com/a.git", origin.urls[0]);
    const foo = got.remotes.get("foo") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("http://foo/bar.git", foo.urls[0]);
}

test "encode/decode remote fetch mirror and branch" {
    const gpa = std.testing.allocator;

    const cfg = try gpa.create(Config);
    defer {
        cfg.deinit();
        gpa.destroy(cfg);
    }
    cfg.* = Config.init(gpa);
    cfg.is_bare = false;
    try cfg.putRemoteFull(
        "origin",
        &[_][]const u8{"https://example.com/r.git"},
        &[_][]const u8{
            "+refs/heads/*:refs/remotes/origin/*",
            "+refs/tags/*:refs/tags/*",
        },
        true,
    );
    try cfg.putBranch("main", "origin", "refs/heads/main");
    try cfg.putBranch("dev", "upstream", "refs/heads/develop");

    const bytes = try encodeMemoryConfig(gpa, cfg);
    defer gpa.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "fetch = +refs/heads/*:refs/remotes/origin/*") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "fetch = +refs/tags/*:refs/tags/*") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "mirror = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[branch \"dev\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[branch \"main\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "merge = refs/heads/main") != null);

    const got = try decodeMemoryConfig(gpa, bytes);
    defer {
        got.deinit();
        gpa.destroy(got);
    }
    try std.testing.expect(!got.is_bare);
    const origin = got.remotes.get("origin") orelse return error.TestExpectedEqual;
    try std.testing.expect(origin.mirror);
    try std.testing.expectEqual(@as(usize, 2), origin.fetch.len);
    try std.testing.expectEqualStrings("+refs/heads/*:refs/remotes/origin/*", origin.fetch[0]);
    try std.testing.expectEqualStrings("+refs/tags/*:refs/tags/*", origin.fetch[1]);
    const main_b = got.branches.get("main") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("origin", main_b.remote);
    try std.testing.expectEqualStrings("refs/heads/main", main_b.merge);
    const dev_b = got.branches.get("dev") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("upstream", dev_b.remote);
    try std.testing.expectEqualStrings("refs/heads/develop", dev_b.merge);
}

test "encode/decode repositoryformatversion and objectformat" {
    const gpa = std.testing.allocator;

    const cfg = try gpa.create(Config);
    defer {
        cfg.deinit();
        gpa.destroy(cfg);
    }
    cfg.* = Config.init(gpa);
    cfg.is_bare = true;
    try cfg.setRepositoryFormatVersion(format_config.Version1);
    try cfg.setObjectFormat(format_config.SHA256);

    const bytes = try encodeMemoryConfig(gpa, cfg);
    defer gpa.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "repositoryformatversion = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[extensions]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "objectformat = sha256") != null);

    const got = try decodeMemoryConfig(gpa, bytes);
    defer {
        got.deinit();
        gpa.destroy(got);
    }
    try std.testing.expect(got.is_bare);
    try std.testing.expectEqualStrings(format_config.Version1, got.repository_format_version);
    try std.testing.expectEqualStrings(format_config.SHA256, got.object_format);
}

test "ConfigStorage setConfig writes git-config and reloads from disk" {
    const gpa = std.testing.allocator;
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();

    var dg = dotgit.DotGit.new(&mem);
    defer dg.deinit();
    try dg.initialize();

    {
        var store = ConfigStorageMem.init(gpa, &dg);
        defer store.deinit();

        const cfg = try gpa.create(Config);
        cfg.* = Config.init(gpa);
        cfg.is_bare = true;
        try cfg.putRemote("origin", &[_][]const u8{"http://example.com/r.git"});
        try store.setConfig(cfg);
    }

    // Cold storage re-reads from disk every config() call.
    var store2 = ConfigStorageMem.init(gpa, &dg);
    defer store2.deinit();
    const got = try store2.config();
    try std.testing.expect(got.is_bare);
    const remote = got.remotes.get("origin") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("http://example.com/r.git", remote.urls[0]);

    // Second config() re-reads (new pointer after dropStored).
    const got2 = try store2.config();
    try std.testing.expect(got2.is_bare);
    try std.testing.expect(got2 != got);

    var f = try mem.open("config");
    defer f.close() catch {};
    const data = try dotgit.readFileAll(gpa, &f);
    defer gpa.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "[remote \"origin\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "bare = true") != null);
}

test "encode/decode user and author identity" {
    const gpa = std.testing.allocator;

    const cfg = try gpa.create(Config);
    defer {
        cfg.deinit();
        gpa.destroy(cfg);
    }
    cfg.* = Config.init(gpa);
    cfg.is_bare = false;
    try cfg.setUser("User Name", "user@example.com");
    try cfg.setAuthor("Author Name", "author@example.com");
    try cfg.setCommitter("Committer Name", "committer@example.com");

    const bytes = try encodeMemoryConfig(gpa, cfg);
    defer gpa.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "[user]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "name = User Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "email = user@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[author]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "name = Author Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "email = author@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[committer]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "name = Committer Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "email = committer@example.com") != null);

    const got = try decodeMemoryConfig(gpa, bytes);
    defer {
        got.deinit();
        gpa.destroy(got);
    }
    try std.testing.expectEqualStrings("User Name", got.user_name);
    try std.testing.expectEqualStrings("user@example.com", got.user_email);
    try std.testing.expectEqualStrings("Author Name", got.author_name);
    try std.testing.expectEqualStrings("author@example.com", got.author_email);
    try std.testing.expectEqualStrings("Committer Name", got.committer_name);
    try std.testing.expectEqualStrings("committer@example.com", got.committer_email);
}

test "encode/decode user only without author" {
    const gpa = std.testing.allocator;

    const cfg = try gpa.create(Config);
    defer {
        cfg.deinit();
        gpa.destroy(cfg);
    }
    cfg.* = Config.init(gpa);
    try cfg.setUser("Only User", "only@example.com");

    const bytes = try encodeMemoryConfig(gpa, cfg);
    defer gpa.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "[user]") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "[author]") == null);

    const got = try decodeMemoryConfig(gpa, bytes);
    defer {
        got.deinit();
        gpa.destroy(got);
    }
    try std.testing.expectEqualStrings("Only User", got.user_name);
    try std.testing.expectEqualStrings("only@example.com", got.user_email);
    try std.testing.expectEqual(@as(usize, 0), got.author_name.len);
    try std.testing.expectEqual(@as(usize, 0), got.author_email.len);
}
