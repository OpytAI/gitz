//! Package index — merkletrie noders over plumbing/format/index.
//!
//! Port of go-git v5.19.2 `utils/merkletrie/index`.

const node_mod = @import("node.zig");

pub const Root = node_mod.Root;
pub const Node = node_mod.Node;
pub const newRootNode = node_mod.newRootNode;

test {
    _ = @import("node.zig");
}
