//! Test entry for //src/plumbing/transport/git:git_test.
//!
//! Pulls unit tests via package root and hermetic/live e2e suites.

test {
    _ = @import("root.zig");
    _ = @import("e2e_test.zig");
}
