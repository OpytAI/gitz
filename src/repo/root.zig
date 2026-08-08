//! Repository core (go-git root package — partial).
//!
//! Init/Open over `*memory.Storage` plus object/ref facades, Log, CreateTag,
//! and configScoped. PlainInit/PlainOpen over filesystem storage + `fs.Mem`
//! live in `plain.zig`. Full Worktree engine is phase 12.
//! Phase 11: Remote Fetch / List / Push via `//src/remote` (re-exported here).
//! Storer config is `memory.Config`; high-level remotes/branches use `gitconfig`
//! (also via `configScoped`).

const repository = @import("repository.zig");
const facade = @import("facade.zig");
const log_mod = @import("log.zig");
const error_mod = @import("error.zig");
const remote_mod = @import("remote.zig");
const crud = @import("crud.zig");
const plain = @import("plain.zig");

pub const Error = error_mod.Error;

pub const Repository = repository.Repository;
pub const InitOptions = repository.InitOptions;
pub const git_dir_name = repository.git_dir_name;
pub const newRepository = repository.newRepository;
pub const init = repository.init;
pub const initWithOptions = repository.initWithOptions;
pub const open = repository.open;
pub const configScopedFromLocal = repository.configScopedFromLocal;
pub const cloneMemoryConfig = repository.cloneMemoryConfig;
pub const mergeGitconfigIntoMemory = repository.mergeGitconfigIntoMemory;

pub const LogOptions = log_mod.LogOptions;
pub const LogOrder = log_mod.LogOrder;
pub const LogResult = log_mod.LogResult;
pub const EncodedCommitIter = facade.EncodedCommitIter;
pub const BlobObjectsIter = facade.BlobObjectsIter;
pub const TagObjectsIter = facade.TagObjectsIter;
pub const ObjectsIter = facade.ObjectsIter;
pub const FilteredRefIter = facade.FilteredRefIter;

pub const Remote = remote_mod.Remote;
pub const newRemote = remote_mod.newRemote;
pub const newRemoteEmbedded = remote_mod.newRemoteEmbedded;
pub const freeReferences = remote_mod.freeReferences;
pub const FetchOptions = remote_mod.FetchOptions;
pub const PushOptions = remote_mod.PushOptions;
pub const ListOptions = remote_mod.ListOptions;
pub const TagMode = remote_mod.TagMode;
pub const PeelingOption = remote_mod.PeelingOption;
pub const ForceWithLease = remote_mod.ForceWithLease;
pub const PushOption = remote_mod.PushOption;
pub const default_remote_name = remote_mod.default_remote_name;
pub const RemoteError = remote_mod.Error;

pub const CreateTagOptions = crud.CreateTagOptions;
pub const AnonymousRemote = crud.AnonymousRemote;

pub const PlainRepository = plain.PlainRepository;
pub const PlainInitOptions = plain.PlainInitOptions;
pub const PlainOpenOptions = plain.PlainOpenOptions;
pub const plainInit = plain.plainInit;
pub const plainInitWithOptions = plain.plainInitWithOptions;
pub const plainOpen = plain.plainOpen;
pub const plainOpenWithOptions = plain.plainOpenWithOptions;

// activateFormat is a method on Repository / PlainRepository.

test {
    _ = repository;
    _ = facade;
    _ = log_mod;
    _ = error_mod;
    _ = remote_mod;
    _ = crud;
    _ = plain;
}
