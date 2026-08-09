//! Worktree Clean (go-git `Worktree.Clean` / `doClean`).
//!
//! Removes untracked files (and empty directories when `CleanOptions.dir`) from
//! the worktree filesystem. Uses `Status.IsUntracked` so ignored paths stay
//! when status respects gitignore.

const std = @import("std");
const fs_pkg = @import("fs");
const pathutil = @import("pathutil");

const options_mod = @import("options.zig");
const status_types = @import("status_types.zig");
const worktree_mod = @import("worktree.zig");
const util = @import("util.zig");

const Allocator = std.mem.Allocator;
const Worktree = worktree_mod.Worktree;
const CleanOptions = options_mod.CleanOptions;
const Status = status_types.Status;
const FileInfo = fs_pkg.FileInfo;
const joinRel = util.joinRel;

/// go-git `GitDirName` — never remove or recurse into `.git`.
const git_dir_name = ".git";

/// go-git `Worktree.Clean` — remove untracked files (and dirs if `o.dir`).
pub fn clean(w: *Worktree, o: CleanOptions) !void {
    var s = try w.status();
    defer s.deinit();

    const root: []const u8 = "";
    const files = try w.filesystem.readDir(root);
    defer w.filesystem.freeReadDir(files);
    try doClean(w, &s, o, root, files);
}

/// go-git `doClean` — recursive clean under `dir`.
fn doClean(
    w: *Worktree,
    status: *const Status,
    opts: CleanOptions,
    dir: []const u8,
    files: []const FileInfo,
) !void {
    for (files) |fi| {
        if (std.mem.eql(u8, fi.name, git_dir_name) or pathutil.isDotGitName(fi.name)) continue;

        const path = try joinRel(w.allocator, dir, fi.name);
        defer w.allocator.free(path);

        if (fi.isDir()) {
            if (!opts.dir) continue;

            const subfiles = try w.filesystem.readDir(path);
            defer w.filesystem.freeReadDir(subfiles);
            try doClean(w, status, opts, path, subfiles);
        } else {
            if (status.isUntracked(path)) {
                try w.filesystem.remove(path);
            }
        }
    }

    if (opts.dir and dir.len > 0) {
        _ = try removeDirIfEmpty(w, dir);
    }
}

/// go-git `removeDirIfEmpty` — remove `dir` when it has no entries.
/// Returns true when the directory was removed.
fn removeDirIfEmpty(w: *Worktree, dir: []const u8) !bool {
    const files = try w.filesystem.readDir(dir);
    defer w.filesystem.freeReadDir(files);
    if (files.len > 0) return false;
    try w.filesystem.remove(dir);
    return true;
}

test {
    _ = @import("util.zig");
}
