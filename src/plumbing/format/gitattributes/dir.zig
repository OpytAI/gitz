//! Load gitattributes from a repository tree and gitconfig.
//!
//! Port of go-git v5.19.2 `plumbing/format/gitattributes/dir.go`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fs_pkg = @import("fs");
const format_config = @import("config");

const attributes_mod = @import("attributes.zig");
const matcher_mod = @import("matcher.zig");

const MatchAttribute = attributes_mod.MatchAttribute;
const freeMatchAttributes = attributes_mod.freeMatchAttributes;
const readAttributes = attributes_mod.readAttributes;
const newMatcher = matcher_mod.newMatcher;

const core_section = "core";
const attributesfile = "attributesfile";
const git_dir = ".git";
const gitattributes_file = ".gitattributes";
const gitconfig_file = ".gitconfig";
const system_file = "/etc/gitconfig";

pub const Error = Allocator.Error || fs_pkg.Error || attributes_mod.Error || format_config.Error;

/// Read one attributes file (go-git `ReadAttributesFile`).
/// Missing file → empty list.
pub fn readAttributesFile(
    allocator: Allocator,
    fs: anytype,
    path: []const []const u8,
    attributes_file: []const u8,
    allow_macro: bool,
) Error![]MatchAttribute {
    const full = try joinDomainFile(allocator, fs, path, attributes_file);
    defer allocator.free(full);

    var f = fs.open(full) catch |err| switch (err) {
        error.NotExist => return &.{},
        else => |e| return e,
    };
    defer f.close() catch {};

    const data = try readAll(allocator, &f);
    defer allocator.free(data);

    return try readAttributes(allocator, data, path, allow_macro);
}

/// Read gitattributes patterns recursively (go-git `ReadPatterns`).
///
/// Root `.gitattributes` allows macros; nested files do not.
pub fn readPatterns(
    allocator: Allocator,
    fs: anytype,
    path: []const []const u8,
) Error![]MatchAttribute {
    var attributes = try readAttributesFile(allocator, fs, path, gitattributes_file, true);
    errdefer freeMatchAttributes(allocator, attributes);

    const nested = try walkDirectory(allocator, fs, path);
    try takeAppend(allocator, &attributes, nested);
    return attributes;
}

fn walkDirectory(
    allocator: Allocator,
    fs: anytype,
    root: []const []const u8,
) Error![]MatchAttribute {
    const dir_path = try joinDomain(allocator, fs, root);
    defer allocator.free(dir_path);

    const fis = try fs.readDir(dir_path);
    defer fs.freeReadDir(fis);

    var attributes: []MatchAttribute = &.{};
    errdefer freeMatchAttributes(allocator, attributes);

    for (fis) |fi| {
        if (!fi.isDir() or std.mem.eql(u8, fi.name, git_dir)) continue;

        const child = try appendPathSeg(allocator, root, fi.name);
        defer freePathSegs(allocator, child);

        const dir_attrs = try readAttributesFile(allocator, fs, child, gitattributes_file, false);
        try takeAppend(allocator, &attributes, dir_attrs);

        const sub = try walkDirectory(allocator, fs, child);
        try takeAppend(allocator, &attributes, sub);
    }
    return attributes;
}

fn loadPatterns(
    allocator: Allocator,
    fs: anytype,
    config_path: []const u8,
) Error![]MatchAttribute {
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
    // go-git: decode error → (nil, nil)
    dec.decode(&raw) catch return &.{};

    const sec = try raw.section(core_section);
    const path = sec.option(attributesfile);
    if (path.len == 0) return &.{};

    return try readAttributesFile(allocator, fs, &.{}, path, true);
}

/// Load from `core.attributesfile` in `$home/.gitconfig` (go-git `LoadGlobalPatterns`).
///
/// Caller supplies `home` (like injecting `UserHomeDir`); this package does not
/// call libc `getenv` / passwd lookup.
pub fn loadGlobalPatterns(
    allocator: Allocator,
    fs: anytype,
    home: []const u8,
) Error![]MatchAttribute {
    const cfg_path = try fs.joinPath(&.{ home, gitconfig_file });
    defer allocator.free(cfg_path);
    return try loadPatterns(allocator, fs, cfg_path);
}

/// Load from `core.attributesfile` in `/etc/gitconfig` (go-git `LoadSystemPatterns`).
pub fn loadSystemPatterns(
    allocator: Allocator,
    fs: anytype,
) Error![]MatchAttribute {
    return try loadPatterns(allocator, fs, system_file);
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

fn joinDomain(allocator: Allocator, fs: anytype, path: []const []const u8) Allocator.Error![]u8 {
    _ = allocator;
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
    const out = try allocator.alloc([]const u8, path.len + 1);
    errdefer allocator.free(out);
    var n: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < n) : (i += 1) allocator.free(out[i]);
    }
    for (path) |p| {
        out[n] = try allocator.dupe(u8, p);
        n += 1;
    }
    out[n] = try allocator.dupe(u8, name);
    n += 1;
    return out;
}

fn freePathSegs(allocator: Allocator, path: [][]const u8) void {
    for (path) |p| allocator.free(p);
    allocator.free(path);
}

fn takeAppend(allocator: Allocator, base: *[]MatchAttribute, extra: []MatchAttribute) Allocator.Error!void {
    if (extra.len == 0) {
        freeMatchAttributes(allocator, extra);
        return;
    }
    const new_len = base.*.len + extra.len;
    if (base.*.len == 0) {
        // base may be static `&.{}` — cannot realloc.
        const out = try allocator.alloc(MatchAttribute, new_len);
        @memcpy(out, extra);
        allocator.free(extra);
        base.* = out;
        return;
    }
    const out = allocator.realloc(base.*, new_len) catch |err| {
        freeMatchAttributes(allocator, extra);
        return err;
    };
    @memcpy(out[base.*.len..], extra);
    allocator.free(extra);
    base.* = out;
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

fn writeGlobalAttrs(fs: *Mem, filename: []const u8) !void {
    try writeFile(fs, filename, "# IntelliJ\n.idea/** text\n*.iml -text\n");
}

test "Dir ReadPatterns" {
    const gpa = testing.allocator;
    var fs = try Mem.init(gpa);
    defer fs.deinit();

    try writeFile(&fs, ".gitattributes", "vendor/g*/** foo=bar\n");
    try fs.mkdirAll("vendor", 0o755);
    try writeFile(&fs, "vendor/.gitattributes", "github.com/** -foo\n");
    try fs.mkdirAll("another", 0o755);
    try fs.mkdirAll("vendor/github.com", 0o755);
    try fs.mkdirAll("vendor/gopkg.in", 0o755);

    const ps = try readPatterns(gpa, &fs, &.{});
    defer freeMatchAttributes(gpa, ps);
    try testing.expectEqual(@as(usize, 2), ps.len);

    var m = try newMatcher(gpa, ps);
    defer m.deinit();

    {
        var out = try m.match(gpa, &.{ "vendor", "gopkg.in", "file" }, &.{});
        defer out.results.deinit(gpa);
        try testing.expectEqualStrings("bar", out.results.get("foo").?.value);
    }
    {
        var out = try m.match(gpa, &.{ "vendor", "github.com", "file" }, &.{});
        defer out.results.deinit(gpa);
        // go-git: lower-priority root overwrites; IsUnset is false
        try testing.expect(!out.results.get("foo").?.isUnset());
    }
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
    const attrs = try fs.joinPath(&.{ home, ".gitattributes_global" });
    defer gpa.free(attrs);

    const quoted = try std.fmt.allocPrint(gpa, "\"{s}\"", .{attrs});
    defer gpa.free(quoted);
    const cfg_body = try std.fmt.allocPrint(gpa, "[core]\n\tattributesfile = {s}\n", .{quoted});
    defer gpa.free(cfg_body);
    try writeFile(&fs, cfg, cfg_body);
    try writeGlobalAttrs(&fs, attrs);

    const ps = try loadGlobalPatterns(gpa, &fs, home);
    defer freeMatchAttributes(gpa, ps);
    try testing.expectEqual(@as(usize, 2), ps.len);

    var m = try newMatcher(gpa, ps);
    defer m.deinit();

    {
        var out = try m.match(gpa, &.{"go-git.v4.iml"}, &.{});
        defer out.results.deinit(gpa);
        try testing.expect(out.results.get("text").?.isUnset());
    }
    {
        var out = try m.match(gpa, &.{ ".idea", "file" }, &.{});
        defer out.results.deinit(gpa);
        try testing.expect(out.results.get("text").?.isSet());
    }
}

test "Dir LoadGlobalPatterns missing gitconfig" {
    const gpa = testing.allocator;
    const home = test_home;

    var fs = try Mem.init(gpa);
    defer fs.deinit();
    const attrs = try fs.joinPath(&.{ home, ".gitattributes_global" });
    defer gpa.free(attrs);
    try writeGlobalAttrs(&fs, attrs);

    const ps = try loadGlobalPatterns(gpa, &fs, home);
    defer freeMatchAttributes(gpa, ps);
    try testing.expectEqual(@as(usize, 0), ps.len);
}

test "Dir LoadGlobalPatterns missing attributesfile" {
    const gpa = testing.allocator;
    const home = test_home;

    var fs = try Mem.init(gpa);
    defer fs.deinit();
    try fs.mkdirAll(home, 0o755);
    const cfg = try fs.joinPath(&.{ home, gitconfig_file });
    defer gpa.free(cfg);
    try writeFile(&fs, cfg, "[core]\n");
    const attrs = try fs.joinPath(&.{ home, ".gitattributes_global" });
    defer gpa.free(attrs);
    try writeGlobalAttrs(&fs, attrs);

    const ps = try loadGlobalPatterns(gpa, &fs, home);
    defer freeMatchAttributes(gpa, ps);
    try testing.expectEqual(@as(usize, 0), ps.len);
}

test "Dir LoadGlobalPatterns missing gitattributes" {
    const gpa = testing.allocator;
    const home = test_home;

    var fs = try Mem.init(gpa);
    defer fs.deinit();
    try fs.mkdirAll(home, 0o755);
    const cfg = try fs.joinPath(&.{ home, gitconfig_file });
    defer gpa.free(cfg);
    const attrs = try fs.joinPath(&.{ home, ".gitattributes_global" });
    defer gpa.free(attrs);
    const quoted = try std.fmt.allocPrint(gpa, "\"{s}\"", .{attrs});
    defer gpa.free(quoted);
    const cfg_body = try std.fmt.allocPrint(gpa, "[core]\n\tattributesfile = {s}\n", .{quoted});
    defer gpa.free(cfg_body);
    try writeFile(&fs, cfg, cfg_body);

    const ps = try loadGlobalPatterns(gpa, &fs, home);
    defer freeMatchAttributes(gpa, ps);
    try testing.expectEqual(@as(usize, 0), ps.len);
}

test "Dir LoadSystemPatterns" {
    const gpa = testing.allocator;
    var fs = try Mem.init(gpa);
    defer fs.deinit();
    try fs.mkdirAll("etc", 0o755);
    try writeFile(&fs, system_file, "[core]\n\tattributesfile = /etc/gitattributes_global\n");
    try writeGlobalAttrs(&fs, "/etc/gitattributes_global");

    const ps = try loadSystemPatterns(gpa, &fs);
    defer freeMatchAttributes(gpa, ps);
    try testing.expectEqual(@as(usize, 2), ps.len);

    var m = try newMatcher(gpa, ps);
    defer m.deinit();

    {
        var out = try m.match(gpa, &.{"go-git.v4.iml"}, &.{});
        defer out.results.deinit(gpa);
        try testing.expect(out.results.get("text").?.isUnset());
    }
    {
        var out = try m.match(gpa, &.{ ".idea", "file" }, &.{});
        defer out.results.deinit(gpa);
        try testing.expect(out.results.get("text").?.isSet());
    }
}
