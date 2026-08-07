//! Submodules and .gitmodules.
//!
//! Port of go-git v5.19.2 `config/modules.go` + `config/modules_test.go`.

const std = @import("std");
const format_config = @import("config");
const pathutil = @import("pathutil");
const owned = @import("owned.zig");

const Allocator = std.mem.Allocator;
const Subsection = format_config.Subsection;
const setOwned = owned.setOwned;
const freeOwned = owned.freeOwned;

const submodule_section = "submodule";
/// Config key for submodule path (also used by Config.marshalSubmodules).
pub const path_key = "path";
const url_key = "url";
const branch_key = "branch";

/// Submodule / modules errors (go-git package vars).
pub const Error = error{
    /// go-git `ErrModuleEmptyURL`.
    ModuleEmptyURL,
    /// go-git `ErrModuleEmptyPath`.
    ModuleEmptyPath,
    /// go-git `ErrModuleBadPath`.
    ModuleBadPath,
    /// go-git `ErrModuleBadName`.
    ModuleBadName,
};

/// Submodule entry (go-git `Submodule`).
pub const Submodule = struct {
    allocator: Allocator,
    name: []const u8 = "",
    path: []const u8 = "",
    url: []const u8 = "",
    branch: []const u8 = "",
    /// Borrowed subsection in raw config (not owned).
    raw: ?*Subsection = null,

    pub fn init(allocator: Allocator) Submodule {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Submodule) void {
        freeOwned(self.allocator, &self.name);
        freeOwned(self.allocator, &self.path);
        freeOwned(self.allocator, &self.url);
        freeOwned(self.allocator, &self.branch);
        self.raw = null;
        self.* = undefined;
    }

    /// go-git `Submodule.Validate`.
    pub fn validate(self: *const Submodule) Error!void {
        try validSubmoduleName(self.name);
        if (self.path.len == 0) return error.ModuleEmptyPath;
        if (self.url.len == 0) return error.ModuleEmptyURL;
        if (hasDotDotPath(self.path)) return error.ModuleBadPath;
    }

    /// go-git `Submodule.unmarshal`.
    pub fn unmarshal(self: *Submodule, s: *Subsection) Allocator.Error!void {
        self.raw = s;
        try setOwned(self.allocator, &self.name, s.name);
        try setOwned(self.allocator, &self.path, s.option(path_key));
        try setOwned(self.allocator, &self.url, s.option(url_key));
        try setOwned(self.allocator, &self.branch, s.option(branch_key));
    }

    /// go-git `Submodule.marshal`.
    ///
    /// Reuses `raw` when set so extra options (e.g. `ignore`) survive a
    /// round-trip — go-git only SetOption path/url/branch on the same subsection.
    pub fn marshal(self: *Submodule) Allocator.Error!*Subsection {
        const want_name = if (self.name.len > 0) self.name else self.path;
        if (self.raw == null) {
            self.raw = try Subsection.create(self.allocator, want_name);
        }
        const r = self.raw.?;
        if (!std.mem.eql(u8, r.name, want_name)) {
            self.allocator.free(r.name);
            r.name = try self.allocator.dupe(u8, want_name);
        }

        {
            const values = [_][]const u8{self.path};
            _ = try r.setOption(path_key, &values);
        }
        {
            const values = [_][]const u8{self.url};
            _ = try r.setOption(url_key, &values);
        }
        if (self.branch.len == 0) {
            _ = r.removeOption(branch_key);
        } else {
            const values = [_][]const u8{self.branch};
            _ = try r.setOption(branch_key, &values);
        }
        return r;
    }
};

/// .gitmodules file model (go-git `Modules`).
pub const Modules = struct {
    allocator: Allocator,
    submodules: std.StringHashMapUnmanaged(*Submodule) = .empty,
    raw: *format_config.Config,

    /// go-git `NewModules` — empty modules file (owns the raw format tree).
    pub fn create(allocator: Allocator) Allocator.Error!Modules {
        const raw = try allocator.create(format_config.Config);
        raw.* = format_config.Config.init(allocator);
        return .{ .allocator = allocator, .raw = raw };
    }

    pub fn deinit(self: *Modules) void {
        clearSubmodules(self);
        self.submodules.deinit(self.allocator);
        self.raw.deinit();
        self.allocator.destroy(self.raw);
        self.* = undefined;
    }

    /// go-git `Modules.Unmarshal`.
    pub fn unmarshal(self: *Modules, data: []const u8) (Allocator.Error || format_config.Error)!void {
        clearSubmodules(self);

        self.raw.deinit();
        self.raw.* = format_config.Config.init(self.allocator);

        var r: std.Io.Reader = .fixed(data);
        var dec = format_config.Decoder.init(&r);
        try dec.decode(self.raw);

        try unmarshalSubmodules(self.allocator, self.raw, &self.submodules);
    }

    /// go-git `Modules.Marshal`.
    ///
    /// Rebuilds the submodule section from the map while **reusing** each
    /// Submodule's existing `raw` subsection when present so non-modeled
    /// options (e.g. `ignore`) are preserved.
    pub fn marshal(self: *Modules) (Allocator.Error || std.Io.Writer.Error)![]u8 {
        const s = try self.raw.section(submodule_section);

        var new_subs: std.ArrayList(*Subsection) = .empty;
        errdefer {
            for (new_subs.items) |ss| {
                var was_old = false;
                for (s.subsections.items) |old| {
                    if (old == ss) {
                        was_old = true;
                        break;
                    }
                }
                if (!was_old) {
                    // Clear Submodule.raw if it points here.
                    var it = self.submodules.iterator();
                    while (it.next()) |e| {
                        if (e.value_ptr.*.raw == ss) e.value_ptr.*.raw = null;
                    }
                    ss.destroy();
                }
            }
            new_subs.deinit(self.allocator);
        }

        var it = self.submodules.iterator();
        while (it.next()) |e| {
            const ss = try e.value_ptr.*.marshal();
            try new_subs.append(self.allocator, ss);
        }

        // Free old subsections that are not reused.
        for (s.subsections.items) |old| {
            var keep = false;
            for (new_subs.items) |n| {
                if (n == old) {
                    keep = true;
                    break;
                }
            }
            if (!keep) {
                var sit = self.submodules.iterator();
                while (sit.next()) |e| {
                    if (e.value_ptr.*.raw == old) e.value_ptr.*.raw = null;
                }
                old.destroy();
            }
        }
        s.subsections.clearRetainingCapacity();
        try s.subsections.appendSlice(s.allocator, new_subs.items);
        new_subs.deinit(self.allocator);

        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        var enc = format_config.Encoder.init(&aw.writer);
        try enc.encode(self.raw);
        return try aw.toOwnedSlice();
    }
};

/// go-git `unmarshalSubmodules` — used by Config and Modules.
///
/// Entries with `ErrModuleBadPath` or `ErrModuleBadName` are dropped; other
/// validate errors (empty path/URL) still add the entry.
pub fn unmarshalSubmodules(
    allocator: Allocator,
    fc: *format_config.Config,
    submodules: *std.StringHashMapUnmanaged(*Submodule),
) Allocator.Error!void {
    if (!fc.hasSection(submodule_section)) return;
    const s = try fc.section(submodule_section);
    for (s.subsections.items) |sub| {
        const m = try allocator.create(Submodule);
        m.* = Submodule.init(allocator);
        var keep = false;
        defer if (!keep) {
            m.deinit();
            allocator.destroy(m);
        };
        try m.unmarshal(sub);

        const skip = blk: {
            m.validate() catch |err| switch (err) {
                error.ModuleBadPath, error.ModuleBadName => break :blk true,
                error.ModuleEmptyPath, error.ModuleEmptyURL => break :blk false,
            };
            break :blk false;
        };
        if (skip) continue;

        const key = try allocator.dupe(u8, m.name);
        errdefer allocator.free(key);
        try submodules.put(allocator, key, m);
        keep = true;
    }
}

fn validSubmoduleName(name: []const u8) Error!void {
    if (name.len == 0 or std.mem.eql(u8, name, ".")) return error.ModuleBadName;

    // go-git: strings.FieldsFunc(name, isPathSep) then IsHFSDot/IsNTFSDot per seg.
    var start: usize = 0;
    var i: usize = 0;
    while (i <= name.len) : (i += 1) {
        if (i == name.len or isPathSep(name[i])) {
            if (i > start) {
                const seg = name[start..i];
                if (pathutil.isHFSDot(seg, ".") or pathutil.isNTFSDot(seg, ".", "")) {
                    return error.ModuleBadName;
                }
            }
            start = i + 1;
        }
    }

    // go-git-specific defensive checks beyond canonical Git.
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.ModuleBadName;
    if (isPathSep(name[0]) or isPathSep(name[name.len - 1])) return error.ModuleBadName;
    if (name.len >= 2 and name[1] == ':') return error.ModuleBadName;
}

fn isPathSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// go-git `dotdotPath` regex: `(^|[/\\])\.\.([/\\]|$)`.
fn hasDotDotPath(path: []const u8) bool {
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        const at_boundary = (i == 0) or isPathSep(path[i - 1]);
        if (!at_boundary) continue;
        if (i + 1 >= path.len) continue;
        if (path[i] != '.' or path[i + 1] != '.') continue;
        const after = i + 2;
        if (after == path.len or isPathSep(path[after])) return true;
    }
    return false;
}

fn clearSubmodules(self: *Modules) void {
    var it = self.submodules.iterator();
    while (it.next()) |e| {
        e.value_ptr.*.deinit();
        self.allocator.destroy(e.value_ptr.*);
        self.allocator.free(e.key_ptr.*);
    }
    self.submodules.clearRetainingCapacity();
}

// ---------------------------------------------------------------------------
// Tests (go-git config/modules_test.go)
// ---------------------------------------------------------------------------

test "Submodule.Validate missing URL" {
    // go-git TestValidateMissingURL
    const gpa = std.testing.allocator;
    var m = Submodule.init(gpa);
    defer m.deinit();
    try setOwned(gpa, &m.name, "foo");
    try setOwned(gpa, &m.path, "foo");
    try std.testing.expectError(error.ModuleEmptyURL, m.validate());
}

test "Submodule.Validate bad path" {
    // go-git TestValidateBadPath
    const gpa = std.testing.allocator;
    const paths = [_][]const u8{
        "..",
        "../",
        "../bar",
        "/..",
        "/../bar",
        "foo/..",
        "foo/../",
        "foo/../bar",
    };
    for (paths) |p| {
        var m = Submodule.init(gpa);
        defer m.deinit();
        try setOwned(gpa, &m.name, "ok");
        try setOwned(gpa, &m.path, p);
        try setOwned(gpa, &m.url, "https://example.com/");
        try std.testing.expectError(error.ModuleBadPath, m.validate());
    }
}

test "Submodule.Validate missing path" {
    // go-git TestValidateMissingName (empty path)
    const gpa = std.testing.allocator;
    var m = Submodule.init(gpa);
    defer m.deinit();
    try setOwned(gpa, &m.name, "ok");
    try setOwned(gpa, &m.url, "bar");
    try std.testing.expectError(error.ModuleEmptyPath, m.validate());
}

test "Submodule.Validate bad name" {
    // go-git TestValidateBadName
    const gpa = std.testing.allocator;
    const names = [_][]const u8{
        "",
        ".",
        "..",
        "../x",
        "a/../../b",
        "/abs",
        "C:\\win",
        "x\x00y",
        "x/",
        "/x",
        ".\\..\\foo",
        "modules/../escape",
        // HFS+ ignored code points → ".."
        ".\u{200c}.",
        "\u{200c}..",
        "..\u{200c}",
        "\u{200c}.\u{200d}.\u{200e}",
        "a/.\u{200c}./b",
        // NTFS trailing space/dot/ADS → ".."
        ".. ",
        "..  ",
        "....",
        ".. .",
        "..::$INDEX_ALLOCATION",
        "..:foo",
        "a/.. /b",
    };
    for (names) |n| {
        var m = Submodule.init(gpa);
        defer m.deinit();
        try setOwned(gpa, &m.name, n);
        try setOwned(gpa, &m.path, "ok");
        try setOwned(gpa, &m.url, "https://example.com/");
        try std.testing.expectError(error.ModuleBadName, m.validate());
    }
}

test "Submodule.Validate good name" {
    // go-git TestValidateGoodName
    const gpa = std.testing.allocator;
    const names = [_][]const u8{ "foo", "lib-foo", "deps/x", "x.y" };
    for (names) |n| {
        var m = Submodule.init(gpa);
        defer m.deinit();
        try setOwned(gpa, &m.name, n);
        try setOwned(gpa, &m.path, "ok");
        try setOwned(gpa, &m.url, "https://example.com/");
        try m.validate();
    }
}

test "Modules.Marshal" {
    // go-git TestMarshal
    const gpa = std.testing.allocator;
    const expected =
        "[submodule \"qux\"]\n" ++
        "\tpath = qux\n" ++
        "\turl = baz\n" ++
        "\tbranch = bar\n";

    var cfg = try Modules.create(gpa);
    defer cfg.deinit();

    const sm = try gpa.create(Submodule);
    sm.* = Submodule.init(gpa);
    try setOwned(gpa, &sm.path, "qux");
    try setOwned(gpa, &sm.url, "baz");
    try setOwned(gpa, &sm.branch, "bar");
    try cfg.submodules.put(gpa, try gpa.dupe(u8, "qux"), sm);

    const output = try cfg.marshal();
    defer gpa.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "Modules.Unmarshal filters suspicious" {
    // go-git TestUnmarshal
    const gpa = std.testing.allocator;
    const input =
        \\[submodule "qux"]
        \\        path = qux
        \\        url = https://github.com/foo/qux.git
        \\[submodule "foo/bar"]
        \\        path = foo/bar
        \\        url = https://github.com/foo/bar.git
        \\        branch = dev
        \\[submodule "suspicious"]
        \\        path = ../../foo/bar
        \\        url = https://github.com/foo/bar.git
        \\[submodule ".."]
        \\        path = deps/x
        \\        url = https://github.com/foo/bar.git
        \\
    ;

    var cfg = try Modules.create(gpa);
    defer cfg.deinit();
    try cfg.unmarshal(input);

    try std.testing.expectEqual(@as(usize, 2), cfg.submodules.count());

    const qux = cfg.submodules.get("qux").?;
    try std.testing.expectEqualStrings("qux", qux.name);
    try std.testing.expectEqualStrings("https://github.com/foo/qux.git", qux.url);

    const foobar = cfg.submodules.get("foo/bar").?;
    try std.testing.expectEqualStrings("foo/bar", foobar.name);
    try std.testing.expectEqualStrings("https://github.com/foo/bar.git", foobar.url);
    try std.testing.expectEqualStrings("dev", foobar.branch);

    try std.testing.expect(cfg.submodules.get("..") == null);
    try std.testing.expect(cfg.submodules.get("suspicious") == null);
}

test "Modules Unmarshal then Marshal preserves extras" {
    // go-git TestUnmarshalMarshal
    const gpa = std.testing.allocator;
    // Input may use spaces; marshal re-encodes with tab indent (go-git).
    const input =
        \\[submodule "foo/bar"]
        \\    path = foo/bar
        \\    url = https://github.com/foo/bar.git
        \\    ignore = all
        \\
    ;
    const expected =
        "[submodule \"foo/bar\"]\n" ++
        "\tpath = foo/bar\n" ++
        "\turl = https://github.com/foo/bar.git\n" ++
        "\tignore = all\n";

    var cfg = try Modules.create(gpa);
    defer cfg.deinit();
    try cfg.unmarshal(input);

    const output = try cfg.marshal();
    defer gpa.free(output);
    try std.testing.expectEqualStrings(expected, output);
}
