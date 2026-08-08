//! Filesystem-backed merkletrie noders (go-git `utils/merkletrie/filesystem`).

const std = @import("std");
const noder = @import("noder");
const plumbing = @import("plumbing");
const filemode = @import("filemode");
const index_fmt = @import("index");
const fs = @import("fs");

const Allocator = std.mem.Allocator;
const Noder = noder.Noder;
const Index = index_fmt.Index;
const Entry = index_fmt.Entry;
const Hash = plumbing.Hash;

const ignore_git = ".git";

/// Options for filesystem root nodes (go-git `Options`).
pub const Options = struct {
    /// When set, enables metadata-first comparison with racy-git handling.
    index: ?*const Index = null,
};

/// Minimal FS operations used by filesystem noders.
pub const FsVTable = struct {
    read_dir: *const fn (ptr: *anyopaque, path: []const u8) anyerror![]fs.FileInfo,
    free_read_dir: *const fn (ptr: *anyopaque, entries: []fs.FileInfo) void,
    open: *const fn (ptr: *anyopaque, path: []const u8) anyerror!FsFile,
    readlink: *const fn (ptr: *anyopaque, path: []const u8) anyerror![]u8,
};

pub const FsFile = struct {
    ptr: *anyopaque,
    read_fn: *const fn (ptr: *anyopaque, buf: []u8) anyerror!usize,
    close_fn: *const fn (ptr: *anyopaque) void,

    pub fn read(self: FsFile, buf: []u8) anyerror!usize {
        return self.read_fn(self.ptr, buf);
    }
    pub fn close(self: FsFile) void {
        self.close_fn(self.ptr);
    }
};

fn OpenedFile(comptime File: type) type {
    return struct {
        file: File,
        allocator: Allocator,

        fn read(ptr: *anyopaque, buf: []u8) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.file.read(buf);
        }
        fn close(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.file.close() catch {};
            self.allocator.destroy(self);
        }
    };
}

fn openOn(comptime Fs: type, fsptr: *Fs, path: []const u8) anyerror!FsFile {
    const file = try fsptr.open(path);
    const Box = OpenedFile(@TypeOf(file));
    const box = try fsptr.allocator.create(Box);
    box.* = .{ .file = file, .allocator = fsptr.allocator };
    return .{
        .ptr = box,
        .read_fn = Box.read,
        .close_fn = Box.close,
    };
}

/// Build FsVTable for a concrete billy-style FS type.
pub fn vtableFor(comptime Fs: type) FsVTable {
    const gen = struct {
        fn readDir(ptr: *anyopaque, path: []const u8) anyerror![]fs.FileInfo {
            const self: *Fs = @ptrCast(@alignCast(ptr));
            return self.readDir(path);
        }
        fn freeReadDir(ptr: *anyopaque, entries: []fs.FileInfo) void {
            const self: *Fs = @ptrCast(@alignCast(ptr));
            self.freeReadDir(entries);
        }
        fn open(ptr: *anyopaque, path: []const u8) anyerror!FsFile {
            const self: *Fs = @ptrCast(@alignCast(ptr));
            return openOn(Fs, self, path);
        }
        fn readlink(ptr: *anyopaque, path: []const u8) anyerror![]u8 {
            const self: *Fs = @ptrCast(@alignCast(ptr));
            return self.readlink(path);
        }
    };
    return .{
        .read_dir = gen.readDir,
        .free_read_dir = gen.freeReadDir,
        .open = gen.open,
        .readlink = gen.readlink,
    };
}

const mem_vtable: FsVTable = vtableFor(fs.Mem);

/// Owned root for a filesystem tree. Always heap-stable via `*Root`.
pub const Root = struct {
    node: *Node,
    submodules: std.StringHashMapUnmanaged(Hash) = .empty,
    idx_map: std.StringHashMapUnmanaged(*const Entry) = .empty,
    idx: ?*const Index = null,
    all: std.ArrayList(*Node) = .empty,
    allocator: Allocator,
    fs_ptr: *anyopaque,
    fs_vt: *const FsVTable,

    pub fn deinit(self: *Root) void {
        var it = self.submodules.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
        }
        self.submodules.deinit(self.allocator);
        self.idx_map.deinit(self.allocator);
        for (self.all.items) |n| {
            n.destroy();
        }
        self.all.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn noder(self: *Root) Noder {
        return self.node.asNoder();
    }

    fn register(self: *Root, n: *Node) Allocator.Error!void {
        try self.all.append(self.allocator, n);
    }
};

/// Composite hash capacity: MaxSize OID + 4-byte mode (go-git 20+4, dual 32+4).
const composite_hash_cap = plumbing.MaxSize + 4;

pub const Node = struct {
    root: *Root,
    path: []u8,
    hash_buf: ?[composite_hash_cap]u8 = null,
    children_list: std.ArrayList(*Node) = .empty,
    children_ready: bool = false,
    is_dir: bool = false,
    mode: u32 = 0,
    size: i64 = 0,
    mtime_sec: i64 = 0,

    fn destroy(self: *Node) void {
        self.root.allocator.free(self.path);
        self.children_list.deinit(self.root.allocator);
        self.root.allocator.destroy(self);
    }

    pub fn asNoder(self: *Node) Noder {
        return noder.noderOf(Node, self);
    }

    pub fn hash(self: *Node) []const u8 {
        if (self.hash_buf == null) self.calculateHash();
        return self.hash_buf.?[0 .. plumbing.digestSize() + 4];
    }

    pub fn name(self: *Node) []const u8 {
        return pathBase(self.path);
    }

    pub fn isDir(self: *Node) bool {
        return self.is_dir;
    }

    pub fn skip(_: *Node) bool {
        return false;
    }

    pub fn children(self: *Node, allocator: Allocator) anyerror![]Noder {
        try self.calculateChildren();
        const out = try allocator.alloc(Noder, self.children_list.items.len);
        for (self.children_list.items, 0..) |c, i| {
            out[i] = c.asNoder();
        }
        return out;
    }

    pub fn numChildren(self: *Node) anyerror!usize {
        try self.calculateChildren();
        return self.children_list.items.len;
    }

    pub fn string(self: *Node, allocator: Allocator) anyerror![]u8 {
        return try allocator.dupe(u8, self.path);
    }

    fn calculateChildren(self: *Node) anyerror!void {
        if (!self.is_dir) return;
        if (self.children_ready) return;

        const entries = self.root.fs_vt.read_dir(self.root.fs_ptr, self.path) catch |err| {
            if (err == error.NotExist) {
                // Empty / missing dir is a successful empty children set.
                self.children_ready = true;
                return;
            }
            return err;
        };
        defer self.root.fs_vt.free_read_dir(self.root.fs_ptr, entries);

        // On failure roll back partial children so a retry is safe.
        const list_start = self.children_list.items.len;
        const all_start = self.root.all.items.len;
        errdefer self.rollbackPartialChildren(list_start, all_start);

        for (entries) |file| {
            if (std.mem.eql(u8, file.name, ignore_git)) continue;
            if (file.mode & 0o170000 == 0o140000) continue;

            const child = try self.newChildNode(file);
            self.children_list.append(self.root.allocator, child) catch |err| {
                child.destroy();
                return err;
            };
            self.root.register(child) catch |err| {
                _ = self.children_list.pop();
                child.destroy();
                return err;
            };
        }
        self.children_ready = true;
    }

    /// Destroy children added after `list_start` / `all_start` (failed partial fill).
    fn rollbackPartialChildren(self: *Node, list_start: usize, all_start: usize) void {
        while (self.children_list.items.len > list_start) {
            const c = self.children_list.pop().?;
            c.destroy();
        }
        // Registered entries for those children sit at the end of `all`.
        self.root.all.shrinkRetainingCapacity(all_start);
    }

    fn newChildNode(self: *Node, file: fs.FileInfo) Allocator.Error!*Node {
        const child_path = try pathJoin(self.root.allocator, self.path, file.name);
        errdefer self.root.allocator.free(child_path);

        var is_dir = file.isDir();
        if (self.root.submodules.contains(child_path)) {
            is_dir = false;
        }

        const n = try self.root.allocator.create(Node);
        n.* = .{
            .root = self.root,
            .path = child_path,
            .is_dir = is_dir,
            .mode = file.mode,
            .size = file.size,
            .mtime_sec = file.mtime_sec,
        };
        // Path ownership moved into node; caller owns `n` until register/append.
        // On create failure, errdefer frees child_path. On success, cancel free by return.
        return n;
    }

    fn calculateHash(self: *Node) void {
        const n = plumbing.digestSize();
        if (self.is_dir) {
            self.hash_buf = .{0} ** composite_hash_cap;
            return;
        }
        const mode = gitModeFromUnix(self.mode) catch {
            self.hash_buf = .{0} ** composite_hash_cap;
            return;
        };
        if (self.root.submodules.get(self.path)) |sub_hash| {
            var buf: [composite_hash_cap]u8 = .{0} ** composite_hash_cap;
            @memcpy(buf[0..n], sub_hash.slice());
            const mb = filemode.bytes(filemode.Submodule);
            @memcpy(buf[n..][0..4], &mb);
            self.hash_buf = buf;
            return;
        }

        if (self.root.idx_map.count() > 0) {
            if (self.root.idx_map.get(self.path)) |entry| {
                if (self.metadataMatches(entry, mode)) {
                    var buf: [composite_hash_cap]u8 = .{0} ** composite_hash_cap;
                    @memcpy(buf[0..n], entry.hash.slice());
                    const mb = filemode.bytes(mode);
                    @memcpy(buf[n..][0..4], &mb);
                    self.hash_buf = buf;
                    return;
                }
            }
        }

        const content_hash = if (self.mode & 0o170000 == 0o120000)
            self.hashSymlink()
        else
            self.hashRegular();

        var buf: [composite_hash_cap]u8 = .{0} ** composite_hash_cap;
        @memcpy(buf[0..n], content_hash.slice());
        const mb = filemode.bytes(mode);
        @memcpy(buf[n..][0..4], &mb);
        self.hash_buf = buf;
    }

    fn metadataMatches(self: *Node, entry: *const Entry, mode: filemode.FileMode) bool {
        if (@as(u32, @intCast(@max(self.size, 0))) != entry.size) return false;
        if (self.mtime_sec != 0 and self.mtime_sec != entry.modified_at.sec) return false;
        if (mode != entry.mode) return false;

        if (self.root.idx) |idx| {
            if (!idx.mod_time.isZero() and self.mtime_sec != 0) {
                // go-git: !modTime.Before(idx.ModTime) → rehash
                if (self.mtime_sec >= idx.mod_time.sec) return false;
            }
        }

        if (self.root.idx == null or self.root.idx.?.mod_time.isZero()) {
            return false;
        }
        return true;
    }

    fn hashRegular(self: *Node) Hash {
        const f = self.root.fs_vt.open(self.root.fs_ptr, self.path) catch return plumbing.ZeroHash;
        defer f.close();

        var hasher = plumbing.Hasher.init(.blob, self.size);
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = f.read(&buf) catch return plumbing.ZeroHash;
            if (n == 0) break;
            hasher.update(buf[0..n]);
        }
        return hasher.sum();
    }

    fn hashSymlink(self: *Node) Hash {
        const target = self.root.fs_vt.readlink(self.root.fs_ptr, self.path) catch return plumbing.ZeroHash;
        defer self.root.allocator.free(target);

        var hasher = plumbing.Hasher.init(.blob, self.size);
        hasher.update(target);
        return hasher.sum();
    }
};

fn gitModeFromUnix(mode: u32) filemode.Error!filemode.FileMode {
    const t = mode & 0o170000;
    if (t == 0o040000) return filemode.Dir;
    if (t == 0o120000) return filemode.Symlink;
    if (t == 0o140000) return filemode.Error.NoEquivalentGitMode;
    if (mode & 0o100 != 0) return filemode.Executable;
    return filemode.Regular;
}

fn pathBase(p: []const u8) []const u8 {
    if (p.len == 0) return ".";
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| {
        if (i + 1 < p.len) return p[i + 1 ..];
        return ".";
    }
    return p;
}

fn pathJoin(allocator: Allocator, dir: []const u8, name: []const u8) Allocator.Error![]u8 {
    if (dir.len == 0) return try allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
}

/// NewRootNode without index optimization (go-git `NewRootNode`).
/// Caller must keep `fsptr` alive for the lifetime of the root.
pub fn newRootNode(
    allocator: Allocator,
    fsptr: *anyopaque,
    fs_vt: *const FsVTable,
    submodules: ?std.StringHashMapUnmanaged(Hash),
) Allocator.Error!*Root {
    return newRootNodeWithOptions(allocator, fsptr, fs_vt, submodules, .{});
}

/// NewRootNode with options (go-git `NewRootNodeWithOptions`).
pub fn newRootNodeWithOptions(
    allocator: Allocator,
    fsptr: *anyopaque,
    fs_vt: *const FsVTable,
    submodules: ?std.StringHashMapUnmanaged(Hash),
    options: Options,
) Allocator.Error!*Root {
    const root_ptr = try allocator.create(Root);
    root_ptr.* = .{
        .node = undefined,
        .allocator = allocator,
        .fs_ptr = fsptr,
        .fs_vt = fs_vt,
        .idx = options.index,
    };
    // `deinit` frees maps, nodes, and `root_ptr` itself.
    errdefer root_ptr.deinit();

    if (submodules) |subs| {
        var it = subs.iterator();
        while (it.next()) |e| {
            const k = try allocator.dupe(u8, e.key_ptr.*);
            errdefer allocator.free(k);
            try root_ptr.submodules.put(allocator, k, e.value_ptr.*);
        }
    }

    if (options.index) |idx| {
        for (idx.entries.items) |*e| {
            try root_ptr.idx_map.put(allocator, e.name, e);
        }
    }

    const node = try allocator.create(Node);
    errdefer allocator.destroy(node);
    node.* = .{
        .root = root_ptr,
        .path = try allocator.dupe(u8, ""),
        .is_dir = true,
    };
    errdefer allocator.free(node.path);
    root_ptr.node = node;
    try root_ptr.all.append(allocator, node);
    return root_ptr;
}

/// Convenience: Mem FS root.
pub fn newRootNodeMem(
    allocator: Allocator,
    mem: *fs.Mem,
    submodules: ?std.StringHashMapUnmanaged(Hash),
) Allocator.Error!*Root {
    return newRootNode(allocator, mem, &mem_vtable, submodules);
}

pub fn newRootNodeMemWithOptions(
    allocator: Allocator,
    mem: *fs.Mem,
    submodules: ?std.StringHashMapUnmanaged(Hash),
    options: Options,
) Allocator.Error!*Root {
    return newRootNodeWithOptions(allocator, mem, &mem_vtable, submodules, options);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const merkletrie = @import("merkletrie");

fn isEmptyComposite(h: []const u8) bool {
    const want = plumbing.digestSize() + 4;
    return h.len == want and std.mem.allEqual(u8, h, 0);
}

fn isEquals(a: Noder, b: Noder) bool {
    const ah = a.hash();
    const bh = b.hash();
    if (isEmptyComposite(ah)) return false;
    if (isEmptyComposite(bh)) return false;
    return std.mem.eql(u8, ah, bh);
}

fn writeFile(mem: *fs.Mem, path: []const u8, data: []const u8, perm: u32) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        try mem.mkdirAll(path[0..i], 0o755);
    }
    var f = try mem.openFile(path, fs.O.RDWR | fs.O.CREATE | fs.O.TRUNC, perm);
    defer f.close() catch {};
    _ = try f.write(data);
}

test "filesystem Diff identical" {
    const a = std.testing.allocator;
    var fs_a = try fs.Mem.init(a);
    defer fs_a.deinit();
    var fs_b = try fs.Mem.init(a);
    defer fs_b.deinit();
    try writeFile(&fs_a, "foo", "foo", 0o644);
    try writeFile(&fs_a, "qux/bar", "foo", 0o644);
    try writeFile(&fs_a, "qux/qux", "foo", 0o644);
    try fs_a.symlink("foo", "bar");
    try writeFile(&fs_b, "foo", "foo", 0o644);
    try writeFile(&fs_b, "qux/bar", "foo", 0o644);
    try writeFile(&fs_b, "qux/qux", "foo", 0o644);
    try fs_b.symlink("foo", "bar");

    const ra = try newRootNodeMem(a, &fs_a, null);
    defer ra.deinit();
    const rb = try newRootNodeMem(a, &fs_b, null);
    defer rb.deinit();

    var ch = try merkletrie.diffTree(a, ra.noder(), rb.noder(), isEquals);
    defer ch.deinit();
    try std.testing.expectEqual(@as(usize, 0), ch.items.items.len);
}

// go-git NoderSuite.TestDiffChangeContent
test "filesystem Diff content change" {
    const a = std.testing.allocator;
    var fs_a = try fs.Mem.init(a);
    defer fs_a.deinit();
    var fs_b = try fs.Mem.init(a);
    defer fs_b.deinit();
    try writeFile(&fs_a, "foo", "foo", 0o644);
    try writeFile(&fs_a, "qux/bar", "foo", 0o644);
    try writeFile(&fs_a, "qux/qux", "foo", 0o644);
    try writeFile(&fs_b, "foo", "foo", 0o644);
    try writeFile(&fs_b, "qux/bar", "bar", 0o644);
    try writeFile(&fs_b, "qux/qux", "foo", 0o644);

    const ra = try newRootNodeMem(a, &fs_a, null);
    defer ra.deinit();
    const rb = try newRootNodeMem(a, &fs_b, null);
    defer rb.deinit();

    var ch = try merkletrie.diffTree(a, ra.noder(), rb.noder(), isEquals);
    defer ch.deinit();
    try std.testing.expectEqual(@as(usize, 1), ch.items.items.len);
    try std.testing.expectEqual(merkletrie.Action.modify, try ch.items.items[0].action());
}

// go-git NoderSuite.TestDiffChangeLink
test "filesystem Diff symlink change" {
    const a = std.testing.allocator;
    var fs_a = try fs.Mem.init(a);
    defer fs_a.deinit();
    var fs_b = try fs.Mem.init(a);
    defer fs_b.deinit();
    try fs_a.symlink("qux", "foo");
    try fs_b.symlink("bar", "foo");

    const ra = try newRootNodeMem(a, &fs_a, null);
    defer ra.deinit();
    const rb = try newRootNodeMem(a, &fs_b, null);
    defer rb.deinit();

    var ch = try merkletrie.diffTree(a, ra.noder(), rb.noder(), isEquals);
    defer ch.deinit();
    try std.testing.expectEqual(@as(usize, 1), ch.items.items.len);
    try std.testing.expectEqual(merkletrie.Action.modify, try ch.items.items[0].action());
}

// go-git NoderSuite.TestDiffSymlinkDirOnA:
// A has only a real directory tree; B also has a symlink that points at that dir.
test "filesystem Diff symlink dir on A" {
    const a = std.testing.allocator;
    var fs_a = try fs.Mem.init(a);
    defer fs_a.deinit();
    var fs_b = try fs.Mem.init(a);
    defer fs_b.deinit();
    try writeFile(&fs_a, "qux/qux", "foo", 0o644);
    try fs_b.symlink("qux", "foo");
    try writeFile(&fs_b, "qux/qux", "foo", 0o644);

    const ra = try newRootNodeMem(a, &fs_a, null);
    defer ra.deinit();
    const rb = try newRootNodeMem(a, &fs_b, null);
    defer rb.deinit();

    var ch = try merkletrie.diffTree(a, ra.noder(), rb.noder(), isEquals);
    defer ch.deinit();
    try std.testing.expectEqual(@as(usize, 1), ch.items.items.len);
    // Symlink "foo" only on B → Insert.
    try std.testing.expectEqual(merkletrie.Action.insert, try ch.items.items[0].action());
}

// go-git NoderSuite.TestDiffSymlinkDirOnB:
// B has only a real directory tree; A also has a symlink that points at that dir.
test "filesystem Diff symlink dir on B" {
    const a = std.testing.allocator;
    var fs_a = try fs.Mem.init(a);
    defer fs_a.deinit();
    var fs_b = try fs.Mem.init(a);
    defer fs_b.deinit();
    try fs_a.symlink("qux", "foo");
    try writeFile(&fs_a, "qux/qux", "foo", 0o644);
    try writeFile(&fs_b, "qux/qux", "foo", 0o644);

    const ra = try newRootNodeMem(a, &fs_a, null);
    defer ra.deinit();
    const rb = try newRootNodeMem(a, &fs_b, null);
    defer rb.deinit();

    var ch = try merkletrie.diffTree(a, ra.noder(), rb.noder(), isEquals);
    defer ch.deinit();
    try std.testing.expectEqual(@as(usize, 1), ch.items.items.len);
    // Symlink "foo" only on A → Delete.
    try std.testing.expectEqual(merkletrie.Action.delete, try ch.items.items[0].action());
}

test "filesystem Diff missing" {
    const a = std.testing.allocator;
    var fs_a = try fs.Mem.init(a);
    defer fs_a.deinit();
    var fs_b = try fs.Mem.init(a);
    defer fs_b.deinit();
    try writeFile(&fs_a, "foo", "foo", 0o644);
    try writeFile(&fs_b, "bar", "bar", 0o644);

    const ra = try newRootNodeMem(a, &fs_a, null);
    defer ra.deinit();
    const rb = try newRootNodeMem(a, &fs_b, null);
    defer rb.deinit();

    var ch = try merkletrie.diffTree(a, ra.noder(), rb.noder(), isEquals);
    defer ch.deinit();
    try std.testing.expectEqual(@as(usize, 2), ch.items.items.len);
}

// go-git NoderSuite.TestDiffChangeMode (0644 vs 0755 → executable bit)
test "filesystem Diff mode change" {
    const a = std.testing.allocator;
    var fs_a = try fs.Mem.init(a);
    defer fs_a.deinit();
    var fs_b = try fs.Mem.init(a);
    defer fs_b.deinit();
    try writeFile(&fs_a, "foo", "foo", 0o644);
    try writeFile(&fs_b, "foo", "foo", 0o755);

    const ra = try newRootNodeMem(a, &fs_a, null);
    defer ra.deinit();
    const rb = try newRootNodeMem(a, &fs_b, null);
    defer rb.deinit();

    var ch = try merkletrie.diffTree(a, ra.noder(), rb.noder(), isEquals);
    defer ch.deinit();
    try std.testing.expectEqual(@as(usize, 1), ch.items.items.len);
    try std.testing.expectEqual(merkletrie.Action.modify, try ch.items.items[0].action());
}

// go-git NoderSuite.TestDiffChangeModeNotRelevant (0644 vs 0655 → same git mode)
test "filesystem Diff mode not relevant" {
    const a = std.testing.allocator;
    var fs_a = try fs.Mem.init(a);
    defer fs_a.deinit();
    var fs_b = try fs.Mem.init(a);
    defer fs_b.deinit();
    try writeFile(&fs_a, "foo", "foo", 0o644);
    try writeFile(&fs_b, "foo", "foo", 0o655);

    const ra = try newRootNodeMem(a, &fs_a, null);
    defer ra.deinit();
    const rb = try newRootNodeMem(a, &fs_b, null);
    defer rb.deinit();

    var ch = try merkletrie.diffTree(a, ra.noder(), rb.noder(), isEquals);
    defer ch.deinit();
    try std.testing.expectEqual(@as(usize, 0), ch.items.items.len);
}

// go-git NoderSuite.TestSocket: Unix sockets are skipped in Children.
// Mem FS cannot create sockets (S_IFSOCK). Mock FsVTable reports socket mode
// matching go-git's filter (file.Mode()&os.ModeSocket) / Zig 0o140000 skip,
// and gitModeFromUnix rejecting sockets with NoEquivalentGitMode.
test "filesystem Children ignores socket" {
    const a = std.testing.allocator;

    const SocketFs = struct {
        allocator: Allocator,

        fn readDir(ptr: *anyopaque, path: []const u8) anyerror![]fs.FileInfo {
            _ = path;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const entries = try self.allocator.alloc(fs.FileInfo, 2);
            errdefer self.allocator.free(entries);
            entries[0] = .{
                .name = try self.allocator.dupe(u8, "foo"),
                .size = 3,
                .mode = 0o100644,
            };
            errdefer self.allocator.free(entries[0].name);
            // S_IFSOCK (0o140000) | 0o644 — calculateChildren skips this type.
            entries[1] = .{
                .name = try self.allocator.dupe(u8, "socket"),
                .size = 0,
                .mode = 0o140644,
            };
            return entries;
        }

        fn freeReadDir(ptr: *anyopaque, entries: []fs.FileInfo) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            for (entries) |e| {
                if (e.name.len > 0) self.allocator.free(e.name);
            }
            self.allocator.free(entries);
        }

        // Children listing does not open files; stubs for FsVTable completeness.
        fn open(_: *anyopaque, _: []const u8) anyerror!FsFile {
            return error.NotExist;
        }
        fn readlink(_: *anyopaque, _: []const u8) anyerror![]u8 {
            return error.NotLink;
        }
    };

    var mock: SocketFs = .{ .allocator = a };
    const vt: FsVTable = .{
        .read_dir = SocketFs.readDir,
        .free_read_dir = SocketFs.freeReadDir,
        .open = SocketFs.open,
        .readlink = SocketFs.readlink,
    };

    const root = try newRootNode(a, &mock, &vt, null);
    defer root.deinit();

    const kids = try root.noder().children(a);
    defer a.free(kids);
    // Only the regular file; the socket entry is ignored.
    try std.testing.expectEqual(@as(usize, 1), kids.len);
    try std.testing.expectEqualStrings("foo", kids[0].name());
}

// Sanity: gitModeFromUnix rejects S_IFSOCK the same way go-git
// filemode.NewFromOSFileMode fails for sockets (NoEquivalentGitMode).
test "filesystem gitModeFromUnix rejects socket" {
    try std.testing.expectError(filemode.Error.NoEquivalentGitMode, gitModeFromUnix(0o140644));
    try std.testing.expectError(filemode.Error.NoEquivalentGitMode, gitModeFromUnix(0o140000));
}

test "filesystem Diff submodule dir" {
    const a = std.testing.allocator;
    var fs_a = try fs.Mem.init(a);
    defer fs_a.deinit();
    var fs_b = try fs.Mem.init(a);
    defer fs_b.deinit();
    try fs_a.mkdirAll("qux/bar", 0o755);
    try fs_b.mkdirAll("qux/bar", 0o755);

    var subs_a: std.StringHashMapUnmanaged(Hash) = .empty;
    defer subs_a.deinit(a);
    var subs_b: std.StringHashMapUnmanaged(Hash) = .empty;
    defer subs_b.deinit(a);
    try subs_a.put(a, "qux/bar", plumbing.newHash("aa102815663d23f8b75a47e7a01965dcdc96468c"));
    try subs_b.put(a, "qux/bar", plumbing.newHash("19102815663d23f8b75a47e7a01965dcdc96468c"));

    const ra = try newRootNodeMem(a, &fs_a, subs_a);
    defer ra.deinit();
    const rb = try newRootNodeMem(a, &fs_b, subs_b);
    defer rb.deinit();

    var ch = try merkletrie.diffTree(a, ra.noder(), rb.noder(), isEquals);
    defer ch.deinit();
    try std.testing.expectEqual(@as(usize, 1), ch.items.items.len);
    try std.testing.expectEqual(merkletrie.Action.modify, try ch.items.items[0].action());
}

test "filesystem zero index modtime forces rehash" {
    const a = std.testing.allocator;
    var mem = try fs.Mem.init(a);
    defer mem.deinit();
    try writeFile(&mem, "testfile", "foo", 0o644);

    var idx = Index.init(a);
    defer idx.deinit();
    const e = try idx.add("testfile");
    e.hash = plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    e.size = 3;
    e.mode = filemode.Regular;
    e.modified_at = .{};
    idx.mod_time = .{};

    const root = try newRootNodeMemWithOptions(a, &mem, null, .{ .index = &idx });
    defer root.deinit();

    const kids = try root.noder().children(a);
    defer a.free(kids);
    try std.testing.expectEqual(@as(usize, 1), kids.len);

    var hasher = plumbing.Hasher.init(.blob, 3);
    hasher.update("foo");
    const real = hasher.sum();
    const n = plumbing.digestSize();
    var expected: [composite_hash_cap]u8 = undefined;
    @memcpy(expected[0..n], real.slice());
    const mb = filemode.bytes(filemode.Regular);
    @memcpy(expected[n..][0..4], &mb);

    try std.testing.expectEqualSlices(u8, expected[0 .. n + 4], kids[0].hash());
}

// go-git NoderSuite.TestRacyGit (node_test.go).
// Content change with preserved size+mtime while mtime is in the racy window
// (mtime >= index.ModTime) must rehash file content, not trust the index hash.
// Mem FS has no host mtime, so after Children() we set Node.mtime_sec to the
// same controlled timestamp used in the index (same comparison as go-git).
test "filesystem racy git rehashes when mtime in racy window" {
    const a = std.testing.allocator;
    var mem = try fs.Mem.init(a);
    defer mem.deinit();

    const orig_content = "foo";
    const new_content = "bar";
    try std.testing.expectEqual(orig_content.len, new_content.len);

    try writeFile(&mem, "racyfile", orig_content, 0o644);

    var foo_hasher = plumbing.Hasher.init(.blob, @intCast(orig_content.len));
    foo_hasher.update(orig_content);
    const foo_hash = foo_hasher.sum();

    // Controlled timestamps (Unix seconds). go-git uses fi.ModTime for both
    // entry.ModifiedAt and idx.ModTime so the file sits in the racy window.
    const mod_sec: i64 = 1_700_000_000;

    var idx = Index.init(a);
    defer idx.deinit();
    const e = try idx.add("racyfile");
    e.hash = foo_hash;
    e.size = @intCast(orig_content.len);
    e.mode = filemode.Regular;
    e.modified_at = index_fmt.Time.unix(mod_sec, 0);
    idx.mod_time = index_fmt.Time.unix(mod_sec, 0);

    // Same size, different content; mtime will be forced to match entry.
    try writeFile(&mem, "racyfile", new_content, 0o644);

    var bar_hasher = plumbing.Hasher.init(.blob, @intCast(new_content.len));
    bar_hasher.update(new_content);
    const bar_hash = bar_hasher.sum();
    try std.testing.expect(!std.mem.eql(u8, foo_hash.slice(), bar_hash.slice()));

    const root = try newRootNodeMemWithOptions(a, &mem, null, .{ .index = &idx });
    defer root.deinit();

    // Materialize children (size/mode from Mem; mtime defaults to 0 on Mem).
    const kids = try root.noder().children(a);
    defer a.free(kids);
    try std.testing.expectEqual(@as(usize, 1), kids.len);

    // Patch mtime before Hash() so metadataMatches runs the racy-git check
    // (mtime matches entry and is not before idx.ModTime → must rehash).
    try std.testing.expectEqual(@as(usize, 1), root.node.children_list.items.len);
    const file_node = root.node.children_list.items[0];
    file_node.mtime_sec = mod_sec;
    file_node.hash_buf = null;

    const file_hash = file_node.hash();
    const n = plumbing.digestSize();
    var expected: [composite_hash_cap]u8 = undefined;
    @memcpy(expected[0..n], bar_hash.slice());
    const mb = filemode.bytes(filemode.Regular);
    @memcpy(expected[n..][0..4], &mb);

    try std.testing.expectEqualSlices(u8, expected[0 .. n + 4], file_hash);
}

// Complementary case: when mtime is older than index ModTime and metadata
// matches, the index hash is trusted (optimization path; not racy).
test "filesystem index hash trusted when mtime before index modtime" {
    const a = std.testing.allocator;
    var mem = try fs.Mem.init(a);
    defer mem.deinit();
    try writeFile(&mem, "stable", "foo", 0o644);

    var foo_hasher = plumbing.Hasher.init(.blob, 3);
    foo_hasher.update("foo");
    const foo_hash = foo_hasher.sum();

    const file_mtime: i64 = 1_000;
    const idx_mtime: i64 = 2_000;

    var idx = Index.init(a);
    defer idx.deinit();
    const e = try idx.add("stable");
    e.hash = foo_hash;
    e.size = 3;
    e.mode = filemode.Regular;
    e.modified_at = index_fmt.Time.unix(file_mtime, 0);
    idx.mod_time = index_fmt.Time.unix(idx_mtime, 0);

    const root = try newRootNodeMemWithOptions(a, &mem, null, .{ .index = &idx });
    defer root.deinit();

    const kids = try root.noder().children(a);
    defer a.free(kids);
    try std.testing.expectEqual(@as(usize, 1), kids.len);
    const file_node = root.node.children_list.items[0];
    file_node.mtime_sec = file_mtime;
    file_node.hash_buf = null;

    const n = plumbing.digestSize();
    var expected: [composite_hash_cap]u8 = undefined;
    @memcpy(expected[0..n], foo_hash.slice());
    const mb = filemode.bytes(filemode.Regular);
    @memcpy(expected[n..][0..4], &mb);
    try std.testing.expectEqualSlices(u8, expected[0 .. n + 4], file_node.hash());
}
