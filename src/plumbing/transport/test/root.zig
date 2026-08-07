//! Package transport/test — cross-package transport fixtures and e2e
//! (go-git `plumbing/transport/test`).
//!
//! Production libraries must not depend on this package. See `docs/TESTING.md`.

const fixtures_mod = @import("fixtures.zig");

pub const makeEndpoint = fixtures_mod.makeEndpoint;
pub const storeBlob = fixtures_mod.storeBlob;
pub const storeTree = fixtures_mod.storeTree;
pub const storeCommit = fixtures_mod.storeCommit;
pub const populateRepo = fixtures_mod.populateRepo;
pub const storeAnnotatedTag = fixtures_mod.storeAnnotatedTag;

test {
    _ = @import("fixtures.zig");
    _ = @import("serve_e2e.zig");
}
