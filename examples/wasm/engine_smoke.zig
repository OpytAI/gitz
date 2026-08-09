const std = @import("std");
const fs = @import("fs");
const image = @import("persistence");
const memory = @import("memory");
const object = @import("object");
const plumbing = @import("plumbing");
const remote = @import("remote");
const repo = @import("repo");
const abi = @import("abi.zig");

const allocator = std.heap.wasm_allocator;
const clock = memory.Clock.fixedClock(memory.Time.unix(1_700_001_000, 0));

export fn gitz_run() u32 {
    const result = run() catch |err| return abi.putError(err);
    return abi.putOwned(result);
}

export fn gitz_result_len(handle: u32) u32 {
    return abi.len(handle);
}

export fn gitz_result_read(handle: u32, out: [*]u8, capacity: u32) u32 {
    return abi.read(handle, out, capacity);
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

fn run() ![]u8 {
    const source_store = try memory.newStorageWithClock(allocator, clock);
    defer {
        source_store.deinit();
        allocator.destroy(source_store);
    }
    var source_fs = try fs.Mem.init(allocator);
    defer source_fs.deinit();
    var source_repo = try repo.init(source_store, &source_fs);
    var source_wt = try source_repo.worktree();

    try writeFile(&source_fs, "nested/value.txt", "base\n");
    _ = try source_wt.add("nested/value.txt");
    const signature = object.Signature{
        .name = "Engine Smoke",
        .email = "smoke@example.invalid",
        .when = 1_700_001_000,
        .tz_offset_minutes = 0,
    };
    const base = try source_wt.commit("base", .{ .author = signature, .committer = signature });

    var feature_buf: [128]u8 = undefined;
    const feature = try plumbing.newBranchReferenceName("engine-smoke", &feature_buf);
    try source_wt.checkout(.{ .branch = feature, .create = true });
    try writeFile(&source_fs, "nested/value.txt", "combined wasm engine\n");
    _ = try source_wt.add("nested/value.txt");
    const tip = try source_wt.commit("feature", .{ .author = signature, .committer = signature });

    var built = try remote.buildPack(allocator, source_store, &.{tip}, &.{base}, .{});
    defer built.deinit(allocator);

    const destination_store = try memory.newStorageWithClock(allocator, clock);
    defer {
        destination_store.deinit();
        allocator.destroy(destination_store);
    }
    var destination_fs = try fs.Mem.init(allocator);
    defer destination_fs.deinit();
    var destination_repo = try repo.init(destination_store, &destination_fs);

    // Seed the have side exactly as negotiated, then import the delta pack.
    const base_objects = try remote.buildPack(allocator, source_store, &.{base}, &.{}, .{});
    defer allocator.free(base_objects.bytes);
    var base_import = remote.PackImportSession.init(allocator, destination_store, .{
        .max_pack_bytes = base_objects.bytes.len,
        .max_objects = 1024,
    });
    defer base_import.deinit();
    try base_import.write(base_objects.bytes);
    _ = try base_import.finish(&.{});

    var import_session = remote.PackImportSession.init(allocator, destination_store, .{
        .max_pack_bytes = built.bytes.len,
        .max_objects = 1024,
    });
    defer import_session.deinit();
    var offset: usize = 0;
    const chunks = [_]usize{ 1, 17, 3, 91, 2 };
    var chunk_index: usize = 0;
    while (offset < built.bytes.len) : (chunk_index += 1) {
        const count = @min(chunks[chunk_index % chunks.len], built.bytes.len - offset);
        try import_session.write(built.bytes[offset .. offset + count]);
        offset += count;
    }
    const main_ref = plumbing.Reference.newHashReference(plumbing.master, tip);
    const imported = try import_session.finish(&.{.{
        .name = plumbing.master,
        .new_reference = main_ref,
        .require_absent = true,
    }});

    var destination_wt = try destination_repo.worktree();
    try destination_wt.checkout(.{ .branch = plumbing.master, .force = true });
    const source_content = try readFile(&source_fs, "nested/value.txt");
    defer allocator.free(source_content);
    const destination_content = try readFile(&destination_fs, "nested/value.txt");
    defer allocator.free(destination_content);
    if (!std.mem.eql(u8, source_content, destination_content)) return error.ContentMismatch;

    const persisted = try image.exportImage(allocator, destination_store, &destination_fs);
    defer allocator.free(persisted);

    var objects = try destination_store.iterEncodedObjects(.any);
    defer objects.deinit();
    var object_count: usize = 0;
    while (objects.next()) |_| object_count += 1 else |err| switch (err) {
        error.EndOfStream => {},
    }
    var tip_buf: [plumbing.MaxHexSize]u8 = undefined;
    const content_oid = plumbing.computeHash(.blob, destination_content);
    var content_oid_buf: [plumbing.MaxHexSize]u8 = undefined;
    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"head\":\"{s}\",\"pack_objects\":{d},\"imported_objects\":{d},\"objects\":{d},\"refs\":{d},\"content\":\"{s}\",\"content_oid\":\"{s}\",\"image_bytes\":{d}}}",
        .{
            tip.string(&tip_buf),
            built.object_count,
            imported.object_count,
            object_count,
            destination_store.countLooseRefs(),
            std.mem.trimEnd(u8, destination_content, "\n"),
            content_oid.string(&content_oid_buf),
            persisted.len,
        },
    );
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
    var buffer: [128]u8 = undefined;
    while (true) {
        const count = try file.read(&buffer);
        if (count == 0) break;
        try bytes.appendSlice(allocator, buffer[0..count]);
    }
    return bytes.toOwnedSlice(allocator);
}
