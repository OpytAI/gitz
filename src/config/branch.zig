//! Branch tracking configuration.
//!
//! Port of go-git v5.19.2 `config/branch.go`.

const std = @import("std");
const plumbing = @import("plumbing");
const format_config = @import("config");
const owned = @import("owned.zig");

const Allocator = std.mem.Allocator;
const Subsection = format_config.Subsection;
const ReferenceName = plumbing.ReferenceName;
const setOwned = owned.setOwned;
const freeOwned = owned.freeOwned;

const remote_key = "remote";
const merge_key = "merge";
const rebase_key = "rebase";
const description_key = "description";

/// Branch config errors (go-git package vars).
pub const Error = error{
    /// go-git `errBranchEmptyName`.
    BranchEmptyName,
    /// go-git `errBranchInvalidMerge`.
    BranchInvalidMerge,
    /// go-git `errBranchInvalidRebase`.
    BranchInvalidRebase,
} || plumbing.Error;

/// Local branch tracking info (go-git `Branch`).
pub const Branch = struct {
    allocator: Allocator,
    name: []const u8 = "",
    remote: []const u8 = "",
    merge: ReferenceName = .{ .raw = "" },
    rebase: []const u8 = "",
    description: []const u8 = "",
    /// Borrowed subsection in raw config (not owned).
    raw: ?*Subsection = null,
    /// Owned storage for merge.raw when set.
    merge_owned: bool = false,

    pub fn init(allocator: Allocator) Branch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Branch) void {
        freeOwned(self.allocator, &self.name);
        freeOwned(self.allocator, &self.remote);
        freeMerge(self);
        freeOwned(self.allocator, &self.rebase);
        freeOwned(self.allocator, &self.description);
        self.raw = null;
        self.* = undefined;
    }

    fn freeMerge(self: *Branch) void {
        if (self.merge_owned and self.merge.raw.len > 0) {
            self.allocator.free(self.merge.raw);
        }
        self.merge = .{ .raw = "" };
        self.merge_owned = false;
    }

    fn setMerge(self: *Branch, value: []const u8) Allocator.Error!void {
        freeMerge(self);
        if (value.len == 0) return;
        self.merge = .{ .raw = try self.allocator.dupe(u8, value) };
        self.merge_owned = true;
    }

    /// go-git `Branch.Validate`.
    pub fn validate(self: *const Branch) Error!void {
        if (self.name.len == 0) return error.BranchEmptyName;

        if (self.merge.raw.len > 0 and !self.merge.isBranch()) {
            return error.BranchInvalidMerge;
        }

        if (self.rebase.len > 0 and
            !std.mem.eql(u8, self.rebase, "true") and
            !std.mem.eql(u8, self.rebase, "interactive") and
            !std.mem.eql(u8, self.rebase, "false"))
        {
            return error.BranchInvalidRebase;
        }

        var buf: [512]u8 = undefined;
        // `newBranchReferenceName` may return `error.NoSpaceLeft` from fixed-buffer
        // formatting; treat that as an invalid reference name.
        const ref = plumbing.newBranchReferenceName(self.name, &buf) catch return error.InvalidReferenceName;
        try ref.validate();
    }

    /// go-git `Branch.unmarshal`.
    pub fn unmarshal(self: *Branch, s: *Subsection) (Allocator.Error || Error)!void {
        self.raw = s;
        try setOwned(self.allocator, &self.name, s.name);
        try setOwned(self.allocator, &self.remote, s.option(remote_key));

        try self.setMerge(s.option(merge_key));
        try setOwned(self.allocator, &self.rebase, s.option(rebase_key));

        const desc = try unquoteDescriptionAlloc(self.allocator, s.option(description_key));
        freeOwned(self.allocator, &self.description);
        if (desc.len == 0) {
            self.allocator.free(desc);
            self.description = "";
        } else {
            self.description = desc;
        }

        try self.validate();
    }

    /// go-git `Branch.marshal`.
    pub fn marshal(self: *Branch) Allocator.Error!*Subsection {
        if (self.raw == null) {
            self.raw = try Subsection.create(self.allocator, self.name);
        }
        const r = self.raw.?;
        if (!std.mem.eql(u8, r.name, self.name)) {
            self.allocator.free(r.name);
            r.name = try self.allocator.dupe(u8, self.name);
        }

        if (self.remote.len == 0) {
            _ = r.removeOption(remote_key);
        } else {
            const values = [_][]const u8{self.remote};
            _ = try r.setOption(remote_key, &values);
        }

        if (self.merge.raw.len == 0) {
            _ = r.removeOption(merge_key);
        } else {
            const values = [_][]const u8{self.merge.raw};
            _ = try r.setOption(merge_key, &values);
        }

        if (self.rebase.len == 0) {
            _ = r.removeOption(rebase_key);
        } else {
            const values = [_][]const u8{self.rebase};
            _ = try r.setOption(rebase_key, &values);
        }

        if (self.description.len == 0) {
            _ = r.removeOption(description_key);
        } else {
            const quoted = try quoteDescription(self.allocator, self.description);
            defer self.allocator.free(quoted);
            const values = [_][]const u8{quoted};
            _ = try r.setOption(description_key, &values);
        }

        return r;
    }
};

/// go-git `quoteDescription` — replace real newlines with `\n` two-char for encoder.
pub fn quoteDescription(allocator: Allocator, desc: []const u8) Allocator.Error![]u8 {
    return try replaceAll(allocator, desc, "\n", "\\n");
}

/// go-git `unquoteDescription` — `\n` two-char → real newline.
pub fn unquoteDescriptionAlloc(allocator: Allocator, desc: []const u8) Allocator.Error![]u8 {
    return try replaceAll(allocator, desc, "\\n", "\n");
}

fn replaceAll(allocator: Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) Allocator.Error![]u8 {
    if (needle.len == 0) return try allocator.dupe(u8, haystack);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < haystack.len) {
        if (std.mem.startsWith(u8, haystack[i..], needle)) {
            try out.appendSlice(allocator, replacement);
            i += needle.len;
        } else {
            try out.append(allocator, haystack[i]);
            i += 1;
        }
    }
    return try out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests (go-git branch_test.go)
// ---------------------------------------------------------------------------

test "Branch.validate name and merge" {
    const gpa = std.testing.allocator;
    var good = Branch.init(gpa);
    defer good.deinit();
    try setOwned(gpa, &good.name, "master");
    try setOwned(gpa, &good.remote, "some_remote");
    good.merge = .{ .raw = "refs/heads/master" };
    try good.validate();

    var bad_name = Branch.init(gpa);
    defer bad_name.deinit();
    try setOwned(gpa, &bad_name.remote, "some_remote");
    bad_name.merge = .{ .raw = "refs/heads/master" };
    try std.testing.expectError(error.BranchEmptyName, bad_name.validate());

    var bad_merge = Branch.init(gpa);
    defer bad_merge.deinit();
    try setOwned(gpa, &bad_merge.name, "master");
    try setOwned(gpa, &bad_merge.remote, "some_remote");
    bad_merge.merge = .{ .raw = "blah" };
    try std.testing.expectError(error.BranchInvalidMerge, bad_merge.validate());
}

test "quoteDescription and unquoteDescriptionAlloc" {
    const gpa = std.testing.allocator;
    const q = try quoteDescription(gpa, "a\nb\n");
    defer gpa.free(q);
    try std.testing.expectEqualStrings("a\\nb\\n", q);
    const u = try unquoteDescriptionAlloc(gpa, q);
    defer gpa.free(u);
    try std.testing.expectEqualStrings("a\nb\n", u);
}
