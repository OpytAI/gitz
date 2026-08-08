//! Phase 12 worktree integration tests (status / add / commit / checkout /
//! reset / clean lifecycle over memory storage + Mem FS).
//!
//! Compiles against `Worktree` surface methods. Sibling modules (status, add,
//! commit, checkout, reset) must exist for the suite to link.

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");
const fs_pkg = @import("fs");
const objpkg = @import("object");

const worktree = @import("root.zig");
const options_mod = @import("options.zig");

const Allocator = std.mem.Allocator;
const Worktree = worktree.Worktree;
const Status = worktree.Status;
const StatusCode = worktree.StatusCode;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn destroyStorage(allocator: Allocator, sto: *memory.Storage) void {
    sto.deinit();
    allocator.destroy(sto);
}

const Env = struct {
    sto: *memory.Storage,
    fs: *fs_pkg.Mem,
    wt: Worktree,

    fn deinit(self: *Env, allocator: Allocator) void {
        self.fs.deinit();
        allocator.destroy(self.fs);
        destroyStorage(allocator, self.sto);
        self.* = undefined;
    }
};

// Init empty memory repo + Mem worktree (manual HEAD; no `//src/repo` dep).
//
// Heap-allocate Mem so `wt.filesystem` is not a dangling stack pointer after return.
fn setupEmpty(allocator: Allocator) !Env {
    const sto = try memory.newStorage(allocator);
    errdefer destroyStorage(allocator, sto);

    try sto.setReference(plumbing.Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

    const fs = try allocator.create(fs_pkg.Mem);
    errdefer allocator.destroy(fs);
    fs.* = try fs_pkg.Mem.init(allocator);
    errdefer fs.deinit();

    // Match status unit tests: no extra process format flip.
    return .{
        .sto = sto,
        .fs = fs,
        .wt = worktree.newWorktree(allocator, sto, fs),
    };
}

fn writeFile(fs: *fs_pkg.Mem, path: []const u8, content: []const u8) !void {
    var f = try fs.create(path);
    defer f.close() catch {};
    _ = try f.write(content);
}

fn readFileAll(allocator: Allocator, fs: *fs_pkg.Mem, path: []const u8) ![]u8 {
    var f = try fs.open(path);
    defer f.close() catch {};
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [256]u8 = undefined;
    while (true) {
        const n = try f.read(&buf);
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
    }
    return try list.toOwnedSlice(allocator);
}

fn fileExists(fs: *fs_pkg.Mem, path: []const u8) bool {
    _ = fs.stat(path) catch return false;
    return true;
}

fn testAuthor() objpkg.Signature {
    return .{
        .name = "testuser",
        .email = "testemail",
        .when = 1_000_000_000,
        .tz_offset_minutes = 0,
    };
}

fn commitOpts() options_mod.CommitOptions {
    return .{ .author = testAuthor() };
}

fn statusCodeAt(st: *const Status, path: []const u8) ?struct { staging: StatusCode, worktree: StatusCode } {
    const e = st.map.get(path) orelse return null;
    return .{ .staging = e.staging, .worktree = e.worktree };
}

// ---------------------------------------------------------------------------
// 1. status clean on empty worktree after init
// ---------------------------------------------------------------------------

test "status clean on empty worktree after init" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    var st = try env.wt.status();
    defer st.deinit();
    try std.testing.expect(st.isClean());
}

// ---------------------------------------------------------------------------
// 2. write → untracked → add → staged → commit → clean
// ---------------------------------------------------------------------------

test "write add commit status cycle" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try writeFile(env.fs, "hello.txt", "hello\n");

    {
        var st = try env.wt.status();
        defer st.deinit();
        try std.testing.expect(!st.isClean());
        const codes = statusCodeAt(&st, "hello.txt") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(StatusCode.untracked, codes.worktree);
        try std.testing.expectEqual(StatusCode.untracked, codes.staging);
    }

    _ = try env.wt.add("hello.txt");

    {
        var st = try env.wt.status();
        defer st.deinit();
        try std.testing.expect(!st.isClean());
        const codes = statusCodeAt(&st, "hello.txt") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(StatusCode.added, codes.staging);
        try std.testing.expectEqual(StatusCode.unmodified, codes.worktree);
    }

    _ = try env.wt.commit("initial", commitOpts());

    {
        var st = try env.wt.status();
        defer st.deinit();
        try std.testing.expect(st.isClean());
    }
}

// ---------------------------------------------------------------------------
// 3. modify file → status modified worktree
// ---------------------------------------------------------------------------

test "modify file shows worktree modified" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try writeFile(env.fs, "tracked.txt", "v1\n");
    _ = try env.wt.add("tracked.txt");
    _ = try env.wt.commit("add tracked", commitOpts());

    try writeFile(env.fs, "tracked.txt", "v2\n");

    var st = try env.wt.status();
    defer st.deinit();
    try std.testing.expect(!st.isClean());
    const codes = statusCodeAt(&st, "tracked.txt") orelse return error.TestUnexpectedResult;
    try std.testing.expect(codes.worktree == .modified);
    try std.testing.expect(codes.staging == .unmodified);
}

// ---------------------------------------------------------------------------
// 4. checkout branch / hard reset restores file
// ---------------------------------------------------------------------------

test "hard reset restores modified file" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try writeFile(env.fs, "file.txt", "original\n");
    _ = try env.wt.add("file.txt");
    const commit_hash = try env.wt.commit("base", commitOpts());

    try writeFile(env.fs, "file.txt", "dirty\n");
    {
        var st = try env.wt.status();
        defer st.deinit();
        try std.testing.expect(!st.isClean());
    }

    try env.wt.reset(.{
        .commit = commit_hash,
        .mode = .hard,
    });

    {
        var st = try env.wt.status();
        defer st.deinit();
        try std.testing.expect(st.isClean());
    }

    const body = try readFileAll(gpa, env.fs, "file.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("original\n", body);
}

test "checkout creates branch and hard checkout restores" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try writeFile(env.fs, "main.txt", "on-master\n");
    _ = try env.wt.add("main.txt");
    _ = try env.wt.commit("on master", commitOpts());

    // Create and switch to feature branch.
    var feature_buf: [64]u8 = undefined;
    const feature = try plumbing.newBranchReferenceName("feature", &feature_buf);
    try env.wt.checkout(.{
        .branch = feature,
        .create = true,
    });

    try writeFile(env.fs, "main.txt", "on-feature\n");
    _ = try env.wt.add("main.txt");
    _ = try env.wt.commit("on feature", commitOpts());

    // Back to master via hard checkout of master tip.
    try env.wt.checkout(.{
        .branch = plumbing.master,
        .force = true,
    });

    const body = try readFileAll(gpa, env.fs, "main.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("on-master\n", body);

    var st = try env.wt.status();
    defer st.deinit();
    try std.testing.expect(st.isClean());
}

// ---------------------------------------------------------------------------
// 5. soft / mixed reset smoke
// ---------------------------------------------------------------------------

test "soft and mixed reset smoke" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try writeFile(env.fs, "a.txt", "one\n");
    _ = try env.wt.add("a.txt");
    const first = try env.wt.commit("first", commitOpts());

    try writeFile(env.fs, "b.txt", "two\n");
    _ = try env.wt.add("b.txt");
    const second = try env.wt.commit("second", commitOpts());
    _ = second;

    // Soft: move HEAD only; index + worktree keep second-commit tree.
    try env.wt.reset(.{
        .commit = first,
        .mode = .soft,
    });
    try std.testing.expect(fileExists(env.fs, "b.txt"));
    {
        // After soft reset to first, b.txt remains staged (index still at second).
        var st = try env.wt.status();
        defer st.deinit();
        try std.testing.expect(!st.isClean());
        const codes = statusCodeAt(&st, "b.txt") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(StatusCode.added, codes.staging);
    }

    // Mixed: HEAD + index to `first`; worktree files stay on disk.
    try env.wt.reset(.{
        .commit = first,
        .mode = .mixed,
    });
    try std.testing.expect(fileExists(env.fs, "a.txt"));
    try std.testing.expect(fileExists(env.fs, "b.txt"));
    {
        var st = try env.wt.status();
        defer st.deinit();
        // b.txt is untracked relative to first commit after mixed reset.
        try std.testing.expect(st.isUntracked("b.txt"));
    }
}

// ---------------------------------------------------------------------------
// Clean: untracked files and directories
// ---------------------------------------------------------------------------

test "clean removes untracked files; dir option removes empty dirs" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    // Seed a committed file so the repo is non-empty and clean baseline exists.
    try writeFile(env.fs, "kept.txt", "keep\n");
    _ = try env.wt.add("kept.txt");
    _ = try env.wt.commit("keep", commitOpts());

    try writeFile(env.fs, "junk.txt", "junk\n");
    try env.fs.mkdirAll("pkgA", 0o755);
    try writeFile(env.fs, "pkgA/nested.txt", "nested\n");

    {
        var st = try env.wt.status();
        defer st.deinit();
        try std.testing.expect(st.isUntracked("junk.txt"));
        try std.testing.expect(st.isUntracked("pkgA/nested.txt"));
    }

    // Without Dir: only top-level untracked files; nested dir contents stay.
    try env.wt.clean(.{ .dir = false });
    try std.testing.expect(!fileExists(env.fs, "junk.txt"));
    try std.testing.expect(fileExists(env.fs, "pkgA/nested.txt"));
    try std.testing.expect(fileExists(env.fs, "kept.txt"));

    // With Dir: remove untracked nested files and empty dirs.
    try env.wt.clean(.{ .dir = true });
    try std.testing.expect(!fileExists(env.fs, "pkgA/nested.txt"));
    try std.testing.expect(!fileExists(env.fs, "pkgA"));
    try std.testing.expect(fileExists(env.fs, "kept.txt"));

    var st = try env.wt.status();
    defer st.deinit();
    try std.testing.expect(st.isClean());
}

test "clean with Dir true leaves root worktree" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try env.wt.clean(.{ .dir = true });
    // Root must remain (go-git TestCleanBare).
    try std.testing.expect(fileExists(env.fs, "."));
    _ = try env.fs.stat(".");
}

test "clean skips .git directory name" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try env.fs.mkdirAll(".git", 0o755);
    try writeFile(env.fs, ".git/config", "[core]\n");
    try writeFile(env.fs, "tmp.o", "obj\n");

    try env.wt.clean(.{ .dir = true });

    try std.testing.expect(!fileExists(env.fs, "tmp.o"));
    try std.testing.expect(fileExists(env.fs, ".git/config"));
}

// ---------------------------------------------------------------------------
// Combined phase exit scenario (single long path)
// ---------------------------------------------------------------------------

test "phase exit scenario full lifecycle" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    // 1. clean after init
    {
        var st = try env.wt.status();
        defer st.deinit();
        try std.testing.expect(st.isClean());
    }

    // 2. write → untracked → add → staged → commit → clean
    try writeFile(env.fs, "lifecycle.txt", "v1\n");
    {
        var st = try env.wt.status();
        defer st.deinit();
        try std.testing.expect(st.isUntracked("lifecycle.txt"));
    }
    _ = try env.wt.add("lifecycle.txt");
    {
        var st = try env.wt.status();
        defer st.deinit();
        const codes = statusCodeAt(&st, "lifecycle.txt") orelse return error.TestUnexpectedResult;
        try std.testing.expect(codes.staging == .added);
    }
    const h1 = try env.wt.commit("v1", commitOpts());
    {
        var st = try env.wt.status();
        defer st.deinit();
        try std.testing.expect(st.isClean());
    }

    // 3. modify → worktree modified
    try writeFile(env.fs, "lifecycle.txt", "v2-dirty\n");
    {
        var st = try env.wt.status();
        defer st.deinit();
        const codes = statusCodeAt(&st, "lifecycle.txt") orelse return error.TestUnexpectedResult;
        try std.testing.expect(codes.worktree == .modified);
    }

    // 4. hard reset restores
    try env.wt.reset(.{ .commit = h1, .mode = .hard });
    {
        const body = try readFileAll(gpa, env.fs, "lifecycle.txt");
        defer gpa.free(body);
        try std.testing.expectEqualStrings("v1\n", body);
        var st = try env.wt.status();
        defer st.deinit();
        try std.testing.expect(st.isClean());
    }

    // 5. soft / mixed smoke after a second commit
    try writeFile(env.fs, "lifecycle.txt", "v2\n");
    _ = try env.wt.add("lifecycle.txt");
    const h2 = try env.wt.commit("v2", commitOpts());
    _ = h2;

    try env.wt.reset(.{ .commit = h1, .mode = .soft });
    try env.wt.reset(.{ .commit = h1, .mode = .mixed });
    try env.wt.reset(.{ .commit = h1, .mode = .hard });

    {
        var st = try env.wt.status();
        defer st.deinit();
        try std.testing.expect(st.isClean());
    }

    // Clean leftover untracked
    try writeFile(env.fs, "scratch.tmp", "x");
    try env.wt.clean(.{});
    try std.testing.expect(!fileExists(env.fs, "scratch.tmp"));
}
