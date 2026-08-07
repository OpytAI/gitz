//! Multi-pattern gitattributes matcher — port of go-git `matcher.go`.
//!
//! Reference: go-git v5.19.2.

const std = @import("std");
const Allocator = std.mem.Allocator;

const attributes_mod = @import("attributes.zig");
const MatchAttribute = attributes_mod.MatchAttribute;
const Attribute = attributes_mod.Attribute;

/// Options placeholder (go-git `MatcherOptions` — empty in v5.19.2).
pub const MatcherOptions = struct {};

/// Global multi-pattern matcher (go-git `Matcher` / `matcher`).
pub const Matcher = struct {
    stack: []const MatchAttribute,
    macros: std.StringHashMapUnmanaged(MatchAttribute) = .empty,
    /// Allocator that owns `macros` keys/map (not stack).
    allocator: Allocator,

    pub fn deinit(self: *Matcher) void {
        // macros map holds pointers into stack; only free the map structure.
        self.macros.deinit(self.allocator);
        self.* = undefined;
    }

    /// Match path against stack (go-git `Matcher.Match`).
    ///
    /// `results` maps attribute name → Attribute (borrowed from stack lifetime).
    /// Caller owns the map and must `deinit` it; keys/values are not owned.
    pub fn match(
        self: *const Matcher,
        allocator: Allocator,
        path: []const []const u8,
        attributes: []const []const u8,
    ) Allocator.Error!struct { results: std.StringHashMapUnmanaged(Attribute), matched: bool } {
        var results: std.StringHashMapUnmanaged(Attribute) = .empty;
        errdefer results.deinit(allocator);

        var matched = false;
        var i = self.stack.len;
        while (i > 0) {
            i -= 1;
            if (attributes.len > 0 and results.count() == attributes.len) {
                return .{ .results = results, .matched = matched };
            }

            const entry = self.stack[i];
            const pattern = entry.pattern orelse continue;
            if (!pattern.match(path)) continue;

            matched = true;
            for (entry.attributes) |attr| {
                if (attr.isSet()) {
                    try self.expandMacro(attr.name, &results, allocator);
                }
                try results.put(allocator, attr.name, attr);
            }
        }
        return .{ .results = results, .matched = matched };
    }

    fn expandMacro(
        self: *const Matcher,
        name: []const u8,
        results: *std.StringHashMapUnmanaged(Attribute),
        allocator: Allocator,
    ) Allocator.Error!void {
        if (self.macros.get(name)) |macro| {
            for (macro.attributes) |attr| {
                try results.put(allocator, attr.name, attr);
            }
        }
    }

    fn initMacros(self: *Matcher) Allocator.Error!void {
        for (self.stack) |attr| {
            if (attr.pattern == null) {
                try self.macros.put(self.allocator, attr.name, attr);
            }
        }
    }
};

/// Construct a matcher (go-git `NewMatcher`). Patterns must be ascending priority.
///
/// `stack` is borrowed for the lifetime of the matcher.
pub fn newMatcher(allocator: Allocator, stack: []const MatchAttribute) Allocator.Error!Matcher {
    var m: Matcher = .{
        .stack = stack,
        .allocator = allocator,
    };
    try m.initMacros();
    return m;
}

// ---------------------------------------------------------------------------
// Tests (go-git matcher_test.go)
// ---------------------------------------------------------------------------

const testing = std.testing;
const readAttributes = attributes_mod.readAttributes;
const freeMatchAttributes = attributes_mod.freeMatchAttributes;

// Fixture lines from go-git TestMatcher_Match (matcher_test.go).
const matcher_fixture =
    \\[attr]binary -diff -merge -text
    \\**/middle/v[uo]l?ano binary text eol=crlf
    \\volcano -eol
    \\foobar diff merge text eol=lf foo=bar
;

test "Matcher_Match" {
    // go-git TestMatcher_Match — macro expand + multi-attr on matching path
    const gpa = testing.allocator;
    const ma = try readAttributes(gpa, matcher_fixture, &.{}, true);
    defer freeMatchAttributes(gpa, ma);

    var m = try newMatcher(gpa, ma);
    defer m.deinit();

    var out = try m.match(gpa, &.{ "head", "middle", "vulkano" }, &.{});
    defer out.results.deinit(gpa);

    try testing.expect(out.matched);
    try testing.expect(out.results.get("binary").?.isSet());
    try testing.expect(out.results.get("diff").?.isUnset());
    try testing.expect(out.results.get("merge").?.isUnset());
    try testing.expect(out.results.get("text").?.isSet());
    try testing.expectEqualStrings("crlf", out.results.get("eol").?.value);
}

test "Matcher_Match non-matching path" {
    // Same fixture: path that hits no pattern → matched false, empty results.
    const gpa = testing.allocator;
    const ma = try readAttributes(gpa, matcher_fixture, &.{}, true);
    defer freeMatchAttributes(gpa, ma);

    var m = try newMatcher(gpa, ma);
    defer m.deinit();

    var out = try m.match(gpa, &.{ "head", "other", "file" }, &.{});
    defer out.results.deinit(gpa);
    try testing.expect(!out.matched);
    try testing.expectEqual(@as(usize, 0), out.results.count());
}

test "Matcher_Match simple name multi-attr" {
    // Fixture lines "volcano -eol" and "foobar …" (present in go-git matcher fixture).
    const gpa = testing.allocator;
    const ma = try readAttributes(gpa, matcher_fixture, &.{}, true);
    defer freeMatchAttributes(gpa, ma);

    var m = try newMatcher(gpa, ma);
    defer m.deinit();

    {
        var out = try m.match(gpa, &.{"volcano"}, &.{});
        defer out.results.deinit(gpa);
        try testing.expect(out.matched);
        try testing.expect(out.results.get("eol").?.isUnset());
    }
    {
        var out = try m.match(gpa, &.{"foobar"}, &.{});
        defer out.results.deinit(gpa);
        try testing.expect(out.matched);
        try testing.expect(out.results.get("diff").?.isSet());
        try testing.expect(out.results.get("merge").?.isSet());
        try testing.expect(out.results.get("text").?.isSet());
        try testing.expectEqualStrings("lf", out.results.get("eol").?.value);
        try testing.expectEqualStrings("bar", out.results.get("foo").?.value);
    }
}
