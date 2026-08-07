//! Partial-clone filter helpers.
//! Port of go-git `plumbing/protocol/packp/filter.go` (v5.19.2).
//!
//! All dynamic filters allocate with the caller allocator. `filterBlobNone` is a
//! static string and needs no free. There are no package-global format buffers.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const plumbing = @import("plumbing");
const common = @import("common.zig");

const ObjectType = plumbing.ObjectType;

/// Filter value for the partial clone capability (go-git `Filter`).
pub const Filter = []const u8;

/// Size unit prefix for `filterBlobLimit` (go-git `BlobLimitPrefix`).
pub const BlobLimitPrefix = enum {
    /// Bytes (go-git `BlobLimitPrefixNone`).
    none,
    /// Kibibytes (go-git `BlobLimitPrefixKibi`).
    kibi,
    /// Mebibytes (go-git `BlobLimitPrefixMebi`).
    mebi,
    /// Gibibytes (go-git `BlobLimitPrefixGibi`).
    gibi,

    /// Wire-format suffix (`""`, `"k"`, `"m"`, `"g"`).
    pub fn string(self: BlobLimitPrefix) []const u8 {
        return switch (self) {
            .none => "",
            .kibi => "k",
            .mebi => "m",
            .gibi => "g",
        };
    }
};

/// Omits all blobs (go-git `FilterBlobNone`). Static; do not free.
pub fn filterBlobNone() Filter {
    return "blob:none";
}

/// Omits blobs of size at least `n` in the given unit (go-git `FilterBlobLimit`).
/// Caller owns the returned slice.
pub fn filterBlobLimit(allocator: Allocator, n: u64, prefix: BlobLimitPrefix) Allocator.Error!Filter {
    return std.fmt.allocPrint(allocator, "blob:limit={d}{s}", .{ n, prefix.string() });
}

/// Omits blobs and trees at depth ≥ `depth` (go-git `FilterTreeDepth`).
/// Caller owns the returned slice.
pub fn filterTreeDepth(allocator: Allocator, depth: u64) Allocator.Error!Filter {
    return std.fmt.allocPrint(allocator, "tree:{d}", .{depth});
}

/// Omits objects that are not of type `t` (go-git `FilterObjectType`).
/// Supported: tag, commit, tree, blob. Caller owns the returned slice on success.
pub fn filterObjectType(allocator: Allocator, t: ObjectType) (Allocator.Error || common.Error)!Filter {
    switch (t) {
        .tag, .commit, .tree, .blob => {
            return std.fmt.allocPrint(allocator, "object:type={s}", .{t.string()});
        },
        else => return error.UnsupportedObjectFilterType,
    }
}

/// Combines multiple filters (go-git `FilterCombine`).
/// Each filter is URL query-escaped and joined with `+`.
/// Caller owns the returned slice.
pub fn filterCombine(allocator: Allocator, filters: []const Filter) Allocator.Error!Filter {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(allocator);

    try list.appendSlice(allocator, "combine:");
    for (filters, 0..) |f, i| {
        if (i > 0) try list.append(allocator, '+');
        try appendQueryEscape(allocator, &list, f);
    }
    return try list.toOwnedSlice(allocator);
}

/// Go `url.QueryEscape` for filter components (unreserved + space→`+`).
fn appendQueryEscape(allocator: Allocator, list: *std.ArrayListUnmanaged(u8), s: []const u8) Allocator.Error!void {
    const hex_digits = "0123456789ABCDEF";
    for (s) |c| {
        if (isUnreserved(c)) {
            try list.append(allocator, c);
        } else if (c == ' ') {
            try list.append(allocator, '+');
        } else {
            try list.append(allocator, '%');
            try list.append(allocator, hex_digits[c >> 4]);
            try list.append(allocator, hex_digits[c & 0xf]);
        }
    }
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests — filter_test.go
// ---------------------------------------------------------------------------

test "filterBlobNone" {
    try testing.expectEqualStrings("blob:none", filterBlobNone());
}

test "filterBlobLimit" {
    const gpa = testing.allocator;
    const a = try filterBlobLimit(gpa, 0, .none);
    defer gpa.free(a);
    try testing.expectEqualStrings("blob:limit=0", a);
    const b = try filterBlobLimit(gpa, 1000, .none);
    defer gpa.free(b);
    try testing.expectEqualStrings("blob:limit=1000", b);
    const c = try filterBlobLimit(gpa, 4, .kibi);
    defer gpa.free(c);
    try testing.expectEqualStrings("blob:limit=4k", c);
    const d = try filterBlobLimit(gpa, 4, .mebi);
    defer gpa.free(d);
    try testing.expectEqualStrings("blob:limit=4m", d);
    const e = try filterBlobLimit(gpa, 4, .gibi);
    defer gpa.free(e);
    try testing.expectEqualStrings("blob:limit=4g", e);
}

test "filterTreeDepth" {
    const gpa = testing.allocator;
    const a = try filterTreeDepth(gpa, 0);
    defer gpa.free(a);
    try testing.expectEqualStrings("tree:0", a);
    const b = try filterTreeDepth(gpa, 1);
    defer gpa.free(b);
    try testing.expectEqualStrings("tree:1", b);
    const c = try filterTreeDepth(gpa, 2);
    defer gpa.free(c);
    try testing.expectEqualStrings("tree:2", c);
}

test "filterObjectType" {
    const gpa = testing.allocator;
    const a = try filterObjectType(gpa, .tag);
    defer gpa.free(a);
    try testing.expectEqualStrings("object:type=tag", a);
    const b = try filterObjectType(gpa, .commit);
    defer gpa.free(b);
    try testing.expectEqualStrings("object:type=commit", b);
    const c = try filterObjectType(gpa, .tree);
    defer gpa.free(c);
    try testing.expectEqualStrings("object:type=tree", c);
    const d = try filterObjectType(gpa, .blob);
    defer gpa.free(d);
    try testing.expectEqualStrings("object:type=blob", d);
    try testing.expectError(error.UnsupportedObjectFilterType, filterObjectType(gpa, .invalid));
    try testing.expectError(error.UnsupportedObjectFilterType, filterObjectType(gpa, .ofs_delta));
}

test "filterCombine" {
    const gpa = testing.allocator;
    const tree = try filterTreeDepth(gpa, 2);
    defer gpa.free(tree);
    const combined = try filterCombine(gpa, &.{ tree, filterBlobNone() });
    defer gpa.free(combined);
    try testing.expectEqualStrings("combine:tree%3A2+blob%3Anone", combined);
}
