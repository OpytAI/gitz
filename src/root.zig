//! gitz — Git in Zig.
//!
//! Full port of go-git v5.19.2. Package layout will mirror go-git under `src/`.
//! This root module is the Bazel smoke anchor until plumbing packages land.

const std = @import("std");

/// Library identity for smoke tests and tooling.
pub const name = "gitz";

/// Semantic version of the gitz library (not go-git).
pub const version = "0.0.0";

/// Pinned go-git reference (see GO_GIT_PIN.md).
pub const go_git_pin = "v5.19.2";

test "identity" {
    try std.testing.expectEqualStrings("gitz", name);
    try std.testing.expectEqualStrings("v5.19.2", go_git_pin);
}
