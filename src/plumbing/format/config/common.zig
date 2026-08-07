//! Config tree and mutation helpers.
//!
//! Port of go-git v5.19.2 `plumbing/format/config/common.go`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const section_mod = @import("section.zig");

pub const Section = section_mod.Section;
pub const Subsection = section_mod.Subsection;
pub const Option = section_mod.Option;

/// Token passed when no subsection is wanted (go-git `NoSubsection`).
pub const NoSubsection: []const u8 = "";

/// Comment string without the prefix '#' or ';'.
pub const Comment = []const u8;

/// Reference to an included config file.
///
/// go-git format package stores path + nested Config; actual disk include
/// expansion is deferred to higher-level config loading (same as go-git format).
pub const Include = struct {
    path: []const u8,
    config: ?*Config = null,

    pub fn create(allocator: Allocator, path: []const u8, nested: ?*Config) Allocator.Error!*Include {
        const inc = try allocator.create(Include);
        errdefer allocator.destroy(inc);
        const p = try allocator.dupe(u8, path);
        inc.* = .{ .path = p, .config = nested };
        return inc;
    }

    pub fn destroy(self: *Include, allocator: Allocator) void {
        allocator.free(self.path);
        if (self.config) |cfg| {
            cfg.deinit();
            allocator.destroy(cfg);
        }
        allocator.destroy(self);
    }
};

/// All sections, comments and includes from a config file.
pub const Config = struct {
    allocator: Allocator,
    comment: ?[]const u8 = null,
    sections: std.ArrayList(*Section) = .empty,
    includes: std.ArrayList(*Include) = .empty,

    /// Create an empty config (go-git `New` / only construction path).
    pub fn init(allocator: Allocator) Config {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Config) void {
        if (self.comment) |c| self.allocator.free(c);
        for (self.sections.items) |s| s.destroy();
        self.sections.deinit(self.allocator);
        for (self.includes.items) |inc| inc.destroy(self.allocator);
        self.includes.deinit(self.allocator);
        self.* = undefined;
    }

    /// Existing section with `name` (case-insensitive) or a newly created one.
    pub fn section(self: *Config, name: []const u8) Allocator.Error!*Section {
        var i = self.sections.items.len;
        while (i > 0) {
            i -= 1;
            const s = self.sections.items[i];
            if (s.isName(name)) return s;
        }
        const s = try Section.create(self.allocator, name);
        errdefer s.destroy();
        try self.sections.append(self.allocator, s);
        return s;
    }

    pub fn hasSection(self: *const Config, name: []const u8) bool {
        for (self.sections.items) |s| {
            if (s.isName(name)) return true;
        }
        return false;
    }

    pub fn removeSection(self: *Config, name: []const u8) *Config {
        var i: usize = 0;
        while (i < self.sections.items.len) {
            if (self.sections.items[i].isName(name)) {
                const removed = self.sections.orderedRemove(i);
                removed.destroy();
            } else {
                i += 1;
            }
        }
        return self;
    }

    pub fn removeSubsection(self: *Config, section_name: []const u8, subsection_name: []const u8) *Config {
        for (self.sections.items) |s| {
            if (s.isName(section_name)) {
                _ = s.removeSubsection(subsection_name);
            }
        }
        return self;
    }

    /// Add an option. Use `NoSubsection` when no subsection is wanted.
    pub fn addOption(
        self: *Config,
        section_name: []const u8,
        subsection_name: []const u8,
        key: []const u8,
        value: []const u8,
    ) Allocator.Error!*Config {
        if (subsection_name.len == 0) {
            _ = try (try self.section(section_name)).addOption(key, value);
        } else {
            _ = try (try (try self.section(section_name)).subsection(subsection_name)).addOption(key, value);
        }
        return self;
    }

    /// Set an option (replace). Use `NoSubsection` when no subsection is wanted.
    pub fn setOption(
        self: *Config,
        section_name: []const u8,
        subsection_name: []const u8,
        key: []const u8,
        value: []const u8,
    ) Allocator.Error!*Config {
        if (subsection_name.len == 0) {
            _ = try (try self.section(section_name)).setOption(key, value);
        } else {
            const values = [_][]const u8{value};
            _ = try (try (try self.section(section_name)).subsection(subsection_name)).setOption(key, &values);
        }
        return self;
    }
};

// ---------------------------------------------------------------------------
// Tests (go-git common_test.go)
// ---------------------------------------------------------------------------

test "Config.setOption section" {
    // go-git TestConfig_SetOption (NoSubsection branch)
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    _ = try cfg.setOption("section", NoSubsection, "key1", "value1");
    try std.testing.expectEqual(@as(usize, 1), cfg.sections.items.len);
    try std.testing.expectEqualStrings("section", cfg.sections.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), cfg.sections.items[0].options.items.len);
    try std.testing.expectEqualStrings("key1", cfg.sections.items[0].options.items[0].key);
    try std.testing.expectEqualStrings("value1", cfg.sections.items[0].options.items[0].value);
    // Second set with same key/value keeps single option (withSettedOption).
    _ = try cfg.setOption("section", NoSubsection, "key1", "value1");
    try std.testing.expectEqual(@as(usize, 1), cfg.sections.items[0].options.items.len);
}

test "Config.setOption subsection" {
    // go-git TestConfig_SetOption (subsection branch)
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    _ = try cfg.setOption("section", "subsection", "key1", "value1");
    try std.testing.expectEqual(@as(usize, 1), cfg.sections.items.len);
    try std.testing.expectEqual(@as(usize, 0), cfg.sections.items[0].options.items.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.sections.items[0].subsections.items.len);
    try std.testing.expectEqualStrings("subsection", cfg.sections.items[0].subsections.items[0].name);
    try std.testing.expectEqualStrings("value1", cfg.sections.items[0].subsections.items[0].option("key1"));
    _ = try cfg.setOption("section", "subsection", "key1", "value1");
    try std.testing.expectEqual(@as(usize, 1), cfg.sections.items[0].subsections.items[0].options.items.len);
}

test "Config.addOption" {
    // go-git TestConfig_AddOption
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    _ = try cfg.addOption("section", NoSubsection, "key1", "value1");
    try std.testing.expectEqual(@as(usize, 1), cfg.sections.items.len);
    try std.testing.expectEqualStrings("section", cfg.sections.items[0].name);
    try std.testing.expectEqualStrings("key1", cfg.sections.items[0].options.items[0].key);
    try std.testing.expectEqualStrings("value1", cfg.sections.items[0].options.items[0].value);
}

test "Config.hasSection" {
    // go-git TestConfig_HasSection
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    _ = try cfg.addOption("section1", "sub1", "key1", "value1");
    _ = try cfg.addOption("section1", "sub2", "key1", "value1");
    try std.testing.expect(cfg.hasSection("section1"));
    try std.testing.expect(!cfg.hasSection("section2"));
}

test "Config.removeSection" {
    // go-git TestConfig_RemoveSection
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    _ = try cfg.addOption("section1", NoSubsection, "key1", "value1");
    _ = try cfg.addOption("section2", NoSubsection, "key1", "value1");
    _ = cfg.removeSection("other");
    try std.testing.expect(cfg.hasSection("section1"));
    try std.testing.expect(cfg.hasSection("section2"));
    _ = cfg.removeSection("section2");
    try std.testing.expect(cfg.hasSection("section1"));
    try std.testing.expect(!cfg.hasSection("section2"));
    try std.testing.expectEqual(@as(usize, 1), cfg.sections.items.len);
}

test "Config.removeSubsection" {
    // go-git TestConfig_RemoveSubsection
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    _ = try cfg.addOption("section1", "sub1", "key1", "value1");
    _ = try cfg.addOption("section1", "sub2", "key1", "value1");
    _ = cfg.removeSubsection("section1", "other");
    try std.testing.expect(cfg.sections.items[0].hasSubsection("sub1"));
    try std.testing.expect(cfg.sections.items[0].hasSubsection("sub2"));
    _ = cfg.removeSubsection("other", "other");
    try std.testing.expect(cfg.sections.items[0].hasSubsection("sub1"));
    try std.testing.expect(cfg.sections.items[0].hasSubsection("sub2"));
    _ = cfg.removeSubsection("section1", "sub2");
    try std.testing.expect(cfg.sections.items[0].hasSubsection("sub1"));
    try std.testing.expect(!cfg.sections.items[0].hasSubsection("sub2"));
}

test "Include path without nested load" {
    // Include stores path; nested Config optional (format package defers disk load).
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();

    const nested_ptr = try gpa.create(Config);
    nested_ptr.* = Config.init(gpa);
    _ = try nested_ptr.addOption("core", NoSubsection, "bare", "true");

    // Include takes ownership of nested_ptr.
    const inc = try Include.create(gpa, "/path/to/foo.inc", nested_ptr);
    try cfg.includes.append(gpa, inc);

    try std.testing.expectEqual(@as(usize, 1), cfg.includes.items.len);
    try std.testing.expectEqualStrings("/path/to/foo.inc", cfg.includes.items[0].path);
    try std.testing.expect(cfg.includes.items[0].config != null);
    try std.testing.expectEqualStrings("true", cfg.includes.items[0].config.?.sections.items[0].option("bare"));

    // Path-only include (no nested config loaded).
    const path_only = try Include.create(gpa, "relative.inc", null);
    try cfg.includes.append(gpa, path_only);
    try std.testing.expectEqual(@as(usize, 2), cfg.includes.items.len);
    try std.testing.expect(cfg.includes.items[1].config == null);
}
