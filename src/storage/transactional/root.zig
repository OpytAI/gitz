//! storage/transactional — demux write/read across two storers (go-git).
//!
//! Writes go to a temporal storer; reads prefer base (objects) or temporal
//! (refs / non-empty shallow / set index & config). `commit` copies temporal
//! content into base.
//!
//! PackfileWriter capability follows temporal (memory: false).
//!
//! # go-git map
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `NewStorage` | `newStorage` / `Storage.init` |
//! | `NewObjectStorage` | `newObjectStorage` |
//! | `NewReferenceStorage` | `newReferenceStorage` |
//! | `NewIndexStorage` | `newIndexStorage` |
//! | `NewShallowStorage` | `newShallowStorage` |
//! | `NewConfigStorage` | `newConfigStorage` |
//! | `Storage.Commit` | `Storage.commit` |
//! | `Storage.PackfileWriter` | `Storage.packfileWriter` (when temporal supports it) |
//! | `ObjectStorage` | `ObjectStorage` |
//! | `ReferenceStorage` | `ReferenceStorage` |
//! | `IndexStorage` | `IndexStorage` |
//! | `ShallowStorage` | `ShallowStorage` |
//! | `ConfigStorage` | `ConfigStorage` |
//!
//! Types hold `*memory.Storage` for base and temporal (Zig style; no interfaces).

const std = @import("std");

const storage_mod = @import("storage.zig");
const object_mod = @import("object.zig");
const reference_mod = @import("reference.zig");
const index_mod = @import("index.zig");
const shallow_mod = @import("shallow.zig");
const config_mod = @import("config.zig");

pub const Storage = storage_mod.Storage;
pub const newStorage = storage_mod.newStorage;
pub const implements_packfile_writer = storage_mod.implements_packfile_writer;

pub const ObjectStorage = object_mod.ObjectStorage;
pub const MultiObjectIter = object_mod.MultiObjectIter;
pub const newObjectStorage = object_mod.newObjectStorage;

pub const ReferenceStorage = reference_mod.ReferenceStorage;
pub const MultiReferenceIter = reference_mod.MultiReferenceIter;
pub const newReferenceStorage = reference_mod.newReferenceStorage;

pub const IndexStorage = index_mod.IndexStorage;
pub const newIndexStorage = index_mod.newIndexStorage;

pub const ShallowStorage = shallow_mod.ShallowStorage;
pub const newShallowStorage = shallow_mod.newShallowStorage;

pub const ConfigStorage = config_mod.ConfigStorage;
pub const newConfigStorage = config_mod.newConfigStorage;

test {
    _ = storage_mod;
    _ = object_mod;
    _ = reference_mod;
    _ = index_mod;
    _ = shallow_mod;
    _ = config_mod;
}

test "newStorage surface" {
    try std.testing.expect(@TypeOf(newStorage) != void);
    try std.testing.expect(@TypeOf(Storage.commit) != void);
    try std.testing.expect(@TypeOf(Storage.packfileWriter) != void);
    try std.testing.expect(@TypeOf(newObjectStorage) != void);
    try std.testing.expect(@TypeOf(newReferenceStorage) != void);
    try std.testing.expect(@TypeOf(newIndexStorage) != void);
    try std.testing.expect(@TypeOf(newShallowStorage) != void);
    try std.testing.expect(@TypeOf(newConfigStorage) != void);
    try std.testing.expectEqual(false, implements_packfile_writer);
}
