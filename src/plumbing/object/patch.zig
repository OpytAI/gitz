//! Patch / FilePatch / unified encode
//! (go-git `plumbing/object/patch.go` + `plumbing/format/diff`).
//!
//! Line-oriented Myers O(ND) diff — same class as go-git `utils/diff.Do`.

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const change_mod = @import("change.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Change = change_mod.Change;
const ChangeEntry = change_mod.ChangeEntry;
const Changes = change_mod.Changes;

pub const default_context_lines: usize = 3;

/// Open: file content loads go through the storer; writers may return WriteFailed.
pub const PatchError = anyerror;

pub const Operation = enum {
    equal,
    add,
    delete,
};

pub const Chunk = struct {
    content: []const u8,
    operation: Operation,

    fn deinit(self: Chunk, allocator: Allocator) void {
        if (self.content.len > 0) allocator.free(self.content);
    }
};

pub const FileSide = struct {
    hash: Hash = plumbing.ZeroHash,
    mode: filemode.FileMode = filemode.Empty,
    /// Owned path when non-empty (duplicated from the source change entry).
    path: []const u8 = "",

    pub fn empty(self: FileSide) bool {
        return !filemode.isFile(self.mode);
    }

    fn deinit(self: *FileSide, allocator: Allocator) void {
        if (self.path.len > 0) allocator.free(self.path);
        self.* = .{};
    }

    fn fromEntry(allocator: Allocator, ce: ChangeEntry) Allocator.Error!FileSide {
        if (!filemode.isFile(ce.tree_entry.mode)) return .{};
        return .{
            .hash = ce.tree_entry.hash,
            .mode = ce.tree_entry.mode,
            .path = if (ce.name.len > 0) try allocator.dupe(u8, ce.name) else "",
        };
    }
};

pub const FilePatch = struct {
    chunks: []Chunk = &.{},
    from: FileSide = .{},
    to: FileSide = .{},
    /// True when content is binary (no text chunks produced).
    binary: bool = false,

    pub fn isBinary(self: *const FilePatch) bool {
        return self.binary;
    }

    pub fn deinit(self: *FilePatch, allocator: Allocator) void {
        for (self.chunks) |ch| ch.deinit(allocator);
        if (self.chunks.len > 0) allocator.free(self.chunks);
        self.from.deinit(allocator);
        self.to.deinit(allocator);
        self.* = .{};
    }
};

pub const Patch = struct {
    message: []const u8 = "",
    file_patches: []FilePatch = &.{},
    allocator: Allocator,

    pub fn deinit(self: *Patch) void {
        for (self.file_patches) |*fp| fp.deinit(self.allocator);
        if (self.file_patches.len > 0) self.allocator.free(self.file_patches);
        if (self.message.len > 0) self.allocator.free(self.message);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn filePatches(self: *const Patch) []const FilePatch {
        return self.file_patches;
    }

    pub fn msg(self: *const Patch) []const u8 {
        return self.message;
    }

    /// go-git `(*Patch).Encode` — unified diff into `writer`.
    pub fn encode(self: *const Patch, writer: anytype) PatchError!void {
        try encodeUnified(self.allocator, writer, self, default_context_lines);
    }

    /// go-git `(*Patch).String`. Caller frees with `allocator`.
    pub fn string(self: *const Patch) PatchError![]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        try encodeUnified(self.allocator, &aw.writer, self, default_context_lines);
        return try aw.toOwnedSlice();
    }

    /// Line-level insertion/deletion counts per file.
    pub fn stats(self: *const Patch) Allocator.Error!FileStats {
        return getFileStats(self.allocator, self.file_patches);
    }
};

pub const FileStat = struct {
    name: []const u8 = "",
    addition: usize = 0,
    deletion: usize = 0,
};

pub const FileStats = struct {
    items: []FileStat = &.{},
    allocator: Allocator,

    pub fn deinit(self: *FileStats) void {
        for (self.items) |s| {
            if (s.name.len > 0) self.allocator.free(s.name);
        }
        if (self.items.len > 0) self.allocator.free(self.items);
        self.* = .{ .allocator = self.allocator };
    }
};

/// go-git `getPatch` / `Changes.Patch` over a list of change pointers.
pub fn getPatch(allocator: Allocator, message: []const u8, changes: []const *const Change) PatchError!Patch {
    var fps: std.ArrayList(FilePatch) = .empty;
    errdefer {
        for (fps.items) |*fp| fp.deinit(allocator);
        fps.deinit(allocator);
    }

    for (changes) |c| {
        try fps.append(allocator, try filePatch(allocator, c));
    }

    return .{
        .message = if (message.len > 0) try allocator.dupe(u8, message) else "",
        .file_patches = try fps.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// go-git `Changes.Patch` — build a `Patch` from a `Changes` list.
pub fn getPatchFromChanges(allocator: Allocator, message: []const u8, changes: *const Changes) PatchError!Patch {
    var fps: std.ArrayList(FilePatch) = .empty;
    errdefer {
        for (fps.items) |*fp| fp.deinit(allocator);
        fps.deinit(allocator);
    }

    for (changes.items) |c| {
        try fps.append(allocator, try filePatch(allocator, c));
    }

    return .{
        .message = if (message.len > 0) try allocator.dupe(u8, message) else "",
        .file_patches = try fps.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// go-git `(*Change).Patch`.
pub fn changePatch(allocator: Allocator, c: *const Change) PatchError!Patch {
    return getPatch(allocator, "", &[_]*const Change{c});
}

fn filePatch(allocator: Allocator, c: *const Change) PatchError!FilePatch {
    const sides = try c.files();
    var from_side = try FileSide.fromEntry(allocator, c.from);
    errdefer from_side.deinit(allocator);
    var to_side = try FileSide.fromEntry(allocator, c.to);
    errdefer to_side.deinit(allocator);

    var from_owned: ?[]u8 = null;
    var to_owned: ?[]u8 = null;
    defer {
        if (from_owned) |p| allocator.free(p);
        if (to_owned) |p| allocator.free(p);
    }

    var from_content: []const u8 = "";
    var to_content: []const u8 = "";
    var binary = false;

    if (sides.from) |f| {
        if (f.isBinary()) {
            binary = true;
        } else {
            from_owned = try f.contents(allocator);
            from_content = from_owned.?;
        }
    }
    if (sides.to) |t| {
        if (t.isBinary()) {
            binary = true;
        } else if (!binary) {
            to_owned = try t.contents(allocator);
            to_content = to_owned.?;
        }
    }

    if (binary) {
        return .{
            .chunks = &.{},
            .from = from_side,
            .to = to_side,
            .binary = true,
        };
    }

    return .{
        .chunks = try myersLineDiff(allocator, from_content, to_content),
        .from = from_side,
        .to = to_side,
        .binary = false,
    };
}

// ---------------------------------------------------------------------------
// Myers line diff
// ---------------------------------------------------------------------------

const Edit = struct {
    op: Operation,
    line: []const u8,
};

fn splitLines(allocator: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);
    if (text.len == 0) return try list.toOwnedSlice(allocator);

    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            try list.append(allocator, text[start .. i + 1]);
            start = i + 1;
        }
    }
    if (start < text.len) try list.append(allocator, text[start..]);
    return try list.toOwnedSlice(allocator);
}

fn vIndex(k: isize, max_d: usize) usize {
    return @intCast(k + @as(isize, @intCast(max_d)));
}

/// Myers O(ND) over lines → coalesced Equal/Delete/Add chunks.
fn myersLineDiff(allocator: Allocator, a_text: []const u8, b_text: []const u8) Allocator.Error![]Chunk {
    const a = try splitLines(allocator, a_text);
    defer allocator.free(a);
    const b = try splitLines(allocator, b_text);
    defer allocator.free(b);

    const n: isize = @intCast(a.len);
    const m: isize = @intCast(b.len);
    if (n == 0 and m == 0) return try allocator.alloc(Chunk, 0);

    const max_d: usize = @intCast(n + m);
    var v = try allocator.alloc(isize, 2 * max_d + 1);
    defer allocator.free(v);
    @memset(v, 0);

    var trace: std.ArrayList([]isize) = .empty;
    defer {
        for (trace.items) |t| allocator.free(t);
        trace.deinit(allocator);
    }

    var found = false;
    var d: usize = 0;
    while (d <= max_d) : (d += 1) {
        var k: isize = -@as(isize, @intCast(d));
        while (k <= @as(isize, @intCast(d))) : (k += 2) {
            const down = k == -@as(isize, @intCast(d)) or
                (k != @as(isize, @intCast(d)) and v[vIndex(k - 1, max_d)] < v[vIndex(k + 1, max_d)]);
            var x: isize = if (down) v[vIndex(k + 1, max_d)] else v[vIndex(k - 1, max_d)] + 1;
            var y = x - k;
            while (x < n and y < m and std.mem.eql(u8, a[@intCast(x)], b[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            v[vIndex(k, max_d)] = x;
            if (x >= n and y >= m) {
                found = true;
                break;
            }
        }
        try trace.append(allocator, try allocator.dupe(isize, v));
        if (found) break;
    }

    var edits: std.ArrayList(Edit) = .empty;
    defer edits.deinit(allocator);

    var x: isize = n;
    var y: isize = m;
    var di: isize = @intCast(trace.items.len);
    di -= 1;
    while (di >= 0) : (di -= 1) {
        const vv = trace.items[@intCast(di)];
        const dd: usize = @intCast(di);
        const k = x - y;
        const down = k == -@as(isize, @intCast(dd)) or
            (k != @as(isize, @intCast(dd)) and vv[vIndex(k - 1, max_d)] < vv[vIndex(k + 1, max_d)]);
        const prev_k: isize = if (down) k + 1 else k - 1;
        const prev_x = vv[vIndex(prev_k, max_d)];
        const prev_y = prev_x - prev_k;

        while (x > prev_x and y > prev_y) {
            x -= 1;
            y -= 1;
            try edits.append(allocator, .{ .op = .equal, .line = a[@intCast(x)] });
        }
        if (dd == 0) break;
        if (x == prev_x) {
            y -= 1;
            try edits.append(allocator, .{ .op = .add, .line = b[@intCast(y)] });
        } else {
            x -= 1;
            try edits.append(allocator, .{ .op = .delete, .line = a[@intCast(x)] });
        }
        x = prev_x;
        y = prev_y;
    }

    std.mem.reverse(Edit, edits.items);
    return try coalesceEdits(allocator, edits.items);
}

fn coalesceEdits(allocator: Allocator, edits: []const Edit) Allocator.Error![]Chunk {
    var chunks: std.ArrayList(Chunk) = .empty;
    errdefer {
        for (chunks.items) |ch| ch.deinit(allocator);
        chunks.deinit(allocator);
    }
    if (edits.len == 0) return try chunks.toOwnedSlice(allocator);

    var cur_op = edits[0].op;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    for (edits) |e| {
        if (e.op != cur_op) {
            try chunks.append(allocator, .{
                .content = try buf.toOwnedSlice(allocator),
                .operation = cur_op,
            });
            buf = .empty;
            cur_op = e.op;
        }
        try buf.appendSlice(allocator, e.line);
    }
    try chunks.append(allocator, .{
        .content = try buf.toOwnedSlice(allocator),
        .operation = cur_op,
    });
    // buf was moved into last chunk; don't free.
    return try chunks.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Unified encoder
// ---------------------------------------------------------------------------

fn encodeUnified(
    allocator: Allocator,
    writer: anytype,
    patch: *const Patch,
    context_lines: usize,
) PatchError!void {
    if (patch.message.len > 0) {
        try writer.writeAll(patch.message);
        if (patch.message[patch.message.len - 1] != '\n') try writer.writeAll("\n");
    }
    for (patch.file_patches) |fp| {
        try writeFilePatchHeader(writer, &fp);
        if (fp.binary) continue;
        try writeHunks(allocator, writer, fp.chunks, context_lines);
    }
}

fn writeFilePatchHeader(writer: anytype, fp: *const FilePatch) PatchError!void {
    const from = fp.from;
    const to = fp.to;
    if (from.empty() and to.empty()) return;

    const src_prefix = "a/";
    const dst_prefix = "b/";

    if (!from.empty() and !to.empty()) {
        try writer.print("diff --git {s}{s} {s}{s}\n", .{ src_prefix, from.path, dst_prefix, to.path });
        if (from.mode != to.mode) {
            try writer.print("old mode {o}\n", .{from.mode});
            try writer.print("new mode {o}\n", .{to.mode});
        }
        if (!std.mem.eql(u8, from.path, to.path)) {
            try writer.print("rename from {s}\n", .{from.path});
            try writer.print("rename to {s}\n", .{to.path});
        }
        if (!from.hash.eql(to.hash)) {
            var fh: [plumbing.HexSize]u8 = undefined;
            var th: [plumbing.HexSize]u8 = undefined;
            const fs = from.hash.string(&fh);
            const ts = to.hash.string(&th);
            if (from.mode != to.mode) {
                try writer.print("index {s}..{s}\n", .{ fs, ts });
            } else {
                try writer.print("index {s}..{s} {o}\n", .{ fs, ts, from.mode });
            }
            try writer.print("--- {s}{s}\n", .{ src_prefix, from.path });
            try writer.print("+++ {s}{s}\n", .{ dst_prefix, to.path });
        }
    } else if (from.empty()) {
        var th: [plumbing.HexSize]u8 = undefined;
        var zh: [plumbing.HexSize]u8 = undefined;
        try writer.print("diff --git {s}{s} {s}{s}\n", .{ src_prefix, to.path, dst_prefix, to.path });
        try writer.print("new file mode {o}\n", .{to.mode});
        try writer.print("index {s}..{s}\n", .{ plumbing.ZeroHash.string(&zh), to.hash.string(&th) });
        try writer.writeAll("--- /dev/null\n");
        try writer.print("+++ {s}{s}\n", .{ dst_prefix, to.path });
    } else {
        var fh: [plumbing.HexSize]u8 = undefined;
        var zh: [plumbing.HexSize]u8 = undefined;
        try writer.print("diff --git {s}{s} {s}{s}\n", .{ src_prefix, from.path, dst_prefix, from.path });
        try writer.print("deleted file mode {o}\n", .{from.mode});
        try writer.print("index {s}..{s}\n", .{ from.hash.string(&fh), plumbing.ZeroHash.string(&zh) });
        try writer.print("--- {s}{s}\n", .{ src_prefix, from.path });
        try writer.writeAll("+++ /dev/null\n");
    }

    if (fp.binary) try writer.writeAll("Binary files differ\n");
}

const LineOp = struct {
    op: Operation,
    text: []const u8,
};

fn writeHunks(
    allocator: Allocator,
    writer: anytype,
    chunks: []const Chunk,
    context_lines: usize,
) PatchError!void {
    var flat: std.ArrayList(LineOp) = .empty;
    defer flat.deinit(allocator);

    for (chunks) |ch| {
        try appendLines(&flat, allocator, ch.operation, ch.content);
    }
    if (flat.items.len == 0) return;

    var i: usize = 0;
    while (i < flat.items.len) {
        while (i < flat.items.len and flat.items[i].op == .equal) : (i += 1) {}
        if (i >= flat.items.len) break;

        const change_start = i;
        while (i < flat.items.len and flat.items[i].op != .equal) : (i += 1) {}
        var change_end = i;

        // Merge nearby change regions when equal run is within 2× context.
        while (change_end < flat.items.len) {
            var j = change_end;
            while (j < flat.items.len and flat.items[j].op == .equal) : (j += 1) {}
            if (j >= flat.items.len) break;
            if (j - change_end > context_lines * 2) break;
            while (j < flat.items.len and flat.items[j].op != .equal) : (j += 1) {}
            change_end = j;
        }

        const ctx_before = @min(context_lines, change_start);
        const hunk_start = change_start - ctx_before;
        var ctx_after: usize = 0;
        while (change_end + ctx_after < flat.items.len and
            flat.items[change_end + ctx_after].op == .equal and
            ctx_after < context_lines) : (ctx_after += 1)
        {}
        const hunk_end = change_end + ctx_after;

        var old_start: usize = 1;
        var new_start: usize = 1;
        var oi: usize = 0;
        while (oi < hunk_start) : (oi += 1) {
            switch (flat.items[oi].op) {
                .equal, .delete => old_start += 1,
                .add => {},
            }
            switch (flat.items[oi].op) {
                .equal, .add => new_start += 1,
                .delete => {},
            }
        }
        var old_count: usize = 0;
        var new_count: usize = 0;
        var hi = hunk_start;
        while (hi < hunk_end) : (hi += 1) {
            switch (flat.items[hi].op) {
                .equal, .delete => old_count += 1,
                .add => {},
            }
            switch (flat.items[hi].op) {
                .equal, .add => new_count += 1,
                .delete => {},
            }
        }
        if (old_count == 0) old_start = 0;
        if (new_count == 0) new_start = 0;

        try writer.print("@@ -{d}", .{old_start});
        if (old_count != 1) try writer.print(",{d}", .{old_count});
        try writer.print(" +{d}", .{new_start});
        if (new_count != 1) try writer.print(",{d}", .{new_count});
        try writer.writeAll(" @@\n");

        hi = hunk_start;
        while (hi < hunk_end) : (hi += 1) {
            const line = flat.items[hi];
            const prefix: u8 = switch (line.op) {
                .equal => ' ',
                .add => '+',
                .delete => '-',
            };
            try writer.writeByte(prefix);
            if (line.text.len > 0 and line.text[line.text.len - 1] == '\n') {
                try writer.writeAll(line.text[0 .. line.text.len - 1]);
                try writer.writeAll("\n");
            } else {
                try writer.writeAll(line.text);
                try writer.writeAll("\n");
            }
        }

        i = change_end;
    }
}

fn appendLines(
    flat: *std.ArrayList(LineOp),
    allocator: Allocator,
    op: Operation,
    text: []const u8,
) Allocator.Error!void {
    if (text.len == 0) return;
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            try flat.append(allocator, .{ .op = op, .text = text[start .. i + 1] });
            start = i + 1;
        }
    }
    if (start < text.len) {
        try flat.append(allocator, .{ .op = op, .text = text[start..] });
    }
}

fn getFileStats(allocator: Allocator, fps: []const FilePatch) Allocator.Error!FileStats {
    var list: std.ArrayList(FileStat) = .empty;
    errdefer {
        for (list.items) |s| if (s.name.len > 0) allocator.free(s.name);
        list.deinit(allocator);
    }
    for (fps) |fp| {
        if (fp.from.empty() and fp.to.empty()) continue;
        var add: usize = 0;
        var del: usize = 0;
        for (fp.chunks) |ch| {
            const n = countLines(ch.content);
            switch (ch.operation) {
                .add => add += n,
                .delete => del += n,
                .equal => {},
            }
        }
        const name = if (!fp.to.empty()) fp.to.path else fp.from.path;
        try list.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .addition = add,
            .deletion = del,
        });
    }
    return .{ .items = try list.toOwnedSlice(allocator), .allocator = allocator };
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var n: usize = 0;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    if (text[text.len - 1] != '\n') n += 1;
    return n;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "myersLineDiff simple" {
    const gpa = std.testing.allocator;
    const chunks = try myersLineDiff(gpa, "a\nb\n", "a\nc\n");
    defer {
        for (chunks) |ch| ch.deinit(gpa);
        gpa.free(chunks);
    }
    var saw_del = false;
    var saw_add = false;
    for (chunks) |ch| {
        if (ch.operation == .delete) saw_del = true;
        if (ch.operation == .add) saw_add = true;
    }
    try std.testing.expect(saw_del and saw_add);
}

test "myersLineDiff empty to content" {
    const gpa = std.testing.allocator;
    const chunks = try myersLineDiff(gpa, "", "x\n");
    defer {
        for (chunks) |ch| ch.deinit(gpa);
        gpa.free(chunks);
    }
    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expect(chunks[0].operation == .add);
}

test "filePatch insert text" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");
    const Storage = memory.Storage;
    const storer = @import("storer");
    const tree_mod = @import("tree.zig");

    var store = Storage.init(gpa);
    defer store.deinit();
    const blob = try store.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write("hello\n");
    const bh = try store.setEncodedObject(blob);

    var tb = tree_mod.Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tb.deinit();
    try tb.appendEntry("hello.txt", filemode.Regular, bh);
    tb.sortEntries();

    const c = Change{
        .from = .{},
        .to = .{
            .name = "hello.txt",
            .tree = &tb,
            .tree_entry = .{
                .name = "hello.txt",
                .mode = filemode.Regular,
                .hash = bh,
            },
        },
    };
    var p = try changePatch(gpa, &c);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.file_patches.len);
    try std.testing.expect(!p.file_patches[0].binary);
    const s = try p.string();
    defer gpa.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "new file mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "+hello") != null);
}
