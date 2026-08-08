//! Relative submodule URL resolution (go-git `submodule.go` Repository path).
//!
//! Mirrors Git `resolve_relative_url` / go-git:
//! when the configured submodule URL is a relative local path (`../X.git`),
//! join it onto the parent repository's default remote URL path.
//!
//! Detection uses the **raw** configured URL (go-git): `transport.NewEndpoint`
//! may absolutize local paths, which would hide relativity.
//!
//! Edge cases (go-git + Git path.Clean semantics):
//! - Empty raw → not relative (caller treats as empty URL).
//! - Scheme / SCP-like → not relative (used as-is).
//! - Leading `/` or OS-absolute → not relative (preserved as-is).
//! - `../` past the root of an absolute URL path stops at `/`.
//! - Parent remote missing or with zero URLs → `ParentRemote*`.

const std = @import("std");
const memory = @import("memory");
const transport = @import("transport");
const giturl = @import("url");
const plumbing = @import("plumbing");

const Allocator = std.mem.Allocator;
const Config = memory.Config;
const RemoteConfig = memory.RemoteConfig;

/// Errors for relative URL resolution (go-git wrapped messages).
pub const Error = error{
    /// Chosen parent remote name is not configured.
    ParentRemoteNotFound,
    /// Parent remote has no URL list.
    ParentRemoteEmptyURL,
};

/// go-git `DefaultRemoteName`.
pub const default_remote_name: []const u8 = "origin";

/// True when `raw` must be resolved against the parent remote (go-git check).
///
/// Relative when `IsLocalEndpoint` and not absolute (posix path.IsAbs or OS Abs).
pub fn isRelativeSubmoduleURL(raw: []const u8) bool {
    if (raw.len == 0) return false;
    if (!giturl.isLocalEndpoint(raw)) return false;
    // path.IsAbs: slash-leading (Go path package, URL-style).
    if (raw[0] == '/') return false;
    // filepath.IsAbs: OS absolute (drive letter, etc.).
    if (std.fs.path.isAbsolute(raw)) return false;
    return true;
}

/// go-git `defaultRemote` / Git `repo_default_remote`:
/// 1. HEAD branch → `branch.<name>.remote` when non-empty
/// 2. else if exactly one remote, use it
/// 3. else `"origin"`
///
/// Returns a pointer into `cfg.remotes` (borrowed). Errors when the chosen
/// remote is missing or has no URLs.
pub fn defaultRemote(cfg: *const Config, head: ?plumbing.Reference) Error!*const RemoteConfig {
    if (head) |ref| {
        // go-git: HEAD symbolic → branch target, then branch.<name>.remote.
        if (ref.type == .symbolic and ref.target.isBranch()) {
            const short = ref.target.short();
            if (cfg.branches.get(short)) |*b| {
                if (b.remote.len > 0) {
                    return lookupRemote(cfg, b.remote);
                }
            }
        }
    }

    if (cfg.remotes.count() == 1) {
        var it = cfg.remotes.iterator();
        if (it.next()) |e| {
            return lookupRemote(cfg, e.key_ptr.*);
        }
    }

    return lookupRemote(cfg, default_remote_name);
}

fn lookupRemote(cfg: *const Config, name: []const u8) Error!*const RemoteConfig {
    const rc = cfg.remotes.getPtr(name) orelse return error.ParentRemoteNotFound;
    if (rc.urls.len == 0) return error.ParentRemoteEmptyURL;
    return rc;
}

/// Join a relative submodule URL onto a parent remote URL (owned result).
///
/// go-git: parse parent with `NewEndpoint`, `path.Join(root.Path, relative)`,
/// then `Endpoint.String()`. Only the path component is rewritten; scheme,
/// user, host, and port come from the parent endpoint.
pub fn resolveRelativeURL(
    allocator: Allocator,
    io: std.Io,
    parent_url: []const u8,
    relative: []const u8,
) (Allocator.Error || transport.Error)![]u8 {
    var root = try transport.newEndpoint(allocator, io, parent_url);
    defer root.deinit();

    const joined = try joinUrlPath(allocator, root.path, relative);
    // Transfer ownership into endpoint (freed by root.deinit).
    if (root.path.len != 0) allocator.free(root.path);
    root.path = joined;

    return try root.string(allocator);
}

/// Resolve `raw` submodule URL against superproject config when relative.
///
/// Non-relative URLs are duplicated as-is. Relative URLs need a parent remote.
/// Caller owns the returned slice.
pub fn resolveSubmoduleURL(
    allocator: Allocator,
    io: std.Io,
    super_cfg: *const Config,
    head: ?plumbing.Reference,
    raw: []const u8,
) (Allocator.Error || Error || transport.Error)![]u8 {
    if (!isRelativeSubmoduleURL(raw)) {
        return try allocator.dupe(u8, raw);
    }
    const base = try defaultRemote(super_cfg, head);
    return resolveRelativeURL(allocator, io, base.urls[0], raw);
}

/// Go `path.Join` + Clean for slash-separated URL paths (not OS filepath).
fn joinUrlPath(allocator: Allocator, base: []const u8, rel: []const u8) Allocator.Error![]u8 {
    // Concatenate then clean `.` / `..` components (always `/` separator).
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);

    if (base.len > 0) {
        try raw.appendSlice(allocator, base);
        if (base[base.len - 1] != '/' and (rel.len == 0 or rel[0] != '/')) {
            try raw.append(allocator, '/');
        }
    }
    try raw.appendSlice(allocator, rel);

    return try cleanSlashPath(allocator, raw.items);
}

/// Clean a slash path: collapse `/./`, resolve `..`, keep leading `/` if present.
/// Mirrors Go `path.Clean` for submodule URL path joins.
fn cleanSlashPath(allocator: Allocator, path: []const u8) Allocator.Error![]u8 {
    const abs = path.len > 0 and path[0] == '/';
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0) {
                _ = parts.pop();
            } else if (!abs) {
                try parts.append(allocator, "..");
            }
            continue;
        }
        try parts.append(allocator, seg);
    }

    if (parts.items.len == 0) {
        return try allocator.dupe(u8, if (abs) "/" else ".");
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (abs) try out.append(allocator, '/');
    for (parts.items, 0..) |p, i| {
        if (i > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, p);
    }
    return try out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "isRelativeSubmoduleURL" {
    try std.testing.expect(isRelativeSubmoduleURL("../X.git"));
    try std.testing.expect(isRelativeSubmoduleURL("../../org/X.git"));
    try std.testing.expect(isRelativeSubmoduleURL("child"));
    try std.testing.expect(!isRelativeSubmoduleURL("/abs/path/X.git"));
    try std.testing.expect(!isRelativeSubmoduleURL("https://example.com/a.git"));
    try std.testing.expect(!isRelativeSubmoduleURL("git@github.com:user/repo.git"));
    try std.testing.expect(!isRelativeSubmoduleURL(""));
}

test "joinUrlPath cleans parent traversal" {
    const gpa = std.testing.allocator;
    const a = try joinUrlPath(gpa, "/group/proj.git", "../X.git");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("/group/X.git", a);

    const b = try joinUrlPath(gpa, "/group/proj.git", "../../org/X.git");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("/org/X.git", b);

    const c = try joinUrlPath(gpa, "/parent/origin", "../child");
    defer gpa.free(c);
    try std.testing.expectEqualStrings("/parent/child", c);
}

test "resolveRelativeURL https parent" {
    const gpa = std.testing.allocator;
    const got = try resolveRelativeURL(
        gpa,
        std.testing.io,
        "https://example.invalid/group/proj.git",
        "../X.git",
    );
    defer gpa.free(got);
    try std.testing.expectEqualStrings("https://example.invalid/group/X.git", got);
}

test "resolveRelativeURL ssh parent" {
    const gpa = std.testing.allocator;
    const got = try resolveRelativeURL(
        gpa,
        std.testing.io,
        "ssh://git@example.invalid/group/proj.git",
        "../X.git",
    );
    defer gpa.free(got);
    try std.testing.expectEqualStrings("ssh://git@example.invalid/group/X.git", got);
}

test "defaultRemote picks origin with two remotes" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    try cfg.putRemote("origin", &[_][]const u8{"file:///parent/origin"});
    try cfg.putRemote("upstream", &[_][]const u8{"file:///parent/upstream"});

    const rc = try defaultRemote(&cfg, null);
    try std.testing.expectEqualStrings("origin", rc.name);
}

test "defaultRemote single remote" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    try cfg.putRemote("upstream", &[_][]const u8{"file:///only"});

    const rc = try defaultRemote(&cfg, null);
    try std.testing.expectEqualStrings("upstream", rc.name);
}

test "defaultRemote branch remote" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    try cfg.putRemote("origin", &[_][]const u8{"file:///origin"});
    try cfg.putRemote("upstream", &[_][]const u8{"file:///upstream"});
    try cfg.putBranch("main", "upstream", "refs/heads/main");

    const head = plumbing.Reference.newSymbolicReference(
        plumbing.HEAD,
        plumbing.ReferenceName.init("refs/heads/main"),
    );
    const rc = try defaultRemote(&cfg, head);
    try std.testing.expectEqualStrings("upstream", rc.name);
}

test "defaultRemote missing origin" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    try std.testing.expectError(error.ParentRemoteNotFound, defaultRemote(&cfg, null));
}

test "resolveSubmoduleURL absolute and relative" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    try cfg.putRemote("origin", &[_][]const u8{"https://example.invalid/group/proj.git"});

    const abs = try resolveSubmoduleURL(gpa, std.testing.io, &cfg, null, "https://other/x.git");
    defer gpa.free(abs);
    try std.testing.expectEqualStrings("https://other/x.git", abs);

    const rel = try resolveSubmoduleURL(gpa, std.testing.io, &cfg, null, "../X.git");
    defer gpa.free(rel);
    try std.testing.expectEqualStrings("https://example.invalid/group/X.git", rel);
}

test "resolveRelativeURL file parent" {
    const gpa = std.testing.allocator;
    const got = try resolveRelativeURL(
        gpa,
        std.testing.io,
        "file:///tmp/group/proj.git",
        "../X.git",
    );
    defer gpa.free(got);
    try std.testing.expectEqualStrings("file:///tmp/group/X.git", got);
}

test "resolveRelativeURL scp-like parent path without leading slash" {
    const gpa = std.testing.allocator;
    // SCP form → ssh endpoint; path is typically "group/proj.git" (no leading /).
    const got = try resolveRelativeURL(
        gpa,
        std.testing.io,
        "git@example.invalid:group/proj.git",
        "../X.git",
    );
    defer gpa.free(got);
    // Endpoint.String re-serializes; path join yields group/X.git.
    try std.testing.expect(std.mem.indexOf(u8, got, "group/X.git") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "proj.git") == null);
}

test "joinUrlPath edge cases" {
    const gpa = std.testing.allocator;

    const dot = try joinUrlPath(gpa, "/a/b", "./c");
    defer gpa.free(dot);
    try std.testing.expectEqualStrings("/a/b/c", dot);

    const over = try joinUrlPath(gpa, "/a/b", "../../..");
    defer gpa.free(over);
    try std.testing.expectEqualStrings("/", over);

    const empty_base = try joinUrlPath(gpa, "", "../X.git");
    defer gpa.free(empty_base);
    try std.testing.expectEqualStrings("../X.git", empty_base);

    const sibling = try joinUrlPath(gpa, "repo.git", "../sibling");
    defer gpa.free(sibling);
    try std.testing.expectEqualStrings("sibling", sibling);
}

test "resolveSubmoduleURL relative needs parent remote" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    try std.testing.expectError(
        error.ParentRemoteNotFound,
        resolveSubmoduleURL(gpa, std.testing.io, &cfg, null, "../X.git"),
    );
}

test "resolveSubmoduleURL parent remote empty URLs" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    // putRemote with empty url list is not allowed by putRemoteFull typically;
    // insert a remote shell with zero URLs via putRemoteFull empty slice.
    try cfg.putRemoteFull("origin", &[_][]const u8{}, &.{}, false);
    try std.testing.expectError(
        error.ParentRemoteEmptyURL,
        resolveSubmoduleURL(gpa, std.testing.io, &cfg, null, "../X.git"),
    );
}

test "isRelativeSubmoduleURL file scheme and scp are not relative" {
    try std.testing.expect(!isRelativeSubmoduleURL("file:///tmp/X.git"));
    try std.testing.expect(!isRelativeSubmoduleURL("file://tmp/X.git"));
    try std.testing.expect(isRelativeSubmoduleURL("./nested.git"));
    try std.testing.expect(isRelativeSubmoduleURL("nested/repo.git"));
}

test "resolveSubmoduleURL absolute local path not rewritten" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    try cfg.putRemote("origin", &[_][]const u8{"https://example.invalid/group/proj.git"});

    const abs = try resolveSubmoduleURL(gpa, std.testing.io, &cfg, null, "/abs/path/X.git");
    defer gpa.free(abs);
    try std.testing.expectEqualStrings("/abs/path/X.git", abs);
}
