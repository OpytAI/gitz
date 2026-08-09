//! Cross-backend high-level repository proof.

const std = @import("std");
const plumbing = @import("plumbing");
const filesystem = @import("filesystem");
const fs_pkg = @import("fs");
const memory = @import("memory");
const objpkg = @import("object");
const remote = @import("remote");
const remote_pack_import_filesystem = @import("remote_pack_import_filesystem");
const utils_sync = @import("utils/sync");

const repository = @import("repository.zig");

test "RepositoryFor and WorktreeFor run a local workflow on fs.Os" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    defer utils_sync.deinitPools(allocator);

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var work_fs = try fs_pkg.Os.initFromDir(allocator, io, tmp.dir, "tmp", false);
    defer work_fs.deinit();
    try work_fs.mkdirAll(".git", fs_pkg.Mode.dir);

    var dot_fs = try work_fs.chroot(".git");
    defer dot_fs.deinit();

    const storage = try filesystem.newStorageOsWithOptions(allocator, &dot_fs, null, .{
        .clock = memory.Clock.fixedClock(memory.Time.unix(1_700_000_000, 0)),
    });
    defer {
        storage.deinit();
        allocator.destroy(storage);
    }
    try storage.initLayout();
    try storage.setReference(plumbing.Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

    var repo = repository.newRepositoryFor(
        filesystem.StorageOs,
        fs_pkg.Os,
        storage,
        &work_fs,
    );
    var wt = try repo.worktree();

    try work_fs.mkdirAll("src", fs_pkg.Mode.dir);
    var source = try work_fs.create("src/main.txt");
    _ = try source.write("native backend\n");
    try source.close();

    _ = try wt.add("src/main.txt");
    const signature = objpkg.Signature{
        .name = "Gitz test",
        .email = "gitz@example.test",
        .when = 1_700_000_000,
        .tz_offset_minutes = 0,
    };
    const first = try wt.commit("native commit", .{
        .author = signature,
        .committer = signature,
    });

    const head = try repo.head();
    defer repo.freeReference(head);
    try std.testing.expect(head.hash.eql(first));
    const commit_object = try repo.commitObject(first);
    defer {
        commit_object.deinit();
        allocator.destroy(commit_object);
    }
    try std.testing.expectEqualStrings("native commit", commit_object.message);

    const cfg = try repo.config();
    try cfg.setUser("Native User", "native@example.test");
    try repo.setConfig(cfg);
    const created_remote = try repo.createRemote("origin", &.{"https://example.test/repo.git"});
    try std.testing.expectEqualStrings("origin", created_remote.name());
    const stored_cfg = try repo.config();
    try std.testing.expectEqualStrings("Native User", stored_cfg.user_name);
    try std.testing.expect(stored_cfg.remotes.contains("origin"));
    const stored_remote = try repo.remote("origin");
    try std.testing.expectEqualStrings("origin", stored_remote.name());

    var clean = try wt.status();
    defer clean.deinit();
    try std.testing.expect(clean.isClean());

    var changed = try work_fs.openFile(
        "src/main.txt",
        fs_pkg.O.WRONLY | fs_pkg.O.TRUNC,
        0o644,
    );
    _ = try changed.write("changed on disk\n");
    try changed.close();

    var dirty = try wt.status();
    defer dirty.deinit();
    try std.testing.expect(!dirty.isClean());

    try wt.reset(.{ .commit = first, .mode = .hard });
    var restored = try work_fs.open("src/main.txt");
    var buf: [64]u8 = undefined;
    const n = try restored.read(&buf);
    try std.testing.expectEqualStrings("native backend\n", buf[0..n]);
    try restored.close();

    const feature = plumbing.ReferenceName.init("refs/heads/native-feature");
    try wt.checkout(.{ .branch = feature, .create = true, .force = true });
    var feature_file = try work_fs.openFile(
        "src/main.txt",
        fs_pkg.O.WRONLY | fs_pkg.O.TRUNC,
        0o644,
    );
    _ = try feature_file.write("feature content\n");
    try feature_file.close();
    _ = try wt.add("src/main.txt");
    const second = try wt.commit("feature commit", .{
        .author = signature,
        .committer = signature,
    });
    try std.testing.expect(!second.eql(first));

    try repo.createBranch("native-feature", "origin", "refs/heads/native-feature");
    const tracking = try repo.branch("native-feature");
    try std.testing.expectEqualStrings("origin", tracking.remote);
    const created_tag = try repo.createTag("v-native", second, null);
    defer repo.freeReference(created_tag);
    const stored_tag = try repo.tag("v-native");
    defer repo.freeReference(stored_tag);
    try std.testing.expect(stored_tag.hash.eql(second));

    var branch_refs = try repo.branches();
    defer branch_refs.deinit();
    var branch_count: usize = 0;
    while (branch_refs.next()) |_| branch_count += 1 else |err| switch (err) {
        error.EndOfStream => {},
    }
    try std.testing.expectEqual(@as(usize, 2), branch_count);

    var tag_refs = try repo.tags();
    defer tag_refs.deinit();
    const iterated_tag = try tag_refs.next();
    try std.testing.expect(iterated_tag.hash.eql(second));
    try std.testing.expect((try repo.resolveRevision("v-native")).eql(second));

    var history = try repo.log(.{ .from = second });
    defer history.deinit();
    const latest = try history.next();
    defer {
        latest.deinit();
        allocator.destroy(latest);
    }
    try std.testing.expect(latest.hash.eql(second));

    var commits = try repo.commitObjects();
    defer commits.deinit();
    var commit_count: usize = 0;
    while (true) {
        const commit = commits.next() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        commit.deinit();
        allocator.destroy(commit);
        commit_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), commit_count);

    var pack = try remote.buildPack(allocator, storage, &.{second}, &.{}, .{});
    defer pack.deinit(allocator);
    try std.testing.expect(pack.object_count > 3);

    try work_fs.mkdirAll("destination/.git", fs_pkg.Mode.dir);
    var destination_work = try work_fs.chroot("destination");
    defer destination_work.deinit();
    var destination_dot = try destination_work.chroot(".git");
    defer destination_dot.deinit();
    const destination_storage = try filesystem.newStorageOsWithOptions(allocator, &destination_dot, null, .{
        .clock = memory.Clock.fixedClock(memory.Time.unix(1_700_000_000, 0)),
    });
    defer {
        destination_storage.deinit();
        allocator.destroy(destination_storage);
    }
    try destination_storage.initLayout();
    try destination_storage.setReference(
        plumbing.Reference.newSymbolicReference(plumbing.HEAD, plumbing.master),
    );

    const ImportSession = remote_pack_import_filesystem.FilesystemPackImportSessionFor(fs_pkg.Os);
    var importer = ImportSession.init(allocator, destination_storage, .{
        .max_pack_bytes = pack.bytes.len,
        .max_objects = 1024,
    });
    defer importer.deinit();
    var offset: usize = 0;
    const chunks = [_]usize{ 1, 17, 3, 127, 5 };
    var chunk_index: usize = 0;
    while (offset < pack.bytes.len) : (chunk_index += 1) {
        const count = @min(chunks[chunk_index % chunks.len], pack.bytes.len - offset);
        try importer.write(pack.bytes[offset .. offset + count]);
        offset += count;
    }

    const destination_tag = plumbing.ReferenceName.init("refs/tags/imported");
    const rejected_updates = [_]memory.ReferenceUpdate{
        .{
            .name = plumbing.master,
            .new_reference = plumbing.Reference.newHashReference(plumbing.master, second),
            .expected = plumbing.Reference.newHashReference(plumbing.master, first),
        },
        .{
            .name = destination_tag,
            .new_reference = plumbing.Reference.newHashReference(destination_tag, second),
        },
    };
    try std.testing.expectError(error.ReferenceHasChanged, importer.finish(&rejected_updates));
    try std.testing.expectError(error.ReferenceNotFound, destination_storage.reference(plumbing.master));
    try std.testing.expectError(error.ReferenceNotFound, destination_storage.reference(destination_tag));

    importer.abort();
    offset = 0;
    while (offset < pack.bytes.len) {
        const count = @min(@as(usize, 113), pack.bytes.len - offset);
        try importer.write(pack.bytes[offset .. offset + count]);
        offset += count;
    }
    const accepted_updates = [_]memory.ReferenceUpdate{
        .{
            .name = plumbing.master,
            .new_reference = plumbing.Reference.newHashReference(plumbing.master, second),
            .require_absent = true,
        },
        .{
            .name = destination_tag,
            .new_reference = plumbing.Reference.newHashReference(destination_tag, second),
            .require_absent = true,
        },
    };
    const imported = try importer.finish(&accepted_updates);
    try std.testing.expectEqual(pack.object_count, imported.object_count);
    try std.testing.expectEqual(@as(usize, 2), imported.reference_count);

    var destination_repo = repository.newRepositoryFor(
        filesystem.StorageOs,
        fs_pkg.Os,
        destination_storage,
        &destination_work,
    );
    var destination_wt = try destination_repo.worktree();
    try destination_wt.checkout(.{ .branch = plumbing.master, .force = true });
    var imported_file = try destination_work.open("src/main.txt");
    defer imported_file.close() catch {};
    const imported_n = try imported_file.read(&buf);
    try std.testing.expectEqualStrings("feature content\n", buf[0..imported_n]);

    try wt.checkout(.{ .branch = plumbing.master, .force = true });
    const master_head = try repo.head();
    defer repo.freeReference(master_head);
    try std.testing.expect(master_head.hash.eql(first));

    var master_file = try work_fs.open("src/main.txt");
    defer master_file.close() catch {};
    const master_n = try master_file.read(&buf);
    try std.testing.expectEqualStrings("native backend\n", buf[0..master_n]);
}
