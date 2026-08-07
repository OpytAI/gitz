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
                // Optional pointers so failed second alloc frees the first, and
                // successful transfer into appendPathLines (which always frees)
                // clears the options before outer errdefer can double-free.
                var src_p: ?[]u8 = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.src_prefix, f.path });
                errdefer if (src_p) |p| self.allocator.free(p);
                var dst_p: ?[]u8 = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.dst_prefix, t.path });
                errdefer if (dst_p) |p| self.allocator.free(p);
                const s = src_p.?;
                const d = dst_p.?;
                src_p = null;
                dst_p = null;
                try self.appendPathLines(&lines, s, d, is_binary);
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
            var src_p: ?[]u8 = try self.allocator.dupe(u8, "/dev/null");
            errdefer if (src_p) |p| self.allocator.free(p);
            var dst_p: ?[]u8 = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.dst_prefix, t.path });
            errdefer if (dst_p) |p| self.allocator.free(p);
            const s = src_p.?;
            const d = dst_p.?;
            src_p = null;
            dst_p = null;
            try self.appendPathLines(&lines, s, d, is_binary);
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
            var src_p: ?[]u8 = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.src_prefix, f.path });
            errdefer if (src_p) |p| self.allocator.free(p);
            var dst_p: ?[]u8 = try self.allocator.dupe(u8, "/dev/null");
            errdefer if (dst_p) |p| self.allocator.free(p);
            const s = src_p.?;
            const d = dst_p.?;
            src_p = null;
            dst_p = null;
            try self.appendPathLines(&lines, s, d, is_binary);
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
        // from_path and to_path are owned; always free them (success or error).
        defer self.allocator.free(from_path);
        defer self.allocator.free(to_path);
        if (is_binary) {
            const line = try std.fmt.allocPrint(
                self.allocator,
                "Binary files {s} and {s} differ",
                .{ from_path, to_path },
            );
            errdefer self.allocator.free(line);
            try lines.append(self.allocator, line);
            return;
        }
        const from_line = try std.fmt.allocPrint(self.allocator, "--- {s}", .{from_path});
        errdefer self.allocator.free(from_line);
        const to_line = try std.fmt.allocPrint(self.allocator, "+++ {s}", .{to_path});
        errdefer self.allocator.free(to_line);
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

const one_chunk_inverted_chunks = [_]Chunk{
    .{ .content = "A\n", .op = .add },
    .{ .content = "B\nC\nD\nE\nF\nG\n", .op = .equal },
    .{ .content = "H\n", .op = .add },
    .{ .content = "I\nJ\nK\nL\nM\nN\n", .op = .equal },
    .{ .content = "Ñ\n", .op = .add },
    .{ .content = "O\nP\nQ\nR\nS\nT\n", .op = .equal },
    .{ .content = "U\n", .op = .add },
    .{ .content = "V\nW\nX\nY\nZ", .op = .equal },
};

const remove_last_letter_chunks = [_]Chunk{
    .{ .content = "B\nC\nD\nE\nF\nG\nI\nJ\nK\nL\nM\nN\nO\nP\nQ\nR\nS\nT\nV\nW\nX\nY\n", .op = .equal },
    .{ .content = "Z", .op = .delete },
};

const remove_last_letter_no_nl_chunks = [_]Chunk{
    .{ .content = "B\nC\nD\nE\nF\nG\nI\nJ\nK\nL\nM\nN\nO\nP\nQ\nR\nS\nT\nV\nW\nX\n", .op = .equal },
    .{ .content = "Y\nZ", .op = .delete },
    .{ .content = "Y", .op = .add },
};

/// Fill `fps` with the onechunk delete FilePatch; Patch borrows `fps` for the call.
fn oneChunkPatch(fps: *[1]FilePatch) Patch {
    fps[0] = .{
        .from = testFile(filemode.Regular, "onechunk.txt", one_chunk_from_seed),
        .to = testFile(filemode.Regular, "onechunk.txt", one_chunk_to_seed),
        .chunks = &one_chunk_chunks,
    };
    return makePatch("", fps[0..]);
}

/// Fill `fps` with the onechunk inverted (add) FilePatch; Patch borrows `fps`.
fn oneChunkPatchInverted(fps: *[1]FilePatch) Patch {
    fps[0] = .{
        .to = testFile(filemode.Regular, "onechunk.txt", one_chunk_from_seed),
        .from = testFile(filemode.Regular, "onechunk.txt", one_chunk_to_seed),
        .chunks = &one_chunk_inverted_chunks,
    };
    return makePatch("", fps[0..]);
}

/// Fill `fps` with remove-last-letter (Z) FilePatch; Patch borrows `fps`.
fn removeLastLetterPatch(fps: *[1]FilePatch) Patch {
    fps[0] = .{
        .from = testFile(filemode.Regular, "onechunk.txt", one_chunk_to_seed),
        .to = testFile(filemode.Regular, "onechunk.txt", "B\nC\nD\nE\nF\nG\nI\nJ\nK\nL\nM\nN\nO\nP\nQ\nR\nS\nT\nV\nW\nX\nY\n"),
        .chunks = &remove_last_letter_chunks,
    };
    return makePatch("", fps[0..]);
}

/// Fill `fps` with remove-last-letter no-newline FilePatch; Patch borrows `fps`.
fn removeLastLetterNoNewlinePatch(fps: *[1]FilePatch) Patch {
    fps[0] = .{
        .from = testFile(filemode.Regular, "onechunk.txt", one_chunk_to_seed),
        .to = testFile(filemode.Regular, "onechunk.txt", "B\nC\nD\nE\nF\nG\nI\nJ\nK\nL\nM\nN\nO\nP\nQ\nR\nS\nT\nV\nW\nX\nY"),
        .chunks = &remove_last_letter_no_nl_chunks,
    };
    return makePatch("", fps[0..]);
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
    var fps = [_]FilePatch{.{}};
    const out = try encodeToString(gpa, 1, .{}, null, null, makePatch("", fps[0..]));
    defer gpa.free(out);
    try testing.expectEqualStrings("", out);
}

test "TestBinaryFile" {
    const gpa = testing.allocator;
    var fps = [_]FilePatch{.{
        .from = testFile(filemode.Regular, "binary", "something"),
        .to = testFile(filemode.Regular, "binary", "otherthing"),
        .is_binary = true,
    }};
    const out = try encodeToString(gpa, 1, .{}, null, null, makePatch("", fps[0..]));
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
    var fps = [_]FilePatch{.{
        .from = testFile(filemode.Regular, "README.md", "hello\nworld\n"),
        .to = testFile(filemode.Regular, "README.md", "hello\nbug\n"),
        .chunks = &chunks,
    }};
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
        .patch = makePatch("", fps[0..]),
    });
}

test "make executable" {
    var fps = [_]FilePatch{.{
        .from = testFile(filemode.Regular, "test.txt", "test"),
        .to = testFile(filemode.Executable, "test.txt", "test"),
    }};
    try runFixture(.{
        .desc = "make executable",
        .context = 1,
        .diff =
        \\diff --git a/test.txt b/test.txt
        \\old mode 100644
        \\new mode 100755
        \\
        ,
        .patch = makePatch("", fps[0..]),
    });
}

test "rename file" {
    var fps = [_]FilePatch{.{
        .from = testFile(filemode.Regular, "test.txt", "test"),
        .to = testFile(filemode.Regular, "test1.txt", "test"),
    }};
    try runFixture(.{
        .desc = "rename file",
        .context = 1,
        .diff =
        \\diff --git a/test.txt b/test1.txt
        \\rename from test.txt
        \\rename to test1.txt
        \\
        ,
        .patch = makePatch("", fps[0..]),
    });
}

test "rename file with changes" {
    const chunks = [_]Chunk{
        .{ .content = "test\n", .op = .delete },
        .{ .content = "test1\n", .op = .add },
    };
    var fps = [_]FilePatch{.{
        .from = testFile(filemode.Regular, "test.txt", "test\n"),
        .to = testFile(filemode.Regular, "test1.txt", "test1\n"),
        .chunks = &chunks,
    }};
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
        .patch = makePatch("", fps[0..]),
    });
}

test "rename with file mode change" {
    var fps = [_]FilePatch{.{
        .from = testFile(filemode.Regular, "test.txt", "test"),
        .to = testFile(filemode.Executable, "test1.txt", "test"),
    }};
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
        .patch = makePatch("", fps[0..]),
    });
}

test "one line change" {
    const chunks = [_]Chunk{
        .{ .content = "test\n", .op = .delete },
        .{ .content = "test2\n", .op = .add },
    };
    var fps = [_]FilePatch{.{
        .from = testFile(filemode.Regular, "test.txt", "test\n"),
        .to = testFile(filemode.Regular, "test.txt", "test2\n"),
        .chunks = &chunks,
    }};
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
        .patch = makePatch("", fps[0..]),
    });
}

test "one line change with message" {
    const chunks = [_]Chunk{
        .{ .content = "test\n", .op = .delete },
        .{ .content = "test2\n", .op = .add },
    };
    var fps = [_]FilePatch{.{
        .from = testFile(filemode.Regular, "test.txt", "test\n"),
        .to = testFile(filemode.Regular, "test.txt", "test2\n"),
        .chunks = &chunks,
    }};
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
        .patch = makePatch("this is the message\n", fps[0..]),
    });
}

test "one line change with message and no end of line" {
    const chunks = [_]Chunk{
        .{ .content = "test", .op = .delete },
        .{ .content = "test2", .op = .add },
    };
    var fps = [_]FilePatch{.{
        .from = testFile(filemode.Regular, "test.txt", "test"),
        .to = testFile(filemode.Regular, "test.txt", "test2"),
        .chunks = &chunks,
    }};
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
        .patch = makePatch("this is the message", fps[0..]),
    });
}

test "new file" {
    const chunks = [_]Chunk{
        .{ .content = "test\ntest2\ntest3", .op = .add },
    };
    var fps = [_]FilePatch{.{
        .to = testFile(filemode.Regular, "new.txt", "test\ntest2\ntest3"),
        .chunks = &chunks,
    }};
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
        .patch = makePatch("", fps[0..]),
    });
}

test "delete file" {
    const chunks = [_]Chunk{
        .{ .content = "test", .op = .delete },
    };
    var fps = [_]FilePatch{.{
        .from = testFile(filemode.Regular, "old.txt", "test"),
        .chunks = &chunks,
    }};
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
        .patch = makePatch("", fps[0..]),
    });
}

test "positive negative number with color" {
    const chunks = [_]Chunk{
        .{ .content = "hello\n", .op = .equal },
        .{ .content = "world\n", .op = .delete },
        .{ .content = "bug\n", .op = .add },
    };
    var fps = [_]FilePatch{.{
        .from = testFile(filemode.Regular, "README.md", "hello\nworld\n"),
        .to = testFile(filemode.Regular, "README.md", "hello\nbug\n"),
        .chunks = &chunks,
    }};
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
        .patch = makePatch("", fps[0..]),
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


test "one line change with color" {
    const chunks = [_]Chunk{
        .{ .content = "test\n", .op = .delete },
        .{ .content = "test2\n", .op = .add },
    };
    var fps = [_]FilePatch{.{
        .from = testFile(filemode.Regular, "test.txt", "test\n"),
        .to = testFile(filemode.Regular, "test.txt", "test2\n"),
        .chunks = &chunks,
    }};
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
        .patch = makePatch("", fps[0..]),
    });
}

// --- onechunk delete fixtures (context 0,1,2,3,4,6) — go-git exact ---

test "modified deleting lines file with context to 0" {
    var fps: [1]FilePatch = undefined;
    try runFixture(.{
        .desc = "modified deleting lines file with context to 0",
        .context = 0,
        .diff =
        \\diff --git a/onechunk.txt b/onechunk.txt
        \\index ab5eed5d4a2c33aeef67e0188ee79bed666bde6f..0adddcde4fd38042c354518351820eb06c417c82 100644
        \\--- a/onechunk.txt
        \\+++ b/onechunk.txt
        \\@@ -1 +0,0 @@
        \\-A
        \\@@ -8 +6,0 @@ G
        \\-H
        \\@@ -15 +12,0 @@ N
        \\-Ñ
        \\@@ -22 +18,0 @@ T
        \\-U
        \\
        ,
        .patch = oneChunkPatch(&fps),
    });
}

test "modified deleting lines file with context to 1" {
    var fps: [1]FilePatch = undefined;
    try runFixture(.{
        .desc = "modified deleting lines file with context to 1",
        .context = 1,
        .diff =
        \\diff --git a/onechunk.txt b/onechunk.txt
        \\index ab5eed5d4a2c33aeef67e0188ee79bed666bde6f..0adddcde4fd38042c354518351820eb06c417c82 100644
        \\--- a/onechunk.txt
        \\+++ b/onechunk.txt
        \\@@ -1,2 +1 @@
        \\-A
        \\ B
        \\@@ -7,3 +6,2 @@ F
        \\ G
        \\-H
        \\ I
        \\@@ -14,3 +12,2 @@ M
        \\ N
        \\-Ñ
        \\ O
        \\@@ -21,3 +18,2 @@ S
        \\ T
        \\-U
        \\ V
        \\
        ,
        .patch = oneChunkPatch(&fps),
    });
}

test "modified deleting lines file with context to 2" {
    var fps: [1]FilePatch = undefined;
    try runFixture(.{
        .desc = "modified deleting lines file with context to 2",
        .context = 2,
        .diff =
        \\diff --git a/onechunk.txt b/onechunk.txt
        \\index ab5eed5d4a2c33aeef67e0188ee79bed666bde6f..0adddcde4fd38042c354518351820eb06c417c82 100644
        \\--- a/onechunk.txt
        \\+++ b/onechunk.txt
        \\@@ -1,3 +1,2 @@
        \\-A
        \\ B
        \\ C
        \\@@ -6,5 +5,4 @@ E
        \\ F
        \\ G
        \\-H
        \\ I
        \\ J
        \\@@ -13,5 +11,4 @@ L
        \\ M
        \\ N
        \\-Ñ
        \\ O
        \\ P
        \\@@ -20,5 +17,4 @@ R
        \\ S
        \\ T
        \\-U
        \\ V
        \\ W
        \\
        ,
        .patch = oneChunkPatch(&fps),
    });
}

test "modified deleting lines file with context to 3" {
    var fps: [1]FilePatch = undefined;
    try runFixture(.{
        .desc = "modified deleting lines file with context to 3",
        .context = 3,
        .diff =
        \\diff --git a/onechunk.txt b/onechunk.txt
        \\index ab5eed5d4a2c33aeef67e0188ee79bed666bde6f..0adddcde4fd38042c354518351820eb06c417c82 100644
        \\--- a/onechunk.txt
        \\+++ b/onechunk.txt
        \\@@ -1,25 +1,21 @@
        \\-A
        \\ B
        \\ C
        \\ D
        \\ E
        \\ F
        \\ G
        \\-H
        \\ I
        \\ J
        \\ K
        \\ L
        \\ M
        \\ N
        \\-Ñ
        \\ O
        \\ P
        \\ Q
        \\ R
        \\ S
        \\ T
        \\-U
        \\ V
        \\ W
        \\ X
        \\
        ,
        .patch = oneChunkPatch(&fps),
    });
}

test "modified deleting lines file with context to 4" {
    var fps: [1]FilePatch = undefined;
    try runFixture(.{
        .desc = "modified deleting lines file with context to 4",
        .context = 4,
        .diff =
        \\diff --git a/onechunk.txt b/onechunk.txt
        \\index ab5eed5d4a2c33aeef67e0188ee79bed666bde6f..0adddcde4fd38042c354518351820eb06c417c82 100644
        \\--- a/onechunk.txt
        \\+++ b/onechunk.txt
        \\@@ -1,26 +1,22 @@
        \\-A
        \\ B
        \\ C
        \\ D
        \\ E
        \\ F
        \\ G
        \\-H
        \\ I
        \\ J
        \\ K
        \\ L
        \\ M
        \\ N
        \\-Ñ
        \\ O
        \\ P
        \\ Q
        \\ R
        \\ S
        \\ T
        \\-U
        \\ V
        \\ W
        \\ X
        \\ Y
        \\
        ,
        .patch = oneChunkPatch(&fps),
    });
}

test "modified deleting lines file with context to 6" {
    var fps: [1]FilePatch = undefined;
    try runFixture(.{
        .desc = "modified deleting lines file with context to 6",
        .context = 6,
        .diff =
        \\diff --git a/onechunk.txt b/onechunk.txt
        \\index ab5eed5d4a2c33aeef67e0188ee79bed666bde6f..0adddcde4fd38042c354518351820eb06c417c82 100644
        \\--- a/onechunk.txt
        \\+++ b/onechunk.txt
        \\@@ -1,27 +1,23 @@
        \\-A
        \\ B
        \\ C
        \\ D
        \\ E
        \\ F
        \\ G
        \\-H
        \\ I
        \\ J
        \\ K
        \\ L
        \\ M
        \\ N
        \\-Ñ
        \\ O
        \\ P
        \\ Q
        \\ R
        \\ S
        \\ T
        \\-U
        \\ V
        \\ W
        \\ X
        \\ Y
        \\ Z
        \\\ No newline at end of file
        \\
        ,
        .patch = oneChunkPatch(&fps),
    });
}

// --- onechunk inverted (add) fixtures (context 0,1,2,3,4) — go-git exact ---

test "modified adding lines file with context to 0" {
    var fps: [1]FilePatch = undefined;
    try runFixture(.{
        .desc = "modified adding lines file with context to 0",
        .context = 0,
        .diff =
        \\diff --git a/onechunk.txt b/onechunk.txt
        \\index 0adddcde4fd38042c354518351820eb06c417c82..ab5eed5d4a2c33aeef67e0188ee79bed666bde6f 100644
        \\--- a/onechunk.txt
        \\+++ b/onechunk.txt
        \\@@ -0,0 +1 @@
        \\+A
        \\@@ -6,0 +8 @@ G
        \\+H
        \\@@ -12,0 +15 @@ N
        \\+Ñ
        \\@@ -18,0 +22 @@ T
        \\+U
        \\
        ,
        .patch = oneChunkPatchInverted(&fps),
    });
}

test "modified adding lines file with context to 1" {
    var fps: [1]FilePatch = undefined;
    try runFixture(.{
        .desc = "modified adding lines file with context to 1",
        .context = 1,
        .diff =
        \\diff --git a/onechunk.txt b/onechunk.txt
        \\index 0adddcde4fd38042c354518351820eb06c417c82..ab5eed5d4a2c33aeef67e0188ee79bed666bde6f 100644
        \\--- a/onechunk.txt
        \\+++ b/onechunk.txt
        \\@@ -1 +1,2 @@
        \\+A
        \\ B
        \\@@ -6,2 +7,3 @@ F
        \\ G
        \\+H
        \\ I
        \\@@ -12,2 +14,3 @@ M
        \\ N
        \\+Ñ
        \\ O
        \\@@ -18,2 +21,3 @@ S
        \\ T
        \\+U
        \\ V
        \\
        ,
        .patch = oneChunkPatchInverted(&fps),
    });
}

test "modified adding lines file with context to 2" {
    var fps: [1]FilePatch = undefined;
    try runFixture(.{
        .desc = "modified adding lines file with context to 2",
        .context = 2,
        .diff =
        \\diff --git a/onechunk.txt b/onechunk.txt
        \\index 0adddcde4fd38042c354518351820eb06c417c82..ab5eed5d4a2c33aeef67e0188ee79bed666bde6f 100644
        \\--- a/onechunk.txt
        \\+++ b/onechunk.txt
        \\@@ -1,2 +1,3 @@
        \\+A
        \\ B
        \\ C
        \\@@ -5,4 +6,5 @@ E
        \\ F
        \\ G
        \\+H
        \\ I
        \\ J
        \\@@ -11,4 +13,5 @@ L
        \\ M
        \\ N
        \\+Ñ
        \\ O
        \\ P
        \\@@ -17,4 +20,5 @@ R
        \\ S
        \\ T
        \\+U
        \\ V
        \\ W
        \\
        ,
        .patch = oneChunkPatchInverted(&fps),
    });
}

test "modified adding lines file with context to 3" {
    var fps: [1]FilePatch = undefined;
    try runFixture(.{
        .desc = "modified adding lines file with context to 3",
        .context = 3,
        .diff =
        \\diff --git a/onechunk.txt b/onechunk.txt
        \\index 0adddcde4fd38042c354518351820eb06c417c82..ab5eed5d4a2c33aeef67e0188ee79bed666bde6f 100644
        \\--- a/onechunk.txt
        \\+++ b/onechunk.txt
        \\@@ -1,21 +1,25 @@
        \\+A
        \\ B
        \\ C
        \\ D
        \\ E
        \\ F
        \\ G
        \\+H
        \\ I
        \\ J
        \\ K
        \\ L
        \\ M
        \\ N
        \\+Ñ
        \\ O
        \\ P
        \\ Q
        \\ R
        \\ S
        \\ T
        \\+U
        \\ V
        \\ W
        \\ X
        \\
        ,
        .patch = oneChunkPatchInverted(&fps),
    });
}

test "modified adding lines file with context to 4" {
    var fps: [1]FilePatch = undefined;
    try runFixture(.{
        .desc = "modified adding lines file with context to 4",
        .context = 4,
        .diff =
        \\diff --git a/onechunk.txt b/onechunk.txt
        \\index 0adddcde4fd38042c354518351820eb06c417c82..ab5eed5d4a2c33aeef67e0188ee79bed666bde6f 100644
        \\--- a/onechunk.txt
        \\+++ b/onechunk.txt
        \\@@ -1,22 +1,26 @@
        \\+A
        \\ B
        \\ C
        \\ D
        \\ E
        \\ F
        \\ G
        \\+H
        \\ I
        \\ J
        \\ K
        \\ L
        \\ M
        \\ N
        \\+Ñ
        \\ O
        \\ P
        \\ Q
        \\ R
        \\ S
        \\ T
        \\+U
        \\ V
        \\ W
        \\ X
        \\ Y
        \\
        ,
        .patch = oneChunkPatchInverted(&fps),
    });
}

// --- last-letter cases ---

test "remove last letter" {
    var fps: [1]FilePatch = undefined;
    try runFixture(.{
        .desc = "remove last letter",
        .context = 0,
        .diff =
        \\diff --git a/onechunk.txt b/onechunk.txt
        \\index 0adddcde4fd38042c354518351820eb06c417c82..553ae669c7a9303cf848fcc749a2569228ac5309 100644
        \\--- a/onechunk.txt
        \\+++ b/onechunk.txt
        \\@@ -23 +22,0 @@ Y
        \\-Z
        \\\ No newline at end of file
        \\
        ,
        .patch = removeLastLetterPatch(&fps),
    });
}

test "remove last letter and no newline at end of file" {
    var fps: [1]FilePatch = undefined;
    try runFixture(.{
        .desc = "remove last letter and no newline at end of file",
        .context = 0,
        .diff =
        \\diff --git a/onechunk.txt b/onechunk.txt
        \\index 0adddcde4fd38042c354518351820eb06c417c82..d39ae38aad7ba9447b5e7998b2e4714f26c9218d 100644
        \\--- a/onechunk.txt
        \\+++ b/onechunk.txt
        \\@@ -22,2 +21 @@ X
        \\-Y
        \\-Z
        \\\ No newline at end of file
        \\+Y
        \\\ No newline at end of file
        \\
        ,
        .patch = removeLastLetterNoNewlinePatch(&fps),
    });
}

// --- onechunk color variant ---

test "modified deleting lines file with context to 1 with color" {
    const expected = color_mod.Bold ++
        "diff --git a/onechunk.txt b/onechunk.txt\n" ++
        "index ab5eed5d4a2c33aeef67e0188ee79bed666bde6f..0adddcde4fd38042c354518351820eb06c417c82 100644\n" ++
        "--- a/onechunk.txt\n" ++
        "+++ b/onechunk.txt" ++ color_mod.Reset ++ "\n" ++
        color_mod.Cyan ++ "@@ -1,2 +1 @@" ++ color_mod.Reset ++ "\n" ++
        color_mod.Red ++ "-A" ++ color_mod.Reset ++ "\n" ++
        " B\n" ++
        color_mod.Cyan ++ "@@ -7,3 +6,2 @@" ++ color_mod.Reset ++ " " ++ color_mod.Reverse ++ "F" ++ color_mod.Reset ++ "\n" ++
        " G\n" ++
        color_mod.Red ++ "-H" ++ color_mod.Reset ++ "\n" ++
        " I\n" ++
        color_mod.Cyan ++ "@@ -14,3 +12,2 @@" ++ color_mod.Reset ++ " " ++ color_mod.Reverse ++ "M" ++ color_mod.Reset ++ "\n" ++
        " N\n" ++
        color_mod.Red ++ "-Ñ" ++ color_mod.Reset ++ "\n" ++
        " O\n" ++
        color_mod.Cyan ++ "@@ -21,3 +18,2 @@" ++ color_mod.Reset ++ " " ++ color_mod.Reverse ++ "S" ++ color_mod.Reset ++ "\n" ++
        " T\n" ++
        color_mod.Red ++ "-U" ++ color_mod.Reset ++ "\n" ++
        " V\n";
    var fps: [1]FilePatch = undefined;
    try runFixture(.{
        .desc = "modified deleting lines file with context to 1 with color",
        .context = 1,
        .use_color = true,
        .color = colorconfig.newColorConfig(&.{
            colorconfig.withColor(.func, color_mod.Reverse),
        }),
        .diff = expected,
        .patch = oneChunkPatch(&fps),
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

test "TestCustomSrcDstPrefix" {
    const gpa = testing.allocator;
    var fps = [_]FilePatch{.{
        .from = testFile(filemode.Regular, "binary", "something"),
        .to = testFile(filemode.Regular, "binary", "otherthing"),
        .is_binary = true,
    }};
    const out = try encodeToString(
        gpa,
        1,
        .{},
        "source/prefix/",
        "dest/prefix/",
        makePatch("", fps[0..]),
    );
    defer gpa.free(out);
    try testing.expectEqualStrings(
        \\diff --git source/prefix/binary dest/prefix/binary
        \\index a459bc245bdbc45e1bca99e7fe61731da5c48da4..6879395eacf3cc7e5634064ccb617ac7aa62be7d 100644
        \\Binary files source/prefix/binary and dest/prefix/binary differ
        \\
    , out);
}


