//! Section and Subsection for git config files.
//!
//! Port of go-git v5.19.2 `plumbing/format/config/section.go`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const option_mod = @import("option.zig");

pub const Option = option_mod.Option;
pub const Options = option_mod.Options;

/// Section inside a git configuration file.
pub const Section = struct {
    allocator: Allocator,
    name: []const u8,
    options: Options = .empty,
    subsections: std.ArrayList(*Subsection) = .empty,

    pub fn create(allocator: Allocator, name: []const u8) Allocator.Error!*Section {
        const s = try allocator.create(Section);
        errdefer allocator.destroy(s);
        const n = try allocator.dupe(u8, name);
        s.* = .{
            .allocator = allocator,
            .name = n,
        };
        return s;
    }

    pub fn destroy(self: *Section) void {
        const a = self.allocator;
        a.free(self.name);
        for (self.options.items) |o| o.deinit(a);
        self.options.deinit(a);
        for (self.subsections.items) |ss| ss.destroy();
        self.subsections.deinit(a);
        a.destroy(self);
    }

    /// Case-insensitive section name match.
    pub fn isName(self: *const Section, name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.name, name);
    }

    /// Return existing subsection or create a new one.
    pub fn subsection(self: *Section, name: []const u8) Allocator.Error!*Subsection {
        var i = self.subsections.items.len;
        while (i > 0) {
            i -= 1;
            const ss = self.subsections.items[i];
            if (ss.isName(name)) return ss;
        }
        const ss = try Subsection.create(self.allocator, name);
        errdefer ss.destroy();
        try self.subsections.append(self.allocator, ss);
        return ss;
    }

    pub fn hasSubsection(self: *const Section, name: []const u8) bool {
        for (self.subsections.items) |ss| {
            if (ss.isName(name)) return true;
        }
        return false;
    }

    pub fn removeSubsection(self: *Section, name: []const u8) *Section {
        var i: usize = 0;
        while (i < self.subsections.items.len) {
            if (self.subsections.items[i].isName(name)) {
                const removed = self.subsections.orderedRemove(i);
                removed.destroy();
            } else {
                i += 1;
            }
        }
        return self;
    }

    pub fn option(self: *const Section, key: []const u8) []const u8 {
        return option_mod.get(self.options.items, key);
    }

    pub fn optionAll(self: *const Section, allocator: Allocator, key: []const u8) Allocator.Error![]const []const u8 {
        return option_mod.getAll(allocator, self.options.items, key);
    }

    pub fn hasOption(self: *const Section, key: []const u8) bool {
        return option_mod.has(self.options.items, key);
    }

    pub fn addOption(self: *Section, key: []const u8, value: []const u8) Allocator.Error!*Section {
        try option_mod.withAddedOption(self.allocator, &self.options, key, value);
        return self;
    }

    pub fn setOption(self: *Section, key: []const u8, value: []const u8) Allocator.Error!*Section {
        const values = [_][]const u8{value};
        try option_mod.withSettedOption(self.allocator, &self.options, key, &values);
        return self;
    }

    pub fn removeOption(self: *Section, key: []const u8) *Section {
        option_mod.withoutOption(self.allocator, &self.options, key);
        return self;
    }
};

/// Subsection under a section (`[section "subsection"]`).
pub const Subsection = struct {
    allocator: Allocator,
    name: []const u8,
    options: Options = .empty,

    pub fn create(allocator: Allocator, name: []const u8) Allocator.Error!*Subsection {
        const s = try allocator.create(Subsection);
        errdefer allocator.destroy(s);
        const n = try allocator.dupe(u8, name);
        s.* = .{
            .allocator = allocator,
            .name = n,
        };
        return s;
    }

    pub fn destroy(self: *Subsection) void {
        const a = self.allocator;
        a.free(self.name);
        for (self.options.items) |o| o.deinit(a);
        self.options.deinit(a);
        a.destroy(self);
    }

    /// Exact (case-sensitive) subsection name match.
    pub fn isName(self: *const Subsection, name: []const u8) bool {
        return std.mem.eql(u8, self.name, name);
    }

    pub fn option(self: *const Subsection, key: []const u8) []const u8 {
        return option_mod.get(self.options.items, key);
    }

    pub fn optionAll(self: *const Subsection, allocator: Allocator, key: []const u8) Allocator.Error![]const []const u8 {
        return option_mod.getAll(allocator, self.options.items, key);
    }

    pub fn hasOption(self: *const Subsection, key: []const u8) bool {
        return option_mod.has(self.options.items, key);
    }

    pub fn addOption(self: *Subsection, key: []const u8, value: []const u8) Allocator.Error!*Subsection {
        try option_mod.withAddedOption(self.allocator, &self.options, key, value);
        return self;
    }

    /// Set one or more values for `key` (go-git variadic `SetOption`).
    pub fn setOption(self: *Subsection, key: []const u8, values: []const []const u8) Allocator.Error!*Subsection {
        try option_mod.withSettedOption(self.allocator, &self.options, key, values);
        return self;
    }

    pub fn removeOption(self: *Subsection, key: []const u8) *Subsection {
        option_mod.withoutOption(self.allocator, &self.options, key);
        return self;
    }
};

// ---------------------------------------------------------------------------
// Tests (go-git section_test.go core cases)
// ---------------------------------------------------------------------------

test "Section.isName case insensitive" {
    const gpa = std.testing.allocator;
    const sect = try Section.create(gpa, "name1");
    defer sect.destroy();
    try std.testing.expect(sect.isName("name1"));
    try std.testing.expect(sect.isName("Name1"));
}

test "Section.subsection creates and finds" {
    const gpa = std.testing.allocator;
    const sect = try Section.create(gpa, "s");
    defer sect.destroy();
    const sub1 = try sect.subsection("name1");
    _ = try sub1.addOption("key1", "value1");
    try std.testing.expect(sect.subsection("name1") catch unreachable == sub1);
    const sub2 = try sect.subsection("name2");
    try std.testing.expect(sub2.isName("name2"));
    try std.testing.expect(sect.hasSubsection("name1"));
    try std.testing.expect(!sect.hasSubsection("name3"));
}

test "Section.removeSubsection" {
    const gpa = std.testing.allocator;
    const sect = try Section.create(gpa, "s");
    defer sect.destroy();
    _ = try sect.subsection("name1");
    _ = try sect.subsection("name2");
    _ = sect.removeSubsection("name1");
    try std.testing.expect(!sect.hasSubsection("name1"));
    try std.testing.expect(sect.hasSubsection("name2"));
}

test "Section option helpers" {
    const gpa = std.testing.allocator;
    const sect = try Section.create(gpa, "s");
    defer sect.destroy();
    _ = try sect.addOption("key1", "value1");
    _ = try sect.addOption("key2", "value2");
    _ = try sect.addOption("key1", "value3");
    try std.testing.expectEqualStrings("", sect.option("otherkey"));
    try std.testing.expectEqualStrings("value2", sect.option("key2"));
    try std.testing.expectEqualStrings("value3", sect.option("key1"));
    try std.testing.expect(sect.hasOption("key1"));
    try std.testing.expect(!sect.hasOption("otherkey"));

    const all = try sect.optionAll(gpa, "key1");
    defer gpa.free(all);
    try std.testing.expectEqual(@as(usize, 2), all.len);
    try std.testing.expectEqualStrings("value1", all[0]);
    try std.testing.expectEqualStrings("value3", all[1]);

    _ = try sect.setOption("key1", "value4");
    try std.testing.expectEqualStrings("value4", sect.option("key1"));
    try std.testing.expectEqualStrings("value2", sect.option("key2"));

    _ = sect.removeOption("key1");
    try std.testing.expect(!sect.hasOption("key1"));
    try std.testing.expect(sect.hasOption("key2"));
}

test "Subsection.isName case sensitive" {
    const gpa = std.testing.allocator;
    const ss = try Subsection.create(gpa, "name1");
    defer ss.destroy();
    try std.testing.expect(ss.isName("name1"));
    try std.testing.expect(!ss.isName("Name1"));
}

test "Subsection.setOption multi value" {
    const gpa = std.testing.allocator;
    const ss = try Subsection.create(gpa, "n");
    defer ss.destroy();
    _ = try ss.addOption("key1", "value1");
    _ = try ss.addOption("key2", "value2");
    _ = try ss.addOption("key1", "value3");
    const vals = [_][]const u8{ "value1", "value4" };
    _ = try ss.setOption("key1", &vals);
    try std.testing.expectEqualStrings("value1", ss.options.items[0].value);
    try std.testing.expectEqualStrings("value2", ss.options.items[1].value);
    try std.testing.expectEqualStrings("value4", ss.options.items[2].value);
    try std.testing.expectEqual(@as(usize, 3), ss.options.items.len);
}
