//! Package merkletrie — Merkle + radix tries for git trees.
//!
//! Port of go-git v5.19.2 `utils/merkletrie` (change, iter, doubleiter, difftree).

const change_mod = @import("change.zig");
const iter_mod = @import("iter.zig");
const doubleiter_mod = @import("doubleiter.zig");
const difftree_mod = @import("difftree.zig");

// --- change ---
pub const Action = change_mod.Action;
pub const Change = change_mod.Change;
pub const Changes = change_mod.Changes;
pub const newInsert = change_mod.newInsert;
pub const newDelete = change_mod.newDelete;
pub const newModify = change_mod.newModify;
pub const Error = change_mod.Error;

// --- iter ---
pub const Iter = iter_mod.Iter;

// --- doubleiter (internal to package; exported for completeness) ---
pub const DoubleIter = doubleiter_mod.DoubleIter;
pub const Remaining = doubleiter_mod.Remaining;
pub const Comparison = doubleiter_mod.Comparison;

// --- difftree ---
pub const Context = difftree_mod.Context;
pub const diffTree = difftree_mod.diffTree;
pub const diffTreeContext = difftree_mod.diffTreeContext;
pub const DiffError = difftree_mod.Error;

test {
    _ = @import("change.zig");
    _ = @import("iter.zig");
    _ = @import("doubleiter.zig");
    _ = @import("difftree.zig");
}
