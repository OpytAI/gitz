//! URL helpers — port of go-git `internal/url` (v5.19.2).
//!
//! Scheme detection, SCP-like SSH URL matching/parsing, and local-endpoint
//! classification. Mirrors Git's `url_is_local_not_ssh` disambiguation.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// go-git `MatchesScheme` — true when `s` looks like `scheme://…`.
/// Regex: `^[^:]+://`
pub fn matchesScheme(s: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return false;
    if (colon == 0) return false;
    if (colon + 2 >= s.len) return false;
    return s[colon + 1] == '/' and s[colon + 2] == '/';
}

/// go-git `MatchesScpLike` — true when `s` matches SCP-like SSH form and is
/// not a local path (slash before first colon, or Windows DOS drive prefix).
pub fn matchesScpLike(s: []const u8) bool {
    if (!matchScpLikeRegex(s)) return false;

    // Mirror Git's url_is_local_not_ssh: `/` before first `:` ⇒ local.
    if (std.mem.indexOfScalar(u8, s, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, s[0..colon], '/') != null) return false;
    } else {
        return false;
    }

    if (builtin.os.tag == .windows and hasDosDrivePrefix(s)) return false;
    return true;
}

/// go-git `FindScpLikeComponents`.
/// Returns user, host, port, path (slices into `s`; empty when absent).
/// Caller should only use this when `matchesScpLike` is true (go-git panics
/// on non-matching input via nil regex submatch).
pub fn findScpLikeComponents(s: []const u8) struct {
    user: []const u8,
    host: []const u8,
    port: []const u8,
    path: []const u8,
} {
    // Regex: `^(?:(?P<user>[^@]+)@)?(?P<host>[^:\s]+):(?:(?P<port>[0-9]{1,5}):)?(?P<path>[^\\].*)$`
    var i: usize = 0;
    var user: []const u8 = "";

    if (std.mem.indexOfScalar(u8, s, '@')) |at| {
        const first_colon = std.mem.indexOfScalar(u8, s, ':') orelse
            return .{ .user = "", .host = "", .port = "", .path = "" };
        if (at < first_colon) {
            user = s[0..at];
            i = at + 1;
        }
    }

    const host_start = i;
    while (i < s.len and s[i] != ':' and s[i] != ' ' and s[i] != '\t') : (i += 1) {}
    const host = s[host_start..i];
    if (host.len == 0 or i >= s.len or s[i] != ':') {
        return .{ .user = user, .host = host, .port = "", .path = "" };
    }
    i += 1; // skip ':'

    var port: []const u8 = "";
    var path: []const u8 = "";
    if (looksLikeScpPortPrefix(s[i..])) |port_end| {
        port = s[i .. i + port_end];
        i += port_end + 1; // digits + trailing ':'
        path = s[i..];
    } else {
        path = s[i..];
    }

    if (path.len == 0 or path[0] == '\\') {
        return .{ .user = user, .host = host, .port = "", .path = path };
    }

    return .{ .user = user, .host = host, .port = port, .path = path };
}

/// go-git `IsLocalEndpoint` — true when URL is neither scheme nor SCP-like.
pub fn isLocalEndpoint(s: []const u8) bool {
    return !matchesScheme(s) and !matchesScpLike(s);
}

/// go-git `hasDosDrivePrefix` — true when `s` begins with `<letter>:` (Windows
/// drive prefix such as `C:` / `c:`). Mirrors Git `win32_has_dos_drive_prefix`.
/// Implemented for correctness on all platforms; `matchesScpLike` only applies
/// it when `builtin.os.tag == .windows`.
pub fn hasDosDrivePrefix(s: []const u8) bool {
    if (s.len < 2 or s[1] != ':') return false;
    const c = s[0];
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

/// Full SCP-like shape check (before local-path disambiguation).
/// Regex: `^(?:(?P<user>[^@]+)@)?(?P<host>[^:\s]+):(?:(?P<port>[0-9]{1,5}):)?(?P<path>[^\\].*)$`
fn matchScpLikeRegex(s: []const u8) bool {
    if (s.len == 0) return false;

    var i: usize = 0;
    if (std.mem.indexOfScalar(u8, s, '@')) |at| {
        const first_colon = std.mem.indexOfScalar(u8, s, ':') orelse return false;
        if (at < first_colon) {
            if (at == 0) return false; // user must be [^@]+
            i = at + 1;
        }
    }

    const host_start = i;
    while (i < s.len and s[i] != ':' and s[i] != ' ' and s[i] != '\t') : (i += 1) {}
    if (i == host_start) return false;
    if (i >= s.len or s[i] != ':') return false;
    i += 1;

    if (looksLikeScpPortPrefix(s[i..])) |port_len| {
        i += port_len + 1;
    }

    // Path: [^\\].*  (at least one char, not starting with \)
    if (i >= s.len) return false;
    if (s[i] == '\\') return false;
    return true;
}

/// If `rest` starts with 1–5 digits followed by `:`, return digit count.
fn looksLikeScpPortPrefix(rest: []const u8) ?usize {
    var n: usize = 0;
    while (n < rest.len and n < 5 and rest[n] >= '0' and rest[n] <= '9') : (n += 1) {}
    if (n == 0) return null;
    if (n >= rest.len or rest[n] != ':') return null;
    return n;
}

// ---------------------------------------------------------------------------
// Tests (port of go-git internal/url/url_test.go)
// ---------------------------------------------------------------------------

test "MatchesScheme" {
    try testing.expect(matchesScheme("http://example.com"));
    try testing.expect(matchesScheme("https://github.com/src-d/go-git"));
    try testing.expect(matchesScheme("file:///home/user/src/go-git"));
    try testing.expect(matchesScheme("git://host/path"));
    try testing.expect(!matchesScheme("git@github.com:user/repo.git"));
    try testing.expect(!matchesScheme("/home/user/src/go-git"));
    try testing.expect(!matchesScheme("github.com:user/repo"));
    try testing.expect(!matchesScheme("://missing-scheme"));
    try testing.expect(!matchesScheme(""));
    try testing.expect(!matchesScheme("http:/single-slash"));
}

test "MatchesScpLike" {
    // See https://github.com/git/git/blob/master/Documentation/urls.txt#L37
    // and go-git TestMatchesScpLike
    const examples = [_][]const u8{
        "git@github.com:james/bond",
        "git@github.com:22:james/bond",
        "git@github.com:007/bond",
        "git@github.com:22:007/bond",
        "git@github.com:bond",
        "git@github.com:22:bond",
        "git@github.com:22:007",
        "git@github.com:22:_007.git",
        "git@github.com:_007.git",
        "git@github.com:_james.git",
        "git@github.com:_james/bond.git",
    };
    for (examples) |url| {
        try testing.expect(matchesScpLike(url));
    }
}

test "MatchesScpLikeStillAcceptsRealSCP" {
    // go-git TestMatchesScpLikeStillAcceptsRealSCP
    const examples = [_][]const u8{
        "git@github.com:james/bond",
        "user@host.example.com:path/to/repo.git",
        "host:path",
    };
    for (examples) |url| {
        try testing.expect(matchesScpLike(url));
    }
}

test "MatchesScpLikeRejectsLocalPaths" {
    // go-git TestMatchesScpLikeRejectsLocalPaths — slash before first `:`
    const examples = [_][]const u8{
        "/abs/path/with:colon/file",
        "./relative:path",
        "./relative/with:colon",
        "sub/dir:foo",
    };
    for (examples) |url| {
        try testing.expect(!matchesScpLike(url));
    }
}

test "MatchesScpLikeWindowsDrivePrefix" {
    // go-git TestMatchesScpLikeWindowsDrivePrefix — platform-specific
    if (builtin.os.tag != .windows) return;
    const examples = [_][]const u8{
        "C:foo",
        "C:/path/to/repo",
        "C:\\path\\to\\repo",
        "d:relative",
    };
    for (examples) |url| {
        try testing.expect(!matchesScpLike(url));
    }
}

test "hasDosDrivePrefix" {
    try testing.expect(hasDosDrivePrefix("C:foo"));
    try testing.expect(hasDosDrivePrefix("c:/path"));
    try testing.expect(hasDosDrivePrefix("Z:"));
    try testing.expect(!hasDosDrivePrefix("1:foo"));
    try testing.expect(!hasDosDrivePrefix(":foo"));
    try testing.expect(!hasDosDrivePrefix("C"));
    try testing.expect(!hasDosDrivePrefix(""));
    try testing.expect(!hasDosDrivePrefix("git@host:path"));
}

test "FindScpLikeComponents" {
    // go-git TestFindScpLikeComponents
    const Case = struct {
        url: []const u8,
        user: []const u8,
        host: []const u8,
        port: []const u8,
        path: []const u8,
    };
    const cases = [_]Case{
        .{ .url = "git@github.com:james/bond", .user = "git", .host = "github.com", .port = "", .path = "james/bond" },
        .{ .url = "git@github.com:22:james/bond", .user = "git", .host = "github.com", .port = "22", .path = "james/bond" },
        .{ .url = "git@github.com:007/bond", .user = "git", .host = "github.com", .port = "", .path = "007/bond" },
        .{ .url = "git@github.com:22:007/bond", .user = "git", .host = "github.com", .port = "22", .path = "007/bond" },
        .{ .url = "git@github.com:bond", .user = "git", .host = "github.com", .port = "", .path = "bond" },
        .{ .url = "git@github.com:22:bond", .user = "git", .host = "github.com", .port = "22", .path = "bond" },
        .{ .url = "git@github.com:22:007", .user = "git", .host = "github.com", .port = "22", .path = "007" },
        .{ .url = "git@github.com:22:_007.git", .user = "git", .host = "github.com", .port = "22", .path = "_007.git" },
        .{ .url = "git@github.com:_007.git", .user = "git", .host = "github.com", .port = "", .path = "_007.git" },
        .{ .url = "git@github.com:_james.git", .user = "git", .host = "github.com", .port = "", .path = "_james.git" },
        .{ .url = "git@github.com:_james/bond.git", .user = "git", .host = "github.com", .port = "", .path = "_james/bond.git" },
    };
    for (cases) |tc| {
        const c = findScpLikeComponents(tc.url);
        try testing.expectEqualStrings(tc.user, c.user);
        try testing.expectEqualStrings(tc.host, c.host);
        try testing.expectEqualStrings(tc.port, c.port);
        try testing.expectEqualStrings(tc.path, c.path);
    }
}

test "IsLocalEndpoint" {
    try testing.expect(isLocalEndpoint("/home/user/src/go-git"));
    try testing.expect(isLocalEndpoint("./relative/path"));
    try testing.expect(isLocalEndpoint("sub/dir:foo")); // slash before colon ⇒ local
    try testing.expect(!isLocalEndpoint("https://github.com/src-d/go-git"));
    try testing.expect(!isLocalEndpoint("git@github.com:james/bond"));
    try testing.expect(!isLocalEndpoint("host:path"));
}
