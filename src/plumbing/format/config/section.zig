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
// Tests (go-git section_test.go — full suite except GoString)
// ---------------------------------------------------------------------------

test "Section.isName case insensitive" {
    // go-git TestSection_IsName
    const gpa = std.testing.allocator;
    const sect = try Section.create(gpa, "name1");
    defer sect.destroy();
    try std.testing.expect(sect.isName("name1"));
    try std.testing.expect(sect.isName("Name1"));
}

test "Section.subsection creates and finds" {
    // go-git TestSection_Subsection
    const gpa = std.testing.allocator;
    const sect = try Section.create(gpa, "s");
    defer sect.destroy();
    const sub1 = try sect.subsection("name1");
    _ = try sub1.addOption("key1", "value1");
    try std.testing.expect(sect.subsection("name1") catch unreachable == sub1);
    try std.testing.expectEqualStrings("value1", sub1.option("key1"));

    const sub2 = try sect.subsection("name2");
    try std.testing.expect(sub2.isName("name2"));
    try std.testing.expectEqual(@as(usize, 0), sub2.options.items.len);
}

test "Section.subsection returns last match" {
    // go-git scans subsections end-to-start; last equal name wins.
    const gpa = std.testing.allocator;
    const sect = try Section.create(gpa, "s");
    defer sect.destroy();
    const first = try Subsection.create(gpa, "dup");
    try sect.subsections.append(gpa, first);
    _ = try first.addOption("k", "first");
    const second = try Subsection.create(gpa, "dup");
    try sect.subsections.append(gpa, second);
    _ = try second.addOption("k", "second");
    const found = try sect.subsection("dup");
    try std.testing.expect(found == second);
    try std.testing.expectEqualStrings("second", found.option("k"));
}

test "Section.hasSubsection" {
    // go-git TestSection_HasSubsection
    const gpa = std.testing.allocator;
    const sect = try Section.create(gpa, "s");
    defer sect.destroy();
    _ = try sect.subsection("name1");
    try std.testing.expect(sect.hasSubsection("name1"));
    try std.testing.expect(!sect.hasSubsection("name2"));
}

test "Section.removeSubsection" {
    // go-git TestSection_RemoveSubsection
    const gpa = std.testing.allocator;
    const sect = try Section.create(gpa, "s");
    defer sect.destroy();
    _ = try sect.subsection("name1");
    _ = try sect.subsection("name2");
    _ = sect.removeSubsection("name1");
    try std.testing.expect(!sect.hasSubsection("name1"));
    try std.testing.expect(sect.hasSubsection("name2"));
}

test "Section.option and optionAll and hasOption" {
    // go-git TestSection_Option / OptionAll / HasOption
    const gpa = std.testing.allocator;
    const sect = try Section.create(gpa, "s");
    defer sect.destroy();
    _ = try sect.addOption("key1", "value1");
    _ = try sect.addOption("key2", "value2");
    _ = try sect.addOption("key1", "value3");

    try std.testing.expectEqualStrings("", sect.option("otherkey"));
    try std.testing.expectEqualStrings("value2", sect.option("key2"));
    try std.testing.expectEqualStrings("value3", sect.option("key1"));

    {
        const all = try sect.optionAll(gpa, "otherkey");
        defer gpa.free(all);
        try std.testing.expectEqual(@as(usize, 0), all.len);
    }
    {
        const all = try sect.optionAll(gpa, "key2");
        defer gpa.free(all);
        try std.testing.expectEqual(@as(usize, 1), all.len);
        try std.testing.expectEqualStrings("value2", all[0]);
    }
    {
        const all = try sect.optionAll(gpa, "key1");
        defer gpa.free(all);
        try std.testing.expectEqual(@as(usize, 2), all.len);
        try std.testing.expectEqualStrings("value1", all[0]);
        try std.testing.expectEqualStrings("value3", all[1]);
    }

    try std.testing.expect(!sect.hasOption("otherkey"));
    try std.testing.expect(sect.hasOption("key2"));
    try std.testing.expect(sect.hasOption("key1"));
}

test "Section.addOption" {
    // go-git TestSection_AddOption
    const gpa = std.testing.allocator;
    const sect = try Section.create(gpa, "s");
    defer sect.destroy();
    _ = try sect.addOption("key1", "value1");
    _ = try sect.addOption("key2", "value2");
    try std.testing.expectEqual(@as(usize, 2), sect.options.items.len);
    try std.testing.expectEqualStrings("key1", sect.options.items[0].key);
    try std.testing.expectEqualStrings("value1", sect.options.items[0].value);
    try std.testing.expectEqualStrings("key2", sect.options.items[1].key);
    try std.testing.expectEqualStrings("value2", sect.options.items[1].value);

    _ = try sect.addOption("key1", "value3");
    try std.testing.expectEqual(@as(usize, 3), sect.options.items.len);
    try std.testing.expectEqualStrings("value3", sect.options.items[2].value);
}

test "Section.setOption replaces key" {
    // go-git TestSection_SetOption
    const gpa = std.testing.allocator;
    const sect = try Section.create(gpa, "s");
    defer sect.destroy();
    _ = try sect.addOption("key1", "value1");
    _ = try sect.addOption("key2", "value2");
    _ = try sect.setOption("key1", "value4");
    try std.testing.expectEqual(@as(usize, 2), sect.options.items.len);
    try std.testing.expectEqualStrings("key2", sect.options.items[0].key);
    try std.testing.expectEqualStrings("value2", sect.options.items[0].value);
    try std.testing.expectEqualStrings("key1", sect.options.items[1].key);
    try std.testing.expectEqualStrings("value4", sect.options.items[1].value);
}

test "Section.removeOption" {
    // go-git TestSection_RemoveOption
    const gpa = std.testing.allocator;
    const sect = try Section.create(gpa, "s");
    defer sect.destroy();
    _ = try sect.addOption("key1", "value1");
    _ = try sect.addOption("key2", "value2");
    _ = try sect.addOption("key1", "value3");
    _ = sect.removeOption("otherkey");
    try std.testing.expectEqual(@as(usize, 3), sect.options.items.len);

    _ = sect.removeOption("key1");
    try std.testing.expectEqual(@as(usize, 1), sect.options.items.len);
    try std.testing.expectEqualStrings("key2", sect.options.items[0].key);
    try std.testing.expectEqualStrings("value2", sect.options.items[0].value);
}

test "Subsection.isName case sensitive" {
    // go-git TestSubsection_IsName
    const gpa = std.testing.allocator;
    const ss = try Subsection.create(gpa, "name1");
    defer ss.destroy();
    try std.testing.expect(ss.isName("name1"));
    try std.testing.expect(!ss.isName("Name1"));
}

test "Subsection.option and optionAll and hasOption" {
    // go-git TestSubsection_Option / OptionAll / HasOption
    const gpa = std.testing.allocator;
    const ss = try Subsection.create(gpa, "n");
    defer ss.destroy();
    _ = try ss.addOption("key1", "value1");
    _ = try ss.addOption("key2", "value2");
    _ = try ss.addOption("key1", "value3");

    try std.testing.expectEqualStrings("", ss.option("otherkey"));
    try std.testing.expectEqualStrings("value2", ss.option("key2"));
    try std.testing.expectEqualStrings("value3", ss.option("key1"));

    {
        const all = try ss.optionAll(gpa, "otherkey");
        defer gpa.free(all);
        try std.testing.expectEqual(@as(usize, 0), all.len);
    }
    {
        const all = try ss.optionAll(gpa, "key2");
        defer gpa.free(all);
        try std.testing.expectEqual(@as(usize, 1), all.len);
        try std.testing.expectEqualStrings("value2", all[0]);
    }
    {
        const all = try ss.optionAll(gpa, "key1");
        defer gpa.free(all);
        try std.testing.expectEqual(@as(usize, 2), all.len);
        try std.testing.expectEqualStrings("value1", all[0]);
        try std.testing.expectEqualStrings("value3", all[1]);
    }

    try std.testing.expect(!ss.hasOption("otherkey"));
    try std.testing.expect(ss.hasOption("key2"));
    try std.testing.expect(ss.hasOption("key1"));
}

test "Subsection.addOption" {
    // go-git TestSubsection_AddOption
    const gpa = std.testing.allocator;
    const ss = try Subsection.create(gpa, "n");
    defer ss.destroy();
    _ = try ss.addOption("key1", "value1");
    _ = try ss.addOption("key2", "value2");
    try std.testing.expectEqual(@as(usize, 2), ss.options.items.len);
    _ = try ss.addOption("key1", "value3");
    try std.testing.expectEqual(@as(usize, 3), ss.options.items.len);
    try std.testing.expectEqualStrings("value3", ss.options.items[2].value);
}

test "Subsection.setOption multi value" {
    // go-git TestSubsection_SetOption
    const gpa = std.testing.allocator;
    const ss = try Subsection.create(gpa, "n");
    defer ss.destroy();
    _ = try ss.addOption("key1", "value1");
    _ = try ss.addOption("key2", "value2");
    _ = try ss.addOption("key1", "value3");
    const vals = [_][]const u8{ "value1", "value4" };
    _ = try ss.setOption("key1", &vals);
    try std.testing.expectEqual(@as(usize, 3), ss.options.items.len);
    try std.testing.expectEqualStrings("value1", ss.options.items[0].value);
    try std.testing.expectEqualStrings("value2", ss.options.items[1].value);
    try std.testing.expectEqualStrings("value4", ss.options.items[2].value);
    try std.testing.expectEqualStrings("key1", ss.options.items[0].key);
    try std.testing.expectEqualStrings("key2", ss.options.items[1].key);
    try std.testing.expectEqualStrings("key1", ss.options.items[2].key);
}

test "Subsection.removeOption" {
    // go-git TestSubsection_RemoveOption
    const gpa = std.testing.allocator;
    const ss = try Subsection.create(gpa, "n");
    defer ss.destroy();
    _ = try ss.addOption("key1", "value1");
    _ = try ss.addOption("key2", "value2");
    _ = try ss.addOption("key1", "value3");
    _ = ss.removeOption("otherkey");
    try std.testing.expectEqual(@as(usize, 3), ss.options.items.len);
    _ = ss.removeOption("key1");
    try std.testing.expectEqual(@as(usize, 1), ss.options.items.len);
    try std.testing.expectEqualStrings("key2", ss.options.items[0].key);
    try std.testing.expectEqualStrings("value2", ss.options.items[0].value);
}
