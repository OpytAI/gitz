//! Noder interface for merkletrie elements (go-git `utils/merkletrie/noder`).
//!
//! Zig uses a thin vtable so DiffTree can walk heterogeneous trees (index,
//! filesystem, test fsnoder) with one algorithm.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Empty children slice (go-git `NoChildren`).
pub const no_children: []Noder = &.{};

/// Type-erased merkletrie node (go-git `noder.Noder` + `Hasher` + `Stringer`).
pub const Noder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Merkle / content hash (go-git `Hasher.Hash`).
        hash: *const fn (ptr: *anyopaque) []const u8,
        /// Relative name of this element (go-git `Name`).
        name: *const fn (ptr: *anyopaque) []const u8,
        /// Directory-like vs file-like (go-git `IsDir`).
        is_dir: *const fn (ptr: *anyopaque) bool,
        /// Children; caller owns the returned slice of `Noder` values.
        children: *const fn (ptr: *anyopaque, allocator: Allocator) anyerror![]Noder,
        /// Child count (may be O(1) vs full `children`).
        num_children: *const fn (ptr: *anyopaque) anyerror!usize,
        /// Sparse-checkout / skip-worktree (go-git `Skip`).
        skip: *const fn (ptr: *anyopaque) bool,
        /// Debug string (go-git `fmt.Stringer`).
        string: *const fn (ptr: *anyopaque, allocator: Allocator) anyerror![]u8,
    };

    pub fn hash(self: Noder) []const u8 {
        return self.vtable.hash(self.ptr);
    }

    pub fn name(self: Noder) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn isDir(self: Noder) bool {
        return self.vtable.is_dir(self.ptr);
    }

    pub fn children(self: Noder, allocator: Allocator) anyerror![]Noder {
        return self.vtable.children(self.ptr, allocator);
    }

    pub fn numChildren(self: Noder) anyerror!usize {
        return self.vtable.num_children(self.ptr);
    }

    pub fn skip(self: Noder) bool {
        return self.vtable.skip(self.ptr);
    }

    /// Caller frees the returned slice.
    pub fn string(self: Noder, allocator: Allocator) anyerror![]u8 {
        return self.vtable.string(self.ptr, allocator);
    }

    pub fn eql(self: Noder, other: Noder) bool {
        return self.ptr == other.ptr and self.vtable == other.vtable;
    }
};

/// Compare two hashers by their hash bytes (go-git `noder.Equal` callback type).
pub const Equal = *const fn (a: Noder, b: Noder) bool;

/// Default equality: byte-equal hashes.
pub fn defaultEqual(a: Noder, b: Noder) bool {
    return std.mem.eql(u8, a.hash(), b.hash());
}

/// Wrap a concrete type that implements the Noder method set as a vtable.
///
/// Required methods on `T`:
/// - `hash(self: *T) []const u8`
/// - `name(self: *const T) []const u8` or `name(self: *T)`
/// - `isDir(self: *const T) bool` or `isDir(self: *T)`
/// - `children(self: *T, allocator: Allocator) anyerror![]Noder`
/// - `numChildren(self: *T) anyerror!usize`
/// - `skip(self: *const T) bool` or `skip(self: *T)`
/// - `string(self: *T, allocator: Allocator) anyerror![]u8`
pub fn noderOf(comptime T: type, impl: *T) Noder {
    const gen = struct {
        fn hash(ptr: *anyopaque) []const u8 {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.hash();
        }
        fn name(ptr: *anyopaque) []const u8 {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.name();
        }
        fn isDir(ptr: *anyopaque) bool {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.isDir();
        }
        fn children(ptr: *anyopaque, allocator: Allocator) anyerror![]Noder {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.children(allocator);
        }
        fn numChildren(ptr: *anyopaque) anyerror!usize {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.numChildren();
        }
        fn skip(ptr: *anyopaque) bool {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.skip();
        }
        fn string(ptr: *anyopaque, allocator: Allocator) anyerror![]u8 {
            const self: *T = @ptrCast(@alignCast(ptr));
            return self.string(allocator);
        }

        const vtable = Noder.VTable{
            .hash = hash,
            .name = name,
            .is_dir = isDir,
            .children = children,
            .num_children = numChildren,
            .skip = skip,
            .string = string,
        };
    };
    return .{
        .ptr = impl,
        .vtable = &gen.vtable,
    };
}

// ---------------------------------------------------------------------------
// Tests — mock noder (go-git noder_test.go)
// ---------------------------------------------------------------------------

const NoderMock = struct {
    name_s: []const u8,
    hash_b: []const u8 = &.{},
    is_dir: bool = false,
    kids: []const Noder = &.{},
    skip_v: bool = false,

    pub fn hash(self: *NoderMock) []const u8 {
        return self.hash_b;
    }
    pub fn name(self: *NoderMock) []const u8 {
        return self.name_s;
    }
    pub fn isDir(self: *NoderMock) bool {
        return self.is_dir;
    }
    pub fn children(self: *NoderMock, allocator: Allocator) anyerror![]Noder {
        return try allocator.dupe(Noder, self.kids);
    }
    pub fn numChildren(self: *NoderMock) anyerror!usize {
        return self.kids.len;
    }
    pub fn skip(self: *NoderMock) bool {
        return self.skip_v;
    }
    pub fn string(self: *NoderMock, allocator: Allocator) anyerror![]u8 {
        return try allocator.dupe(u8, self.name_s);
    }
};

test "NoderMock basic" {
    var c1 = NoderMock{ .name_s = "c1" };
    var c2 = NoderMock{ .name_s = "c2" };
    const kids = [_]Noder{ noderOf(NoderMock, &c1), noderOf(NoderMock, &c2) };
    var n1 = NoderMock{
        .name_s = "1",
        .hash_b = &[_]u8{ 0x00, 0x01, 0x02 },
        .is_dir = true,
        .kids = &kids,
    };
    const n = noderOf(NoderMock, &n1);
    try std.testing.expectEqualStrings("1", n.name());
    try std.testing.expect(n.isDir());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x02 }, n.hash());
    try std.testing.expectEqual(@as(usize, 2), try n.numChildren());
    try std.testing.expect(!n.skip());
}
