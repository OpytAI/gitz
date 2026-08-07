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

test "RefSpec.match and matchAny" {
    const rs = RefSpec.init("+refs/heads/*:refs/remotes/origin/*");
    try std.testing.expect(rs.match(plumbing.ReferenceName.init("refs/heads/master")));
    try std.testing.expect(!rs.match(plumbing.ReferenceName.init("refs/tags/v1")));
    const list = [_]RefSpec{rs};
    try std.testing.expect(matchAny(&list, plumbing.ReferenceName.init("refs/heads/foo")));
}
