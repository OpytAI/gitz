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
///
/// go-git does **not** record newly appended values into `added`, so a values
/// slice with duplicates (e.g. `{"a","a"}` on an empty list) yields two options.
///
/// Ownership: on error, `opts` is left intact (dropped options are not freed
/// until commit). Only options allocated during this call are freed on error.
pub fn withSettedOption(
    allocator: Allocator,
    opts: *Options,
    key: []const u8,
    values: []const []const u8,
) Allocator.Error!void {
    var result: Options = .empty;
    // Count of options newly allocated in this call (tail of `result`).
    var new_count: usize = 0;
    // Options removed from `opts` but not yet freed (commit frees them).
    var dropped: Options = .empty;
    defer dropped.deinit(allocator);

    errdefer {
        // Free only options we allocated in this call; leave `opts` items alone.
        // Dropped options remain owned by `opts` (not freed until commit).
        const start = result.items.len -| new_count;
        for (result.items[start..]) |o| o.deinit(allocator);
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
            // Record existing kept values only (go-git `added` semantics).
            try added.append(allocator, o.value);
            try result.append(allocator, o);
        } else {
            try dropped.append(allocator, o);
        }
    }

    for (values) |value| {
        if (containsExact(added.items, value)) continue;
        const k = try allocator.dupe(u8, key);
        errdefer allocator.free(k);
        const v = try allocator.dupe(u8, value);
        errdefer allocator.free(v);
        try result.append(allocator, .{ .key = k, .value = v });
        new_count += 1;
        // Intentionally do NOT append to `added` — go-git parity for
        // duplicate entries in the values slice.
    }

    // Commit: free dropped options, free old array storage, install result.
    for (dropped.items) |o| o.deinit(allocator);
    dropped.clearRetainingCapacity();
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
    // go-git TestOptions_Has
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
    // go-git TestOptions_GetAll
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
    {
        var empty: Options = .empty;
        defer empty.deinit(gpa);
        const all = try getAll(gpa, empty.items, "k");
        defer gpa.free(all);
        try std.testing.expectEqual(@as(usize, 0), all.len);
    }
}

test "Option.isKey" {
    // go-git TestOption_IsKey
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
    // Behaviour noted in option.go Get docs (used by Section.Option).
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

test "Options.withAddedOption" {
    const gpa = std.testing.allocator;
    var opts: Options = .empty;
    defer {
        for (opts.items) |o| o.deinit(gpa);
        opts.deinit(gpa);
    }
    try withAddedOption(gpa, &opts, "k", "v1");
    try withAddedOption(gpa, &opts, "k", "v2");
    try std.testing.expectEqual(@as(usize, 2), opts.items.len);
    try std.testing.expectEqualStrings("v1", opts.items[0].value);
    try std.testing.expectEqualStrings("v2", opts.items[1].value);
}

test "Options.withoutOption" {
    const gpa = std.testing.allocator;
    var opts: Options = .empty;
    defer {
        for (opts.items) |o| o.deinit(gpa);
        opts.deinit(gpa);
    }
    try withAddedOption(gpa, &opts, "key1", "value1");
    try withAddedOption(gpa, &opts, "key2", "value2");
    try withAddedOption(gpa, &opts, "key1", "value3");
    withoutOption(gpa, &opts, "key1");
    try std.testing.expectEqual(@as(usize, 1), opts.items.len);
    try std.testing.expectEqualStrings("key2", opts.items[0].key);
    try std.testing.expectEqualStrings("value2", opts.items[0].value);
}

test "Options.withSettedOption multi keep and append" {
    // go-git withSettedOption used by Subsection.SetOption
    const gpa = std.testing.allocator;
    var opts: Options = .empty;
    defer {
        for (opts.items) |o| o.deinit(gpa);
        opts.deinit(gpa);
    }
    try withAddedOption(gpa, &opts, "key1", "value1");
    try withAddedOption(gpa, &opts, "key2", "value2");
    try withAddedOption(gpa, &opts, "key1", "value3");
    const vals = [_][]const u8{ "value1", "value4" };
    try withSettedOption(gpa, &opts, "key1", &vals);
    try std.testing.expectEqual(@as(usize, 3), opts.items.len);
    try std.testing.expectEqualStrings("value1", opts.items[0].value);
    try std.testing.expectEqualStrings("value2", opts.items[1].value);
    try std.testing.expectEqualStrings("value4", opts.items[2].value);
}

test "Options.withSettedOption replace single" {
    // go-git Section.SetOption path (single value)
    const gpa = std.testing.allocator;
    var opts: Options = .empty;
    defer {
        for (opts.items) |o| o.deinit(gpa);
        opts.deinit(gpa);
    }
    try withAddedOption(gpa, &opts, "key1", "value1");
    try withAddedOption(gpa, &opts, "key2", "value2");
    const vals = [_][]const u8{"value4"};
    try withSettedOption(gpa, &opts, "key1", &vals);
    try std.testing.expectEqual(@as(usize, 2), opts.items.len);
    try std.testing.expectEqualStrings("key2", opts.items[0].key);
    try std.testing.expectEqualStrings("value2", opts.items[0].value);
    try std.testing.expectEqualStrings("key1", opts.items[1].key);
    try std.testing.expectEqualStrings("value4", opts.items[1].value);
}

test "Options.withSettedOption duplicate values in values slice" {
    // go-git does not record newly appended values into `added`, so duplicates
    // in the values slice each become their own option when not already present.
    const gpa = std.testing.allocator;
    var opts: Options = .empty;
    defer {
        for (opts.items) |o| o.deinit(gpa);
        opts.deinit(gpa);
    }
    const vals = [_][]const u8{ "a", "a" };
    try withSettedOption(gpa, &opts, "k", &vals);
    try std.testing.expectEqual(@as(usize, 2), opts.items.len);
    try std.testing.expectEqualStrings("a", opts.items[0].value);
    try std.testing.expectEqualStrings("a", opts.items[1].value);
}

test "Options.withSettedOption keeps multiple existing equal values" {
    // Existing matches are kept and recorded in `added`, so values already
    // present are not re-appended.
    const gpa = std.testing.allocator;
    var opts: Options = .empty;
    defer {
        for (opts.items) |o| o.deinit(gpa);
        opts.deinit(gpa);
    }
    try withAddedOption(gpa, &opts, "k", "a");
    try withAddedOption(gpa, &opts, "k", "a");
    const vals = [_][]const u8{ "a", "a" };
    try withSettedOption(gpa, &opts, "k", &vals);
    try std.testing.expectEqual(@as(usize, 2), opts.items.len);
    try std.testing.expectEqualStrings("a", opts.items[0].value);
    try std.testing.expectEqualStrings("a", opts.items[1].value);
}

test "Options.withSettedOption empty values removes key" {
    const gpa = std.testing.allocator;
    var opts: Options = .empty;
    defer {
        for (opts.items) |o| o.deinit(gpa);
        opts.deinit(gpa);
    }
    try withAddedOption(gpa, &opts, "key1", "value1");
    try withAddedOption(gpa, &opts, "key2", "value2");
    const vals = [_][]const u8{};
    try withSettedOption(gpa, &opts, "key1", &vals);
    try std.testing.expectEqual(@as(usize, 1), opts.items.len);
    try std.testing.expectEqualStrings("key2", opts.items[0].key);
}
