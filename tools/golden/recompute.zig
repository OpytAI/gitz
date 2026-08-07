//! Recompute committed Class A golden `expected.txt` files from library APIs.
//!
//! Loads each suite's expected dump via Bazel runfiles (`data/goldens/...`) and
//! rebuilds the same non-comment payload from pure Zig. A mismatch means a
//! library regression or a stale golden.

const std = @import("std");
const Allocator = std.mem.Allocator;

const utils_diff = @import("diff");
const pathutil = @import("pathutil");
const revision = @import("revision");
const format_diff = @import("format_diff");
const gitignore = @import("gitignore");
const gitattributes = @import("gitattributes");
const merkletrie = @import("merkletrie");
const fsnoder = @import("fsnoder");
const plumbing = @import("plumbing");
const filemode = @import("filemode");

// ---------------------------------------------------------------------------
// Expected fixtures (generated vectors.zig from data/goldens/**/expected.txt)
// ---------------------------------------------------------------------------

const vectors = @import("golden_vectors");

fn expectedFor(comptime suite: []const u8) []const u8 {
    return @field(vectors, suite);
}

fn payloadLines(allocator: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    return try out.toOwnedSlice(allocator);
}

fn expectPayload(computed: []const u8, expected_file: []const u8) !void {
    const gpa = std.testing.allocator;
    const a = try payloadLines(gpa, expected_file);
    defer gpa.free(a);
    const b = try payloadLines(gpa, computed);
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
}

fn appendFmt(out: *std.ArrayList(u8), allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try out.appendSlice(allocator, s);
}

// ---------------------------------------------------------------------------
// diff_do_equal
// ---------------------------------------------------------------------------

fn unescapeNl(allocator: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len and s[i + 1] == 'n') {
            try out.append(allocator, '\n');
            i += 1;
        } else try out.append(allocator, s[i]);
    }
    return try out.toOwnedSlice(allocator);
}

fn escapeNl(allocator: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (s) |c| {
        if (c == '\n') try out.appendSlice(allocator, "\\n") else try out.append(allocator, c);
    }
    return try out.toOwnedSlice(allocator);
}

fn recomputeDiffDoEqual(allocator: Allocator, expected: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var src_esc: ?[]const u8 = null;
    var dst_esc: ?[]const u8 = null;
    var in_case = false;

    var lines = std.mem.splitScalar(u8, expected, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "case:")) {
            if (in_case and src_esc != null and dst_esc != null) {
                try emitDiffCase(&out, allocator, src_esc.?, dst_esc.?);
            }
            in_case = true;
            src_esc = null;
            dst_esc = null;
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        } else if (std.mem.startsWith(u8, line, "src:")) {
            src_esc = line["src:".len..];
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        } else if (std.mem.startsWith(u8, line, "dst:")) {
            dst_esc = line["dst:".len..];
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        } else if (std.mem.startsWith(u8, line, "ops:") or std.mem.startsWith(u8, line, "text")) {
            continue;
        } else {
            if (in_case and src_esc != null and dst_esc != null and (line.len == 0 or line[0] == '#')) {
                try emitDiffCase(&out, allocator, src_esc.?, dst_esc.?);
                in_case = false;
                src_esc = null;
                dst_esc = null;
            }
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
    }
    if (in_case and src_esc != null and dst_esc != null) {
        try emitDiffCase(&out, allocator, src_esc.?, dst_esc.?);
    }
    return try out.toOwnedSlice(allocator);
}

fn emitDiffCase(out: *std.ArrayList(u8), allocator: Allocator, src_esc: []const u8, dst_esc: []const u8) !void {
    const src = try unescapeNl(allocator, src_esc);
    defer allocator.free(src);
    const dst = try unescapeNl(allocator, dst_esc);
    defer allocator.free(dst);
    const diffs = try utils_diff.do(allocator, src, dst);
    defer utils_diff.freeDiffs(allocator, diffs);

    try out.appendSlice(allocator, "ops:");
    for (diffs, 0..) |d, i| {
        if (i > 0) try out.append(allocator, ',');
        try appendFmt(out, allocator, "{d}", .{@intFromEnum(d.operation)});
    }
    try out.append(allocator, '\n');
    for (diffs, 0..) |d, i| {
        const esc = try escapeNl(allocator, d.text);
        defer allocator.free(esc);
        try appendFmt(out, allocator, "text{d}:{s}\n", .{ i, esc });
    }
}

test "recompute diff_do_equal" {
    const gpa = std.testing.allocator;
    const expected = expectedFor("diff_do_equal");
    const computed = try recomputeDiffDoEqual(gpa, expected);
    defer gpa.free(computed);
    try expectPayload(computed, expected);
}

// ---------------------------------------------------------------------------
// pathutil_ntfs_dotgit
// ---------------------------------------------------------------------------

fn recomputePathutilNtfs(allocator: Allocator, expected: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, expected, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            continue;
        }
        if (std.mem.startsWith(u8, line, "IsNTFSDotGit\"")) {
            const rest = line["IsNTFSDotGit\"".len..];
            const endq = std.mem.lastIndexOfScalar(u8, rest, '"') orelse return error.BadGolden;
            const name = rest[0..endq];
            try appendFmt(&out, allocator, "IsNTFSDotGit\"{s}\"{s}\n", .{ name, if (pathutil.isNTFSDotGit(name)) "true" else "false" });
        } else if (std.mem.startsWith(u8, line, "WindowsValidPath\"")) {
            const rest = line["WindowsValidPath\"".len..];
            const endq = std.mem.lastIndexOfScalar(u8, rest, '"') orelse return error.BadGolden;
            const name = rest[0..endq];
            try appendFmt(&out, allocator, "WindowsValidPath\"{s}\"{s}\n", .{ name, if (pathutil.windowsValidPath(name)) "true" else "false" });
        } else {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
    }
    return try out.toOwnedSlice(allocator);
}

test "recompute pathutil_ntfs_dotgit" {
    const gpa = std.testing.allocator;
    const expected = expectedFor("pathutil_ntfs_dotgit");
    const computed = try recomputePathutilNtfs(gpa, expected);
    defer gpa.free(computed);
    try expectPayload(computed, expected);
}

// ---------------------------------------------------------------------------
// pathutil_tree_reject
// ---------------------------------------------------------------------------

fn decodeQuotedPath(allocator: Allocator, inner: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '\\' and i + 1 < inner.len) {
            const n = inner[i + 1];
            if (n == 'x' and i + 3 < inner.len) {
                const byte = try std.fmt.parseInt(u8, inner[i + 2 .. i + 4], 16);
                try out.append(allocator, byte);
                i += 3;
            } else if (n == 'u' and i + 5 < inner.len) {
                const cp = try std.fmt.parseInt(u21, inner[i + 2 .. i + 6], 16);
                var buf: [4]u8 = undefined;
                const len = try std.unicode.utf8Encode(cp, &buf);
                try out.appendSlice(allocator, buf[0..len]);
                i += 5;
            } else {
                try out.append(allocator, n);
                i += 1;
            }
        } else {
            try out.append(allocator, inner[i]);
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn recomputeTreeReject(allocator: Allocator, expected: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, expected, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            continue;
        }
        if (line[0] != '"') {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            continue;
        }
        const endq = std.mem.lastIndexOfScalar(u8, line, '"') orelse return error.BadGolden;
        const inner = line[1..endq];
        const path = try decodeQuotedPath(allocator, inner);
        defer allocator.free(path);
        const is_err = if (pathutil.validTreePath(path)) |_| false else |_| true;
        // Preserve original quoted spelling; recompute only wantErr.
        try appendFmt(&out, allocator, "\"{s}\"\t{s}\n", .{ inner, if (is_err) "true" else "false" });
    }
    return try out.toOwnedSlice(allocator);
}

test "recompute pathutil_tree_reject" {
    const gpa = std.testing.allocator;
    const expected = expectedFor("pathutil_tree_reject");
    const computed = try recomputeTreeReject(gpa, expected);
    defer gpa.free(computed);
    try expectPayload(computed, expected);
}

// ---------------------------------------------------------------------------
// gitignore_simple
// ---------------------------------------------------------------------------

fn recomputeGitignore(allocator: Allocator, expected: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, expected, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            continue;
        }
        var cols = std.mem.splitScalar(u8, line, '\t');
        const pat = cols.next() orelse return error.BadGolden;
        const path_s = cols.next() orelse return error.BadGolden;
        const is_dir_s = cols.next() orelse return error.BadGolden;
        _ = cols.next();

        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(allocator);
        var pit = std.mem.splitScalar(u8, path_s, '/');
        while (pit.next()) |p| {
            if (p.len > 0) try parts.append(allocator, p);
        }
        var pattern = try gitignore.parsePattern(allocator, pat, &.{});
        defer pattern.deinit();
        const res = pattern.match(parts.items, std.mem.eql(u8, is_dir_s, "true"));
        const res_s: []const u8 = switch (res) {
            .include => "include",
            .exclude => "exclude",
            .no_match => "no_match",
        };
        try appendFmt(&out, allocator, "{s}\t{s}\t{s}\t{s}\n", .{ pat, path_s, is_dir_s, res_s });
    }
    return try out.toOwnedSlice(allocator);
}

test "recompute gitignore_simple" {
    const gpa = std.testing.allocator;
    const expected = expectedFor("gitignore_simple");
    const computed = try recomputeGitignore(gpa, expected);
    defer gpa.free(computed);
    try expectPayload(computed, expected);
}

// ---------------------------------------------------------------------------
// gitattributes_simple
// ---------------------------------------------------------------------------

fn recomputeGitattributes(allocator: Allocator, expected: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, expected, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            continue;
        }
        var cols = std.mem.splitScalar(u8, line, '\t');
        const pat = cols.next() orelse return error.BadGolden;
        const domain_s = cols.next() orelse return error.BadGolden;
        const path_s = cols.next() orelse return error.BadGolden;
        _ = cols.next();

        var domain: std.ArrayList([]const u8) = .empty;
        defer domain.deinit(allocator);
        if (domain_s.len > 0) {
            var dit = std.mem.splitScalar(u8, domain_s, '/');
            while (dit.next()) |p| {
                if (p.len > 0) try domain.append(allocator, p);
            }
        }
        var path_parts: std.ArrayList([]const u8) = .empty;
        defer path_parts.deinit(allocator);
        var pit = std.mem.splitScalar(u8, path_s, '/');
        while (pit.next()) |p| {
            if (p.len > 0) try path_parts.append(allocator, p);
        }

        var pattern = try gitattributes.parsePattern(allocator, pat, domain.items);
        defer pattern.deinit();
        const matched = pattern.match(path_parts.items);
        try appendFmt(&out, allocator, "{s}\t{s}\t{s}\t{s}\n", .{
            pat,
            domain_s,
            path_s,
            if (matched) "match" else "no_match",
        });
    }
    return try out.toOwnedSlice(allocator);
}

test "recompute gitattributes_simple" {
    const gpa = std.testing.allocator;
    const expected = expectedFor("gitattributes_simple");
    const computed = try recomputeGitattributes(gpa, expected);
    defer gpa.free(computed);
    try expectPayload(computed, expected);
}

// ---------------------------------------------------------------------------
// revision_parse
// ---------------------------------------------------------------------------

fn formatRev(allocator: Allocator, r: revision.Revisioner) ![]u8 {
    return switch (r) {
        .ref => |v| try std.fmt.allocPrint(allocator, "Ref:{s}", .{v.name}),
        .tilde_path => |v| try std.fmt.allocPrint(allocator, "TildePath:{d}", .{v.depth}),
        .caret_path => |v| try std.fmt.allocPrint(allocator, "CaretPath:{d}", .{v.depth}),
        .caret_reg => |v| try std.fmt.allocPrint(allocator, "CaretReg:{s}", .{v.pattern}),
        .caret_type => |v| try std.fmt.allocPrint(allocator, "CaretType:{s}", .{v.object_type}),
        .at_reflog => |v| try std.fmt.allocPrint(allocator, "AtReflog:{d}", .{v.depth}),
        .at_checkout => |v| try std.fmt.allocPrint(allocator, "AtCheckout:{d}", .{v.depth}),
        .at_upstream => |v| if (v.branch_name.len == 0)
            try allocator.dupe(u8, "AtUpstream:")
        else
            try std.fmt.allocPrint(allocator, "AtUpstream:{s}", .{v.branch_name}),
        .at_push => |v| if (v.branch_name.len == 0)
            try allocator.dupe(u8, "AtPush:")
        else
            try std.fmt.allocPrint(allocator, "AtPush:{s}", .{v.branch_name}),
        .at_date => |v| try std.fmt.allocPrint(allocator, "AtDate:{d}", .{v.unix_seconds}),
        .colon_reg => |v| try std.fmt.allocPrint(allocator, "ColonReg:{s}", .{v.pattern}),
        .colon_path => |v| try std.fmt.allocPrint(allocator, "ColonPath:{s}", .{v.path}),
        .colon_stage_path => |v| try std.fmt.allocPrint(allocator, "ColonStagePath:{s}:{d}", .{ v.path, v.stage }),
    };
}

fn isComponentLine(line: []const u8) bool {
    if (std.mem.startsWith(u8, line, "components:")) return true;
    if (std.mem.startsWith(u8, line, "error:")) return true;
    const tags = [_][]const u8{ "Ref:", "TildePath:", "CaretPath:", "CaretReg:", "CaretType:", "AtReflog:", "AtCheckout:", "AtUpstream:", "AtPush:", "AtDate:", "ColonReg:", "ColonPath:", "ColonStagePath:" };
    for (tags) |t| {
        if (std.mem.startsWith(u8, line, t)) return true;
    }
    return false;
}

fn recomputeRevision(allocator: Allocator, expected: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var pending: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, expected, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            if (pending) |rev| {
                try emitRev(&out, allocator, rev);
                pending = null;
            }
            try out.append(allocator, '\n');
            continue;
        }
        if (line[0] == '#') {
            if (pending) |rev| {
                try emitRev(&out, allocator, rev);
                pending = null;
            }
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            continue;
        }
        if (isComponentLine(line)) continue;

        if (pending) |rev| {
            try emitRev(&out, allocator, rev);
        }
        pending = line;
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    if (pending) |rev| try emitRev(&out, allocator, rev);
    return try out.toOwnedSlice(allocator);
}

fn emitRev(out: *std.ArrayList(u8), allocator: Allocator, input: []const u8) !void {
    var p = revision.newParserFromString(allocator, input);
    defer p.deinit();
    const revs = p.parse() catch {
        try appendFmt(out, allocator, "error:{s}\n", .{p.invalidRevision().reason});
        return;
    };
    defer revision.freeRevisioners(allocator, revs);
    try appendFmt(out, allocator, "components:{d}\n", .{revs.len});
    for (revs) |r| {
        const s = try formatRev(allocator, r);
        defer allocator.free(s);
        try out.appendSlice(allocator, s);
        try out.append(allocator, '\n');
    }
}

test "recompute revision_parse" {
    const gpa = std.testing.allocator;
    const expected = expectedFor("revision_parse");
    const computed = try recomputeRevision(gpa, expected);
    defer gpa.free(computed);
    try expectPayload(computed, expected);
}

// ---------------------------------------------------------------------------
// unified_diff_one_line
// ---------------------------------------------------------------------------

test "recompute unified_diff_one_line" {
    const gpa = std.testing.allocator;
    const expected = expectedFor("unified_diff_one_line");

    const old_c = "hello\nworld\n";
    const new_c = "hello\nbug\n";
    const old_h = plumbing.computeHash(.blob, old_c);
    const new_h = plumbing.computeHash(.blob, new_c);

    const diffs = try utils_diff.do(gpa, old_c, new_c);
    defer utils_diff.freeDiffs(gpa, diffs);

    const chunks = try gpa.alloc(format_diff.Chunk, diffs.len);
    defer gpa.free(chunks);
    for (diffs, chunks) |d, *ch| {
        ch.* = .{
            .content = d.text,
            .op = switch (d.operation) {
                .equal => .equal,
                .insert => .add,
                .delete => .delete,
            },
        };
    }

    var fps = [_]format_diff.FilePatch{.{
        .from = .{ .path = "README.md", .mode = filemode.Regular, .hash = old_h },
        .to = .{ .path = "README.md", .mode = filemode.Regular, .hash = new_h },
        .chunks = chunks,
    }};
    const patch = format_diff.Patch{ .file_patches = fps[0..] };

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = format_diff.UnifiedEncoder.init(gpa, &aw.writer, format_diff.DefaultContextLines);
    try enc.encode(patch);
    const got = try aw.toOwnedSlice();
    defer gpa.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

// ---------------------------------------------------------------------------
// merkletrie suites
// ---------------------------------------------------------------------------

fn actionChar(act: merkletrie.Action) u8 {
    return switch (act) {
        .insert => '+',
        .delete => '-',
        .modify => '*',
    };
}

fn recomputeMerkle(allocator: Allocator, expected: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var from_s: ?[]const u8 = null;
    var to_s: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, expected, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "from:")) {
            from_s = line["from:".len..];
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        } else if (std.mem.startsWith(u8, line, "to:")) {
            to_s = line["to:".len..];
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        } else if (std.mem.startsWith(u8, line, "changes:") or
            std.mem.startsWith(u8, line, "actions:") or
            std.mem.startsWith(u8, line, "names:"))
        {
            continue;
        } else if (line.len == 0 or line[0] == '#') {
            if (from_s != null and to_s != null) {
                try emitMerkle(&out, allocator, from_s.?, to_s.?);
                from_s = null;
                to_s = null;
            }
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        } else if (line[0] == '<') {
            // NewInsert/NewDelete/NewModify string dumps — skip in recompute path.
            continue;
        } else {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
    }
    if (from_s != null and to_s != null) {
        try emitMerkle(&out, allocator, from_s.?, to_s.?);
    }
    return try out.toOwnedSlice(allocator);
}

fn emitMerkle(out: *std.ArrayList(u8), allocator: Allocator, from_s: []const u8, to_s: []const u8) !void {
    var from = try fsnoder.New(allocator, from_s);
    defer from.deinit(allocator);
    var to = try fsnoder.New(allocator, to_s);
    defer to.deinit(allocator);

    var changes = try merkletrie.diffTree(allocator, from.noder(), to.noder(), fsnoder.hashEqual);
    defer changes.deinit();

    // Collect path + action, sort by path so golden order is stable regardless
    // of DiffTree enumeration order.
    const Entry = struct { path: []u8, act: u8 };
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |e| allocator.free(e.path);
        entries.deinit(allocator);
    }
    for (changes.items.items) |*c| {
        const act = try c.action();
        const full = switch (act) {
            .insert => try c.to.?.string(allocator),
            .delete => try c.from.?.string(allocator),
            .modify => try c.to.?.string(allocator),
        };
        try entries.append(allocator, .{ .path = full, .act = actionChar(act) });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.less);

    try appendFmt(out, allocator, "changes:{d}\n", .{entries.items.len});
    try out.appendSlice(allocator, "actions:");
    for (entries.items, 0..) |e, i| {
        if (i > 0) try out.append(allocator, ' ');
        try appendFmt(out, allocator, "{c}{s}", .{ e.act, e.path });
    }
    try out.append(allocator, '\n');

    // Empty DiffTree cases omit names: (see merkletrie_empty golden).
    if (entries.items.len > 0) {
        try out.appendSlice(allocator, "names:");
        for (entries.items, 0..) |e, i| {
            if (i > 0) try out.append(allocator, ',');
            try out.appendSlice(allocator, e.path);
        }
        try out.append(allocator, '\n');
    }
}

fn merklePayload(allocator: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#' or line[0] == '<') continue;
        if (std.mem.startsWith(u8, line, "NewDelete:") or
            std.mem.startsWith(u8, line, "NewInsert:") or
            std.mem.startsWith(u8, line, "NewModify:") or
            std.mem.startsWith(u8, line, "string:"))
            continue;
        // Normalize action token order on actions: lines for comparison.
        if (std.mem.startsWith(u8, line, "actions:")) {
            const rest = line["actions:".len..];
            var toks: std.ArrayList([]const u8) = .empty;
            defer toks.deinit(allocator);
            var tit = std.mem.tokenizeScalar(u8, rest, ' ');
            while (tit.next()) |t| try toks.append(allocator, t);
            std.mem.sort([]const u8, toks.items, {}, struct {
                fn less(_: void, a: []const u8, b: []const u8) bool {
                    // Sort by path (skip leading +/-/*).
                    const ap = if (a.len > 0) a[1..] else a;
                    const bp = if (b.len > 0) b[1..] else b;
                    return std.mem.order(u8, ap, bp) == .lt;
                }
            }.less);
            try out.appendSlice(allocator, "actions:");
            for (toks.items, 0..) |t, i| {
                if (i > 0) try out.append(allocator, ' ');
                try out.appendSlice(allocator, t);
            }
            try out.append(allocator, '\n');
            continue;
        }
        if (std.mem.startsWith(u8, line, "names:")) {
            const rest = line["names:".len..];
            var toks: std.ArrayList([]const u8) = .empty;
            defer toks.deinit(allocator);
            var tit = std.mem.splitScalar(u8, rest, ',');
            while (tit.next()) |t| {
                if (t.len > 0) try toks.append(allocator, t);
            }
            std.mem.sort([]const u8, toks.items, {}, struct {
                fn less(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.less);
            try out.appendSlice(allocator, "names:");
            for (toks.items, 0..) |t, i| {
                if (i > 0) try out.append(allocator, ',');
                try out.appendSlice(allocator, t);
            }
            try out.append(allocator, '\n');
            continue;
        }
        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }
    return try out.toOwnedSlice(allocator);
}

fn expectMerkle(computed: []const u8, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    const a = try merklePayload(gpa, expected);
    defer gpa.free(a);
    const b = try merklePayload(gpa, computed);
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test "recompute merkletrie_empty" {
    const gpa = std.testing.allocator;
    const expected = expectedFor("merkletrie_empty");
    const computed = try recomputeMerkle(gpa, expected);
    defer gpa.free(computed);
    try expectMerkle(computed, expected);
}

test "recompute merkletrie_insert" {
    const gpa = std.testing.allocator;
    const expected = expectedFor("merkletrie_insert");
    const computed = try recomputeMerkle(gpa, expected);
    defer gpa.free(computed);
    try expectMerkle(computed, expected);
}

test "recompute merkletrie_modify_delete" {
    const gpa = std.testing.allocator;
    const expected = expectedFor("merkletrie_modify_delete");
    const computed = try recomputeMerkle(gpa, expected);
    defer gpa.free(computed);
    try expectMerkle(computed, expected);
}
