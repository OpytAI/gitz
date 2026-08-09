//! Versioned opaque image for a memory storer plus `fs.Mem` worktree.
//!
//! The image owns Git objects, refs, shallow state, index bytes (including
//! sparse flags), local config, nested module storers, and filesystem entries.

const std = @import("std");
const fs = @import("fs");
const index = @import("index");
const memory = @import("memory");
const plumbing = @import("plumbing");

const Allocator = std.mem.Allocator;
const magic = "GITZIMG1";
const version: u32 = 1;

pub const Restored = struct {
    store: *memory.Storage,
    filesystem: fs.Mem,

    pub fn deinit(self: *Restored, allocator: Allocator) void {
        self.filesystem.deinit();
        self.store.deinit();
        allocator.destroy(self.store);
        self.* = undefined;
    }
};

pub fn exportImage(
    allocator: Allocator,
    store: *memory.Storage,
    filesystem: *fs.Mem,
) ![]u8 {
    var writer = ImageWriter.init(allocator);
    errdefer writer.deinit();
    try writer.raw(magic);
    try writer.int(u32, version);
    try writeStorage(&writer, store);
    try writeFilesystem(&writer, filesystem);
    return writer.finish();
}

pub fn restoreImage(
    allocator: Allocator,
    clock: memory.Clock,
    bytes: []const u8,
) !Restored {
    var reader = ImageReader.init(bytes);
    if (!std.mem.eql(u8, try reader.raw(magic.len), magic)) return error.InvalidImage;
    if (try reader.int(u32) != version) return error.UnsupportedImageVersion;

    const store = try memory.newStorageWithClock(allocator, clock);
    errdefer {
        store.deinit();
        allocator.destroy(store);
    }
    try readStorage(&reader, store);

    var filesystem = try fs.Mem.init(allocator);
    errdefer filesystem.deinit();
    try readFilesystem(&reader, &filesystem);
    if (!reader.done()) return error.InvalidImage;
    return .{ .store = store, .filesystem = filesystem };
}

fn writeStorage(writer: *ImageWriter, store: *memory.Storage) !void {
    try writer.byte(@intFromEnum(store.hashAlgo()));

    var objects = try store.iterEncodedObjects(.any);
    defer objects.deinit();
    var object_list: std.ArrayList(*plumbing.MemoryObject) = .empty;
    defer object_list.deinit(writer.allocator);
    while (objects.next()) |obj| try object_list.append(writer.allocator, obj) else |err| switch (err) {
        error.EndOfStream => {},
    }
    try writer.int(u32, @intCast(object_list.items.len));
    for (object_list.items) |obj| {
        try writer.byte(@bitCast(@as(i8, @intFromEnum(obj.object_type))));
        try writer.bytes(obj.readerBytes());
    }

    var refs = try store.iterReferences();
    defer refs.deinit();
    var ref_list: std.ArrayList(plumbing.Reference) = .empty;
    defer ref_list.deinit(writer.allocator);
    while (refs.next()) |ref| try ref_list.append(writer.allocator, ref) else |err| switch (err) {
        error.EndOfStream => {},
    }
    try writer.int(u32, @intCast(ref_list.items.len));
    for (ref_list.items) |ref| {
        try writer.byte(@bitCast(@as(i8, @intFromEnum(ref.type))));
        try writer.bytes(ref.name.raw);
        switch (ref.type) {
            .hash => try writer.bytes(ref.hash.slice()),
            .symbolic => try writer.bytes(ref.target.raw),
            .invalid => try writer.bytes(&.{}),
        }
    }

    const shallow = store.shallow();
    try writer.int(u32, @intCast(shallow.len));
    for (shallow) |hash| try writer.bytes(hash.slice());

    const idx = try store.index();
    var index_writer: std.Io.Writer.Allocating = .init(writer.allocator);
    defer index_writer.deinit();
    var encoder = index.Encoder.init(&index_writer.writer);
    try encoder.encode(idx);
    try writer.bytes(index_writer.written());

    try writeConfig(writer, try store.config());

    try writer.int(u32, @intCast(store.module_storage.modules.count()));
    var modules = store.module_storage.modules.iterator();
    while (modules.next()) |entry| {
        try writer.bytes(entry.key_ptr.*);
        try writeStorage(writer, entry.value_ptr.*);
    }
}

fn readStorage(reader: *ImageReader, store: *memory.Storage) !void {
    const algo: plumbing.Algorithm = @enumFromInt(try reader.byte());
    store.setHashAlgo(algo);

    const object_count = try reader.int(u32);
    for (0..object_count) |_| {
        const object_type: plumbing.ObjectType = @enumFromInt(@as(i8, @bitCast(try reader.byte())));
        const content = try reader.bytes();
        const obj = try store.newEncodedObject();
        errdefer {
            obj.deinit();
            store.allocator.destroy(obj);
        }
        obj.setType(object_type);
        try obj.setContent(content);
        _ = try store.setEncodedObject(obj);
    }

    const ref_count = try reader.int(u32);
    for (0..ref_count) |_| {
        const ref_type: plumbing.ReferenceType = @enumFromInt(@as(i8, @bitCast(try reader.byte())));
        const name = try reader.bytes();
        const value = try reader.bytes();
        const ref = switch (ref_type) {
            .hash => plumbing.Reference.newHashReference(
                plumbing.ReferenceName.init(name),
                plumbing.Hash.fromBytes(value),
            ),
            .symbolic => plumbing.Reference.newSymbolicReference(
                plumbing.ReferenceName.init(name),
                plumbing.ReferenceName.init(value),
            ),
            .invalid => plumbing.Reference{},
        };
        try store.setReference(ref);
    }

    const shallow_count = try reader.int(u32);
    const shallows = try store.allocator.alloc(plumbing.Hash, shallow_count);
    defer store.allocator.free(shallows);
    for (shallows) |*hash| hash.* = plumbing.Hash.fromBytes(try reader.bytes());
    try store.setShallow(shallows);

    const index_bytes = try reader.bytes();
    var index_reader = std.Io.Reader.fixed(index_bytes);
    var decoder = index.Decoder.init(&index_reader);
    const idx = try store.allocator.create(memory.Index);
    errdefer store.allocator.destroy(idx);
    idx.* = memory.Index.init(store.allocator);
    errdefer idx.deinit();
    try decoder.decode(idx);
    store.setIndex(idx);

    try readConfig(reader, try store.config());

    const module_count = try reader.int(u32);
    for (0..module_count) |_| {
        const name = try reader.bytes();
        try readStorage(reader, try store.module(name));
    }
}

fn writeConfig(writer: *ImageWriter, config: *const memory.Config) !void {
    try writer.byte(@intFromBool(config.is_bare));
    inline for (.{
        "repository_format_version",
        "object_format",
        "user_name",
        "user_email",
        "author_name",
        "author_email",
        "committer_name",
        "committer_email",
    }) |field| try writer.bytes(@field(config, field));

    try writer.int(u32, @intCast(config.remotes.count()));
    var remotes = config.remotes.iterator();
    while (remotes.next()) |entry| {
        const remote = entry.value_ptr.*;
        try writer.bytes(remote.name);
        try writer.int(u32, @intCast(remote.urls.len));
        for (remote.urls) |url| try writer.bytes(url);
        try writer.int(u32, @intCast(remote.fetch.len));
        for (remote.fetch) |spec| try writer.bytes(spec);
        try writer.byte(@intFromBool(remote.mirror));
    }

    try writer.int(u32, @intCast(config.branches.count()));
    var branches = config.branches.iterator();
    while (branches.next()) |entry| {
        const branch = entry.value_ptr.*;
        try writer.bytes(branch.name);
        try writer.bytes(branch.remote);
        try writer.bytes(branch.merge);
    }

    try writer.int(u32, @intCast(config.submodules.count()));
    var submodules = config.submodules.iterator();
    while (submodules.next()) |entry| {
        const module = entry.value_ptr.*;
        try writer.bytes(module.name);
        try writer.bytes(module.path);
        try writer.bytes(module.url);
        try writer.bytes(module.branch);
    }
}

fn readConfig(reader: *ImageReader, config: *memory.Config) !void {
    config.is_bare = try reader.byte() != 0;
    try config.setRepositoryFormatVersion(try reader.bytes());
    try config.setObjectFormat(try reader.bytes());
    try config.setUser(try reader.bytes(), try reader.bytes());
    try config.setAuthor(try reader.bytes(), try reader.bytes());
    try config.setCommitter(try reader.bytes(), try reader.bytes());

    const remote_count = try reader.int(u32);
    for (0..remote_count) |_| {
        const name = try reader.bytes();
        const url_count = try reader.int(u32);
        const urls = try config.allocator.alloc([]const u8, url_count);
        defer config.allocator.free(urls);
        for (urls) |*url| url.* = try reader.bytes();
        const fetch_count = try reader.int(u32);
        const fetch = try config.allocator.alloc([]const u8, fetch_count);
        defer config.allocator.free(fetch);
        for (fetch) |*spec| spec.* = try reader.bytes();
        const mirror = try reader.byte() != 0;
        try config.putRemoteFull(name, urls, fetch, mirror);
    }

    const branch_count = try reader.int(u32);
    for (0..branch_count) |_| {
        try config.putBranch(try reader.bytes(), try reader.bytes(), try reader.bytes());
    }
    const submodule_count = try reader.int(u32);
    for (0..submodule_count) |_| {
        try config.putSubmodule(
            try reader.bytes(),
            try reader.bytes(),
            try reader.bytes(),
            try reader.bytes(),
        );
    }
}

fn writeFilesystem(writer: *ImageWriter, filesystem: *fs.Mem) !void {
    var records: std.ArrayList(FsRecord) = .empty;
    defer {
        for (records.items) |record| writer.allocator.free(record.path);
        records.deinit(writer.allocator);
    }
    try collectFilesystem(writer.allocator, filesystem, "", &records);
    try writer.int(u32, @intCast(records.items.len));
    for (records.items) |record| {
        const info = try filesystem.lstat(record.path);
        try writer.bytes(record.path);
        try writer.int(u32, info.mode);
        try writer.int(i64, info.atime_sec);
        try writer.int(i64, info.mtime_sec);
        try writer.int(i64, info.uid);
        try writer.int(i64, info.gid);
        const kind = info.mode & 0o170000;
        if (kind == fs.Mode.dir_flag) {
            try writer.bytes(&.{});
        } else if (kind == fs.Mode.symlink_flag) {
            const target = try filesystem.readlink(record.path);
            defer writer.allocator.free(target);
            try writer.bytes(target);
        } else {
            const content = try readFile(writer.allocator, filesystem, record.path);
            defer writer.allocator.free(content);
            try writer.bytes(content);
        }
    }
}

const FsRecord = struct { path: []u8 };

fn collectFilesystem(
    allocator: Allocator,
    filesystem: *fs.Mem,
    dir: []const u8,
    records: *std.ArrayList(FsRecord),
) !void {
    const entries = try filesystem.readDir(if (dir.len == 0) "." else dir);
    defer filesystem.freeReadDir(entries);
    for (entries) |entry| {
        const path = if (dir.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, entry.name });
        errdefer allocator.free(path);
        try records.append(allocator, .{ .path = path });
        if (entry.mode & 0o170000 == fs.Mode.dir_flag) {
            try collectFilesystem(allocator, filesystem, path, records);
        }
    }
}

fn readFilesystem(reader: *ImageReader, filesystem: *fs.Mem) !void {
    const count = try reader.int(u32);
    for (0..count) |_| {
        const path = try reader.bytes();
        const mode = try reader.int(u32);
        const atime = try reader.int(i64);
        const mtime = try reader.int(i64);
        const uid = try reader.int(i64);
        const gid = try reader.int(i64);
        const content = try reader.bytes();
        const kind = mode & 0o170000;
        if (kind == fs.Mode.dir_flag) {
            try filesystem.mkdirAll(path, mode);
        } else if (kind == fs.Mode.symlink_flag) {
            try filesystem.symlink(content, path);
        } else {
            var file = try filesystem.create(path);
            defer file.close() catch {};
            _ = try file.write(content);
        }
        try filesystem.chmod(path, mode);
        try filesystem.lchown(path, uid, gid);
        try filesystem.chtimes(path, atime, mtime);
    }
}

fn readFile(allocator: Allocator, filesystem: *fs.Mem, path: []const u8) ![]u8 {
    var file = try filesystem.open(path);
    defer file.close() catch {};
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = try file.read(&buffer);
        if (count == 0) break;
        try bytes.appendSlice(allocator, buffer[0..count]);
    }
    return bytes.toOwnedSlice(allocator);
}

const ImageWriter = struct {
    allocator: Allocator,
    bytes_list: std.ArrayList(u8) = .empty,

    fn init(allocator: Allocator) ImageWriter {
        return .{ .allocator = allocator };
    }
    fn deinit(self: *ImageWriter) void {
        self.bytes_list.deinit(self.allocator);
    }
    fn raw(self: *ImageWriter, value: []const u8) !void {
        try self.bytes_list.appendSlice(self.allocator, value);
    }
    fn byte(self: *ImageWriter, value: u8) !void {
        try self.bytes_list.append(self.allocator, value);
    }
    fn int(self: *ImageWriter, comptime T: type, value: T) !void {
        var buffer: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &buffer, value, .little);
        try self.raw(&buffer);
    }
    fn bytes(self: *ImageWriter, value: []const u8) !void {
        try self.int(u32, @intCast(value.len));
        try self.raw(value);
    }
    fn finish(self: *ImageWriter) ![]u8 {
        return self.bytes_list.toOwnedSlice(self.allocator);
    }
};

const ImageReader = struct {
    image: []const u8,
    offset: usize = 0,

    fn init(image: []const u8) ImageReader {
        return .{ .image = image };
    }
    fn raw(self: *ImageReader, length: usize) ![]const u8 {
        if (length > self.image.len -| self.offset) return error.InvalidImage;
        const result = self.image[self.offset .. self.offset + length];
        self.offset += length;
        return result;
    }
    fn byte(self: *ImageReader) !u8 {
        return (try self.raw(1))[0];
    }
    fn int(self: *ImageReader, comptime T: type) !T {
        const value = try self.raw(@sizeOf(T));
        const array: *const [@sizeOf(T)]u8 = @ptrCast(value.ptr);
        return std.mem.readInt(T, array, .little);
    }
    fn bytes(self: *ImageReader) ![]const u8 {
        return self.raw(try self.int(u32));
    }
    fn done(self: *const ImageReader) bool {
        return self.offset == self.image.len;
    }
};

test "empty image round trip" {
    const allocator = std.testing.allocator;
    const store = try memory.newStorageWithClock(allocator, memory.Clock.fixedClock(.{}));
    defer {
        store.deinit();
        allocator.destroy(store);
    }
    var filesystem = try fs.Mem.init(allocator);
    defer filesystem.deinit();
    const image = try exportImage(allocator, store, &filesystem);
    defer allocator.free(image);
    var restored = try restoreImage(allocator, memory.Clock.fixedClock(.{}), image);
    defer restored.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), restored.store.countLooseRefs());
}
