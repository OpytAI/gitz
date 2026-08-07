//! URL rewrite rules (insteadOf).
//!
//! Port of go-git v5.19.2 `config/url.go` + `config/url_test.go`.

const std = @import("std");
const format_config = @import("config");
const owned = @import("owned.zig");

const Allocator = std.mem.Allocator;
const Subsection = format_config.Subsection;
const setOwned = owned.setOwned;
const freeOwned = owned.freeOwned;

const instead_of_key = "insteadOf";

/// URL rewrite errors.
pub const Error = error{
    /// go-git `errURLEmptyInsteadOf`.
    URLEmptyInsteadOf,
};

/// URL rewrite rule (go-git `URL`).
pub const URL = struct {
    allocator: Allocator,
    /// New base URL (subsection name).
    name: []const u8 = "",
    /// Prefix replaced by `name` when matched (longest wins).
    instead_of: []const u8 = "",
    /// Borrowed subsection in raw config (not owned).
    raw: ?*Subsection = null,

    pub fn init(allocator: Allocator) URL {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *URL) void {
        freeOwned(self.allocator, &self.name);
        freeOwned(self.allocator, &self.instead_of);
        self.raw = null;
        self.* = undefined;
    }

    /// go-git `URL.Validate`.
    pub fn validate(self: *const URL) Error!void {
        if (self.instead_of.len == 0) return error.URLEmptyInsteadOf;
    }

    /// go-git `URL.unmarshal`.
    pub fn unmarshal(self: *URL, s: *Subsection) Allocator.Error!void {
        self.raw = s;
        try setOwned(self.allocator, &self.name, s.name);
        try setOwned(self.allocator, &self.instead_of, s.option(instead_of_key));
    }

    /// go-git `URL.marshal` — updates `raw` in place; creates if null.
    pub fn marshal(self: *URL) Allocator.Error!*Subsection {
        if (self.raw == null) {
            self.raw = try Subsection.create(self.allocator, self.name);
        }
        const r = self.raw.?;
        if (!std.mem.eql(u8, r.name, self.name)) {
            self.allocator.free(r.name);
            r.name = try self.allocator.dupe(u8, self.name);
        }
        const values = [_][]const u8{self.instead_of};
        _ = try r.setOption(instead_of_key, &values);
        return r;
    }

    /// go-git `ApplyInsteadOf`.
    ///
    /// When the rule matches, returns a newly allocated rewritten string
    /// (caller frees). When it does not match, returns a dupe of `remote_url`
    /// (always owned — simpler than mixed ownership).
    pub fn applyInsteadOf(
        self: *const URL,
        allocator: Allocator,
        remote_url: []const u8,
    ) Allocator.Error![]u8 {
        if (!std.mem.startsWith(u8, remote_url, self.instead_of)) {
            return try allocator.dupe(u8, remote_url);
        }
        return try std.fmt.allocPrint(allocator, "{s}{s}", .{
            self.name,
            remote_url[self.instead_of.len..],
        });
    }
};

/// go-git `findLongestInsteadOfMatch`.
pub fn findLongestInsteadOfMatch(
    remote_url: []const u8,
    urls: *const std.StringHashMapUnmanaged(*URL),
) ?*URL {
    var longest: ?*URL = null;
    var it = urls.iterator();
    while (it.next()) |e| {
        const u = e.value_ptr.*;
        if (!std.mem.startsWith(u8, remote_url, u.instead_of)) continue;
        if (longest == null or longest.?.instead_of.len < u.instead_of.len) {
            longest = u;
        }
    }
    return longest;
}

// ---------------------------------------------------------------------------
// Tests (go-git config/url_test.go)
// ---------------------------------------------------------------------------

test "URL.Validate insteadOf" {
    // go-git TestValidateInsteadOf
    const gpa = std.testing.allocator;
    var good = URL.init(gpa);
    defer good.deinit();
    try setOwned(gpa, &good.name, "ssh://github.com");
    try setOwned(gpa, &good.instead_of, "http://github.com");
    try good.validate();

    var bad = URL.init(gpa);
    defer bad.deinit();
    try std.testing.expectError(error.URLEmptyInsteadOf, bad.validate());
}

test "URL marshal via format config" {
    // go-git TestMarshal (Config path: core bare + url section)
    const gpa = std.testing.allocator;
    // Format encoder indents options with a tab (go-git format/config).
    const expected =
        "[core]\n" ++
        "\tbare = false\n" ++
        "[url \"ssh://git@github.com/\"]\n" ++
        "\tinsteadOf = https://github.com/\n";

    var raw = format_config.Config.init(gpa);
    defer raw.deinit();
    _ = try raw.setOption("core", format_config.NoSubsection, "bare", "false");

    var rule = URL.init(gpa);
    defer rule.deinit();
    try setOwned(gpa, &rule.name, "ssh://git@github.com/");
    try setOwned(gpa, &rule.instead_of, "https://github.com/");
    const ss = try rule.marshal();
    const url_sec = try raw.section("url");
    try url_sec.subsections.append(url_sec.allocator, ss);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = format_config.Encoder.init(&aw.writer);
    try enc.encode(&raw);
    try std.testing.expectEqualStrings(expected, aw.written());
}

test "URL unmarshal via format config" {
    // go-git TestUnmarshal
    const gpa = std.testing.allocator;
    const input =
        \\[core]
        \\    bare = false
        \\[url "ssh://git@github.com/"]
        \\    insteadOf = https://github.com/
        \\
    ;

    var raw = format_config.Config.init(gpa);
    defer raw.deinit();
    var r = std.Io.Reader.fixed(input);
    var dec = format_config.Decoder.init(&r);
    try dec.decode(&raw);

    const url_sec = try raw.section("url");
    try std.testing.expectEqual(@as(usize, 1), url_sec.subsections.items.len);

    var rule = URL.init(gpa);
    defer rule.deinit();
    try rule.unmarshal(url_sec.subsections.items[0]);
    try std.testing.expectEqualStrings("ssh://git@github.com/", rule.name);
    try std.testing.expectEqualStrings("https://github.com/", rule.instead_of);
}

test "URL.ApplyInsteadOf" {
    // go-git TestApplyInsteadOf
    const gpa = std.testing.allocator;
    var rule = URL.init(gpa);
    defer rule.deinit();
    try setOwned(gpa, &rule.name, "ssh://github.com");
    try setOwned(gpa, &rule.instead_of, "http://github.com");

    const unchanged = try rule.applyInsteadOf(gpa, "http://google.com");
    defer gpa.free(unchanged);
    try std.testing.expectEqualStrings("http://google.com", unchanged);

    const rewritten = try rule.applyInsteadOf(gpa, "http://github.com/myrepo");
    defer gpa.free(rewritten);
    try std.testing.expectEqualStrings("ssh://github.com/myrepo", rewritten);
}

test "findLongestInsteadOfMatch" {
    const gpa = std.testing.allocator;
    var map: std.StringHashMapUnmanaged(*URL) = .empty;
    defer {
        var it = map.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            gpa.destroy(e.value_ptr.*);
            gpa.free(e.key_ptr.*);
        }
        map.deinit(gpa);
    }

    const short = try gpa.create(URL);
    short.* = URL.init(gpa);
    try setOwned(gpa, &short.name, "ssh://gh/");
    try setOwned(gpa, &short.instead_of, "http://gh/");
    try map.put(gpa, try gpa.dupe(u8, short.name), short);

    const longer = try gpa.create(URL);
    longer.* = URL.init(gpa);
    try setOwned(gpa, &longer.name, "ssh://github.com/");
    try setOwned(gpa, &longer.instead_of, "http://github.com/");
    try map.put(gpa, try gpa.dupe(u8, longer.name), longer);

    const hit = findLongestInsteadOfMatch("http://github.com/foo", &map);
    try std.testing.expect(hit == longer);

    const miss = findLongestInsteadOfMatch("https://example.com/", &map);
    try std.testing.expect(miss == null);

    const applied = try longer.applyInsteadOf(gpa, "http://github.com/org/repo.git");
    defer gpa.free(applied);
    try std.testing.expectEqualStrings("ssh://github.com/org/repo.git", applied);
}
