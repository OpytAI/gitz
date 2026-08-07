//! Git file view over a blob (go-git `plumbing/object/file.go`).
//!
//! `FileIter` lives on `Tree` (`tree.zig`) and walks recursively.
//!
//! Pin: go-git v5.19.2.

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");

const blob_mod = @import("blob.zig");

const Allocator = std.mem.Allocator;
const Blob = blob_mod.Blob;
const FileMode = filemode.FileMode;

/// Sniff length for binary detection (go-git `utils/binary` `sniffLen`).
const sniff_len: usize = 8000;

/// A path + mode + blob (go-git `File`).
///
/// Embeds `Blob` fields via `blob` (go-git embeds `Blob` anonymously).
/// `name` is borrowed (caller owns the path string).
pub const File = struct {
    /// Path relative to a tree (go-git `Name`).
    name: []const u8 = "",
    /// Entry mode (go-git `Mode`).
    mode: FileMode = filemode.Empty,
    /// File content blob (go-git embedded `Blob`).
    blob: Blob = .{},

    /// go-git `NewFile`.
    pub fn init(name: []const u8, m: FileMode, b: *const Blob) File {
        return .{
            .name = name,
            .mode = m,
            .blob = b.*,
        };
    }

    /// Owned content copy (go-git `(*File).Contents`). Caller frees with `allocator`.
    pub fn contents(self: *const File, allocator: Allocator) Allocator.Error![]u8 {
        return try allocator.dupe(u8, self.blob.readerBytes());
    }

    /// True when a NUL byte appears in the first `sniff_len` content bytes.
    /// go-git `(*File).IsBinary` via `utils/binary.IsBinary`.
    pub fn isBinary(self: *const File) bool {
        return isBinaryBytes(self.blob.readerBytes());
    }

    /// Lines without end-of-line characters; trailing empty line stripped.
    /// go-git `(*File).Lines`.
    ///
    /// Caller frees each line string and the outer slice with `allocator`.
    pub fn lines(self: *const File, allocator: Allocator) Allocator.Error![]const []const u8 {
        const content = try self.contents(allocator);
        defer allocator.free(content);

        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |line| allocator.free(line);
            list.deinit(allocator);
        }

        if (content.len == 0) {
            // strings.Split("", "\n") → [""] → strip trailing empty → [].
            return try list.toOwnedSlice(allocator);
        }

        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |part| {
            try list.append(allocator, try allocator.dupe(u8, part));
        }

        if (list.items.len > 0 and list.items[list.items.len - 1].len == 0) {
            const last = list.pop().?;
            allocator.free(last);
        }

        return try list.toOwnedSlice(allocator);
    }
};

/// Free-function constructor (go-git `NewFile`).
pub fn newFile(name: []const u8, m: FileMode, b: *const Blob) File {
    return File.init(name, m, b);
}

/// go-git `utils/binary.IsBinary` over an in-memory slice.
pub fn isBinaryBytes(data: []const u8) bool {
    const n = @min(data.len, sniff_len);
    return std.mem.indexOfScalar(u8, data[0..n], 0) != null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "newFile fields" {
    const gpa = std.testing.allocator;
    var o = plumbing.MemoryObject.init(gpa);
    defer o.deinit();
    o.setType(.blob);
    _ = try o.write("hi");

    var blob: Blob = .{};
    try blob.decode(&o);

    const f = newFile("path/to/file", filemode.Regular, &blob);
    try std.testing.expectEqualStrings("path/to/file", f.name);
    try std.testing.expectEqual(filemode.Regular, f.mode);
    try std.testing.expectEqual(@as(i64, 2), f.blob.size);
    try std.testing.expectEqualStrings("hi", f.blob.readerBytes());
}

test "File contents" {
    const gpa = std.testing.allocator;
    var o = plumbing.MemoryObject.init(gpa);
    defer o.deinit();
    o.setType(.blob);
    _ = try o.write("hello\nworld\n");

    var blob: Blob = .{};
    try blob.decode(&o);
    const f = newFile("f", filemode.Regular, &blob);

    const c = try f.contents(gpa);
    defer gpa.free(c);
    try std.testing.expectEqualStrings("hello\nworld\n", c);
}

test "File lines strips trailing empty" {
    const gpa = std.testing.allocator;
    var o = plumbing.MemoryObject.init(gpa);
    defer o.deinit();
    o.setType(.blob);
    _ = try o.write("a\nb\n");

    var blob: Blob = .{};
    try blob.decode(&o);
    const f = newFile("f", filemode.Regular, &blob);

    const ls = try f.lines(gpa);
    defer {
        for (ls) |line| gpa.free(line);
        gpa.free(ls);
    }
    try std.testing.expectEqual(@as(usize, 2), ls.len);
    try std.testing.expectEqualStrings("a", ls[0]);
    try std.testing.expectEqualStrings("b", ls[1]);
}

test "File lines empty content" {
    const gpa = std.testing.allocator;
    var o = plumbing.MemoryObject.init(gpa);
    defer o.deinit();
    o.setType(.blob);
    _ = try o.write("");

    var blob: Blob = .{};
    try blob.decode(&o);
    const f = newFile("f", filemode.Regular, &blob);

    const ls = try f.lines(gpa);
    defer gpa.free(ls);
    try std.testing.expectEqual(@as(usize, 0), ls.len);
}

test "File isBinary" {
    const gpa = std.testing.allocator;

    {
        var o = plumbing.MemoryObject.init(gpa);
        defer o.deinit();
        o.setType(.blob);
        _ = try o.write("text\nonly\n");
        var blob: Blob = .{};
        try blob.decode(&o);
        const f = newFile("t", filemode.Regular, &blob);
        try std.testing.expect(!f.isBinary());
    }
    {
        var o = plumbing.MemoryObject.init(gpa);
        defer o.deinit();
        o.setType(.blob);
        _ = try o.write(&[_]u8{ 'a', 0, 'b' });
        var blob: Blob = .{};
        try blob.decode(&o);
        const f = newFile("b", filemode.Regular, &blob);
        try std.testing.expect(f.isBinary());
    }
}

test "isBinaryBytes sniff length" {
    // No NUL in first 8000 → not binary even if a later byte is NUL.
    var buf: [sniff_len + 1]u8 = undefined;
    @memset(buf[0..sniff_len], 'x');
    buf[sniff_len] = 0;
    try std.testing.expect(!isBinaryBytes(buf[0 .. sniff_len + 1]));

    buf[sniff_len - 1] = 0;
    try std.testing.expect(isBinaryBytes(buf[0..sniff_len]));
}
