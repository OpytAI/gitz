//! Test root for `//src/remote:remote_test` — production surface + integration tests.
const remote = @import("root.zig");
test {
    _ = remote;
    _ = @import("tests.zig");
}
