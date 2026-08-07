//! Reference storer helpers (go-git `plumbing/storer/reference.go`).
//!
//! ReferenceStorer method set is documented in `root.zig`.
//!
//! # go-git test map
//!
//! | go-git test | Zig test |
//! |---|---|
//! | TestReferenceSliceIterNext | `ReferenceSliceIter next` |
//! | TestReferenceSliceIterForEach | `ReferenceSliceIter forEach` |
//! | TestReferenceSliceIterForEachError | `ReferenceSliceIter forEach error` |
//! | TestReferenceSliceIterForEachStop | `ReferenceSliceIter forEach stop` |
//! | TestReferenceFilteredIterNext | `ReferenceFilteredIter next` |
//! | TestReferenceFilteredIterForEach | `ReferenceFilteredIter forEach` |
//! | TestReferenceFilteredIterError | `ReferenceFilteredIter forEach error` |
//! | TestReferenceFilteredIterForEachStop | `ReferenceFilteredIter forEach stop` |
//! | TestMultiReferenceIterForEach | `MultiReferenceIter forEach` |
//!
//! Extra resolve / multi next coverage (go-git has no unit tests for resolve):
//!
//! | Coverage | Zig test |
//! |---|---|
//! | Resolve hash identity | `resolveReference hash ref is identity` |
//! | Resolve symbolic chain | `resolveReference follows symbolic chain` |
//! | Resolve missing | `resolveReference missing name` |
//! | MaxResolveRecursion | `resolveReference MaxResolveRecursion` |
//! | Function getter | `resolveReference accepts function getter` |
//! | Multi next | `MultiReferenceIter next` |
//! | Multi forEach stop/error | `MultiReferenceIter forEach stop/error` |

const std = @import("std");
const plumbing = @import("plumbing");
const error_mod = @import("error.zig");

const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const ReferenceType = plumbing.ReferenceType;

/// Maximum symbolic-ref hops when resolving (go-git `MaxResolveRecursion`).
pub const MaxResolveRecursion: usize = 1024;

// Re-export package errors for local use (`error.Stop`, `error.MaxResolveRecursion`).
pub const Error = error_mod.Error;

// ---------------------------------------------------------------------------
// Type-erased ReferenceIter (go-git ReferenceIter interface)
// ---------------------------------------------------------------------------

/// Type-erased closable iterator over references.
///
/// `next` returns `error.EndOfStream` at end (go-git `io.EOF`).
pub const ReferenceIter = struct {
    ptr: *anyopaque,
    next_fn: *const fn (ptr: *anyopaque) anyerror!*const Reference,
    close_fn: *const fn (ptr: *anyopaque) void,

    pub fn next(self: ReferenceIter) anyerror!*const Reference {
        return self.next_fn(self.ptr);
    }

    pub fn close(self: ReferenceIter) void {
        self.close_fn(self.ptr);
    }

    /// go-git `ReferenceIter.ForEach`.
    pub fn forEach(self: ReferenceIter, cb: anytype) !void {
        return forEachReference(self, cb);
    }
};

// ---------------------------------------------------------------------------
// forEachReference (go-git forEachReferenceIter)
// ---------------------------------------------------------------------------

/// Shared ForEach for bare reference iterators with `next` + `close`
/// (go-git `forEachReferenceIter`).
///
/// - `error.EndOfStream` from `next` ends iteration successfully.
/// - `error.Stop` from `cb` ends iteration successfully (go-git `ErrStop`).
/// - Other errors propagate. The iterator is always closed.
///
/// `cb` is `fn (*const Reference) !void` (any error set including `error.Stop`).
pub fn forEachReference(iter: anytype, cb: anytype) !void {
    defer iter.close();
    while (true) {
        const ref = iter.next() catch |err| {
            const e: anyerror = err;
            if (e == error.EndOfStream) return;
            return e;
        };

        cb(ref) catch |err| {
            // `error.Stop` (go-git ErrStop) ends successfully even when the
            // callback error set does not list Stop explicitly.
            const e: anyerror = err;
            if (e == error.Stop) return;
            return e;
        };
    }
}

// ---------------------------------------------------------------------------
// ReferenceSliceIter
// ---------------------------------------------------------------------------

/// Iterate a fixed slice of references (go-git `ReferenceSliceIter`).
/// Series elements are borrowed; caller owns storage.
pub const ReferenceSliceIter = struct {
    series: []const Reference,
    pos: usize = 0,

    /// go-git `NewReferenceSliceIter` / inventory `ReferenceSliceIter.init`.
    pub fn init(series: []const Reference) ReferenceSliceIter {
        return .{ .series = series };
    }

    /// go-git `ReferenceSliceIter.Next`.
    pub fn next(self: *ReferenceSliceIter) anyerror!*const Reference {
        if (self.pos >= self.series.len) return error.EndOfStream;
        const obj = &self.series[self.pos];
        self.pos += 1;
        return obj;
    }

    /// go-git `ReferenceSliceIter.ForEach`.
    pub fn forEach(self: *ReferenceSliceIter, cb: anytype) !void {
        return forEachReference(self, cb);
    }

    /// go-git `ReferenceSliceIter.Close`.
    pub fn close(self: *ReferenceSliceIter) void {
        self.pos = self.series.len;
    }

    /// Erase to `ReferenceIter` for composition.
    pub fn asIter(self: *ReferenceSliceIter) ReferenceIter {
        return .{
            .ptr = self,
            .next_fn = nextThunk,
            .close_fn = closeThunk,
        };
    }

    fn nextThunk(ptr: *anyopaque) anyerror!*const Reference {
        const self: *ReferenceSliceIter = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn closeThunk(ptr: *anyopaque) void {
        const self: *ReferenceSliceIter = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// go-git `NewReferenceSliceIter` free-function alias.
pub fn newReferenceSliceIter(series: []const Reference) ReferenceSliceIter {
    return ReferenceSliceIter.init(series);
}

// ---------------------------------------------------------------------------
// ReferenceFilteredIter
// ---------------------------------------------------------------------------

/// Filter an underlying iterator (go-git `referenceFilteredIter`).
pub const ReferenceFilteredIter = struct {
    filter: *const fn (r: *const Reference) bool,
    inner: ReferenceIter,

    /// go-git `NewReferenceFilteredIter`.
    pub fn init(
        filter: *const fn (r: *const Reference) bool,
        inner: ReferenceIter,
    ) ReferenceFilteredIter {
        return .{ .filter = filter, .inner = inner };
    }

    /// go-git `referenceFilteredIter.Next`.
    pub fn next(self: *ReferenceFilteredIter) anyerror!*const Reference {
        while (true) {
            const r = try self.inner.next();
            if (self.filter(r)) return r;
        }
    }

    /// go-git `referenceFilteredIter.ForEach`.
    ///
    /// Matches go-git: close on finish / Stop / error; Stop is not a failure.
    pub fn forEach(self: *ReferenceFilteredIter, cb: anytype) !void {
        defer self.close();
        while (true) {
            const r = self.next() catch |err| {
                const e: anyerror = err;
                if (e == error.EndOfStream) return;
                return e;
            };
            cb(r) catch |err| {
                const e: anyerror = err;
                if (e == error.Stop) return;
                return e;
            };
        }
    }

    /// go-git `referenceFilteredIter.Close`.
    pub fn close(self: *ReferenceFilteredIter) void {
        self.inner.close();
    }

    /// Erase to `ReferenceIter` for composition.
    pub fn asIter(self: *ReferenceFilteredIter) ReferenceIter {
        return .{
            .ptr = self,
            .next_fn = nextThunk,
            .close_fn = closeThunk,
        };
    }

    fn nextThunk(ptr: *anyopaque) anyerror!*const Reference {
        const self: *ReferenceFilteredIter = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn closeThunk(ptr: *anyopaque) void {
        const self: *ReferenceFilteredIter = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// go-git `NewReferenceFilteredIter` free-function alias.
pub fn newReferenceFilteredIter(
    filter: *const fn (r: *const Reference) bool,
    inner: ReferenceIter,
) ReferenceFilteredIter {
    return ReferenceFilteredIter.init(filter, inner);
}

// ---------------------------------------------------------------------------
// MultiReferenceIter
// ---------------------------------------------------------------------------

/// Concatenate several iterators (go-git `MultiReferenceIter`).
/// `iters` is borrowed and advanced by slicing off exhausted heads.
pub const MultiReferenceIter = struct {
    iters: []ReferenceIter,

    /// go-git `NewMultiReferenceIter` / inventory `MultiReferenceIter.init`.
    pub fn init(iters: []ReferenceIter) MultiReferenceIter {
        return .{ .iters = iters };
    }

    /// go-git `MultiReferenceIter.Next`.
    pub fn next(self: *MultiReferenceIter) anyerror!*const Reference {
        while (self.iters.len > 0) {
            const obj = self.iters[0].next() catch |err| {
                const e: anyerror = err;
                if (e == error.EndOfStream) {
                    self.iters[0].close();
                    self.iters = self.iters[1..];
                    continue;
                }
                return e;
            };
            return obj;
        }
        return error.EndOfStream;
    }

    /// go-git `MultiReferenceIter.ForEach`.
    pub fn forEach(self: *MultiReferenceIter, cb: anytype) !void {
        return forEachReference(self, cb);
    }

    /// go-git `MultiReferenceIter.Close`.
    pub fn close(self: *MultiReferenceIter) void {
        for (self.iters) |it| it.close();
        self.iters = self.iters[0..0];
    }

    /// Erase to `ReferenceIter` for composition.
    pub fn asIter(self: *MultiReferenceIter) ReferenceIter {
        return .{
            .ptr = self,
            .next_fn = nextThunk,
            .close_fn = closeThunk,
        };
    }

    fn nextThunk(ptr: *anyopaque) anyerror!*const Reference {
        const self: *MultiReferenceIter = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn closeThunk(ptr: *anyopaque) void {
        const self: *MultiReferenceIter = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// go-git `NewMultiReferenceIter` free-function alias.
pub fn newMultiReferenceIter(iters: []ReferenceIter) MultiReferenceIter {
    return MultiReferenceIter.init(iters);
}

// ---------------------------------------------------------------------------
// ResolveReference
// ---------------------------------------------------------------------------

/// Resolve a reference name through symbolic links to a hash reference
/// (go-git `ResolveReference`).
///
/// `get` is either:
/// - a callable `fn (name: ReferenceName) !Reference`, or
/// - a store value/pointer with method `reference(name: ReferenceName) !Reference`.
///
/// Missing names should return `error.ReferenceNotFound` (plumbing).
/// Symbolic chains longer than `MaxResolveRecursion` return
/// `error.MaxResolveRecursion` (go-git `ErrMaxResolveRecursion`).
///
/// Loop form (same counters as go-git recursion) avoids stack overflow on
/// long or cyclic symbolic chains.
pub fn resolveReference(get: anytype, name: ReferenceName) !Reference {
    const r = try callGet(get, name);
    return resolveReferenceFrom(get, r);
}

/// Resolve an already-loaded reference through symbolic targets
/// (go-git unexported `resolveReference`).
pub fn resolveReferenceFrom(get: anytype, start: Reference) !Reference {
    var r = start;
    var recursion: usize = 0;
    while (r.type == ReferenceType.symbolic) {
        if (recursion > MaxResolveRecursion) return error.MaxResolveRecursion;
        r = try callGet(get, r.target);
        recursion += 1;
    }
    return r;
}

fn callGet(get: anytype, name: ReferenceName) !Reference {
    const G = @TypeOf(get);
    if (comptime hasReferenceMethod(G)) {
        return get.reference(name);
    }
    return get(name);
}

fn hasReferenceMethod(comptime G: type) bool {
    // Zig 0.16: @hasDecl requires struct/enum/union/opaque — not fn types.
    // Function getters (fn (ReferenceName) !Reference) must return false here.
    const info = @typeInfo(G);
    const Base = switch (info) {
        .pointer => |p| p.child,
        .@"fn" => return false,
        else => G,
    };
    return switch (@typeInfo(Base)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(Base, "reference"),
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests (go-git reference_test.go + resolve behaviour)
// ---------------------------------------------------------------------------

fn filterBar(r: *const Reference) bool {
    return std.mem.eql(u8, r.name.string(), "bar");
}

// --- go-git TestReferenceSliceIterNext ---

test "ReferenceSliceIter next" {
    const slice = [_]Reference{
        Reference.fromStrings("foo", "foo"),
        Reference.fromStrings("bar", "bar"),
    };
    var i = ReferenceSliceIter.init(&slice);

    const foo = try i.next();
    try std.testing.expect(foo == &slice[0]);

    const bar = try i.next();
    try std.testing.expect(bar == &slice[1]);

    try std.testing.expectError(error.EndOfStream, i.next());
}

// --- go-git TestReferenceSliceIterForEach ---

test "ReferenceSliceIter forEach" {
    const slice = [_]Reference{
        Reference.fromStrings("foo", "foo"),
        Reference.fromStrings("bar", "bar"),
    };
    var i = ReferenceSliceIter.init(&slice);
    var count: usize = 0;
    const Gen = struct {
        var series: []const Reference = undefined;
        var n: *usize = undefined;
        fn cb(r: *const Reference) !void {
            try std.testing.expect(r == &series[n.*]);
            n.* += 1;
        }
    };
    Gen.series = &slice;
    Gen.n = &count;
    try i.forEach(Gen.cb);
    try std.testing.expectEqual(@as(usize, 2), count);
}

// --- go-git TestReferenceSliceIterForEachError ---

test "ReferenceSliceIter forEach error" {
    const slice = [_]Reference{
        Reference.fromStrings("foo", "foo"),
        Reference.fromStrings("bar", "bar"),
    };
    var i = ReferenceSliceIter.init(&slice);
    var count: usize = 0;
    const Gen = struct {
        var series: []const Reference = undefined;
        var n: *usize = undefined;
        fn cb(r: *const Reference) !void {
            try std.testing.expect(r == &series[n.*]);
            n.* += 1;
            if (n.* == 2) return error.SomeError;
        }
    };
    Gen.series = &slice;
    Gen.n = &count;
    try std.testing.expectError(error.SomeError, i.forEach(Gen.cb));
    try std.testing.expectEqual(@as(usize, 2), count);
}

// --- go-git TestReferenceSliceIterForEachStop ---

test "ReferenceSliceIter forEach stop" {
    const slice = [_]Reference{
        Reference.fromStrings("foo", "foo"),
        Reference.fromStrings("bar", "bar"),
    };
    var i = ReferenceSliceIter.init(&slice);
    var count: usize = 0;
    const Gen = struct {
        var series: []const Reference = undefined;
        var n: *usize = undefined;
        fn cb(r: *const Reference) !void {
            try std.testing.expect(r == &series[n.*]);
            n.* += 1;
            return error.Stop;
        }
    };
    Gen.series = &slice;
    Gen.n = &count;
    try i.forEach(Gen.cb);
    try std.testing.expectEqual(@as(usize, 1), count);
}

// --- go-git TestReferenceFilteredIterNext ---

test "ReferenceFilteredIter next" {
    const slice = [_]Reference{
        Reference.fromStrings("foo", "foo"),
        Reference.fromStrings("bar", "bar"),
    };
    var base = ReferenceSliceIter.init(&slice);
    var i = ReferenceFilteredIter.init(filterBar, base.asIter());

    const got = try i.next();
    try std.testing.expect(got != &slice[0]);
    try std.testing.expect(got == &slice[1]);
    try std.testing.expectError(error.EndOfStream, i.next());
}

// --- go-git TestReferenceFilteredIterForEach ---

test "ReferenceFilteredIter forEach" {
    const slice = [_]Reference{
        Reference.fromStrings("foo", "foo"),
        Reference.fromStrings("bar", "bar"),
    };
    var base = ReferenceSliceIter.init(&slice);
    var i = ReferenceFilteredIter.init(filterBar, base.asIter());
    var count: usize = 0;
    const Gen = struct {
        var expected: *const Reference = undefined;
        var n: *usize = undefined;
        fn cb(r: *const Reference) !void {
            try std.testing.expect(r == expected);
            n.* += 1;
        }
    };
    Gen.expected = &slice[1];
    Gen.n = &count;
    try i.forEach(Gen.cb);
    try std.testing.expectEqual(@as(usize, 1), count);
}

// --- go-git TestReferenceFilteredIterError ---

test "ReferenceFilteredIter forEach error" {
    const slice = [_]Reference{
        Reference.fromStrings("foo", "foo"),
        Reference.fromStrings("bar", "bar"),
    };
    var base = ReferenceSliceIter.init(&slice);
    var i = ReferenceFilteredIter.init(filterBar, base.asIter());
    var count: usize = 0;
    const Gen = struct {
        var expected: *const Reference = undefined;
        var n: *usize = undefined;
        fn cb(r: *const Reference) !void {
            try std.testing.expect(r == expected);
            n.* += 1;
            if (n.* == 1) return error.SomeError;
        }
    };
    Gen.expected = &slice[1];
    Gen.n = &count;
    try std.testing.expectError(error.SomeError, i.forEach(Gen.cb));
    try std.testing.expectEqual(@as(usize, 1), count);
}

// --- go-git TestReferenceFilteredIterForEachStop ---

test "ReferenceFilteredIter forEach stop" {
    const slice = [_]Reference{
        Reference.fromStrings("foo", "foo"),
        Reference.fromStrings("bar", "bar"),
    };
    var base = ReferenceSliceIter.init(&slice);
    var i = ReferenceFilteredIter.init(filterBar, base.asIter());
    var count: usize = 0;
    const Gen = struct {
        var expected: *const Reference = undefined;
        var n: *usize = undefined;
        fn cb(r: *const Reference) !void {
            try std.testing.expect(r == expected);
            n.* += 1;
            return error.Stop;
        }
    };
    Gen.expected = &slice[1];
    Gen.n = &count;
    try i.forEach(Gen.cb);
    try std.testing.expectEqual(@as(usize, 1), count);
}

// --- go-git TestMultiReferenceIterForEach ---

test "MultiReferenceIter forEach" {
    const a = [_]Reference{Reference.fromStrings("foo", "foo")};
    const b = [_]Reference{Reference.fromStrings("bar", "bar")};
    var ia = ReferenceSliceIter.init(&a);
    var ib = ReferenceSliceIter.init(&b);
    var iters = [_]ReferenceIter{ ia.asIter(), ib.asIter() };
    var i = MultiReferenceIter.init(&iters);

    var result: [2][]const u8 = undefined;
    var n: usize = 0;
    const Gen = struct {
        var out: *[2][]const u8 = undefined;
        var idx: *usize = undefined;
        fn cb(r: *const Reference) !void {
            out.*[idx.*] = r.name.string();
            idx.* += 1;
        }
    };
    Gen.out = &result;
    Gen.idx = &n;
    try i.forEach(Gen.cb);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("foo", result[0]);
    try std.testing.expectEqualStrings("bar", result[1]);
}

test "MultiReferenceIter next" {
    const a = [_]Reference{Reference.fromStrings("foo", "foo")};
    const empty = [_]Reference{};
    const b = [_]Reference{Reference.fromStrings("bar", "bar")};
    var ia = ReferenceSliceIter.init(&a);
    var i_empty = ReferenceSliceIter.init(&empty);
    var ib = ReferenceSliceIter.init(&b);
    var iters = [_]ReferenceIter{ ia.asIter(), i_empty.asIter(), ib.asIter() };
    var i = MultiReferenceIter.init(&iters);

    const foo = try i.next();
    try std.testing.expectEqualStrings("foo", foo.name.string());
    const bar = try i.next();
    try std.testing.expectEqualStrings("bar", bar.name.string());
    try std.testing.expectError(error.EndOfStream, i.next());
}

test "MultiReferenceIter forEach stop" {
    const a = [_]Reference{
        Reference.fromStrings("foo", "foo"),
        Reference.fromStrings("bar", "bar"),
    };
    var ia = ReferenceSliceIter.init(&a);
    var iters = [_]ReferenceIter{ia.asIter()};
    var i = MultiReferenceIter.init(&iters);

    var count: usize = 0;
    const Gen = struct {
        var n: *usize = undefined;
        fn cb(_: *const Reference) !void {
            n.* += 1;
            return error.Stop;
        }
    };
    Gen.n = &count;
    try i.forEach(Gen.cb);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "MultiReferenceIter forEach error" {
    const a = [_]Reference{
        Reference.fromStrings("foo", "foo"),
        Reference.fromStrings("bar", "bar"),
    };
    var ia = ReferenceSliceIter.init(&a);
    var iters = [_]ReferenceIter{ia.asIter()};
    var i = MultiReferenceIter.init(&iters);

    try std.testing.expectError(error.SomeError, i.forEach(struct {
        fn cb(_: *const Reference) error{SomeError}!void {
            return error.SomeError;
        }
    }.cb));
}

test "newReference* free aliases match init" {
    const slice = [_]Reference{Reference.fromStrings("foo", "foo")};
    const a = ReferenceSliceIter.init(&slice);
    const b = newReferenceSliceIter(&slice);
    try std.testing.expectEqual(a.series.len, b.series.len);

    var base = ReferenceSliceIter.init(&slice);
    const f0 = ReferenceFilteredIter.init(filterBar, base.asIter());
    var base2 = ReferenceSliceIter.init(&slice);
    const f1 = newReferenceFilteredIter(filterBar, base2.asIter());
    try std.testing.expect(f0.filter == f1.filter);

    var ia = ReferenceSliceIter.init(&slice);
    var iters = [_]ReferenceIter{ia.asIter()};
    const m0 = MultiReferenceIter.init(&iters);
    const m1 = newMultiReferenceIter(&iters);
    try std.testing.expectEqual(m0.iters.len, m1.iters.len);
}

// --- ResolveReference ---

const MapStore = struct {
    entries: []const Reference,

    pub fn reference(self: MapStore, name: ReferenceName) !Reference {
        for (self.entries) |e| {
            if (e.name.eql(name)) return e;
        }
        return error.ReferenceNotFound;
    }
};

test "resolveReference hash ref is identity" {
    const h = plumbing.newHash("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    const entries = [_]Reference{
        Reference.newHashReference(ReferenceName.init("refs/heads/main"), h),
    };
    const store = MapStore{ .entries = &entries };
    const got = try resolveReference(store, ReferenceName.init("refs/heads/main"));
    try std.testing.expect(got.type == .hash);
    try std.testing.expect(got.hash.eql(h));
}

test "resolveReference follows symbolic chain" {
    const h = plumbing.newHash("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    const entries = [_]Reference{
        Reference.newSymbolicReference(plumbing.HEAD, plumbing.master),
        Reference.newHashReference(plumbing.master, h),
    };
    const store = MapStore{ .entries = &entries };
    const got = try resolveReference(store, plumbing.HEAD);
    try std.testing.expect(got.type == .hash);
    try std.testing.expect(got.hash.eql(h));
    try std.testing.expectEqualStrings("refs/heads/master", got.name.string());
}

test "resolveReference missing name" {
    const store = MapStore{ .entries = &.{} };
    try std.testing.expectError(
        error.ReferenceNotFound,
        resolveReference(store, plumbing.HEAD),
    );
}

test "resolveReference missing target in chain" {
    const entries = [_]Reference{
        Reference.newSymbolicReference(plumbing.HEAD, plumbing.master),
    };
    const store = MapStore{ .entries = &entries };
    try std.testing.expectError(
        error.ReferenceNotFound,
        resolveReference(store, plumbing.HEAD),
    );
}

test "resolveReference MaxResolveRecursion" {
    // Cycle forces the recursion counter past MaxResolveRecursion.
    const entries = [_]Reference{
        Reference.newSymbolicReference(ReferenceName.init("refs/a"), ReferenceName.init("refs/b")),
        Reference.newSymbolicReference(ReferenceName.init("refs/b"), ReferenceName.init("refs/a")),
    };
    const store = MapStore{ .entries = &entries };
    try std.testing.expectError(
        error.MaxResolveRecursion,
        resolveReference(store, ReferenceName.init("refs/a")),
    );
}

test "resolveReference accepts function getter" {
    const getFn = struct {
        fn get(name: ReferenceName) !Reference {
            if (std.mem.eql(u8, name.string(), "refs/heads/x")) {
                return Reference.newHashReference(
                    name,
                    plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
                );
            }
            return error.ReferenceNotFound;
        }
    }.get;
    const got = try resolveReference(getFn, ReferenceName.init("refs/heads/x"));
    try std.testing.expect(got.type == .hash);
    try std.testing.expect(got.hash.eql(plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")));
}

test "resolveReferenceFrom starts from loaded ref" {
    const h = plumbing.newHash("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    const entries = [_]Reference{
        Reference.newSymbolicReference(plumbing.HEAD, plumbing.master),
        Reference.newHashReference(plumbing.master, h),
    };
    const store = MapStore{ .entries = &entries };
    const start = try store.reference(plumbing.HEAD);
    const got = try resolveReferenceFrom(store, start);
    try std.testing.expect(got.type == .hash);
    try std.testing.expect(got.hash.eql(h));
}

test "MaxResolveRecursion constant" {
    try std.testing.expectEqual(@as(usize, 1024), MaxResolveRecursion);
}

test "ReferenceIter type erase forEach" {
    const slice = [_]Reference{
        Reference.fromStrings("foo", "foo"),
        Reference.fromStrings("bar", "bar"),
    };
    var base = ReferenceSliceIter.init(&slice);
    const erased = base.asIter();
    var count: usize = 0;
    const Gen = struct {
        var n: *usize = undefined;
        fn cb(_: *const Reference) !void {
            n.* += 1;
        }
    };
    Gen.n = &count;
    try erased.forEach(Gen.cb);
    try std.testing.expectEqual(@as(usize, 2), count);
}
