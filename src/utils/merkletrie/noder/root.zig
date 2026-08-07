//! Package noder — merkletrie node interface and paths.
//!
//! Port of go-git v5.19.2 `utils/merkletrie/noder`.

const noder_mod = @import("noder.zig");
const path_mod = @import("path.zig");

pub const Noder = noder_mod.Noder;
pub const Equal = noder_mod.Equal;
pub const defaultEqual = noder_mod.defaultEqual;
pub const noderOf = noder_mod.noderOf;
pub const no_children = noder_mod.no_children;
/// Alias matching go-git `NoChildren` name in docs.
pub const NoChildren = no_children;

pub const Path = path_mod.Path;

test {
    _ = @import("noder.zig");
    _ = @import("path.zig");
}
