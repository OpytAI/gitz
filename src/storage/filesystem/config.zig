//! Filesystem config storage (go-git `storage/filesystem/config.go`).
//!
//! On-disk form is real git-config text via `plumbing/format/config` encode/decode.
//! In-memory surface is the shared storage `memory.Config` (`is_bare` + remotes
//! name/urls) used by BaseStorageSuite and the memory backend.
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

/// Encode `memory.Config` as git-config bytes (go-git `Marshal` for bare + remotes).
fn encodeMemoryConfig(allocator: Allocator, cfg: *const Config) Error![]u8 {
    var raw = format_config.Config.init(allocator);
    defer raw.deinit();

    const bare = if (cfg.is_bare) "true" else "false";
    _ = try raw.setOption("core", format_config.NoSubsection, "bare", bare);

    // Stable remote order for deterministic on-disk output (sorted by name).
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    {
        var it = cfg.remotes.keyIterator();
        while (it.next()) |k| try names.append(allocator, k.*);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);

    for (names.items) |name| {
        const remote = cfg.remotes.get(name) orelse continue;
        for (remote.urls) |url| {
            _ = try raw.addOption("remote", name, "url", url);
        }
    }

    var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 128);
    errdefer aw.deinit();
    var enc = format_config.Encoder.init(&aw.writer);
    try enc.encode(&raw);
    return try aw.toOwnedSlice();
}

/// Decode git-config bytes into a heap `memory.Config` (go-git `ReadConfig` for bare + remotes).
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
    }

    if (raw.hasSection("remote")) {
        const remote_sec = try raw.section("remote");
        for (remote_sec.subsections.items) |ss| {
            var urls: std.ArrayList([]const u8) = .empty;
            defer urls.deinit(allocator);
            for (ss.options.items) |opt| {
                if (std.ascii.eqlIgnoreCase(opt.key, "url") or
                    std.ascii.eqlIgnoreCase(opt.key, "pushurl"))
                {
                    try urls.append(allocator, opt.value);
                }
            }
            try c.putRemote(ss.name, urls.items);
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
