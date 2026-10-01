//! Thin check that Worktree.merge is the merge package, not a second implementation.

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");
const fs_pkg = @import("fs");

const worktree = @import("root.zig");

test "Worktree.merge on an unborn HEAD changes nothing" {
    const gpa = std.testing.allocator;
    const sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    try sto.setReference(plumbing.Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
    const tree = try gpa.create(fs_pkg.Mem);
    defer {
        tree.deinit();
        gpa.destroy(tree);
    }
    tree.* = try fs_pkg.Mem.init(gpa);
    var w = worktree.newWorktree(gpa, sto, tree);
    try std.testing.expectError(error.UnbornHead, w.merge(&.{plumbing.ZeroHash}, .{}));
}
