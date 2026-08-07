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

/// Reference to an included config file (structure only; include expansion is
/// higher-level than this format package).
pub const Include = struct {
    path: []const u8,
    config: ?*Config = null,

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
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    _ = try cfg.setOption("section", NoSubsection, "key1", "value1");
    try std.testing.expectEqual(@as(usize, 1), cfg.sections.items.len);
    try std.testing.expectEqualStrings("section", cfg.sections.items[0].name);
    try std.testing.expectEqualStrings("value1", cfg.sections.items[0].option("key1"));
    _ = try cfg.setOption("section", NoSubsection, "key1", "value1");
    try std.testing.expectEqual(@as(usize, 1), cfg.sections.items[0].options.items.len);
}

test "Config.setOption subsection" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    _ = try cfg.setOption("section", "subsection", "key1", "value1");
    try std.testing.expectEqual(@as(usize, 1), cfg.sections.items.len);
    try std.testing.expectEqual(@as(usize, 1), cfg.sections.items[0].subsections.items.len);
    try std.testing.expectEqualStrings("value1", cfg.sections.items[0].subsections.items[0].option("key1"));
}

test "Config.addOption and hasSection" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    _ = try cfg.addOption("section1", "sub1", "key1", "value1");
    _ = try cfg.addOption("section1", "sub2", "key1", "value1");
    try std.testing.expect(cfg.hasSection("section1"));
    try std.testing.expect(!cfg.hasSection("section2"));
}

test "Config.removeSection" {
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
}

test "Config.removeSubsection" {
    const gpa = std.testing.allocator;
    var cfg = Config.init(gpa);
    defer cfg.deinit();
    _ = try cfg.addOption("section1", "sub1", "key1", "value1");
    _ = try cfg.addOption("section1", "sub2", "key1", "value1");
    _ = cfg.removeSubsection("section1", "other");
    try std.testing.expect(cfg.sections.items[0].hasSubsection("sub1"));
    try std.testing.expect(cfg.sections.items[0].hasSubsection("sub2"));
    _ = cfg.removeSubsection("other", "other");
    try std.testing.expect(cfg.sections.items[0].hasSubsection("sub2"));
    _ = cfg.removeSubsection("section1", "sub2");
    try std.testing.expect(cfg.sections.items[0].hasSubsection("sub1"));
    try std.testing.expect(!cfg.sections.items[0].hasSubsection("sub2"));
}
