//! Unresolved pack delta object metadata (go-git `storage/filesystem/deltaobject.go`).
//!
//! go-git wraps an `EncodedObject` with BaseHash / ActualHash / ActualSize.
//! gitz attaches the same fields via `plumbing.MemoryObject.DeltaMeta`.

const plumbing = @import("plumbing");

const Hash = plumbing.Hash;
const MemoryObject = plumbing.MemoryObject;
const DeltaMeta = plumbing.DeltaMeta;

/// Attach delta metadata to a MemoryObject (go-git `newDeltaObject`).
/// Content remains the raw delta payload; type is left as set by the caller.
/// Hashes are re-canonicalized so dirty pad cannot poison map keys.
pub fn setDeltaObject(
    obj: *MemoryObject,
    actual_hash: Hash,
    base: Hash,
    actual_size: i64,
) void {
    obj.setDeltaMeta(.{
        .base_hash = Hash.fromBytes(base.slice()),
        .actual_hash = Hash.fromBytes(actual_hash.slice()),
        .actual_size = actual_size,
    });
}

/// Convenience constructor matching go-git `newDeltaObject` return shape.
pub fn newDeltaObject(
    obj: *MemoryObject,
    hash: Hash,
    base: Hash,
    size: i64,
) *MemoryObject {
    setDeltaObject(obj, hash, base, size);
    return obj;
}

// Keep DeltaMeta in the type graph for inventory / callers.
pub const Meta = DeltaMeta;
