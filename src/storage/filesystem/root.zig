//! storage/filesystem — on-disk git storage backend (go-git `storage/filesystem`).
//!
//! Composite of object, reference, index, config, shallow, and module storages
//! over `//src/fs` (`Mem` for hermetic tests; `Os` via `std.Io` for on-disk)
//! plus `//src/storage/filesystem/dotgit` layout helpers (`DotGit` / `DotGitOs`).
//!
//! Storage types are monomorphised over `Fs`:
//! - `Storage` / `StorageMem` = Mem specialisation (default call sites)
//! - `StorageOs` = Os specialisation
//! - `newStorage` / `newStorageWithOptions` — Mem
//! - `newStorageOs` / `newStorageOsWithOptions` — Os
//!
//! # go-git surface map
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `NewStorage` / `NewStorageWithOptions` | `newStorage` / `newStorageWithOptions` |
//! | `Storage.Init` | `Storage.initLayout` |
//! | `Storage.Filesystem` | `Storage.filesystem` |
//! | `ObjectStorage.SetEncodedObject` | `setEncodedObject` |
//! | `ObjectStorage.LazyWriter` | `lazyWriter` / `LazyWriter` |
//! | `ObjectStorage.IterEncodedObjects` | `iterEncodedObjects` (loose + pack, `ObjectHashIter`) |
//! | `ObjectStorage` pack path | `requireIndex` / `getFromPackfile` / `encodedObject` |
//! | `LooseObjectTime` / `DeleteLooseObject` | `looseObjectTime` / `deleteLooseObject` |
//! | `HashesWithPrefix` | `hashesWithPrefix` |
//! | `DeleteOldObjectPackAndIndex` | `deleteOldObjectPackAndIndex` |
//! | `ReferenceStorage` / `IndexStorage` / … | same method names |
//! | `storage_test.go` BaseStorageSuite | `filesystem_test` + `//src/storage:storage_suite` |

const std = @import("std");
const plumbing = @import("plumbing");
const cache_pkg = @import("cache");
const fs_pkg = @import("fs");
const gitconfig = @import("gitconfig");

const storage_mod = @import("storage.zig");
const object_mod = @import("object.zig");
const reference_mod = @import("reference.zig");
const index_mod = @import("index.zig");
const config_mod = @import("config.zig");
const shallow_mod = @import("shallow.zig");
const module_mod = @import("module.zig");
const deltaobject_mod = @import("deltaobject.zig");
const dotgit = @import("dotgit");

// --- Storage shell ---

/// Generic factory: `StorageFor(fs.Mem)` / `StorageFor(fs.Os)`.
pub const StorageFor = storage_mod.Storage;
/// Mem specialisation (default, all existing call sites).
pub const StorageMem = storage_mod.StorageMem;
/// Os specialisation (on-disk via `std.Io`).
pub const StorageOs = storage_mod.StorageOs;
/// Default export — Mem specialisation (backward compatible).
pub const Storage = StorageMem;

pub const Options = storage_mod.Options;
pub const OptionsOs = storage_mod.OptionsOs;
pub const OptionsFor = storage_mod.OptionsFor;
pub const newStorage = storage_mod.newStorage;
pub const newStorageWithOptions = storage_mod.newStorageWithOptions;
pub const newStorageOs = storage_mod.newStorageOs;
pub const newStorageOsWithOptions = storage_mod.newStorageOsWithOptions;
pub const newStorageFor = storage_mod.newStorageFor;
pub const newStorageWithOptionsFor = storage_mod.newStorageWithOptionsFor;

// --- Module storage ---

pub const ModuleStorageFor = module_mod.ModuleStorageFor;
pub const ModuleStorageMem = module_mod.ModuleStorageMem;
pub const ModuleStorageOs = module_mod.ModuleStorageOs;
pub const ModuleStorage = module_mod.ModuleStorage;

// --- Capability flags ---

pub const implements_transactioner = storage_mod.implements_transactioner;
pub const implements_packfile_writer = storage_mod.implements_packfile_writer;
pub const implements_delta_object_storer = storage_mod.implements_delta_object_storer;

// --- Object storage ---

/// Generic factory: `ObjectStorageFor(fs.Mem)` / `ObjectStorageFor(fs.Os)`.
pub const ObjectStorageFor = object_mod.ObjectStorageFor;
pub const ObjectStorageMem = object_mod.ObjectStorageMem;
pub const ObjectStorageOs = object_mod.ObjectStorageOs;
/// Default export — Mem specialisation.
pub const ObjectStorage = ObjectStorageMem;
pub const ObjectHashIter = object_mod.ObjectHashIter;
pub const ObjectHashIterOs = object_mod.ObjectHashIterOs;
/// go-git LazyWriter (Mem).
pub const LazyWriter = object_mod.LazyWriter;
/// LazyWriter for Os ObjectStorage.
pub const LazyWriterOs = object_mod.LazyWriterOs;
pub const newObjectStorage = object_mod.newObjectStorage;
pub const newObjectStorageWithOptions = object_mod.newObjectStorageWithOptions;
pub const newObjectStorageOs = object_mod.newObjectStorageOs;
pub const newObjectStorageOsWithOptions = object_mod.newObjectStorageOsWithOptions;

// --- Reference storage ---

pub const ReferenceStorageFor = reference_mod.ReferenceStorage;
pub const ReferenceStorageMem = reference_mod.ReferenceStorageMem;
pub const ReferenceStorageOs = reference_mod.ReferenceStorageOs;
pub const ReferenceStorage = ReferenceStorageMem;
pub const ReferenceSliceIter = reference_mod.ReferenceSliceIter;

// --- Index storage ---

pub const IndexStorageFor = index_mod.IndexStorage;
pub const IndexStorageMem = index_mod.IndexStorageMem;
pub const IndexStorageOs = index_mod.IndexStorageOs;
pub const IndexStorage = IndexStorageMem;
pub const Index = index_mod.Index;

// --- Config storage ---

pub const ConfigStorageFor = config_mod.ConfigStorage;
pub const ConfigStorageMem = config_mod.ConfigStorageMem;
pub const ConfigStorageOs = config_mod.ConfigStorageOs;
pub const ConfigStorage = ConfigStorageMem;
pub const Config = config_mod.Config;
pub const ConfigStorer = gitconfig.ConfigStorer(Config);

pub fn configStorerFor(comptime Fs: type, storage: *StorageFor(Fs)) ConfigStorer {
    return ConfigStorer.from(StorageFor(Fs), storage);
}

// --- Shallow storage ---

pub const ShallowStorageFor = shallow_mod.ShallowStorage;
pub const ShallowStorageMem = shallow_mod.ShallowStorageMem;
pub const ShallowStorageOs = shallow_mod.ShallowStorageOs;
pub const ShallowStorage = ShallowStorageMem;

// --- DotGit re-export ---

pub const DotGit = dotgit.DotGit;
pub const DotGitOs = dotgit.DotGitOs;
pub const DotGitFor = dotgit.DotGitFor;

pub const newDeltaObject = deltaobject_mod.newDeltaObject;

test {
    _ = storage_mod;
    _ = object_mod;
    _ = reference_mod;
    _ = index_mod;
    _ = config_mod;
    _ = shallow_mod;
    _ = module_mod;
    _ = deltaobject_mod;
    _ = dotgit;
}
