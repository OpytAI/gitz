//! Status map types (go-git `status.go`).

const std = @import("std");

const Allocator = std.mem.Allocator;

/// go-git `StatusCode`.
pub const StatusCode = enum(u8) {
    unmodified = ' ',
    untracked = '?',
    modified = 'M',
    added = 'A',
    deleted = 'D',
    renamed = 'R',
    copied = 'C',
    updated_but_unmerged = 'U',

    pub fn char(self: StatusCode) u8 {
        return @intFromEnum(self);
    }
};

/// go-git `FileStatus`.
pub const FileStatus = struct {
    staging: StatusCode = .untracked,
    worktree: StatusCode = .untracked,
    /// Extra info (e.g. previous name on rename).
    extra: []const u8 = "",
};

/// go-git `StatusStrategy`.
pub const StatusStrategy = enum {
    /// Missing paths mean untracked (default go-git Empty).
    empty,
    /// Preload all index paths as unmodified.
    preload,
};

/// go-git default status strategy (`Empty`).
pub const default_status_strategy: StatusStrategy = .empty;

/// go-git `StatusOptions`.
pub const StatusOptions = struct {
    strategy: StatusStrategy = default_status_strategy,
};

/// go-git `Status` — path → file status. Paths use `/` separators.
///
/// Owns path keys and optional `extra` strings; free with `deinit`.
pub const Status = struct {
    map: std.StringHashMapUnmanaged(FileStatus) = .empty,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Status {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Status) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            if (e.value_ptr.extra.len > 0) self.allocator.free(e.value_ptr.extra);
        }
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    /// go-git `Status.File` — get or insert untracked/untracked entry.
    ///
    /// Owns path keys: dupes before insert so callers may free temporaries.
    pub fn file(self: *Status, path: []const u8) !*FileStatus {
        if (self.map.getPtr(path)) |p| return p;

        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        const gop = try self.map.getOrPut(self.allocator, owned);
        if (gop.found_existing) {
            // Equal path already present (content eql); drop unused dupe.
            self.allocator.free(owned);
            return gop.value_ptr;
        }
        // getOrPut stored `owned` as the key; keep it.
        gop.value_ptr.* = .{ .worktree = .untracked, .staging = .untracked };
        return gop.value_ptr;
    }

    /// go-git `Status.IsUntracked`.
    pub fn isUntracked(self: *const Status, path: []const u8) bool {
        const st = self.map.get(path) orelse return false;
        return st.worktree == .untracked;
    }

    /// go-git `Status.IsClean`.
    pub fn isClean(self: *const Status) bool {
        var it = self.map.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.worktree != .unmodified or e.value_ptr.staging != .unmodified)
                return false;
        }
        return true;
    }

    /// go-git `Status.String` — dirty paths only. Caller frees.
    pub fn string(self: *const Status, allocator: Allocator) Allocator.Error![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        var it = self.map.iterator();
        while (it.next()) |e| {
            const st = e.value_ptr.*;
            if (st.staging == .unmodified and st.worktree == .unmodified) continue;
            const path = if (st.staging == .renamed and st.extra.len > 0)
                try std.fmt.allocPrint(allocator, "{s} -> {s}", .{ e.key_ptr.*, st.extra })
            else
                try allocator.dupe(u8, e.key_ptr.*);
            defer allocator.free(path);
            try list.writer(allocator).print("{c}{c} {s}\n", .{
                st.staging.char(),
                st.worktree.char(),
                path,
            });
        }
        return try list.toOwnedSlice(allocator);
    }
};

test "Status File IsClean" {
    const gpa = std.testing.allocator;
    var s = Status.init(gpa);
    defer s.deinit();
    try std.testing.expect(s.isClean());
    const f = try s.file("a.txt");
    try std.testing.expect(f.worktree == .untracked);
    try std.testing.expect(!s.isClean());
    f.worktree = .unmodified;
    f.staging = .unmodified;
    try std.testing.expect(s.isClean());
}

test "Status.file owns key after caller frees path" {
    const gpa = std.testing.allocator;
    var s = Status.init(gpa);
    defer s.deinit();
    const path = try gpa.dupe(u8, "owned.txt");
    const f = try s.file(path);
    f.staging = .added;
    gpa.free(path); // original must not be the map key
    const got = s.map.get("owned.txt") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(StatusCode.added, got.staging);
}
