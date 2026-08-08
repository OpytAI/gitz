//! Worktree / repository Grep (go-git `Worktree.Grep` / `Repository.Grep`).
//!
//! Greps **tree contents from a commit** (not the live working tree).
//! Patterns are fixed-string substrings (no regex) for hermetic parity.

const std = @import("std");
const plumbing = @import("plumbing");
const objpkg = @import("object");
const storer = @import("storer");

const worktree_mod = @import("worktree.zig");
const options_mod = @import("options.zig");

const Allocator = std.mem.Allocator;
const Worktree = worktree_mod.Worktree;
const GrepOptions = options_mod.GrepOptions;
const Hash = plumbing.Hash;
const File = objpkg.File;

/// go-git `GrepResult`.
///
/// All string fields are owned; free with `freeGrepResults`.
pub const GrepResult = struct {
    file_name: []const u8,
    /// 1-based line number (go-git `LineNumber`).
    line_number: usize,
    content: []const u8,
    /// Reference name or commit hash hex (go-git `TreeName`).
    tree_name: []const u8,
};

/// Free a slice returned by `grep` (including empty `toOwnedSlice` results).
pub fn freeGrepResults(allocator: Allocator, results: []GrepResult) void {
    for (results) |r| {
        allocator.free(r.file_name);
        allocator.free(r.content);
        allocator.free(r.tree_name);
    }
    allocator.free(results);
}

/// go-git `(*Worktree).Grep` → repository grep over commit tree.
pub fn grep(w: *Worktree, o: GrepOptions) ![]GrepResult {
    var opts = o;
    try opts.validate(w.storer);

    var commit_hash: Hash = undefined;
    var tree_name: []const u8 = undefined;

    if (opts.reference_name.raw.len > 0) {
        const ref = try storer.resolveReference(w.storer, opts.reference_name);
        commit_hash = ref.hash;
        tree_name = try w.allocator.dupe(u8, opts.reference_name.raw);
    } else {
        // validate() defaults commit_hash to HEAD when both empty.
        commit_hash = opts.commit_hash;
        var hex_buf: [plumbing.MaxHexSize]u8 = undefined;
        const hex = commit_hash.string(&hex_buf);
        tree_name = try w.allocator.dupe(u8, hex);
    }
    defer w.allocator.free(tree_name);

    const commit = try objpkg.getCommit(w.allocator, w.storer, commit_hash);
    defer {
        commit.deinit();
        w.allocator.destroy(commit);
    }

    var file_iter = try commit.files();
    return try findMatchInFiles(w.allocator, &file_iter, tree_name, &opts);
}

fn findMatchInFiles(
    allocator: Allocator,
    file_iter: *objpkg.FileIter,
    tree_name: []const u8,
    opts: *const GrepOptions,
) ![]GrepResult {
    defer file_iter.close();

    var results: std.ArrayList(GrepResult) = .empty;
    errdefer {
        for (results.items) |r| {
            allocator.free(r.file_name);
            allocator.free(r.content);
            allocator.free(r.tree_name);
        }
        results.deinit(allocator);
    }

    while (true) {
        const file = file_iter.next() catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };

        if (!pathMatches(file.name, opts.path_specs)) continue;

        try findMatchInFile(allocator, &file, tree_name, opts, &results);
    }

    return try results.toOwnedSlice(allocator);
}

fn pathMatches(name: []const u8, path_specs: []const []const u8) bool {
    if (path_specs.len == 0) return true;
    for (path_specs) |spec| {
        if (spec.len == 0) continue;
        if (std.mem.indexOf(u8, name, spec) != null) return true;
    }
    return false;
}

fn findMatchInFile(
    allocator: Allocator,
    file: *const File,
    tree_name: []const u8,
    opts: *const GrepOptions,
    results: *std.ArrayList(GrepResult),
) !void {
    const content = try file.contents(allocator);
    defer allocator.free(content);

    // go-git uses strings.Split (keeps trailing empty segment after final \n).
    var line_num: usize = 0;
    var start: usize = 0;
    while (true) {
        const rel = std.mem.indexOfScalar(u8, content[start..], '\n');
        const line: []const u8 = if (rel) |r|
            content[start .. start + r]
        else
            content[start..];

        line_num += 1;
        if (lineMatches(line, opts)) {
            try results.append(allocator, .{
                .file_name = try allocator.dupe(u8, file.name),
                .line_number = line_num,
                .content = try allocator.dupe(u8, line),
                .tree_name = try allocator.dupe(u8, tree_name),
            });
        }

        if (rel) |r| {
            start = start + r + 1;
            if (start > content.len) break;
            if (start == content.len) {
                // Trailing empty line after final newline.
                line_num += 1;
                if (lineMatches("", opts)) {
                    try results.append(allocator, .{
                        .file_name = try allocator.dupe(u8, file.name),
                        .line_number = line_num,
                        .content = try allocator.dupe(u8, ""),
                        .tree_name = try allocator.dupe(u8, tree_name),
                    });
                }
                break;
            }
        } else {
            break;
        }
    }
}

/// Fixed-string match: any pattern matches (OR). Invert → none match.
///
/// go-git compiles each pattern as a regexp and ORs MatchString results; with
/// fixed strings this is substring OR, then XOR with InvertMatch.
fn lineMatches(line: []const u8, opts: *const GrepOptions) bool {
    if (opts.patterns.len == 0) return false;

    var any = false;
    for (opts.patterns) |pattern| {
        if (pattern.len == 0) continue;
        if (std.mem.indexOf(u8, line, pattern) != null) {
            any = true;
            break;
        }
    }
    return if (opts.invert_match) !any else any;
}

test "lineMatches fixed string and invert" {
    const opts_match = GrepOptions{ .patterns = &.{"import"} };
    try std.testing.expect(lineMatches("import (", &opts_match));
    try std.testing.expect(!lineMatches("package main", &opts_match));

    const opts_inv = GrepOptions{ .patterns = &.{"import"}, .invert_match = true };
    try std.testing.expect(!lineMatches("import (", &opts_inv));
    try std.testing.expect(lineMatches("package main", &opts_inv));
}

test "lineMatches multi-pattern OR and invert" {
    const opts = GrepOptions{ .patterns = &.{ "foo", "bar" } };
    try std.testing.expect(lineMatches("xx fooyy", &opts));
    try std.testing.expect(lineMatches("bar only", &opts));
    try std.testing.expect(!lineMatches("neither", &opts));

    const inv = GrepOptions{ .patterns = &.{ "foo", "bar" }, .invert_match = true };
    try std.testing.expect(!lineMatches("has foo", &inv));
    try std.testing.expect(lineMatches("neither", &inv));
}
