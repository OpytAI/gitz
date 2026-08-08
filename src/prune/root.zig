//! Package prune — object reachability walk + loose-object prune (go-git root).
//!
//! Ports `object_walker.go` and `prune.go`. Free functions take
//! `*memory.Storage` (LooseObjectStorer method set on memory backend).
//!
//! Memory `deleteLooseObject` returns `error.NotSupported` (go-git memory).
//! `prune` still walks and reports unreferenced hashes via the handler;
//! callers that need real deletes use a filesystem storage backend.
//!
//! Collect for `forEachObjectHash` uses stack-local context (no process-local
//! statics). Concurrent prune on distinct storages is safe; one storage is not
//! safe for concurrent mutation during walk/handler.
//!
//! # go-git surface
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `objectWalker` / `newObjectWalker` | `ObjectWalker` / `newObjectWalker` |
//! | `walkAllRefs` / `walkObjectTree` / `isSeen` | methods on `ObjectWalker` |
//! | `PruneHandler` / `PruneOptions` | `PruneHandler` / `PruneOptions` |
//! | `ErrLooseObjectsNotSupported` | `ErrLooseObjectsNotSupported` / `error.LooseObjectsNotSupported` |
//! | `Repository.DeleteObject` | `deleteObject` |
//! | `Repository.Prune` | `prune` / `pruneWithHandler` |
//!
//! # go-git test map
//!
//! Fixture-based go-git `prune_test.go` uses filesystem unpacked fixtures.
//! This package covers the same semantics with in-memory objects:
//!
//! | go-git idea | Zig test |
//! |-------------|----------|
//! | Walk marks reachable objects | `walker marks reachable…` (object_walker.zig) |
//! | Prune deletes unreachable | `prune calls handler only for unreachable…` |
//! | Age filter keeps objects | `prune with age filter skips all on memory` |
//! | DeleteObject | `deleteObject on memory returns NotSupported` |

const object_walker = @import("object_walker.zig");
const prune_mod = @import("prune.zig");

// --- object_walker.zig ---
pub const SeenSet = object_walker.SeenSet;
pub const ObjectWalker = object_walker.ObjectWalker;
pub const newObjectWalker = object_walker.newObjectWalker;

// --- prune.zig ---
pub const PruneHandler = prune_mod.PruneHandler;
pub const PruneOptions = prune_mod.PruneOptions;
pub const ErrLooseObjectsNotSupported = prune_mod.ErrLooseObjectsNotSupported;
pub const Error = prune_mod.Error;
pub const deleteObject = prune_mod.deleteObject;
pub const prune = prune_mod.prune;
pub const pruneWithHandler = prune_mod.pruneWithHandler;

test {
    _ = object_walker;
    _ = prune_mod;
}
