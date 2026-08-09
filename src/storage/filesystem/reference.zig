//! Filesystem reference storage (go-git `storage/filesystem/reference.go`).
//!
//! Thin wrappers over DotGit ref APIs. Monomorphised over `Fs`.

const std = @import("std");
const plumbing = @import("plumbing");
const fs_pkg = @import("fs");
const memory = @import("memory");

const dotgit = @import("dotgit");

const Allocator = std.mem.Allocator;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const ReferenceUpdate = memory.ReferenceUpdate;

pub const Error = error{
    ReferenceNotFound,
    ReferenceHasChanged,
    ReferenceNameEscape,
} || Allocator.Error || fs_pkg.Error || plumbing.Error || dotgit.Error;

/// go-git `filesystem.ReferenceStorage` monomorphised over billy-style `Fs`.
pub fn ReferenceStorage(comptime Fs: type) type {
    const DotGit = dotgit.DotGitFor(Fs);

    return struct {
        const Self = @This();

        allocator: Allocator,
        dir: *DotGit,

        pub fn init(allocator: Allocator, dir: *DotGit) Self {
            return .{ .allocator = allocator, .dir = dir };
        }

        pub fn deinit(self: *Self) void {
            self.* = undefined;
        }

        /// go-git `SetReference`.
        pub fn setReference(self: *Self, ref: Reference) Error!void {
            try self.dir.setRef(ref, null);
        }

        /// go-git `CheckAndSetReference`.
        pub fn checkAndSetReference(self: *Self, ref: ?Reference, old: ?Reference) Error!void {
            const new_ref = ref orelse return;
            try self.dir.setRef(new_ref, old);
        }

        /// go-git `Reference`.
        ///
        /// DotGit maps loose/packed miss to `ReferenceNotFound` (never raw
        /// `NotExist` at this boundary).
        pub fn reference(self: *Self, n: ReferenceName) Error!Reference {
            return try self.dir.ref(n);
        }

        /// go-git `IterReferences` — owned slice; caller must `deinit` the iter.
        pub fn iterReferences(self: *Self) Error!ReferenceSliceIter {
            const all = try self.dir.refs();
            return .{
                .allocator = self.allocator,
                .items = all,
                .pos = 0,
            };
        }

        /// go-git `RemoveReference`.
        pub fn removeReference(self: *Self, n: ReferenceName) Error!void {
            try self.dir.removeRef(n);
        }

        /// go-git `CountLooseRefs`.
        pub fn countLooseRefs(self: *Self) Error!usize {
            return try self.dir.countLooseRefs();
        }

        /// go-git `PackRefs`.
        pub fn packRefs(self: *Self) Error!void {
            try self.dir.packRefs();
        }

        /// Validate every update and snapshot the old values before any ref is
        /// visible. The caller must deinitialize the returned preparation.
        pub fn prepareUpdates(
            self: *Self,
            updates: []const ReferenceUpdate,
        ) !PreparedReferenceUpdates {
            var names: std.StringHashMapUnmanaged(void) = .empty;
            defer names.deinit(self.allocator);

            const previous = try self.allocator.alloc(?Reference, updates.len);
            errdefer self.allocator.free(previous);
            @memset(previous, null);
            var initialized: usize = 0;
            errdefer {
                for (previous[0..initialized]) |old| {
                    if (old) |ref| dotgit.freeRef(self.allocator, ref);
                }
            }

            for (updates, 0..) |update, i| {
                try update.name.validate();
                if (names.contains(update.name.raw)) return error.DuplicateReference;
                try names.put(self.allocator, update.name.raw, {});
                if (update.new_reference) |new_ref| {
                    if (!std.mem.eql(u8, new_ref.name.raw, update.name.raw)) {
                        return error.ReferenceNameMismatch;
                    }
                    try new_ref.name.validate();
                    if (new_ref.type == .symbolic) try new_ref.target.validate();
                }

                const current = self.reference(update.name) catch |err| switch (err) {
                    error.ReferenceNotFound => null,
                    else => |e| return e,
                };
                previous[i] = current;
                initialized = i + 1;

                if (update.require_absent and current != null) return error.ReferenceHasChanged;
                if (update.expected) |expected| {
                    if (current == null or !referencesEqual(current.?, expected)) {
                        return error.ReferenceHasChanged;
                    }
                }
            }
            return .{ .allocator = self.allocator, .previous = previous };
        }

        /// Apply a prepared update set. A write failure restores every earlier
        /// ref from the preparation before returning the original error.
        pub fn commitPrepared(
            self: *Self,
            updates: []const ReferenceUpdate,
            prepared: *PreparedReferenceUpdates,
        ) !void {
            std.debug.assert(updates.len == prepared.previous.len);
            var applied: usize = 0;
            errdefer {
                var i = applied;
                while (i > 0) {
                    i -= 1;
                    const update = updates[i];
                    if (prepared.previous[i]) |old| {
                        self.setReference(old) catch {};
                    } else {
                        self.removeReference(update.name) catch {};
                    }
                }
            }

            for (updates) |update| {
                if (update.new_reference) |new_ref| {
                    try self.setReference(new_ref);
                } else {
                    try self.removeReference(update.name);
                }
                applied += 1;
            }
        }
    };
}

pub const PreparedReferenceUpdates = struct {
    allocator: Allocator,
    previous: []?Reference,

    pub fn deinit(self: *PreparedReferenceUpdates) void {
        for (self.previous) |old| {
            if (old) |ref| dotgit.freeRef(self.allocator, ref);
        }
        self.allocator.free(self.previous);
        self.* = undefined;
    }
};

fn referencesEqual(a: Reference, b: Reference) bool {
    if (a.type != b.type) return false;
    if (!std.mem.eql(u8, a.name.raw, b.name.raw)) return false;
    return switch (a.type) {
        .hash => a.hash.eql(b.hash),
        .symbolic => std.mem.eql(u8, a.target.raw, b.target.raw),
        .invalid => true,
    };
}

/// Mem specialisation.
pub const ReferenceStorageMem = ReferenceStorage(fs_pkg.Mem);
/// Os specialisation.
pub const ReferenceStorageOs = ReferenceStorage(fs_pkg.Os);

pub const ReferenceSliceIter = struct {
    allocator: Allocator,
    items: []Reference = &.{},
    pos: usize = 0,

    pub fn deinit(self: *ReferenceSliceIter) void {
        for (self.items) |r| dotgit.freeRef(self.allocator, r);
        if (self.items.len > 0) self.allocator.free(self.items);
        self.items = &.{};
    }

    /// Next reference or `error.EndOfStream` (go-git `io.EOF`; matches memory suite).
    pub fn next(self: *ReferenceSliceIter) error{EndOfStream}!Reference {
        if (self.pos >= self.items.len) return error.EndOfStream;
        const r = self.items[self.pos];
        self.pos += 1;
        return r;
    }
};
