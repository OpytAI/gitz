//! Parallel walk of two merkletries (go-git `utils/merkletrie/doubleiter.go`).

const std = @import("std");
const noder = @import("noder");
const iter_mod = @import("iter.zig");

const Allocator = std.mem.Allocator;
const Noder = noder.Noder;
const Path = noder.Path;
const Equal = noder.Equal;
const Iter = iter_mod.Iter;

pub const Remaining = enum {
    no_more_noders,
    only_to_remains,
    only_from_remains,
    both_have_nodes,
};

pub const Comparison = struct {
    same_hash: bool = false,
    both_are_files: bool = false,
    file_and_dir: bool = false,
    both_are_dirs: bool = false,
    from_is_empty_dir: bool = false,
    to_is_empty_dir: bool = false,
};

const Side = struct {
    iter: Iter,
    current: ?Path = null,

    fn deinit(self: *Side, allocator: Allocator) void {
        if (self.current) |*p| p.deinit(allocator);
        self.current = null;
        self.iter.deinit();
    }
};

/// Parallel iterators over two trees (go-git `doubleIter`).
pub const DoubleIter = struct {
    from: Side,
    to: Side,
    hash_equal: Equal,
    allocator: Allocator,

    pub fn init(allocator: Allocator, from: Noder, to: Noder, hash_equal: Equal) anyerror!DoubleIter {
        var di: DoubleIter = .{
            .from = .{ .iter = try Iter.init(allocator, from) },
            .to = .{ .iter = undefined },
            .hash_equal = hash_equal,
            .allocator = allocator,
        };
        errdefer di.from.iter.deinit();

        di.to.iter = try Iter.init(allocator, to);
        errdefer di.to.iter.deinit();

        di.from.current = try takeNext(&di.from.iter);
        errdefer if (di.from.current) |*p| p.deinit(allocator);

        di.to.current = try takeNext(&di.to.iter);
        return di;
    }

    pub fn deinit(self: *DoubleIter) void {
        self.from.deinit(self.allocator);
        self.to.deinit(self.allocator);
        self.* = undefined;
    }

    fn takeNext(it: *Iter) anyerror!?Path {
        const p = it.next() catch |err| {
            if (err == error.EndOfStream) return null;
            return err;
        };
        return p;
    }

    pub fn nextBoth(self: *DoubleIter) anyerror!void {
        try self.nextFrom();
        try self.nextTo();
    }

    pub fn nextFrom(self: *DoubleIter) anyerror!void {
        if (self.from.current) |*p| p.deinit(self.allocator);
        self.from.current = try takeNext(&self.from.iter);
    }

    pub fn nextTo(self: *DoubleIter) anyerror!void {
        if (self.to.current) |*p| p.deinit(self.allocator);
        self.to.current = try takeNext(&self.to.iter);
    }

    pub fn stepBoth(self: *DoubleIter) anyerror!void {
        if (self.from.current) |*p| p.deinit(self.allocator);
        self.from.current = blk: {
            const p = self.from.iter.step() catch |err| {
                if (err == error.EndOfStream) break :blk null;
                return err;
            };
            break :blk p;
        };
        if (self.to.current) |*p| p.deinit(self.allocator);
        self.to.current = blk: {
            const p = self.to.iter.step() catch |err| {
                if (err == error.EndOfStream) break :blk null;
                return err;
            };
            break :blk p;
        };
    }

    pub fn remaining(self: *const DoubleIter) Remaining {
        const f = self.from.current != null;
        const t = self.to.current != null;
        if (!f and !t) return .no_more_noders;
        if (!f and t) return .only_to_remains;
        if (f and !t) return .only_from_remains;
        return .both_have_nodes;
    }

    pub fn compare(self: *const DoubleIter) anyerror!Comparison {
        const from_p = self.from.current.?;
        const to_p = self.to.current.?;
        var s: Comparison = .{};
        // go-git: hashEqual(from.current, to.current) — Path implements Hasher.
        s.same_hash = self.hash_equal(from_p.last(), to_p.last());

        const from_is_dir = from_p.isDir();
        const to_is_dir = to_p.isDir();
        s.both_are_dirs = from_is_dir and to_is_dir;
        s.both_are_files = !from_is_dir and !to_is_dir;
        s.file_and_dir = !s.both_are_dirs and !s.both_are_files;

        const from_n = try from_p.numChildren();
        const to_n = try to_p.numChildren();
        s.from_is_empty_dir = from_is_dir and from_n == 0;
        s.to_is_empty_dir = to_is_dir and to_n == 0;
        return s;
    }
};
