//! Capability list — port of go-git
//! `plumbing/protocol/packp/capability/list.go` (v5.19.2).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const cap_mod = @import("capability.zig");

pub const Capability = cap_mod.Capability;

// ---------------------------------------------------------------------------
// Errors (go-git Err*)
// ---------------------------------------------------------------------------

/// Errors returned by List validation and mutation (go-git package vars).
pub const Error = error{
    /// Capability requires arguments (go-git `ErrArgumentsRequired`).
    ArgumentsRequired,
    /// Arguments given where not allowed (go-git `ErrArguments`).
    Arguments,
    /// Empty argument value (go-git `ErrEmptyArgument`).
    EmptyArgument,
    /// Multiple arguments not allowed (go-git `ErrMultipleArguments`).
    MultipleArguments,
};

// ---------------------------------------------------------------------------
// Entry + List
// ---------------------------------------------------------------------------

const Entry = struct {
    /// Owned capability name (same bytes as map key).
    name: []const u8,
    /// Owned argument values.
    values: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinitValues(self: *Entry, allocator: Allocator) void {
        for (self.values.items) |v| allocator.free(v);
        self.values.deinit(allocator);
        self.values = .empty;
    }

    fn deinit(self: *Entry, allocator: Allocator) void {
        self.deinitValues(allocator);
        allocator.free(self.name);
    }
};

/// List of capabilities with insertion-order iteration (go-git `List`).
pub const List = struct {
    allocator: Allocator,
    /// Map capability name → entry. Keys are owned (`entry.name`).
    m: std.StringHashMapUnmanaged(Entry) = .empty,
    /// Insertion-order names (borrowed pointers into `m` keys / entry.name).
    sort: std.ArrayListUnmanaged([]const u8) = .empty,

    /// Create an empty list (go-git `NewList`).
    pub fn init(allocator: Allocator) List {
        return .{ .allocator = allocator };
    }

    /// Deep-copy into a new list owned by `allocator` (via string encode/decode).
    pub fn clone(self: *const List, allocator: Allocator) (Error || Allocator.Error)!List {
        const wire = try self.string(allocator);
        defer allocator.free(wire);
        var dst = List.init(allocator);
        errdefer dst.deinit();
        try dst.decode(wire);
        return dst;
    }

    /// Free all owned names and values.
    pub fn deinit(self: *List) void {
        var it = self.m.valueIterator();
        while (it.next()) |entry| {
            // `entry.name` is the map key pointer; free values + name once.
            for (entry.values.items) |v| self.allocator.free(v);
            entry.values.deinit(self.allocator);
            self.allocator.free(entry.name);
        }
        self.m.deinit(self.allocator);
        // sort items borrow map key pointers (already freed above)
        self.sort.deinit(self.allocator);
        self.* = undefined;
    }

    /// True if the list has no capabilities (go-git `IsEmpty`).
    pub fn isEmpty(self: *const List) bool {
        return self.sort.items.len == 0;
    }

    /// Number of distinct capabilities.
    pub fn count(self: *const List) usize {
        return self.m.count();
    }

    /// Decode a space-separated capability advertisement (go-git `Decode`).
    ///
    /// Trims leading/trailing space (git 1.x receive-pack quirk). Each token
    /// is either `name` or `name=value` (`=` splits at most once).
    pub fn decode(self: *List, raw: []const u8) (Error || Allocator.Error)!void {
        const trimmed = std.mem.trim(u8, raw, " \t\n\r");
        if (trimmed.len == 0) return;

        var it = std.mem.splitScalar(u8, trimmed, ' ');
        while (it.next()) |token| {
            if (token.len == 0) {
                // Empty token from consecutive spaces: treat as bare empty name.
                try self.add("", &.{});
                continue;
            }
            if (std.mem.indexOfScalar(u8, token, '=')) |eq| {
                const name = token[0..eq];
                const value = token[eq + 1 ..];
                try self.add(name, &.{value});
            } else {
                try self.add(token, &.{});
            }
        }
    }

    /// Values for `capability`, or empty if absent / no args (go-git `Get`).
    /// Borrowed from the list; do not free.
    pub fn get(self: *const List, capability: Capability) []const []const u8 {
        const entry = self.m.get(capability) orelse return &.{};
        return entry.values.items;
    }

    /// Set capability, replacing previous values (go-git `Set`).
    pub fn set(self: *List, capability: Capability, values: []const []const u8) (Error || Allocator.Error)!void {
        if (self.m.getPtr(capability)) |entry| {
            entry.deinitValues(self.allocator);
        }
        return self.add(capability, values);
    }

    /// Add a capability; `values` are optional (go-git `Add`).
    pub fn add(self: *List, c: Capability, values: []const []const u8) (Error || Allocator.Error)!void {
        try self.validate(c, values);

        if (!self.supports(c)) {
            const name_owned = try self.allocator.dupe(u8, c);
            errdefer self.allocator.free(name_owned);
            const entry = Entry{ .name = name_owned };
            try self.m.put(self.allocator, name_owned, entry);
            errdefer _ = self.m.remove(name_owned);
            try self.sort.append(self.allocator, name_owned);
        }

        if (values.len == 0) return;

        const entry = self.m.getPtr(c).?;
        if (cap_mod.isKnown(c) and !cap_mod.multipleArgument(c) and entry.values.items.len > 0) {
            return error.MultipleArguments;
        }

        for (values) |v| {
            const v_owned = try self.allocator.dupe(u8, v);
            errdefer self.allocator.free(v_owned);
            try entry.values.append(self.allocator, v_owned);
        }
    }

    fn validateNoEmptyArgs(_: *List, values: []const []const u8) Error!void {
        for (values) |v| {
            if (v.len == 0) return error.EmptyArgument;
        }
    }

    fn validate(self: *List, c: Capability, values: []const []const u8) Error!void {
        if (!cap_mod.isKnown(c)) {
            return self.validateNoEmptyArgs(values);
        }
        if (cap_mod.requiresArgument(c) and values.len == 0) {
            return error.ArgumentsRequired;
        }
        if (!cap_mod.requiresArgument(c) and values.len != 0) {
            return error.Arguments;
        }
        if (!cap_mod.multipleArgument(c) and values.len > 1) {
            return error.MultipleArguments;
        }
        return self.validateNoEmptyArgs(values);
    }

    /// True if capability is present (go-git `Supports`).
    pub fn supports(self: *const List, capability: Capability) bool {
        return self.m.contains(capability);
    }

    /// Remove a capability if present (go-git `Delete`).
    pub fn delete(self: *List, capability: Capability) void {
        if (!self.supports(capability)) return;

        // Drop from insertion-order slice before freeing the name bytes.
        for (self.sort.items, 0..) |name, i| {
            if (std.mem.eql(u8, name, capability)) {
                _ = self.sort.orderedRemove(i);
                break;
            }
        }

        if (self.m.fetchRemove(capability)) |kv| {
            var entry = kv.value;
            // key and entry.name are the same owned allocation
            entry.deinit(self.allocator);
        }
    }

    /// All capabilities in insertion order (go-git `All`).
    /// Borrowed names; valid until list is mutated.
    pub fn all(self: *const List) []const Capability {
        return self.sort.items;
    }

    /// Space-joined capability string, insertion order (go-git `String`).
    /// Caller owns the returned slice.
    pub fn string(self: *const List, allocator: Allocator) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var first = true;
        for (self.sort.items) |key| {
            const entry = self.m.get(key) orelse continue;
            if (entry.values.items.len == 0) {
                if (!first) try out.append(allocator, ' ');
                first = false;
                try out.appendSlice(allocator, key);
                continue;
            }
            for (entry.values.items) |value| {
                if (!first) try out.append(allocator, ' ');
                first = false;
                try out.appendSlice(allocator, key);
                try out.append(allocator, '=');
                try out.appendSlice(allocator, value);
            }
        }
        return try out.toOwnedSlice(allocator);
    }
};

// ---------------------------------------------------------------------------
// Tests (list_test.go)
// ---------------------------------------------------------------------------

test "list_test.TestIsEmpty" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try testing.expect(list.isEmpty());
}

test "list_test.TestDecode" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try list.decode("symref=foo symref=qux thin-pack");

    try testing.expectEqual(@as(usize, 2), list.count());
    const sym = list.get(cap_mod.SymRef);
    try testing.expectEqual(@as(usize, 2), sym.len);
    try testing.expectEqualStrings("foo", sym[0]);
    try testing.expectEqualStrings("qux", sym[1]);
    try testing.expectEqual(@as(usize, 0), list.get(cap_mod.ThinPack).len);
    try testing.expect(list.supports(cap_mod.ThinPack));
}

test "list_test.TestDecodeWithLeadingSpace" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try list.decode(" report-status");

    try testing.expectEqual(@as(usize, 1), list.count());
    try testing.expect(list.supports(cap_mod.ReportStatus));
}

test "list_test.TestDecodeEmpty" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try list.decode("");
    try testing.expect(list.isEmpty());

    var list2 = List.init(testing.allocator);
    defer list2.deinit();
    try list2.decode(&.{});
    try testing.expect(list2.isEmpty());
}

test "list_test.TestDecodeWithErrArguments" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try testing.expectError(error.Arguments, list.decode("thin-pack=foo"));
}

test "list_test.TestDecodeWithEqual" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try list.decode("agent=foo=bar");

    try testing.expectEqual(@as(usize, 1), list.count());
    const vals = list.get(cap_mod.Agent);
    try testing.expectEqual(@as(usize, 1), vals.len);
    try testing.expectEqualStrings("foo=bar", vals[0]);
}

test "list_test.TestDecodeWithUnknownCapability" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try list.decode("foo");
    try testing.expect(list.supports("foo"));
}

test "list_test.TestDecodeWithUnknownCapabilityWithArgument" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try list.decode("oldref=HEAD:refs/heads/v2 thin-pack");

    try testing.expectEqual(@as(usize, 2), list.count());
    const vals = list.get("oldref");
    try testing.expectEqual(@as(usize, 1), vals.len);
    try testing.expectEqualStrings("HEAD:refs/heads/v2", vals[0]);
    try testing.expectEqual(@as(usize, 0), list.get(cap_mod.ThinPack).len);
    try testing.expect(list.supports(cap_mod.ThinPack));
}

test "list_test.TestDecodeWithUnknownCapabilityWithMultipleArgument" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try list.decode("foo=HEAD:refs/heads/v2 foo=HEAD:refs/heads/v1 thin-pack");

    try testing.expectEqual(@as(usize, 2), list.count());
    const vals = list.get("foo");
    try testing.expectEqual(@as(usize, 2), vals.len);
    try testing.expectEqualStrings("HEAD:refs/heads/v2", vals[0]);
    try testing.expectEqualStrings("HEAD:refs/heads/v1", vals[1]);
    try testing.expectEqual(@as(usize, 0), list.get(cap_mod.ThinPack).len);
}

test "list_test.TestString" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try list.set(cap_mod.Agent, &.{"bar"});
    try list.set(cap_mod.SymRef, &.{"foo:qux"});
    try list.set(cap_mod.ThinPack, &.{});

    const s = try list.string(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("agent=bar symref=foo:qux thin-pack", s);
}

test "list_test.TestStringSort" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try list.set(cap_mod.Agent, &.{"bar"});
    try list.set(cap_mod.SymRef, &.{"foo:qux"});
    try list.set(cap_mod.ThinPack, &.{});

    const s = try list.string(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("agent=bar symref=foo:qux thin-pack", s);
}

test "list_test.TestSet" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try list.add(cap_mod.SymRef, &.{ "foo", "qux" });
    try list.set(cap_mod.SymRef, &.{"bar"});

    try testing.expectEqual(@as(usize, 1), list.count());
    const vals = list.get(cap_mod.SymRef);
    try testing.expectEqual(@as(usize, 1), vals.len);
    try testing.expectEqualStrings("bar", vals[0]);
}

test "list_test.TestSetEmpty" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try list.set(cap_mod.Agent, &.{"bar"});
    try testing.expectEqual(@as(usize, 1), list.get(cap_mod.Agent).len);
}

test "list_test.TestSetDuplicate" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try list.set(cap_mod.Agent, &.{"baz"});
    try list.set(cap_mod.Agent, &.{"bar"});

    const s = try list.string(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("agent=bar", s);
}

test "list_test.TestGetEmpty" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 0), list.get(cap_mod.Agent).len);
}

test "list_test.TestDelete" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    list.delete(cap_mod.SymRef);

    try list.add(cap_mod.Sideband, &.{});
    try list.set(cap_mod.SymRef, &.{"bar"});
    try list.set(cap_mod.Sideband64k, &.{});

    list.delete(cap_mod.SymRef);

    const s = try list.string(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("side-band side-band-64k", s);
}

test "list_test.TestAdd" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try list.add(cap_mod.SymRef, &.{ "foo", "qux" });
    try list.add(cap_mod.ThinPack, &.{});

    const s = try list.string(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("symref=foo symref=qux thin-pack", s);
}

test "list_test.TestAddUnknownCapability" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try list.add("foo", &.{});
    try testing.expect(list.supports("foo"));
}

test "list_test.TestAddErrArgumentsRequired" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try testing.expectError(error.ArgumentsRequired, list.add(cap_mod.SymRef, &.{}));
}

test "list_test.TestAddErrArgumentsNotAllowed" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try testing.expectError(error.Arguments, list.add(cap_mod.OFSDelta, &.{"foo"}));
}

test "list_test.TestAddErrArguments" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try testing.expectError(error.EmptyArgument, list.add(cap_mod.SymRef, &.{""}));
}

test "list_test.TestAddErrMultipleArguments" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try list.add(cap_mod.Agent, &.{"foo"});
    try testing.expectError(error.MultipleArguments, list.add(cap_mod.Agent, &.{"bar"}));
}

test "list_test.TestAddErrMultipleArgumentsAtTheSameTime" {
    var list = List.init(testing.allocator);
    defer list.deinit();
    try testing.expectError(error.MultipleArguments, list.add(cap_mod.Agent, &.{ "foo", "bar" }));
}

test "list_test.TestAll" {
    var empty = List.init(testing.allocator);
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.all().len);

    var list = List.init(testing.allocator);
    defer list.deinit();
    try list.add(cap_mod.Agent, &.{"foo"});
    {
        const a = list.all();
        try testing.expectEqual(@as(usize, 1), a.len);
        try testing.expectEqualStrings(cap_mod.Agent, a[0]);
    }
    try list.add(cap_mod.OFSDelta, &.{});
    {
        const a = list.all();
        try testing.expectEqual(@as(usize, 2), a.len);
        try testing.expectEqualStrings(cap_mod.Agent, a[0]);
        try testing.expectEqualStrings(cap_mod.OFSDelta, a[1]);
    }
}

test "List.clone deep free under gpa" {
    const gpa = testing.allocator;
    var a = List.init(gpa);
    defer a.deinit();
    try a.set(cap_mod.Agent, &.{"go-git/5.x"});
    try a.set(cap_mod.OFSDelta, &.{});
    var b = try a.clone(gpa);
    defer b.deinit();
    try testing.expect(b.supports(cap_mod.Agent));
    try testing.expect(b.supports(cap_mod.OFSDelta));
}
