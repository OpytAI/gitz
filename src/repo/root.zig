//! Repository core (go-git root package — partial).
//!
//! Default Init/Open use `*memory.Storage`. `RepositoryFor` exposes the same
//! local object/ref/config/worktree surface for compatible backends.
//! PlainInit/PlainOpen over filesystem storage + `fs.Mem` live in `plain.zig`.
//! Remote Fetch / List / Push use `//src/remote` and are re-exported here.
//! Storer config is `memory.Config`; high-level remotes/branches use `gitconfig`
//! (also via `configScoped`).

const repository = @import("repository.zig");
const facade = @import("facade.zig");
const log_mod = @import("log.zig");
const error_mod = @import("error.zig");
const remote_mod = @import("remote.zig");
const crud = @import("crud.zig");
const plain = @import("plain.zig");
const worktree_api = @import("worktree_api.zig");
const repack_mod = @import("repack.zig");

pub const Error = error_mod.Error;

pub const RepackConfig = repack_mod.RepackConfig;
pub const repackObjects = repack_mod.repackObjects;
pub const repackObjectsFs = repack_mod.repackObjectsFs;
pub const MergeStrategy = repository.MergeStrategy;
pub const MergeOptions = repository.MergeOptions;
pub const PruneOptions = repository.PruneOptions;
pub const BlameResult = repository.BlameResult;

pub const Repository = repository.Repository;
pub const RepositoryFor = repository.RepositoryFor;
pub const InitOptions = repository.InitOptions;
pub const git_dir_name = repository.git_dir_name;
pub const newRepository = repository.newRepository;
pub const newRepositoryFor = repository.newRepositoryFor;
pub const init = repository.init;
pub const initWithOptions = repository.initWithOptions;
pub const open = repository.open;
pub const verifyExtensions = repository.verifyExtensions;
pub const configScopedFromLocal = repository.configScopedFromLocal;
pub const cloneMemoryConfig = repository.cloneMemoryConfig;
pub const mergeGitconfigIntoMemory = repository.mergeGitconfigIntoMemory;

pub const LogOptions = log_mod.LogOptions;
pub const LogOrder = log_mod.LogOrder;
pub const LogResult = log_mod.LogResult;
pub const EncodedCommitIter = facade.EncodedCommitIter;
pub const EncodedCommitIterFor = facade.EncodedCommitIterFor;
pub const BlobObjectsIter = facade.BlobObjectsIter;
pub const BlobObjectsIterFor = facade.BlobObjectsIterFor;
pub const TagObjectsIter = facade.TagObjectsIter;
pub const TagObjectsIterFor = facade.TagObjectsIterFor;
pub const ObjectsIter = facade.ObjectsIter;
pub const ObjectsIterFor = facade.ObjectsIterFor;
pub const FilteredRefIter = facade.FilteredRefIter;
pub const FilteredRefIterFor = facade.FilteredRefIterFor;

pub const Remote = remote_mod.Remote;
pub const RemoteFor = remote_mod.RemoteFor;
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
pub const AnonymousRemoteFor = crud.AnonymousRemoteFor;

pub const PlainRepository = plain.PlainRepository;
pub const PlainInitOptions = plain.PlainInitOptions;
pub const PlainOpenOptions = plain.PlainOpenOptions;
pub const plainInit = plain.plainInit;
pub const plainInitWithOptions = plain.plainInitWithOptions;
pub const plainOpen = plain.plainOpen;
pub const plainOpenWithOptions = plain.plainOpenWithOptions;

/// go-git `Repository.Worktree` free-function form of `Repository.worktree`.
pub const worktreeOf = worktree_api.worktreeOf;
pub const worktreeEmbedded = worktree_api.worktreeEmbedded;

// activateFormat is a method on Repository / PlainRepository.

// Network MapLoader e2e lives in network_tests.zig pulled by //src/repo:repo_test
// only (test_root). Keep production root free of transport test fixtures.
test {
    _ = repository;
    _ = facade;
    _ = log_mod;
    _ = error_mod;
    _ = remote_mod;
    _ = crud;
    _ = plain;
    _ = worktree_api;
    _ = repack_mod;
}
