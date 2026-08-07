//! GetObject / DecodeObject / ObjectIter (go-git `plumbing/object/object.go`).
//!
//! Dispatches encoded objects to typed decode helpers (commit/tree/blob/tag).
//!
//! # Sibling decode signatures (this worktree)
//!
//! | Helper | Signature |
//! |--------|-----------|
//! | `decodeCommit` | `(allocator, s: anytype, o) !*Commit` |
//! | `decodeTree` | `(allocator, s: ?*memory.Storage, o) !Tree` |
//! | `decodeBlob` | `(o) !Blob` |
//! | `decodeTag` | `(allocator, s: anytype, o) !Tag` |
//!
//! `s` for commit/tag must be a pointer to a type with `encodedObject`
//! (see `ObjectGetter.from(@TypeOf(s.*), s)` in those modules).
//!
//! # Errors
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `ErrUnsupportedObject` | `error.UnsupportedObject` (`error.zig`) |
//! | `plumbing.ErrInvalidType` | `error.InvalidType` |
//!
//! # go-git test map
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `DateFormat` constant | `DateFormat` |
//! | `GetObject` / `DecodeObject` | `getObject` / `decodeObject` |
//! | `NewObjectIter` / `ObjectIter.Next` | `newObjectIter` / `ObjectIter.next` |

const std = @import("std");
const plumbing = @import("plumbing");
const storer_mod = @import("storer");
const memory = @import("memory");

const error_mod = @import("error.zig");
const blob_mod = @import("blob.zig");
const tree_mod = @import("tree.zig");
const commit_mod = @import("commit.zig");
const tag_mod = @import("tag.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ObjectType = plumbing.ObjectType;
const MemoryObject = plumbing.MemoryObject;
const Storage = memory.Storage;

// ---------------------------------------------------------------------------
// Errors / constants (go-git object.go)
// ---------------------------------------------------------------------------

/// Package error set (includes go-git `ErrUnsupportedObject`).
pub const Error = error_mod.Error;

/// go-git `ErrUnsupportedObject` — prefer `error.UnsupportedObject` in unions.
pub const ErrUnsupportedObject = error.UnsupportedObject;

/// go-git `DateFormat` — original git author-date layout (Go reference time).
/// Also re-exported from `signature.zig` as `DateFormat`.
pub const DateFormat = "Mon Jan 02 15:04:05 2006 -0700";

// ---------------------------------------------------------------------------
// Object (go-git `Object` interface → tagged union)
// ---------------------------------------------------------------------------

/// Generic decoded Git object (go-git `Object`).
///
/// Ownership:
/// - `.commit` — heap `*Commit`; free with `deinit(allocator)`
/// - `.tree` / `.tag` — by-value; `deinit` frees owned strings/entries
/// - `.blob` — borrowed `obj` pointer only; no heap free
pub const Object = union(enum) {
    commit: *commit_mod.Commit,
    tree: *tree_mod.Tree,
    blob: blob_mod.Blob,
    tag: tag_mod.Tag,

    /// go-git `Object.ID`.
    pub fn id(self: *const Object) Hash {
        return switch (self.*) {
            .commit => |c| c.hash,
            .tree => |t| t.hash,
            .blob => |b| b.hash,
            .tag => |t| t.hash,
        };
    }

    /// go-git `Object.Type`.
    pub fn objectType(self: *const Object) ObjectType {
        return switch (self.*) {
            .commit => .commit,
            .tree => .tree,
            .blob => .blob,
            .tag => .tag,
        };
    }

    /// Free owned resources. Safe to call once.
    pub fn deinit(self: *Object, allocator: Allocator) void {
        switch (self.*) {
            .commit => |c| {
                c.deinit();
                allocator.destroy(c);
            },
            .tree => |t| tree_mod.freeTree(allocator, t),
            .blob => {},
            .tag => |*t| t.deinit(),
        }
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// GetObject / DecodeObject
// ---------------------------------------------------------------------------

/// go-git `GetObject` — load by hash (`AnyObject`) and decode.
///
/// `s` must be a pointer to a storer with `encodedObject(ObjectType, Hash)`.
pub fn getObject(allocator: Allocator, s: anytype, h: Hash) !Object {
    const o = try s.encodedObject(.any, h);
    return decodeObject(allocator, s, o);
}

/// go-git `DecodeObject` — dispatch on encoded type to typed decode helpers.
///
/// Unknown / non-standard types yield `error.InvalidType` (go-git
/// `plumbing.ErrInvalidType`), not `UnsupportedObject`.
pub fn decodeObject(allocator: Allocator, s: anytype, o: *MemoryObject) !Object {
    return switch (o.object_type) {
        .commit => .{ .commit = try commit_mod.decodeCommit(allocator, s, o) },
        .tree => .{ .tree = try decodeTreeFor(allocator, s, o) },
        .blob => .{ .blob = try blob_mod.decodeBlob(o) },
        .tag => .{ .tag = try tag_mod.decodeTag(allocator, s, o) },
        else => error.InvalidType,
    };
}

/// `decodeTree` wants `?*memory.Storage`. Pass through when `s` is that type;
/// otherwise decode with a null storer (tree body only).
fn decodeTreeFor(allocator: Allocator, s: anytype, o: *MemoryObject) !*tree_mod.Tree {
    const T = @TypeOf(s);
    if (T == *Storage) {
        return tree_mod.decodeTree(allocator, s, o);
    }
    if (comptime @typeInfo(T) == .pointer) {
        const Child = @typeInfo(T).pointer.child;
        if (Child == Storage) {
            return tree_mod.decodeTree(allocator, @constCast(s), o);
        }
    }
    return tree_mod.decodeTreeNoStore(allocator, o);
}


// ---------------------------------------------------------------------------
// ObjectIter (go-git `ObjectIter`)
// ---------------------------------------------------------------------------

/// Iterator that decodes each encoded object from an `EncodedObjectIter`
/// (go-git `ObjectIter`). Skips entries that decode as `error.InvalidType`.
///
/// Holds an `ObjectGetter` (type-erased storer) plus allocator for decode.
pub const ObjectIter = struct {
    allocator: Allocator,
    inner: storer_mod.EncodedObjectIter,
    storage: storer_mod.ObjectGetter,

    /// go-git `NewObjectIter`.
    pub fn init(
        allocator: Allocator,
        storage: storer_mod.ObjectGetter,
        iter: storer_mod.EncodedObjectIter,
    ) ObjectIter {
        return .{
            .allocator = allocator,
            .inner = iter,
            .storage = storage,
        };
    }

    /// go-git `ObjectIter.Next` — `error.EndOfStream` at end (go-git `io.EOF`).
    pub fn next(self: *ObjectIter) !Object {
        while (true) {
            const enc = self.inner.next() catch |err| {
                const e: anyerror = err;
                if (e == error.EndOfStream) return error.EndOfStream;
                return e;
            };

            const obj = self.toObject(enc) catch |err| {
                const e: anyerror = err;
                // go-git continues on ErrInvalidType only.
                if (e == error.InvalidType) continue;
                return e;
            };
            return obj;
        }
    }

    /// go-git `ObjectIter.ForEach`. `error.Stop` ends successfully; iter is closed.
    ///
    /// The callback receives `*Object` for the duration of the call. The iterator
    /// frees the object after each callback returns (including on `error.Stop`).
    pub fn forEach(self: *ObjectIter, cb: anytype) !void {
        defer self.close();
        while (true) {
            var obj = self.next() catch |err| {
                const e: anyerror = err;
                if (e == error.EndOfStream) return;
                return e;
            };
            const cb_result = cb(&obj);
            obj.deinit(self.allocator);
            cb_result catch |err| {
                const e: anyerror = err;
                if (e == error.Stop) return;
                return e;
            };
        }
    }

    /// go-git `ObjectIter.Close`.
    pub fn close(self: *ObjectIter) void {
        self.inner.close();
    }

    /// go-git `ObjectIter.toObject`.
    fn toObject(self: *ObjectIter, enc: *MemoryObject) !Object {
        // decodeCommit/decodeTag need a pointer with encodedObject.
        return switch (enc.object_type) {
            .blob => .{ .blob = try blob_mod.decodeBlob(enc) },
            .tree => .{ .tree = try tree_mod.decodeTreeNoStore(self.allocator, enc) },
            .commit => .{ .commit = try commit_mod.decodeCommit(self.allocator, &self.storage, enc) },
            .tag => .{ .tag = try tag_mod.decodeTag(self.allocator, &self.storage, enc) },
            else => error.InvalidType,
        };
    }
};

/// go-git `NewObjectIter` free-function alias.
pub fn newObjectIter(
    allocator: Allocator,
    storage: storer_mod.ObjectGetter,
    iter: storer_mod.EncodedObjectIter,
) ObjectIter {
    return ObjectIter.init(allocator, storage, iter);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "DateFormat matches go-git object.go" {
    try std.testing.expectEqualStrings("Mon Jan 02 15:04:05 2006 -0700", DateFormat);
}

test "ErrUnsupportedObject is UnsupportedObject" {
    try std.testing.expect(ErrUnsupportedObject == error.UnsupportedObject);
    const sample: Error = error.UnsupportedObject;
    try std.testing.expect(sample == error.UnsupportedObject);
}

test "decodeObject InvalidType for delta and invalid" {
    var o = MemoryObject.init(std.testing.allocator);
    defer o.deinit();

    const Stub = struct {
        pub fn encodedObject(_: *@This(), _: ObjectType, _: Hash) anyerror!*MemoryObject {
            return error.ObjectNotFound;
        }
    };
    var stub: Stub = .{};

    o.setType(.ofs_delta);
    try std.testing.expectError(error.InvalidType, decodeObject(std.testing.allocator, &stub, &o));

    o.setType(.ref_delta);
    try std.testing.expectError(error.InvalidType, decodeObject(std.testing.allocator, &stub, &o));

    o.setType(.invalid);
    try std.testing.expectError(error.InvalidType, decodeObject(std.testing.allocator, &stub, &o));

    o.setType(.any);
    try std.testing.expectError(error.InvalidType, decodeObject(std.testing.allocator, &stub, &o));
}

test "decodeObject blob via getObject path" {
    const gpa = std.testing.allocator;

    var store = memory.ObjectStorage.init(gpa);
    defer store.deinit();

    const obj = try store.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write("FOO");
    const h = try store.setEncodedObject(obj);

    var decoded = try getObject(gpa, &store, h);
    defer decoded.deinit(gpa);

    try std.testing.expect(decoded.objectType() == .blob);
    try std.testing.expect(decoded.id().eql(h));
    try std.testing.expectEqual(@as(i64, 3), decoded.blob.size);
}

test "ObjectIter skips invalid types and yields blob" {
    const gpa = std.testing.allocator;

    var store = memory.ObjectStorage.init(gpa);
    defer store.deinit();

    const obj = try store.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write("x");
    const h = try store.setEncodedObject(obj);

    const series = [_]Hash{h};
    var lookup = storer_mod.EncodedObjectLookupIter.init(
        storer_mod.ObjectGetter.from(memory.ObjectStorage, &store),
        .any,
        &series,
    );

    var iter = newObjectIter(
        gpa,
        storer_mod.ObjectGetter.from(memory.ObjectStorage, &store),
        lookup.asIter(),
    );

    var o = try iter.next();
    defer o.deinit(gpa);
    try std.testing.expect(o.objectType() == .blob);
    try std.testing.expectError(error.EndOfStream, iter.next());
    iter.close();
}
