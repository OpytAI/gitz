//! Multi-pattern gitignore matcher — port of go-git `plumbing/format/gitignore/matcher.go`.
//!
//! Reference: go-git v5.19.2.

const std = @import("std");
const pattern_mod = @import("pattern.zig");

const Pattern = pattern_mod.Pattern;

/// Global multi-pattern matcher for gitignore patterns (go-git `Matcher`).
pub const Matcher = struct {
    patterns: []const Pattern,

    /// Match patterns in reverse priority order (go-git `Matcher.Match`).
    ///
    /// Returns true when the path is excluded (go-git: match == Exclude).
    pub fn match(self: Matcher, path: []const []const u8, is_dir: bool) bool {
        var i = self.patterns.len;
        while (i > 0) {
            i -= 1;
            const r = self.patterns[i].match(path, is_dir);
            if (r.isDecisive()) {
                return r == .exclude;
            }
        }
        return false;
    }
};

/// Construct a matcher. Patterns must be in increasing priority order
/// (go-git `NewMatcher`).
pub fn newMatcher(ps: []const Pattern) Matcher {
    return .{ .patterns = ps };
}

// ---------------------------------------------------------------------------
// Tests (go-git matcher_test.go)
// ---------------------------------------------------------------------------

const testing = std.testing;
const parsePattern = pattern_mod.parsePattern;

test "Matcher_Match" {
    // go-git TestMatcher_Match — later include (!volcano) overrides earlier exclude
    const gpa = testing.allocator;
    var p0 = try parsePattern(gpa, "**/middle/v[uo]l?ano", &.{});
    defer p0.deinit();
    var p1 = try parsePattern(gpa, "!volcano", &.{});
    defer p1.deinit();
    const ps = [_]Pattern{ p0, p1 };
    const m = newMatcher(&ps);
    try testing.expect(m.match(&.{ "head", "middle", "vulkano" }, false));
    try testing.expect(!m.match(&.{ "head", "middle", "volcano" }, false));
}

test "Matcher_Match empty patterns never exclude" {
    const m = newMatcher(&.{});
    try testing.expect(!m.match(&.{"any"}, false));
    try testing.expect(!m.match(&.{ "a", "b" }, true));
}
