//! File metadata (os.FileInfo analogue).

const std = @import("std");

/// Directory entry / stat result.
///
/// # Name ownership
///
/// - **`readDir` entries:** `name` is heap-owned by the backend. Free the whole
///   slice with `fs.freeReadDir(entries)` (never free individual names alone).
/// - **`stat` / `lstat`:** `name` is always empty (`""`). Callers that need a
///   base name should keep the path they passed in and use `path.baseName`.
///   Returning a view into a temporary path buffer would dangle after return.
pub const FileInfo = struct {
    /// Base name only (like os.FileInfo.Name). Owned only for readDir entries.
    name: []const u8 = "",
    size: i64 = 0,
    /// Unix mode bits (type + perms).
    mode: u32 = 0,
    /// Modification time as Unix seconds (0 if unknown).
    mtime_sec: i64 = 0,

    pub fn isDir(self: FileInfo) bool {
        return self.mode & 0o170000 == 0o040000;
    }

    pub fn isSymlink(self: FileInfo) bool {
        return self.mode & 0o170000 == 0o120000;
    }

    pub fn isRegular(self: FileInfo) bool {
        const t = self.mode & 0o170000;
        return t == 0 or t == 0o100000;
    }
};

test "FileInfo type bits" {
    const d: FileInfo = .{ .mode = 0o040755 };
    try std.testing.expect(d.isDir());
    try std.testing.expect(!d.isSymlink());
    const f: FileInfo = .{ .mode = 0o100644 };
    try std.testing.expect(f.isRegular());
    try std.testing.expect(!f.isDir());
}
