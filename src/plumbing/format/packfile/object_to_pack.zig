//! ObjectToPack — object scheduled for pack encoding
//! (go-git `plumbing/format/packfile/object_pack.go`).
//!
//! Encoded objects are always `*plumbing.MemoryObject` (no Go interface).

const std = @import("std");
const plumbing = @import("plumbing");

const MemoryObject = plumbing.MemoryObject;
const ObjectType = plumbing.ObjectType;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;

/// Representation of an object that is going into a pack file
/// (go-git `ObjectToPack`).
pub const ObjectToPack = struct {
    /// The main object to pack; may be a full object or a delta.
    object: ?*MemoryObject = null,
    /// Base object when `object` is a delta; null for non-delta.
    base: ?*ObjectToPack = null,
    /// Full object: same as `object` when non-delta, or the resolved target
    /// when `object` is a delta. May be cleaned to free memory after metadata
    /// is saved.
    original: ?*MemoryObject = null,
    /// Number of deltas needed to resolve to `original` (chain depth).
    depth: i32 = 0,
    /// Pack offset once written, or 0 if not written. Special value 1 means
    /// WantWrite (see `markWantWrite` / `wantWrite` / `isWritten`).
    offset: i64 = 0,

    // Metadata cached from `original` so Type/Hash/Size still work after
    // `cleanOriginal` (go-git unexported fields).
    resolved_original: bool = false,
    original_type: ObjectType = .invalid,
    original_size: i64 = 0,
    original_hash: Hash = ZeroHash,

    /// go-git `BackToOriginal` — undeltify if this was a delta and Original is set.
    pub fn backToOriginal(self: *ObjectToPack) void {
        if (self.isDelta() and self.original != null) {
            self.object = self.original;
            self.base = null;
            self.depth = 0;
        }
    }

    /// go-git `IsWritten` — true when a real pack offset was recorded (`offset > 1`).
    pub fn isWritten(self: *const ObjectToPack) bool {
        return self.offset > 1;
    }

    /// go-git `MarkWantWrite` — mark as WantWrite to avoid delta-chain loops.
    pub fn markWantWrite(self: *ObjectToPack) void {
        self.offset = 1;
    }

    /// go-git `WantWrite` — true if marked WantWrite (`offset == 1`).
    pub fn wantWrite(self: *const ObjectToPack) bool {
        return self.offset == 1;
    }

    /// go-git `SetOriginal` — set Original and save size/type/hash when non-null.
    /// If `obj` is null, Original is cleared but previously resolved metadata is kept.
    pub fn setOriginal(self: *ObjectToPack, obj: ?*MemoryObject) void {
        self.original = obj;
        self.saveOriginalMetadata();
    }

    /// go-git `SaveOriginalMetadata` — cache size, type, hash of Original.
    pub fn saveOriginalMetadata(self: *ObjectToPack) void {
        if (self.original) |orig| {
            self.original_size = orig.size;
            self.original_type = orig.object_type;
            self.original_hash = orig.hash();
            self.resolved_original = true;
        }
    }

    /// go-git `CleanOriginal` — drop the Original pointer (metadata may remain).
    pub fn cleanOriginal(self: *ObjectToPack) void {
        self.original = null;
    }

    /// go-git `Type`.
    pub fn objectType(self: *const ObjectToPack) ObjectType {
        if (self.original) |orig| {
            return orig.object_type;
        }
        if (self.resolved_original) {
            return self.original_type;
        }
        if (self.base) |b| {
            return b.objectType();
        }
        if (self.object) |obj| {
            return obj.object_type;
        }
        // go-git panics when type cannot be resolved; same contract here.
        unreachable;
    }

    /// go-git `Hash`.
    ///
    /// When Original is absent and metadata was not saved, go-git falls back to
    /// `plumbing.DeltaObject.ActualHash`. This port has no DeltaObject type, so
    /// that path is unreachable (same as an unresolved object in go-git).
    pub fn objectHash(self: *ObjectToPack) Hash {
        if (self.original) |orig| {
            return orig.hash();
        }
        if (self.resolved_original) {
            return self.original_hash;
        }
        unreachable;
    }

    /// go-git `Size`.
    ///
    /// Same notes as `objectHash` regarding the missing DeltaObject fallback.
    pub fn objectSize(self: *const ObjectToPack) i64 {
        if (self.original) |orig| {
            return orig.size;
        }
        if (self.resolved_original) {
            return self.original_size;
        }
        unreachable;
    }

    /// go-git `IsDelta` — true when a base is set.
    pub fn isDelta(self: *const ObjectToPack) bool {
        return self.base != null;
    }

    /// go-git `SetDelta` — attach a delta object based on `base`.
    pub fn setDelta(self: *ObjectToPack, base: *ObjectToPack, delta: *MemoryObject) void {
        self.object = delta;
        self.base = base;
        self.depth = base.depth + 1;
    }
};

/// go-git `newObjectToPack` — non-delta object (Object and Original both `o`).
pub fn newObjectToPack(o: *MemoryObject) ObjectToPack {
    return .{
        .object = o,
        .original = o,
    };
}

/// go-git `newDeltaObjectToPack` — delta against `base`, target `original`,
/// delta body `delta`. Depth is `base.depth + 1`.
pub fn newDeltaObjectToPack(
    base: *ObjectToPack,
    original: *MemoryObject,
    delta: *MemoryObject,
) ObjectToPack {
    return .{
        .object = delta,
        .base = base,
        .original = original,
        .depth = base.depth + 1,
    };
}

// ---------------------------------------------------------------------------
// Tests (go-git object_pack_test.go + write-state machine)
// ---------------------------------------------------------------------------

fn makeBlob(allocator: std.mem.Allocator, content: []const u8) !MemoryObject {
    var o = MemoryObject.init(allocator);
    o.setType(.blob);
    _ = try o.write(content);
    return o;
}

test "newObjectToPack non-delta" {
    var obj = try makeBlob(std.testing.allocator, "hello");
    defer obj.deinit();

    const otp = newObjectToPack(&obj);
    try std.testing.expect(otp.object == &obj);
    try std.testing.expect(otp.original == &obj);
    try std.testing.expect(otp.base == null);
    try std.testing.expect(!otp.isDelta());
    try std.testing.expectEqual(@as(i32, 0), otp.depth);
    try std.testing.expectEqual(@as(i64, 0), otp.offset);
    try std.testing.expect(!otp.isWritten());
    try std.testing.expect(!otp.wantWrite());
    try std.testing.expect(otp.objectType() == .blob);
    try std.testing.expectEqual(@as(i64, 5), otp.objectSize());
}

test "newDeltaObjectToPack" {
    var base_obj = try makeBlob(std.testing.allocator, "base-content");
    defer base_obj.deinit();
    var original = try makeBlob(std.testing.allocator, "full-target");
    defer original.deinit();
    var delta = try makeBlob(std.testing.allocator, "delta-bytes");
    defer delta.deinit();
    // Delta objects in pack use ofs/ref delta type; body is still MemoryObject.
    delta.setType(.ofs_delta);

    var base = newObjectToPack(&base_obj);
    const dtp = newDeltaObjectToPack(&base, &original, &delta);

    try std.testing.expect(dtp.object == &delta);
    try std.testing.expect(dtp.original == &original);
    try std.testing.expect(dtp.base == &base);
    try std.testing.expect(dtp.isDelta());
    try std.testing.expectEqual(@as(i32, 1), dtp.depth);
    // Type/Size/Hash come from Original (the resolved target), not the delta body.
    try std.testing.expect(dtp.objectType() == .blob);
    try std.testing.expectEqual(@as(i64, 11), dtp.objectSize());
}

test "nested delta depth" {
    var o1 = try makeBlob(std.testing.allocator, "a");
    defer o1.deinit();
    var o2 = try makeBlob(std.testing.allocator, "ab");
    defer o2.deinit();
    var o3 = try makeBlob(std.testing.allocator, "abc");
    defer o3.deinit();
    var d2 = try makeBlob(std.testing.allocator, "d2");
    defer d2.deinit();
    var d3 = try makeBlob(std.testing.allocator, "d3");
    defer d3.deinit();

    var base = newObjectToPack(&o1);
    var mid = newDeltaObjectToPack(&base, &o2, &d2);
    const leaf = newDeltaObjectToPack(&mid, &o3, &d3);

    try std.testing.expectEqual(@as(i32, 0), base.depth);
    try std.testing.expectEqual(@as(i32, 1), mid.depth);
    try std.testing.expectEqual(@as(i32, 2), leaf.depth);
    try std.testing.expect(leaf.base == &mid);
    try std.testing.expect(mid.base == &base);
}

test "want write / written state machine" {
    var obj = try makeBlob(std.testing.allocator, "x");
    defer obj.deinit();
    var otp = newObjectToPack(&obj);

    // Fresh: neither want-write nor written.
    try std.testing.expect(!otp.wantWrite());
    try std.testing.expect(!otp.isWritten());
    try std.testing.expectEqual(@as(i64, 0), otp.offset);

    otp.markWantWrite();
    try std.testing.expect(otp.wantWrite());
    try std.testing.expect(!otp.isWritten());
    try std.testing.expectEqual(@as(i64, 1), otp.offset);

    // Real pack offsets are > 1 (pack header is 12 bytes).
    otp.offset = 12;
    try std.testing.expect(!otp.wantWrite());
    try std.testing.expect(otp.isWritten());

    otp.offset = 2;
    try std.testing.expect(otp.isWritten());
    try std.testing.expect(!otp.wantWrite());
}

test "backToOriginal undeltifies" {
    var base_obj = try makeBlob(std.testing.allocator, "base");
    defer base_obj.deinit();
    var original = try makeBlob(std.testing.allocator, "orig");
    defer original.deinit();
    var delta = try makeBlob(std.testing.allocator, "dlt");
    defer delta.deinit();

    var base = newObjectToPack(&base_obj);
    var dtp = newDeltaObjectToPack(&base, &original, &delta);
    try std.testing.expect(dtp.isDelta());
    try std.testing.expectEqual(@as(i32, 1), dtp.depth);
    try std.testing.expect(dtp.object == &delta);

    dtp.backToOriginal();
    try std.testing.expect(!dtp.isDelta());
    try std.testing.expect(dtp.base == null);
    try std.testing.expectEqual(@as(i32, 0), dtp.depth);
    try std.testing.expect(dtp.object == &original);
    try std.testing.expect(dtp.original == &original);
}

test "backToOriginal no-op when not delta" {
    var obj = try makeBlob(std.testing.allocator, "solo");
    defer obj.deinit();
    var otp = newObjectToPack(&obj);
    otp.backToOriginal();
    try std.testing.expect(otp.object == &obj);
    try std.testing.expect(otp.base == null);
}

test "backToOriginal no-op when original cleaned" {
    var base_obj = try makeBlob(std.testing.allocator, "base");
    defer base_obj.deinit();
    var original = try makeBlob(std.testing.allocator, "orig");
    defer original.deinit();
    var delta = try makeBlob(std.testing.allocator, "dlt");
    defer delta.deinit();

    var base = newObjectToPack(&base_obj);
    var dtp = newDeltaObjectToPack(&base, &original, &delta);
    dtp.cleanOriginal();
    dtp.backToOriginal(); // Original is nil → stay delta
    try std.testing.expect(dtp.isDelta());
    try std.testing.expect(dtp.object == &delta);
    try std.testing.expectEqual(@as(i32, 1), dtp.depth);
}

test "setOriginal save and clean metadata" {
    var obj = try makeBlob(std.testing.allocator, "content");
    defer obj.deinit();
    var otp = newObjectToPack(&obj);

    otp.setOriginal(&obj);
    try std.testing.expect(otp.resolved_original);
    try std.testing.expect(otp.original_type == .blob);
    try std.testing.expectEqual(@as(i64, 7), otp.original_size);
    const h = otp.objectHash();
    try std.testing.expect(!h.isZero());
    try std.testing.expect(h.eql(otp.original_hash));

    otp.cleanOriginal();
    try std.testing.expect(otp.original == null);
    // Metadata still serves Type/Hash/Size.
    try std.testing.expect(otp.objectType() == .blob);
    try std.testing.expectEqual(@as(i64, 7), otp.objectSize());
    try std.testing.expect(otp.objectHash().eql(h));
}

test "setOriginal nil keeps resolved metadata" {
    var obj = try makeBlob(std.testing.allocator, "keep-me");
    defer obj.deinit();
    var otp = newObjectToPack(&obj);
    otp.setOriginal(&obj);
    const saved_hash = otp.original_hash;
    const saved_size = otp.original_size;

    otp.setOriginal(null);
    try std.testing.expect(otp.original == null);
    try std.testing.expect(otp.resolved_original);
    try std.testing.expect(otp.original_hash.eql(saved_hash));
    try std.testing.expectEqual(saved_size, otp.original_size);
    try std.testing.expect(otp.objectType() == .blob);
    try std.testing.expectEqual(saved_size, otp.objectSize());
}

test "setDelta attaches base and increments depth" {
    var base_obj = try makeBlob(std.testing.allocator, "b");
    defer base_obj.deinit();
    var target = try makeBlob(std.testing.allocator, "target");
    defer target.deinit();
    var delta = try makeBlob(std.testing.allocator, "delta");
    defer delta.deinit();

    var base = newObjectToPack(&base_obj);
    var target_otp = newObjectToPack(&target);
    try std.testing.expect(!target_otp.isDelta());

    target_otp.setDelta(&base, &delta);
    try std.testing.expect(target_otp.isDelta());
    try std.testing.expect(target_otp.base == &base);
    try std.testing.expect(target_otp.object == &delta);
    try std.testing.expectEqual(@as(i32, 1), target_otp.depth);
    // Original still the full target for Type/Size.
    try std.testing.expect(target_otp.original == &target);
    try std.testing.expect(target_otp.objectType() == .blob);
}

test "Type falls back to base when original cleaned without metadata" {
    var base_obj = try makeBlob(std.testing.allocator, "base");
    defer base_obj.deinit();
    base_obj.setType(.tree);
    var original = try makeBlob(std.testing.allocator, "orig");
    defer original.deinit();
    var delta = try makeBlob(std.testing.allocator, "d");
    defer delta.deinit();
    delta.setType(.ofs_delta);

    var base = newObjectToPack(&base_obj);
    var dtp = newDeltaObjectToPack(&base, &original, &delta);
    // Clean without saving metadata — Type walks to Base.
    dtp.original = null;
    dtp.resolved_original = false;
    try std.testing.expect(dtp.objectType() == .tree);
}

test "Type falls back to object when no original base or metadata" {
    var obj = try makeBlob(std.testing.allocator, "solo");
    defer obj.deinit();
    obj.setType(.commit);
    var otp = newObjectToPack(&obj);
    otp.original = null;
    otp.resolved_original = false;
    try std.testing.expect(otp.objectType() == .commit);
}
