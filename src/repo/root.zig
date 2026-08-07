//! Repository core (go-git root package — partial).
//!
//! Init/Open over `*memory.Storage` plus object/ref facades. Full Worktree and
//! Remote engines are later phases. Storer config is still `memory.Config`;
//! high-level remotes/branches use `gitconfig` separately.

const repository = @import("repository.zig");
const facade = @import("facade.zig");
const error_mod = @import("error.zig");
const remote_mod = @import("remote.zig");
const crud = @import("crud.zig");

pub const Error = error_mod.Error;

pub const Repository = repository.Repository;
pub const InitOptions = repository.InitOptions;
pub const git_dir_name = repository.git_dir_name;
pub const newRepository = repository.newRepository;
pub const init = repository.init;
pub const initWithOptions = repository.initWithOptions;
pub const open = repository.open;

pub const LogOptions = facade.LogOptions;
pub const LogOrder = facade.LogOrder;
pub const LogResult = facade.LogResult;
pub const EncodedCommitIter = facade.EncodedCommitIter;
pub const BlobObjectsIter = facade.BlobObjectsIter;
pub const TagObjectsIter = facade.TagObjectsIter;
pub const ObjectsIter = facade.ObjectsIter;
pub const FilteredRefIter = facade.FilteredRefIter;

pub const Remote = remote_mod.Remote;
pub const CreateTagOptions = crud.CreateTagOptions;
pub const AnonymousRemote = crud.AnonymousRemote;

test {
    _ = repository;
    _ = facade;
    _ = error_mod;
    _ = remote_mod;
    _ = crud;
}
