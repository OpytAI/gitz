//! gitz — Git in Zig (full port of go-git v5.19.2).
//!
//! # Layout
//! Package paths under `src/` mirror go-git. Prefer importing leaf packages
//! (`plumbing`, `hash`, `filemode`, …) over this root for library use.
//! `//src:gitz` re-exports foundation modules for convenience and smoke tests.

const std = @import("std");

pub const name = "gitz";
pub const version = "0.0.0";
pub const go_git_pin = "v5.19.2";

pub const plumbing = @import("plumbing");
pub const hash = @import("hash");
pub const filemode = @import("filemode");
pub const color = @import("color");
pub const binary = @import("binary");
/// Free lists (go-git `utils/sync`). Imported as `utils/sync` in leaf code.
pub const sync = @import("utils/sync");
pub const ioutil = @import("ioutil");
pub const trace = @import("trace");

// Phase 2 leaf codecs.
pub const pktline = @import("pktline");
pub const objfile = @import("objfile");
pub const config_format = @import("config");
pub const idxfile = @import("idxfile");

// Phase 3 packfile read.
pub const packfile = @import("packfile");

// Phase 4 storer + cache + storage/memory.
pub const storer = @import("storer");
pub const cache = @import("cache");
pub const storage = @import("storage");
/// In-memory storage backend (go-git `storage/memory`). Import name from package.
pub const memory_storage = @import("memory");

test "identity" {
    try std.testing.expectEqualStrings("gitz", name);
    try std.testing.expectEqualStrings("v5.19.2", go_git_pin);
}

test "phase1 foundation surface" {
    try std.testing.expect(plumbing.ZeroHash.isZero());
    try std.testing.expectEqual(@as(usize, 20), hash.Size);
    try std.testing.expectEqual(@as(filemode.FileMode, 0o100644), filemode.Regular);
    try std.testing.expect(std.mem.startsWith(u8, color.Reset, "\x1b"));
    try std.testing.expect(binary.ErrIntegerOverflow == binary.Error.IntegerOverflow);
    try std.testing.expectEqual(@as(usize, 16 * 1024), sync.byte_slice_len);
    var empty = ioutil.newReaderFromBuf(&.{});
    try std.testing.expectError(error.EmptyReader, ioutil.nonEmptyReader(&empty));
    try std.testing.expect(!trace.enabled(trace.general));
}

test "phase2 leaf codec surface" {
    try std.testing.expectEqual(@as(usize, 65516), pktline.MaxPayloadSize);
    try std.testing.expectEqual(@as(u32, 2), idxfile.VersionSupported);
    _ = objfile.Reader.open;
    _ = objfile.Writer.open;
    _ = config_format.Config.init;
}

test "phase3 packfile read surface" {
    try std.testing.expectEqual(@as(u32, 2), packfile.VersionSupported);
    try std.testing.expectEqualSlices(u8, "PACK", &packfile.signature);
    _ = packfile.Scanner.init;
    _ = packfile.Parser.init;
    _ = packfile.Packfile.init;
    _ = packfile.patchDelta;
    _ = packfile.applyDelta;
}

test "phase4 storer memory cache surface" {
    try std.testing.expectEqual(@as(usize, 1024), storer.MaxResolveRecursion);
    try std.testing.expect(storer.Error.Stop == storer.Error.Stop);
    try std.testing.expect(storage.Error.ReferenceHasChanged == storage.Error.ReferenceHasChanged);
    try std.testing.expectEqual(cache.DefaultMaxSize, @as(cache.FileSize, 96 * cache.MiByte));
    _ = cache.ObjectLru.initDefault;
    _ = cache.BufferLru.initDefault;
    _ = memory_storage.Storage.init;
    _ = storer.resolveReference;
    _ = storer.newEncodedObjectSliceIter;
    _ = storer.newReferenceSliceIter;
}
