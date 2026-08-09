//! Transport-independent transactional pack import for repository backends.

const std = @import("std");
const plumbing = @import("plumbing");
const packfile = @import("packfile");
const memory = @import("memory");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;

pub const PackImportResult = struct {
    checksum: Hash,
    object_count: usize,
    reference_count: usize,
};

pub const PackImportSession = struct {
    allocator: Allocator,
    destination: *memory.Storage,
    input: packfile.ImportSession,
    transaction: memory.TxObjectStorage,

    pub fn init(
        allocator: Allocator,
        destination: *memory.Storage,
        limits: packfile.ImportLimits,
    ) PackImportSession {
        return .{
            .allocator = allocator,
            .destination = destination,
            .input = packfile.ImportSession.init(allocator, limits),
            .transaction = destination.object_storage.begin(),
        };
    }

    pub fn deinit(self: *PackImportSession) void {
        self.transaction.deinit();
        self.input.deinit();
        self.* = undefined;
    }

    pub fn write(self: *PackImportSession, chunk: []const u8) !void {
        return self.input.write(chunk);
    }

    pub fn finish(
        self: *PackImportSession,
        updates: []const memory.ReferenceUpdate,
    ) !PackImportResult {
        var target = ImportTarget{
            .allocator = self.allocator,
            .base = self.destination,
            .transaction = &self.transaction,
        };
        const sink = packfile.EncodedObjectStore.from(ImportTarget, &target);

        var committed = false;
        defer if (!committed) self.transaction.rollback();

        const checksum = try self.input.finish(sink);
        const object_count = self.transaction.count();

        var prepared_refs = try self.destination.reference_storage.prepareUpdates(updates);
        var refs_owned = true;
        defer if (refs_owned) prepared_refs.deinit();

        try self.destination.object_storage.prepareTransaction(&self.transaction);
        self.destination.object_storage.commitPrepared(&self.transaction);
        self.destination.reference_storage.commitPrepared(&prepared_refs);
        refs_owned = false;
        committed = true;

        return .{
            .checksum = checksum,
            .object_count = object_count,
            .reference_count = updates.len,
        };
    }

    /// Roll back decoded objects, discard bytes, and reuse this session.
    pub fn abort(self: *PackImportSession) void {
        self.transaction.rollback();
        self.input.abort();
    }
};

const ImportTarget = struct {
    allocator: Allocator,
    base: *memory.Storage,
    transaction: *memory.TxObjectStorage,

    pub fn get(self: *ImportTarget, h: Hash) !*plumbing.MemoryObject {
        return self.transaction.encodedObject(.any, h) catch |err| switch (err) {
            error.ObjectNotFound => self.base.encodedObject(.any, h),
        };
    }

    pub fn putContent(self: *ImportTarget, t: plumbing.ObjectType, content: []const u8) !Hash {
        const obj = try self.allocator.create(plumbing.MemoryObject);
        errdefer self.allocator.destroy(obj);
        obj.* = plumbing.MemoryObject.init(self.allocator);
        obj.hash_algo = self.base.hashAlgo();
        errdefer obj.deinit();
        obj.setType(t);
        try obj.setContent(content);
        return self.transaction.setEncodedObject(obj);
    }
};
