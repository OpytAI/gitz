//! Repository.Worktree free-function form — go-git `Repository.Worktree`.
//!
//! Methods live on `Repository` (`worktree` / `worktreeEmbedded`). This module
//! re-exports free-function aliases for package-level use and inventory mapping.

const fs_pkg = @import("fs");
const worktree = @import("worktree");
const server = @import("server");

const repository = @import("repository.zig");
const error_mod = @import("error.zig");

/// go-git `Repository.Worktree` free-function form of `Repository.worktree`.
///
/// Returns `error.IsBareRepository` when no worktree filesystem is attached.
pub fn worktreeOf(self: *repository.Repository) error_mod.Error!worktree.Worktree {
    const fs: *fs_pkg.Mem = self.wt orelse return error.IsBareRepository;
    return worktree.newWorktree(self.storer.allocator, self.storer, fs);
}

/// Free-function form of `Repository.worktreeEmbedded`.
pub fn worktreeEmbedded(
    self: *repository.Repository,
    srv: *server.Server,
) error_mod.Error!worktree.Worktree {
    const fs: *fs_pkg.Mem = self.wt orelse return error.IsBareRepository;
    return worktree.newWorktreeEmbedded(self.storer.allocator, self.storer, fs, srv);
}

// ---------------------------------------------------------------------------
// Tests — Repository ↔ Worktree glue
// ---------------------------------------------------------------------------

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");
const objpkg = @import("object");

fn destroyStorage(allocator: std.mem.Allocator, sto: *memory.Storage) void {
    sto.deinit();
    allocator.destroy(sto);
}

fn writeFile(fs: *fs_pkg.Mem, path: []const u8, content: []const u8) !void {
    var f = try fs.create(path);
    defer f.close() catch {};
    _ = try f.write(content);
}

fn testAuthor() objpkg.Signature {
    return .{
        .name = "testuser",
        .email = "testemail",
        .when = 1_000_000_000,
        .tz_offset_minutes = 0,
    };
}

test "non-bare Repository.worktree returns Worktree and status is clean" {
    const gpa = std.testing.allocator;
    const sto = try memory.newStorage(gpa);
    defer destroyStorage(gpa, sto);

    var fs = try fs_pkg.Mem.init(gpa);
    defer fs.deinit();

    var r = try repository.init(sto, &fs);
    try std.testing.expect(!r.isBare());

    var wt = try r.worktree();
    try std.testing.expect(wt.storer == sto);
    try std.testing.expect(wt.filesystem == &fs);

    var st = try wt.status();
    defer st.deinit();
    try std.testing.expect(st.isClean());
}

test "worktreeOf free function matches Repository.worktree" {
    const gpa = std.testing.allocator;
    const sto = try memory.newStorage(gpa);
    defer destroyStorage(gpa, sto);

    var fs = try fs_pkg.Mem.init(gpa);
    defer fs.deinit();

    var r = try repository.init(sto, &fs);
    const via_method = try r.worktree();
    const via_free = try worktreeOf(&r);
    try std.testing.expect(via_method.storer == via_free.storer);
    try std.testing.expect(via_method.filesystem == via_free.filesystem);
}

test "bare Repository.worktree returns IsBareRepository" {
    const gpa = std.testing.allocator;
    const sto = try memory.newStorage(gpa);
    defer destroyStorage(gpa, sto);

    var r = try repository.init(sto, null);
    try std.testing.expect(r.isBare());
    try std.testing.expectError(error.IsBareRepository, r.worktree());
    try std.testing.expectError(error.IsBareRepository, worktreeOf(&r));
    try std.testing.expectError(error.IsBareRepository, r.worktreeFs());
}

test "Repository.worktree write add commit status cycle" {
    const gpa = std.testing.allocator;
    const sto = try memory.newStorage(gpa);
    defer destroyStorage(gpa, sto);

    var fs = try fs_pkg.Mem.init(gpa);
    defer fs.deinit();

    var r = try repository.init(sto, &fs);
    var wt = try r.worktree();

    try writeFile(&fs, "hello.txt", "hello\n");

    {
        var st = try wt.status();
        defer st.deinit();
        try std.testing.expect(!st.isClean());
        const e = st.map.get("hello.txt") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(worktree.StatusCode.untracked, e.worktree);
        try std.testing.expectEqual(worktree.StatusCode.untracked, e.staging);
    }

    _ = try wt.add("hello.txt");

    {
        var st = try wt.status();
        defer st.deinit();
        try std.testing.expect(!st.isClean());
        const e = st.map.get("hello.txt") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(worktree.StatusCode.added, e.staging);
        try std.testing.expectEqual(worktree.StatusCode.unmodified, e.worktree);
    }

    _ = try wt.commit("initial", .{ .author = testAuthor() });

    {
        var st = try wt.status();
        defer st.deinit();
        try std.testing.expect(st.isClean());
    }

    // HEAD should resolve through the repository facade.
    const head = try r.head();
    try std.testing.expect(head.type == .hash);
    try std.testing.expect(!head.hash.isZero());
}
