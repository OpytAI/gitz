//! Full-path glob match (go-git `plumbing/format/index/match.go`).
//!
//! `filepath.Match` algorithm with support for matching full paths, not only
//! file names. Source lineage: Go stdlib
//! `path/filepath/match.go` (commit 39852bf4). go-git drops the “cannot skip
//! `/`” restriction so `*` can span path separators.

const std = @import("std");
const builtin = @import("builtin");
const err_mod = @import("error.zig");

const Error = err_mod.Error;

/// True when running as Windows (backslash is not an escape, matching go-git).
const is_windows = builtin.os.tag == .windows;

/// Match `name` against `pattern` (go-git unexported `match`).
///
/// Pattern syntax is the same as `filepath.Match` / `filepath.Glob`.
pub fn match(pattern_in: []const u8, name_in: []const u8) Error!bool {
    var pattern = pattern_in;
    var name = name_in;

    while (pattern.len > 0) {
        const scanned = scanChunk(pattern);
        const star = scanned.star;
        const chunk = scanned.chunk;
        pattern = scanned.rest;

        // Look for match at current position.
        const t_ok = try matchChunk(chunk, name);
        // if we're the last chunk, make sure we've exhausted the name
        // otherwise we'll give a false result even if we could still match
        // using the star
        if (t_ok.ok and (t_ok.rest.len == 0 or pattern.len > 0)) {
            name = t_ok.rest;
            continue;
        }
        if (star) {
            // Look for match skipping i+1 bytes.
            // go-git comment says “Cannot skip /” but the loop does not enforce
            // that (full-path match intentionally spans separators).
            var i: usize = 0;
            while (i < name.len) : (i += 1) {
                const t2 = try matchChunk(chunk, name[i + 1 ..]);
                if (t2.ok) {
                    // if we're the last chunk, make sure we exhausted the name
                    if (pattern.len == 0 and t2.rest.len > 0) {
                        continue;
                    }
                    name = t2.rest;
                    // continue Pattern
                    break;
                }
            } else {
                // for exhausted without break → no star match
                return false;
            }
            // broke out of while → continue Pattern
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

/// Next segment of pattern: non-star string, optionally preceded by a star.
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
                    // error check handled in matchChunk: bad pattern.
                    if (i + 1 < pattern.len) {
                        i += 1;
                    }
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

/// Whether `chunk` matches the beginning of `s`.
/// On success, returns the remainder of `s` after the match.
fn matchChunk(chunk_in: []const u8, s_in: []const u8) Error!MatchChunkResult {
    var chunk = chunk_in;
    var s = s_in;

    while (chunk.len > 0) {
        if (s.len == 0) {
            return .{ .rest = s, .ok = false };
        }
        switch (chunk[0]) {
            '[' => {
                // character class
                const dr = decodeRune(s);
                s = s[dr.n..];
                chunk = chunk[1..];
                // We can't end right after '[', we're expecting at least
                // a closing bracket and possibly a caret.
                if (chunk.len == 0) return Error.BadPattern;
                // possibly negated
                var negated = false;
                if (chunk[0] == '^') {
                    negated = true;
                    chunk = chunk[1..];
                }
                // parse all ranges
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
                    if (chunk[0] == '-') {
                        const hi_esc = try getEsc(chunk[1..]);
                        hi = hi_esc.r;
                        chunk = hi_esc.nchunk;
                    }
                    if (lo <= dr.r and dr.r <= hi) {
                        matched = true;
                    }
                    nrange += 1;
                }
                if (matched == negated) {
                    return .{ .rest = s, .ok = false };
                }
            },
            '?' => {
                const dr = decodeRune(s);
                s = s[dr.n..];
                chunk = chunk[1..];
            },
            '\\' => {
                if (!is_windows) {
                    chunk = chunk[1..];
                    if (chunk.len == 0) return Error.BadPattern;
                }
                // fallthrough default
                if (chunk[0] != s[0]) {
                    return .{ .rest = s, .ok = false };
                }
                s = s[1..];
                chunk = chunk[1..];
            },
            else => {
                if (chunk[0] != s[0]) {
                    return .{ .rest = s, .ok = false };
                }
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

/// Possibly-escaped character from chunk (character class).
fn getEsc(chunk_in: []const u8) Error!EscResult {
    var chunk = chunk_in;
    if (chunk.len == 0 or chunk[0] == '-' or chunk[0] == ']') {
        return Error.BadPattern;
    }
    if (chunk[0] == '\\' and !is_windows) {
        chunk = chunk[1..];
        if (chunk.len == 0) return Error.BadPattern;
    }
    const dr = decodeRune(chunk);
    if (dr.r == 0xFFFD and dr.n == 1) {
        // utf8.RuneError && n == 1
        return Error.BadPattern;
    }
    const nchunk = chunk[dr.n..];
    if (nchunk.len == 0) return Error.BadPattern;
    return .{ .r = dr.r, .nchunk = nchunk };
}

const DecodedRune = struct {
    r: u21,
    n: usize,
};

/// Decode one UTF-8 rune; invalid sequences yield U+FFFD with n=1 (Go behaviour).
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
// Tests (support Glob cases from index_test.go)
// ---------------------------------------------------------------------------

test "match simple and star" {
    try std.testing.expect(try match("foo", "foo"));
    try std.testing.expect(!try match("foo", "bar"));
    try std.testing.expect(try match("f*", "foo"));
    try std.testing.expect(try match("foo/b*", "foo/bar/bar"));
    try std.testing.expect(try match("foo/b*", "foo/baz/qux"));
    try std.testing.expect(!try match("foo/b*", "fux"));
    try std.testing.expect(try match("f*/baz/q*", "foo/baz/qux"));
    try std.testing.expect(!try match("f*/baz/q*", "foo/bar/bar"));
}

test "match question and class" {
    try std.testing.expect(try match("f?o", "foo"));
    try std.testing.expect(!try match("f?o", "fooo"));
    try std.testing.expect(try match("[fb]oo", "foo"));
    try std.testing.expect(try match("[a-z]oo", "foo"));
    try std.testing.expect(!try match("[^f]oo", "foo"));
    try std.testing.expect(try match("[^b]oo", "foo"));
}
