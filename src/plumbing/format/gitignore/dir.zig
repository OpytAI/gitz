//! Load gitignore patterns from a repository tree and gitconfig.
//!
//! Port of go-git v5.19.2 `plumbing/format/gitignore/dir.go`.
//! Filesystem access uses monomorphised billy-style `fs` backends (`Mem` / `Os`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const fs_pkg = @import("fs");
const format_config = @import("config");

const pattern_mod = @import("pattern.zig");
const matcher_mod = @import("matcher.zig");

const Pattern = pattern_mod.Pattern;
const parsePattern = pattern_mod.parsePattern;
const newMatcher = matcher_mod.newMatcher;

const comment_prefix = "#";
const core_section = "core";
const excludesfile = "excludesfile";
const git_dir = ".git";
const gitignore_file = ".gitignore";
const gitconfig_file = ".gitconfig";
const system_file = "/etc/gitconfig";
const info_exclude_file = ".git/info/exclude";

/// Free a slice returned by `readPatterns` / `loadGlobalPatterns` / `loadSystemPatterns`.
///
/// Empty results are always the non-owned sentinel `&.{}` (missing file, empty
/// config, etc.) — never an `alloc(0)` slice. Only free the outer container when
/// `ps.len > 0`.
pub fn freePatterns(allocator: Allocator, ps: []Pattern) void {
    for (ps) |*p| p.deinit();
    if (ps.len > 0) allocator.free(ps);
}

/// Read a specific git ignore file (go-git `readIgnoreFile`).
///
/// Missing file yields an empty list (not an error). Other open errors propagate.
/// `home` is used only to expand a leading `~/` in `ignore_file_in` (see `expandTilde`).
fn readIgnoreFile(
    allocator: Allocator,
    fs: anytype,
    path: []const []const u8,
    ignore_file_in: []const u8,
    home: []const u8,
) (Allocator.Error || fs_pkg.Error)![]Pattern {
    const ignore_file = try expandTilde(allocator, ignore_file_in, home);
    defer allocator.free(ignore_file);

    const full = try joinDomainFile(allocator, fs, path, ignore_file);
    defer allocator.free(full);

    var f = fs.open(full) catch |err| switch (err) {
        error.NotExist => return &.{},
        else => |e| return e,
    };
    defer f.close() catch {};

    const data = try readAll(allocator, &f);
    defer allocator.free(data);

    var list: std.ArrayList(Pattern) = .empty;
    errdefer {
        for (list.items) |*p| p.deinit();
        list.deinit(allocator);
    }

    var start: usize = 0;
    var i: usize = 0;
    while (i <= data.len) : (i += 1) {
        if (i == data.len or data[i] == '\n') {
            var line = data[start..i];
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0 .. line.len - 1];
            }
            start = i + 1;
            if (std.mem.startsWith(u8, line, comment_prefix)) continue;
            if (std.mem.trim(u8, line, " \t").len == 0) continue;
            const pat = try parsePattern(allocator, line, path);
            try list.append(allocator, pat);
        }
    }
    if (list.items.len == 0) {
        // Keep empty as non-owned `&.{}` so freePatterns never frees a sentinel.
        list.deinit(allocator);
        return &.{};
    }
    return try list.toOwnedSlice(allocator);
}

/// Read `.git/info/exclude` then gitignore patterns recursively (go-git `ReadPatterns`).
///
/// Result is ascending priority (last higher). Caller frees with `freePatterns`.
pub fn readPatterns(
    allocator: Allocator,
    fs: anytype,
    path: []const []const u8,
) (Allocator.Error || fs_pkg.Error)![]Pattern {
    // Repo-relative paths; no home needed for tilde expansion.
    var ps = try readIgnoreFile(allocator, fs, path, info_exclude_file, "");
    errdefer freePatterns(allocator, ps);

    {
        const subps = try readIgnoreFile(allocator, fs, path, gitignore_file, "");
        try takeAppend(allocator, &ps, subps);
    }

    const dir_path = try joinDomain(fs, path);
    defer allocator.free(dir_path);

    const fis = try fs.readDir(dir_path);
    defer fs.freeReadDir(fis);

    for (fis) |fi| {
        if (!fi.isDir()) continue;
        if (std.mem.eql(u8, fi.name, git_dir)) continue;

        const child_path = try appendPathSeg(allocator, path, fi.name);
        defer freePathSegs(allocator, child_path);

        if (newMatcher(ps).match(child_path, true)) continue;

        const nested = try readPatterns(allocator, fs, child_path);
        try takeAppend(allocator, &ps, nested);
    }
    return ps;
}

fn loadPatterns(
    allocator: Allocator,
    fs: anytype,
    config_path: []const u8,
    home: []const u8,
) (Allocator.Error || fs_pkg.Error || format_config.Error)![]Pattern {
    var f = fs.open(config_path) catch |err| switch (err) {
        error.NotExist => return &.{},
        else => |e| return e,
    };
    defer f.close() catch {};

    const data = try readAll(allocator, &f);
    defer allocator.free(data);

    var raw = format_config.Config.init(allocator);
    defer raw.deinit();
    var reader = std.Io.Reader.fixed(data);
    var dec = format_config.Decoder.init(&reader);
    try dec.decode(&raw);

    const sec = try raw.section(core_section);
    const efo = sec.option(excludesfile);
    if (efo.len == 0) return &.{};

    return try readIgnoreFile(allocator, fs, &.{}, efo, home);
}

/// Load gitignore patterns from `core.excludesfile` in `$home/.gitconfig`
/// (go-git `LoadGlobalPatterns`).
///
/// Caller supplies `home` (like injecting `UserHomeDir`); this package does not
/// call libc `getenv` / passwd lookup.
pub fn loadGlobalPatterns(
    allocator: Allocator,
    fs: anytype,
    home: []const u8,
) (Allocator.Error || fs_pkg.Error || format_config.Error)![]Pattern {
    const cfg_path = try fs.joinPath(&.{ home, gitconfig_file });
    defer allocator.free(cfg_path);
    return try loadPatterns(allocator, fs, cfg_path, home);
}

/// Load gitignore patterns from `core.excludesfile` in `/etc/gitconfig`
/// (go-git `LoadSystemPatterns`).
///
/// Tilde expansion in `core.excludesfile` is not applied (no home injected).
pub fn loadSystemPatterns(
    allocator: Allocator,
    fs: anytype,
) (Allocator.Error || fs_pkg.Error || format_config.Error)![]Pattern {
    return try loadPatterns(allocator, fs, system_file, "");
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn readAll(allocator: Allocator, f: anytype) (Allocator.Error || fs_pkg.Error)![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
    }
    return try list.toOwnedSlice(allocator);
}

fn joinDomain(fs: anytype, path: []const []const u8) (Allocator.Error)![]u8 {
    if (path.len == 0) return try fs.joinPath(&.{"."});
    return try fs.joinPath(path);
}

fn joinDomainFile(
    allocator: Allocator,
    fs: anytype,
    path: []const []const u8,
    file: []const u8,
) Allocator.Error![]u8 {
    if (path.len == 0) return try fs.joinPath(&.{file});
    var parts = try allocator.alloc([]const u8, path.len + 1);
    defer allocator.free(parts);
    for (path, 0..) |p, i| parts[i] = p;
    parts[path.len] = file;
    return try fs.joinPath(parts);
}

fn appendPathSeg(allocator: Allocator, path: []const []const u8, name: []const u8) Allocator.Error![][]const u8 {
    var out = try allocator.alloc([]const u8, path.len + 1);
    errdefer allocator.free(out);
    for (path, 0..) |p, i| {
        out[i] = try allocator.dupe(u8, p);
    }
    errdefer {
        var i: usize = 0;
        while (i < path.len) : (i += 1) allocator.free(out[i]);
    }
    out[path.len] = try allocator.dupe(u8, name);
    return out;
}

fn freePathSegs(allocator: Allocator, path: [][]const u8) void {
    for (path) |p| allocator.free(p);
    allocator.free(path);
}

/// Move all patterns from `extra` onto `base`. Takes ownership of `extra`
/// (pattern values and container). Updates `base` in place.
fn takeAppend(allocator: Allocator, base: *[]Pattern, extra: []Pattern) Allocator.Error!void {
    if (extra.len == 0) {
        freePatterns(allocator, extra);
        return;
    }
    const new_len = base.*.len + extra.len;
    if (base.*.len == 0) {
        // base may be static `&.{}` — allocate fresh (cannot realloc).
        const out = try allocator.alloc(Pattern, new_len);
        @memcpy(out, extra);
        allocator.free(extra);
        base.* = out;
        return;
    }
    const out = allocator.realloc(base.*, new_len) catch |err| {
        freePatterns(allocator, extra);
        return err;
    };
    @memcpy(out[base.*.len..], extra);
    // Pattern values moved; free only the `extra` container.
    allocator.free(extra);
    base.* = out;
}

/// Expand leading `~/` using the provided home directory (go-git `ReplaceTildeWithHome`).
///
/// - `~/path` → `{home}/path` (caller supplies home; no libc getenv).
/// - `~user/path` → left unchanged (no `getpwnam` / passwd lookup).
/// - other paths → duplicated unchanged.
///
/// Always returns an owned slice.
fn expandTilde(allocator: Allocator, path: []const u8, home: []const u8) Allocator.Error![]u8 {
    if (path.len == 0 or path[0] != '~') return try allocator.dupe(u8, path);

    const slash = std.mem.indexOfScalar(u8, path, '/') orelse {
        return try allocator.dupe(u8, path);
    };

    if (slash == 1) {
        // ~/...
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, path[1..] });
    }

    // ~user/... — no passwd lookup; leave unchanged.
    return try allocator.dupe(u8, path);
}

// ---------------------------------------------------------------------------
// Tests (go-git dir_test.go — mem FS)
// ---------------------------------------------------------------------------

const testing = std.testing;
const Mem = fs_pkg.Mem;

fn writeFile(fs: *Mem, path: []const u8, content: []const u8) !void {
    var f = try fs.create(path);
    defer f.close() catch {};
    _ = try f.write(content);
}

fn setupRepoFs(allocator: Allocator) !Mem {
    var fs = try Mem.init(allocator);
    errdefer fs.deinit();

    try fs.mkdirAll(".git/info", 0o755);
    try writeFile(&fs, ".git/info/exclude", "exclude.crlf\r\n");
    try writeFile(&fs, ".gitignore", "vendor/g*/\nignore.crlf\r\nignore_dir\n");

    try fs.mkdirAll("vendor", 0o755);
    try writeFile(&fs, "vendor/.gitignore", "!github.com/\n");

    try fs.mkdirAll("ignore_dir", 0o755);
    try writeFile(&fs, "ignore_dir/.gitignore", "!file\n");
    try writeFile(&fs, "ignore_dir/file", "");

    try fs.mkdirAll("another", 0o755);
    try fs.mkdirAll("exclude.crlf", 0o755);
    try fs.mkdirAll("ignore.crlf", 0o755);
    try fs.mkdirAll("vendor/github.com", 0o755);
    try fs.mkdirAll("vendor/gopkg.in", 0o755);

    try fs.mkdirAll("multiple/sub/ignores/first", 0o755);
    try fs.mkdirAll("multiple/sub/ignores/second", 0o755);
    try writeFile(&fs, "multiple/sub/ignores/first/.gitignore", "ignore_dir\n");
    try writeFile(&fs, "multiple/sub/ignores/second/.gitignore", "ignore_dir\n");
    try fs.mkdirAll("multiple/sub/ignores/first/ignore_dir", 0o755);
    try fs.mkdirAll("multiple/sub/ignores/second/ignore_dir", 0o755);

    return fs;
}

fn checkReadPatterns(ps: []const Pattern) !void {
    try testing.expectEqual(@as(usize, 7), ps.len);
    const m = newMatcher(ps);
    try testing.expect(m.match(&.{"exclude.crlf"}, true));
    try testing.expect(m.match(&.{"ignore.crlf"}, true));
    try testing.expect(m.match(&.{ "vendor", "gopkg.in" }, true));
    try testing.expect(m.match(&.{ "ignore_dir", "file" }, false));
    try testing.expect(!m.match(&.{ "vendor", "github.com" }, true));
    try testing.expect(m.match(&.{ "multiple", "sub", "ignores", "first", "ignore_dir" }, true));
    try testing.expect(m.match(&.{ "multiple", "sub", "ignores", "second", "ignore_dir" }, true));
}

test "Dir ReadPatterns" {
    const gpa = testing.allocator;
    var fs = try setupRepoFs(gpa);
    defer fs.deinit();

    const ps = try readPatterns(gpa, &fs, &.{});
    defer freePatterns(gpa, ps);
    try checkReadPatterns(ps);
}

/// Synthetic home for Mem FS global-pattern tests (caller-owned; no real HOME).
const test_home = "/home/test";

test "Dir LoadGlobalPatterns" {
    const gpa = testing.allocator;
    const home = test_home;

    var fs = try Mem.init(gpa);
    defer fs.deinit();
    try fs.mkdirAll(home, 0o755);

    const cfg = try fs.joinPath(&.{ home, gitconfig_file });
    defer gpa.free(cfg);
    const ignores = try fs.joinPath(&.{ home, ".gitignore_global" });
    defer gpa.free(ignores);

    // Quote path like go-git strconv.Quote
    const quoted = try std.fmt.allocPrint(gpa, "\"{s}\"", .{ignores});
    defer gpa.free(quoted);
    const cfg_body = try std.fmt.allocPrint(gpa, "[core]\n\texcludesfile = {s}\n", .{quoted});
    defer gpa.free(cfg_body);
    try writeFile(&fs, cfg, cfg_body);
    try writeFile(&fs, ignores, "# IntelliJ\n.idea/\n*.iml\n");

    const ps = try loadGlobalPatterns(gpa, &fs, home);
    defer freePatterns(gpa, ps);
    try testing.expectEqual(@as(usize, 2), ps.len);

    const m = newMatcher(ps);
    try testing.expect(m.match(&.{"go-git.v4.iml"}, true));
    try testing.expect(m.match(&.{".idea"}, true));
}

test "Dir LoadGlobalPatterns missing gitconfig" {
    const gpa = testing.allocator;
    const home = test_home;

    var fs = try Mem.init(gpa);
    defer fs.deinit();
    try fs.mkdirAll(home, 0o755);
    const ignores = try fs.joinPath(&.{ home, ".gitignore_global" });
    defer gpa.free(ignores);
    try writeFile(&fs, ignores, "# IntelliJ\n.idea/\n*.iml\n");

    const ps = try loadGlobalPatterns(gpa, &fs, home);
    defer freePatterns(gpa, ps);
    try testing.expectEqual(@as(usize, 0), ps.len);
}

test "Dir LoadGlobalPatterns missing excludesfile" {
    const gpa = testing.allocator;
    const home = test_home;

    var fs = try Mem.init(gpa);
    defer fs.deinit();
    try fs.mkdirAll(home, 0o755);
    const cfg = try fs.joinPath(&.{ home, gitconfig_file });
    defer gpa.free(cfg);
    try writeFile(&fs, cfg, "[core]\n");
    const ignores = try fs.joinPath(&.{ home, ".gitignore_global" });
    defer gpa.free(ignores);
    try writeFile(&fs, ignores, "# IntelliJ\n.idea/\n*.iml\n");

    const ps = try loadGlobalPatterns(gpa, &fs, home);
    defer freePatterns(gpa, ps);
    try testing.expectEqual(@as(usize, 0), ps.len);
}

test "Dir LoadGlobalPatterns missing gitignore" {
    const gpa = testing.allocator;
    const home = test_home;

    var fs = try Mem.init(gpa);
    defer fs.deinit();
    try fs.mkdirAll(home, 0o755);
    const cfg = try fs.joinPath(&.{ home, gitconfig_file });
    defer gpa.free(cfg);
    const ignores = try fs.joinPath(&.{ home, ".gitignore_global" });
    defer gpa.free(ignores);
    const quoted = try std.fmt.allocPrint(gpa, "\"{s}\"", .{ignores});
    defer gpa.free(quoted);
    const cfg_body = try std.fmt.allocPrint(gpa, "[core]\n\texcludesfile = {s}\n", .{quoted});
    defer gpa.free(cfg_body);
    try writeFile(&fs, cfg, cfg_body);

    const ps = try loadGlobalPatterns(gpa, &fs, home);
    defer freePatterns(gpa, ps);
    try testing.expectEqual(@as(usize, 0), ps.len);
}

test "Dir LoadGlobalPatterns relative tilde" {
    const gpa = testing.allocator;
    const home = test_home;

    var fs = try Mem.init(gpa);
    defer fs.deinit();
    try fs.mkdirAll(home, 0o755);
    const cfg = try fs.joinPath(&.{ home, gitconfig_file });
    defer gpa.free(cfg);
    try writeFile(&fs, cfg, "[core]\n\texcludesfile = ~/.gitignore_global\n");
    const ignores = try fs.joinPath(&.{ home, ".gitignore_global" });
    defer gpa.free(ignores);
    try writeFile(&fs, ignores, "# IntelliJ\n.idea/\n*.iml\n");

    const ps = try loadGlobalPatterns(gpa, &fs, home);
    defer freePatterns(gpa, ps);
    try testing.expectEqual(@as(usize, 2), ps.len);

    const m = newMatcher(ps);
    // go-git TestDir_ReadRelativeGlobalGitIgnore:
    // Match([]string{".idea/"}, true) is false — pattern is ".idea/" dir-only
    // against path segment ".idea/" (slash in name) which does not match basename ".idea".
    // Match on literal "*.iml" is true; "IntelliJ" (comment text) is false.
    try testing.expect(!m.match(&.{".idea/"}, true));
    try testing.expect(m.match(&.{"*.iml"}, true));
    try testing.expect(!m.match(&.{"IntelliJ"}, true));
}

test "Dir LoadGlobalPatterns ~user path not expanded" {
    // go-git RFSU expands ~user via passwd; gitz leaves ~user unchanged (no getpwnam).
    // With only a file under home, LoadGlobalPatterns yields no patterns.
    const gpa = testing.allocator;
    const home = test_home;

    var fs = try Mem.init(gpa);
    defer fs.deinit();
    try fs.mkdirAll(home, 0o755);
    const cfg = try fs.joinPath(&.{ home, gitconfig_file });
    defer gpa.free(cfg);
    try writeFile(&fs, cfg, "[core]\n\texcludesfile = ~testuser/.gitignore_global\n");
    const ignores = try fs.joinPath(&.{ home, ".gitignore_global" });
    defer gpa.free(ignores);
    try writeFile(&fs, ignores, "# IntelliJ\n.idea/\n*.iml\n");

    const ps = try loadGlobalPatterns(gpa, &fs, home);
    defer freePatterns(gpa, ps);
    try testing.expectEqual(@as(usize, 0), ps.len);
}

test "expandTilde ~/ uses home; ~user unchanged" {
    const gpa = testing.allocator;
    const home = test_home;

    const expanded = try expandTilde(gpa, "~/.gitignore_global", home);
    defer gpa.free(expanded);
    try testing.expectEqualStrings("/home/test/.gitignore_global", expanded);

    const user_path = try expandTilde(gpa, "~alice/.gitignore_global", home);
    defer gpa.free(user_path);
    try testing.expectEqualStrings("~alice/.gitignore_global", user_path);

    const bare = try expandTilde(gpa, "~", home);
    defer gpa.free(bare);
    try testing.expectEqualStrings("~", bare);

    const plain = try expandTilde(gpa, "/abs/path", home);
    defer gpa.free(plain);
    try testing.expectEqualStrings("/abs/path", plain);
}

test "Dir LoadSystemPatterns" {
    const gpa = testing.allocator;
    var fs = try Mem.init(gpa);
    defer fs.deinit();
    try fs.mkdirAll("etc", 0o755);
    try writeFile(&fs, system_file, "[core]\n\texcludesfile = /etc/gitignore_global\n");
    try writeFile(&fs, "/etc/gitignore_global", "# IntelliJ\n.idea/\n*.iml\n");

    const ps = try loadSystemPatterns(gpa, &fs);
    defer freePatterns(gpa, ps);
    try testing.expectEqual(@as(usize, 2), ps.len);

    const m = newMatcher(ps);
    try testing.expect(m.match(&.{"go-git.v4.iml"}, true));
    try testing.expect(m.match(&.{".idea"}, true));
}
