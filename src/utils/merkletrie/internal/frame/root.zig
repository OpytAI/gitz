//! Package frame — sibling stack for merkletrie iteration.
//!
//! Port of go-git v5.19.2 `utils/merkletrie/internal/frame`.

const frame_mod = @import("frame.zig");

pub const Frame = frame_mod.Frame;

test {
    _ = @import("frame.zig");
}
