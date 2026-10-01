//! Git merge strategies.
//!
//! Not a go-git package. `Repository.merge` stays fast-forward only.
//! Goldens and the rules in this package follow Git.

const error_mod = @import("error.zig");
const options_mod = @import("options.zig");
const apply_mod = @import("apply.zig");

pub const Error = error_mod.Error;

pub const Strategy = options_mod.Strategy;
pub const FastForward = options_mod.FastForward;
pub const Favor = options_mod.Favor;
pub const DiffAlgorithm = options_mod.DiffAlgorithm;
pub const ConflictStyle = options_mod.ConflictStyle;
pub const Identity = options_mod.Identity;
pub const MergeOptions = options_mod.MergeOptions;
pub const ContinueOptions = options_mod.ContinueOptions;
pub const MergeResult = options_mod.MergeResult;

pub const merge = apply_mod.merge;
pub const mergeAbort = apply_mod.mergeAbort;
pub const mergeContinue = apply_mod.mergeContinue;

test {
    _ = error_mod;
    _ = options_mod;
    _ = @import("model.zig");
    _ = @import("engine.zig");
    _ = apply_mod;
}
