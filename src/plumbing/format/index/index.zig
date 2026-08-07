//! Index data model and methods (go-git `plumbing/format/index/index.go`).
//!
//! Types: Index, Entry, Stage, Tree, TreeEntry, ResolveUndo, ResolveUndoEntry,
//! EndOfIndexEntry. Methods: Add, Entry, Remove, Glob, String, SkipUnless.

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");

const err_mod = @import("error.zig");
const match_mod = @import("match.zig");

const Allocator = std.mem.Allocator;

pub const Error = err_mod.Error;
pub const Hash = plumbing.Hash;
pub const FileMode = filemode.FileMode;

// ---------------------------------------------------------------------------
// Extension signatures (go-git package vars)
// ---------------------------------------------------------------------------

/// Index file magic: `DIRC` (dircache).
pub const index_signature = [_]u8{ 'D', 'I', 'R', 'C' };
/// Cached tree extension: `TREE`.
pub const tree_ext_signature = [_]u8{ 'T', 'R', 'E', 'E' };
/// Resolve undo extension: `REUC`.
pub const resolve_undo_ext_signature = [_]u8{ 'R', 'E', 'U', 'C' };
/// End of index entry extension: `EOIE`.
pub const end_of_index_entry_ext_signature = [_]u8{ 'E', 'O', 'I', 'E' };

// ---------------------------------------------------------------------------
// Stage (merge stages)
// ---------------------------------------------------------------------------

/// Stage during merge (go-git `Stage`). Stored as the 2-bit stage field value.
pub const Stage = i32;

/// Default stage name in go-git (`Merged Stage = 1`). Note: normal index
/// entries decoded from disk have stage **0**; this constant equals
/// `AncestorMode` by design in go-git.
pub const Merged: Stage = 1;
/// Base revision in a merge (`AncestorMode Stage = 1`).
pub const AncestorMode: Stage = 1;
/// First tree revision, ours (`OurMode Stage = 2`).
pub const OurMode: Stage = 2;
/// Second tree revision, theirs (`TheirMode Stage = 3`).
pub const TheirMode: Stage = 3;

// ---------------------------------------------------------------------------
// Time (maps go-git `time.Time`)
// ---------------------------------------------------------------------------

/// Instant for index timestamps.
///
/// Maps go-git `time.Time`:
/// - `sec`  = `time.Time.Unix()` (seconds since Unix epoch)
/// - `nsec` = `time.Time.Nanosecond()` (0..999_999_999)
///
/// Zero / unset time (go-git `time.Time{}.IsZero()`) is `sec == 0 and nsec == 0`.
/// The on-disk index stores each as a pair of uint32 (seconds, nanoseconds).
pub const Time = struct {
    sec: i64 = 0,
    nsec: i32 = 0,

    /// True when both components are zero (go-git `IsZero`).
    pub fn isZero(self: Time) bool {
        return self.sec == 0 and self.nsec == 0;
    }

    /// Build from Unix seconds + nanoseconds (go-git `time.Unix(sec, nsec)`).
    pub fn unix(sec: i64, nsec: i64) Time {
        return .{ .sec = sec, .nsec = @intCast(nsec) };
    }
};

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

/// One file (or one merge stage of a file) in the index (go-git `Entry`).
///
/// `name` is owned by the entry when it lives in an `Index` (freed by
/// `Index.deinit` or by `Entry.deinit` after `remove` transfers ownership).
pub const Entry = struct {
    /// SHA-1 of the represented blob (go-git `Hash`).
    hash: Hash = plumbing.ZeroHash,
    /// Path relative to the top level, with `/` separators (go-git `Name`).
    name: []const u8 = "",
    /// ctime (go-git `CreatedAt`).
    created_at: Time = .{},
    /// mtime (go-git `ModifiedAt`).
    modified_at: Time = .{},
    /// Device and inode from stat (go-git `Dev`, `Inode`).
    dev: u32 = 0,
    inode: u32 = 0,
    /// Git file mode (go-git `Mode`).
    mode: FileMode = filemode.Empty,
    /// Owner ids (go-git `UID`, `GID`).
    uid: u32 = 0,
    gid: u32 = 0,
    /// File size, truncated to 32-bit (go-git `Size`).
    size: u32 = 0,
    /// Merge stage (go-git `Stage`).
    stage: Stage = 0,
    /// Sparse checkout skip-worktree bit (go-git `SkipWorktree`).
    skip_worktree: bool = false,
    /// Intent-to-add bit, `git add -N` (go-git `IntentToAdd`).
    intent_to_add: bool = false,

    /// Free owned `name` (call after `Index.remove` transfers the entry).
    pub fn deinit(self: *Entry, allocator: Allocator) void {
        if (self.name.len != 0) allocator.free(self.name);
        self.name = "";
    }

    /// Debug string equivalent to `git ls-files --stage --debug` for one entry
    /// (go-git `Entry.String`). Caller frees the returned slice.
    pub fn string(self: *const Entry, allocator: Allocator) Allocator.Error![]u8 {
        var hash_hex: [plumbing.HexSize]u8 = undefined;
        const hash_s = self.hash.string(&hash_hex);

        // go-git Entry.String: "%06o %s %d\t%s\n" + ctime/mtime/dev/uid/size lines.
        return std.fmt.allocPrint(
            allocator,
            "{o:0>6} {s} {d}\t{s}\n  ctime: {d}:{d}\n  mtime: {d}:{d}\n  dev: {d}\tino: {d}\n  uid: {d}\tgid: {d}\n  size: {d}\tflags: {x}\n",
            .{
                self.mode,
                hash_s,
                self.stage,
                self.name,
                self.created_at.sec,
                self.created_at.nsec,
                self.modified_at.sec,
                self.modified_at.nsec,
                self.dev,
                self.inode,
                self.uid,
                self.gid,
                self.size,
                @as(u32, 0),
            },
        );
    }
};

// ---------------------------------------------------------------------------
// Tree (cached tree extension)
// ---------------------------------------------------------------------------

/// Cached tree extension (go-git `Tree`).
pub const Tree = struct {
    entries: std.ArrayList(TreeEntry) = .empty,

    pub fn deinit(self: *Tree, allocator: Allocator) void {
        for (self.entries.items) |*te| te.deinit(allocator);
        self.entries.deinit(allocator);
    }
};

/// One entry of a cached tree (go-git `TreeEntry`).
pub const TreeEntry = struct {
    /// Path component relative to parent (go-git `Path`). Owned.
    path: []const u8 = "",
    /// Number of index entries covered; negative means invalidated (go-git `Entries`).
    entries: i32 = 0,
    /// Number of subtrees (go-git `Trees`).
    trees: i32 = 0,
    /// Object name for the tree that would be written (go-git `Hash`).
    hash: Hash = plumbing.ZeroHash,

    pub fn deinit(self: *TreeEntry, allocator: Allocator) void {
        if (self.path.len != 0) allocator.free(self.path);
        self.path = "";
    }
};

// ---------------------------------------------------------------------------
// Resolve undo
// ---------------------------------------------------------------------------

/// Resolve-undo extension (go-git `ResolveUndo`).
pub const ResolveUndo = struct {
    entries: std.ArrayList(ResolveUndoEntry) = .empty,

    pub fn deinit(self: *ResolveUndo, allocator: Allocator) void {
        for (self.entries.items) |*e| e.deinit(allocator);
        self.entries.deinit(allocator);
    }
};

/// One resolved conflict path (go-git `ResolveUndoEntry`).
///
/// go-git uses `map[Stage]plumbing.Hash`. Stages present are 1..3 only.
/// `stages[s]` is non-null when stage `s` was recorded.
pub const ResolveUndoEntry = struct {
    /// Full path relative to repo root (go-git `Path`). Owned.
    path: []const u8 = "",
    /// Hash per stage index 0..3; only indices 1..3 are used. Null = absent.
    stages: [4]?Hash = .{null} ** 4,

    pub fn deinit(self: *ResolveUndoEntry, allocator: Allocator) void {
        if (self.path.len != 0) allocator.free(self.path);
        self.path = "";
    }

    /// Number of stages present (go-git `len(Stages)`).
    pub fn stageCount(self: *const ResolveUndoEntry) usize {
        var n: usize = 0;
        for (self.stages) |h| {
            if (h != null) n += 1;
        }
        return n;
    }

    /// Set hash for a stage (go-git `Stages[s] = h`).
    pub fn setStage(self: *ResolveUndoEntry, s: Stage, h: Hash) void {
        const i: usize = @intCast(s);
        if (i < self.stages.len) self.stages[i] = h;
    }

    /// Get hash for a stage, if present.
    pub fn getStage(self: *const ResolveUndoEntry, s: Stage) ?Hash {
        const i: usize = @intCast(s);
        if (i >= self.stages.len) return null;
        return self.stages[i];
    }
};

// ---------------------------------------------------------------------------
// End of Index Entry
// ---------------------------------------------------------------------------

/// End of Index Entry extension (go-git `EndOfIndexEntry`).
pub const EndOfIndexEntry = struct {
    /// Offset to the end of the index entries (go-git `Offset`).
    offset: u32 = 0,
    /// SHA-1 over extension types and sizes, not contents (go-git `Hash`).
    hash: Hash = plumbing.ZeroHash,
};

// ---------------------------------------------------------------------------
// Index
// ---------------------------------------------------------------------------

/// Git index (dircache) in memory (go-git `Index`).
///
/// Entries are owned by the index (names freed in `deinit`). Optional
/// extension pointers are owned when non-null.
pub const Index = struct {
    allocator: Allocator,
    /// Index format version (go-git `Version`). Supported: 2, 3, 4.
    version: u32 = 0,
    /// Index entries; order is not guaranteed (go-git `Entries`).
    entries: std.ArrayList(Entry) = .empty,
    /// Cached tree extension (go-git `Cache`).
    cache: ?*Tree = null,
    /// Resolve undo extension (go-git `ResolveUndo`).
    resolve_undo: ?*ResolveUndo = null,
    /// End of index entry extension (go-git `EndOfIndexEntry`).
    end_of_index_entry: ?*EndOfIndexEntry = null,
    /// Modification time of the index file (go-git `ModTime`).
    mod_time: Time = .{},

    /// Create an empty index (caller supplies allocator for owned fields).
    pub fn init(allocator: Allocator) Index {
        return .{ .allocator = allocator };
    }

    /// Free all owned entries and extensions.
    pub fn deinit(self: *Index) void {
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        if (self.cache) |t| {
            t.deinit(self.allocator);
            self.allocator.destroy(t);
        }
        if (self.resolve_undo) |ru| {
            ru.deinit(self.allocator);
            self.allocator.destroy(ru);
        }
        if (self.end_of_index_entry) |e| {
            self.allocator.destroy(e);
        }
        self.* = undefined;
    }

    /// Create a new entry for `path` and append it (go-git `Add`).
    ///
    /// Path separators are normalised to `/` (go-git `filepath.ToSlash`).
    /// The caller should ensure no other entry with the same path exists.
    /// Returned pointer is valid until the next `entries` reallocation.
    pub fn add(self: *Index, path: []const u8) Allocator.Error!*Entry {
        const name = try toSlashOwned(self.allocator, path);
        errdefer self.allocator.free(name);
        try self.entries.append(self.allocator, .{ .name = name });
        return &self.entries.items[self.entries.items.len - 1];
    }

    /// Return the entry matching `path`, if any (go-git `Entry`).
    pub fn entry(self: *Index, path: []const u8) Error!*Entry {
        for (self.entries.items) |*e| {
            if (pathEqualSlash(e.name, path)) return e;
        }
        return Error.EntryNotFound;
    }

    /// Remove the entry matching `path` and return it (go-git `Remove`).
    ///
    /// Ownership of the returned `Entry` (including `name`) transfers to the
    /// caller; call `Entry.deinit(allocator)` when done.
    pub fn remove(self: *Index, path: []const u8) Error!Entry {
        for (self.entries.items, 0..) |*e, i| {
            if (pathEqualSlash(e.name, path)) {
                return self.entries.orderedRemove(i);
            }
        }
        return Error.EntryNotFound;
    }

    /// All entries matching `pattern`, or empty slice if none (go-git `Glob`).
    ///
    /// Pattern syntax matches `filepath.Glob`. Returned slice holds pointers
    /// into `self.entries`; free the slice with `allocator.free`, not the
    /// entries. Order follows index entry order.
    pub fn glob(self: *Index, pattern: []const u8) (Error || Allocator.Error)![]*Entry {
        const pat = try toSlashOwned(self.allocator, pattern);
        defer self.allocator.free(pat);

        var matches: std.ArrayList(*Entry) = .empty;
        errdefer matches.deinit(self.allocator);

        for (self.entries.items) |*e| {
            const m = try match_mod.match(pat, e.name);
            if (m) try matches.append(self.allocator, e);
        }
        return try matches.toOwnedSlice(self.allocator);
    }

    /// Concatenation of every entry's debug string (go-git `Index.String`).
    /// Equivalent to `git ls-files --stage --debug`. Caller frees the result.
    pub fn string(self: *const Index, allocator: Allocator) Allocator.Error![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        for (self.entries.items) |*e| {
            const s = try e.string(allocator);
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        }
        return try buf.toOwnedSlice(allocator);
    }

    /// Mark entries not covered by `patterns` with skip-worktree (go-git `SkipUnless`).
    ///
    /// Patterns are path prefixes of the form `A`, `A/B`, `A/B/C`. An entry is
    /// included when its name has any pattern as a prefix (`strings.HasPrefix`).
    pub fn skipUnless(self: *Index, patterns: []const []const u8) void {
        for (self.entries.items) |*e| {
            var include = false;
            for (patterns) |pattern| {
                if (std.mem.startsWith(u8, e.name, pattern)) {
                    include = true;
                    break;
                }
            }
            if (!include) {
                e.skip_worktree = true;
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Path helpers (filepath.ToSlash)
// ---------------------------------------------------------------------------

/// Own a copy of `path` with `\\` replaced by `/`.
fn toSlashOwned(allocator: Allocator, path: []const u8) Allocator.Error![]u8 {
    const out = try allocator.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

/// Compare `stored` (already slash-normalised) to `path` with ToSlash semantics.
/// `filepath.ToSlash` only replaces `\\` → `/`; length is unchanged.
fn pathEqualSlash(stored: []const u8, path: []const u8) bool {
    if (stored.len != path.len) return false;
    for (stored, path) |a, b| {
        const bb: u8 = if (b == '\\') '/' else b;
        if (a != bb) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests — go-git plumbing/format/index/index_test.go
// ---------------------------------------------------------------------------

test "TestIndexAdd" {
    // go-git IndexSuite.TestIndexAdd
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();

    const e = try idx.add("foo");
    e.size = 42;

    const found = try idx.entry("foo");
    try std.testing.expectEqualStrings("foo", found.name);
    try std.testing.expectEqual(@as(u32, 42), found.size);
}

test "TestIndexEntry" {
    // go-git IndexSuite.TestIndexEntry
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();

    const n1 = try allocator.dupe(u8, "foo");
    try idx.entries.append(allocator, .{ .name = n1, .size = 42 });
    const n2 = try allocator.dupe(u8, "bar");
    try idx.entries.append(allocator, .{ .name = n2, .size = 82 });

    const e = try idx.entry("foo");
    try std.testing.expectEqualStrings("foo", e.name);

    try std.testing.expectError(Error.EntryNotFound, idx.entry("missing"));
}

test "TestIndexRemove" {
    // go-git IndexSuite.TestIndexRemove
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();

    const n1 = try allocator.dupe(u8, "foo");
    try idx.entries.append(allocator, .{ .name = n1, .size = 42 });
    const n2 = try allocator.dupe(u8, "bar");
    try idx.entries.append(allocator, .{ .name = n2, .size = 82 });

    var removed = try idx.remove("foo");
    defer removed.deinit(allocator);
    try std.testing.expectEqualStrings("foo", removed.name);

    try std.testing.expectError(Error.EntryNotFound, idx.remove("foo"));
}

test "TestIndexGlob" {
    // go-git IndexSuite.TestIndexGlob
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();

    const names = [_][]const u8{ "foo/bar/bar", "foo/baz/qux", "fux" };
    for (names) |n| {
        const owned = try allocator.dupe(u8, n);
        try idx.entries.append(allocator, .{ .name = owned, .size = if (n[0] == 'f' and n.len == 3) 82 else 42 });
    }

    // filepath.Join("foo", "b*") → "foo/b*" on Unix
    {
        const m = try idx.glob("foo/b*");
        defer allocator.free(m);
        try std.testing.expectEqual(@as(usize, 2), m.len);
        try std.testing.expectEqualStrings("foo/bar/bar", m[0].name);
        try std.testing.expectEqualStrings("foo/baz/qux", m[1].name);
    }
    {
        const m = try idx.glob("f*");
        defer allocator.free(m);
        try std.testing.expectEqual(@as(usize, 3), m.len);
    }
    {
        const m = try idx.glob("f*/baz/q*");
        defer allocator.free(m);
        try std.testing.expectEqual(@as(usize, 1), m.len);
    }
}

test "IndexSuite.SkipUnless sets skip_worktree" {
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();

    _ = try idx.add("A/x");
    _ = try idx.add("B/y");
    _ = try idx.add("A/B/z");

    idx.skipUnless(&[_][]const u8{ "A", "A/B" });

    try std.testing.expect(!(try idx.entry("A/x")).skip_worktree);
    try std.testing.expect((try idx.entry("B/y")).skip_worktree);
    try std.testing.expect(!(try idx.entry("A/B/z")).skip_worktree);
}

test "Entry.string stage debug format" {
    const allocator = std.testing.allocator;
    var e = Entry{
        .mode = filemode.Regular,
        .hash = plumbing.ZeroHash,
        .stage = TheirMode,
        .name = "foo",
        .created_at = Time.unix(1, 2),
        .modified_at = Time.unix(3, 4),
        .dev = 5,
        .inode = 6,
        .uid = 7,
        .gid = 8,
        .size = 9,
    };
    const s = try e.string(allocator);
    defer allocator.free(s);

    try std.testing.expect(std.mem.startsWith(u8, s, "100644 "));
    try std.testing.expect(std.mem.indexOf(u8, s, " 3\tfoo\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "  ctime: 1:2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "  mtime: 3:4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "  dev: 5\tino: 6\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "  uid: 7\tgid: 8\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "  size: 9\tflags: 0\n") != null);
}

test "Stage constants match go-git" {
    try std.testing.expectEqual(@as(Stage, 1), Merged);
    try std.testing.expectEqual(@as(Stage, 1), AncestorMode);
    try std.testing.expectEqual(@as(Stage, 2), OurMode);
    try std.testing.expectEqual(@as(Stage, 3), TheirMode);
    try std.testing.expectEqual(Merged, AncestorMode);
}

test "Time isZero" {
    try std.testing.expect((Time{}).isZero());
    try std.testing.expect(!Time.unix(1, 0).isZero());
    try std.testing.expect(!Time.unix(0, 1).isZero());
}

test "Index.string concatenates entry debug lines" {
    // go-git Index.String — concatenation of every Entry.String()
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();

    const e1 = try idx.add("a");
    e1.mode = filemode.Regular;
    e1.stage = 0;
    e1.size = 1;
    const e2 = try idx.add("b");
    e2.mode = filemode.Regular;
    e2.stage = TheirMode;
    e2.size = 2;

    const s = try idx.string(allocator);
    defer allocator.free(s);

    try std.testing.expect(std.mem.indexOf(u8, s, "\ta\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "\tb\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "  size: 1\tflags: 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "  size: 2\tflags: 0\n") != null);
    // Stage digits appear before the tab+name (go-git "%d\t%s").
    try std.testing.expect(std.mem.indexOf(u8, s, " 0\ta\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, " 3\tb\n") != null);
}
