//! Package filesystem — merkletrie noders over billy-style `fs`.
//!
//! Port of go-git v5.19.2 `utils/merkletrie/filesystem`.

const node_mod = @import("node.zig");

pub const Options = node_mod.Options;
pub const Root = node_mod.Root;
pub const Node = node_mod.Node;
pub const FsVTable = node_mod.FsVTable;
pub const FsFile = node_mod.FsFile;
pub const vtableFor = node_mod.vtableFor;
pub const newRootNode = node_mod.newRootNode;
pub const newRootNodeWithOptions = node_mod.newRootNodeWithOptions;
pub const newRootNodeMem = node_mod.newRootNodeMem;
pub const newRootNodeMemWithOptions = node_mod.newRootNodeMemWithOptions;
pub const newRootNodeFor = node_mod.newRootNodeFor;
pub const newRootNodeForWithOptions = node_mod.newRootNodeForWithOptions;

test {
    _ = @import("node.zig");
}
