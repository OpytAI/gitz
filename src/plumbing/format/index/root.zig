//! plumbing/format/index — Git index (dircache) codec (go-git `plumbing/format/index`).
//!
//! Types (`Index`, `Entry`, extensions), path match/glob, and binary encode/decode
//! for versions 2–4.
//!
//! # go-git test map (package slice)
//!
//! | go-git | Zig |
//! |--------|-----|
//! | IndexSuite.TestIndexAdd/Entry/Remove/Glob | `index.zig` |
//! | match.go | `match.zig` |
//! | decoder_test.go | `decoder.zig` |
//! | encoder_test.go | `encoder.zig` |

const error_mod = @import("error.zig");
const index_mod = @import("index.zig");
const match_mod = @import("match.zig");
const decoder_mod = @import("decoder.zig");
const encoder_mod = @import("encoder.zig");

// --- Errors ---
pub const Error = error_mod.Error;

// --- Match ---
pub const match = match_mod.match;

// --- Stage ---
pub const Stage = index_mod.Stage;
pub const Merged = index_mod.Merged;
pub const AncestorMode = index_mod.AncestorMode;
pub const OurMode = index_mod.OurMode;
pub const TheirMode = index_mod.TheirMode;

// --- Time ---
pub const Time = index_mod.Time;

// --- Core types ---
pub const Entry = index_mod.Entry;
pub const Index = index_mod.Index;
pub const Tree = index_mod.Tree;
pub const TreeEntry = index_mod.TreeEntry;
pub const ResolveUndo = index_mod.ResolveUndo;
pub const ResolveUndoEntry = index_mod.ResolveUndoEntry;
pub const EndOfIndexEntry = index_mod.EndOfIndexEntry;

// --- Extension signatures ---
pub const index_signature = index_mod.index_signature;
pub const tree_ext_signature = index_mod.tree_ext_signature;
pub const resolve_undo_ext_signature = index_mod.resolve_undo_ext_signature;
pub const end_of_index_entry_ext_signature = index_mod.end_of_index_entry_ext_signature;

// --- Re-exports used by callers ---
pub const Hash = index_mod.Hash;
pub const FileMode = index_mod.FileMode;

// --- Decoder / Encoder ---
pub const Decoder = decoder_mod.Decoder;
pub const DecodeVersionSupported = decoder_mod.DecodeVersionSupported;
pub const Encoder = encoder_mod.Encoder;
/// go-git `EncodeVersionSupported` (max version the encoder writes).
pub const EncodeVersionSupported = encoder_mod.encode_version_supported;

test {
    _ = error_mod;
    _ = index_mod;
    _ = match_mod;
    _ = decoder_mod;
    _ = encoder_mod;
}
