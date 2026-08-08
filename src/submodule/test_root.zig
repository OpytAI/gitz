//! Test entry for //src/submodule:submodule_test.

test {
    _ = @import("root.zig");
    _ = @import("tests.zig");
}
