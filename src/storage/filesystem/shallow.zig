//! Filesystem shallow storage (go-git `storage/filesystem/shallow.go`).
//!
//! One 40-byte hex hash per line in `.git/shallow`. Monomorphised over `Fs`.

const std = @import("std");
const plumbing = @import("plumbing");
const fs_pkg = @import("fs");

const dotgit = @import("dotgit");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;

pub const Error = Allocator.Error || fs_pkg.Error;

/// go-git `filesystem.ShallowStorage` monomorphised over billy-style `Fs`.
pub fn ShallowStorage(comptime Fs: type) type {
    const DotGit = dotgit.DotGitFor(Fs);

    return struct {
        const Self = @This();

        allocator: Allocator,
        dir: *DotGit,
        /// Cached copy of last SetShallow (optional convenience).
        commits: []Hash = &.{},

        pub fn init(allocator: Allocator, dir: *DotGit) Self {
            return .{ .allocator = allocator, .dir = dir };
        }

        pub fn deinit(self: *Self) void {
            if (self.commits.len > 0) self.allocator.free(self.commits);
            self.commits = &.{};
            self.* = undefined;
        }

        /// go-git `SetShallow`.
        pub fn setShallow(self: *Self, commits: []const Hash) Error!void {
            // Dupe first so a failed alloc leaves neither disk nor cache half-updated.
            const copy = try self.allocator.dupe(Hash, commits);
            errdefer self.allocator.free(copy);

            var f = try self.dir.shallowWriter();
            defer f.close() catch {};

            for (commits) |h| {
                var hex: [plumbing.HexSize]u8 = undefined;
                const s = h.string(&hex);
                _ = try f.write(s);
                _ = try f.write("\n");
            }

            if (self.commits.len > 0) self.allocator.free(self.commits);
            self.commits = copy;
        }

        /// go-git `Shallow` — read from file; empty when missing.
        pub fn shallow(self: *Self) Error![]const Hash {
            const maybe = try self.dir.shallow();
            if (maybe == null) {
                if (self.commits.len > 0) {
                    self.allocator.free(self.commits);
                    self.commits = &.{};
                }
                return self.commits;
            }
            var f = maybe.?;
            defer f.close() catch {};

            const data = try dotgit.readFileAll(self.allocator, &f);
            defer self.allocator.free(data);

            var list: std.ArrayList(Hash) = .empty;
            errdefer list.deinit(self.allocator);
            var it = std.mem.splitScalar(u8, data, '\n');
            while (it.next()) |line| {
                const t = std.mem.trim(u8, line, " \t\r");
                if (t.len == 0) continue;
                try list.append(self.allocator, plumbing.newHash(t));
            }

            if (self.commits.len > 0) self.allocator.free(self.commits);
            self.commits = try list.toOwnedSlice(self.allocator);
            return self.commits;
        }
    };
}

/// Mem specialisation.
pub const ShallowStorageMem = ShallowStorage(fs_pkg.Mem);
/// Os specialisation.
pub const ShallowStorageOs = ShallowStorage(fs_pkg.Os);
