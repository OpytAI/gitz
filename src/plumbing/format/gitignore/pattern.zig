//! Single gitignore pattern — port of go-git `plumbing/format/gitignore/pattern.go`.
//!
//! Reference: go-git v5.19.2.

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const inclusion_prefix = "!";
const zero_to_many_dirs = "**";
const pattern_dir_sep = "/";

const is_windows = builtin.os.tag == .windows;

/// Outcomes of a match: no match, exclusion, or inclusion (go-git `MatchResult`).
pub const MatchResult = enum(u8) {
    /// No match (go-git `NoMatch`).
    no_match = 0,
    /// Exclusion (go-git `Exclude`).
    exclude = 1,
    /// Explicit inclusion / negation (go-git `Include`).
    include = 2,

    /// go-git numeric compare: match > NoMatch.
    pub fn isDecisive(self: MatchResult) bool {
        return self != .no_match;
    }
};

/// A single gitignore pattern (go-git `Pattern` / `pattern`).
pub const Pattern = struct {
    allocator: Allocator,
    domain: [][]const u8,
    pattern: [][]const u8,
    inclusion: bool = false,
    dir_only: bool = false,
    is_glob: bool = false,

    pub fn deinit(self: *Pattern) void {
        for (self.domain) |s| self.allocator.free(s);
        self.allocator.free(self.domain);
        for (self.pattern) |s| self.allocator.free(s);
        self.allocator.free(self.pattern);
        self.* = undefined;
    }

    /// Match `path` segments against this pattern (go-git `Pattern.Match`).
    pub fn match(self: *const Pattern, path: []const []const u8, is_dir: bool) MatchResult {
        if (path.len <= self.domain.len) return .no_match;
        for (self.domain, 0..) |e, i| {
            if (!std.mem.eql(u8, path[i], e)) return .no_match;
        }

        const rest = path[self.domain.len..];
        if (self.is_glob) {
            if (!self.globMatch(rest, is_dir)) return .no_match;
        } else {
            if (!self.simpleNameMatch(rest, is_dir)) return .no_match;
        }

        return if (self.inclusion) .include else .exclude;
    }

    fn simpleNameMatch(self: *const Pattern, path: []const []const u8, is_dir: bool) bool {
        if (self.pattern.len == 0) return false;
        const pat = self.pattern[0];
        for (path, 0..) |name, i| {
            if (!filePathMatch(pat, name)) continue;
            if (self.dir_only and !is_dir and i == path.len - 1) return false;
            return true;
        }
        return false;
    }

    fn globMatch(self: *const Pattern, path_in: []const []const u8, is_dir: bool) bool {
        var path = path_in;
        var matched = false;
        var can_traverse = false;

        for (self.pattern, 0..) |pat, i| {
            if (pat.len == 0) {
                can_traverse = false;
                continue;
            }
            if (std.mem.eql(u8, pat, zero_to_many_dirs)) {
                if (i == self.pattern.len - 1) break;
                can_traverse = true;
                continue;
            }
            if (std.mem.indexOf(u8, pat, zero_to_many_dirs) != null) return false;
            if (path.len == 0) return false;

            if (can_traverse) {
                can_traverse = false;
                while (path.len > 0) {
                    const e = path[0];
                    path = path[1..];
                    if (filePathMatch(pat, e)) {
                        matched = true;
                        break;
                    } else if (path.len == 0) {
                        matched = false;
                    }
                }
            } else {
                if (!filePathMatch(pat, path[0])) return false;
                matched = true;
                path = path[1..];
            }
        }
        if (matched and self.dir_only and !is_dir and path.len == 0) {
            matched = false;
        }
        return matched;
    }
};

/// Parse a gitignore pattern string (go-git `ParsePattern`).
///
/// Copies `domain` and pattern segments; caller must `deinit` the result.
pub fn parsePattern(allocator: Allocator, p_in: []const u8, domain: []const []const u8) Allocator.Error!Pattern {
    const domain_owned = try copyStringSlice(allocator, domain);
    errdefer freeStringSlice(allocator, domain_owned);

    var p = p_in;
    var inclusion = false;
    var dir_only = false;
    var is_glob = false;

    if (std.mem.startsWith(u8, p, inclusion_prefix)) {
        inclusion = true;
        p = p[1..];
    }

    // Trailing spaces ignored unless quoted with backslash ("\ ").
    if (!std.mem.endsWith(u8, p, "\\ ")) {
        p = std.mem.trimEnd(u8, p, " ");
    }

    if (std.mem.endsWith(u8, p, pattern_dir_sep)) {
        dir_only = true;
        p = p[0 .. p.len - 1];
    }

    if (std.mem.indexOf(u8, p, pattern_dir_sep) != null) {
        is_glob = true;
    }

    const pattern_owned = try splitOwned(allocator, p, '/');
    errdefer freeStringSlice(allocator, pattern_owned);

    return .{
        .allocator = allocator,
        .domain = domain_owned,
        .pattern = pattern_owned,
        .inclusion = inclusion,
        .dir_only = dir_only,
        .is_glob = is_glob,
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

// ---------------------------------------------------------------------------
// filepath.Match subset (Go path/filepath Match on a single name).
// Bad pattern → false (go-git ignores filepath.Match errors).
// ---------------------------------------------------------------------------

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
            // Cannot skip '/': name is a single path segment (no '/').
            var i: usize = 0;
            while (i < name.len) : (i += 1) {
                if (name[i] == '/') return false;
                const t2 = try matchChunk(chunk, name[i + 1 ..]);
                if (t2.ok) {
                    if (pattern.len == 0 and t2.rest.len > 0) continue;
                    // remainder must not reintroduce '/'
                    if (std.mem.indexOfScalar(u8, t2.rest, '/') != null) continue;
                    name = t2.rest;
                    break;
                }
            } else {
                return false;
            }
            continue;
        }
        return false;
    }
    return name.len == 0;
}

const ScanResult = struct {
    star: bool,
    chunk: []const u8,
    rest: []const u8,
};

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
                if (!is_windows) {
                    if (i + 1 < pattern.len) i += 1;
                }
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

const MatchChunkResult = struct {
    rest: []const u8,
    ok: bool,
};

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

const EscResult = struct {
    r: u21,
    nchunk: []const u8,
};

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

const DecodedRune = struct {
    r: u21,
    n: usize,
};

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
    is_dir: bool = false,
    want: MatchResult,
};

// Full vector table from go-git plumbing/format/gitignore/pattern_test.go.
const go_git_pattern_cases = [_]Case{
    .{ .name = "TestSimpleMatch_inclusion", .pattern = "!vul?ano", .path = &.{ "value", "vulkano", "tail" }, .want = .include },
    .{ .name = "TestMatch_domainLonger_mismatch", .pattern = "value", .domain = &.{ "head", "middle", "tail" }, .path = &.{ "head", "middle" }, .want = .no_match },
    .{ .name = "TestMatch_domainSameLength_mismatch", .pattern = "value", .domain = &.{ "head", "middle", "tail" }, .path = &.{ "head", "middle", "tail" }, .want = .no_match },
    .{ .name = "TestMatch_domainMismatch_mismatch", .pattern = "value", .domain = &.{ "head", "middle", "tail" }, .path = &.{ "head", "middle", "_tail_", "value" }, .want = .no_match },
    .{ .name = "TestSimpleMatch_withDomain", .pattern = "middle/", .domain = &.{ "value", "volcano" }, .path = &.{ "value", "volcano", "middle", "tail" }, .want = .exclude },
    .{ .name = "TestSimpleMatch_onlyMatchInDomain_mismatch", .pattern = "volcano/", .domain = &.{ "value", "volcano" }, .path = &.{ "value", "volcano", "tail" }, .is_dir = true, .want = .no_match },
    .{ .name = "TestSimpleMatch_atStart", .pattern = "value", .path = &.{ "value", "tail" }, .want = .exclude },
    .{ .name = "TestSimpleMatch_inTheMiddle", .pattern = "value", .path = &.{ "head", "value", "tail" }, .want = .exclude },
    .{ .name = "TestSimpleMatch_atEnd", .pattern = "value", .path = &.{ "head", "value" }, .want = .exclude },
    .{ .name = "TestSimpleMatch_atStart_dirWanted", .pattern = "value/", .path = &.{ "value", "tail" }, .want = .exclude },
    .{ .name = "TestSimpleMatch_inTheMiddle_dirWanted", .pattern = "value/", .path = &.{ "head", "value", "tail" }, .want = .exclude },
    .{ .name = "TestSimpleMatch_atEnd_dirWanted", .pattern = "value/", .path = &.{ "head", "value" }, .is_dir = true, .want = .exclude },
    .{ .name = "TestSimpleMatch_atEnd_dirWanted_notADir_mismatch", .pattern = "value/", .path = &.{ "head", "value" }, .want = .no_match },
    .{ .name = "TestSimpleMatch_mismatch", .pattern = "value", .path = &.{ "head", "val", "tail" }, .want = .no_match },
    .{ .name = "TestSimpleMatch_valueLonger_mismatch", .pattern = "val", .path = &.{ "head", "value", "tail" }, .want = .no_match },
    .{ .name = "TestSimpleMatch_withAsterisk", .pattern = "v*o", .path = &.{ "value", "vulkano", "tail" }, .want = .exclude },
    .{ .name = "TestSimpleMatch_withQuestionMark", .pattern = "vul?ano", .path = &.{ "value", "vulkano", "tail" }, .want = .exclude },
    .{ .name = "TestSimpleMatch_magicChars", .pattern = "v[ou]l[kc]ano", .path = &.{ "value", "volcano" }, .want = .exclude },
    .{ .name = "TestSimpleMatch_wrongPattern_mismatch", .pattern = "v[ou]l[", .path = &.{ "value", "vol[" }, .want = .no_match },
    .{ .name = "TestGlobMatch_fromRootWithSlash", .pattern = "/value/vul?ano", .path = &.{ "value", "vulkano", "tail" }, .want = .exclude },
    .{ .name = "TestGlobMatch_withDomain", .pattern = "middle/tail/", .domain = &.{ "value", "volcano" }, .path = &.{ "value", "volcano", "middle", "tail" }, .is_dir = true, .want = .exclude },
    .{ .name = "TestGlobMatch_onlyMatchInDomain_mismatch", .pattern = "volcano/tail", .domain = &.{ "value", "volcano" }, .path = &.{ "value", "volcano", "tail" }, .want = .no_match },
    .{ .name = "TestGlobMatch_fromRootWithoutSlash", .pattern = "value/vul?ano", .path = &.{ "value", "vulkano", "tail" }, .want = .exclude },
    .{ .name = "TestGlobMatch_fromRoot_mismatch", .pattern = "value/vulkano", .path = &.{ "value", "volcano" }, .want = .no_match },
    .{ .name = "TestGlobMatch_fromRoot_tooShort_mismatch", .pattern = "value/vul?ano", .path = &.{"value"}, .want = .no_match },
    .{ .name = "TestGlobMatch_fromRoot_notAtRoot_mismatch", .pattern = "/value/volcano", .path = &.{ "value", "value", "volcano" }, .want = .no_match },
    .{ .name = "TestGlobMatch_leadingAsterisks_atStart", .pattern = "**/*lue/vol?ano", .path = &.{ "value", "volcano", "tail" }, .want = .exclude },
    .{ .name = "TestGlobMatch_leadingAsterisks_notAtStart", .pattern = "**/*lue/vol?ano", .path = &.{ "head", "value", "volcano", "tail" }, .want = .exclude },
    .{ .name = "TestGlobMatch_leadingAsterisks_mismatch", .pattern = "**/*lue/vol?ano", .path = &.{ "head", "value", "Volcano", "tail" }, .want = .no_match },
    .{ .name = "TestGlobMatch_leadingAsterisks_isDir", .pattern = "**/*lue/vol?ano/", .path = &.{ "head", "value", "volcano", "tail" }, .want = .exclude },
    .{ .name = "TestGlobMatch_leadingAsterisks_isDirAtEnd", .pattern = "**/*lue/vol?ano/", .path = &.{ "head", "value", "volcano" }, .is_dir = true, .want = .exclude },
    .{ .name = "TestGlobMatch_leadingAsterisks_isDir_mismatch", .pattern = "**/*lue/vol?ano/", .path = &.{ "head", "value", "Colcano" }, .is_dir = true, .want = .no_match },
    .{ .name = "TestGlobMatch_leadingAsterisks_isDirNoDirAtEnd_mismatch", .pattern = "**/*lue/vol?ano/", .path = &.{ "head", "value", "volcano" }, .want = .no_match },
    .{ .name = "TestGlobMatch_tailingAsterisks", .pattern = "/*lue/vol?ano/**", .path = &.{ "value", "volcano", "tail", "moretail" }, .want = .exclude },
    .{ .name = "TestGlobMatch_tailingAsterisks_exactMatch", .pattern = "/*lue/vol?ano/**", .path = &.{ "value", "volcano" }, .want = .exclude },
    .{ .name = "TestGlobMatch_middleAsterisks_emptyMatch", .pattern = "/*lue/**/vol?ano", .path = &.{ "value", "volcano" }, .want = .exclude },
    .{ .name = "TestGlobMatch_middleAsterisks_oneMatch", .pattern = "/*lue/**/vol?ano", .path = &.{ "value", "middle", "volcano" }, .want = .exclude },
    .{ .name = "TestGlobMatch_middleAsterisks_multiMatch", .pattern = "/*lue/**/vol?ano", .path = &.{ "value", "middle1", "middle2", "volcano" }, .want = .exclude },
    .{ .name = "TestGlobMatch_middleAsterisks_isDir_trailing", .pattern = "/*lue/**/vol?ano/", .path = &.{ "value", "middle1", "middle2", "volcano" }, .is_dir = true, .want = .exclude },
    .{ .name = "TestGlobMatch_middleAsterisks_isDir_trailing_mismatch", .pattern = "/*lue/**/vol?ano/", .path = &.{ "value", "middle1", "middle2", "volcano" }, .want = .no_match },
    .{ .name = "TestGlobMatch_middleAsterisks_isDir", .pattern = "/*lue/**/vol?ano/", .path = &.{ "value", "middle1", "middle2", "volcano", "tail" }, .want = .exclude },
    .{ .name = "TestGlobMatch_wrongDoubleAsterisk_mismatch", .pattern = "/*lue/**foo/vol?ano", .path = &.{ "value", "foo", "volcano", "tail" }, .want = .no_match },
    .{ .name = "TestGlobMatch_magicChars", .pattern = "**/head/v[ou]l[kc]ano", .path = &.{ "value", "head", "volcano" }, .want = .exclude },
    .{ .name = "TestGlobMatch_wrongPattern_noTraversal_mismatch", .pattern = "**/head/v[ou]l[", .path = &.{ "value", "head", "vol[" }, .want = .no_match },
    .{ .name = "TestGlobMatch_wrongPattern_onTraversal_mismatch", .pattern = "/value/**/v[ou]l[", .path = &.{ "value", "head", "vol[" }, .want = .no_match },
    .{ .name = "TestGlobMatch_issue_923", .pattern = "**/android/**/GeneratedPluginRegistrant.java", .path = &.{ "packages", "flutter_tools", "lib", "src", "android", "gradle.dart" }, .want = .no_match },
};

test "pattern_test.go all go-git PatternSuite vectors" {
    try testing.expectEqual(@as(usize, 46), go_git_pattern_cases.len);
    for (go_git_pattern_cases) |c| {
        var p = try parsePattern(testing.allocator, c.pattern, c.domain);
        defer p.deinit();
        const got = p.match(c.path, c.is_dir);
        if (got != c.want) {
            std.debug.print("FAIL {s}: pattern={s} want={} got={}\n", .{ c.name, c.pattern, c.want, got });
            try testing.expectEqual(c.want, got);
        }
    }
}
