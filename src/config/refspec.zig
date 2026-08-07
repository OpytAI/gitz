//! RefSpec mapping local branches to remote references.
//!
//! Port of go-git v5.19.2 `config/refspec.go`.

const std = @import("std");
const plumbing = @import("plumbing");

const ref_spec_wildcard = "*";
const ref_spec_force = '+';
const ref_spec_separator = ':';

/// Refspec errors (go-git package vars).
pub const Error = error{
    /// go-git `ErrRefSpecMalformedSeparator`.
    RefSpecMalformedSeparator,
    /// go-git `ErrRefSpecMalformedWildcard`.
    RefSpecMalformedWildcard,
};

/// Mapping from local branches to remote references (go-git `RefSpec`).
///
/// Format: optional `+`, then `<src>:<dst>`. The `+` allows non-fast-forward updates.
pub const RefSpec = struct {
    raw: []const u8,

    pub fn init(raw: []const u8) RefSpec {
        return .{ .raw = raw };
    }

    pub fn string(self: RefSpec) []const u8 {
        return self.raw;
    }

    /// go-git `RefSpec.Validate`.
    pub fn validate(self: RefSpec) Error!void {
        const spec = self.raw;
        if (std.mem.count(u8, spec, ":") != 1) return error.RefSpecMalformedSeparator;

        const sep = std.mem.indexOfScalar(u8, spec, ref_spec_separator) orelse
            return error.RefSpecMalformedSeparator;
        if (sep == spec.len - 1) return error.RefSpecMalformedSeparator;

        const ws = std.mem.count(u8, spec[0..sep], ref_spec_wildcard);
        const wd = std.mem.count(u8, spec[sep + 1 ..], ref_spec_wildcard);
        if (ws == wd and ws < 2 and wd < 2) return;
        return error.RefSpecMalformedWildcard;
    }

    /// go-git `IsForceUpdate`.
    pub fn isForceUpdate(self: RefSpec) bool {
        return self.raw.len > 0 and self.raw[0] == ref_spec_force;
    }

    /// go-git `IsDelete` — empty src (starts with `:`).
    pub fn isDelete(self: RefSpec) bool {
        return self.raw.len > 0 and self.raw[0] == ref_spec_separator;
    }

    /// go-git `IsExactSHA1`.
    pub fn isExactSHA1(self: RefSpec) bool {
        return plumbing.isHash(self.src());
    }

    /// go-git `Src`.
    pub fn src(self: RefSpec) []const u8 {
        const spec = self.raw;
        const start: usize = if (self.isForceUpdate()) 1 else 0;
        const end = std.mem.indexOfScalar(u8, spec, ref_spec_separator) orelse spec.len;
        return spec[start..end];
    }

    /// go-git `IsWildcard`.
    pub fn isWildcard(self: RefSpec) bool {
        return std.mem.indexOfScalar(u8, self.raw, '*') != null;
    }

    /// go-git `Match`.
    pub fn match(self: RefSpec, n: plumbing.ReferenceName) bool {
        if (!self.isWildcard()) return self.matchExact(n);
        return self.matchGlob(n);
    }

    fn matchExact(self: RefSpec, n: plumbing.ReferenceName) bool {
        return std.mem.eql(u8, self.src(), n.string());
    }

    fn matchGlob(self: RefSpec, n: plumbing.ReferenceName) bool {
        const source = self.src();
        const name = n.string();
        const wildcard = std.mem.indexOfScalar(u8, source, '*') orelse return false;

        const prefix = source[0..wildcard];
        const suffix = if (source.len > wildcard + 1) source[wildcard + 1 ..] else "";

        return name.len >= prefix.len + suffix.len and
            std.mem.startsWith(u8, name, prefix) and
            std.mem.endsWith(u8, name, suffix);
    }

    /// go-git `Dst` — always allocates; caller frees `result.raw`.
    pub fn dst(
        self: RefSpec,
        allocator: std.mem.Allocator,
        n: plumbing.ReferenceName,
    ) std.mem.Allocator.Error!plumbing.ReferenceName {
        const spec = self.raw;
        const start = (std.mem.indexOfScalar(u8, spec, ref_spec_separator) orelse 0) + 1;
        const dest = spec[start..];
        const source = self.src();

        if (!self.isWildcard()) {
            const owned = try allocator.dupe(u8, dest);
            return plumbing.ReferenceName.init(owned);
        }

        const name = n.string();
        const ws = std.mem.indexOfScalar(u8, source, '*') orelse 0;
        const wd = std.mem.indexOfScalar(u8, dest, '*') orelse 0;
        const match_part = name[ws .. name.len - (source.len - (ws + 1))];
        const owned = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{
            dest[0..wd],
            match_part,
            dest[wd + 1 ..],
        });
        return plumbing.ReferenceName.init(owned);
    }

    /// go-git `Reverse` — allocates; caller frees the returned slice.
    pub fn reverse(self: RefSpec, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        const spec = self.raw;
        const separator = std.mem.indexOfScalar(u8, spec, ref_spec_separator) orelse
            return try allocator.dupe(u8, spec);
        return try std.fmt.allocPrint(allocator, "{s}:{s}", .{
            spec[separator + 1 ..],
            spec[0..separator],
        });
    }
};

/// go-git `MatchAny`.
pub fn matchAny(list: []const RefSpec, n: plumbing.ReferenceName) bool {
    for (list) |r| {
        if (r.match(n)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests (go-git refspec_test.go subset)
// ---------------------------------------------------------------------------

test "RefSpec.validate" {
    try RefSpec.init("+refs/heads/*:refs/remotes/origin/*").validate();
    try std.testing.expectError(
        error.RefSpecMalformedWildcard,
        RefSpec.init("refs/heads/*:refs/remotes/origin/").validate(),
    );
    try RefSpec.init("refs/heads/master:refs/remotes/origin/master").validate();
    try RefSpec.init(":refs/heads/master").validate();
    try std.testing.expectError(
        error.RefSpecMalformedWildcard,
        RefSpec.init(":refs/heads/*").validate(),
    );
    try std.testing.expectError(
        error.RefSpecMalformedWildcard,
        RefSpec.init(":*").validate(),
    );
    try std.testing.expectError(
        error.RefSpecMalformedSeparator,
        RefSpec.init("refs/heads/*").validate(),
    );
    try std.testing.expectError(
        error.RefSpecMalformedSeparator,
        RefSpec.init("refs/heads:").validate(),
    );
    try RefSpec.init("12039e008f9a4e3394f3f94f8ea897785cb09448:refs/heads/foo").validate();
    try std.testing.expectError(
        error.RefSpecMalformedWildcard,
        RefSpec.init("12039e008f9a4e3394f3f94f8ea897785cb09448:refs/heads/*").validate(),
    );
}

test "RefSpec force delete src" {
    try std.testing.expect(RefSpec.init("+refs/heads/*:refs/remotes/origin/*").isForceUpdate());
    try std.testing.expect(!RefSpec.init("refs/heads/*:refs/remotes/origin/*").isForceUpdate());
    try std.testing.expect(RefSpec.init(":refs/heads/master").isDelete());
    try std.testing.expect(!RefSpec.init("refs/heads/*:refs/remotes/origin/*").isDelete());
    try std.testing.expectEqualStrings(
        "refs/heads/*",
        RefSpec.init("+refs/heads/*:refs/remotes/origin/*").src(),
    );
    try std.testing.expect(RefSpec.init("12039e008f9a4e3394f3f94f8ea897785cb09448:refs/heads/foo").isExactSHA1());
    try std.testing.expect(!RefSpec.init("foo:refs/heads/master").isExactSHA1());
}

test "RefSpec.match exact" {
    // go-git TestRefSpecMatch
    {
        const rs = RefSpec.init("refs/heads/master:refs/remotes/origin/master");
        try std.testing.expect(!rs.match(plumbing.ReferenceName.init("refs/heads/foo")));
        try std.testing.expect(rs.match(plumbing.ReferenceName.init("refs/heads/master")));
    }
    {
        const rs = RefSpec.init("+refs/heads/master:refs/remotes/origin/master");
        try std.testing.expect(!rs.match(plumbing.ReferenceName.init("refs/heads/foo")));
        try std.testing.expect(rs.match(plumbing.ReferenceName.init("refs/heads/master")));
    }
    {
        const rs = RefSpec.init(":refs/heads/master");
        try std.testing.expect(rs.match(plumbing.ReferenceName.init("")));
        try std.testing.expect(!rs.match(plumbing.ReferenceName.init("refs/heads/master")));
    }
    {
        const rs = RefSpec.init("refs/heads/love+hate:heads/love+hate");
        try std.testing.expect(rs.match(plumbing.ReferenceName.init("refs/heads/love+hate")));
    }
    {
        const rs = RefSpec.init("+refs/heads/love+hate:heads/love+hate");
        try std.testing.expect(rs.match(plumbing.ReferenceName.init("refs/heads/love+hate")));
    }
}

test "RefSpec.matchGlob" {
    // go-git TestRefSpecMatchGlob
    const Case = struct { ref: []const u8, matches: bool };
    const SpecCases = struct { spec: []const u8, cases: []const Case };

    const table = [_]SpecCases{
        .{
            .spec = "refs/heads/*:refs/remotes/origin/*",
            .cases = &[_]Case{
                .{ .ref = "refs/tag/foo", .matches = false },
                .{ .ref = "refs/heads/foo", .matches = true },
            },
        },
        .{
            .spec = "refs/heads/*bc:refs/remotes/origin/*bc",
            .cases = &[_]Case{
                .{ .ref = "refs/heads/abc", .matches = true },
                .{ .ref = "refs/heads/bc", .matches = true },
                .{ .ref = "refs/heads/abx", .matches = false },
            },
        },
        .{
            .spec = "refs/heads/a*c:refs/remotes/origin/a*c",
            .cases = &[_]Case{
                .{ .ref = "refs/heads/abc", .matches = true },
                .{ .ref = "refs/heads/ac", .matches = true },
                .{ .ref = "refs/heads/abx", .matches = false },
            },
        },
        .{
            .spec = "refs/heads/ab*:refs/remotes/origin/ab*",
            .cases = &[_]Case{
                .{ .ref = "refs/heads/abc", .matches = true },
                .{ .ref = "refs/heads/ab", .matches = true },
                .{ .ref = "refs/heads/xbc", .matches = false },
            },
        },
    };

    for (table) |row| {
        const rs = RefSpec.init(row.spec);
        for (row.cases) |c| {
            try std.testing.expectEqual(c.matches, rs.match(plumbing.ReferenceName.init(c.ref)));
        }
    }
}

test "RefSpec.dst exact" {
    // go-git TestRefSpecDst
    const gpa = std.testing.allocator;
    const rs = RefSpec.init("refs/heads/master:refs/remotes/origin/master");
    const d = try rs.dst(gpa, plumbing.ReferenceName.init("refs/heads/master"));
    defer gpa.free(d.raw);
    try std.testing.expectEqualStrings("refs/remotes/origin/master", d.string());
}

test "RefSpec.dst wildcard" {
    // go-git TestRefSpecDstBlob
    const gpa = std.testing.allocator;
    const ref = plumbing.ReferenceName.init("refs/heads/abc");
    const Case = struct { spec: []const u8, dst: []const u8 };
    const table = [_]Case{
        .{ .spec = "refs/heads/*:refs/remotes/origin/*", .dst = "refs/remotes/origin/abc" },
        .{ .spec = "refs/heads/*bc:refs/remotes/origin/*", .dst = "refs/remotes/origin/a" },
        .{ .spec = "refs/heads/*bc:refs/remotes/origin/*bc", .dst = "refs/remotes/origin/abc" },
        .{ .spec = "refs/heads/a*c:refs/remotes/origin/*", .dst = "refs/remotes/origin/b" },
        .{ .spec = "refs/heads/a*c:refs/remotes/origin/a*c", .dst = "refs/remotes/origin/abc" },
        .{ .spec = "refs/heads/ab*:refs/remotes/origin/*", .dst = "refs/remotes/origin/c" },
        .{ .spec = "refs/heads/ab*:refs/remotes/origin/ab*", .dst = "refs/remotes/origin/abc" },
        .{ .spec = "refs/heads/*abc:refs/remotes/origin/*abc", .dst = "refs/remotes/origin/abc" },
        .{ .spec = "refs/heads/abc*:refs/remotes/origin/abc*", .dst = "refs/remotes/origin/abc" },
    };
    for (table) |c| {
        const rs = RefSpec.init(c.spec);
        const d = try rs.dst(gpa, ref);
        defer gpa.free(d.raw);
        try std.testing.expectEqualStrings(c.dst, d.string());
    }
}

test "RefSpec.reverse" {
    // go-git TestRefSpecReverse
    const gpa = std.testing.allocator;
    const rs = RefSpec.init("refs/heads/*:refs/remotes/origin/*");
    const rev = try rs.reverse(gpa);
    defer gpa.free(rev);
    try std.testing.expectEqualStrings("refs/remotes/origin/*:refs/heads/*", rev);
}

test "matchAny multi-list" {
    // go-git TestMatchAny
    const specs = [_]RefSpec{
        RefSpec.init("refs/heads/bar:refs/remotes/origin/foo"),
        RefSpec.init("refs/heads/foo:refs/remotes/origin/bar"),
    };
    try std.testing.expect(matchAny(&specs, plumbing.ReferenceName.init("refs/heads/foo")));
    try std.testing.expect(matchAny(&specs, plumbing.ReferenceName.init("refs/heads/bar")));
    try std.testing.expect(!matchAny(&specs, plumbing.ReferenceName.init("refs/heads/master")));
}
