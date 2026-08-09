//! Worktree integration tests (status / add / commit / checkout /
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

test "clean preserves case-folded git metadata directory" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try env.fs.mkdirAll(".GIT", 0o755);
    try writeFile(env.fs, ".GIT/config", "[core]\n");

    try env.wt.clean(.{ .dir = true });

    try std.testing.expect(fileExists(env.fs, ".GIT/config"));
}

test "add rejects paths outside the worktree" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try std.testing.expectError(error.InvalidPath, env.wt.add("../outside"));
}

test "remove rejects git metadata paths" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try std.testing.expectError(error.InvalidPath, env.wt.remove(".git/config"));
}

test "move rejects source paths outside the worktree" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try std.testing.expectError(error.InvalidPath, env.wt.move("../from", "safe"));
}

test "move rejects destination paths outside the worktree" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try std.testing.expectError(error.InvalidPath, env.wt.move("safe", "../to"));
}

// ---------------------------------------------------------------------------
// Combined lifecycle scenario
// ---------------------------------------------------------------------------

test "full worktree lifecycle" {
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

// ---------------------------------------------------------------------------
// Restore
// ---------------------------------------------------------------------------

test "restore no files returns NoRestorePaths" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try std.testing.expectError(
        worktree.Error.NoRestorePaths,
        env.wt.restore(.{ .staged = true }),
    );
}

test "restore worktree-only returns RestoreWorktreeOnlyNotSupported" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try writeFile(env.fs, "f.txt", "x\n");
    _ = try env.wt.add("f.txt");
    _ = try env.wt.commit("c", commitOpts());

    try std.testing.expectError(
        worktree.Error.RestoreWorktreeOnlyNotSupported,
        env.wt.restore(.{
            .worktree = true,
            .files = &.{"f.txt"},
        }),
    );
    // Neither staged nor worktree is also unsupported once files are given.
    try std.testing.expectError(
        worktree.Error.RestoreWorktreeOnlyNotSupported,
        env.wt.restore(.{
            .files = &.{"f.txt"},
        }),
    );
}

test "restore staged-only resets index from HEAD (mixed)" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try writeFile(env.fs, "tracked.txt", "original\n");
    _ = try env.wt.add("tracked.txt");
    _ = try env.wt.commit("base", commitOpts());

    // Stage a modification, then make a secondary worktree-only edit.
    try writeFile(env.fs, "tracked.txt", "staged\n");
    _ = try env.wt.add("tracked.txt");
    try writeFile(env.fs, "tracked.txt", "worktree-secondary\n");

    {
        var st = try env.wt.status();
        defer st.deinit();
        const codes = statusCodeAt(&st, "tracked.txt") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(StatusCode.modified, codes.staging);
        try std.testing.expectEqual(StatusCode.modified, codes.worktree);
    }

    try env.wt.restore(.{
        .staged = true,
        .files = &.{"tracked.txt"},
    });

    // Mixed restore: index matches HEAD; worktree keeps secondary edits.
    {
        var st = try env.wt.status();
        defer st.deinit();
        const codes = statusCodeAt(&st, "tracked.txt") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(StatusCode.unmodified, codes.staging);
        try std.testing.expectEqual(StatusCode.modified, codes.worktree);
    }

    const body = try readFileAll(gpa, env.fs, "tracked.txt");
    defer gpa.free(body);
    try std.testing.expectEqualStrings("worktree-secondary\n", body);
}

// ---------------------------------------------------------------------------
// Grep
// ---------------------------------------------------------------------------

test "grep finds line in committed blob" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try env.fs.mkdirAll("src", 0o755);
    try writeFile(env.fs, "src/main.txt", "alpha\nfindme here\nomega\n");
    _ = try env.wt.add("src/main.txt");
    const h = try env.wt.commit("add main", commitOpts());

    // Dirty worktree must not affect grep (commit tree only).
    try writeFile(env.fs, "src/main.txt", "no match in worktree\n");

    const results = try env.wt.grep(.{
        .patterns = &.{"findme"},
    });
    defer worktree.freeGrepResults(gpa, results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("src/main.txt", results[0].file_name);
    try std.testing.expectEqual(@as(usize, 2), results[0].line_number);
    try std.testing.expectEqualStrings("findme here", results[0].content);

    var hex_buf: [plumbing.MaxHexSize]u8 = undefined;
    const hex = h.string(&hex_buf);
    try std.testing.expectEqualStrings(hex, results[0].tree_name);
}

test "grep invert excludes matching lines" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try writeFile(env.fs, "notes.txt", "keep\nskip-import\nkeep2\n");
    _ = try env.wt.add("notes.txt");
    _ = try env.wt.commit("notes", commitOpts());

    const results = try env.wt.grep(.{
        .patterns = &.{"import"},
        .invert_match = true,
    });
    defer worktree.freeGrepResults(gpa, results);

    // invert: all non-matching lines (including trailing empty from final \n).
    var found_keep = false;
    var found_keep2 = false;
    var found_import = false;
    for (results) |r| {
        if (std.mem.eql(u8, r.content, "keep")) found_keep = true;
        if (std.mem.eql(u8, r.content, "keep2")) found_keep2 = true;
        if (std.mem.indexOf(u8, r.content, "import") != null) found_import = true;
    }
    try std.testing.expect(found_keep);
    try std.testing.expect(found_keep2);
    try std.testing.expect(!found_import);
}

test "grep path_specs filter" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try env.fs.mkdirAll("go", 0o755);
    try env.fs.mkdirAll("vendor", 0o755);
    try writeFile(env.fs, "go/example.go", "package main\nimport (\n");
    try writeFile(env.fs, "vendor/foo.go", "package foo\nimport \"fmt\"\n");
    _ = try env.wt.add("go/example.go");
    _ = try env.wt.add("vendor/foo.go");
    _ = try env.wt.commit("two files", commitOpts());

    const results = try env.wt.grep(.{
        .patterns = &.{"import"},
        .path_specs = &.{"go/"},
    });
    defer worktree.freeGrepResults(gpa, results);

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("go/example.go", results[0].file_name);
}

test "grep hash and reference exclusive" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try writeFile(env.fs, "a.txt", "x\n");
    _ = try env.wt.add("a.txt");
    const h = try env.wt.commit("c", commitOpts());

    try std.testing.expectError(
        worktree.Error.HashOrReference,
        env.wt.grep(.{
            .patterns = &.{"x"},
            .commit_hash = h,
            .reference_name = plumbing.master,
        }),
    );
}

// ---------------------------------------------------------------------------
// Sparse checkout / ResetSparsely
// ---------------------------------------------------------------------------
//
// go-git Index.SkipUnless marks non-matching index entries with skip_worktree
// (it does not delete them). Hard ResetSparsely then materialises only the
// non-skip paths into the worktree. Active (non-skip) index paths are those
// under the sparse dir prefixes (e.g. "a" → a/*).

test "resetSparsely hard keeps only sparse prefix active in index" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try env.fs.mkdirAll("a", 0o755);
    try env.fs.mkdirAll("b", 0o755);
    try writeFile(env.fs, "a/x.txt", "ax\n");
    try writeFile(env.fs, "b/y.txt", "by\n");
    _ = try env.wt.add("a/x.txt");
    _ = try env.wt.add("b/y.txt");
    const h = try env.wt.commit("nested", commitOpts());

    // Sparse hard reset: only "a" stays checked out / active.
    try env.wt.resetSparsely(.{
        .commit = h,
        .mode = .hard,
    }, &.{"a"});

    const idx = try env.sto.index();
    var active_a = false;
    var active_b = false;
    var skip_b = false;
    for (idx.entries.items) |*e| {
        if (std.mem.eql(u8, e.name, "a/x.txt")) {
            try std.testing.expect(!e.skip_worktree);
            active_a = true;
        } else if (std.mem.eql(u8, e.name, "b/y.txt")) {
            if (e.skip_worktree) skip_b = true else active_b = true;
        }
    }
    try std.testing.expect(active_a);
    // b is either marked skip_worktree or absent from active checkout view.
    try std.testing.expect(skip_b or !active_b);
    try std.testing.expect(!active_b);

    // Worktree should still have a/x.txt; sparse hard drops other prefixes.
    try std.testing.expect(fileExists(env.fs, "a/x.txt"));
}

// ---------------------------------------------------------------------------
// move / removeGlob / grep integration tests
// ---------------------------------------------------------------------------

test "move renames tracked file in index and worktree" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try writeFile(env.fs, "old.txt", "body\n");
    _ = try env.wt.add("old.txt");
    _ = try env.wt.commit("base", commitOpts());

    const h = try env.wt.move("old.txt", "new.txt");
    try std.testing.expect(!h.isZero());
    try std.testing.expect(!fileExists(env.fs, "old.txt"));
    try std.testing.expect(fileExists(env.fs, "new.txt"));

    const idx = try env.sto.index();
    try std.testing.expectError(error.EntryNotFound, idx.entry("old.txt"));
    const e = try idx.entry("new.txt");
    try std.testing.expect(e.hash.eql(h));
}

test "removeGlob removes matching index and worktree paths" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try env.fs.mkdirAll("pkg", 0o755);
    try writeFile(env.fs, "pkg/a.go", "package a\n");
    try writeFile(env.fs, "pkg/b.go", "package b\n");
    try writeFile(env.fs, "keep.txt", "keep\n");
    _ = try env.wt.add("pkg/a.go");
    _ = try env.wt.add("pkg/b.go");
    _ = try env.wt.add("keep.txt");
    _ = try env.wt.commit("files", commitOpts());

    try env.wt.removeGlob("pkg/*.go");

    const idx = try env.sto.index();
    try std.testing.expectError(error.EntryNotFound, idx.entry("pkg/a.go"));
    try std.testing.expectError(error.EntryNotFound, idx.entry("pkg/b.go"));
    _ = try idx.entry("keep.txt");
    try std.testing.expect(!fileExists(env.fs, "pkg/a.go"));
    try std.testing.expect(!fileExists(env.fs, "pkg/b.go"));
    try std.testing.expect(fileExists(env.fs, "keep.txt"));
}

test "grep finds fixed string in committed tree" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try writeFile(env.fs, "main.go", "package main\nimport \"fmt\"\n");
    _ = try env.wt.add("main.go");
    _ = try env.wt.commit("go", commitOpts());

    const results = try env.wt.grep(.{ .patterns = &.{"import"} });
    defer worktree.freeGrepResults(gpa, results);

    try std.testing.expect(results.len >= 1);
    try std.testing.expectEqualStrings("main.go", results[0].file_name);
    try std.testing.expect(std.mem.indexOf(u8, results[0].content, "import") != null);
}

test "worktree lifecycle includes move removeGlob grep" {
    const gpa = std.testing.allocator;
    var env = try setupEmpty(gpa);
    defer env.deinit(gpa);

    try writeFile(env.fs, "life.txt", "hello world\n");
    _ = try env.wt.add("life.txt");
    _ = try env.wt.commit("life", commitOpts());

    // grep smoke after commit
    {
        const results = try env.wt.grep(.{ .patterns = &.{"hello"} });
        defer worktree.freeGrepResults(gpa, results);
        try std.testing.expect(results.len >= 1);
    }

    // move smoke
    _ = try env.wt.move("life.txt", "life2.txt");
    try std.testing.expect(fileExists(env.fs, "life2.txt"));
    _ = try env.wt.add("life2.txt"); // ensure staged if needed
    // After move, index already has life2.txt; commit rename.
    _ = try env.wt.commit("rename", commitOpts());

    // removeGlob smoke
    try writeFile(env.fs, "tmp.o", "obj\n");
    _ = try env.wt.add("tmp.o");
    _ = try env.wt.commit("obj", commitOpts());
    try env.wt.removeGlob("*.o");
    try std.testing.expect(!fileExists(env.fs, "tmp.o"));
}
