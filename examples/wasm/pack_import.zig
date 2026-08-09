const std = @import("std");
const fs = @import("fs");
const memory = @import("memory");
const object = @import("object");
const plumbing = @import("plumbing");
const remote = @import("remote");
const repo = @import("repo");
const abi = @import("abi.zig");

const allocator = std.heap.wasm_allocator;

const Engine = struct {
    store: *memory.Storage,
    filesystem: fs.Mem,
    repository: repo.Repository,
    import_session: ?remote.PackImportSession = null,
    expected_commit: plumbing.Hash = plumbing.ZeroHash,
    expected_tag: plumbing.Hash = plumbing.ZeroHash,
    expected_thin: plumbing.Hash = plumbing.ZeroHash,

    fn deinit(self: *Engine) void {
        if (self.import_session) |*session| session.deinit();
        self.filesystem.deinit();
        self.store.deinit();
        allocator.destroy(self.store);
        self.* = undefined;
    }
};

var engine: ?Engine = null;

export fn gitz_fixture_pack() u32 {
    const bytes = makeFixturePack() catch |err| return abi.putError(err);
    return abi.putOwned(bytes);
}

export fn gitz_thin_fixture_pack() u32 {
    const bytes = makeThinFixturePack() catch |err| return abi.putError(err);
    return abi.putOwned(bytes);
}

export fn gitz_import_begin(max_pack_bytes: u32) u32 {
    const e = getEngine() catch return 1;
    if (e.import_session) |*old| old.deinit();
    e.import_session = remote.PackImportSession.init(allocator, e.store, .{
        .max_pack_bytes = max_pack_bytes,
        .max_objects = 1024,
    });
    return 0;
}

export fn gitz_import_write(input: [*]const u8, length: u32) u32 {
    const e = getEngine() catch return 1;
    const session = if (e.import_session) |*value| value else return 1;
    session.write(input[0..length]) catch |err| return switch (err) {
        error.PackTooLarge => 2,
        error.ImportFinished => 3,
        else => 4,
    };
    return 0;
}

export fn gitz_import_abort() void {
    const e = getEngine() catch return;
    if (e.import_session) |*session| session.abort();
}

export fn gitz_import_finish(inject_ref_failure: u32) u32 {
    const result = finishImport(inject_ref_failure != 0) catch |err| return abi.putError(err);
    return abi.putOwned(result);
}

export fn gitz_thin_import_finish() u32 {
    const result = finishThinImport() catch |err| return abi.putError(err);
    return abi.putOwned(result);
}

export fn gitz_state() u32 {
    const result = stateJson() catch |err| return abi.putError(err);
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

fn resetEngine() !*Engine {
    if (engine) |*old| old.deinit();
    const store = try memory.newStorageWithClock(
        allocator,
        memory.Clock.fixedClock(memory.Time.unix(1_700_000_000, 0)),
    );
    errdefer {
        store.deinit();
        allocator.destroy(store);
    }
    var filesystem = try fs.Mem.init(allocator);
    errdefer filesystem.deinit();
    const repository = try repo.init(store, &filesystem);
    engine = .{ .store = store, .filesystem = filesystem, .repository = repository };
    // `Repository` borrows its worktree. Rebind after moving `filesystem`
    // into the long-lived engine value.
    engine.?.repository.wt = &engine.?.filesystem;
    return &engine.?;
}

fn getEngine() !*Engine {
    return if (engine) |*value| value else error.EngineNotInitialized;
}

fn makeFixturePack() ![]u8 {
    const destination = try resetEngine();

    const source_store = try memory.newStorageWithClock(
        allocator,
        memory.Clock.fixedClock(memory.Time.unix(1_700_000_000, 0)),
    );
    defer {
        source_store.deinit();
        allocator.destroy(source_store);
    }
    var source_fs = try fs.Mem.init(allocator);
    defer source_fs.deinit();
    var source_repo = try repo.init(source_store, &source_fs);
    var wt = try source_repo.worktree();

    try writeFile(&source_fs, "nested/imported.txt", "transactional pack import\n");
    _ = try wt.add("nested/imported.txt");
    const signature = object.Signature{
        .name = "Pack Source",
        .email = "pack@example.invalid",
        .when = 1_700_000_000,
        .tz_offset_minutes = 0,
    };
    const commit = try wt.commit("pack fixture", .{ .author = signature, .committer = signature });
    const tag_ref = try source_repo.createTag("v-import", commit, .{
        .tagger = signature,
        .message = "import fixture",
    });

    const built = try remote.buildPack(allocator, source_store, &.{tag_ref.hash}, &.{}, .{});
    destination.expected_commit = commit;
    destination.expected_tag = tag_ref.hash;
    return built.bytes;
}

fn finishImport(inject_failure: bool) ![]u8 {
    const e = try getEngine();
    const session = if (e.import_session) |*value| value else return error.ImportNotStarted;

    const main_ref = plumbing.Reference.newHashReference(plumbing.master, e.expected_commit);
    var tag_name_buf: [128]u8 = undefined;
    const tag_name = try plumbing.newTagReferenceName("v-import", &tag_name_buf);
    const tag_ref = plumbing.Reference.newHashReference(tag_name, e.expected_tag);

    var updates = [_]memory.ReferenceUpdate{
        .{ .name = plumbing.master, .new_reference = main_ref, .require_absent = true },
        .{ .name = tag_name, .new_reference = tag_ref, .require_absent = true },
    };
    if (inject_failure) {
        updates[1].expected = plumbing.Reference.newHashReference(tag_name, plumbing.ZeroHash);
        updates[1].require_absent = false;
    }

    const imported = try session.finish(&updates);
    var wt = try e.repository.worktree();
    try wt.checkout(.{ .branch = plumbing.master, .force = true });

    const content = try readFile(&e.filesystem, "nested/imported.txt");
    defer allocator.free(content);
    const head = try e.repository.head();
    var head_buf: [plumbing.MaxHexSize]u8 = undefined;
    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"head\":\"{s}\",\"objects\":{d},\"refs_updated\":{d},\"refs\":{d},\"content\":\"{s}\"}}",
        .{
            head.hash.string(&head_buf),
            imported.object_count,
            imported.reference_count,
            e.store.countLooseRefs(),
            std.mem.trimEnd(u8, content, "\n"),
        },
    );
}

fn makeThinFixturePack() ![]u8 {
    const e = try getEngine();
    const base_content = "thin base";
    const target_content = "thin base!";
    const base = try storeObject(e.store, .blob, base_content);
    e.expected_thin = plumbing.computeHash(.blob, target_content);

    var delta = [_]u8{
        base_content.len,
        target_content.len,
        0x90,
        base_content.len,
        1,
        '!',
    };
    return buildThinPack(base, &delta);
}

fn finishThinImport() ![]u8 {
    const e = try getEngine();
    const session = if (e.import_session) |*value| value else return error.ImportNotStarted;
    const imported = try session.finish(&.{});
    const target = try e.store.encodedObject(.blob, e.expected_thin);
    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"objects\":{d},\"content\":\"{s}\"}}",
        .{ imported.object_count, target.readerBytes() },
    );
}

fn storeObject(store: *memory.Storage, t: plumbing.ObjectType, content: []const u8) !plumbing.Hash {
    const obj = try store.newEncodedObject();
    errdefer {
        obj.deinit();
        allocator.destroy(obj);
    }
    obj.setType(t);
    try obj.setContent(content);
    return store.setEncodedObject(obj);
}

fn buildThinPack(base: plumbing.Hash, delta: []const u8) ![]u8 {
    var compressed_writer: std.Io.Writer.Allocating = try .initCapacity(allocator, 64);
    defer compressed_writer.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(
        &compressed_writer.writer,
        &window,
        .zlib,
        .default,
    );
    try compressor.writer.writeAll(delta);
    try compressor.finish();

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, "PACK");
    var word: [4]u8 = undefined;
    std.mem.writeInt(u32, &word, 2, .big);
    try bytes.appendSlice(allocator, &word);
    std.mem.writeInt(u32, &word, 1, .big);
    try bytes.appendSlice(allocator, &word);

    var remaining = delta.len;
    var first: u8 = (@as(u8, @intFromEnum(plumbing.ObjectType.ref_delta)) << 4) |
        @as(u8, @truncate(remaining & 0x0f));
    remaining >>= 4;
    if (remaining != 0) first |= 0x80;
    try bytes.append(allocator, first);
    while (remaining != 0) {
        var next: u8 = @truncate(remaining & 0x7f);
        remaining >>= 7;
        if (remaining != 0) next |= 0x80;
        try bytes.append(allocator, next);
    }
    try bytes.appendSlice(allocator, base.slice());
    try bytes.appendSlice(allocator, compressed_writer.written());

    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(bytes.items);
    var checksum: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    hasher.final(&checksum);
    try bytes.appendSlice(allocator, &checksum);
    return bytes.toOwnedSlice(allocator);
}

fn stateJson() ![]u8 {
    const e = try getEngine();
    var objects = try e.store.iterEncodedObjects(.any);
    defer objects.deinit();
    var object_count: usize = 0;
    while (objects.next()) |_| object_count += 1 else |err| switch (err) {
        error.EndOfStream => {},
    }
    const main_visible = if (e.store.reference(plumbing.master)) |_| true else |_| false;
    var tag_buf: [128]u8 = undefined;
    const tag_name = try plumbing.newTagReferenceName("v-import", &tag_buf);
    const tag_visible = if (e.store.reference(tag_name)) |_| true else |_| false;
    return std.fmt.allocPrint(
        allocator,
        "{{\"ok\":true,\"objects\":{d},\"main\":{},\"tag\":{},\"refs\":{d}}}",
        .{ object_count, main_visible, tag_visible, e.store.countLooseRefs() },
    );
}

fn writeFile(filesystem: *fs.Mem, path: []const u8, content: []const u8) !void {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    if (slash) |index| try filesystem.mkdirAll(path[0..index], fs.Mode.dir);
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
