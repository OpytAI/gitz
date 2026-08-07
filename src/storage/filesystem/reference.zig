//! Filesystem reference storage (go-git `storage/filesystem/reference.go`).
//!
//! Thin wrappers over DotGit ref APIs. Monomorphised over `Fs`.

const std = @import("std");
const plumbing = @import("plumbing");
const fs_pkg = @import("fs");

const dotgit = @import("dotgit");

const Allocator = std.mem.Allocator;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;

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
