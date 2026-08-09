//! Remote handle for the repository package.
//!
//! Re-exports the full `//src/remote` surface (Fetch / List / Push).
//! Config-only CRUD lives in `crud.zig`.

const remote_pkg = @import("remote");

pub const Remote = remote_pkg.Remote;
pub const newRemote = remote_pkg.newRemote;
pub const newRemoteEmbedded = remote_pkg.newRemoteEmbedded;
pub const freeReferences = remote_pkg.freeReferences;
pub const isFastForward = remote_pkg.isFastForward;

pub const Error = remote_pkg.Error;
pub const default_remote_name = remote_pkg.default_remote_name;
pub const TagMode = remote_pkg.TagMode;
pub const PeelingOption = remote_pkg.PeelingOption;
pub const ForceWithLease = remote_pkg.ForceWithLease;
pub const PushOption = remote_pkg.PushOption;
pub const FetchOptions = remote_pkg.FetchOptions;
pub const PushOptions = remote_pkg.PushOptions;
pub const ListOptions = remote_pkg.ListOptions;
