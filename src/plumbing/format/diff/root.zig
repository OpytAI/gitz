//! Package diff implements encoding of Git unified diffs.
//!
//! Port of go-git v5.19.2 `plumbing/format/diff`.
//!
//! # Surface
//!
//! | go-git | Zig |
//! |---|---|
//! | `Operation` / Equal / Add / Delete | `Operation` |
//! | `Patch` / `FilePatch` / `File` / `Chunk` | concrete structs |
//! | `ColorKey` / `ColorConfig` / `NewColorConfig` / `WithColor` / `Reset` | `colorconfig.zig` |
//! | `UnifiedEncoder` / `NewUnifiedEncoder` / `SetColor` / … / `Encode` | `unified_encoder.zig` |
//! | `DefaultContextLines` | `DefaultContextLines` |

const patch_mod = @import("patch.zig");
const colorconfig_mod = @import("colorconfig.zig");
const unified_encoder_mod = @import("unified_encoder.zig");

// --- patch ---
pub const Operation = patch_mod.Operation;
pub const File = patch_mod.File;
pub const Chunk = patch_mod.Chunk;
pub const FilePatch = patch_mod.FilePatch;
pub const Patch = patch_mod.Patch;

// --- colorconfig ---
pub const ColorKey = colorconfig_mod.ColorKey;
pub const ColorConfig = colorconfig_mod.ColorConfig;
pub const ColorConfigOption = colorconfig_mod.ColorConfigOption;
pub const withColor = colorconfig_mod.withColor;
pub const newColorConfig = colorconfig_mod.newColorConfig;
pub const Context = colorconfig_mod.Context;
pub const Meta = colorconfig_mod.Meta;
pub const Frag = colorconfig_mod.Frag;
pub const Old = colorconfig_mod.Old;
pub const New = colorconfig_mod.New;
pub const Commit = colorconfig_mod.Commit;
pub const Whitespace = colorconfig_mod.Whitespace;
pub const Func = colorconfig_mod.Func;
pub const OldMoved = colorconfig_mod.OldMoved;
pub const OldMovedAlternative = colorconfig_mod.OldMovedAlternative;
pub const OldMovedDimmed = colorconfig_mod.OldMovedDimmed;
pub const OldMovedAlternativeDimmed = colorconfig_mod.OldMovedAlternativeDimmed;
pub const NewMoved = colorconfig_mod.NewMoved;
pub const NewMovedAlternative = colorconfig_mod.NewMovedAlternative;
pub const NewMovedDimmed = colorconfig_mod.NewMovedDimmed;
pub const NewMovedAlternativeDimmed = colorconfig_mod.NewMovedAlternativeDimmed;
pub const ContextDimmed = colorconfig_mod.ContextDimmed;
pub const OldDimmed = colorconfig_mod.OldDimmed;
pub const NewDimmed = colorconfig_mod.NewDimmed;
pub const ContextBold = colorconfig_mod.ContextBold;
pub const OldBold = colorconfig_mod.OldBold;
pub const NewBold = colorconfig_mod.NewBold;

// --- unified encoder ---
pub const UnifiedEncoder = unified_encoder_mod.UnifiedEncoder;
pub const newUnifiedEncoder = unified_encoder_mod.newUnifiedEncoder;
pub const default_context_lines = unified_encoder_mod.default_context_lines;
pub const DefaultContextLines = unified_encoder_mod.DefaultContextLines;

test {
    _ = patch_mod;
    _ = colorconfig_mod;
    _ = unified_encoder_mod;
}
