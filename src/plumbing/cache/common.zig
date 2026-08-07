//! Shared cache size units and the Object/Buffer surface (go-git `plumbing/cache/common.go`).

const std = @import("std");

/// Size unit for cache capacity accounting (go-git `FileSize`).
pub const FileSize = i64;

/// 1 byte.
pub const Byte: FileSize = 1 << 0;
/// 1024 bytes.
pub const KiByte: FileSize = 1 << 10;
/// 1024 KiB.
pub const MiByte: FileSize = 1 << 20;
/// 1024 MiB.
pub const GiByte: FileSize = 1 << 30;

/// Default LRU capacity (go-git `DefaultMaxSize` = 96 MiB).
pub const DefaultMaxSize: FileSize = 96 * MiByte;

// Object / Buffer interfaces in go-git are method sets on cache implementations.
// Zig ports expose the same methods on `ObjectLru` / `BufferLru` directly:
//   Object: put(*MemoryObject), get(Hash) -> ?*MemoryObject, clear()
//   Buffer: put(i64, []u8), get(i64) -> ?[]u8, clear()

test "FileSize units" {
    try std.testing.expectEqual(@as(FileSize, 1), Byte);
    try std.testing.expectEqual(@as(FileSize, 1024), KiByte);
    try std.testing.expectEqual(@as(FileSize, 1024 * 1024), MiByte);
    try std.testing.expectEqual(@as(FileSize, 1024 * 1024 * 1024), GiByte);
    try std.testing.expectEqual(@as(FileSize, 96 * MiByte), DefaultMaxSize);
}
