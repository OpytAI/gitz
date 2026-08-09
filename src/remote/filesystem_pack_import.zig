//! Native filesystem pack import.
//!
//! Keep this adapter separate from `remote`. Browser artifacts use the memory
//! importer and must not acquire a filesystem dependency through that package.

const std = @import("std");
const plumbing = @import("plumbing");
const packfile = @import("packfile");
const memory = @import("memory");
const filesystem = @import("filesystem");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;

pub const PackImportResult = struct {
    checksum: Hash,
    object_count: usize,
    reference_count: usize,
};

/// Stage decoded objects in memory. Validate every ref before object
/// persistence. Then publish refs as one rollback-capable set. An object write
/// failure leaves all refs unchanged. Unreachable loose objects can remain
/// after an I/O failure, as in native Git receive-pack.
pub fn FilesystemPackImportSessionFor(comptime Fs: type) type {
    const Storage = filesystem.StorageFor(Fs);
    return struct {
        const Self = @This();

        allocator: Allocator,
        destination: *Storage,
        input: packfile.ImportSession,
        staging: memory.ObjectStorage,

        pub fn init(
            allocator: Allocator,
            destination: *Storage,
            limits: packfile.ImportLimits,
        ) Self {
            destination.activateFormat();
            return .{
                .allocator = allocator,
                .destination = destination,
                .input = packfile.ImportSession.init(allocator, limits),
                .staging = memory.ObjectStorage.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.staging.deinit();
            self.input.deinit();
            self.* = undefined;
        }

        pub fn write(self: *Self, chunk: []const u8) !void {
            return self.input.write(chunk);
        }

        pub fn finish(
            self: *Self,
            updates: []const memory.ReferenceUpdate,
        ) !PackImportResult {
            var prepared = try self.destination.prepareReferenceUpdates(updates);
            defer prepared.deinit();

            var target = FilesystemImportTarget(Fs){
                .allocator = self.allocator,
                .base = self.destination,
                .staging = &self.staging,
            };
            const sink = packfile.EncodedObjectStore.from(FilesystemImportTarget(Fs), &target);
            const checksum = try self.input.finish(sink);
            const object_count = self.staging.count();

            var objects = try self.staging.iterEncodedObjects(.any);
            defer objects.deinit();
            while (objects.next()) |obj| {
                _ = try self.destination.setEncodedObject(obj);
            } else |err| if (err != error.EndOfStream) return err;

            try self.destination.commitPreparedReferenceUpdates(updates, &prepared);
            return .{
                .checksum = checksum,
                .object_count = object_count,
                .reference_count = updates.len,
            };
        }

        pub fn abort(self: *Self) void {
            self.staging.deinit();
            self.staging = memory.ObjectStorage.init(self.allocator);
            self.input.abort();
        }
    };
}

fn FilesystemImportTarget(comptime Fs: type) type {
    const Storage = filesystem.StorageFor(Fs);
    return struct {
        const Self = @This();

        allocator: Allocator,
        base: *Storage,
        staging: *memory.ObjectStorage,

        pub fn get(self: *Self, h: Hash) !*plumbing.MemoryObject {
            return self.staging.encodedObject(.any, h) catch |err| switch (err) {
                error.ObjectNotFound => self.base.encodedObject(.any, h),
            };
        }

        pub fn putContent(self: *Self, t: plumbing.ObjectType, content: []const u8) !Hash {
            const obj = try self.allocator.create(plumbing.MemoryObject);
            errdefer self.allocator.destroy(obj);
            obj.* = plumbing.MemoryObject.init(self.allocator);
            obj.hash_algo = self.base.hashAlgo();
            errdefer obj.deinit();
            obj.setType(t);
            try obj.setContent(content);
            return self.staging.setEncodedObject(obj);
        }
    };
}
