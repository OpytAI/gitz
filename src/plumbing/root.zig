//! plumbing — core types for gitz (port of go-git `plumbing` package).
//!
//! Hash, ObjectType, MemoryObject, Reference, and related helpers.
//! Subpackages (`hash`, `filemode`, `color`, …) are separate modules.

const std = @import("std");

const error_mod = @import("error.zig");
const hash_mod = @import("hash.zig");
const object_mod = @import("object.zig");
const memory_mod = @import("memory.zig");
const reference_mod = @import("reference.zig");

// --- Errors ---
pub const Error = error_mod.Error;

// --- Hash ---
pub const Hash = hash_mod.Hash;
pub const Size = hash_mod.Size;
pub const HexSize = hash_mod.HexSize;
pub const ZeroHash = hash_mod.ZeroHash;
pub const Hasher = hash_mod.Hasher;
pub const parseHash = hash_mod.parseHash;
pub const newHash = hash_mod.newHash;
pub const isHash = hash_mod.isHash;
pub const computeHash = hash_mod.computeHash;

// --- ObjectType ---
pub const ObjectType = object_mod.ObjectType;

// --- MemoryObject ---
pub const MemoryObject = memory_mod.MemoryObject;

// --- Reference ---
pub const Reference = reference_mod.Reference;
pub const ReferenceName = reference_mod.ReferenceName;
pub const ReferenceType = reference_mod.ReferenceType;
pub const HEAD = reference_mod.HEAD;
pub const master = reference_mod.master;
pub const main = reference_mod.main;
pub const ref_rev_parse_rules = reference_mod.ref_rev_parse_rules;
pub const newBranchReferenceName = reference_mod.newBranchReferenceName;
pub const newTagReferenceName = reference_mod.newTagReferenceName;
pub const newNoteReferenceName = reference_mod.newNoteReferenceName;
pub const newRemoteReferenceName = reference_mod.newRemoteReferenceName;
pub const newRemoteHEADReferenceName = reference_mod.newRemoteHEADReferenceName;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Hash zero and parse/string" {
    try std.testing.expect(ZeroHash.isZero());
    try std.testing.expect(ZeroHash.eql(ZeroHash));

    const hex = "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391";
    try std.testing.expect(isHash(hex));
    try std.testing.expect(!isHash("too-short"));
    try std.testing.expect(!isHash("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));

    const h = try parseHash(hex);
    try std.testing.expect(!h.isZero());
    var buf: [HexSize]u8 = undefined;
    try std.testing.expectEqualStrings(hex, h.string(&buf));

    const h2 = newHash(hex);
    try std.testing.expect(h.eql(h2));

    // Invalid hex → zero (go-git NewHash ignores decode error).
    try std.testing.expect(newHash("not-hex").isZero());
}

test "ObjectType string parse valid delta" {
    try std.testing.expectEqualStrings("commit", ObjectType.commit.string());
    try std.testing.expectEqualStrings("tree", ObjectType.tree.string());
    try std.testing.expectEqualStrings("blob", ObjectType.blob.string());
    try std.testing.expectEqualStrings("tag", ObjectType.tag.string());
    try std.testing.expectEqualStrings("ofs-delta", ObjectType.ofs_delta.string());
    try std.testing.expectEqualStrings("ref-delta", ObjectType.ref_delta.string());
    try std.testing.expectEqualStrings("any", ObjectType.any.string());
    try std.testing.expectEqualStrings("unknown", ObjectType.invalid.string());

    try std.testing.expectEqualStrings("blob", ObjectType.blob.bytes());

    try std.testing.expect(ObjectType.commit.valid());
    try std.testing.expect(ObjectType.ref_delta.valid());
    try std.testing.expect(!ObjectType.invalid.valid());
    try std.testing.expect(!ObjectType.any.valid());

    try std.testing.expect(ObjectType.ofs_delta.isDelta());
    try std.testing.expect(ObjectType.ref_delta.isDelta());
    try std.testing.expect(!ObjectType.blob.isDelta());

    try std.testing.expect((try ObjectType.parse("blob")) == .blob);
    try std.testing.expect((try ObjectType.parse("commit")) == .commit);
    try std.testing.expectError(error.InvalidType, ObjectType.parse("any"));
    try std.testing.expectError(error.InvalidType, ObjectType.parse("nope"));

    // Git pack type integers.
    try std.testing.expectEqual(@as(i8, 1), @intFromEnum(ObjectType.commit));
    try std.testing.expectEqual(@as(i8, 3), @intFromEnum(ObjectType.blob));
    try std.testing.expectEqual(@as(i8, -127), @intFromEnum(ObjectType.any));
}

test "computeHash empty blob" {
    // echo -n 'blob 0\0' | sha1sum → e69de29bb2d1d6434b8b29ae775ad8c2e48c5391
    const h = computeHash(.blob, &[_]u8{});
    var buf: [HexSize]u8 = undefined;
    try std.testing.expectEqualStrings(
        "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
        h.string(&buf),
    );
}

test "MemoryObject write and hash" {
    var obj = MemoryObject.init(std.testing.allocator);
    defer obj.deinit();

    obj.object_type = .blob;
    _ = try obj.write("hello");
    try std.testing.expectEqual(@as(i64, 5), obj.size);
    try std.testing.expectEqualStrings("hello", obj.readerBytes());

    const h = obj.hash();
    try std.testing.expect(!h.isZero());
    // Second call returns cached value.
    try std.testing.expect(h.eql(obj.hash()));
}

test "Reference hash and symbolic" {
    const name = ReferenceName.init("refs/heads/main");
    try std.testing.expect(name.isBranch());
    try std.testing.expect(!name.isTag());
    try name.validate();

    const h = newHash("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    const href = Reference.newHashReference(name, h);
    try std.testing.expect(href.type == .hash);
    try std.testing.expect(href.hash.eql(h));
    try std.testing.expectEqualStrings("refs/heads/main", href.name.string());

    const head = Reference.newSymbolicReference(HEAD, master);
    try std.testing.expect(head.type == .symbolic);
    try std.testing.expectEqualStrings("refs/heads/master", head.target.string());

    const from = Reference.fromStrings("HEAD", "ref: refs/heads/main");
    try std.testing.expect(from.type == .symbolic);
    try std.testing.expectEqualStrings("refs/heads/main", from.target.string());

    const from_hash = Reference.fromStrings("refs/tags/v1", "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391");
    try std.testing.expect(from_hash.type == .hash);
    try std.testing.expect(from_hash.hash.eql(h));
}
