//! Patch / FilePatch / unified encode
//! (go-git `plumbing/object/patch.go` + `plumbing/format/diff`).
//!
//! Line diffs go through `//src/utils/diff` (go-git `utils/diff.Do`).
//! Unified encoding goes through `//src/plumbing/format/diff` UnifiedEncoder
//! (go-git `fdiff.NewUnifiedEncoder` + `Encode`).

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const utils_diff = @import("diff");
const format_diff = @import("format_diff");
const change_mod = @import("change.zig");
const error_mod = @import("error.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Change = change_mod.Change;
const ChangeEntry = change_mod.ChangeEntry;
const Changes = change_mod.Changes;
const Writer = std.Io.Writer;

/// go-git / format_diff `DefaultContextLines`.
pub const default_context_lines: usize = format_diff.DefaultContextLines;

/// Closed patch error set. Storer/writer backends outside this set map to
/// `error.PatchBackend` at public entry points.
pub const PatchError = error_mod.Error || Allocator.Error || plumbing.Error || error{
    /// Writer failed mid-encode (Io write path).
    WriteFailed,
};

pub const Operation = enum {
    equal,
    add,
    delete,
};

pub const Chunk = struct {
    content: []const u8,
    operation: Operation,

    /// Free heap content. Invariant: empty content is never allocator-owned
    /// (always `""` / a non-owned empty view). `lineDiffChunks` normalizes
    /// empty Myers texts to `""` after freeing any empty allocation.
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

    /// go-git `(*Patch).Encode` — unified diff via format_diff.UnifiedEncoder.
    pub fn encode(self: *const Patch, w: *Writer) PatchError!void {
        encodeViaUnifiedEncoder(self, w) catch |err| return mapPatchErr(err);
    }

    /// go-git `(*Patch).String`. Caller frees with `allocator`.
    pub fn string(self: *const Patch) PatchError![]u8 {
        var aw: Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();
        encodeViaUnifiedEncoder(self, &aw.writer) catch |err| return mapPatchErr(err);
        return aw.toOwnedSlice() catch |err| return mapPatchErr(err);
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

    /// go-git `FileStat.String` / `printStat` for one entry. Caller frees.
    pub fn string(self: FileStat, allocator: Allocator) Allocator.Error![]u8 {
        return try printStat(allocator, &[_]FileStat{self});
    }
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

    /// go-git `FileStats.String` / `printStat`. Caller frees with `self.allocator`.
    pub fn string(self: *const FileStats) Allocator.Error![]u8 {
        return try printStat(self.allocator, self.items);
    }
};

/// go-git `printStat` — git-style shortstat table.
/// Parts: `<pad><filename><pad>|<pad><changeNumber><pad><+++/---><newline>`
fn printStat(allocator: Allocator, file_stats: []const FileStat) Allocator.Error![]u8 {
    const max_graph_width: usize = 53;

    var max_name_len: usize = 0;
    var max_change_len: usize = 0;
    for (file_stats) |fs| {
        if (fs.name.len > max_name_len) max_name_len = fs.name.len;
        var buf: [32]u8 = undefined;
        const changes = std.fmt.bufPrint(&buf, "{d}", .{fs.addition + fs.deletion}) catch unreachable;
        if (changes.len > max_change_len) max_change_len = changes.len;
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    for (file_stats) |fs| {
        var add: usize = fs.addition;
        var del: usize = fs.deletion;
        const total = add + del;
        if (total > max_graph_width) {
            add = scaleLinear(add, max_graph_width, total);
            del = scaleLinear(del, max_graph_width, total);
        }

        const np = max_name_len - fs.name.len;
        var total_buf: [32]u8 = undefined;
        const total_s = std.fmt.bufPrint(&total_buf, "{d}", .{fs.addition + fs.deletion}) catch unreachable;
        const cp = max_change_len - total_s.len;

        try result.append(allocator, ' ');
        try result.appendSlice(allocator, fs.name);
        try result.appendNTimes(allocator, ' ', np);
        try result.appendSlice(allocator, " | ");
        try result.appendNTimes(allocator, ' ', cp);
        try result.appendSlice(allocator, total_s);
        try result.append(allocator, ' ');
        try result.appendNTimes(allocator, '+', add);
        try result.appendNTimes(allocator, '-', del);
        try result.append(allocator, '\n');
    }
    return try result.toOwnedSlice(allocator);
}

fn scaleLinear(it: usize, width: usize, max: usize) usize {
    if (it == 0 or max == 0) return 0;
    return 1 + (it * (width - 1) / max);
}

fn mapPatchErr(err: anyerror) PatchError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ObjectNotFound => error.ObjectNotFound,
        error.UnsupportedObject => error.UnsupportedObject,
        error.MalformedChange => error.MalformedChange,
        error.FileNotFound => error.FileNotFound,
        error.WriteFailed => error.WriteFailed,
        error.PatchBackend => error.PatchBackend,
        else => error.PatchBackend,
    };
}

/// go-git `getPatch` / `Changes.Patch` over a list of change pointers.
pub fn getPatch(allocator: Allocator, message: []const u8, changes: []const *const Change) PatchError!Patch {
    return buildPatch(allocator, message, changes) catch |err| mapPatchErr(err);
}

/// go-git `Changes.Patch` — build a `Patch` from a `Changes` list.
pub fn getPatchFromChanges(allocator: Allocator, message: []const u8, changes: *const Changes) PatchError!Patch {
    // Reuse getPatch without allocating a pointer table: items is []*Change.
    if (changes.items.len == 0) return buildPatch(allocator, message, &.{}) catch |err| mapPatchErr(err);
    // `[]*Change` is not coercible to `[]const *const Change`; build views.
    const views = allocator.alloc(*const Change, changes.items.len) catch |err| return mapPatchErr(err);
    defer allocator.free(views);
    for (changes.items, 0..) |c, i| views[i] = c;
    return buildPatch(allocator, message, views) catch |err| mapPatchErr(err);
}

fn buildPatch(allocator: Allocator, message: []const u8, changes: []const *const Change) anyerror!Patch {
    var fps: std.ArrayList(FilePatch) = .empty;
    errdefer {
        for (fps.items) |*fp| fp.deinit(allocator);
        fps.deinit(allocator);
    }

    for (changes) |c| {
        var fp = try filePatch(allocator, c);
        errdefer fp.deinit(allocator);
        try fps.append(allocator, fp);
    }

    const msg_owned = if (message.len > 0) try allocator.dupe(u8, message) else "";
    errdefer if (msg_owned.len > 0) allocator.free(msg_owned);

    return .{
        .message = msg_owned,
        .file_patches = try fps.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// go-git `(*Change).Patch`.
pub fn changePatch(allocator: Allocator, c: *const Change) PatchError!Patch {
    return getPatch(allocator, "", &[_]*const Change{c});
}

fn filePatch(allocator: Allocator, c: *const Change) anyerror!FilePatch {
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
        .chunks = try lineDiffChunks(allocator, from_content, to_content),
        .from = from_side,
        .to = to_side,
        .binary = false,
    };
}

// ---------------------------------------------------------------------------
// Line diff adapter (//src/utils/diff → patch Chunk)
// ---------------------------------------------------------------------------

/// Map utils/diff Operation (delete=-1, equal=0, insert=1) to patch Operation.
fn mapDiffOperation(op: utils_diff.Operation) Operation {
    return switch (op) {
        .delete => .delete,
        .equal => .equal,
        .insert => .add,
    };
}

/// Map object Operation → format_diff.Operation.
fn mapFormatOperation(op: Operation) format_diff.Operation {
    return switch (op) {
        .equal => .equal,
        .add => .add,
        .delete => .delete,
    };
}

/// go-git path: `utils/diff.Do` then convert to plumbing/format/diff chunks.
/// Coalescing is already done inside utils/diff. Caller owns the returned chunks
/// (including each `Chunk.content` when non-empty). Empty result is a non-owned
/// empty slice. Empty Myers texts are freed and stored as `""` so `Chunk.deinit`
/// never frees a non-owned empty view (and never frees string-literal test chunks).
fn lineDiffChunks(allocator: Allocator, src_text: []const u8, dst_text: []const u8) Allocator.Error![]Chunk {
    const diffs = try utils_diff.do(allocator, src_text, dst_text);
    errdefer utils_diff.freeDiffs(allocator, diffs);

    if (diffs.len == 0) {
        utils_diff.freeDiffs(allocator, diffs);
        return &.{};
    }

    const chunks = try allocator.alloc(Chunk, diffs.len);
    // On success, Diff.text is moved into chunks (or freed if empty); free Diff slice only.
    // Loop is infallible so outer freeDiffs errdefer still owns all texts until the free below.
    for (diffs, chunks) |d, *ch| {
        if (d.text.len == 0) {
            // Normalize empty owned text → non-owned "" (Chunk.deinit free-if-len>0).
            allocator.free(d.text);
            ch.* = .{
                .content = "",
                .operation = mapDiffOperation(d.operation),
            };
        } else {
            ch.* = .{
                .content = d.text,
                .operation = mapDiffOperation(d.operation),
            };
        }
    }
    allocator.free(diffs);
    return chunks;
}

// ---------------------------------------------------------------------------
// Unified encoder bridge (object Patch → format_diff.UnifiedEncoder)
// ---------------------------------------------------------------------------

/// go-git:
///   ue := fdiff.NewUnifiedEncoder(w, fdiff.DefaultContextLines)
///   return ue.Encode(p)
///
/// Builds temporary format_diff views that borrow object paths/chunk content
/// (no deep copy of text). Allocator only owns the view tables for Encode.
fn encodeViaUnifiedEncoder(patch: *const Patch, w: *Writer) anyerror!void {
    const allocator = patch.allocator;

    const fd_fps = try allocator.alloc(format_diff.FilePatch, patch.file_patches.len);
    defer allocator.free(fd_fps);

    // Per-file chunk tables (views into object Chunk.content).
    const chunk_tables = try allocator.alloc([]format_diff.Chunk, patch.file_patches.len);
    defer {
        for (chunk_tables) |t| {
            if (t.len > 0) allocator.free(t);
        }
        allocator.free(chunk_tables);
    }
    for (chunk_tables) |*t| t.* = &.{};

    for (patch.file_patches, 0..) |fp, i| {
        if (fp.chunks.len > 0) {
            const table = try allocator.alloc(format_diff.Chunk, fp.chunks.len);
            chunk_tables[i] = table;
            for (fp.chunks, table) |src, *dst| {
                dst.* = .{
                    .content = src.content,
                    .op = mapFormatOperation(src.operation),
                };
            }
        }

        fd_fps[i] = .{
            .from = if (fp.from.empty()) null else format_diff.File{
                .hash = fp.from.hash,
                .mode = fp.from.mode,
                .path = fp.from.path,
            },
            .to = if (fp.to.empty()) null else format_diff.File{
                .hash = fp.to.hash,
                .mode = fp.to.mode,
                .path = fp.to.path,
            },
            .chunks = chunk_tables[i],
            .is_binary = fp.binary,
        };
    }

    const fd_patch = format_diff.Patch{
        .message = patch.message,
        .file_patches = fd_fps,
    };

    var ue = format_diff.UnifiedEncoder.init(allocator, w, format_diff.DefaultContextLines);
    try ue.encode(fd_patch);
}

// ---------------------------------------------------------------------------
// File stats (go-git getFileStatsFromFilePatches)
// ---------------------------------------------------------------------------

fn getFileStats(allocator: Allocator, fps: []const FilePatch) Allocator.Error!FileStats {
    var list: std.ArrayList(FileStat) = .empty;
    errdefer {
        for (list.items) |s| if (s.name.len > 0) allocator.free(s.name);
        list.deinit(allocator);
    }
    for (fps) |fp| {
        // go-git: ignore empty patches (binary files, submodule refs updates)
        if (fp.chunks.len == 0) continue;

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

        // go-git naming: new → to; delete → from; rename → "from => to"; modify → from.
        const name = blk: {
            if (fp.from.empty()) {
                break :blk try allocator.dupe(u8, fp.to.path);
            } else if (fp.to.empty()) {
                break :blk try allocator.dupe(u8, fp.from.path);
            } else if (!std.mem.eql(u8, fp.from.path, fp.to.path)) {
                break :blk try std.fmt.allocPrint(allocator, "{s} => {s}", .{ fp.from.path, fp.to.path });
            } else {
                break :blk try allocator.dupe(u8, fp.from.path);
            }
        };

        try list.append(allocator, .{
            .name = name,
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

test "lineDiffChunks simple" {
    const gpa = std.testing.allocator;
    const chunks = try lineDiffChunks(gpa, "a\nb\n", "a\nc\n");
    defer {
        for (chunks) |ch| ch.deinit(gpa);
        gpa.free(chunks);
    }
    try std.testing.expectEqual(@as(usize, 3), chunks.len);
    try std.testing.expect(chunks[0].operation == .equal);
    try std.testing.expectEqualStrings("a\n", chunks[0].content);
    try std.testing.expect(chunks[1].operation == .delete);
    try std.testing.expectEqualStrings("b\n", chunks[1].content);
    try std.testing.expect(chunks[2].operation == .add);
    try std.testing.expectEqualStrings("c\n", chunks[2].content);
}

test "lineDiffChunks empty to content" {
    const gpa = std.testing.allocator;
    const chunks = try lineDiffChunks(gpa, "", "x\n");
    defer {
        for (chunks) |ch| ch.deinit(gpa);
        gpa.free(chunks);
    }
    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expect(chunks[0].operation == .add);
    try std.testing.expectEqualStrings("x\n", chunks[0].content);
}

test "filePatch insert text full unified" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");
    const Storage = memory.Storage;
    const storer = @import("storer");
    const tree_mod = @import("tree.zig");

    var store = Storage.init(gpa);
    defer store.deinit();
    const content = "hello\n";
    const blob = try store.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write(content);
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

    var hex: [plumbing.HexSize]u8 = undefined;
    const hash_s = bh.string(&hex);
    const expected = try std.fmt.allocPrint(gpa,
        \\diff --git a/hello.txt b/hello.txt
        \\new file mode 100644
        \\index 0000000000000000000000000000000000000000..{s}
        \\--- /dev/null
        \\+++ b/hello.txt
        \\@@ -0,0 +1 @@
        \\+hello
        \\
    , .{hash_s});
    defer gpa.free(expected);

    const s = try p.string();
    defer gpa.free(s);
    try std.testing.expectEqualStrings(expected, s);
}

test "filePatch binary encode line" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");
    const Storage = memory.Storage;
    const storer = @import("storer");
    const tree_mod = @import("tree.zig");

    var store = Storage.init(gpa);
    defer store.deinit();
    // NUL in the first sniff bytes → binary.
    const content = "\x00bin-data";
    const blob = try store.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write(content);
    const bh = try store.setEncodedObject(blob);

    var tb = tree_mod.Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tb.deinit();
    try tb.appendEntry("data.bin", filemode.Regular, bh);
    tb.sortEntries();

    const c = Change{
        .from = .{},
        .to = .{
            .name = "data.bin",
            .tree = &tb,
            .tree_entry = .{
                .name = "data.bin",
                .mode = filemode.Regular,
                .hash = bh,
            },
        },
    };
    var p = try changePatch(gpa, &c);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.file_patches.len);
    try std.testing.expect(p.file_patches[0].binary);

    var hex: [plumbing.HexSize]u8 = undefined;
    const hash_s = bh.string(&hex);
    const expected = try std.fmt.allocPrint(gpa,
        \\diff --git a/data.bin b/data.bin
        \\new file mode 100644
        \\index 0000000000000000000000000000000000000000..{s}
        \\Binary files /dev/null and b/data.bin differ
        \\
    , .{hash_s});
    defer gpa.free(expected);

    const s = try p.string();
    defer gpa.free(s);
    try std.testing.expectEqualStrings(expected, s);
}

test "getFileStats skips empty chunks and names renames" {
    const gpa = std.testing.allocator;

    // Binary / empty-chunk patch is skipped.
    const binary_fps = [_]FilePatch{.{
        .chunks = &.{},
        .binary = true,
        .from = .{ .mode = filemode.Regular, .path = "a.bin", .hash = plumbing.computeHash(.blob, "\x00a") },
        .to = .{ .mode = filemode.Regular, .path = "a.bin", .hash = plumbing.computeHash(.blob, "\x00b") },
    }};
    var empty_stats = try getFileStats(gpa, &binary_fps);
    defer empty_stats.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_stats.items.len);

    // Rename with content: "from => to".
    var rename_chunks = [_]Chunk{.{ .content = "line\n", .operation = .add }};
    const rename_fps = [_]FilePatch{.{
        .chunks = rename_chunks[0..],
        .from = .{
            .mode = filemode.Regular,
            .path = "old.txt",
            .hash = plumbing.computeHash(.blob, ""),
        },
        .to = .{
            .mode = filemode.Regular,
            .path = "new.txt",
            .hash = plumbing.computeHash(.blob, "line\n"),
        },
    }};
    var rename_stats = try getFileStats(gpa, &rename_fps);
    defer rename_stats.deinit();
    try std.testing.expectEqual(@as(usize, 1), rename_stats.items.len);
    try std.testing.expectEqualStrings("old.txt => new.txt", rename_stats.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), rename_stats.items[0].addition);
    try std.testing.expectEqual(@as(usize, 0), rename_stats.items[0].deletion);

    // Modify (same path): prefer from path.
    var mod_chunks = [_]Chunk{
        .{ .content = "a\n", .operation = .delete },
        .{ .content = "b\n", .operation = .add },
    };
    const mod_fps = [_]FilePatch{.{
        .chunks = mod_chunks[0..],
        .from = .{
            .mode = filemode.Regular,
            .path = "same.txt",
            .hash = plumbing.computeHash(.blob, "a\n"),
        },
        .to = .{
            .mode = filemode.Regular,
            .path = "same.txt",
            .hash = plumbing.computeHash(.blob, "b\n"),
        },
    }};
    var mod_stats = try getFileStats(gpa, &mod_fps);
    defer mod_stats.deinit();
    try std.testing.expectEqual(@as(usize, 1), mod_stats.items.len);
    try std.testing.expectEqualStrings("same.txt", mod_stats.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), mod_stats.items[0].addition);
    try std.testing.expectEqual(@as(usize, 1), mod_stats.items[0].deletion);

    // Insert naming: to path; delete naming: from path.
    var ins_chunks = [_]Chunk{.{ .content = "n\n", .operation = .add }};
    const ins_fps = [_]FilePatch{.{
        .chunks = ins_chunks[0..],
        .from = .{},
        .to = .{ .mode = filemode.Regular, .path = "new.txt", .hash = plumbing.computeHash(.blob, "n\n") },
    }};
    var ins_stats = try getFileStats(gpa, &ins_fps);
    defer ins_stats.deinit();
    try std.testing.expectEqualStrings("new.txt", ins_stats.items[0].name);

    var del_chunks = [_]Chunk{.{ .content = "o\n", .operation = .delete }};
    const del_fps = [_]FilePatch{.{
        .chunks = del_chunks[0..],
        .from = .{ .mode = filemode.Regular, .path = "gone.txt", .hash = plumbing.computeHash(.blob, "o\n") },
        .to = .{},
    }};
    var del_stats = try getFileStats(gpa, &del_fps);
    defer del_stats.deinit();
    try std.testing.expectEqualStrings("gone.txt", del_stats.items[0].name);
}

// go-git PatchSuite.TestFileStatsString / printStat cases
test "FileStats string printStat formatting" {
    const gpa = std.testing.allocator;

    // no files changed
    {
        var fs: FileStats = .{ .items = &.{}, .allocator = gpa };
        const s = try fs.string();
        defer gpa.free(s);
        try std.testing.expectEqualStrings("", s);
    }

    // one file touched - no changes
    {
        const s = try (FileStat{ .name = "file1" }).string(gpa);
        defer gpa.free(s);
        try std.testing.expectEqualStrings(" file1 | 0 \n", s);
    }

    // one file changed
    {
        const s = try (FileStat{ .name = "file1", .addition = 1 }).string(gpa);
        defer gpa.free(s);
        try std.testing.expectEqualStrings(" file1 | 1 +\n", s);
    }

    // one file changed with one addition and one deletion
    {
        const s = try (FileStat{
            .name = ".github/workflows/git.yml",
            .addition = 1,
            .deletion = 1,
        }).string(gpa);
        defer gpa.free(s);
        try std.testing.expectEqualStrings(" .github/workflows/git.yml | 2 +-\n", s);
    }

    // two files changed
    {
        var items = [_]FileStat{
            .{ .name = ".github/workflows/git.yml", .addition = 1, .deletion = 1 },
            .{ .name = "cli/go-git/go.mod", .addition = 4, .deletion = 4 },
        };
        var fs: FileStats = .{ .items = items[0..], .allocator = gpa };
        const s = try fs.string();
        defer gpa.free(s);
        try std.testing.expectEqualStrings(
            " .github/workflows/git.yml | 2 +-\n cli/go-git/go.mod         | 8 ++++----\n",
            s,
        );
    }

    // three files changed (additions only)
    {
        var items = [_]FileStat{
            .{ .name = ".github/workflows/git.yml", .addition = 3, .deletion = 3 },
            .{ .name = "worktree.go", .addition = 107 },
            .{ .name = "worktree_test.go", .addition = 75 },
        };
        var fs: FileStats = .{ .items = items[0..], .allocator = gpa };
        const s = try fs.string();
        defer gpa.free(s);
        try std.testing.expectEqualStrings(
            " .github/workflows/git.yml |   6 +++---\n" ++
                " worktree.go               | 107 +++++++++++++++++++++++++++++++++++++++++++++++++++++\n" ++
                " worktree_test.go          |  75 +++++++++++++++++++++++++++++++++++++++++++++++++++++\n",
            s,
        );
    }

    // three files changed with deletions and additions (graph scaled)
    {
        var items = [_]FileStat{
            .{ .name = ".github/workflows/git.yml", .addition = 3, .deletion = 3 },
            .{ .name = "worktree.go", .addition = 107, .deletion = 217 },
            .{ .name = "worktree_test.go", .addition = 75, .deletion = 275 },
        };
        var fs: FileStats = .{ .items = items[0..], .allocator = gpa };
        const s = try fs.string();
        defer gpa.free(s);
        try std.testing.expectEqualStrings(
            " .github/workflows/git.yml |   6 +++---\n" ++
                " worktree.go               | 324 ++++++++++++++++++-----------------------------------\n" ++
                " worktree_test.go          | 350 ++++++++++++-----------------------------------------\n",
            s,
        );
    }
}

// go-git PatchStatsSuite.TestStatsWithRename — naming via getFileStats
test "FileStats rename naming foo => bar" {
    const gpa = std.testing.allocator;
    var chunks = [_]Chunk{
        .{ .content = "foo\n", .operation = .equal },
        .{ .content = "bar\n", .operation = .equal },
    };
    // Pure rename (same content) still produces equal chunks when patched; if only
    // equal chunks, additions/deletions stay 0 but name still uses rename form.
    const fps = [_]FilePatch{.{
        .chunks = chunks[0..],
        .from = .{ .mode = filemode.Regular, .path = "foo", .hash = plumbing.computeHash(.blob, "foo\nbar\n") },
        .to = .{ .mode = filemode.Regular, .path = "bar", .hash = plumbing.computeHash(.blob, "foo\nbar\n") },
    }};
    var stats = try getFileStats(gpa, &fps);
    defer stats.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.items.len);
    try std.testing.expectEqualStrings("foo => bar", stats.items[0].name);
}

test "Patch stats from changePatch insert" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");
    const Storage = memory.Storage;
    const storer = @import("storer");
    const tree_mod = @import("tree.zig");

    var store = Storage.init(gpa);
    defer store.deinit();
    const content = "a\nb\n";
    const blob = try store.newEncodedObject();
    blob.setType(.blob);
    _ = try blob.write(content);
    const bh = try store.setEncodedObject(blob);

    var tb = tree_mod.Tree.init(gpa, storer.ObjectGetter.from(Storage, &store));
    defer tb.deinit();
    try tb.appendEntry("f.txt", filemode.Regular, bh);
    tb.sortEntries();

    const c = Change{
        .from = .{},
        .to = .{
            .name = "f.txt",
            .tree = &tb,
            .tree_entry = .{
                .name = "f.txt",
                .mode = filemode.Regular,
                .hash = bh,
            },
        },
    };
    var p = try changePatch(gpa, &c);
    defer p.deinit();
    var stats = try p.stats();
    defer stats.deinit();
    try std.testing.expectEqual(@as(usize, 1), stats.items.len);
    try std.testing.expectEqualStrings("f.txt", stats.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), stats.items[0].addition);
    try std.testing.expectEqual(@as(usize, 0), stats.items[0].deletion);

    const printed = try stats.string();
    defer gpa.free(printed);
    try std.testing.expectEqualStrings(" f.txt | 2 ++\n", printed);
}
