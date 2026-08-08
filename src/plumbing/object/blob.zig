//! Blob object (go-git `plumbing/object/blob.go`).
//!
//! Pin: go-git v5.19.2.

const std = @import("std");
const plumbing = @import("plumbing");
const storer = @import("storer");

const Error = @import("error.zig").Error;

const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const ObjectType = plumbing.ObjectType;
const MemoryObject = plumbing.MemoryObject;

/// Arbitrary file content object (go-git `Blob`).
///
/// `obj` is a borrowed pointer to the source encoded object (not owned).
pub const Blob = struct {
    /// Object id (go-git `Hash`).
    hash: Hash = ZeroHash,
    /// Uncompressed content size (go-git `Size`).
    size: i64 = 0,
    /// Backing encoded object (go-git unexported `obj`).
    obj: ?*MemoryObject = null,

    /// go-git `(*Blob).ID`.
    pub fn id(self: *const Blob) Hash {
        return self.hash;
    }

    /// Always `.blob` (go-git `(*Blob).Type`).
    pub fn objectType(self: *const Blob) ObjectType {
        _ = self;
        return .blob;
    }

    /// Decode from an encoded object (go-git `(*Blob).Decode`).
    pub fn decode(self: *Blob, o: *MemoryObject) Error!void {
        if (o.object_type != .blob) return error.UnsupportedObject;
        self.hash = o.hash();
        self.size = o.size;
        self.obj = o;
    }

    /// Copy content into `o` as a blob (go-git `(*Blob).Encode`).
    pub fn encode(self: *const Blob, o: *MemoryObject) std.mem.Allocator.Error!void {
        o.setType(.blob);
        const data = self.readerBytes();
        try o.setContent(data);
    }

    /// Content bytes from the backing object (empty if none).
    pub fn readerBytes(self: *const Blob) []const u8 {
        if (self.obj) |o| return o.readerBytes();
        return &.{};
    }
};

/// Decode `o` into a `Blob` (go-git `DecodeBlob`).
pub fn decodeBlob(o: *MemoryObject) Error!Blob {
    var b: Blob = .{};
    try b.decode(o);
    return b;
}

/// Load and decode a blob from a storer with `encodedObject(type, hash)`.
/// go-git `GetBlob`.
pub fn getBlob(s: anytype, h: Hash) !Blob {
    const o = try s.encodedObject(ObjectType.blob, h);
    return try decodeBlob(o);
}

/// Iterator that yields only blob objects (go-git `BlobIter`).
pub const BlobIter = struct {
    encoded_iter: storer.EncodedObjectIter,

    /// go-git `NewBlobIter` — `s` is kept for API parity and unused.
    pub fn init(s: anytype, iter: storer.EncodedObjectIter) BlobIter {
        _ = s;
        return .{ .encoded_iter = iter };
    }

    /// Next blob or `error.EndOfStream` (go-git `io.EOF`).
    pub fn next(self: *BlobIter) !Blob {
        while (true) {
            const obj = try self.encoded_iter.next();
            if (obj.object_type != .blob) continue;
            return try decodeBlob(obj);
        }
    }

    /// Call `cb(*const Blob)` for each blob; `error.Stop` ends successfully.
    /// Closes the underlying iterator (go-git `ForEach`).
    pub fn forEach(self: *BlobIter, cb: anytype) !void {
        defer self.close();
        while (true) {
            const b = self.next() catch |err| {
                if (err == error.EndOfStream) return;
                return err;
            };
            @call(.auto, cb, .{&b}) catch |err| {
                const e: anyerror = err;
                if (e == error.Stop) return;
                return e;
            };
        }
    }

    /// go-git `Close` via the encoded-object iterator.
    pub fn close(self: *BlobIter) void {
        self.encoded_iter.close();
    }
};

/// Free-function alias for `BlobIter.init` (go-git `NewBlobIter`).
pub fn newBlobIter(s: anytype, iter: storer.EncodedObjectIter) BlobIter {
    return BlobIter.init(s, iter);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Blob decode FOO hash and size" {
    const gpa = std.testing.allocator;
    var o = MemoryObject.init(gpa);
    defer o.deinit();
    o.setType(.blob);
    _ = try o.write("FOO");

    var blob: Blob = .{};
    try blob.decode(&o);

    try std.testing.expectEqual(@as(i64, 3), blob.size);
    var hex: [plumbing.MaxHexSize]u8 = undefined;
    try std.testing.expectEqualStrings(
        "d96c7efbfec2814ae0301ad054dc8d9fc416c9b5",
        blob.hash.string(&hex),
    );
    try std.testing.expectEqualStrings("FOO", blob.readerBytes());
    try std.testing.expect(blob.id().eql(blob.hash));
    try std.testing.expect(blob.objectType() == .blob);
}

test "Blob decode encode idempotent" {
    const gpa = std.testing.allocator;
    const samples = [_][]const u8{ "foo", "foo\n" };
    for (samples) |str| {
        var object = MemoryObject.init(gpa);
        defer object.deinit();
        _ = try object.write(str);
        object.setType(.blob);
        _ = object.hash();

        var blob: Blob = .{};
        try blob.decode(&object);

        var new_object = MemoryObject.init(gpa);
        defer new_object.deinit();
        try blob.encode(&new_object);
        _ = new_object.hash();

        try std.testing.expect(object.object_type == new_object.object_type);
        try std.testing.expectEqual(object.size, new_object.size);
        try std.testing.expectEqualStrings(object.readerBytes(), new_object.readerBytes());
        try std.testing.expect(object.hash().eql(new_object.hash()));
    }
}

test "Blob decode wrong type" {
    const gpa = std.testing.allocator;
    var o = MemoryObject.init(gpa);
    defer o.deinit();
    o.setType(.commit);
    _ = try o.write("not a blob");

    var blob: Blob = .{};
    try std.testing.expectError(error.UnsupportedObject, blob.decode(&o));
}

test "getBlob from memory storage" {
    const memory = @import("memory");
    const gpa = std.testing.allocator;

    var store = memory.ObjectStorage.init(gpa);
    defer store.deinit();

    const obj = try store.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write("hello");
    const h = try store.setEncodedObject(obj);

    const blob = try getBlob(&store, h);
    try std.testing.expectEqual(@as(i64, 5), blob.size);
    try std.testing.expectEqualStrings("hello", blob.readerBytes());
    try std.testing.expect(blob.hash.eql(h));
}

test "BlobIter skips non-blobs" {
    const gpa = std.testing.allocator;

    var blob_obj = MemoryObject.init(gpa);
    defer blob_obj.deinit();
    blob_obj.setType(.blob);
    _ = try blob_obj.write("b");

    var tree_obj = MemoryObject.init(gpa);
    defer tree_obj.deinit();
    tree_obj.setType(.tree);
    _ = try tree_obj.write("t");

    var series = [_]*MemoryObject{ &tree_obj, &blob_obj };
    var slice_iter = storer.EncodedObjectSliceIter.init(&series);
    var iter = BlobIter.init({}, slice_iter.asIter());

    const b = try iter.next();
    try std.testing.expectEqualStrings("b", b.readerBytes());
    try std.testing.expectError(error.EndOfStream, iter.next());
}
