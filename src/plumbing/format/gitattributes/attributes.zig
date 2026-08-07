//! Gitattributes line parsing — port of go-git `plumbing/format/gitattributes/attributes.go`.
//!
//! Reference: go-git v5.19.2.

const std = @import("std");
const Allocator = std.mem.Allocator;

const pattern_mod = @import("pattern.zig");
const Pattern = pattern_mod.Pattern;
const parsePattern = pattern_mod.parsePattern;

const comment_prefix = "#";
const macro_prefix = "[attr]";

/// go-git `ErrMacroNotAllowed`.
pub const ErrMacroNotAllowed = error{MacroNotAllowed};
/// go-git `ErrInvalidAttributeName`.
pub const ErrInvalidAttributeName = error{InvalidAttributeName};

pub const Error = ErrMacroNotAllowed || ErrInvalidAttributeName || Allocator.Error;

const AttributeState = enum(u8) {
    unknown = 0,
    set = 1,
    unspecified = '!',
    unset = '-',
    set_value = '=',
};

/// One attribute name/state/value (go-git `Attribute` / `attribute`).
pub const Attribute = struct {
    name: []const u8,
    state: AttributeState = .set,
    value: []const u8 = "",

    pub fn isSet(self: Attribute) bool {
        return self.state == .set;
    }
    pub fn isUnset(self: Attribute) bool {
        return self.state == .unset;
    }
    pub fn isUnspecified(self: Attribute) bool {
        return self.state == .unspecified;
    }
    pub fn isValueSet(self: Attribute) bool {
        return self.state == .set_value;
    }
    /// go-git `Attribute.String`.
    pub fn string(self: Attribute, buf: *std.ArrayList(u8), allocator: Allocator) Allocator.Error!void {
        try buf.appendSlice(allocator, self.name);
        try buf.appendSlice(allocator, ": ");
        switch (self.state) {
            .set => try buf.appendSlice(allocator, "set"),
            .unset => try buf.appendSlice(allocator, "unset"),
            .unspecified => try buf.appendSlice(allocator, "unspecified"),
            else => try buf.appendSlice(allocator, self.value),
        }
    }
    /// Convenience format to owned string (tests).
    pub fn formatString(self: Attribute, allocator: Allocator) Allocator.Error![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        try self.string(&list, allocator);
        return try list.toOwnedSlice(allocator);
    }
};

/// One pattern (or macro) with attributes (go-git `MatchAttribute`).
pub const MatchAttribute = struct {
    name: []const u8,
    /// null for macros (go-git `Pattern == nil`).
    pattern: ?Pattern = null,
    attributes: []Attribute,

    pub fn deinit(self: *MatchAttribute, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.pattern) |*p| p.deinit();
        for (self.attributes) |a| {
            allocator.free(a.name);
            if (a.value.len > 0) allocator.free(a.value);
        }
        if (self.attributes.len > 0) allocator.free(self.attributes);
        self.* = undefined;
    }
};

/// Free a slice from `readAttributes` / loaders.
pub fn freeMatchAttributes(allocator: Allocator, list: []MatchAttribute) void {
    for (list) |*m| m.deinit(allocator);
    if (list.len > 0) allocator.free(list);
}

/// Read patterns and attributes from a gitattributes stream (go-git `ReadAttributes`).
pub fn readAttributes(
    allocator: Allocator,
    data: []const u8,
    domain: []const []const u8,
    allow_macro: bool,
) Error![]MatchAttribute {
    var list: std.ArrayList(MatchAttribute) = .empty;
    errdefer {
        for (list.items) |*m| m.deinit(allocator);
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

            const ma = try parseAttributesLine(allocator, line, domain, allow_macro);
            if (ma.name.len == 0) {
                // empty / comment — nothing allocated of interest
                continue;
            }
            try list.append(allocator, ma);
        }
    }
    return try list.toOwnedSlice(allocator);
}

/// Parse one gitattributes line (go-git `ParseAttributesLine`).
pub fn parseAttributesLine(
    allocator: Allocator,
    line_in: []const u8,
    domain: []const []const u8,
    allow_macro: bool,
) Error!MatchAttribute {
    const line = std.mem.trim(u8, line_in, " \t");
    if (line.len == 0 or std.mem.startsWith(u8, line, comment_prefix)) {
        return .{
            .name = "",
            .pattern = null,
            .attributes = &.{},
        };
    }

    var name_buf: []const u8 = undefined;
    var unquoted: []const u8 = undefined;
    const uq = unquote(line);
    if (uq.name.len > 0) {
        name_buf = uq.name;
        unquoted = uq.rest;
    } else {
        name_buf = "";
        unquoted = uq.rest;
    }

    var fields = std.ArrayList([]const u8).empty;
    defer fields.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, unquoted, " \t");
    while (it.next()) |f| {
        if (f.len > 0) try fields.append(allocator, f);
    }

    var name: []const u8 = name_buf;
    var attrs_start: usize = 0;
    if (name.len == 0) {
        if (fields.items.len == 0) {
            return .{ .name = "", .pattern = null, .attributes = &.{} };
        }
        name = fields.items[0];
        attrs_start = 1;
    }

    const macro_check = try checkMacro(name, allow_macro);
    const is_macro = macro_check.macro;
    name = macro_check.macro_name;

    const name_owned = try allocator.dupe(u8, name);
    errdefer allocator.free(name_owned);

    var attrs: std.ArrayList(Attribute) = .empty;
    errdefer {
        for (attrs.items) |a| {
            allocator.free(a.name);
            if (a.value.len > 0) allocator.free(a.value);
        }
        attrs.deinit(allocator);
    }

    const attr_fields = fields.items[attrs_start..];
    for (attr_fields) |attr_name_raw| {
        var attr: Attribute = .{
            .name = attr_name_raw,
            .state = .set,
        };

        if (attr.name.len > 0) {
            // go-git: attributeState(attr.name[0]) for '!' / '-'
            if (attr.name[0] == '!') {
                attr.state = .unspecified;
                attr.name = attr.name[1..];
            } else if (attr.name[0] == '-') {
                attr.state = .unset;
                attr.name = attr.name[1..];
            }
        }

        if (std.mem.indexOfScalar(u8, attr_name_raw, '=')) |eq| {
            attr.name = attr_name_raw[0..eq];
            attr.value = attr_name_raw[eq + 1 ..];
            attr.state = .set_value;
        }

        if (!validAttributeName(attr.name)) return error.InvalidAttributeName;

        const n = try allocator.dupe(u8, attr.name);
        errdefer allocator.free(n);
        const v = if (attr.value.len > 0) try allocator.dupe(u8, attr.value) else "";
        try attrs.append(allocator, .{
            .name = n,
            .state = attr.state,
            .value = v,
        });
    }

    var pattern: ?Pattern = null;
    if (!is_macro) {
        pattern = try parsePattern(allocator, name_owned, domain);
    }

    return .{
        .name = name_owned,
        .pattern = pattern,
        .attributes = try attrs.toOwnedSlice(allocator),
    };
}

const MacroCheck = struct {
    macro: bool,
    macro_name: []const u8,
};

fn checkMacro(name: []const u8, allow_macro: bool) Error!MacroCheck {
    if (!std.mem.startsWith(u8, name, macro_prefix)) {
        return .{ .macro = false, .macro_name = name };
    }
    if (!allow_macro) return error.MacroNotAllowed;
    const macro_name = name[macro_prefix.len..];
    if (!validAttributeName(macro_name)) return error.InvalidAttributeName;
    return .{ .macro = true, .macro_name = macro_name };
}

fn validAttributeName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '-') return false;
    for (name) |ch| {
        const ok = ch == '-' or ch == '.' or ch == '_' or
            (ch >= '0' and ch <= '9') or
            (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z');
        if (!ok) return false;
    }
    return true;
}

const UnquoteResult = struct {
    name: []const u8,
    rest: []const u8,
};

fn unquote(str: []const u8) UnquoteResult {
    if (str.len == 0 or str[0] != '"') return .{ .name = "", .rest = str };
    var i: usize = 1;
    while (i < str.len) : (i += 1) {
        switch (str[i]) {
            '\\' => i += 1,
            '"' => return .{ .name = str[1..i], .rest = str[i + 1 ..] },
            else => {},
        }
    }
    return .{ .name = "", .rest = str };
}

// ---------------------------------------------------------------------------
// Tests (go-git attributes_test.go)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Attributes_ReadAttributes" {
    // go-git TestAttributes_ReadAttributes — macros + multi-attr line
    const gpa = testing.allocator;
    const text =
        \\[attr]sub -a
        \\[attr]add a
        \\* sub a
        \\* !a foo=bar -b c
    ;
    const mas = try readAttributes(gpa, text, &.{}, true);
    defer freeMatchAttributes(gpa, mas);
    try testing.expectEqual(@as(usize, 4), mas.len);

    // MatchAttribute[0]: macro "sub" → -a (pattern nil)
    try testing.expectEqualStrings("sub", mas[0].name);
    try testing.expect(mas[0].pattern == null);
    try testing.expectEqual(@as(usize, 1), mas[0].attributes.len);
    try testing.expectEqualStrings("a", mas[0].attributes[0].name);
    try testing.expect(mas[0].attributes[0].isUnset());

    // MatchAttribute[1]: macro "add" → a set
    try testing.expectEqualStrings("add", mas[1].name);
    try testing.expect(mas[1].pattern == null);
    try testing.expectEqual(@as(usize, 1), mas[1].attributes.len);
    try testing.expect(mas[1].attributes[0].isSet());

    // MatchAttribute[2]: pattern "*" with attrs sub, a
    try testing.expectEqualStrings("*", mas[2].name);
    try testing.expect(mas[2].pattern != null);
    try testing.expectEqual(@as(usize, 2), mas[2].attributes.len);
    try testing.expectEqualStrings("sub", mas[2].attributes[0].name);
    try testing.expect(mas[2].attributes[0].isSet());
    try testing.expectEqualStrings("a", mas[2].attributes[1].name);
    try testing.expect(mas[2].attributes[1].isSet());

    // MatchAttribute[3]: multi-attr !a foo=bar -b c
    try testing.expectEqualStrings("*", mas[3].name);
    try testing.expect(mas[3].pattern != null);
    try testing.expectEqual(@as(usize, 4), mas[3].attributes.len);
    try testing.expect(mas[3].attributes[0].isUnspecified());
    try testing.expectEqualStrings("a", mas[3].attributes[0].name);
    try testing.expect(mas[3].attributes[1].isValueSet());
    try testing.expectEqualStrings("foo", mas[3].attributes[1].name);
    try testing.expectEqualStrings("bar", mas[3].attributes[1].value);
    try testing.expect(mas[3].attributes[2].isUnset());
    try testing.expectEqualStrings("b", mas[3].attributes[2].name);
    try testing.expect(mas[3].attributes[3].isSet());
    try testing.expectEqualStrings("c", mas[3].attributes[3].name);

    // Attribute.String() forms from go-git
    const s0 = try mas[3].attributes[0].formatString(gpa);
    defer gpa.free(s0);
    try testing.expectEqualStrings("a: unspecified", s0);
    const s1 = try mas[3].attributes[1].formatString(gpa);
    defer gpa.free(s1);
    try testing.expectEqualStrings("foo: bar", s1);
    const s2 = try mas[3].attributes[2].formatString(gpa);
    defer gpa.free(s2);
    try testing.expectEqualStrings("b: unset", s2);
    const s3 = try mas[3].attributes[3].formatString(gpa);
    defer gpa.free(s3);
    try testing.expectEqualStrings("c: set", s3);
}

test "Attributes_ReadAttributesDisallowMacro" {
    // go-git TestAttributes_ReadAttributesDisallowMacro
    const gpa = testing.allocator;
    const text =
        \\[attr]sub -a
        \\* a add
    ;
    try testing.expectError(error.MacroNotAllowed, readAttributes(gpa, text, &.{}, false));
}

test "Attributes_ReadAttributesInvalidName" {
    // go-git TestAttributes_ReadAttributesInvalidName
    const gpa = testing.allocator;
    const text = "[attr]foo!bar -a\n";
    try testing.expectError(error.InvalidAttributeName, readAttributes(gpa, text, &.{}, true));
}

test "ParseAttributesLine multi-attr and comment skip" {
    // Edge cases exercised by ReadAttributes fixtures but not separate go-git methods.
    const gpa = testing.allocator;

    // Empty / comment → empty name (skipped by ReadAttributes)
    {
        const empty = try parseAttributesLine(gpa, "", &.{}, true);
        try testing.expectEqual(@as(usize, 0), empty.name.len);
        const comment = try parseAttributesLine(gpa, "# IntelliJ", &.{}, true);
        try testing.expectEqual(@as(usize, 0), comment.name.len);
    }

    // Multi-attr line with value + unset + set
    {
        var ma = try parseAttributesLine(gpa, "*.iml -text eol=lf custom", &.{}, true);
        defer ma.deinit(gpa);
        try testing.expectEqualStrings("*.iml", ma.name);
        try testing.expect(ma.pattern != null);
        try testing.expectEqual(@as(usize, 3), ma.attributes.len);
        try testing.expect(ma.attributes[0].isUnset());
        try testing.expectEqualStrings("text", ma.attributes[0].name);
        try testing.expect(ma.attributes[1].isValueSet());
        try testing.expectEqualStrings("eol", ma.attributes[1].name);
        try testing.expectEqualStrings("lf", ma.attributes[1].value);
        try testing.expect(ma.attributes[2].isSet());
        try testing.expectEqualStrings("custom", ma.attributes[2].name);
    }

    // Macro line
    {
        var ma = try parseAttributesLine(gpa, "[attr]binary -diff -merge -text", &.{}, true);
        defer ma.deinit(gpa);
        try testing.expectEqualStrings("binary", ma.name);
        try testing.expect(ma.pattern == null);
        try testing.expectEqual(@as(usize, 3), ma.attributes.len);
        try testing.expect(ma.attributes[0].isUnset());
        try testing.expectEqualStrings("diff", ma.attributes[0].name);
        try testing.expect(ma.attributes[1].isUnset());
        try testing.expect(ma.attributes[2].isUnset());
    }
}

test "ReadAttributes skips blank and comment lines" {
    const gpa = testing.allocator;
    const text =
        \\# header
        \\
        \\*.o -text
        \\
        \\# trailing
    ;
    const mas = try readAttributes(gpa, text, &.{}, true);
    defer freeMatchAttributes(gpa, mas);
    try testing.expectEqual(@as(usize, 1), mas.len);
    try testing.expectEqualStrings("*.o", mas[0].name);
    try testing.expect(mas[0].attributes[0].isUnset());
}
