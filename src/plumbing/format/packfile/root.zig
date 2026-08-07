//! Package packfile — Git packfile **read** path.
//!
//! Port of go-git v5.19.2 `plumbing/format/packfile` (scanner, delta apply,
//! parser, Packfile+idx random access). Encoder / write path is phase 5.
//!
//! # Construction
//!
//! | Need | Constructor |
//! |------|-------------|
//! | Sequential stream (non-seekable) | `Scanner.init` |
//! | Memory pack image (seek + CRC/SHA-1) | `Scanner.initSeekable` |
//! | Random Get by hash/offset | `Packfile.init` (always seekable) |
//!
//! Prefer `initSeekable` whenever the full pack image is in memory. Pack
//! trailer verification is reliable on the seekable path; use it for fixtures
//! and random access.

const std = @import("std");

const error_mod = @import("error.zig");
const common_mod = @import("common.zig");
const scanner_mod = @import("scanner.zig");
const patch_delta_mod = @import("patch_delta.zig");
const parser_mod = @import("parser.zig");
const packfile_mod = @import("packfile.zig");

pub const Error = error_mod.Error;

pub const signature = common_mod.signature;
pub const VersionSupported = common_mod.VersionSupported;
pub const max_delta_chain_depth = common_mod.max_delta_chain_depth;

pub const Scanner = scanner_mod.Scanner;
pub const ObjectHeader = scanner_mod.ObjectHeader;

pub const patchDelta = patch_delta_mod.patchDelta;
pub const applyDelta = patch_delta_mod.applyDelta;
pub const readerFromDelta = patch_delta_mod.readerFromDelta;
pub const applyDeltaFromReader = patch_delta_mod.applyDeltaFromReader;

pub const Parser = parser_mod.Parser;
pub const Observer = parser_mod.Observer;
pub const ObjectStore = parser_mod.ObjectStore;

pub const Packfile = packfile_mod.Packfile;
pub const ObjectIterator = packfile_mod.ObjectIterator;

test {
    _ = @import("error.zig");
    _ = @import("common.zig");
    _ = @import("scanner.zig");
    _ = @import("patch_delta.zig");
    _ = @import("parser.zig");
    _ = @import("packfile.zig");
    _ = @import("basic_pack.zig");
    _ = @import("ref_delta_pack.zig");
    _ = @import("ref_delta_idx.zig");
    _ = @import("delta_before_base_pack.zig");
    _ = @import("thinpack_pack.zig");
    _ = @import("codecommit_pack.zig");
    _ = @import("thin_pack_tests.zig");
}

test "basic and ref-delta pack headers" {
    {
        var sc = Scanner.initSeekable(@import("basic_pack.zig").data());
        const version, const objects = try sc.header();
        try std.testing.expectEqual(VersionSupported, version);
        try std.testing.expectEqual(@as(u32, 31), objects);
    }
    {
        var sc = Scanner.initSeekable(@import("ref_delta_pack.zig").data());
        const version, const objects = try sc.header();
        try std.testing.expectEqual(VersionSupported, version);
        try std.testing.expectEqual(@as(u32, 31), objects);
    }
    try std.testing.expectEqualSlices(u8, "PACK", &signature);
}
