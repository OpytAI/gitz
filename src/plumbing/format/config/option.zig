//! Option key/value helpers for git config files.
//!
//! Port of go-git v5.19.2 `plumbing/format/config/option.go`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Key/value entity in a config file.
pub const Option = struct {
    /// Key preserving original caseness. Use `isKey` for case-insensitive compare.
    key: []const u8,
    /// Original value as string (may not be normalized).
    value: []const u8,

    /// True if `key` matches this option's key (case-insensitive).
    pub fn isKey(self: *const Option, key: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.key, key);
    }

    pub fn deinit(self: Option, allocator: Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
    }
};

/// List of options (go-git `Options`).
pub const Options = std.ArrayList(Option);

/// Get the value for `key` if set; otherwise empty string.
///
/// When multiple definitions exist, the last one wins (git v1.8.1-rc1+).
pub fn get(opts: []const Option, key: []const u8) []const u8 {
    var i = opts.len;
    while (i > 0) {
        i -= 1;
        if (opts[i].isKey(key)) return opts[i].value;
    }
    return "";
}

/// True if an option with `key` exists.
pub fn has(opts: []const Option, key: []const u8) bool {
    for (opts) |o| {
        if (o.isKey(key)) return true;
    }
    return false;
}

/// All values for `key` (caller owns the returned slice; values are not owned).
pub fn getAll(allocator: Allocator, opts: []const Option, key: []const u8) Allocator.Error![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer result.deinit(allocator);
    for (opts) |o| {
        if (o.isKey(key)) try result.append(allocator, o.value);
    }
    return try result.toOwnedSlice(allocator);
}

/// Append a new option (owns duped key/value).
pub fn withAddedOption(allocator: Allocator, opts: *Options, key: []const u8, value: []const u8) Allocator.Error!void {
    const k = try allocator.dupe(u8, key);
    errdefer allocator.free(k);
    const v = try allocator.dupe(u8, value);
    errdefer allocator.free(v);
    try opts.append(allocator, .{ .key = k, .value = v });
}

/// Remove all options whose key matches `key` (case-insensitive).
pub fn withoutOption(allocator: Allocator, opts: *Options, key: []const u8) void {
    var i: usize = 0;
    while (i < opts.items.len) {
        if (opts.items[i].isKey(key)) {
            const removed = opts.orderedRemove(i);
            removed.deinit(allocator);
        } else {
            i += 1;
        }
    }
}

/// Set option(s) for `key`: keep existing matching key+value pairs that appear
/// in `values`, drop other matches, append missing values (go-git `withSettedOption`).
pub fn withSettedOption(
    allocator: Allocator,
    opts: *Options,
    key: []const u8,
    values: []const []const u8,
) Allocator.Error!void {
    var result: Options = .empty;
    errdefer {
        for (result.items) |o| o.deinit(allocator);
        result.deinit(allocator);
    }

    var added: std.ArrayList([]const u8) = .empty;
    defer added.deinit(allocator);

    for (opts.items) |o| {
        if (!o.isKey(key)) {
            try result.append(allocator, o);
            continue;
        }
        if (containsExact(values, o.value)) {
            try added.append(allocator, o.value);
            try result.append(allocator, o);
        } else {
            o.deinit(allocator);
        }
    }

    for (values) |value| {
        if (containsExact(added.items, value)) continue;
        const k = try allocator.dupe(u8, key);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, value);
        errdefer allocator.free(v);
        try result.append(allocator, .{ .key = k, .value = v });
        try added.append(allocator, v);
    }

    // Drop old array storage only; items were moved or freed.
    opts.deinit(allocator);
    opts.* = result;
}

fn containsExact(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests (go-git option_test.go)
// ---------------------------------------------------------------------------

test "Options.has" {
    const gpa = std.testing.allocator;
    var opts: Options = .empty;
    defer {
        for (opts.items) |o| o.deinit(gpa);
        opts.deinit(gpa);
    }
    try withAddedOption(gpa, &opts, "k", "v");
    try withAddedOption(gpa, &opts, "ok", "v1");
    try withAddedOption(gpa, &opts, "K", "v2");

    try std.testing.expect(has(opts.items, "k"));
    try std.testing.expect(has(opts.items, "K"));
    try std.testing.expect(has(opts.items, "ok"));
    try std.testing.expect(!has(opts.items, "unexistant"));

    var empty: Options = .empty;
    defer empty.deinit(gpa);
    try std.testing.expect(!has(empty.items, "k"));
}

test "Options.getAll" {
    const gpa = std.testing.allocator;
    var opts: Options = .empty;
    defer {
        for (opts.items) |o| o.deinit(gpa);
        opts.deinit(gpa);
    }
    try withAddedOption(gpa, &opts, "k", "v");
    try withAddedOption(gpa, &opts, "ok", "v1");
    try withAddedOption(gpa, &opts, "K", "v2");

    {
        const all = try getAll(gpa, opts.items, "k");
        defer gpa.free(all);
        try std.testing.expectEqual(@as(usize, 2), all.len);
        try std.testing.expectEqualStrings("v", all[0]);
        try std.testing.expectEqualStrings("v2", all[1]);
    }
    {
        const all = try getAll(gpa, opts.items, "K");
        defer gpa.free(all);
        try std.testing.expectEqual(@as(usize, 2), all.len);
        try std.testing.expectEqualStrings("v", all[0]);
        try std.testing.expectEqualStrings("v2", all[1]);
    }
    {
        const all = try getAll(gpa, opts.items, "ok");
        defer gpa.free(all);
        try std.testing.expectEqual(@as(usize, 1), all.len);
        try std.testing.expectEqualStrings("v1", all[0]);
    }
    {
        const all = try getAll(gpa, opts.items, "unexistant");
        defer gpa.free(all);
        try std.testing.expectEqual(@as(usize, 0), all.len);
    }
}

test "Option.isKey" {
    const o = Option{ .key = "key", .value = "" };
    try std.testing.expect(o.isKey("key"));
    try std.testing.expect(o.isKey("KEY"));
    const o2 = Option{ .key = "KEY", .value = "" };
    try std.testing.expect(o2.isKey("key"));
    try std.testing.expect(!o.isKey("other"));
    try std.testing.expect(!o.isKey(""));
    const empty_key = Option{ .key = "", .value = "" };
    try std.testing.expect(!empty_key.isKey("key"));
}

test "Options.get last wins" {
    const gpa = std.testing.allocator;
    var opts: Options = .empty;
    defer {
        for (opts.items) |o| o.deinit(gpa);
        opts.deinit(gpa);
    }
    try withAddedOption(gpa, &opts, "key1", "value1");
    try withAddedOption(gpa, &opts, "key2", "value2");
    try withAddedOption(gpa, &opts, "key1", "value3");
    try std.testing.expectEqualStrings("", get(opts.items, "otherkey"));
    try std.testing.expectEqualStrings("value2", get(opts.items, "key2"));
    try std.testing.expectEqualStrings("value3", get(opts.items, "key1"));
}
