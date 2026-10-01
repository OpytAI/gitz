const worktree = @import("root.zig");
test {
    _ = worktree;
    _ = @import("tests.zig");
    _ = @import("merge_test.zig");
}
