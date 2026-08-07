//! internal/reference — stable ordering of plumbing references
//! (port of go-git `internal/reference`).

const sort_mod = @import("sort.zig");

/// Sort `[]plumbing.Reference` by name ascending (go-git `reference.Sort`).
pub const sort = sort_mod.sort;

/// Sort `[]*const plumbing.Reference` by name ascending.
pub const sortPtrs = sort_mod.sortPtrs;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const std = @import("std");
const plumbing = @import("plumbing");
const testing = std.testing;

const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const Hash = plumbing.Hash;

fn hashRef(name: []const u8) Reference {
    return Reference.newHashReference(ReferenceName.init(name), Hash{});
}

test "sort mixed names ascending" {
    var refs = [_]Reference{
        hashRef("refs/tags/v2"),
        hashRef("HEAD"),
        hashRef("refs/heads/master"),
        hashRef("refs/heads/feature/a"),
        hashRef("refs/tags/v1"),
        hashRef("refs/remotes/origin/main"),
    };

    sort(&refs);

    const expected = [_][]const u8{
        "HEAD",
        "refs/heads/feature/a",
        "refs/heads/master",
        "refs/remotes/origin/main",
        "refs/tags/v1",
        "refs/tags/v2",
    };
    try testing.expectEqual(expected.len, refs.len);
    for (expected, refs) |want, got| {
        try testing.expectEqualStrings(want, got.name.string());
    }
}

test "sort empty and single are no-ops" {
    var empty: [0]Reference = .{};
    sort(&empty);

    var one = [_]Reference{hashRef("refs/heads/main")};
    sort(&one);
    try testing.expectEqualStrings("refs/heads/main", one[0].name.raw);
}

test "sort already ordered stays ordered" {
    var refs = [_]Reference{
        hashRef("A"),
        hashRef("B"),
        hashRef("C"),
    };
    sort(&refs);
    try testing.expectEqualStrings("A", refs[0].name.raw);
    try testing.expectEqualStrings("B", refs[1].name.raw);
    try testing.expectEqualStrings("C", refs[2].name.raw);
}

test "sortPtrs mixed names ascending" {
    var a = hashRef("refs/tags/z");
    var b = hashRef("HEAD");
    var c = hashRef("refs/heads/a");
    var ptrs = [_]*const Reference{ &a, &b, &c };

    sortPtrs(&ptrs);

    try testing.expectEqualStrings("HEAD", ptrs[0].name.raw);
    try testing.expectEqualStrings("refs/heads/a", ptrs[1].name.raw);
    try testing.expectEqualStrings("refs/tags/z", ptrs[2].name.raw);
}
