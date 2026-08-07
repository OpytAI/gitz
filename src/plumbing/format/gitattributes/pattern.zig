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
// Tests (go-git pattern_test.go — one row per suite method)
// ---------------------------------------------------------------------------

const testing = std.testing;

const Case = struct {
    /// go-git test method name (PatternSuite).
    name: []const u8,
    pattern: []const u8,
    domain: []const []const u8 = &.{},
    path: []const []const u8,
    want: bool,
};

// Full vector table from go-git plumbing/format/gitattributes/pattern_test.go.
const go_git_pattern_cases = [_]Case{
    .{ .name = "TestMatch_domainLonger_mismatch", .pattern = "value", .domain = &.{ "head", "middle", "tail" }, .path = &.{ "head", "middle" }, .want = false },
    .{ .name = "TestMatch_domainSameLength_mismatch", .pattern = "value", .domain = &.{ "head", "middle", "tail" }, .path = &.{ "head", "middle", "tail" }, .want = false },
    .{ .name = "TestMatch_domainMismatch_mismatch", .pattern = "value", .domain = &.{ "head", "middle", "tail" }, .path = &.{ "head", "middle", "_tail_", "value" }, .want = false },
    .{ .name = "TestSimpleMatch_match", .pattern = "vul?ano", .path = &.{ "value", "vulkano" }, .want = true },
    .{ .name = "TestSimpleMatch_withDomain", .pattern = "middle/tail", .domain = &.{ "value", "volcano" }, .path = &.{ "value", "volcano", "middle", "tail" }, .want = true },
    .{ .name = "TestSimpleMatch_onlyMatchInDomain_mismatch", .pattern = "value/volcano", .domain = &.{ "value", "volcano" }, .path = &.{ "value", "volcano", "tail" }, .want = false },
    .{ .name = "TestSimpleMatch_atStart", .pattern = "value", .path = &.{ "value", "tail" }, .want = false },
    .{ .name = "TestSimpleMatch_inTheMiddle", .pattern = "value", .path = &.{ "head", "value", "tail" }, .want = false },
    .{ .name = "TestSimpleMatch_atEnd", .pattern = "value", .path = &.{ "head", "value" }, .want = true },
    .{ .name = "TestSimpleMatch_mismatch", .pattern = "value", .path = &.{ "head", "val", "tail" }, .want = false },
    .{ .name = "TestSimpleMatch_valueLonger_mismatch", .pattern = "tai", .path = &.{ "head", "value", "tail" }, .want = false },
    .{ .name = "TestSimpleMatch_withAsterisk", .pattern = "t*l", .path = &.{ "value", "vulkano", "tail" }, .want = true },
    .{ .name = "TestSimpleMatch_withQuestionMark", .pattern = "ta?l", .path = &.{ "value", "vulkano", "tail" }, .want = true },
    .{ .name = "TestSimpleMatch_magicChars", .pattern = "v[ou]l[kc]ano", .path = &.{ "value", "volcano" }, .want = true },
    .{ .name = "TestSimpleMatch_wrongPattern_mismatch", .pattern = "v[ou]l[", .path = &.{ "value", "vol[" }, .want = false },
    .{ .name = "TestGlobMatch_fromRootWithSlash", .pattern = "/value/vul?ano/tail", .path = &.{ "value", "vulkano", "tail" }, .want = true },
    .{ .name = "TestGlobMatch_withDomain", .pattern = "middle/tail", .domain = &.{ "value", "volcano" }, .path = &.{ "value", "volcano", "middle", "tail" }, .want = true },
    .{ .name = "TestGlobMatch_onlyMatchInDomain_mismatch", .pattern = "volcano/tail", .domain = &.{ "value", "volcano" }, .path = &.{ "value", "volcano", "tail" }, .want = false },
    .{ .name = "TestGlobMatch_fromRootWithoutSlash", .pattern = "value/vul?ano/tail", .path = &.{ "value", "vulkano", "tail" }, .want = true },
    .{ .name = "TestGlobMatch_fromRoot_mismatch", .pattern = "value/vulkano", .path = &.{ "value", "volcano" }, .want = false },
    .{ .name = "TestGlobMatch_fromRoot_tooShort_mismatch", .pattern = "value/vul?ano", .path = &.{"value"}, .want = false },
    .{ .name = "TestGlobMatch_fromRoot_notAtRoot_mismatch", .pattern = "/value/volcano", .path = &.{ "value", "value", "volcano" }, .want = false },
    .{ .name = "TestGlobMatch_leadingAsterisks_atStart", .pattern = "**/*lue/vol?ano/ta?l", .path = &.{ "value", "volcano", "tail" }, .want = true },
    .{ .name = "TestGlobMatch_leadingAsterisks_notAtStart", .pattern = "**/*lue/vol?ano/tail", .path = &.{ "head", "value", "volcano", "tail" }, .want = true },
    .{ .name = "TestGlobMatch_leadingAsterisks_mismatch", .pattern = "**/*lue/vol?ano/tail", .path = &.{ "head", "value", "Volcano", "tail" }, .want = false },
    .{ .name = "TestGlobMatch_tailingAsterisks", .pattern = "/*lue/vol?ano/**", .path = &.{ "value", "volcano", "tail", "moretail" }, .want = true },
    .{ .name = "TestGlobMatch_tailingAsterisks_single", .pattern = "/*lue/**", .path = &.{ "value", "volcano" }, .want = true },
    .{ .name = "TestGlobMatch_tailingAsterisk_single", .pattern = "/*lue/*", .path = &.{ "value", "volcano", "tail" }, .want = false },
    .{ .name = "TestGlobMatch_tailingAsterisks_exactMatch", .pattern = "/*lue/vol?ano/**", .path = &.{ "value", "volcano" }, .want = false },
    .{ .name = "TestGlobMatch_middleAsterisks_emptyMatch", .pattern = "/*lue/**/vol?ano", .path = &.{ "value", "volcano" }, .want = true },
    .{ .name = "TestGlobMatch_middleAsterisks_oneMatch", .pattern = "/*lue/**/vol?ano", .path = &.{ "value", "middle", "volcano" }, .want = true },
    .{ .name = "TestGlobMatch_middleAsterisks_multiMatch", .pattern = "/*lue/**/vol?ano", .path = &.{ "value", "middle1", "middle2", "volcano" }, .want = true },
    .{ .name = "TestGlobMatch_wrongDoubleAsterisk_mismatch", .pattern = "/*lue/**foo/vol?ano/tail", .path = &.{ "value", "foo", "volcano", "tail" }, .want = false },
    .{ .name = "TestGlobMatch_magicChars", .pattern = "**/head/v[ou]l[kc]ano", .path = &.{ "value", "head", "volcano" }, .want = true },
    .{ .name = "TestGlobMatch_wrongPattern_noTraversal_mismatch", .pattern = "**/head/v[ou]l[", .path = &.{ "value", "head", "vol[" }, .want = false },
    .{ .name = "TestGlobMatch_wrongPattern_onTraversal_mismatch", .pattern = "/value/**/v[ou]l[", .path = &.{ "value", "head", "vol[" }, .want = false },
    .{ .name = "TestGlobMatch_issue_923", .pattern = "**/android/**/GeneratedPluginRegistrant.java", .path = &.{ "packages", "flutter_tools", "lib", "src", "android", "gradle.dart" }, .want = false },
};

test "pattern_test.go all go-git PatternSuite vectors" {
    try testing.expectEqual(@as(usize, 37), go_git_pattern_cases.len);
    for (go_git_pattern_cases) |c| {
        var p = try parsePattern(testing.allocator, c.pattern, c.domain);
        defer p.deinit();
        const got = p.match(c.path);
        if (got != c.want) {
            std.debug.print("FAIL {s}: pattern={s} want={} got={}\n", .{ c.name, c.pattern, c.want, got });
            try testing.expectEqual(c.want, got);
        }
    }
}
