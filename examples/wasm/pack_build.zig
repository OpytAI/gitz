const std = @import("std");
const memory = @import("memory");
const packfile = @import("packfile");
const plumbing = @import("plumbing");
const remote = @import("remote");
const abi = @import("abi.zig");

const allocator = std.heap.wasm_allocator;
const Hash = plumbing.Hash;

const Fixture = struct {
    store: *memory.Storage,
    first: Hash,
    second: Hash,
    tag: Hash,

    fn deinit(self: *Fixture) void {
        self.store.deinit();
        allocator.destroy(self.store);
        self.* = undefined;
    }
};

export fn gitz_run() u32 {
    const bytes = runMetadata() catch |err| return abi.putError(err);
    return abi.putOwned(bytes);
}

export fn gitz_pack_build() u32 {
    var fixture = makeFixture() catch |err| return abi.putError(err);
    defer fixture.deinit();
    const built = remote.buildPack(
        allocator,
        fixture.store,
        &.{ fixture.second, fixture.tag },
        &.{fixture.first},
        .{},
    ) catch |err| return abi.putError(err);
    return abi.putOwned(built.bytes);
}

export fn gitz_result_len(handle: u32) u32 {
    return abi.len(handle);
}

export fn gitz_result_read(handle: u32, out: [*]u8, capacity: u32) u32 {
    return abi.read(handle, out, capacity);
}

export fn gitz_result_read_at(handle: u32, offset: u32, out: [*]u8, capacity: u32) u32 {
    return abi.readAt(handle, offset, out, capacity);
}

export fn gitz_result_free(handle: u32) void {
    abi.free(handle);
}

export fn gitz_result_buffer() [*]u8 {
    return abi.scratchPtr();
}

export fn gitz_result_buffer_capacity() u32 {
    return abi.scratchCapacity();
}

fn runMetadata() ![]u8 {
    var fixture = try makeFixture();
    defer fixture.deinit();

    var built = try remote.buildPack(
        allocator,
        fixture.store,
        &.{ fixture.second, fixture.tag },
        &.{fixture.first},
        .{},
    );
    defer built.deinit(allocator);

    var decoded = packfile.ObjectStore.init(allocator);
    defer decoded.deinit();
    _ = try packfile.updateObjectStorage(allocator, &decoded, built.bytes);

    var empty_delta = try remote.buildPack(
        allocator,
        fixture.store,
        &.{fixture.first},
        &.{fixture.first},
        .{},
    );
    defer empty_delta.deinit(allocator);
    var empty_decoded = packfile.ObjectStore.init(allocator);
    defer empty_decoded.deinit();
    _ = try packfile.updateObjectStorage(allocator, &empty_decoded, empty_delta.bytes);

    var deletion = try remote.buildPack(allocator, fixture.store, &.{}, &.{}, .{});
    defer deletion.deinit(allocator);
    var deletion_decoded = packfile.ObjectStore.init(allocator);
    defer deletion_decoded.deinit();
    _ = try packfile.updateObjectStorage(allocator, &deletion_decoded, deletion.bytes);

    const second_obj = try decoded.get(fixture.second);
    if (second_obj.object_type != .commit) return error.InvalidObjectType;
    const tag_obj = try decoded.get(fixture.tag);
    if (tag_obj.object_type != .tag) return error.InvalidObjectType;
    if (decoded.get(fixture.first)) |_| return error.HaveObjectIncluded else |err| {
        if (err != error.ObjectNotFound) return err;
    }

    var first_hex: [plumbing.MaxHexSize]u8 = undefined;
    var second_hex: [plumbing.MaxHexSize]u8 = undefined;
    var tag_hex: [plumbing.MaxHexSize]u8 = undefined;
    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"have\":\"{s}\",\"want\":\"{s}\",\"tag\":\"{s}\",\"selected\":{d},\"parsed\":{d},\"pack_bytes\":{d},\"empty_delta\":{d},\"deletion_objects\":{d}}}",
        .{
            fixture.first.string(&first_hex),
            fixture.second.string(&second_hex),
            fixture.tag.string(&tag_hex),
            built.object_count,
            decoded.map.count(),
            built.bytes.len,
            empty_decoded.map.count(),
            deletion_decoded.map.count(),
        },
    );
}

fn makeFixture() !Fixture {
    const store = try memory.newStorageWithClock(
        allocator,
        memory.Clock.fixedClock(memory.Time.unix(1_700_000_000, 0)),
    );
    errdefer {
        store.deinit();
        allocator.destroy(store);
    }

    const shared = try storeObject(store, .blob, "shared\n");
    const old_blob = try storeObject(store, .blob, "old\n");
    const nested_one = try storeTree(store, &.{
        .{ .mode = "100644", .name = "old.txt", .hash = old_blob },
    });
    const root_one = try storeTree(store, &.{
        .{ .mode = "040000", .name = "nested", .hash = nested_one },
        .{ .mode = "100644", .name = "shared.txt", .hash = shared },
    });
    const first = try storeCommit(store, root_one, &.{}, "first");

    const new_blob = try storeObject(store, .blob, "new\n");
    const nested_two = try storeTree(store, &.{
        .{ .mode = "100644", .name = "new.txt", .hash = new_blob },
    });
    const root_two = try storeTree(store, &.{
        .{ .mode = "040000", .name = "nested", .hash = nested_two },
        .{ .mode = "100644", .name = "shared.txt", .hash = shared },
    });
    const second = try storeCommit(store, root_two, &.{first}, "second");
    const tag = try storeTag(store, second, "v-wasm-pack");

    return .{ .store = store, .first = first, .second = second, .tag = tag };
}

fn storeObject(store: *memory.Storage, t: plumbing.ObjectType, content: []const u8) !Hash {
    const obj = try store.newEncodedObject();
    errdefer {
        obj.deinit();
        allocator.destroy(obj);
    }
    obj.setType(t);
    try obj.setContent(content);
    return store.setEncodedObject(obj);
}

const TreeEntry = struct { mode: []const u8, name: []const u8, hash: Hash };

fn storeTree(store: *memory.Storage, entries: []const TreeEntry) !Hash {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    for (entries) |entry| {
        try bytes.appendSlice(allocator, entry.mode);
        try bytes.append(allocator, ' ');
        try bytes.appendSlice(allocator, entry.name);
        try bytes.append(allocator, 0);
        try bytes.appendSlice(allocator, entry.hash.slice());
    }
    return storeObject(store, .tree, bytes.items);
}

fn storeCommit(store: *memory.Storage, tree: Hash, parents: []const Hash, message: []const u8) !Hash {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    var hash_buf: [plumbing.MaxHexSize]u8 = undefined;
    try bytes.appendSlice(allocator, "tree ");
    try bytes.appendSlice(allocator, tree.string(&hash_buf));
    try bytes.append(allocator, '\n');
    for (parents) |parent| {
        try bytes.appendSlice(allocator, "parent ");
        try bytes.appendSlice(allocator, parent.string(&hash_buf));
        try bytes.append(allocator, '\n');
    }
    try bytes.appendSlice(allocator, "author Wasm <wasm@example.invalid> 1700000000 +0000\n");
    try bytes.appendSlice(allocator, "committer Wasm <wasm@example.invalid> 1700000000 +0000\n\n");
    try bytes.appendSlice(allocator, message);
    try bytes.append(allocator, '\n');
    return storeObject(store, .commit, bytes.items);
}

fn storeTag(store: *memory.Storage, target: Hash, name: []const u8) !Hash {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    var hash_buf: [plumbing.MaxHexSize]u8 = undefined;
    try bytes.appendSlice(allocator, "object ");
    try bytes.appendSlice(allocator, target.string(&hash_buf));
    try bytes.appendSlice(allocator, "\ntype commit\ntag ");
    try bytes.appendSlice(allocator, name);
    try bytes.appendSlice(allocator, "\ntagger Wasm <wasm@example.invalid> 1700000000 +0000\n\ntag\n");
    return storeObject(store, .tag, bytes.items);
}
