const std = @import("std");
const fs = @import("fs");
const image = @import("persistence");
const memory = @import("memory");
const object = @import("object");
const plumbing = @import("plumbing");
const repo = @import("repo");
const worktree = @import("worktree");
const sync = @import("utils/sync");
const abi = @import("abi.zig");

// Process allocator for this module. Pool get/put and `deinitPools` must share it.
const allocator = std.heap.wasm_allocator;
const fixed_clock = memory.Clock.fixedClock(memory.Time.unix(1_700_000_500, 0));

const Engine = struct {
    restored: image.Restored,
    repository: repo.Repository,

    fn deinit(self: *Engine) void {
        self.restored.deinit(allocator);
        // Engine close: drain process pools with the module allocator.
        sync.deinitPools(allocator);
        self.* = undefined;
    }
};

var engine: ?Engine = null;
var restore_bytes: std.ArrayListUnmanaged(u8) = .empty;
var restore_limit: usize = 0;

export fn gitz_create_image() u32 {
    const bytes = createImage() catch |err| return abi.putError(err);
    return abi.putOwned(bytes);
}

export fn gitz_restore_begin(max_bytes: u32) void {
    restore_bytes.clearRetainingCapacity();
    restore_limit = max_bytes;
}

export fn gitz_restore_write(input: [*]const u8, length: u32) u32 {
    if (length > restore_limit -| restore_bytes.items.len) return 1;
    restore_bytes.appendSlice(allocator, input[0..length]) catch return 2;
    return 0;
}

export fn gitz_restore_finish() u32 {
    const result = restoreAndVerify() catch |err| return abi.putError(err);
    return abi.putOwned(result);
}

export fn gitz_result_len(handle: u32) u32 {
    return abi.len(handle);
}

export fn gitz_result_read_at(handle: u32, offset: u32, out: [*]u8, capacity: u32) u32 {
    return abi.readAt(handle, offset, out, capacity);
}

export fn gitz_result_free(handle: u32) void {
    abi.free(handle);
}

export fn gitz_buffer() [*]u8 {
    return abi.scratchPtr();
}

export fn gitz_buffer_capacity() u32 {
    return abi.scratchCapacity();
}

fn createImage() ![]u8 {
    // One-shot session close (no long-lived Engine on the create path).
    defer sync.deinitPools(allocator);

    const store = try memory.newStorageWithClock(allocator, fixed_clock);
    defer {
        store.deinit();
        allocator.destroy(store);
    }
    var filesystem = try fs.Mem.init(allocator);
    defer filesystem.deinit();
    var repository = try repo.init(store, &filesystem);
    _ = try repository.createRemote("origin", &.{"https://example.invalid/persist.git"});
    var wt = try repository.worktree();

    try writeFile(&filesystem, "committed.txt", "committed base\n");
    try writeFile(&filesystem, "executable.sh", "#!/bin/sh\necho persisted\n");
    try filesystem.chmod("executable.sh", 0o755);
    try writeFile(&filesystem, "sparse/kept.txt", "sparse bytes\n");
    _ = try wt.add("committed.txt");
    _ = try wt.add("executable.sh");
    _ = try wt.add("sparse/kept.txt");

    const signature = object.Signature{
        .name = "Persistence",
        .email = "persist@example.invalid",
        .when = 1_700_000_500,
        .tz_offset_minutes = 0,
    };
    _ = try wt.commit("persistent base", .{ .author = signature, .committer = signature });

    try writeFile(&filesystem, "staged.txt", "staged bytes\n");
    _ = try wt.add("staged.txt");
    try writeFile(&filesystem, "committed.txt", "dirty bytes\n");
    try writeFile(&filesystem, "untracked.txt", "untracked bytes\n");

    const idx = try store.index();
    for (idx.entries.items) |*entry| {
        if (std.mem.eql(u8, entry.name, "sparse/kept.txt")) entry.skip_worktree = true;
    }
    store.setIndex(idx);

    return image.exportImage(allocator, store, &filesystem);
}

fn restoreAndVerify() ![]u8 {
    if (engine) |*old| old.deinit();
    var restored = try image.restoreImage(allocator, fixed_clock, restore_bytes.items);
    errdefer restored.deinit(allocator);
    const repository = try repo.open(restored.store, &restored.filesystem);
    engine = .{ .restored = restored, .repository = repository };
    engine.?.repository.wt = &engine.?.restored.filesystem;
    const e = &engine.?;

    const head_before = try e.repository.head();
    var wt = try e.repository.worktree();
    var status_before = try wt.status();
    defer status_before.deinit();
    const counts = statusCounts(&status_before);

    const idx = try e.restored.store.index();
    var sparse_count: usize = 0;
    var executable_mode: u32 = 0;
    for (idx.entries.items) |entry| {
        if (entry.skip_worktree) sparse_count += 1;
        if (std.mem.eql(u8, entry.name, "executable.sh")) executable_mode = entry.mode;
    }
    const fs_mode = (try e.restored.filesystem.stat("executable.sh")).mode;
    const dirty = try readFile(&e.restored.filesystem, "committed.txt");
    defer allocator.free(dirty);
    const untracked = try readFile(&e.restored.filesystem, "untracked.txt");
    defer allocator.free(untracked);

    const signature = object.Signature{
        .name = "Persistence",
        .email = "persist@example.invalid",
        .when = 1_700_000_500,
        .tz_offset_minutes = 0,
    };
    const next = try wt.commit("commit after restore", .{ .author = signature, .committer = signature });
    if (next.eql(head_before.hash)) return error.CommitDidNotAdvance;

    var head_buf: [plumbing.MaxHexSize]u8 = undefined;
    var next_buf: [plumbing.MaxHexSize]u8 = undefined;
    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"head_before\":\"{s}\",\"head_after\":\"{s}\",\"refs\":{d},\"index_entries\":{d},\"sparse\":{d},\"staged\":{d},\"dirty\":{d},\"untracked\":{d},\"index_exec\":{},\"fs_exec\":{},\"dirty_bytes\":\"{s}\",\"untracked_bytes\":\"{s}\",\"remote\":{}}}",
        .{
            head_before.hash.string(&head_buf),
            next.string(&next_buf),
            e.restored.store.countLooseRefs(),
            idx.entries.items.len,
            sparse_count,
            counts.staged,
            counts.dirty,
            counts.untracked,
            executable_mode & 0o111 != 0,
            fs_mode & 0o111 != 0,
            std.mem.trimEnd(u8, dirty, "\n"),
            std.mem.trimEnd(u8, untracked, "\n"),
            (try e.repository.remote("origin")).name().len > 0,
        },
    );
}

const StatusCounts = struct { staged: usize = 0, dirty: usize = 0, untracked: usize = 0 };

fn statusCounts(status: *const worktree.Status) StatusCounts {
    var result = StatusCounts{};
    var iterator = status.map.iterator();
    while (iterator.next()) |entry| {
        const value = entry.value_ptr.*;
        if (value.staging == .added or value.staging == .modified or value.staging == .deleted) {
            result.staged += 1;
        }
        if (value.worktree == .modified or value.worktree == .deleted) result.dirty += 1;
        if (value.worktree == .untracked) result.untracked += 1;
    }
    return result;
}

fn writeFile(filesystem: *fs.Mem, path: []const u8, content: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        try filesystem.mkdirAll(path[0..slash], fs.Mode.dir);
    }
    var file = try filesystem.create(path);
    defer file.close() catch {};
    _ = try file.write(content);
}

fn readFile(filesystem: *fs.Mem, path: []const u8) ![]u8 {
    var file = try filesystem.open(path);
    defer file.close() catch {};
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var buffer: [256]u8 = undefined;
    while (true) {
        const count = try file.read(&buffer);
        if (count == 0) break;
        try bytes.appendSlice(allocator, buffer[0..count]);
    }
    return bytes.toOwnedSlice(allocator);
}
