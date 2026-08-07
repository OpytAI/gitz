//! Single gitattributes pattern — port of go-git `plumbing/format/gitattributes/pattern.go`.
//!
//! Reference: go-git v5.19.2.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const pattern_dir_sep = "/";
const zero_to_many_dirs = "**";
const is_windows = builtin.os.tag == .windows;

/// A gitattributes path pattern (go-git `Pattern` / `pattern`).
pub const Pattern = struct {
    allocator: Allocator,
    domain: [][]const u8,
    pattern: [][]const u8,

    pub fn deinit(self: *Pattern) void {
        for (self.domain) |s| self.allocator.free(s);
        self.allocator.free(self.domain);
        for (self.pattern) |s| self.allocator.free(s);
        self.allocator.free(self.pattern);
        self.* = undefined;
    }

    /// Match `path` against this pattern (go-git `Pattern.Match`).
    pub fn match(self: *const Pattern, path_in: []const []const u8) bool {
        if (path_in.len <= self.domain.len) return false;
        for (self.domain, 0..) |e, i| {
            if (!std.mem.eql(u8, path_in[i], e)) return false;
        }

        var path: []const []const u8 = undefined;
        if (self.pattern.len == 1) {
            // Simple rule: only the last path segment is considered.
            path = path_in[path_in.len - 1 ..];
        } else {
            path = path_in[self.domain.len..];
        }

        var pattern = self.pattern;
        var matched = false;
        var doublestar = false;

        for (path) |part| {
            if (pattern.len == 0) return false;

            if (pattern[0].len == 0) {
                pattern = pattern[1..];
                if (pattern.len == 0) return false;
            }

            if (std.mem.eql(u8, pattern[0], zero_to_many_dirs)) {
                pattern = pattern[1..];
                if (pattern.len == 0) return true;
                doublestar = true;
            }

            if (std.mem.indexOf(u8, pattern[0], "**") != null) return false;

            if (doublestar) {
                if (filePathMatch(pattern[0], part)) {
                    doublestar = false;
                    pattern = pattern[1..];
                    matched = true;
                }
            } else {
                if (!filePathMatch(pattern[0], part)) return false;
                matched = true;
                pattern = pattern[1..];
            }
        }

        if (pattern.len > 0) return false;
        return matched;
    }
};

/// Parse a gitattributes pattern string (go-git `ParsePattern`).
pub fn parsePattern(allocator: Allocator, p: []const u8, domain: []const []const u8) Allocator.Error!Pattern {
    const domain_owned = try copyStringSlice(allocator, domain);
    errdefer freeStringSlice(allocator, domain_owned);
    const pattern_owned = try splitOwned(allocator, p, pattern_dir_sep[0]);
    errdefer freeStringSlice(allocator, pattern_owned);
    return .{
        .allocator = allocator,
        .domain = domain_owned,
        .pattern = pattern_owned,
    };
}

fn copyStringSlice(allocator: Allocator, src: []const []const u8) Allocator.Error![][]const u8 {
    const out = try allocator.alloc([]const u8, src.len);
    errdefer allocator.free(out);
    var n: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < n) : (i += 1) allocator.free(out[i]);
    }
    for (src) |s| {
        out[n] = try allocator.dupe(u8, s);
        n += 1;
    }
    return out;
}

fn freeStringSlice(allocator: Allocator, slice: [][]const u8) void {
    for (slice) |s| allocator.free(s);
    allocator.free(slice);
}

fn splitOwned(allocator: Allocator, s: []const u8, sep: u8) Allocator.Error![][]const u8 {
    var count: usize = 1;
    for (s) |c| {
        if (c == sep) count += 1;
    }
    const out = try allocator.alloc([]const u8, count);
    errdefer allocator.free(out);
    var n: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < n) : (i += 1) allocator.free(out[i]);
    }
    var start: usize = 0;
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (i == s.len or s[i] == sep) {
            out[n] = try allocator.dupe(u8, s[start..i]);
            n += 1;
            start = i + 1;
        }
    }
    return out;
}

// filepath.Match subset — BadPattern → false.
fn filePathMatch(pattern: []const u8, name: []const u8) bool {
    return matchName(pattern, name) catch false;
}

fn matchName(pattern_in: []const u8, name_in: []const u8) error{BadPattern}!bool {
    var pattern = pattern_in;
    var name = name_in;
    while (pattern.len > 0) {
        const scanned = scanChunk(pattern);
        const star = scanned.star;
        const chunk = scanned.chunk;
        pattern = scanned.rest;
        const t_ok = try matchChunk(chunk, name);
        if (t_ok.ok and (t_ok.rest.len == 0 or pattern.len > 0)) {
            name = t_ok.rest;
            continue;
        }
        if (star) {
            var i: usize = 0;
            while (i < name.len) : (i += 1) {
                if (name[i] == '/') return false;
                const t2 = try matchChunk(chunk, name[i + 1 ..]);
                if (t2.ok) {
                    if (pattern.len == 0 and t2.rest.len > 0) continue;
                    name = t2.rest;
                    break;
                }
            } else return false;
            continue;
        }
        return false;
    }
    return name.len == 0;
}

const ScanResult = struct { star: bool, chunk: []const u8, rest: []const u8 };

fn scanChunk(pattern_in: []const u8) ScanResult {
    var pattern = pattern_in;
    var star = false;
    while (pattern.len > 0 and pattern[0] == '*') {
        pattern = pattern[1..];
        star = true;
    }
    var inrange = false;
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '\\' => {
                if (!is_windows and i + 1 < pattern.len) i += 1;
            },
            '[' => inrange = true,
            ']' => inrange = false,
            '*' => {
                if (!inrange) break;
            },
            else => {},
        }
    }
    return .{ .star = star, .chunk = pattern[0..i], .rest = pattern[i..] };
}

const MatchChunkResult = struct { rest: []const u8, ok: bool };

fn matchChunk(chunk_in: []const u8, s_in: []const u8) error{BadPattern}!MatchChunkResult {
    var chunk = chunk_in;
    var s = s_in;
    while (chunk.len > 0) {
        if (s.len == 0) return .{ .rest = s, .ok = false };
        switch (chunk[0]) {
            '[' => {
                const dr = decodeRune(s);
                s = s[dr.n..];
                chunk = chunk[1..];
                if (chunk.len == 0) return error.BadPattern;
                var negated = false;
                if (chunk[0] == '^') {
                    negated = true;
                    chunk = chunk[1..];
                }
                var matched = false;
                var nrange: usize = 0;
                while (true) {
                    if (chunk.len > 0 and chunk[0] == ']' and nrange > 0) {
                        chunk = chunk[1..];
                        break;
                    }
                    const lo_esc = try getEsc(chunk);
                    const lo = lo_esc.r;
                    chunk = lo_esc.nchunk;
                    var hi = lo;
                    if (chunk.len > 0 and chunk[0] == '-') {
                        const hi_esc = try getEsc(chunk[1..]);
                        hi = hi_esc.r;
                        chunk = hi_esc.nchunk;
                    }
                    if (lo <= dr.r and dr.r <= hi) matched = true;
                    nrange += 1;
                }
                if (matched == negated) return .{ .rest = s, .ok = false };
            },
            '?' => {
                if (s[0] == '/') return .{ .rest = s, .ok = false };
                const dr = decodeRune(s);
                s = s[dr.n..];
                chunk = chunk[1..];
            },
            '\\' => {
                if (!is_windows) {
                    chunk = chunk[1..];
                    if (chunk.len == 0) return error.BadPattern;
                }
                if (chunk[0] != s[0]) return .{ .rest = s, .ok = false };
                s = s[1..];
                chunk = chunk[1..];
            },
            else => {
                if (chunk[0] != s[0]) return .{ .rest = s, .ok = false };
                s = s[1..];
                chunk = chunk[1..];
            },
        }
    }
    return .{ .rest = s, .ok = true };
}

const EscResult = struct { r: u21, nchunk: []const u8 };

fn getEsc(chunk_in: []const u8) error{BadPattern}!EscResult {
    var chunk = chunk_in;
    if (chunk.len == 0 or chunk[0] == '-' or chunk[0] == ']') return error.BadPattern;
    if (chunk[0] == '\\' and !is_windows) {
        chunk = chunk[1..];
        if (chunk.len == 0) return error.BadPattern;
    }
    const dr = decodeRune(chunk);
    if (dr.r == 0xFFFD and dr.n == 1) return error.BadPattern;
    const nchunk = chunk[dr.n..];
    if (nchunk.len == 0) return error.BadPattern;
    return .{ .r = dr.r, .nchunk = nchunk };
}

const DecodedRune = struct { r: u21, n: usize };

fn decodeRune(s: []const u8) DecodedRune {
    if (s.len == 0) return .{ .r = 0xFFFD, .n = 0 };
    const seq_len = std.unicode.utf8ByteSequenceLength(s[0]) catch {
        return .{ .r = 0xFFFD, .n = 1 };
    };
    if (seq_len > s.len) return .{ .r = 0xFFFD, .n = 1 };
    const r = std.unicode.utf8Decode(s[0..seq_len]) catch {
        return .{ .r = 0xFFFD, .n = 1 };
    };
    return .{ .r = r, .n = seq_len };
}

// ---------------------------------------------------------------------------
// Tests (go-git pattern_test.go)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectMatch(pat: []const u8, domain: []const []const u8, path: []const []const u8, want: bool) !void {
    var p = try parsePattern(testing.allocator, pat, domain);
    defer p.deinit();
    try testing.expectEqual(want, p.match(path));
}

test "gitattributes domain mismatches" {
    try expectMatch("value", &.{ "head", "middle", "tail" }, &.{ "head", "middle" }, false);
    try expectMatch("value", &.{ "head", "middle", "tail" }, &.{ "head", "middle", "tail" }, false);
    try expectMatch("value", &.{ "head", "middle", "tail" }, &.{ "head", "middle", "_tail_", "value" }, false);
}

test "gitattributes simple match" {
    try expectMatch("vul?ano", &.{}, &.{ "value", "vulkano" }, true);
    try expectMatch("middle/tail", &.{ "value", "volcano" }, &.{ "value", "volcano", "middle", "tail" }, true);
    try expectMatch("value/volcano", &.{ "value", "volcano" }, &.{ "value", "volcano", "tail" }, false);
    try expectMatch("value", &.{}, &.{ "value", "tail" }, false);
    try expectMatch("value", &.{}, &.{ "head", "value", "tail" }, false);
    try expectMatch("value", &.{}, &.{ "head", "value" }, true);
    try expectMatch("value", &.{}, &.{ "head", "val", "tail" }, false);
    try expectMatch("tai", &.{}, &.{ "head", "value", "tail" }, false);
    try expectMatch("t*l", &.{}, &.{ "value", "vulkano", "tail" }, true);
    try expectMatch("ta?l", &.{}, &.{ "value", "vulkano", "tail" }, true);
    try expectMatch("v[ou]l[kc]ano", &.{}, &.{ "value", "volcano" }, true);
    try expectMatch("v[ou]l[", &.{}, &.{ "value", "vol[" }, false);
}

test "gitattributes glob match" {
    try expectMatch("/value/vul?ano/tail", &.{}, &.{ "value", "vulkano", "tail" }, true);
    try expectMatch("middle/tail", &.{ "value", "volcano" }, &.{ "value", "volcano", "middle", "tail" }, true);
    try expectMatch("volcano/tail", &.{ "value", "volcano" }, &.{ "value", "volcano", "tail" }, false);
    try expectMatch("value/vul?ano/tail", &.{}, &.{ "value", "vulkano", "tail" }, true);
    try expectMatch("value/vulkano", &.{}, &.{ "value", "volcano" }, false);
    try expectMatch("value/vul?ano", &.{}, &.{"value"}, false);
    try expectMatch("/value/volcano", &.{}, &.{ "value", "value", "volcano" }, false);
    try expectMatch("**/*lue/vol?ano/ta?l", &.{}, &.{ "value", "volcano", "tail" }, true);
    try expectMatch("**/*lue/vol?ano/tail", &.{}, &.{ "head", "value", "volcano", "tail" }, true);
    try expectMatch("**/*lue/vol?ano/tail", &.{}, &.{ "head", "value", "Volcano", "tail" }, false);
    try expectMatch("/*lue/vol?ano/**", &.{}, &.{ "value", "volcano", "tail", "moretail" }, true);
    try expectMatch("/*lue/**", &.{}, &.{ "value", "volcano" }, true);
    try expectMatch("/*lue/*", &.{}, &.{ "value", "volcano", "tail" }, false);
    try expectMatch("/*lue/vol?ano/**", &.{}, &.{ "value", "volcano" }, false);
    try expectMatch("/*lue/**/vol?ano", &.{}, &.{ "value", "volcano" }, true);
    try expectMatch("/*lue/**/vol?ano", &.{}, &.{ "value", "middle", "volcano" }, true);
    try expectMatch("/*lue/**/vol?ano", &.{}, &.{ "value", "middle1", "middle2", "volcano" }, true);
    try expectMatch("/*lue/**foo/vol?ano/tail", &.{}, &.{ "value", "foo", "volcano", "tail" }, false);
    try expectMatch("**/head/v[ou]l[kc]ano", &.{}, &.{ "value", "head", "volcano" }, true);
    try expectMatch("**/head/v[ou]l[", &.{}, &.{ "value", "head", "vol[" }, false);
    try expectMatch("/value/**/v[ou]l[", &.{}, &.{ "value", "head", "vol[" }, false);
    try expectMatch(
        "**/android/**/GeneratedPluginRegistrant.java",
        &.{},
        &.{ "packages", "flutter_tools", "lib", "src", "android", "gradle.dart" },
        false,
    );
}
