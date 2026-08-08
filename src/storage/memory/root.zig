//! storage/memory — ephemeral in-memory git storage (go-git `storage/memory`).
//!
//! Composite of object, reference, shallow, index, config, and module storages.
//!
//! # go-git test map
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `storage/memory/storage_test.go` (BaseStorageSuite) | `//src/storage:suite_test` + `storage_suite` lib |
//! | Unit edges (objects/tx/refs/config/index) | tests in this package (`object.zig`, `reference.zig`, …) |
//!
//! Memory does **not** implement PackfileWriter or DeltaObjectStorer (capability false).
//! Memory **does** implement Transactioner via `begin()` → `TxObjectStorage`.

const std = @import("std");
const plumbing = @import("plumbing");

const error_mod = @import("error.zig");
const storage_mod = @import("storage.zig");
const object_mod = @import("object.zig");
const reference_mod = @import("reference.zig");
const config_mod = @import("config.zig");
const index_mod = @import("index.zig");
const module_mod = @import("module.zig");

pub const Storage = storage_mod.Storage;
pub const newStorage = storage_mod.newStorage;
pub const ShallowStorage = storage_mod.ShallowStorage;
pub const ModuleStorage = module_mod.ModuleStorage;

pub const implements_transactioner = storage_mod.implements_transactioner;
pub const implements_packfile_writer = storage_mod.implements_packfile_writer;
pub const implements_delta_object_storer = storage_mod.implements_delta_object_storer;

pub const ObjectStorage = object_mod.ObjectStorage;
pub const TxObjectStorage = object_mod.TxObjectStorage;
pub const ObjectSnapshotIter = object_mod.ObjectSnapshotIter;
/// Alias of `ObjectSnapshotIter` (not the storer borrowed-slice iterator).
pub const EncodedObjectSliceIter = object_mod.ObjectSnapshotIter;
pub const ObjectError = error_mod.Error;
/// Object-storage errors (`UnsupportedObjectType`, `NotSupported`).
pub const Error = error_mod.Error;

pub const ReferenceStorage = reference_mod.ReferenceStorage;
pub const ReferenceSliceIter = reference_mod.ReferenceSliceIter;

pub const ConfigStorage = config_mod.ConfigStorage;
pub const Config = config_mod.Config;
pub const RemoteConfig = config_mod.RemoteConfig;
pub const BranchConfig = config_mod.BranchConfig;
pub const ConfigError = config_mod.Error;

pub const IndexStorage = index_mod.IndexStorage;
pub const Index = index_mod.Index;
pub const Entry = index_mod.Entry;
pub const Time = index_mod.Time;

test {
    _ = error_mod;
    _ = storage_mod;
    _ = object_mod;
    _ = reference_mod;
    _ = config_mod;
    _ = index_mod;
    _ = module_mod;
}

test "newStorage empty object round-trip" {
    const allocator = std.testing.allocator;
    const s = try newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    const obj = try s.newEncodedObject();
    obj.setType(.blob);
    const h = try s.setEncodedObject(obj);
    var buf: [plumbing.MaxHexSize]u8 = undefined;
    try std.testing.expectEqualStrings(
        "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391",
        h.string(&buf),
    );

    const got = try s.encodedObject(.blob, h);
    try std.testing.expect(got.hash().eql(h));
}

test "reference check-and-set changed" {
    const allocator = std.testing.allocator;
    const s = try newStorage(allocator);
    defer {
        s.deinit();
        allocator.destroy(s);
    }

    try s.setReference(plumbing.Reference.fromStrings(
        "refs/heads/main",
        "c3f4688a08fd86f1bf8e055724c84b7a40a09733",
    ));
    try std.testing.expectError(
        error.ReferenceHasChanged,
        s.checkAndSetReference(
            plumbing.Reference.fromStrings("refs/heads/main", "bc9968d75e48de59f0870ffb71f5e160bbbdcf52"),
            plumbing.Reference.fromStrings("refs/heads/main", "482e0eada5de4039e6f216b45b3c9b683b83bfa"),
        ),
    );
}

test "memory capabilities and suite entry points exist" {
    try std.testing.expect(implements_transactioner);
    try std.testing.expect(!implements_packfile_writer);
    try std.testing.expect(!implements_delta_object_storer);
    // BaseStorageSuite lives in //src/storage:suite_test (go-git storage_test.go).
    try std.testing.expect(@TypeOf(newStorage) != void);
    try std.testing.expect(@TypeOf(Storage.begin) != void);
}
