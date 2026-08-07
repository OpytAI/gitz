//! OptBool tri-state and git-style bool parsing.
//!
//! Port of go-git v5.19.2 `config/optbool.go`.

const std = @import("std");

/// Tri-state boolean: unset, explicitly false, or explicitly true (go-git `OptBool`).
pub const OptBool = enum(u8) {
    /// Setting was not specified (go-git `OptBoolUnset`).
    unset = 0,
    /// Explicitly false (go-git `OptBoolFalse`).
    set_false = 1,
    /// Explicitly true (go-git `OptBoolTrue`).
    set_true = 2,

    /// go-git `NewOptBool`.
    pub fn fromBool(v: bool) OptBool {
        return if (v) .set_true else .set_false;
    }

    /// go-git `IsTrue`.
    pub fn isTrue(self: OptBool) bool {
        return self == .set_true;
    }

    /// go-git `IsSet`.
    pub fn isSet(self: OptBool) bool {
        return self != .unset;
    }

    pub fn string(self: OptBool) []const u8 {
        return switch (self) {
            .set_true => "true",
            .set_false => "false",
            .unset => "unset",
        };
    }

    /// go-git `FormatBool` — only meaningful when `isSet`.
    pub fn formatBool(self: OptBool) []const u8 {
        return if (self.isTrue()) "true" else "false";
    }
};

/// Parse git-style bool text (go-git `parseConfigBool`).
///
/// Accepts true/yes/on and false/no/off case-insensitively, plus any decimal
/// integer (0 → false, non-zero → true). Empty or unrecognised → unset.
pub fn parseConfigBool(v: []const u8) OptBool {
    if (std.ascii.eqlIgnoreCase(v, "true") or
        std.ascii.eqlIgnoreCase(v, "yes") or
        std.ascii.eqlIgnoreCase(v, "on"))
    {
        return .set_true;
    }
    if (std.ascii.eqlIgnoreCase(v, "false") or
        std.ascii.eqlIgnoreCase(v, "no") or
        std.ascii.eqlIgnoreCase(v, "off"))
    {
        return .set_false;
    }
    if (std.fmt.parseInt(i64, v, 10)) |i| {
        return if (i != 0) .set_true else .set_false;
    } else |_| {
        return .unset;
    }
}

// ---------------------------------------------------------------------------
// Tests (go-git optbool_test.go)
// ---------------------------------------------------------------------------

test "parseConfigBool truthy" {
    try std.testing.expectEqual(OptBool.set_true, parseConfigBool("true"));
    try std.testing.expectEqual(OptBool.set_true, parseConfigBool("True"));
    try std.testing.expectEqual(OptBool.set_true, parseConfigBool("TRUE"));
    try std.testing.expectEqual(OptBool.set_true, parseConfigBool("yes"));
    try std.testing.expectEqual(OptBool.set_true, parseConfigBool("on"));
    try std.testing.expectEqual(OptBool.set_true, parseConfigBool("1"));
    try std.testing.expectEqual(OptBool.set_true, parseConfigBool("2"));
    try std.testing.expectEqual(OptBool.set_true, parseConfigBool("-1"));
    try std.testing.expectEqual(OptBool.set_true, parseConfigBool("+1"));
}

test "parseConfigBool falsy" {
    try std.testing.expectEqual(OptBool.set_false, parseConfigBool("false"));
    try std.testing.expectEqual(OptBool.set_false, parseConfigBool("no"));
    try std.testing.expectEqual(OptBool.set_false, parseConfigBool("off"));
    try std.testing.expectEqual(OptBool.set_false, parseConfigBool("0"));
    try std.testing.expectEqual(OptBool.set_false, parseConfigBool("-0"));
    try std.testing.expectEqual(OptBool.set_false, parseConfigBool("0000"));
}

test "parseConfigBool unset" {
    try std.testing.expectEqual(OptBool.unset, parseConfigBool(""));
    try std.testing.expectEqual(OptBool.unset, parseConfigBool("maybe"));
    try std.testing.expectEqual(OptBool.unset, parseConfigBool("t"));
    try std.testing.expectEqual(OptBool.unset, parseConfigBool("0x1"));
    try std.testing.expectEqual(OptBool.unset, parseConfigBool("1.5"));
    try std.testing.expectEqual(OptBool.unset, parseConfigBool("  true  "));
}

test "OptBool helpers" {
    try std.testing.expect(OptBool.fromBool(true).isTrue());
    try std.testing.expect(!OptBool.fromBool(false).isTrue());
    try std.testing.expect(OptBool.set_true.isSet());
    try std.testing.expect(OptBool.set_false.isSet());
    try std.testing.expect(!OptBool.unset.isSet());
    try std.testing.expectEqualStrings("true", OptBool.set_true.formatBool());
    try std.testing.expectEqualStrings("false", OptBool.set_false.formatBool());
    try std.testing.expectEqualStrings("unset", OptBool.unset.string());
}
