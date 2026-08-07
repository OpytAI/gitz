//! Package storer — storage method-set contracts and iterator helpers.
//!
//! Port of go-git v5.19.2 `plumbing/storer`.
//!
//! Zig does not use Go interfaces. Backends implement the method sets below on
//! **concrete types** (for example `storage/memory.Storage`). Call sites use
//! those types directly or generic parameters constrained by the methods.
//!
//! Encoded objects are always `*plumbing.MemoryObject`.
//!
//! # EncodedObjectStorer method set
//!
//! A concrete type that stores encoded objects implements:
//!
//! | Method | Role |
//! |--------|------|
//! | `newEncodedObject(allocator)` | Return a new empty `*MemoryObject` (heap; caller owns until set) |
//! | `setEncodedObject(obj)` | Save object; return its `plumbing.Hash` |
//! | `encodedObject(object_type, hash)` | Load by type + hash; `AnyObject` matches any type |
//! | `iterEncodedObjects(object_type)` | Iterator over objects of the given type |
//! | `hasEncodedObject(hash)` | `error.ObjectNotFound` if missing, else success |
//! | `encodedObjectSize(hash)` | Plaintext size of the encoded object body |
//! | `addAlternate(remote)` | Register an alternate object database path |
//!
//! Related method sets (backend-specific; go-git uses type-assert, not defaults):
//!
//! - **DeltaObjectStorer:** `deltaObject(object_type, hash)` — like `encodedObject` but leave deltas unresolved.
//! - **Transactioner:** `begin()` → **Transaction** with `setEncodedObject` / `encodedObject` / `commit` / `rollback`.
//! - **LooseObjectStorer:** `forEachObjectHash`, `looseObjectTime`, `deleteLooseObject`.
//! - **PackedObjectStorer:** `objectPacks`, `deleteOldObjectPackAndIndex`.
//! - **PackfileWriter:** `packfileWriter()` when the backend supports direct pack ingest.
//!   Callers type-assert (capability flag). If absent, write objects via `setEncodedObject`.
//!   This package documents the method set only — no trait or stub.
//!
//! # ReferenceStorer method set
//!
//! A concrete type that stores references implements:
//!
//! | Method | Role |
//! |--------|------|
//! | `setReference(ref)` | Create or update a reference |
//! | `checkAndSetReference(new, old)` | CAS update; if `old` is non-null, require current value match |
//! | `reference(name)` | Lookup by name; `error.ReferenceNotFound` if missing |
//! | `iterReferences()` | Iterator over all references |
//! | `removeReference(name)` | Delete a reference |
//! | `countLooseRefs()` | Count of loose (unpacked) refs |
//! | `packRefs()` | Pack loose refs into packed-refs form |
//!
//! # ShallowStorer method set
//!
//! See `shallow.zig`. Methods: `setShallow(hashes)`, `shallow()`.
//!
//! # IndexStorer method set
//!
//! See `index_stub.zig`. Methods: `setIndex(idx)`, `index()`. Phase 4 uses
//! `IndexStub` until the full index codec lands in phase 5.
//!
//! # Combined storer (go-git `Storer`)
//!
//! A full storer implements both EncodedObjectStorer and ReferenceStorer method
//! sets. Some backends also expose `init()` (go-git `Initializer`).
//!
//! # Errors
//!
//! Package errors live in `error.zig` (`storer.Error`):
//!
//! - `Stop` — ForEach callback stop (go-git `ErrStop`); not a hard failure
//! - `MaxResolveRecursion` — symbolic-ref resolution depth exceeded
//!   (go-git `ErrMaxResolveRecursion`)
//!
//! Plumbing errors (`ObjectNotFound`, `ReferenceNotFound`) come from `plumbing`.
//!
//! Constants: `MaxResolveRecursion == 1024` (go-git).

const error_mod = @import("error.zig");
const object_mod = @import("object.zig");
const reference_mod = @import("reference.zig");
const shallow_mod = @import("shallow.zig");
const index_stub_mod = @import("index_stub.zig");

// --- error.zig ---
pub const Error = error_mod.Error;

// --- object.zig (go-git object.go iterators / helpers) ---
pub const EncodedObjectIter = object_mod.EncodedObjectIter;
pub const ObjectGetter = object_mod.ObjectGetter;
pub const EncodedObjectLookupIter = object_mod.EncodedObjectLookupIter;
pub const newEncodedObjectLookupIter = object_mod.newEncodedObjectLookupIter;
pub const EncodedObjectSliceIter = object_mod.EncodedObjectSliceIter;
pub const newEncodedObjectSliceIter = object_mod.newEncodedObjectSliceIter;
pub const MultiEncodedObjectIter = object_mod.MultiEncodedObjectIter;
pub const newMultiEncodedObjectIter = object_mod.newMultiEncodedObjectIter;
pub const forEachIterator = object_mod.forEachIterator;
pub const forEachEncodedObject = object_mod.forEachEncodedObject;

// --- reference.zig (go-git reference.go) ---
pub const MaxResolveRecursion = reference_mod.MaxResolveRecursion;
pub const ReferenceIter = reference_mod.ReferenceIter;
pub const forEachReference = reference_mod.forEachReference;
pub const ReferenceFilteredIter = reference_mod.ReferenceFilteredIter;
pub const newReferenceFilteredIter = reference_mod.newReferenceFilteredIter;
pub const ReferenceSliceIter = reference_mod.ReferenceSliceIter;
pub const newReferenceSliceIter = reference_mod.newReferenceSliceIter;
pub const MultiReferenceIter = reference_mod.MultiReferenceIter;
pub const newMultiReferenceIter = reference_mod.newMultiReferenceIter;
pub const resolveReference = reference_mod.resolveReference;
pub const resolveReferenceFrom = reference_mod.resolveReferenceFrom;

// --- shallow.zig / index_stub.zig ---
pub const ShallowList = shallow_mod.ShallowList;
pub const IndexStub = index_stub_mod.IndexStub;
pub const IndexStubStore = index_stub_mod.IndexStubStore;

// Method-set name tokens for inventories (documentation only; not traits).
pub const method_sets = struct {
    pub const EncodedObjectStorer = "EncodedObjectStorer";
    pub const ReferenceStorer = "ReferenceStorer";
    pub const ShallowStorer = "ShallowStorer";
    pub const IndexStorer = "IndexStorer";
    pub const DeltaObjectStorer = "DeltaObjectStorer";
    pub const Transactioner = "Transactioner";
    pub const Transaction = "Transaction";
    pub const LooseObjectStorer = "LooseObjectStorer";
    pub const PackedObjectStorer = "PackedObjectStorer";
    pub const PackfileWriter = "PackfileWriter";
    pub const Initializer = "Initializer";
    pub const Storer = "Storer";
};

test {
    _ = error_mod;
    _ = object_mod;
    _ = reference_mod;
    _ = shallow_mod;
    _ = index_stub_mod;
}

test "storer package surface constants and constructors" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 1024), MaxResolveRecursion);
    try std.testing.expect(Error.Stop == Error.Stop);
    try std.testing.expect(Error.MaxResolveRecursion == Error.MaxResolveRecursion);
    _ = EncodedObjectSliceIter.init;
    _ = EncodedObjectLookupIter.init;
    _ = MultiEncodedObjectIter.init;
    _ = ReferenceSliceIter.init;
    _ = MultiReferenceIter.init;
    _ = ReferenceFilteredIter.init;
    _ = resolveReference;
    _ = forEachIterator;
    _ = forEachReference;
    _ = method_sets.PackfileWriter;
    _ = method_sets.EncodedObjectStorer;
    _ = ShallowList;
    _ = IndexStub;
    _ = IndexStubStore;
}
