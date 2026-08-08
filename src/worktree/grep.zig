//! Worktree / repository Grep (go-git `Worktree.Grep` / `Repository.Grep`).
//!
//! Greps **tree contents from a commit** (not the live working tree).
//! Patterns and pathspecs use pure-Zig regex (`regex.zig`) with Go
//! `MatchString` semantics (unanchored).

const std = @import("std");
const plumbing = @import("plumbing");
const objpkg = @import("object");
const storer = @import("storer");

const worktree_mod = @import("worktree.zig");
const options_mod = @import("options.zig");
const error_mod = @import("error.zig");
const regex_mod = @import("regex.zig");

const Allocator = std.mem.Allocator;
const Worktree = worktree_mod.Worktree;
const GrepOptions = options_mod.GrepOptions;
const Hash = plumbing.Hash;
const File = objpkg.File;

/// go-git `GrepResult`. All string fields owned; free with `freeGrepResults`.
pub const GrepResult = struct {
    file_name: []const u8,
    /// 1-based line number.
    line_number: usize,
    content: []const u8,
    /// Reference name or commit hash hex.
    tree_name: []const u8,
};

pub fn freeGrepResults(allocator: Allocator, results: []GrepResult) void {
    for (results) |r| {
        allocator.free(r.file_name);
        allocator.free(r.content);
        allocator.free(r.tree_name);
    }
    allocator.free(results);
}

/// go-git `(*Worktree).Grep`.
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
        commit_hash = opts.commit_hash;
        var hex_buf: [plumbing.MaxHexSize]u8 = undefined;
        const hex = commit_hash.string(&hex_buf);
        tree_name = try w.allocator.dupe(u8, hex);
    }
    defer w.allocator.free(tree_name);

    // Compile patterns once.
    const compiled = try compileAll(w.allocator, opts.patterns);
    defer freeCompiled(w.allocator, compiled);
    const path_compiled = try compileAll(w.allocator, opts.path_specs);
    defer freeCompiled(w.allocator, path_compiled);

    const commit = try objpkg.getCommit(w.allocator, w.storer, commit_hash);
    defer {
        commit.deinit();
        w.allocator.destroy(commit);
    }

    var file_iter = try commit.files();
    return try findMatchInFiles(
        w.allocator,
        &file_iter,
        tree_name,
        compiled,
        path_compiled,
        opts.invert_match,
    );
}

const Compiled = struct {
    regexes: []regex_mod.Regex,
};

fn compileAll(allocator: Allocator, patterns: []const []const u8) !Compiled {
    var list: std.ArrayList(regex_mod.Regex) = .empty;
    errdefer {
        for (list.items) |*r| r.deinit();
        list.deinit(allocator);
    }
    for (patterns) |p| {
        if (p.len == 0) continue;
        const re = regex_mod.compile(allocator, p) catch |err| switch (err) {
            error.InvalidRegex => return error_mod.Error.InvalidRegex,
            error.OutOfMemory => return error.OutOfMemory,
        };
        try list.append(allocator, re);
    }
    return .{ .regexes = try list.toOwnedSlice(allocator) };
}

fn freeCompiled(allocator: Allocator, c: Compiled) void {
    for (c.regexes) |*r| r.deinit();
    allocator.free(c.regexes);
}

fn findMatchInFiles(
    allocator: Allocator,
    file_iter: *objpkg.FileIter,
    tree_name: []const u8,
    patterns: Compiled,
    path_specs: Compiled,
    invert_match: bool,
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

        if (!pathMatches(file.name, path_specs)) continue;

        try findMatchInFile(allocator, &file, tree_name, patterns, invert_match, &results);
    }

    return try results.toOwnedSlice(allocator);
}

fn pathMatches(name: []const u8, path_specs: Compiled) bool {
    if (path_specs.regexes.len == 0) return true;
    for (path_specs.regexes) |*re| {
        if (re.matchString(name)) return true;
    }
    return false;
}

fn findMatchInFile(
    allocator: Allocator,
    file: *const File,
    tree_name: []const u8,
    patterns: Compiled,
    invert_match: bool,
    results: *std.ArrayList(GrepResult),
) !void {
    if (patterns.regexes.len == 0) return;

    const content = try file.contents(allocator);
    defer allocator.free(content);

    // go-git strings.Split — trailing empty segment after final \n.
    var line_num: usize = 0;
    var start: usize = 0;
    while (true) {
        const rel = std.mem.indexOfScalar(u8, content[start..], '\n');
        const line: []const u8 = if (rel) |r|
            content[start .. start + r]
        else
            content[start..];

        line_num += 1;
        if (lineMatches(line, patterns, invert_match)) {
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
                line_num += 1;
                if (lineMatches("", patterns, invert_match)) {
                    try results.append(allocator, .{
                        .file_name = try allocator.dupe(u8, file.name),
                        .line_number = line_num,
                        .content = try allocator.dupe(u8, ""),
                        .tree_name = try allocator.dupe(u8, tree_name),
                    });
                }
                break;
            }
        } else break;
    }
}

/// go-git multi-pattern loop (OR for match; invert breaks on first non-match).
fn lineMatches(line: []const u8, patterns: Compiled, invert_match: bool) bool {
    for (patterns.regexes) |*re| {
        const matched = re.matchString(line);
        if (matched) {
            if (!invert_match) return true;
        } else if (invert_match) {
            return true;
        }
    }
    return false;
}

test "lineMatches regex and invert go-git loop" {
    const gpa = std.testing.allocator;
    const c = try compileAll(gpa, &.{"import"});
    defer freeCompiled(gpa, c);
    try std.testing.expect(lineMatches("import \"fmt\"", c, false));
    try std.testing.expect(!lineMatches("package main", c, false));
    try std.testing.expect(!lineMatches("import \"fmt\"", c, true));
    try std.testing.expect(lineMatches("package main", c, true));
}

test "case insensitive pattern" {
    const gpa = std.testing.allocator;
    const c = try compileAll(gpa, &.{"(?i)IMport"});
    defer freeCompiled(gpa, c);
    try std.testing.expect(lineMatches("import x", c, false));
}

test "invalid regex surfaces InvalidRegex" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error_mod.Error.InvalidRegex, compileAll(gpa, &.{"[unterminated"}));
}

test "pathMatches regex pathspec" {
    const gpa = std.testing.allocator;
    const specs = try compileAll(gpa, &.{"go/"});
    defer freeCompiled(gpa, specs);
    try std.testing.expect(pathMatches("src/go/main.go", specs));
    try std.testing.expect(!pathMatches("src/vendor/x", specs));
}
