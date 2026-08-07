//! Packfile constants + pack-ingest helpers
//! (go-git `plumbing/format/packfile/common.go`).
//!
//! Wire-format masks are `pub` for sibling modules in this package only.
//! Package root re-exports only the few values external callers need.
//!
//! `updateObjectStorage` / `writePackfileToObjectStorage` live in this file's
//! companion implementations via `parser.zig` free functions (re-exported from
//! package root) so `common.zig` stays free of a parser import cycle.

const std = @import("std");
const pack_error = @import("error.zig");

/// Pack signature bytes: `PACK`.
pub const signature = [_]u8{ 'P', 'A', 'C', 'K' };

/// Only pack version supported (go-git `VersionSupported`).
pub const VersionSupported: u32 = 2;

// Object header bit layout (go-git firstLengthBits / mask*).
pub const first_length_bits: u3 = 4;
pub const length_bits: u3 = 7;
pub const mask_first_length: u8 = 15;
pub const mask_continue: u8 = 0x80;
pub const mask_length: u8 = 127;
pub const mask_type: u8 = 112;

/// Parser prealloc hint cap (go-git `maxObjectsPrealloc`).
pub const max_objects_prealloc: usize = 1 << 16;
/// Content prealloc hint cap (go-git `maxObjectPreallocBytes`).
pub const max_object_prealloc_bytes: usize = 1 << 30;
/// Max OFS/REF delta chain depth (go-git `maxDeltaChainDepth` = 4095).
pub const max_delta_chain_depth: usize = 4095;

/// go-git `WritePackfileToObjectStorage` — copy a pack image into a raw writer.
///
/// go-git obtains the writer from `storer.PackfileWriter` (filesystem storage,
/// phase 6). This helper is the copy + empty check once a writer is available.
/// Returns `Error.EmptyPackfile` when `pack_bytes` is empty (go-git `n == 0`).
pub fn writePackfileToObjectStorage(w: *std.Io.Writer, pack_bytes: []const u8) (pack_error.Error || std.Io.Writer.Error)!void {
    if (pack_bytes.len == 0) return pack_error.Error.EmptyPackfile;
    try w.writeAll(pack_bytes);
}

test "writePackfileToObjectStorage empty returns EmptyPackfile" {
    var buf: [8]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expectError(pack_error.Error.EmptyPackfile, writePackfileToObjectStorage(&w, &.{}));
}

test "writePackfileToObjectStorage copies bytes" {
    var buf: [16]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writePackfileToObjectStorage(&w, "PACK");
    try std.testing.expectEqualSlices(u8, "PACK", w.buffered());
}
