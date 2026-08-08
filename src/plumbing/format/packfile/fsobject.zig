//! Lazy filesystem-backed pack object (go-git `packfile.FSObject`).
//!
//! The reader opens and decodes the pack only when content is requested.
//! Metadata access stays lazy.

const std = @import("std");
const plumbing = @import("plumbing");
const idxfile = @import("idxfile");
const fs_pkg = @import("fs");
const packfile_mod = @import("packfile.zig");

const Allocator = std.mem.Allocator;

/// Owned reader returned by FSObject. Closing releases decoded content.
pub const FSObjectReader = struct {
    allocator: Allocator,
    content: []u8,
    reader_state: std.Io.Reader,
    closed: bool = false,

    pub fn init(allocator: Allocator, content: []u8) FSObjectReader {
        return .{ .allocator = allocator, .content = content, .reader_state = .fixed(content) };
    }

    pub fn reader(self: *FSObjectReader) *std.Io.Reader {
        return &self.reader_state;
    }

    pub fn close(self: *FSObjectReader) void {
        if (self.closed) return;
        self.closed = true;
        self.allocator.free(self.content);
        self.content = &.{};
    }
};

pub fn FSObjectFor(comptime Fs: type) type {
    return struct {
        hash_value: plumbing.Hash,
        offset: i64,
        size_value: i64,
        object_type: plumbing.ObjectType,
        index: *idxfile.MemoryIndex,
        fs: *Fs,
        path: []const u8,

        pub fn init(
            object_hash: plumbing.Hash,
            final_type: plumbing.ObjectType,
            offset: i64,
            content_size: i64,
            index: *idxfile.MemoryIndex,
            backend: *Fs,
            path: []const u8,
        ) @This() {
            return .{
                .hash_value = object_hash,
                .offset = offset,
                .size_value = content_size,
                .object_type = final_type,
                .index = index,
                .fs = backend,
                .path = path,
            };
        }

        pub fn hash(self: *const @This()) plumbing.Hash {
            return self.hash_value;
        }

        pub fn size(self: *const @This()) i64 {
            return self.size_value;
        }

        pub fn objectType(self: *const @This()) plumbing.ObjectType {
            return self.object_type;
        }

        /// FSObject SetSize/SetType are intentional no-ops in go-git.
        pub fn setSize(_: *@This(), _: i64) void {}
        pub fn setType(_: *@This(), _: plumbing.ObjectType) void {}

        fn readContent(self: *@This(), allocator: Allocator) anyerror![]u8 {
            var file = try self.fs.open(self.path);
            defer file.close() catch {};
            var bytes: std.ArrayList(u8) = .empty;
            defer bytes.deinit(allocator);
            var buf: [16 * 1024]u8 = undefined;
            while (true) {
                const n = try file.read(&buf);
                if (n == 0) break;
                try bytes.appendSlice(allocator, buf[0..n]);
            }

            var pack: packfile_mod.Packfile = undefined;
            pack.init(allocator, self.index, bytes.items);
            defer pack.close();
            const object = try pack.getByOffset(self.offset);
            if (!object.hash().eql(self.hash_value) or object.object_type != self.object_type) {
                return error.InvalidObject;
            }
            return allocator.dupe(u8, object.readerBytes());
        }

        /// Reader-shaped go-git parity. The returned value owns decoded
        /// content; callers must call `close`.
        pub fn reader(self: *@This(), allocator: Allocator) anyerror!FSObjectReader {
            return FSObjectReader.init(allocator, try self.readContent(allocator));
        }
    };
}

pub const FSObject = FSObjectFor(fs_pkg.Mem);
pub const FSObjectOs = FSObjectFor(fs_pkg.Os);

test "FSObject metadata is stable and setters are no-ops" {
    const allocator = std.testing.allocator;
    var mem = try fs_pkg.Mem.init(allocator);
    defer mem.deinit();
    var index = idxfile.MemoryIndex.init(allocator);
    defer index.deinit();
    const expected = plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    var object = FSObject.init(expected, .blob, 12, 34, &index, &mem, "objects/pack/p.pack");
    object.setSize(99);
    object.setType(.tree);
    try std.testing.expect(object.hash().eql(expected));
    try std.testing.expectEqual(@as(i64, 34), object.size());
    try std.testing.expectEqual(plumbing.ObjectType.blob, object.objectType());
    try std.testing.expectError(error.NotExist, object.reader(allocator));
}

test "FSObjectReader releases owned content on close" {
    const allocator = std.testing.allocator;
    const content = try allocator.dupe(u8, "streamed");
    var reader = FSObjectReader.init(allocator, content);
    try std.testing.expectEqualStrings("streamed", try reader.reader().take(8));
    reader.close();
    reader.close();
}
