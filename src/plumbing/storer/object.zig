//! Encoded-object iterators and ForEach helpers (go-git `plumbing/storer/object.go`).
//!
//! Objects are always `*plumbing.MemoryObject` (no Go `EncodedObject` interface).
//!
//! # go-git test map
//!
//! | go-git test | Zig test |
//! |---|---|
//! | TestMultiObjectIterNext | `MultiEncodedObjectIter forEach` |
//! | TestObjectLookupIter | `EncodedObjectLookupIter forEach` |
//! | TestObjectSliceIter | `EncodedObjectSliceIter forEach` |
//! | TestObjectSliceIterStop | `EncodedObjectSliceIter forEach stop` |
//! | TestObjectSliceIterError | `EncodedObjectSliceIter forEach error` |
//!
//! Extra (composition completeness — full forEach / Stop / Error paths):
//!
//! | Coverage | Zig test |
//! |---|---|
//! | Lookup forEach Stop | `EncodedObjectLookupIter forEach stop` |
//! | Lookup forEach Error | `EncodedObjectLookupIter forEach error` |
//! | Lookup Next EOF / missing | `EncodedObjectLookupIter next` |
//! | Multi forEach Stop | `MultiEncodedObjectIter forEach stop` |
//! | Multi forEach Error | `MultiEncodedObjectIter forEach error` |
//! | Multi Next across empties | `MultiEncodedObjectIter next` |
//! | Slice Next / Close | `EncodedObjectSliceIter next` |
//! | ForEachIterator helper | `forEachIterator EndOfStream Stop Error` |

const std = @import("std");
const plumbing = @import("plumbing");

const Hash = plumbing.Hash;
const ObjectType = plumbing.ObjectType;
const MemoryObject = plumbing.MemoryObject;

/// Discard a never-set create on any storer that implements `discardEncodedObject`.
///
/// Prefer the method form (`store.discardEncodedObject(obj)`) at monomorphised
/// call sites. This free function is for `anytype` helpers.
pub fn discardEncodedObject(store: anytype, obj: *MemoryObject) void {
    store.discardEncodedObject(obj);
}

// ---------------------------------------------------------------------------
// Type-erased EncodedObjectIter (go-git EncodedObjectIter interface)
// ---------------------------------------------------------------------------

/// Type-erased closable iterator over `*MemoryObject`.
///
/// `next` returns `error.EndOfStream` at end (go-git `io.EOF`). Other errors
/// (for example `error.ObjectNotFound` from a lookup) propagate.
pub const EncodedObjectIter = struct {
    ptr: *anyopaque,
    next_fn: *const fn (ptr: *anyopaque) anyerror!*MemoryObject,
    close_fn: *const fn (ptr: *anyopaque) void,

    pub fn next(self: EncodedObjectIter) anyerror!*MemoryObject {
        return self.next_fn(self.ptr);
    }

    pub fn close(self: EncodedObjectIter) void {
        self.close_fn(self.ptr);
    }

    /// go-git `EncodedObjectIter.ForEach`.
    pub fn forEach(self: EncodedObjectIter, cb: anytype) !void {
        return forEachIterator(self, cb);
    }
};

// ---------------------------------------------------------------------------
// ObjectGetter (EncodedObjectStorer.EncodedObject subset for LookupIter)
// ---------------------------------------------------------------------------

/// Minimal store surface for `EncodedObjectLookupIter`
/// (go-git `EncodedObjectStorer.EncodedObject`).
pub const ObjectGetter = struct {
    ptr: *anyopaque,
    encoded_object_fn: *const fn (ptr: *anyopaque, t: ObjectType, h: Hash) anyerror!*MemoryObject,

    pub fn encodedObject(self: ObjectGetter, t: ObjectType, h: Hash) anyerror!*MemoryObject {
        return self.encoded_object_fn(self.ptr, t, h);
    }

    /// Build from a type with
    /// `encodedObject(self: *T, t: ObjectType, h: Hash) anyerror!*MemoryObject`.
    pub fn from(comptime T: type, impl: *T) ObjectGetter {
        const gen = struct {
            fn get(ptr: *anyopaque, t: ObjectType, h: Hash) anyerror!*MemoryObject {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.encodedObject(t, h);
            }
        };
        return .{
            .ptr = impl,
            .encoded_object_fn = gen.get,
        };
    }
};

// ---------------------------------------------------------------------------
// EncodedObjectLookupIter
// ---------------------------------------------------------------------------

/// Lazy hash→object lookup iterator (go-git `EncodedObjectLookupIter`).
pub const EncodedObjectLookupIter = struct {
    storage: ObjectGetter,
    series: []const Hash,
    t: ObjectType,
    pos: usize = 0,

    /// go-git `NewEncodedObjectLookupIter` / inventory `EncodedObjectLookupIter.init`.
    pub fn init(storage: ObjectGetter, t: ObjectType, series: []const Hash) EncodedObjectLookupIter {
        return .{
            .storage = storage,
            .series = series,
            .t = t,
        };
    }

    /// go-git `EncodedObjectLookupIter.Next`.
    /// Advances `pos` only after a successful lookup (go-git).
    pub fn next(self: *EncodedObjectLookupIter) anyerror!*MemoryObject {
        if (self.pos >= self.series.len) return error.EndOfStream;

        const hash = self.series[self.pos];
        const obj = try self.storage.encodedObject(self.t, hash);
        self.pos += 1;
        return obj;
    }

    /// go-git `EncodedObjectLookupIter.ForEach`.
    pub fn forEach(self: *EncodedObjectLookupIter, cb: anytype) !void {
        return forEachIterator(self, cb);
    }

    /// go-git `EncodedObjectLookupIter.Close`.
    pub fn close(self: *EncodedObjectLookupIter) void {
        self.pos = self.series.len;
    }

    /// Erase to `EncodedObjectIter` for composition.
    pub fn asIter(self: *EncodedObjectLookupIter) EncodedObjectIter {
        return .{
            .ptr = self,
            .next_fn = nextThunk,
            .close_fn = closeThunk,
        };
    }

    fn nextThunk(ptr: *anyopaque) anyerror!*MemoryObject {
        const self: *EncodedObjectLookupIter = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn closeThunk(ptr: *anyopaque) void {
        const self: *EncodedObjectLookupIter = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// go-git `NewEncodedObjectLookupIter` free-function alias.
pub fn newEncodedObjectLookupIter(
    storage: ObjectGetter,
    t: ObjectType,
    series: []const Hash,
) EncodedObjectLookupIter {
    return EncodedObjectLookupIter.init(storage, t, series);
}

// ---------------------------------------------------------------------------
// EncodedObjectSliceIter
// ---------------------------------------------------------------------------

/// Iterator over a slice of `*MemoryObject` (go-git `EncodedObjectSliceIter`).
/// Series elements are borrowed; caller owns the objects.
pub const EncodedObjectSliceIter = struct {
    series: []*MemoryObject,

    /// go-git `NewEncodedObjectSliceIter` / inventory `EncodedObjectSliceIter.init`.
    pub fn init(series: []*MemoryObject) EncodedObjectSliceIter {
        return .{ .series = series };
    }

    /// go-git `EncodedObjectSliceIter.Next`.
    pub fn next(self: *EncodedObjectSliceIter) anyerror!*MemoryObject {
        if (self.series.len == 0) return error.EndOfStream;

        const obj = self.series[0];
        self.series = self.series[1..];
        return obj;
    }

    /// go-git `EncodedObjectSliceIter.ForEach`.
    pub fn forEach(self: *EncodedObjectSliceIter, cb: anytype) !void {
        return forEachIterator(self, cb);
    }

    /// go-git `EncodedObjectSliceIter.Close`.
    pub fn close(self: *EncodedObjectSliceIter) void {
        self.series = self.series[0..0];
    }

    /// Erase to `EncodedObjectIter` for composition.
    pub fn asIter(self: *EncodedObjectSliceIter) EncodedObjectIter {
        return .{
            .ptr = self,
            .next_fn = nextThunk,
            .close_fn = closeThunk,
        };
    }

    fn nextThunk(ptr: *anyopaque) anyerror!*MemoryObject {
        const self: *EncodedObjectSliceIter = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn closeThunk(ptr: *anyopaque) void {
        const self: *EncodedObjectSliceIter = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// go-git `NewEncodedObjectSliceIter` free-function alias.
pub fn newEncodedObjectSliceIter(series: []*MemoryObject) EncodedObjectSliceIter {
    return EncodedObjectSliceIter.init(series);
}

// ---------------------------------------------------------------------------
// MultiEncodedObjectIter
// ---------------------------------------------------------------------------

/// Chains several `EncodedObjectIter`s (go-git `MultiEncodedObjectIter`).
/// `iters` is borrowed and advanced by slicing off exhausted heads.
pub const MultiEncodedObjectIter = struct {
    iters: []EncodedObjectIter,

    /// go-git `NewMultiEncodedObjectIter` / inventory `MultiEncodedObjectIter.init`.
    pub fn init(iters: []EncodedObjectIter) MultiEncodedObjectIter {
        return .{ .iters = iters };
    }

    /// go-git `MultiEncodedObjectIter.Next`.
    /// On `EndOfStream`, closes the head iterator and continues with the rest.
    pub fn next(self: *MultiEncodedObjectIter) anyerror!*MemoryObject {
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

    /// go-git `MultiEncodedObjectIter.ForEach`.
    pub fn forEach(self: *MultiEncodedObjectIter, cb: anytype) !void {
        return forEachIterator(self, cb);
    }

    /// go-git `MultiEncodedObjectIter.Close`.
    pub fn close(self: *MultiEncodedObjectIter) void {
        for (self.iters) |it| it.close();
        self.iters = self.iters[0..0];
    }

    /// Erase to `EncodedObjectIter` for composition.
    pub fn asIter(self: *MultiEncodedObjectIter) EncodedObjectIter {
        return .{
            .ptr = self,
            .next_fn = nextThunk,
            .close_fn = closeThunk,
        };
    }

    fn nextThunk(ptr: *anyopaque) anyerror!*MemoryObject {
        const self: *MultiEncodedObjectIter = @ptrCast(@alignCast(ptr));
        return self.next();
    }

    fn closeThunk(ptr: *anyopaque) void {
        const self: *MultiEncodedObjectIter = @ptrCast(@alignCast(ptr));
        self.close();
    }
};

/// go-git `NewMultiEncodedObjectIter` free-function alias.
pub fn newMultiEncodedObjectIter(iters: []EncodedObjectIter) MultiEncodedObjectIter {
    return MultiEncodedObjectIter.init(iters);
}

// ---------------------------------------------------------------------------
// ForEachIterator
// ---------------------------------------------------------------------------

/// Shared ForEach for bare iterators with `next` + `close` (go-git `ForEachIterator`).
///
/// - `error.EndOfStream` from `next` ends iteration successfully.
/// - `error.Stop` from `cb` ends iteration successfully (go-git `ErrStop`).
/// - Other errors propagate. The iterator is always closed.
///
/// `cb` is `fn (*MemoryObject) !void` (any error set including `error.Stop`).
pub fn forEachIterator(iter: anytype, cb: anytype) !void {
    defer iter.close();
    while (true) {
        const obj = iter.next() catch |err| {
            // Coerce so callers with narrow error sets still compile.
            const e: anyerror = err;
            if (e == error.EndOfStream) return;
            return e;
        };

        cb(obj) catch |err| {
            // `error.Stop` (go-git ErrStop) ends successfully even when the
            // callback error set does not list Stop explicitly.
            const e: anyerror = err;
            if (e == error.Stop) return;
            return e;
        };
    }
}

/// Compatibility alias for `forEachEncodedObject`.
pub const forEachEncodedObject = forEachIterator;

// ---------------------------------------------------------------------------
// Tests (port of go-git object_test.go + composition completeness)
// ---------------------------------------------------------------------------

fn buildObject(allocator: std.mem.Allocator, content: []const u8) !MemoryObject {
    var o = MemoryObject.init(allocator);
    _ = try o.write(content);
    return o;
}

const MockObjectStorage = struct {
    db: []*MemoryObject,

    fn encodedObject(self: *MockObjectStorage, t: ObjectType, h: Hash) anyerror!*MemoryObject {
        _ = t;
        for (self.db) |o| {
            if (o.hash().eql(h)) return o;
        }
        return error.ObjectNotFound;
    }
};

// --- go-git TestMultiObjectIterNext ---

test "MultiEncodedObjectIter forEach (go-git TestMultiObjectIterNext)" {
    var o0: MemoryObject = .init(std.testing.allocator);
    defer o0.deinit();
    var o1: MemoryObject = .init(std.testing.allocator);
    defer o1.deinit();
    var o2: MemoryObject = .init(std.testing.allocator);
    defer o2.deinit();
    var o3: MemoryObject = .init(std.testing.allocator);
    defer o3.deinit();
    var o4: MemoryObject = .init(std.testing.allocator);
    defer o4.deinit();
    var o5: MemoryObject = .init(std.testing.allocator);
    defer o5.deinit();

    var expected = [_]*MemoryObject{ &o0, &o1, &o2, &o3, &o4, &o5 };

    var s0 = EncodedObjectSliceIter.init(expected[0..2]);
    var s1 = EncodedObjectSliceIter.init(expected[2..4]);
    var s2 = EncodedObjectSliceIter.init(expected[4..5]);

    var iters = [_]EncodedObjectIter{ s0.asIter(), s1.asIter(), s2.asIter() };
    var multi = MultiEncodedObjectIter.init(&iters);

    var i: usize = 0;
    const Gen = struct {
        var exp: []*MemoryObject = undefined;
        var idx: *usize = undefined;
        fn cb(o: *MemoryObject) !void {
            try std.testing.expect(o == exp[idx.*]);
            idx.* += 1;
        }
    };
    Gen.exp = &expected;
    Gen.idx = &i;
    try multi.forEach(Gen.cb);

    // go-git slices cover indices 0..4 only (5 objects); sixth is unused.
    try std.testing.expectEqual(@as(usize, 5), i);
    multi.close();
}

// --- go-git TestObjectLookupIter ---

test "EncodedObjectLookupIter forEach (go-git TestObjectLookupIter)" {
    var foo = try buildObject(std.testing.allocator, "foo");
    defer foo.deinit();
    var bar = try buildObject(std.testing.allocator, "bar");
    defer bar.deinit();

    var objects = [_]*MemoryObject{ &foo, &bar };
    const hashes = [_]Hash{ foo.hash(), bar.hash() };

    var storage = MockObjectStorage{ .db = &objects };
    var iter = EncodedObjectLookupIter.init(
        ObjectGetter.from(MockObjectStorage, &storage),
        .commit,
        &hashes,
    );

    var count: usize = 0;
    const Gen = struct {
        var hs: []const Hash = undefined;
        var c: *usize = undefined;
        fn cb(o: *MemoryObject) !void {
            try std.testing.expect(o.hash().eql(hs[c.*]));
            c.* += 1;
        }
    };
    Gen.hs = &hashes;
    Gen.c = &count;
    try iter.forEach(Gen.cb);

    try std.testing.expectEqual(@as(usize, 2), count);
    iter.close();
}

// --- go-git TestObjectSliceIter ---

test "EncodedObjectSliceIter forEach (go-git TestObjectSliceIter)" {
    var foo = try buildObject(std.testing.allocator, "foo");
    defer foo.deinit();
    var bar = try buildObject(std.testing.allocator, "bar");
    defer bar.deinit();

    var objects = [_]*MemoryObject{ &foo, &bar };
    const hashes = [_]Hash{ foo.hash(), bar.hash() };

    var iter = EncodedObjectSliceIter.init(&objects);

    var count: usize = 0;
    const Gen = struct {
        var hs: []const Hash = undefined;
        var c: *usize = undefined;
        fn cb(o: *MemoryObject) !void {
            try std.testing.expect(o.hash().eql(hs[c.*]));
            c.* += 1;
        }
    };
    Gen.hs = &hashes;
    Gen.c = &count;
    try iter.forEach(Gen.cb);

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(usize, 0), iter.series.len);
}

// --- go-git TestObjectSliceIterStop ---

test "EncodedObjectSliceIter forEach stop (go-git TestObjectSliceIterStop)" {
    var foo = try buildObject(std.testing.allocator, "foo");
    defer foo.deinit();
    var bar = try buildObject(std.testing.allocator, "bar");
    defer bar.deinit();

    var objects = [_]*MemoryObject{ &foo, &bar };
    const hashes = [_]Hash{ foo.hash(), bar.hash() };

    var iter = EncodedObjectSliceIter.init(&objects);

    var count: usize = 0;
    const Gen = struct {
        var hs: []const Hash = undefined;
        var c: *usize = undefined;
        fn cb(o: *MemoryObject) !void {
            try std.testing.expect(o.hash().eql(hs[c.*]));
            c.* += 1;
            return error.Stop;
        }
    };
    Gen.hs = &hashes;
    Gen.c = &count;
    try iter.forEach(Gen.cb);

    try std.testing.expectEqual(@as(usize, 1), count);
}

// --- go-git TestObjectSliceIterError ---

test "EncodedObjectSliceIter forEach error (go-git TestObjectSliceIterError)" {
    var foo = try buildObject(std.testing.allocator, "foo");
    defer foo.deinit();

    var objects = [_]*MemoryObject{&foo};
    var iter = EncodedObjectSliceIter.init(&objects);

    try std.testing.expectError(error.ARandomError, iter.forEach(struct {
        fn cb(_: *MemoryObject) error{ARandomError}!void {
            return error.ARandomError;
        }
    }.cb));
}

// --- Composition: Lookup Stop / Error / Next ---

test "EncodedObjectLookupIter forEach stop" {
    var foo = try buildObject(std.testing.allocator, "foo");
    defer foo.deinit();
    var bar = try buildObject(std.testing.allocator, "bar");
    defer bar.deinit();

    var objects = [_]*MemoryObject{ &foo, &bar };
    const hashes = [_]Hash{ foo.hash(), bar.hash() };
    var storage = MockObjectStorage{ .db = &objects };
    var iter = EncodedObjectLookupIter.init(
        ObjectGetter.from(MockObjectStorage, &storage),
        .any,
        &hashes,
    );

    var count: usize = 0;
    const Gen = struct {
        var c: *usize = undefined;
        fn cb(_: *MemoryObject) !void {
            c.* += 1;
            return error.Stop;
        }
    };
    Gen.c = &count;
    try iter.forEach(Gen.cb);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "EncodedObjectLookupIter forEach error" {
    var foo = try buildObject(std.testing.allocator, "foo");
    defer foo.deinit();
    var bar = try buildObject(std.testing.allocator, "bar");
    defer bar.deinit();

    var objects = [_]*MemoryObject{ &foo, &bar };
    const hashes = [_]Hash{ foo.hash(), bar.hash() };
    var storage = MockObjectStorage{ .db = &objects };
    var iter = EncodedObjectLookupIter.init(
        ObjectGetter.from(MockObjectStorage, &storage),
        .any,
        &hashes,
    );

    try std.testing.expectError(error.ARandomError, iter.forEach(struct {
        fn cb(_: *MemoryObject) error{ARandomError}!void {
            return error.ARandomError;
        }
    }.cb));
}

test "EncodedObjectLookupIter next" {
    var foo = try buildObject(std.testing.allocator, "foo");
    defer foo.deinit();
    var bar = try buildObject(std.testing.allocator, "bar");
    defer bar.deinit();

    var objects = [_]*MemoryObject{ &foo, &bar };
    const hashes = [_]Hash{ foo.hash(), bar.hash() };
    var storage = MockObjectStorage{ .db = &objects };
    var iter = EncodedObjectLookupIter.init(
        ObjectGetter.from(MockObjectStorage, &storage),
        .blob,
        &hashes,
    );

    const a = try iter.next();
    try std.testing.expect(a.hash().eql(foo.hash()));
    const b = try iter.next();
    try std.testing.expect(b.hash().eql(bar.hash()));
    try std.testing.expectError(error.EndOfStream, iter.next());

    // Close forces subsequent next to EOF.
    iter.pos = 0;
    iter.close();
    try std.testing.expectError(error.EndOfStream, iter.next());
}

test "EncodedObjectLookupIter next missing object does not advance" {
    var foo = try buildObject(std.testing.allocator, "foo");
    defer foo.deinit();

    var objects = [_]*MemoryObject{&foo};
    const missing = plumbing.newHash("deadbeefdeadbeefdeadbeefdeadbeefdeadbeef");
    const hashes = [_]Hash{ missing, foo.hash() };
    var storage = MockObjectStorage{ .db = &objects };
    var iter = EncodedObjectLookupIter.init(
        ObjectGetter.from(MockObjectStorage, &storage),
        .any,
        &hashes,
    );

    try std.testing.expectError(error.ObjectNotFound, iter.next());
    try std.testing.expectEqual(@as(usize, 0), iter.pos);

    // Still stuck on missing hash (go-git does not advance on error).
    try std.testing.expectError(error.ObjectNotFound, iter.next());
    try std.testing.expectEqual(@as(usize, 0), iter.pos);
}

// --- Composition: Multi Stop / Error / Next ---

test "MultiEncodedObjectIter forEach stop" {
    var o0: MemoryObject = .init(std.testing.allocator);
    defer o0.deinit();
    var o1: MemoryObject = .init(std.testing.allocator);
    defer o1.deinit();
    var o2: MemoryObject = .init(std.testing.allocator);
    defer o2.deinit();

    var a = [_]*MemoryObject{ &o0, &o1 };
    var b = [_]*MemoryObject{&o2};
    var s0 = EncodedObjectSliceIter.init(&a);
    var s1 = EncodedObjectSliceIter.init(&b);
    var iters = [_]EncodedObjectIter{ s0.asIter(), s1.asIter() };
    var multi = MultiEncodedObjectIter.init(&iters);

    var count: usize = 0;
    const Gen = struct {
        var c: *usize = undefined;
        fn cb(_: *MemoryObject) !void {
            c.* += 1;
            return error.Stop;
        }
    };
    Gen.c = &count;
    try multi.forEach(Gen.cb);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "MultiEncodedObjectIter forEach error" {
    var o0: MemoryObject = .init(std.testing.allocator);
    defer o0.deinit();
    var o1: MemoryObject = .init(std.testing.allocator);
    defer o1.deinit();

    var a = [_]*MemoryObject{ &o0, &o1 };
    var s0 = EncodedObjectSliceIter.init(&a);
    var iters = [_]EncodedObjectIter{s0.asIter()};
    var multi = MultiEncodedObjectIter.init(&iters);

    try std.testing.expectError(error.ARandomError, multi.forEach(struct {
        fn cb(_: *MemoryObject) error{ARandomError}!void {
            return error.ARandomError;
        }
    }.cb));
}

test "MultiEncodedObjectIter next" {
    var o0: MemoryObject = .init(std.testing.allocator);
    defer o0.deinit();
    var o1: MemoryObject = .init(std.testing.allocator);
    defer o1.deinit();
    var o2: MemoryObject = .init(std.testing.allocator);
    defer o2.deinit();

    // Empty head slice is skipped after EOF + close.
    var empty = [_]*MemoryObject{};
    var mid = [_]*MemoryObject{ &o0, &o1 };
    var tail = [_]*MemoryObject{&o2};
    var s_empty = EncodedObjectSliceIter.init(&empty);
    var s_mid = EncodedObjectSliceIter.init(&mid);
    var s_tail = EncodedObjectSliceIter.init(&tail);
    var iters = [_]EncodedObjectIter{ s_empty.asIter(), s_mid.asIter(), s_tail.asIter() };
    var multi = MultiEncodedObjectIter.init(&iters);

    try std.testing.expect(try multi.next() == &o0);
    try std.testing.expect(try multi.next() == &o1);
    try std.testing.expect(try multi.next() == &o2);
    try std.testing.expectError(error.EndOfStream, multi.next());
    try std.testing.expectError(error.EndOfStream, multi.next());
}

test "MultiEncodedObjectIter close remaining" {
    var o0: MemoryObject = .init(std.testing.allocator);
    defer o0.deinit();
    var o1: MemoryObject = .init(std.testing.allocator);
    defer o1.deinit();

    var a = [_]*MemoryObject{&o0};
    var b = [_]*MemoryObject{&o1};
    var s0 = EncodedObjectSliceIter.init(&a);
    var s1 = EncodedObjectSliceIter.init(&b);
    var iters = [_]EncodedObjectIter{ s0.asIter(), s1.asIter() };
    var multi = MultiEncodedObjectIter.init(&iters);

    _ = try multi.next();
    multi.close();
    try std.testing.expectEqual(@as(usize, 0), multi.iters.len);
    // Underlying slice iters closed (series emptied / pos at end).
    try std.testing.expectEqual(@as(usize, 0), s0.series.len);
    try std.testing.expectEqual(@as(usize, 0), s1.series.len);
}

// --- Slice next / free aliases ---

test "EncodedObjectSliceIter next" {
    var foo = try buildObject(std.testing.allocator, "foo");
    defer foo.deinit();
    var bar = try buildObject(std.testing.allocator, "bar");
    defer bar.deinit();

    var objects = [_]*MemoryObject{ &foo, &bar };
    var iter = newEncodedObjectSliceIter(&objects);

    try std.testing.expect(try iter.next() == &foo);
    try std.testing.expect(try iter.next() == &bar);
    try std.testing.expectError(error.EndOfStream, iter.next());
    iter.close();
    try std.testing.expectEqual(@as(usize, 0), iter.series.len);
}

// --- forEachIterator helper paths ---

test "forEachIterator EndOfStream Stop Error" {
    var o0: MemoryObject = .init(std.testing.allocator);
    defer o0.deinit();
    var o1: MemoryObject = .init(std.testing.allocator);
    defer o1.deinit();

    // Empty → success (EndOfStream).
    var empty_objs = [_]*MemoryObject{};
    var empty = EncodedObjectSliceIter.init(&empty_objs);
    try forEachIterator(&empty, struct {
        fn cb(_: *MemoryObject) !void {
            return error.ARandomError;
        }
    }.cb);

    // Stop → success, closed.
    var objs = [_]*MemoryObject{ &o0, &o1 };
    var iter = EncodedObjectSliceIter.init(&objs);
    var count: usize = 0;
    const Gen = struct {
        var c: *usize = undefined;
        fn cb(_: *MemoryObject) !void {
            c.* += 1;
            return error.Stop;
        }
    };
    Gen.c = &count;
    try forEachIterator(&iter, Gen.cb);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 0), iter.series.len);

    // Error propagates.
    var objs2 = [_]*MemoryObject{&o0};
    var iter2 = EncodedObjectSliceIter.init(&objs2);
    try std.testing.expectError(error.ARandomError, forEachIterator(&iter2, struct {
        fn cb(_: *MemoryObject) error{ARandomError}!void {
            return error.ARandomError;
        }
    }.cb));
}

test "newEncodedObject* free aliases match init" {
    var o: MemoryObject = .init(std.testing.allocator);
    defer o.deinit();
    var series = [_]*MemoryObject{&o};
    const a = EncodedObjectSliceIter.init(&series);
    const b = newEncodedObjectSliceIter(&series);
    try std.testing.expectEqual(a.series.len, b.series.len);

    var storage = MockObjectStorage{ .db = &series };
    const hashes = [_]Hash{o.hash()};
    const l0 = EncodedObjectLookupIter.init(
        ObjectGetter.from(MockObjectStorage, &storage),
        .any,
        &hashes,
    );
    const l1 = newEncodedObjectLookupIter(
        ObjectGetter.from(MockObjectStorage, &storage),
        .any,
        &hashes,
    );
    try std.testing.expectEqual(l0.series.len, l1.series.len);

    var s = EncodedObjectSliceIter.init(&series);
    var iters = [_]EncodedObjectIter{s.asIter()};
    const m0 = MultiEncodedObjectIter.init(&iters);
    const m1 = newMultiEncodedObjectIter(&iters);
    try std.testing.expectEqual(m0.iters.len, m1.iters.len);
}

test "EncodedObjectIter type erase forEach" {
    var o0: MemoryObject = .init(std.testing.allocator);
    defer o0.deinit();
    var o1: MemoryObject = .init(std.testing.allocator);
    defer o1.deinit();
    var series = [_]*MemoryObject{ &o0, &o1 };
    var slice = EncodedObjectSliceIter.init(&series);
    const erased = slice.asIter();

    var count: usize = 0;
    const Gen = struct {
        var c: *usize = undefined;
        fn cb(_: *MemoryObject) !void {
            c.* += 1;
        }
    };
    Gen.c = &count;
    try erased.forEach(Gen.cb);
    try std.testing.expectEqual(@as(usize, 2), count);
}
