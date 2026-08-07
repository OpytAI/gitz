//! Tree object (go-git `plumbing/object/tree.go`).
//!
//! Git tree: ordered list of `TreeEntry` (`mode SP name NUL hash20`).
//! Navigation uses an optional `*memory.Storage`. Blob/file views use
//! `blob.zig` / `file.zig` when loading content.

const std = @import("std");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const memory = @import("memory");
const storer = @import("storer");

const blob_mod = @import("blob.zig");
const file_mod = @import("file.zig");
const Error = @import("error.zig").Error;

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const ObjectType = plumbing.ObjectType;
const MemoryObject = plumbing.MemoryObject;
const FileMode = filemode.FileMode;
const Storage = memory.Storage;
const ObjectGetter = storer.ObjectGetter;
const File = file_mod.File;

/// Maximum recursion depth for `TreeWalker` (go-git `maxTreeDepth`).
pub const max_tree_depth: usize = 1024;

const starting_stack_size: usize = 8;

// ---------------------------------------------------------------------------
// TreeEntry
// ---------------------------------------------------------------------------

/// One tree entry (go-git `TreeEntry`).
///
/// `name` is owned by the parent `Tree` after `decode` / `appendEntry`.
pub const TreeEntry = struct {
    name: []const u8,
    mode: FileMode,
    hash: Hash,
};

// ---------------------------------------------------------------------------
// Tree
// ---------------------------------------------------------------------------

/// Logical tree object (go-git `Tree`).
pub const Tree = struct {
    allocator: Allocator,
    entries: std.ArrayListUnmanaged(TreeEntry) = .empty,
    hash: Hash = ZeroHash,
    /// Optional object storer for navigation (go-git `Tree.s`).
    storer: ?ObjectGetter = null,
    /// Path → subtree cache for `findEntry` (go-git `Tree.t`).
    path_cache: std.StringHashMapUnmanaged(*Tree) = .empty,
    entries_sorted: bool = true,

    pub fn init(allocator: Allocator, s: ?ObjectGetter) Tree {
        return .{
            .allocator = allocator,
            .storer = s,
        };
    }

    pub fn deinit(self: *Tree) void {
        self.clearEntries();
        self.entries.deinit(self.allocator);
        self.clearPathCache();
        self.path_cache.deinit(self.allocator);
        self.* = undefined;
    }

    fn clearEntries(self: *Tree) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.name);
        }
        self.entries.clearRetainingCapacity();
    }

    fn clearPathCache(self: *Tree) void {
        var it = self.path_cache.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            kv.value_ptr.*.deinit();
            self.allocator.destroy(kv.value_ptr.*);
        }
        self.path_cache.clearRetainingCapacity();
    }

    /// Append an entry, duplicating `name`.
    pub fn appendEntry(self: *Tree, name: []const u8, mode: FileMode, hash: Hash) Allocator.Error!void {
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.entries.append(self.allocator, .{
            .name = owned,
            .mode = mode,
            .hash = hash,
        });
        self.entries_sorted = false;
    }

    /// Sort entries by git tree order (directory names as `name/`).
    pub fn sortEntries(self: *Tree) void {
        std.mem.sort(TreeEntry, self.entries.items, {}, struct {
            fn less(_: void, a: TreeEntry, b: TreeEntry) bool {
                return compareSortNames(a.name, a.mode == filemode.Dir, b.name, b.mode == filemode.Dir) == .lt;
            }
        }.less);
        self.entries_sorted = true;
    }

    /// go-git `Tree.ID`.
    pub fn id(self: *const Tree) Hash {
        return self.hash;
    }

    /// go-git `Tree.Type`.
    pub fn objectType(_: *const Tree) ObjectType {
        return .tree;
    }

    fn reset(self: *Tree) void {
        self.clearEntries();
        self.clearPathCache();
        self.hash = ZeroHash;
        self.entries_sorted = true;
    }

    // --- Decode / Encode ---

    /// go-git `(*Tree).Decode`.
    pub fn decode(self: *Tree, o: *MemoryObject) (Error || Allocator.Error)!void {
        if (o.object_type != .tree) return error.UnsupportedObject;

        self.reset();
        self.hash = o.hash();
        self.entries_sorted = true;
        if (o.size == 0) return;

        const data = o.readerBytes();
        var pos: usize = 0;
        var prev_sort: ?[]u8 = null;
        defer if (prev_sort) |p| self.allocator.free(p);

        while (pos < data.len) {
            const sp = std.mem.indexOfScalarPos(u8, data, pos, ' ') orelse return error.MalformedTree;
            const mode_str = data[pos..sp];
            pos = sp + 1;

            const raw_mode = filemode.new(mode_str) catch return error.MalformedTree;
            const mode = canonicalTreeMode(raw_mode);

            const nul = std.mem.indexOfScalarPos(u8, data, pos, 0) orelse return error.MalformedTree;
            if (nul == pos) return error.MalformedTree;
            const base_name = data[pos..nul];
            pos = nul + 1;

            if (pos + plumbing.Size > data.len) return error.MalformedTree;
            var hash_bytes: [plumbing.Size]u8 = undefined;
            @memcpy(&hash_bytes, data[pos .. pos + plumbing.Size]);
            pos += plumbing.Size;

            const owned_name = try self.allocator.dupe(u8, base_name);
            errdefer self.allocator.free(owned_name);

            const te = TreeEntry{
                .name = owned_name,
                .mode = mode,
                .hash = Hash.fromBytes(hash_bytes),
            };

            const sort_name = try sortNameAlloc(self.allocator, &te);
            defer self.allocator.free(sort_name);

            if (self.entries.items.len != 0) {
                if (prev_sort) |prev| {
                    if (std.mem.order(u8, prev, sort_name) == .gt) {
                        self.entries_sorted = false;
                    }
                }
            }
            if (prev_sort) |p| self.allocator.free(p);
            prev_sort = try self.allocator.dupe(u8, sort_name);

            try self.entries.append(self.allocator, te);
        }
    }

    /// go-git `(*Tree).Encode`. Entries must be sorted by git tree order.
    pub fn encode(self: *const Tree, o: *MemoryObject) (Error || Allocator.Error)!void {
        if (!isEntriesSorted(self.entries.items)) return error.EntriesNotSorted;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        for (self.entries.items) |ent| {
            if (std.mem.indexOfScalar(u8, ent.name, 0) != null) {
                return error.MalformedTree;
            }
            var mode_buf: [16]u8 = undefined;
            const mode_str = std.fmt.bufPrint(&mode_buf, "{o}", .{ent.mode}) catch unreachable;
            try buf.appendSlice(self.allocator, mode_str);
            try buf.append(self.allocator, ' ');
            try buf.appendSlice(self.allocator, ent.name);
            try buf.append(self.allocator, 0);
            try buf.appendSlice(self.allocator, ent.hash.bytes[0..]);
        }

        o.setType(.tree);
        try o.setContent(buf.items);
    }

    // --- Lookup ---

    /// go-git `(*Tree).FindEntry`.
    pub fn findEntry(self: *Tree, path: []const u8) !*const TreeEntry {
        try validTreePath(path);

        const path_parts = try splitPath(self.allocator, path);
        defer self.allocator.free(path_parts);
        if (path_parts.len == 0) return error.InvalidPath;

        var starting_tree: *Tree = self;
        var path_current: []u8 = try self.allocator.dupe(u8, "");
        defer self.allocator.free(path_current);
        var parts = path_parts;

        if (parts.len > 2) {
            var i: usize = parts.len - 1;
            while (i > 1) : (i -= 1) {
                const candidate = try joinPathParts(self.allocator, parts[0..i]);
                defer self.allocator.free(candidate);
                if (self.path_cache.get(candidate)) |cached| {
                    starting_tree = cached;
                    parts = parts[i..];
                    self.allocator.free(path_current);
                    path_current = try self.allocator.dupe(u8, candidate);
                    break;
                }
            }
        }

        var tree_ptr: *Tree = starting_tree;
        while (parts.len > 1) {
            tree_ptr = try tree_ptr.dir(parts[0]);
            const next_current = try simpleJoinAlloc(self.allocator, path_current, parts[0]);
            self.allocator.free(path_current);
            path_current = next_current;

            // Cache under this root tree (go-git `t.t[pathCurrent] = tree`).
            if (self.path_cache.getEntry(path_current)) |existing| {
                existing.value_ptr.*.deinit();
                self.allocator.destroy(existing.value_ptr.*);
                existing.value_ptr.* = tree_ptr;
            } else {
                const key = try self.allocator.dupe(u8, path_current);
                errdefer self.allocator.free(key);
                try self.path_cache.put(self.allocator, key, tree_ptr);
            }
            parts = parts[1..];
        }

        return try tree_ptr.entryByName(parts[0]);
    }

    /// go-git `(*Tree).File`. `path` is borrowed into the returned `File.name`.
    pub fn file(self: *Tree, path: []const u8) !File {
        const e = self.findEntry(path) catch return error.FileNotFound;
        const s = self.storer orelse return error.FileNotFound;
        const b = blob_mod.getBlob(s, e.hash) catch |err| {
            if (err == error.ObjectNotFound) return error.FileNotFound;
            return err;
        };
        return file_mod.newFile(path, e.mode, &b);
    }

    /// go-git `(*Tree).Size`.
    pub fn sizeAt(self: *Tree, path: []const u8) !i64 {
        const e = self.findEntry(path) catch return error.EntryNotFound;
        const s = self.storer orelse return error.EntryNotFound;
        const obj = s.encodedObject(.any, e.hash) catch return error.EntryNotFound;
        return obj.size;
    }

    /// go-git `(*Tree).Tree` — subdirectory (heap; caller `deinit` + `destroy`).
    pub fn treeAt(self: *Tree, path: []const u8) !*Tree {
        const e = self.findEntry(path) catch return error.DirectoryNotFound;
        const s = self.storer orelse return error.DirectoryNotFound;
        return getTree(self.allocator, s, e.hash) catch |err| {
            if (err == error.ObjectNotFound) return error.DirectoryNotFound;
            return err;
        };
    }

    /// go-git `(*Tree).TreeEntryFile`.
    pub fn treeEntryFile(self: *Tree, e: *const TreeEntry) !File {
        try validTreePath(e.name);
        const s = self.storer orelse return error.ObjectNotFound;
        const b = try blob_mod.getBlob(s, e.hash);
        return file_mod.newFile(e.name, e.mode, &b);
    }

    /// go-git `(*Tree).Files` (allocation may fail).
    pub fn files(self: *Tree) Allocator.Error!FileIter {
        return FileIter.init(self);
    }

    fn dir(self: *Tree, base_name: []const u8) !*Tree {
        const ent = self.entryByName(base_name) catch return error.DirectoryNotFound;
        const s = self.storer orelse return error.DirectoryNotFound;
        return getTree(self.allocator, s, ent.hash);
    }

    fn entryByName(self: *Tree, base_name: []const u8) Error!*const TreeEntry {
        if (self.entries_sorted) {
            if (self.searchEntry(base_name)) |e| return e;
            return error.EntryNotFound;
        }

        var past_buf: [512]u8 = undefined;
        const use_past = base_name.len + 1 <= past_buf.len;
        if (use_past) {
            @memcpy(past_buf[0..base_name.len], base_name);
            past_buf[base_name.len] = '/';
        }
        const past_name = if (use_past) past_buf[0 .. base_name.len + 1] else base_name;

        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.name, base_name)) return e;
            if (use_past and compareSortNameToStr(e.*, past_name) == .gt) break;
        }
        return error.EntryNotFound;
    }

    fn searchEntry(self: *const Tree, base_name: []const u8) ?*const TreeEntry {
        const entry_idx = self.searchEntryIndex(base_name);
        if (entry_idx < self.entries.items.len and std.mem.eql(u8, self.entries.items[entry_idx].name, base_name)) {
            return &self.entries.items[entry_idx];
        }
        var slash_buf: [512]u8 = undefined;
        if (base_name.len + 1 <= slash_buf.len) {
            @memcpy(slash_buf[0..base_name.len], base_name);
            slash_buf[base_name.len] = '/';
            const key = slash_buf[0 .. base_name.len + 1];
            const idx1 = self.searchEntryIndex(key);
            if (idx1 < self.entries.items.len and std.mem.eql(u8, self.entries.items[idx1].name, base_name)) {
                return &self.entries.items[idx1];
            }
        }
        return null;
    }

    fn searchEntryIndex(self: *const Tree, name: []const u8) usize {
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (compareSortNameToStr(self.entries.items[mid], name) != .lt) {
                hi = mid;
            } else {
                lo = mid + 1;
            }
        }
        return lo;
    }
};

// ---------------------------------------------------------------------------
// getTree / decodeTree
// ---------------------------------------------------------------------------

fn objectGetterFrom(s: anytype) ?ObjectGetter {
    const T = @TypeOf(s);
    if (T == @TypeOf(null) or T == ?*ObjectGetter) return null;
    if (T == ObjectGetter) return s;
    if (T == ?ObjectGetter) return s;
    // `*Storage`, `*ObjectStorage`, or any pointer with encodedObject.
    return ObjectGetter.from(@TypeOf(s.*), s);
}

/// go-git `GetTree` — heap-allocates; caller must `deinit` then `destroy`.
///
/// `s` is any storer with `encodedObject(type, hash)` (`*memory.Storage`,
/// `ObjectGetter`, …). Matches commit.zig / package root call sites.
pub fn getTree(allocator: Allocator, s: anytype, h: Hash) !*Tree {
    const o = try s.encodedObject(ObjectType.tree, h);
    return decodeTree(allocator, s, o);
}

/// go-git `DecodeTree` — heap-allocates; caller must `deinit` then `destroy`.
pub fn decodeTree(allocator: Allocator, s: anytype, o: *MemoryObject) !*Tree {
    const t = try allocator.create(Tree);
    errdefer allocator.destroy(t);
    t.* = Tree.init(allocator, objectGetterFrom(s));
    errdefer t.deinit();
    try t.decode(o);
    return t;
}

/// Decode without attaching a storer (encode/decode unit tests).
pub fn decodeTreeNoStore(allocator: Allocator, o: *MemoryObject) (Error || Allocator.Error)!*Tree {
    const t = try allocator.create(Tree);
    errdefer allocator.destroy(t);
    t.* = Tree.init(allocator, null);
    errdefer t.deinit();
    try t.decode(o);
    return t;
}

/// Free a heap tree from `getTree` / `decodeTree`.
pub fn freeTree(allocator: Allocator, t: *Tree) void {
    t.deinit();
    allocator.destroy(t);
}

// ---------------------------------------------------------------------------
// TreeEntryIter / TreeWalker / TreeIter / FileIter
// ---------------------------------------------------------------------------

const TreeEntryIter = struct {
    t: *Tree,
    pos: usize = 0,

    fn next(self: *TreeEntryIter) error{EndOfStream}!TreeEntry {
        if (self.pos >= self.t.entries.items.len) return error.EndOfStream;
        const e = self.t.entries.items[self.pos];
        self.pos += 1;
        return e;
    }
};

/// go-git `TreeWalker`.
pub const TreeWalker = struct {
    allocator: Allocator,
    stack: std.ArrayListUnmanaged(TreeEntryIter) = .empty,
    owned: std.ArrayListUnmanaged(*Tree) = .empty,
    base: std.ArrayListUnmanaged(u8) = .empty,
    recursive: bool,
    seen: ?*std.AutoHashMapUnmanaged(Hash, void),
    storer: ?ObjectGetter,
    root: *Tree,
    last_name: std.ArrayListUnmanaged(u8) = .empty,

    /// go-git `NewTreeWalker`.
    pub fn init(t: *Tree, recursive: bool, seen: ?*std.AutoHashMapUnmanaged(Hash, void)) Allocator.Error!TreeWalker {
        var w: TreeWalker = .{
            .allocator = t.allocator,
            .recursive = recursive,
            .seen = seen,
            .storer = t.storer,
            .root = t,
        };
        try w.stack.ensureTotalCapacity(t.allocator, starting_stack_size);
        try w.stack.append(t.allocator, .{ .t = t, .pos = 0 });
        return w;
    }

    pub fn close(self: *TreeWalker) void {
        for (self.owned.items) |tr| {
            tr.deinit();
            self.allocator.destroy(tr);
        }
        self.owned.deinit(self.allocator);
        self.stack.deinit(self.allocator);
        self.base.deinit(self.allocator);
        self.last_name.deinit(self.allocator);
        self.* = undefined;
    }

    /// go-git `(*TreeWalker).Next`.
    pub fn next(self: *TreeWalker) !struct { name: []const u8, entry: TreeEntry } {
        var obj: ?*Tree = null;
        var entry: TreeEntry = undefined;

        while (true) {
            if (self.stack.items.len == 0) return error.EndOfStream;
            if (self.stack.items.len > max_tree_depth) return error.MaxTreeDepth;

            const stack_i = self.stack.items.len - 1;
            entry = self.stack.items[stack_i].next() catch {
                _ = self.stack.pop();
                trimBaseParent(&self.base);
                continue;
            };

            if (self.seen) |sm| {
                if (sm.contains(entry.hash)) continue;
            }

            try validTreePath(entry.name);

            obj = null;
            if (entry.mode == filemode.Dir) {
                if (self.storer) |s| {
                    const heap = getTree(self.allocator, s, entry.hash) catch {
                        return error.EndOfStream;
                    };
                    try self.owned.append(self.allocator, heap);
                    obj = heap;
                } else {
                    return error.EndOfStream;
                }
            }

            self.last_name.clearRetainingCapacity();
            if (self.base.items.len > 0) {
                try self.last_name.appendSlice(self.allocator, self.base.items);
                try self.last_name.append(self.allocator, '/');
            }
            try self.last_name.appendSlice(self.allocator, entry.name);
            break;
        }

        if (self.recursive) {
            if (obj) |sub| {
                try self.stack.append(self.allocator, .{ .t = sub, .pos = 0 });
                if (self.base.items.len > 0) {
                    try self.base.append(self.allocator, '/');
                }
                try self.base.appendSlice(self.allocator, entry.name);
            }
        }

        return .{ .name = self.last_name.items, .entry = entry };
    }

    /// go-git `(*TreeWalker).Tree`.
    pub fn tree(self: *const TreeWalker) ?*Tree {
        var current: isize = @intCast(self.stack.items.len);
        current -= 1;
        if (current < 0) return null;
        if (self.stack.items[@intCast(current)].pos == 0) {
            current -= 1;
        }
        if (current < 0) return null;
        return self.stack.items[@intCast(current)].t;
    }
};

fn trimBaseParent(base: *std.ArrayListUnmanaged(u8)) void {
    if (base.items.len == 0) return;
    if (std.mem.lastIndexOfScalar(u8, base.items, '/')) |idx| {
        base.shrinkRetainingCapacity(idx);
    } else {
        base.clearRetainingCapacity();
    }
}

/// go-git `TreeIter`.
pub const TreeIter = struct {
    allocator: Allocator,
    storer: ObjectGetter,
    inner: memory.ObjectSnapshotIter,

    pub fn init(allocator: Allocator, s: ObjectGetter, inner: memory.ObjectSnapshotIter) TreeIter {
        return .{ .allocator = allocator, .storer = s, .inner = inner };
    }

    pub fn deinit(self: *TreeIter) void {
        self.inner.deinit();
        self.* = undefined;
    }

    pub fn close(self: *TreeIter) void {
        self.inner.close();
    }

    pub fn next(self: *TreeIter) !*Tree {
        while (true) {
            const obj = try self.inner.next();
            if (obj.object_type != .tree) continue;
            return try decodeTree(self.allocator, self.storer, obj);
        }
    }

    pub fn forEach(self: *TreeIter, cb: anytype) !void {
        defer self.close();
        while (true) {
            const t = self.next() catch |err| {
                if (err == error.EndOfStream) return;
                return err;
            };
            defer freeTree(self.allocator, t);
            @call(.auto, cb, .{t}) catch |err| {
                const e: anyerror = err;
                if (e == error.Stop) return;
                return e;
            };
        }
    }
};

/// go-git `NewTreeIter` over a memory storage.
pub fn newTreeIter(allocator: Allocator, s: *Storage) Allocator.Error!TreeIter {
    const inner = try s.iterEncodedObjects(.tree);
    return TreeIter.init(allocator, ObjectGetter.from(Storage, s), inner);
}

/// go-git `FileIter` (walks tree recursively; skips dirs/submodules).
pub const FileIter = struct {
    walker: TreeWalker,
    storer: ?ObjectGetter,
    /// Holds last path so `File.name` stays valid until the next `next`.
    name_buf: std.ArrayListUnmanaged(u8) = .empty,
    allocator: Allocator,
    /// When set (e.g. `Commit.files`), free the root tree on `close`.
    owned_root: ?*Tree = null,

    pub fn init(t: *Tree) Allocator.Error!FileIter {
        return .{
            .walker = try TreeWalker.init(t, true, null),
            .storer = t.storer,
            .allocator = t.allocator,
        };
    }

    pub fn close(self: *FileIter) void {
        self.walker.close();
        self.name_buf.deinit(self.allocator);
        if (self.owned_root) |t| freeTree(self.allocator, t);
        self.* = undefined;
    }

    pub fn next(self: *FileIter) !File {
        while (true) {
            const item = try self.walker.next();
            if (item.entry.mode == filemode.Dir or item.entry.mode == filemode.Submodule) {
                continue;
            }
            const s = self.storer orelse return error.ObjectNotFound;
            const b = try blob_mod.getBlob(s, item.entry.hash);
            self.name_buf.clearRetainingCapacity();
            try self.name_buf.appendSlice(self.allocator, item.name);
            return file_mod.newFile(self.name_buf.items, item.entry.mode, &b);
        }
    }

    pub fn forEach(self: *FileIter, cb: anytype) !void {
        defer self.close();
        while (true) {
            const f = self.next() catch |err| {
                if (err == error.EndOfStream) return;
                return err;
            };
            @call(.auto, cb, .{&f}) catch |err| {
                const e: anyerror = err;
                if (e == error.Stop) return;
                return e;
            };
        }
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn compareSortNames(a_name: []const u8, a_dir: bool, b_name: []const u8, b_dir: bool) std.math.Order {
    const a_extra: usize = if (a_dir) 1 else 0;
    const b_extra: usize = if (b_dir) 1 else 0;
    const a_total = a_name.len + a_extra;
    const b_total = b_name.len + b_extra;
    var ai: usize = 0;
    var bi: usize = 0;
    while (ai < a_total and bi < b_total) : ({
        ai += 1;
        bi += 1;
    }) {
        const ac: u8 = if (ai < a_name.len) a_name[ai] else '/';
        const bc: u8 = if (bi < b_name.len) b_name[bi] else '/';
        if (ac < bc) return .lt;
        if (ac > bc) return .gt;
    }
    if (a_total < b_total) return .lt;
    if (a_total > b_total) return .gt;
    return .eq;
}

fn compareSortNameToStr(e: TreeEntry, name: []const u8) std.math.Order {
    const e_dir = e.mode == filemode.Dir;
    const e_extra: usize = if (e_dir) 1 else 0;
    const e_total = e.name.len + e_extra;
    var ei: usize = 0;
    var ni: usize = 0;
    while (ei < e_total and ni < name.len) : ({
        ei += 1;
        ni += 1;
    }) {
        const ec: u8 = if (ei < e.name.len) e.name[ei] else '/';
        const nc = name[ni];
        if (ec < nc) return .lt;
        if (ec > nc) return .gt;
    }
    if (e_total < name.len) return .lt;
    if (e_total > name.len) return .gt;
    return .eq;
}

fn sortNameAlloc(allocator: Allocator, e: *const TreeEntry) Allocator.Error![]u8 {
    if (e.mode == filemode.Dir) {
        var buf = try allocator.alloc(u8, e.name.len + 1);
        @memcpy(buf[0..e.name.len], e.name);
        buf[e.name.len] = '/';
        return buf;
    }
    return try allocator.dupe(u8, e.name);
}

fn isEntriesSorted(entries: []const TreeEntry) bool {
    if (entries.len < 2) return true;
    var i: usize = 1;
    while (i < entries.len) : (i += 1) {
        const a = entries[i - 1];
        const b = entries[i];
        if (compareSortNames(a.name, a.mode == filemode.Dir, b.name, b.mode == filemode.Dir) == .gt) {
            return false;
        }
    }
    return true;
}

fn canonicalTreeMode(mode: FileMode) FileMode {
    return switch (mode & 0o170000) {
        0o040000 => filemode.Dir,
        0o100000 => if (mode & 0o111 != 0) filemode.Executable else filemode.Regular,
        0o120000 => filemode.Symlink,
        else => filemode.Submodule,
    };
}

/// Subset of go-git `pathutil.ValidTreePath`.
fn validTreePath(p: []const u8) error{InvalidPath}!void {
    if (p.len == 0) return error.InvalidPath;
    for (p) |c| {
        if (c < 0x20 or c == 0x7f) return error.InvalidPath;
    }
    if (p.len >= 2 and p[1] == ':' and std.ascii.isAlphabetic(p[0])) return error.InvalidPath;

    var start: usize = 0;
    var i: usize = 0;
    var any_part = false;
    while (i <= p.len) : (i += 1) {
        const at_sep = i == p.len or p[i] == '/' or p[i] == '\\';
        if (!at_sep) continue;
        const part = p[start..i];
        start = i + 1;
        if (part.len == 0) continue;
        any_part = true;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidPath;
        if (isDotGitName(part)) return error.InvalidPath;
    }
    if (!any_part) return error.InvalidPath;
}

fn isDotGitName(name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, ".git")) return true;
    if (std.ascii.eqlIgnoreCase(name, "git~1")) return true;
    return false;
}

fn splitPath(allocator: Allocator, path: []const u8) Allocator.Error![][]const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer list.deinit(allocator);
    var start: usize = 0;
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            if (i > start) {
                try list.append(allocator, path[start..i]);
            }
            start = i + 1;
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn joinPathParts(allocator: Allocator, parts: []const []const u8) Allocator.Error![]u8 {
    if (parts.len == 0) return try allocator.dupe(u8, "");
    var len: usize = 0;
    for (parts, 0..) |p, idx| {
        len += p.len;
        if (idx + 1 < parts.len) len += 1;
    }
    var out = try allocator.alloc(u8, len);
    var pos: usize = 0;
    for (parts, 0..) |p, idx| {
        @memcpy(out[pos .. pos + p.len], p);
        pos += p.len;
        if (idx + 1 < parts.len) {
            out[pos] = '/';
            pos += 1;
        }
    }
    return out;
}

fn simpleJoinAlloc(allocator: Allocator, parent: []const u8, child: []const u8) Allocator.Error![]u8 {
    if (parent.len == 0) return try allocator.dupe(u8, child);
    var out = try allocator.alloc(u8, parent.len + 1 + child.len);
    @memcpy(out[0..parent.len], parent);
    out[parent.len] = '/';
    @memcpy(out[parent.len + 1 ..], child);
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "empty tree encode decode round-trip" {
    const gpa = std.testing.allocator;

    var tree = Tree.init(gpa, null);
    defer tree.deinit();

    var obj = MemoryObject.init(gpa);
    defer obj.deinit();

    try tree.encode(&obj);
    try std.testing.expect(obj.object_type == .tree);
    try std.testing.expectEqual(@as(i64, 0), obj.size);

    var decoded = Tree.init(gpa, null);
    defer decoded.deinit();
    try decoded.decode(&obj);
    try std.testing.expectEqual(@as(usize, 0), decoded.entries.items.len);
    try std.testing.expect(decoded.hash.eql(obj.hash()));
    try std.testing.expect(decoded.objectType() == .tree);
}

test "one blob entry encode decode round-trip via MemoryObject" {
    const gpa = std.testing.allocator;
    const blob_hash = plumbing.newHash("b029517f6300c2da0f4b651b8642506cd6aaf45d");

    var tree = Tree.init(gpa, null);
    defer tree.deinit();
    try tree.appendEntry("README", filemode.Regular, blob_hash);
    tree.sortEntries();

    var obj = MemoryObject.init(gpa);
    defer obj.deinit();
    try tree.encode(&obj);

    const body = obj.readerBytes();
    try std.testing.expect(std.mem.startsWith(u8, body, "100644 README"));
    try std.testing.expectEqual(@as(u8, 0), body["100644 README".len]);

    const decoded = try decodeTreeNoStore(gpa, &obj);
    defer freeTree(gpa, decoded);

    try std.testing.expectEqual(@as(usize, 1), decoded.entries.items.len);
    try std.testing.expectEqualStrings("README", decoded.entries.items[0].name);
    try std.testing.expectEqual(filemode.Regular, decoded.entries.items[0].mode);
    try std.testing.expect(decoded.entries.items[0].hash.eql(blob_hash));
    try std.testing.expect(decoded.hash.eql(obj.hash()));
    try std.testing.expect(decoded.entries_sorted);
}

test "encode rejects unsorted entries" {
    const gpa = std.testing.allocator;
    var tree = Tree.init(gpa, null);
    defer tree.deinit();
    const h = plumbing.newHash("b029517f6300c2da0f4b651b8642506cd6aaf45d");
    try tree.appendEntry("foo", filemode.Regular, h);
    try tree.appendEntry("bar", filemode.Regular, h);
    var obj = MemoryObject.init(gpa);
    defer obj.deinit();
    try std.testing.expectError(error.EntriesNotSorted, tree.encode(&obj));
    tree.sortEntries();
    try tree.encode(&obj);
}

test "decode non-tree is UnsupportedObject" {
    const gpa = std.testing.allocator;
    var blob_obj = MemoryObject.init(gpa);
    defer blob_obj.deinit();
    blob_obj.setType(.blob);
    try blob_obj.setContent("hi");

    var tree = Tree.init(gpa, null);
    defer tree.deinit();
    try std.testing.expectError(error.UnsupportedObject, tree.decode(&blob_obj));
}

test "decode detects unsorted entries" {
    const gpa = std.testing.allocator;
    const h1 = plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const h2 = plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "100644 z");
    try body.append(gpa, 0);
    try body.appendSlice(gpa, &h1.bytes);
    try body.appendSlice(gpa, "100644 a");
    try body.append(gpa, 0);
    try body.appendSlice(gpa, &h2.bytes);

    var obj = MemoryObject.init(gpa);
    defer obj.deinit();
    obj.setType(.tree);
    try obj.setContent(body.items);

    const tree = try decodeTreeNoStore(gpa, &obj);
    defer freeTree(gpa, tree);
    try std.testing.expectEqual(@as(usize, 2), tree.entries.items.len);
    try std.testing.expect(!tree.entries_sorted);
}

test "getTree and findEntry via memory.Storage" {
    const gpa = std.testing.allocator;
    var store = Storage.init(gpa);
    defer store.deinit();
    const getter = ObjectGetter.from(Storage, &store);

    const blob_obj = try store.newEncodedObject();
    blob_obj.setType(.blob);
    try blob_obj.setContent("hello");
    const blob_h = try store.setEncodedObject(blob_obj);

    var tree = Tree.init(gpa, getter);
    defer tree.deinit();
    try tree.appendEntry("hello.txt", filemode.Regular, blob_h);
    tree.sortEntries();

    const tree_obj = try store.newEncodedObject();
    try tree.encode(tree_obj);
    const tree_h = try store.setEncodedObject(tree_obj);

    const loaded = try getTree(gpa, &store, tree_h);
    defer freeTree(gpa, loaded);
    try std.testing.expectEqual(@as(usize, 1), loaded.entries.items.len);

    const ent = try loaded.findEntry("hello.txt");
    try std.testing.expectEqualStrings("hello.txt", ent.name);
    try std.testing.expect(ent.hash.eql(blob_h));

    const f = try loaded.file("hello.txt");
    try std.testing.expectEqualStrings("hello", f.blob.readerBytes());
    try std.testing.expectEqualStrings("hello.txt", f.name);

    try std.testing.expectError(error.EntryNotFound, loaded.findEntry("missing"));
    try std.testing.expectError(error.FileNotFound, loaded.file("missing"));
}

test "nested tree findEntry and treeAt" {
    const gpa = std.testing.allocator;
    var store = Storage.init(gpa);
    defer store.deinit();
    const getter = ObjectGetter.from(Storage, &store);

    const blob_obj = try store.newEncodedObject();
    blob_obj.setType(.blob);
    try blob_obj.setContent("nested");
    const blob_h = try store.setEncodedObject(blob_obj);

    var sub = Tree.init(gpa, getter);
    defer sub.deinit();
    try sub.appendEntry("foo.go", filemode.Regular, blob_h);
    sub.sortEntries();
    const sub_obj = try store.newEncodedObject();
    try sub.encode(sub_obj);
    const sub_h = try store.setEncodedObject(sub_obj);

    var root = Tree.init(gpa, getter);
    defer root.deinit();
    try root.appendEntry("vendor", filemode.Dir, sub_h);
    root.sortEntries();
    const root_obj = try store.newEncodedObject();
    try root.encode(root_obj);
    const root_h = try store.setEncodedObject(root_obj);

    const loaded = try getTree(gpa, &store, root_h);
    defer freeTree(gpa, loaded);

    const ent = try loaded.findEntry("vendor/foo.go");
    try std.testing.expectEqualStrings("foo.go", ent.name);
    try std.testing.expect(ent.hash.eql(blob_h));

    const sub_loaded = try loaded.treeAt("vendor");
    defer freeTree(gpa, sub_loaded);
    try std.testing.expect(sub_loaded.hash.eql(sub_h));

    try std.testing.expectError(error.DirectoryNotFound, loaded.treeAt("nope"));
}

test "TreeWalker non-recursive and FileIter" {
    // FileIter nested tree ownership is still being tightened.
    const gpa = std.testing.allocator;
    var store = Storage.init(gpa);
    defer store.deinit();
    const getter = ObjectGetter.from(Storage, &store);

    const b1 = try store.newEncodedObject();
    b1.setType(.blob);
    try b1.setContent("a");
    const h1 = try store.setEncodedObject(b1);

    const b2 = try store.newEncodedObject();
    b2.setType(.blob);
    try b2.setContent("b");
    const h2 = try store.setEncodedObject(b2);

    var sub = Tree.init(gpa, getter);
    defer sub.deinit();
    try sub.appendEntry("inner.txt", filemode.Regular, h2);
    sub.sortEntries();
    const sub_obj = try store.newEncodedObject();
    try sub.encode(sub_obj);
    const sub_h = try store.setEncodedObject(sub_obj);

    var root = Tree.init(gpa, getter);
    defer root.deinit();
    try root.appendEntry("dir", filemode.Dir, sub_h);
    try root.appendEntry("top.txt", filemode.Regular, h1);
    root.sortEntries();
    const root_obj = try store.newEncodedObject();
    try root.encode(root_obj);
    const root_h = try store.setEncodedObject(root_obj);

    const loaded = try getTree(gpa, &store, root_h);
    defer freeTree(gpa, loaded);

    var walker = try TreeWalker.init(loaded, false, null);
    defer walker.close();
    var count: usize = 0;
    while (true) {
        _ = walker.next() catch |err| {
            try std.testing.expect(err == error.EndOfStream);
            break;
        };
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);

    var fiter = try FileIter.init(loaded);
    const Counter = struct {
        var n: usize = 0;
        fn cb(_: *const File) anyerror!void {
            n += 1;
        }
    };
    Counter.n = 0;
    try fiter.forEach(Counter.cb);
    try std.testing.expectEqual(@as(usize, 2), Counter.n);
}

test "malformed tree truncated hash" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "100644 x");
    try body.append(gpa, 0);
    try body.appendSlice(gpa, "short");

    var obj = MemoryObject.init(gpa);
    defer obj.deinit();
    obj.setType(.tree);
    try obj.setContent(body.items);

    var tree = Tree.init(gpa, null);
    defer tree.deinit();
    try std.testing.expectError(error.MalformedTree, tree.decode(&obj));
}

test "validTreePath rejects dots and git" {
    try std.testing.expectError(error.InvalidPath, validTreePath(""));
    try std.testing.expectError(error.InvalidPath, validTreePath("."));
    try std.testing.expectError(error.InvalidPath, validTreePath(".."));
    try std.testing.expectError(error.InvalidPath, validTreePath("a/../b"));
    try std.testing.expectError(error.InvalidPath, validTreePath(".git"));
    try std.testing.expectError(error.InvalidPath, validTreePath("foo/.git/bar"));
    try validTreePath("vendor/foo.go");
    try validTreePath("README");
}

test "dir sorts after file with same prefix" {
    try std.testing.expect(compareSortNames("foo", false, "foo", true) == .lt);
    try std.testing.expect(compareSortNames("a", false, "b", false) == .lt);
}
