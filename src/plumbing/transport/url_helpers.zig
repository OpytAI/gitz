//! Private URL helpers ported from go-git `internal/url` (v5.19.2).
//!
//! Kept inside `plumbing/transport` (no `internal/url` package).

const std = @import("std");
const builtin = @import("builtin");

/// go-git `internal/url.MatchesScheme` — true when `s` looks like `scheme://…`.
pub fn matchesScheme(s: []const u8) bool {
    // `^[^:]+://`
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return false;
    if (colon == 0) return false;
    if (colon + 2 >= s.len) return false;
    return s[colon + 1] == '/' and s[colon + 2] == '/';
}

/// go-git `internal/url.MatchesScpLike`.
pub fn matchesScpLike(s: []const u8) bool {
    if (!matchScpLikeRegex(s)) return false;

    // Mirror canonical Git's url_is_local_not_ssh: `/` before first `:` ⇒ local.
    if (std.mem.indexOfScalar(u8, s, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, s[0..colon], '/') != null) return false;
    } else {
        return false;
    }

    if (builtin.os.tag == .windows and hasDosDrivePrefix(s)) return false;
    return true;
}

/// go-git `internal/url.FindScpLikeComponents`.
/// Returns user, host, port, path (slices into `s`; may be empty).
pub fn findScpLikeComponents(s: []const u8) struct {
    user: []const u8,
    host: []const u8,
    port: []const u8,
    path: []const u8,
} {
    // Regex: `^(?:(?P<user>[^@]+)@)?(?P<host>[^:\s]+):(?:(?P<port>[0-9]{1,5}):)?(?P<path>[^\\].*)$`
    var i: usize = 0;
    var user: []const u8 = "";
    // Optional user@
    if (std.mem.indexOfScalar(u8, s, '@')) |at| {
        // Only treat as user if '@' is before the first ':' of host:path
        const first_colon = std.mem.indexOfScalar(u8, s, ':') orelse return .{ .user = "", .host = "", .port = "", .path = "" };
        if (at < first_colon) {
            user = s[0..at];
            i = at + 1;
        }
    }

    // Host: [^:\s]+
    const host_start = i;
    while (i < s.len and s[i] != ':' and s[i] != ' ' and s[i] != '\t') : (i += 1) {}
    const host = s[host_start..i];
    if (host.len == 0 or i >= s.len or s[i] != ':') {
        return .{ .user = user, .host = host, .port = "", .path = "" };
    }
    i += 1; // skip ':'

    // Optional port: (?:(?P<port>[0-9]{1,5}):)?
    var port: []const u8 = "";
    var path: []const u8 = "";
    if (looksLikeScpPortPrefix(s[i..])) |port_end| {
        port = s[i .. i + port_end];
        i += port_end + 1; // skip digits and trailing ':'
        path = s[i..];
    } else {
        path = s[i..];
    }

    // Path must match [^\\].* (no leading backslash; non-empty for full match)
    if (path.len == 0 or path[0] == '\\') {
        return .{ .user = user, .host = host, .port = "", .path = path };
    }

    return .{ .user = user, .host = host, .port = port, .path = path };
}

/// go-git `internal/url.IsLocalEndpoint`.
pub fn isLocalEndpoint(s: []const u8) bool {
    return !matchesScheme(s) and !matchesScpLike(s);
}

fn hasDosDrivePrefix(s: []const u8) bool {
    if (s.len < 2 or s[1] != ':') return false;
    const c = s[0];
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

/// Full SCP-like shape check (before local-path disambiguation).
fn matchScpLikeRegex(s: []const u8) bool {
    // `^(?:(?P<user>[^@]+)@)?(?P<host>[^:\s]+):(?:(?P<port>[0-9]{1,5}):)?(?P<path>[^\\].*)$`
    if (s.len == 0) return false;

    var i: usize = 0;
    // Optional user@
    if (std.mem.indexOfScalar(u8, s, '@')) |at| {
        const first_colon = std.mem.indexOfScalar(u8, s, ':') orelse return false;
        if (at < first_colon) {
            if (at == 0) return false; // user must be [^@]+
            // user chars: anything except @
            i = at + 1;
        }
    }

    // Host: [^:\s]+
    const host_start = i;
    while (i < s.len and s[i] != ':' and s[i] != ' ' and s[i] != '\t') : (i += 1) {}
    if (i == host_start) return false;
    if (i >= s.len or s[i] != ':') return false;
    i += 1;

    // Optional port digits + ':'
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
    // Need a trailing ':' after the digits for the optional port group.
    if (n >= rest.len or rest[n] != ':') return null;
    // Digits must be 1..5 (regex {1,5}); n is already capped.
    return n;
}

test "matchesScheme" {
    try std.testing.expect(matchesScheme("http://example.com"));
    try std.testing.expect(matchesScheme("file:///foo"));
    try std.testing.expect(!matchesScheme("git@github.com:user/repo.git"));
    try std.testing.expect(!matchesScheme("/foo.git"));
    try std.testing.expect(!matchesScheme("C:\\foo.git"));
}

test "matchesScpLike" {
    try std.testing.expect(matchesScpLike("git@github.com:user/repo.git"));
    try std.testing.expect(matchesScpLike("github.com:user/repo.git"));
    try std.testing.expect(matchesScpLike("git@github.com:8080:9999/user/repo.git"));
    // go-git regex also matches `http://…` as host=http path=//…; scheme filtering
    // is done by MatchesScheme / NewEndpoint, not MatchesScpLike.
    try std.testing.expect(matchesScpLike("http://github.com/user/repo.git"));
    try std.testing.expect(!matchesScpLike("/abs/with:colon/file"));
    try std.testing.expect(!matchesScpLike("./relative:path"));
}

test "findScpLikeComponents" {
    {
        const c = findScpLikeComponents("git@github.com:user/repository.git");
        try std.testing.expectEqualStrings("git", c.user);
        try std.testing.expectEqualStrings("github.com", c.host);
        try std.testing.expectEqualStrings("", c.port);
        try std.testing.expectEqualStrings("user/repository.git", c.path);
    }
    {
        const c = findScpLikeComponents("git@github.com:8080:9999/user/repository.git");
        try std.testing.expectEqualStrings("git", c.user);
        try std.testing.expectEqualStrings("github.com", c.host);
        try std.testing.expectEqualStrings("8080", c.port);
        try std.testing.expectEqualStrings("9999/user/repository.git", c.path);
    }
    {
        const c = findScpLikeComponents("git@github.com:9999/user/repository.git");
        try std.testing.expectEqualStrings("git", c.user);
        try std.testing.expectEqualStrings("github.com", c.host);
        try std.testing.expectEqualStrings("", c.port);
        try std.testing.expectEqualStrings("9999/user/repository.git", c.path);
    }
}
