//! UnifiedEncoder — port of go-git `plumbing/format/diff/unified_encoder.go`.
//!
//! Encodes a unified diff into the provided writer. Does not support similarity
//! index for renames or sorting hash representations.

const std = @import("std");
const plumbing = @import("plumbing");
const color_mod = @import("color");

const patch_mod = @import("patch.zig");
const colorconfig = @import("colorconfig.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Operation = patch_mod.Operation;
pub const File = patch_mod.File;
pub const Chunk = patch_mod.Chunk;
pub const FilePatch = patch_mod.FilePatch;
pub const Patch = patch_mod.Patch;
pub const ColorConfig = colorconfig.ColorConfig;
pub const ColorKey = colorconfig.ColorKey;

/// DefaultContextLines is the default number of context lines.
pub const default_context_lines: usize = 3;
/// go-git `DefaultContextLines` alias.
pub const DefaultContextLines = default_context_lines;

const operation_char = [_]u8{
    ' ', // equal
    '+', // add
    '-', // delete
};

fn operationColorKey(op: Operation) ColorKey {
    return switch (op) {
        .add => .new,
        .delete => .old,
        .equal => .context,
    };
}

/// UnifiedEncoder encodes a unified diff into the provided Writer.
pub const UnifiedEncoder = struct {
    w: *Writer,
    allocator: Allocator,
    /// Count of unchanged lines that will appear surrounding a change.
    context_lines: usize,
    /// Prepended to source file paths when encoding a diff.
    src_prefix: []const u8 = "a/",
    /// Prepended to destination file paths when encoding a diff.
    dst_prefix: []const u8 = "b/",
    /// Color configuration. Default is no color.
    color: ColorConfig = .{},

    /// go-git `NewUnifiedEncoder`.
    pub fn init(allocator: Allocator, w: *Writer, context_lines: usize) UnifiedEncoder {
        return .{
            .w = w,
            .allocator = allocator,
            .context_lines = context_lines,
        };
    }

    /// Set color configuration and return self (go-git `SetColor`).
    pub fn setColor(self: *UnifiedEncoder, color_config: ColorConfig) *UnifiedEncoder {
        self.color = color_config;
        return self;
    }

    /// Set srcPrefix and return self (go-git `SetSrcPrefix`).
    pub fn setSrcPrefix(self: *UnifiedEncoder, prefix: []const u8) *UnifiedEncoder {
        self.src_prefix = prefix;
        return self;
    }

    /// Set dstPrefix and return self (go-git `SetDstPrefix`).
    pub fn setDstPrefix(self: *UnifiedEncoder, prefix: []const u8) *UnifiedEncoder {
        self.dst_prefix = prefix;
        return self;
    }

    /// Encode patch (go-git `Encode`).
    pub fn encode(self: *UnifiedEncoder, patch: Patch) !void {
        if (patch.message.len > 0) {
            try self.w.writeAll(patch.message);
            if (patch.message[patch.message.len - 1] != '\n') {
                try self.w.writeByte('\n');
            }
        }

        for (patch.file_patches) |fp| {
            try self.writeFilePatchHeader(fp);
            var gen = HunksGenerator.init(self.allocator, fp.chunks, self.context_lines);
            defer gen.deinit();
            const hunks = try gen.generate();
            for (hunks) |h| {
                try h.writeTo(self.w, self.color);
            }
        }
    }

    fn writeFilePatchHeader(self: *UnifiedEncoder, file_patch: FilePatch) !void {
        const from = file_patch.from;
        const to = file_patch.to;
        if (from == null and to == null) return;

        const is_binary = file_patch.is_binary;
        var lines: std.ArrayList([]const u8) = .empty;
        defer {
            for (lines.items) |line| self.allocator.free(line);
            lines.deinit(self.allocator);
        }

        if (from != null and to != null) {
            const f = from.?;
            const t = to.?;
            const hash_equals = f.hash.eql(t.hash);

            try lines.append(self.allocator, try std.fmt.allocPrint(
                self.allocator,
                "diff --git {s}{s} {s}{s}",
                .{ self.src_prefix, f.path, self.dst_prefix, t.path },
            ));

            if (f.mode != t.mode) {
                try lines.append(self.allocator, try std.fmt.allocPrint(
                    self.allocator,
                    "old mode {o}",
                    .{f.mode},
                ));
                try lines.append(self.allocator, try std.fmt.allocPrint(
                    self.allocator,
                    "new mode {o}",
                    .{t.mode},
                ));
            }
            if (!std.mem.eql(u8, f.path, t.path)) {
                try lines.append(self.allocator, try std.fmt.allocPrint(
                    self.allocator,
                    "rename from {s}",
                    .{f.path},
                ));
                try lines.append(self.allocator, try std.fmt.allocPrint(
                    self.allocator,
                    "rename to {s}",
                    .{t.path},
                ));
            }

            if (f.mode != t.mode and !hash_equals) {
                var fh: [plumbing.HexSize]u8 = undefined;
                var th: [plumbing.HexSize]u8 = undefined;
                try lines.append(self.allocator, try std.fmt.allocPrint(
                    self.allocator,
                    "index {s}..{s}",
                    .{ f.hash.string(&fh), t.hash.string(&th) },
                ));
            } else if (!hash_equals) {
                var fh: [plumbing.HexSize]u8 = undefined;
                var th: [plumbing.HexSize]u8 = undefined;
                try lines.append(self.allocator, try std.fmt.allocPrint(
                    self.allocator,
                    "index {s}..{s} {o}",
                    .{ f.hash.string(&fh), t.hash.string(&th), f.mode },
                ));
            }

            if (!hash_equals) {
                try self.appendPathLines(
                    &lines,
                    try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.src_prefix, f.path }),
                    try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.dst_prefix, t.path }),
                    is_binary,
                );
            }
        } else if (from == null) {
            const t = to.?;
            var th: [plumbing.HexSize]u8 = undefined;
            var zh: [plumbing.HexSize]u8 = undefined;
            try lines.append(self.allocator, try std.fmt.allocPrint(
                self.allocator,
                "diff --git {s}{s} {s}{s}",
                .{ self.src_prefix, t.path, self.dst_prefix, t.path },
            ));
            try lines.append(self.allocator, try std.fmt.allocPrint(
                self.allocator,
                "new file mode {o}",
                .{t.mode},
            ));
            try lines.append(self.allocator, try std.fmt.allocPrint(
                self.allocator,
                "index {s}..{s}",
                .{ plumbing.ZeroHash.string(&zh), t.hash.string(&th) },
            ));
            try self.appendPathLines(
                &lines,
                try self.allocator.dupe(u8, "/dev/null"),
                try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.dst_prefix, t.path }),
                is_binary,
            );
        } else {
            const f = from.?;
            var fh: [plumbing.HexSize]u8 = undefined;
            var zh: [plumbing.HexSize]u8 = undefined;
            try lines.append(self.allocator, try std.fmt.allocPrint(
                self.allocator,
                "diff --git {s}{s} {s}{s}",
                .{ self.src_prefix, f.path, self.dst_prefix, f.path },
            ));
            try lines.append(self.allocator, try std.fmt.allocPrint(
                self.allocator,
                "deleted file mode {o}",
                .{f.mode},
            ));
            try lines.append(self.allocator, try std.fmt.allocPrint(
                self.allocator,
                "index {s}..{s}",
                .{ f.hash.string(&fh), plumbing.ZeroHash.string(&zh) },
            ));
            try self.appendPathLines(
                &lines,
                try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.src_prefix, f.path }),
                try self.allocator.dupe(u8, "/dev/null"),
                is_binary,
            );
        }

        try self.w.writeAll(self.color.get(.meta));
        try self.w.writeAll(lines.items[0]);
        for (lines.items[1..]) |line| {
            try self.w.writeByte('\n');
            try self.w.writeAll(line);
        }
        try self.w.writeAll(self.color.reset(.meta));
        try self.w.writeByte('\n');
    }

    fn appendPathLines(
        self: *UnifiedEncoder,
        lines: *std.ArrayList([]const u8),
        from_path: []const u8,
        to_path: []const u8,
        is_binary: bool,
    ) !void {
        // from_path and to_path are owned; consume into lines.
        if (is_binary) {
            const line = try std.fmt.allocPrint(
                self.allocator,
                "Binary files {s} and {s} differ",
                .{ from_path, to_path },
            );
            self.allocator.free(from_path);
            self.allocator.free(to_path);
            try lines.append(self.allocator, line);
            return;
        }
        const from_line = try std.fmt.allocPrint(self.allocator, "--- {s}", .{from_path});
        const to_line = try std.fmt.allocPrint(self.allocator, "+++ {s}", .{to_path});
        self.allocator.free(from_path);
        self.allocator.free(to_path);
        try lines.append(self.allocator, from_line);
        try lines.append(self.allocator, to_line);
    }
};

/// go-git `NewUnifiedEncoder`.
pub fn newUnifiedEncoder(allocator: Allocator, w: *Writer, context_lines: usize) UnifiedEncoder {
    return UnifiedEncoder.init(allocator, w, context_lines);
}

// ---------------------------------------------------------------------------
// Hunk generation (faithful port of go-git hunksGenerator / hunk / op)
// ---------------------------------------------------------------------------
//
// Ownership model (matches go-git *hunk):
// - Op.text and context arrays are slices into Chunk.content (stable for Encode).
// - splitLines allocates only the slice table; elements point into content.
// - After copying those fat-pointers into context/ops, the table may be freed.
// - Hunk is always heap-allocated (*Hunk) so ArrayList(Op) is never bitwise-copied
//   as part of a by-value optional or ArrayList growth of Hunk structs.

const Op = struct {
    text: []const u8,
    t: Operation,
};

const Hunk = struct {
    from_line: isize = 0,
    to_line: isize = 0,
    from_count: isize = 0,
    to_count: isize = 0,
    /// Function context line (trailing newline already stripped). Slice into content.
    ctx_prefix: []const u8 = "",
    ops: std.ArrayList(Op) = .empty,
    allocator: Allocator,

    fn create(allocator: Allocator) !*Hunk {
        const h = try allocator.create(Hunk);
        h.* = .{
            .ops = .empty,
            .allocator = allocator,
        };
        return h;
    }

    fn destroy(self: *Hunk) void {
        self.ops.deinit(self.allocator);
        const a = self.allocator;
        a.destroy(self);
    }

    fn addOp(self: *Hunk, t: Operation, ss: []const []const u8) !void {
        const n: isize = @intCast(ss.len);
        switch (t) {
            .add => self.to_count += n,
            .delete => self.from_count += n,
            .equal => {
                self.to_count += n;
                self.from_count += n;
            },
        }
        for (ss) |s| {
            try self.ops.append(self.allocator, .{ .text = s, .t = t });
        }
    }

    fn writeTo(self: *const Hunk, w: *Writer, cc: ColorConfig) !void {
        try w.writeAll(cc.get(.frag));
        try w.writeAll("@@ -");

        var num_buf: [64]u8 = undefined;
        if (self.from_count == 1) {
            const s = try std.fmt.bufPrint(&num_buf, "{d}", .{self.from_line});
            try w.writeAll(s);
        } else {
            const s = try std.fmt.bufPrint(&num_buf, "{d},{d}", .{ self.from_line, self.from_count });
            try w.writeAll(s);
        }

        try w.writeAll(" +");

        if (self.to_count == 1) {
            const s = try std.fmt.bufPrint(&num_buf, "{d}", .{self.to_line});
            try w.writeAll(s);
        } else {
            const s = try std.fmt.bufPrint(&num_buf, "{d},{d}", .{ self.to_line, self.to_count });
            try w.writeAll(s);
        }

        try w.writeAll(" @@");
        try w.writeAll(cc.reset(.frag));

        if (self.ctx_prefix.len > 0) {
            try w.writeByte(' ');
            try w.writeAll(cc.get(.func));
            try w.writeAll(self.ctx_prefix);
            try w.writeAll(cc.reset(.func));
        }

        try w.writeByte('\n');

        for (self.ops.items) |op| {
            try writeOp(w, cc, op);
        }
    }
};

fn writeOp(w: *Writer, cc: ColorConfig, o: Op) !void {
    const color_key = operationColorKey(o.t);
    try w.writeAll(cc.get(color_key));
    try w.writeByte(operation_char[@intFromEnum(o.t)]);
    if (std.mem.endsWith(u8, o.text, "\n")) {
        try w.writeAll(o.text[0 .. o.text.len - 1]);
    } else {
        try w.writeAll(o.text);
        try w.writeAll("\n\\ No newline at end of file");
    }
    try w.writeAll(cc.reset(color_key));
    try w.writeByte('\n');
}

const HunksGenerator = struct {
    from_line: isize = 0,
    to_line: isize = 0,
    ctx_lines: usize,
    chunks: []const Chunk,
    /// go-git `current *hunk` — always heap-allocated when non-null.
    current: ?*Hunk = null,
    hunks: std.ArrayList(*Hunk) = .empty,
    /// Line slices into chunk content (not owned strings).
    before_context: std.ArrayList([]const u8) = .empty,
    after_context: std.ArrayList([]const u8) = .empty,
    allocator: Allocator,

    fn init(allocator: Allocator, chunks: []const Chunk, ctx_lines: usize) HunksGenerator {
        return .{
            .ctx_lines = ctx_lines,
            .chunks = chunks,
            .allocator = allocator,
        };
    }

    fn deinit(self: *HunksGenerator) void {
        if (self.current) |c| c.destroy();
        for (self.hunks.items) |h| h.destroy();
        self.hunks.deinit(self.allocator);
        self.before_context.deinit(self.allocator);
        self.after_context.deinit(self.allocator);
        self.* = undefined;
    }

    fn generate(self: *HunksGenerator) ![]const *Hunk {
        for (self.chunks, 0..) |chunk, i| {
            // Slice table only; elements point into chunk.content (stable).
            const lines = try splitLines(self.allocator, chunk.content);
            defer self.allocator.free(lines);
            const n_lines: isize = @intCast(lines.len);

            switch (chunk.op) {
                .equal => {
                    self.from_line += n_lines;
                    self.to_line += n_lines;
                    try self.processEqualsLines(lines, i);
                },
                .delete => {
                    if (n_lines != 0) {
                        self.from_line += 1;
                    }
                    try self.processHunk(i, chunk.op);
                    self.from_line += n_lines - 1;
                    const cur = self.current orelse return error.UnexpectedEndOfHunk;
                    try cur.addOp(chunk.op, lines);
                },
                .add => {
                    if (n_lines != 0) {
                        self.to_line += 1;
                    }
                    try self.processHunk(i, chunk.op);
                    self.to_line += n_lines - 1;
                    const cur = self.current orelse return error.UnexpectedEndOfHunk;
                    try cur.addOp(chunk.op, lines);
                },
            }

            if (i == self.chunks.len - 1) {
                if (self.current) |cur| {
                    try self.hunks.append(self.allocator, cur);
                    self.current = null;
                }
            }
        }
        return self.hunks.items;
    }

    fn processHunk(self: *HunksGenerator, i: usize, op: Operation) !void {
        if (self.current != null) return;

        var ctx_prefix: []const u8 = "";
        var lines_before: usize = self.before_context.items.len;
        if (lines_before > self.ctx_lines) {
            // go-git: ctxPrefix = beforeContext[linesBefore-ctxLines-1]
            ctx_prefix = self.before_context.items[lines_before - self.ctx_lines - 1];
            // go-git: beforeContext = beforeContext[linesBefore-ctxLines:]
            const start = lines_before - self.ctx_lines;
            const kept = try self.allocator.dupe([]const u8, self.before_context.items[start..]);
            self.before_context.clearRetainingCapacity();
            try self.before_context.appendSlice(self.allocator, kept);
            self.allocator.free(kept);
            lines_before = self.ctx_lines;
        }

        // go-git: strings.TrimSuffix(ctxPrefix, "\n")
        if (std.mem.endsWith(u8, ctx_prefix, "\n")) {
            ctx_prefix = ctx_prefix[0 .. ctx_prefix.len - 1];
        }

        const h = try Hunk.create(self.allocator);
        errdefer h.destroy();
        h.ctx_prefix = ctx_prefix;
        try h.addOp(.equal, self.before_context.items);

        switch (op) {
            .delete => {
                const pair = self.addLineNumbers(self.from_line, self.to_line, lines_before, i, .add);
                h.from_line = pair[0];
                h.to_line = pair[1];
            },
            .add => {
                const pair = self.addLineNumbers(self.to_line, self.from_line, lines_before, i, .delete);
                h.to_line = pair[0];
                h.from_line = pair[1];
            },
            .equal => {},
        }

        self.current = h;
        self.before_context.clearRetainingCapacity();
    }

    /// addLineNumbers obtains the line numbers in a new chunk (go-git).
    fn addLineNumbers(
        self: *const HunksGenerator,
        la: isize,
        lb: isize,
        lines_before: usize,
        i: usize,
        op: Operation,
    ) struct { isize, isize } {
        const cla = la - @as(isize, @intCast(lines_before));
        var clb: isize = 0;
        // switch {
        // case linesBefore != 0 && g.ctxLines != 0: ...
        // case g.ctxLines == 0: clb = lb
        // case i != len(g.chunks)-1: ...
        // }
        if (lines_before != 0 and self.ctx_lines != 0) {
            if (lb > @as(isize, @intCast(self.ctx_lines))) {
                clb = lb - @as(isize, @intCast(self.ctx_lines)) + 1;
            } else {
                clb = 1;
            }
        } else if (self.ctx_lines == 0) {
            clb = lb;
        } else if (i != self.chunks.len - 1) {
            const next = self.chunks[i + 1];
            if (next.op == op or next.op == .equal) {
                clb = lb + 1;
            }
        }
        return .{ cla, clb };
    }

    fn processEqualsLines(self: *HunksGenerator, ls: []const []const u8, i: usize) !void {
        if (self.current == null) {
            try self.before_context.appendSlice(self.allocator, ls);
            return;
        }

        try self.after_context.appendSlice(self.allocator, ls);
        const cur = self.current orelse return error.UnexpectedEndOfHunk;
        if (self.after_context.items.len <= self.ctx_lines * 2 and i != self.chunks.len - 1) {
            // Still in the middle of a change group: fold after-context into the hunk.
            try cur.addOp(.equal, self.after_context.items);
            self.after_context.clearRetainingCapacity();
        } else {
            // Close the hunk: keep only trailing context on the hunk; remainder
            // becomes the next before-context (go-git processEqualsLines else).
            var ctx_n = self.ctx_lines;
            if (ctx_n > self.after_context.items.len) {
                ctx_n = self.after_context.items.len;
            }
            try cur.addOp(.equal, self.after_context.items[0..ctx_n]);
            try self.hunks.append(self.allocator, cur);
            self.current = null;

            const rest = self.after_context.items[ctx_n..];
            self.before_context.clearRetainingCapacity();
            try self.before_context.appendSlice(self.allocator, rest);
            self.after_context.clearRetainingCapacity();
        }
    }
};

/// Split content into lines keeping trailing newlines (go-git `splitLines`).
/// Matches regexp `[^\n]*(\n|$)` with trailing empty match stripped.
///
/// Returned outer slice is allocator-owned. Elements are views into `s` (not owned).
fn splitLines(allocator: Allocator, s: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);

    // go-git: FindAllString; empty s yields one "" match then strip → empty.
    if (s.len == 0) return try list.toOwnedSlice(allocator);

    var start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\n') {
            try list.append(allocator, s[start .. i + 1]);
            start = i + 1;
        }
    }
    if (start < s.len) {
        // Final line without trailing newline (regexp match of `[^\n]*$`).
        try list.append(allocator, s[start..]);
    }
    // When s ends with '\n', Go's FindAllString also produces a trailing "" match
    // from the final `$`; that empty match is stripped. We never append it.
    return try list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests (go-git unified_encoder_test.go)
// ---------------------------------------------------------------------------

const testing = std.testing;
const filemode = @import("filemode");

fn testFile(mode: filemode.FileMode, path: []const u8, seed: []const u8) File {
    return .{
        .hash = plumbing.computeHash(.blob, seed),
        .mode = mode,
        .path = path,
    };
}

fn makePatch(message: []const u8, fps: []const FilePatch) Patch {
    return .{ .message = message, .file_patches = fps };
}

fn encodeToString(allocator: Allocator, context_lines: usize, color_cfg: ColorConfig, src_prefix: ?[]const u8, dst_prefix: ?[]const u8, patch: Patch) ![]u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var e = UnifiedEncoder.init(allocator, &aw.writer, context_lines);
    _ = e.setColor(color_cfg);
    if (src_prefix) |p| _ = e.setSrcPrefix(p);
    if (dst_prefix) |p| _ = e.setDstPrefix(p);
    try e.encode(patch);
    return try aw.toOwnedSlice();
}

const one_chunk_from_seed = "A\nB\nC\nD\nE\nF\nG\nH\nI\nJ\nK\nL\nM\nN\nÑ\nO\nP\nQ\nR\nS\nT\nU\nV\nW\nX\nY\nZ";
const one_chunk_to_seed = "B\nC\nD\nE\nF\nG\nI\nJ\nK\nL\nM\nN\nO\nP\nQ\nR\nS\nT\nV\nW\nX\nY\nZ";

const one_chunk_chunks = [_]Chunk{
    .{ .content = "A\n", .op = .delete },
    .{ .content = "B\nC\nD\nE\nF\nG\n", .op = .equal },
    .{ .content = "H\n", .op = .delete },
    .{ .content = "I\nJ\nK\nL\nM\nN\n", .op = .equal },
    .{ .content = "Ñ\n", .op = .delete },
    .{ .content = "O\nP\nQ\nR\nS\nT\n", .op = .equal },
    .{ .content = "U\n", .op = .delete },
    .{ .content = "V\nW\nX\nY\nZ", .op = .equal },
};

/// Build onechunk patch. Uses a static FilePatch slot so `file_patches` is not a
/// dangling pointer to a temporary array (Zig `&[_]T{...}` in return is UAF).
fn oneChunkPatch() Patch {
    const Holder = struct {
        var buf: [1]FilePatch = undefined;
    };
    Holder.buf[0] = .{
        .from = testFile(filemode.Regular, "onechunk.txt", one_chunk_from_seed),
        .to = testFile(filemode.Regular, "onechunk.txt", one_chunk_to_seed),
        .chunks = &one_chunk_chunks,
    };
    return makePatch("", Holder.buf[0..]);
}

const Fixture = struct {
    desc: []const u8,
    context: usize,
    color: ColorConfig = .{},
    use_color: bool = false,
    diff: []const u8,
    patch: Patch,
};

fn runFixture(f: Fixture) !void {
    const gpa = testing.allocator;
    const color_cfg = if (f.use_color) f.color else ColorConfig{};
    const out = try encodeToString(gpa, f.context, color_cfg, null, null, f.patch);
    defer gpa.free(out);
    try testing.expectEqualStrings(f.diff, out);
}

test "TestBothFilesEmpty" {
    const gpa = testing.allocator;
    const out = try encodeToString(gpa, 1, .{}, null, null, makePatch("", &[_]FilePatch{.{}}));
    defer gpa.free(out);
    try testing.expectEqualStrings("", out);
}

test "TestBinaryFile" {
    const gpa = testing.allocator;
    const fp = FilePatch{
        .from = testFile(filemode.Regular, "binary", "something"),
        .to = testFile(filemode.Regular, "binary", "otherthing"),
        .is_binary = true,
    };
    const out = try encodeToString(gpa, 1, .{}, null, null, makePatch("", &[_]FilePatch{fp}));
    defer gpa.free(out);
    try testing.expectEqualStrings(
        \\diff --git a/binary b/binary
        \\index a459bc245bdbc45e1bca99e7fe61731da5c48da4..6879395eacf3cc7e5634064ccb617ac7aa62be7d 100644
        \\Binary files a/binary and b/binary differ
        \\
    , out);
}

test "positive negative number" {
    const chunks = [_]Chunk{
        .{ .content = "hello\n", .op = .equal },
        .{ .content = "world\n", .op = .delete },
        .{ .content = "bug\n", .op = .add },
    };
    try runFixture(.{
        .desc = "positive negative number",
        .context = 2,
        .diff =
        \\diff --git a/README.md b/README.md
        \\index 94954abda49de8615a048f8d2e64b5de848e27a1..f3dad9514629b9ff9136283ae331ad1fc95748a8 100644
        \\--- a/README.md
        \\+++ b/README.md
        \\@@ -1,2 +1,2 @@
        \\ hello
        \\-world
        \\+bug
        \\
        ,
        .patch = makePatch("", &[_]FilePatch{.{
            .from = testFile(filemode.Regular, "README.md", "hello\nworld\n"),
            .to = testFile(filemode.Regular, "README.md", "hello\nbug\n"),
            .chunks = &chunks,
        }}),
    });
}

test "make executable" {
    try runFixture(.{
        .desc = "make executable",
        .context = 1,
        .diff =
        \\diff --git a/test.txt b/test.txt
        \\old mode 100644
        \\new mode 100755
        \\
        ,
        .patch = makePatch("", &[_]FilePatch{.{
            .from = testFile(filemode.Regular, "test.txt", "test"),
            .to = testFile(filemode.Executable, "test.txt", "test"),
        }}),
    });
}

test "rename file" {
    try runFixture(.{
        .desc = "rename file",
        .context = 1,
        .diff =
        \\diff --git a/test.txt b/test1.txt
        \\rename from test.txt
        \\rename to test1.txt
        \\
        ,
        .patch = makePatch("", &[_]FilePatch{.{
            .from = testFile(filemode.Regular, "test.txt", "test"),
            .to = testFile(filemode.Regular, "test1.txt", "test"),
        }}),
    });
}

test "rename file with changes" {
    const chunks = [_]Chunk{
        .{ .content = "test\n", .op = .delete },
        .{ .content = "test1\n", .op = .add },
    };
    try runFixture(.{
        .desc = "rename file with changes",
        .context = 1,
        .diff =
        \\diff --git a/test.txt b/test1.txt
        \\rename from test.txt
        \\rename to test1.txt
        \\index 9daeafb9864cf43055ae93beb0afd6c7d144bfa4..a5bce3fd2565d8f458555a0c6f42d0504a848bd5 100644
        \\--- a/test.txt
        \\+++ b/test1.txt
        \\@@ -1 +1 @@
        \\-test
        \\+test1
        \\
        ,
        .patch = makePatch("", &[_]FilePatch{.{
            .from = testFile(filemode.Regular, "test.txt", "test\n"),
            .to = testFile(filemode.Regular, "test1.txt", "test1\n"),
            .chunks = &chunks,
        }}),
    });
}

test "rename with file mode change" {
    try runFixture(.{
        .desc = "rename with file mode change",
        .context = 1,
        .diff =
        \\diff --git a/test.txt b/test1.txt
        \\old mode 100644
        \\new mode 100755
        \\rename from test.txt
        \\rename to test1.txt
        \\
        ,
        .patch = makePatch("", &[_]FilePatch{.{
            .from = testFile(filemode.Regular, "test.txt", "test"),
            .to = testFile(filemode.Executable, "test1.txt", "test"),
        }}),
    });
}

test "one line change" {
    const chunks = [_]Chunk{
        .{ .content = "test\n", .op = .delete },
        .{ .content = "test2\n", .op = .add },
    };
    try runFixture(.{
        .desc = "one line change",
        .context = 1,
        .diff =
        \\diff --git a/test.txt b/test.txt
        \\index 9daeafb9864cf43055ae93beb0afd6c7d144bfa4..180cf8328022becee9aaa2577a8f84ea2b9f3827 100644
        \\--- a/test.txt
        \\+++ b/test.txt
        \\@@ -1 +1 @@
        \\-test
        \\+test2
        \\
        ,
        .patch = makePatch("", &[_]FilePatch{.{
            .from = testFile(filemode.Regular, "test.txt", "test\n"),
            .to = testFile(filemode.Regular, "test.txt", "test2\n"),
            .chunks = &chunks,
        }}),
    });
}

test "one line change with message" {
    const chunks = [_]Chunk{
        .{ .content = "test\n", .op = .delete },
        .{ .content = "test2\n", .op = .add },
    };
    try runFixture(.{
        .desc = "one line change with message",
        .context = 1,
        .diff =
        \\this is the message
        \\diff --git a/test.txt b/test.txt
        \\index 9daeafb9864cf43055ae93beb0afd6c7d144bfa4..180cf8328022becee9aaa2577a8f84ea2b9f3827 100644
        \\--- a/test.txt
        \\+++ b/test.txt
        \\@@ -1 +1 @@
        \\-test
        \\+test2
        \\
        ,
        .patch = makePatch("this is the message\n", &[_]FilePatch{.{
            .from = testFile(filemode.Regular, "test.txt", "test\n"),
            .to = testFile(filemode.Regular, "test.txt", "test2\n"),
            .chunks = &chunks,
        }}),
    });
}

test "one line change with message and no end of line" {
    const chunks = [_]Chunk{
        .{ .content = "test", .op = .delete },
        .{ .content = "test2", .op = .add },
    };
    try runFixture(.{
        .desc = "one line change with message and no end of line",
        .context = 1,
        .diff =
        \\this is the message
        \\diff --git a/test.txt b/test.txt
        \\index 30d74d258442c7c65512eafab474568dd706c430..d606037cb232bfda7788a8322492312d55b2ae9d 100644
        \\--- a/test.txt
        \\+++ b/test.txt
        \\@@ -1 +1 @@
        \\-test
        \\\ No newline at end of file
        \\+test2
        \\\ No newline at end of file
        \\
        ,
        .patch = makePatch("this is the message", &[_]FilePatch{.{
            .from = testFile(filemode.Regular, "test.txt", "test"),
            .to = testFile(filemode.Regular, "test.txt", "test2"),
            .chunks = &chunks,
        }}),
    });
}

test "new file" {
    const chunks = [_]Chunk{
        .{ .content = "test\ntest2\ntest3", .op = .add },
    };
    try runFixture(.{
        .desc = "new file",
        .context = 1,
        .diff =
        \\diff --git a/new.txt b/new.txt
        \\new file mode 100644
        \\index 0000000000000000000000000000000000000000..3ceaab5442b64a0c2b33dd25fae67ccdb4fd1ea8
        \\--- /dev/null
        \\+++ b/new.txt
        \\@@ -0,0 +1,3 @@
        \\+test
        \\+test2
        \\+test3
        \\\ No newline at end of file
        \\
        ,
        .patch = makePatch("", &[_]FilePatch{.{
            .to = testFile(filemode.Regular, "new.txt", "test\ntest2\ntest3"),
            .chunks = &chunks,
        }}),
    });
}

test "delete file" {
    const chunks = [_]Chunk{
        .{ .content = "test", .op = .delete },
    };
    try runFixture(.{
        .desc = "delete file",
        .context = 1,
        .diff =
        \\diff --git a/old.txt b/old.txt
        \\deleted file mode 100644
        \\index 30d74d258442c7c65512eafab474568dd706c430..0000000000000000000000000000000000000000
        \\--- a/old.txt
        \\+++ /dev/null
        \\@@ -1 +0,0 @@
        \\-test
        \\\ No newline at end of file
        \\
        ,
        .patch = makePatch("", &[_]FilePatch{.{
            .from = testFile(filemode.Regular, "old.txt", "test"),
            .chunks = &chunks,
        }}),
    });
}

test "positive negative number with color" {
    const chunks = [_]Chunk{
        .{ .content = "hello\n", .op = .equal },
        .{ .content = "world\n", .op = .delete },
        .{ .content = "bug\n", .op = .add },
    };
    const expected = color_mod.Bold ++
        "diff --git a/README.md b/README.md\n" ++
        "index 94954abda49de8615a048f8d2e64b5de848e27a1..f3dad9514629b9ff9136283ae331ad1fc95748a8 100644\n" ++
        "--- a/README.md\n" ++
        "+++ b/README.md" ++ color_mod.Reset ++ "\n" ++
        color_mod.Cyan ++ "@@ -1,2 +1,2 @@" ++ color_mod.Reset ++ "\n" ++
        " hello\n" ++
        color_mod.Red ++ "-world" ++ color_mod.Reset ++ "\n" ++
        color_mod.Green ++ "+bug" ++ color_mod.Reset ++ "\n";
    try runFixture(.{
        .desc = "positive negative number with color",
        .context = 2,
        .use_color = true,
        .color = colorconfig.newColorConfig(&.{}),
        .diff = expected,
        .patch = makePatch("", &[_]FilePatch{.{
            .from = testFile(filemode.Regular, "README.md", "hello\nworld\n"),
            .to = testFile(filemode.Regular, "README.md", "hello\nbug\n"),
            .chunks = &chunks,
        }}),
    });
}

test "newColorConfig defaults and WithColor" {
    const cc = colorconfig.newColorConfig(&.{
        colorconfig.withColor(.func, color_mod.Reverse),
    });
    try testing.expectEqualStrings(color_mod.Bold, cc.get(.meta));
    try testing.expectEqualStrings(color_mod.Reverse, cc.get(.func));
    try testing.expectEqualStrings(color_mod.Reset, cc.reset(.meta));
    try testing.expectEqualStrings("", (ColorConfig{}).reset(.meta));
}


// --- onechunk delete fixtures (context 0–6) ---

test "one line change with color" {
    const chunks = [_]Chunk{
        .{ .content = "test\n", .op = .delete },
        .{ .content = "test2\n", .op = .add },
    };
    const expected = color_mod.Bold ++
        "diff --git a/test.txt b/test.txt\n" ++
        "index 9daeafb9864cf43055ae93beb0afd6c7d144bfa4..180cf8328022becee9aaa2577a8f84ea2b9f3827 100644\n" ++
        "--- a/test.txt\n" ++
        "+++ b/test.txt" ++ color_mod.Reset ++ "\n" ++
        color_mod.Cyan ++ "@@ -1 +1 @@" ++ color_mod.Reset ++ "\n" ++
        color_mod.Red ++ "-test" ++ color_mod.Reset ++ "\n" ++
        color_mod.Green ++ "+test2" ++ color_mod.Reset ++ "\n";
    try runFixture(.{
        .desc = "one line change with color",
        .context = 1,
        .use_color = true,
        .color = colorconfig.newColorConfig(&.{
            colorconfig.withColor(.func, color_mod.Reverse),
        }),
        .diff = expected,
        .patch = makePatch("", &[_]FilePatch{.{
            .from = testFile(filemode.Regular, "test.txt", "test\n"),
            .to = testFile(filemode.Regular, "test.txt", "test2\n"),
            .chunks = &chunks,
        }}),
    });
}

test "splitLines keeps trailing newlines and strips empty tail" {
    const gpa = testing.allocator;

    {
        const lines = try splitLines(gpa, "A\n");
        defer gpa.free(lines);
        try testing.expectEqual(@as(usize, 1), lines.len);
        try testing.expectEqualStrings("A\n", lines[0]);
    }
    {
        const lines = try splitLines(gpa, "Y\nZ");
        defer gpa.free(lines);
        try testing.expectEqual(@as(usize, 2), lines.len);
        try testing.expectEqualStrings("Y\n", lines[0]);
        try testing.expectEqualStrings("Z", lines[1]);
    }
    {
        const lines = try splitLines(gpa, "Z");
        defer gpa.free(lines);
        try testing.expectEqual(@as(usize, 1), lines.len);
        try testing.expectEqualStrings("Z", lines[0]);
    }
    {
        const lines = try splitLines(gpa, "");
        defer gpa.free(lines);
        try testing.expectEqual(@as(usize, 0), lines.len);
    }
}

// Silence unused import if color_mod only used in color tests (always used).


test "generate only onechunk context 0" {
    const gpa = testing.allocator;
    var gen = HunksGenerator.init(gpa, &one_chunk_chunks, 0);
    defer gen.deinit();
    const hunks = try gen.generate();
    try testing.expect(hunks.len >= 1);
}


test "writeTo onechunk context 0 no header" {
    const gpa = testing.allocator;
    var gen = HunksGenerator.init(gpa, &one_chunk_chunks, 0);
    defer gen.deinit();
    const hunks = try gen.generate();
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    for (hunks) |h| {
        try h.writeTo(&aw.writer, .{});
    }
    const out = aw.written();
    try testing.expect(out.len > 10);
}


test "header only onechunk" {
    const gpa = testing.allocator;
    const patch = oneChunkPatch();
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var e = UnifiedEncoder.init(gpa, &aw.writer, 0);
    // only header
    for (patch.file_patches) |fp| {
        try e.writeFilePatchHeader(fp);
    }
    const out = aw.written();
    try testing.expect(std.mem.startsWith(u8, out, "diff --git"));
}





test "encode multi-hunk simple no N" {
    const gpa = testing.allocator;
    const chunks = [_]Chunk{
        .{ .content = "A\n", .op = .delete },
        .{ .content = "B\nC\n", .op = .equal },
        .{ .content = "D\n", .op = .delete },
        .{ .content = "E\n", .op = .equal },
    };
    const patch = makePatch("", &[_]FilePatch{.{
        .from = testFile(filemode.Regular, "f.txt", "A\nB\nC\nD\nE\n"),
        .to = testFile(filemode.Regular, "f.txt", "B\nC\nE\n"),
        .chunks = &chunks,
    }});
    const out = try encodeToString(gpa, 0, .{}, null, null, patch);
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "@@") != null);
}


test "encode onechunk full context 0" {
    const gpa = testing.allocator;
    const out = try encodeToString(gpa, 0, .{}, null, null, oneChunkPatch());
    defer gpa.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "diff --git"));
    try testing.expect(std.mem.indexOf(u8, out, "@@") != null);
}
test "encode onechunk full context 1" {
    const gpa = testing.allocator;
    const out = try encodeToString(gpa, 1, .{}, null, null, oneChunkPatch());
    defer gpa.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "@@") != null);
}
comptime {
    _ = color_mod;
}


