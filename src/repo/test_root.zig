//! Test root for //src/repo:repo_test — production surface + network e2e.
const repo = @import("root.zig");
test {
    _ = repo;
    _ = @import("network_tests.zig");
    _ = @import("backend_tests.zig");
}
