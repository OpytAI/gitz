//! plumbing/format/index — Git index (dircache) codec (go-git `plumbing/format/index`).
//!
//! Types (`Index`, `Entry`, extensions), path match/glob, and binary encode/decode
//! for versions 2–4 (go-git pin v5.19.2).
//!
//! # go-git test map (package slice)
//!
//! | go-git | Zig |
//! |--------|-----|
//! | IndexSuite.TestIndexAdd | `index.zig` `TestIndexAdd` |
//! | IndexSuite.TestIndexEntry | `index.zig` `TestIndexEntry` |
//! | IndexSuite.TestIndexRemove | `index.zig` `TestIndexRemove` |
//! | IndexSuite.TestIndexGlob | `index.zig` `TestIndexGlob` (+ `match.zig`) |
//! | match.go (filepath.Match subset) | `match.zig` |
//! | IndexSuite.TestDecode | `decoder.zig` `IndexSuite.TestDecode` |
//! | IndexSuite.TestDecodeEntries | `decoder.zig` `IndexSuite.TestDecodeEntries` |
//! | IndexSuite.TestDecodeCacheTree | `decoder.zig` `IndexSuite.TestDecodeCacheTree` |
//! | TestTreeExtensionInvalidatedEntry | `decoder.zig` `TestTreeExtensionInvalidatedEntry` |
//! | IndexSuite.TestDecodeMergeConflict | `decoder.zig` `IndexSuite.TestDecodeMergeConflict` |
//! | IndexSuite.TestDecodeExtendedV3 | `decoder.zig` `IndexSuite.TestDecodeExtendedV3` |
//! | IndexSuite.TestDecodeResolveUndo | `decoder.zig` `IndexSuite.TestDecodeResolveUndo` |
//! | IndexSuite.TestDecodeV4 | `decoder.zig` `IndexSuite.TestDecodeV4` |
//! | IndexSuite.TestDecodeEndOfIndexEntry | `decoder.zig` `IndexSuite.TestDecodeEndOfIndexEntry` |
//! | IndexSuite.TestDecodeUnknownOptionalExt | `decoder.zig` `IndexSuite.TestDecodeUnknownOptionalExt` |
//! | IndexSuite.TestDecodeUnknownMandatoryExt | `decoder.zig` `IndexSuite.TestDecodeUnknownMandatoryExt` |
//! | IndexSuite.TestDecodeTruncatedExt | `decoder.zig` `IndexSuite.TestDecodeTruncatedExt` |
//! | IndexSuite.TestDecodeInvalidHash | `decoder.zig` `IndexSuite.TestDecodeInvalidHash` |
//! | (ErrMalformedSignature path) | `decoder.zig` `IndexSuite.TestDecodeMalformedSignature` |
//! | (ErrUnsupportedVersion path) | `decoder.zig` `IndexSuite.TestDecodeUnsupportedVersion` |
//! | TestDecodeV4StripLength | `decoder.zig` `TestDecodeV4StripLength` |
//! | TestDecodeNameLength0xFFF | `decoder.zig` `TestDecodeNameLength0xFFF` (+ long then short) |
//! | TestDecodeNameLength0xFFFPatchedFlags | `decoder.zig` `TestDecodeNameLength0xFFFPatchedFlags` |
//! | TestDecodeAllIndexFixtures | `decoder.zig` `TestDecodeAllIndexFixtures` + `fixtures.zig` |
//! | IndexSuite.TestEncode | `encoder.zig` `IndexSuite.TestEncode` |
//! | TestEncodeLongName | `encoder.zig` `TestEncodeLongName` |
//! | TestEncodeV4 | `encoder.zig` `TestEncodeV4` |
//! | IndexSuite.TestEncodeUnsupportedVersion | `encoder.zig` `IndexSuite.TestEncodeUnsupportedVersion` |
//! | IndexSuite.TestEncodeWithIntentToAddUnsupportedVersion | `encoder.zig` `IndexSuite.TestEncodeWithIntentToAdd` (v3 success; go-git name is misleading) |
//! | IndexSuite.TestEncodeWithSkipWorktreeUnsupportedVersion | `encoder.zig` `IndexSuite.TestEncodeWithSkipWorktree` (v3 success; go-git name is misleading) |
//!
//! # Fixtures (package-private)
//!
//! `fixtures.zig` is **test-only** and is not re-exported from this root. Unit
//! tests pull it in via `@import("fixtures.zig")` (see the package `test` block
//! below and `decoder.zig`). Embedded images cover versions {2, 3, 4} as the
//! go-git `TestDecodeAllIndexFixtures` want map (rules_zig `.zig`-only srcs; no
//! runfiles). Human-owned hex/binaries live under `data/fixtures/index/`.
//! Regenerate only through the Bazel graph:
//! `bazel run //tools:gen_index_fixtures` and
//! `bazel test //tools:gen_index_fixtures_test` (rules_python hermetic CPython).
//!
//! # Version support (go-git names)
//!
//! - `DecodeVersionSupported` — `{ min = 2, max = 4 }` (go-git `Min`/`Max`)
//! - `EncodeVersionSupported` — `4` (max version the encoder accepts; go-git
//!   `EncodeVersionSupported uint32 = 4`)

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
/// go-git `DecodeVersionSupported` — supported decode versions Min=2, Max=4.
pub const DecodeVersionSupported = decoder_mod.DecodeVersionSupported;
pub const Encoder = encoder_mod.Encoder;
/// go-git `EncodeVersionSupported` — max index version the encoder accepts (`4`).
pub const EncodeVersionSupported = encoder_mod.EncodeVersionSupported;

test {
    _ = error_mod;
    _ = index_mod;
    _ = match_mod;
    _ = decoder_mod;
    _ = encoder_mod;
    // fixtures.zig is package-private (test-only); pull in its tests without re-export.
    _ = @import("fixtures.zig");
}
