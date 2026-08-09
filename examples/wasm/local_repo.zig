const std = @import("std");
const fs = @import("fs");
const memory = @import("memory");
const object = @import("object");
const plumbing = @import("plumbing");
const repo = @import("repo");
const worktree = @import("worktree");
const abi = @import("abi.zig");

const allocator = std.heap.wasm_allocator;

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
    const store = try memory.newStorageWithClock(
        allocator,
        memory.Clock.fixedClock(memory.Time.unix(1_700_000_000, 123_000_000)),
    );
    defer {
        store.deinit();
        allocator.destroy(store);
    }

    var filesystem = try fs.Mem.init(allocator);
    defer filesystem.deinit();

    var repository = try repo.init(store, &filesystem);
    var wt = try repository.worktree();

    try filesystem.mkdirAll("nested/deep", fs.Mode.dir);
    try writeFile(&filesystem, "nested/deep/hello.txt", "hello from wasm\n");
    try writeFile(&filesystem, "run.sh", "#!/bin/sh\necho gitz\n");
    try filesystem.chmod("run.sh", 0o755);

    var before_add = try wt.status();
    defer before_add.deinit();
    const untracked_count = before_add.map.count();

    _ = try wt.add("nested/deep/hello.txt");
    _ = try wt.add("run.sh");

    const signature = object.Signature{
        .name = "Wasm Author",
        .email = "wasm@example.invalid",
        .when = 1_700_000_000,
        .tz_offset_minutes = 0,
    };
    const first = try wt.commit("initial wasm commit", .{
        .author = signature,
        .committer = signature,
    });

    const cfg = try repository.config();
    try cfg.setUser("Wasm User", "wasm-user@example.invalid");
    try repository.setConfig(cfg);
    const created_tag = try repository.createTag("v-wasm", first, null);
    const created_remote = try repository.createRemote("origin", &.{"https://example.invalid/repo.git"});

    var feature_name_buf: [64]u8 = undefined;
    const feature_name = try plumbing.newBranchReferenceName("wasm-feature", &feature_name_buf);
    try wt.checkout(.{ .branch = feature_name, .create = true });
    try writeFile(&filesystem, "nested/deep/hello.txt", "feature content\n");
    _ = try wt.add("nested/deep/hello.txt");
    _ = try wt.commit("feature commit", .{ .author = signature, .committer = signature });
    try wt.checkout(.{ .branch = plumbing.master, .force = true });

    try writeFile(&filesystem, "nested/deep/hello.txt", "dirty content\n");
    var dirty = try wt.status();
    defer dirty.deinit();
    const dirty_count = countDirty(&dirty);

    _ = try wt.add("nested/deep/hello.txt");
    var staged_diff = try wt.diffCommitWithStaging(first, false);
    defer worktree.deinitMaterializedChanges(allocator, &staged_diff);
    const diff_count = staged_diff.items.items.len;

    try wt.reset(.{ .commit = first, .mode = .hard });
    var final_status = try wt.status();
    defer final_status.deinit();

    const head = try repository.head();
    defer repository.freeReference(head);
    var head_buf: [plumbing.MaxHexSize]u8 = undefined;
    const head_text = head.hash.string(&head_buf);

    const branch_ref = try repository.reference(feature_name, false);
    defer repository.freeReference(branch_ref);
    const stored_tag = try repository.tag("v-wasm");
    defer repository.freeReference(stored_tag);
    const stored_remote = try repository.remote("origin");
    const stored_cfg = try repository.config();

    var log = try repository.log(.{});
    defer log.deinit();
    var commit_count: usize = 0;
    while (true) {
        const commit = log.next() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        commit_count += 1;
        commit.deinit();
        allocator.destroy(commit);
    }

    var objects = try store.iterEncodedObjects(.any);
    defer objects.deinit();
    var object_count: usize = 0;
    while (objects.next()) |_| {
        object_count += 1;
    } else |err| switch (err) {
        error.EndOfStream => {},
    }

    const executable_mode = (try filesystem.stat("run.sh")).mode;
    const restored = try readFile(&filesystem, "nested/deep/hello.txt");
    defer allocator.free(restored);
    const content_oid = plumbing.computeHash(.blob, restored);
    var content_oid_buf: [plumbing.MaxHexSize]u8 = undefined;

    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"head\":\"{s}\",\"commits\":{d},\"objects\":{d},\"refs\":{d},\"untracked\":{d},\"dirty\":{d},\"diff\":{d},\"clean\":{},\"mode\":{d},\"branch\":{},\"tag\":{},\"config\":{},\"remote\":{},\"content\":\"{s}\",\"content_oid\":\"{s}\"}}",
        .{
            head_text,
            commit_count,
            object_count,
            store.countLooseRefs(),
            untracked_count,
            dirty_count,
            diff_count,
            final_status.isClean(),
            executable_mode,
            branch_ref.type == .hash and branch_ref.name.eql(feature_name),
            stored_tag.hash.eql(created_tag.hash),
            std.mem.eql(u8, stored_cfg.user_name, "Wasm User"),
            std.mem.eql(u8, stored_remote.name(), created_remote.name()),
            std.mem.trimEnd(u8, restored, "\n"),
            content_oid.string(&content_oid_buf),
        },
    );
}

fn writeFile(filesystem: *fs.Mem, path: []const u8, content: []const u8) !void {
    var file = try filesystem.create(path);
    defer file.close() catch {};
    _ = try file.write(content);
}

fn readFile(filesystem: *fs.Mem, path: []const u8) ![]u8 {
    var file = try filesystem.open(path);
    defer file.close() catch {};
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buffer: [128]u8 = undefined;
    while (true) {
        const count = try file.read(&buffer);
        if (count == 0) break;
        try out.appendSlice(allocator, buffer[0..count]);
    }
    return out.toOwnedSlice(allocator);
}

fn countDirty(status: *const worktree.Status) usize {
    var count: usize = 0;
    var iterator = status.map.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.staging != .unmodified or entry.value_ptr.worktree != .unmodified) {
            count += 1;
        }
    }
    return count;
}
