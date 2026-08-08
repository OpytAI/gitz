//! Submodule status types (go-git `SubmoduleStatus` / `SubmodulesStatus`).

const std = @import("std");
const plumbing = @import("plumbing");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const ReferenceName = plumbing.ReferenceName;

/// go-git `SubmoduleStatus` — status for one submodule in the worktree.
pub const SubmoduleStatus = struct {
    path: []const u8 = "",
    current: Hash = ZeroHash,
    expected: Hash = ZeroHash,
    branch: ReferenceName = ReferenceName.init(""),

    /// go-git `SubmoduleStatus.IsClean` — HEAD equals expected commit.
    pub fn isClean(self: *const SubmoduleStatus) bool {
        return self.current.eql(self.expected);
    }

    /// go-git `SubmoduleStatus.String` — `git submodule status <path>` line.
    ///
    /// Prefix: `-` not initialized (current zero), `+` dirty, space clean.
    /// Caller frees the returned slice.
    pub fn string(self: *const SubmoduleStatus, allocator: Allocator) Allocator.Error![]u8 {
        var status_char: u8 = ' ';
        if (self.current.isZero()) {
            status_char = '-';
        } else if (!self.isClean()) {
            status_char = '+';
        }

        var exp_buf: [plumbing.MaxHexSize]u8 = undefined;
        const exp_hex = self.expected.string(&exp_buf);

        var extra: []const u8 = "";
        var extra_owned: ?[]u8 = null;
        defer if (extra_owned) |o| allocator.free(o);

        if (self.branch.raw.len != 0) {
            // go-git: string(s.Branch[5:]) — strip "refs/" prefix when present.
            if (self.branch.raw.len > 5 and std.mem.startsWith(u8, self.branch.raw, "refs/")) {
                extra = self.branch.raw[5..];
            } else {
                extra = self.branch.raw;
            }
        } else if (!self.current.isZero()) {
            var cur_buf: [plumbing.MaxHexSize]u8 = undefined;
            const cur_hex = self.current.string(&cur_buf);
            const short_n = @min(cur_hex.len, 7);
            extra_owned = try allocator.dupe(u8, cur_hex[0..short_n]);
            extra = extra_owned.?;
        }

        if (extra.len > 0) {
            return std.fmt.allocPrint(
                allocator,
                "{c}{s} {s} ({s})",
                .{ status_char, exp_hex, self.path, extra },
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "{c}{s} {s}",
            .{ status_char, exp_hex, self.path },
        );
    }
};

/// go-git `SubmodulesStatus` — status list for all submodules.
pub const SubmodulesStatus = struct {
    items: []const SubmoduleStatus = &.{},

    /// go-git `SubmodulesStatus.String` — multiline `git submodule status`.
    /// Caller frees.
    pub fn string(self: *const SubmodulesStatus, allocator: Allocator) Allocator.Error![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        for (self.items) |st| {
            const line = try st.string(allocator);
            defer allocator.free(line);
            try list.appendSlice(allocator, line);
            try list.append(allocator, '\n');
        }
        return try list.toOwnedSlice(allocator);
    }

    pub fn free(self: *SubmodulesStatus, allocator: Allocator) void {
        if (self.items.len > 0) allocator.free(self.items);
        self.items = &.{};
    }
};
