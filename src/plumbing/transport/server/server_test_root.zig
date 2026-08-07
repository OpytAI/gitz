//! Test entrypoint for `//src/plumbing/transport/server:server_test`.
//!
//! Keeps production `root.zig` free of test-only imports (fixtures, e2e helpers).

test {
    _ = @import("root.zig");
    _ = @import("server_test.zig");
}
