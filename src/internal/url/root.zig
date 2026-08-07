//! Package root — port of go-git `internal/url` (v5.19.2).
//!
//! Inventory / import name: `url` (`//src/internal/url`).

const url_mod = @import("url.zig");

pub const matchesScheme = url_mod.matchesScheme;
pub const matchesScpLike = url_mod.matchesScpLike;
pub const findScpLikeComponents = url_mod.findScpLikeComponents;
pub const isLocalEndpoint = url_mod.isLocalEndpoint;
pub const hasDosDrivePrefix = url_mod.hasDosDrivePrefix;

// Re-export tests from url.zig via this root for zig_test main = root.zig.
test {
    _ = @import("url.zig");
}
