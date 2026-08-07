//! In-memory filesystem (go-billy `memfs`).
//!
//! Paths use `/`. The process-wide root of a new `Mem` is `/`.

const std = @import("std");
const error_mod = @import("error.zig");
const fileinfo_mod = @import("fileinfo.zig");
const path_mod = @import("path.zig");
const root_mod = @import("root.zig");

const Allocator = std.mem.Allocator;
const Error = error_mod.Error;
const FileInfo = fileinfo_mod.FileInfo;
const O = root_mod.O;

const NodeKind = enum { file, dir, symlink };

const Node = struct {
    kind: NodeKind,
    mode: u32,
    data: std.ArrayList(u8) = .empty,
    /// basename → absolute child path (both strings owned by this node map / store).
    children: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    fn deinit(self: *Node, allocator: Allocator) void {
        self.data.deinit(allocator);
        var it = self.children.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        self.children.deinit(allocator);
    }
};

/// In-memory billy.Filesystem.
///
/// Chroot views share the root store's node map via `shared_nodes` so map growth
/// after chroot never leaves a stale HashMap header (use-after-free).
///
/// # Pinning
/// The root `Mem` that owns the node map must not be moved in memory while
/// chroot views live (they hold `*HashMap` into the root). Keep the root in a
/// stable binding (`var mem = …` or heap) for the lifetime of those views.
pub const Mem = struct {
    pub const File = MemFile;

    allocator: Allocator,
    /// Root map storage. Only the root instance uses this field for lookups
    /// (`shared_nodes == null`).
    nodes_storage: std.StringHashMapUnmanaged(*Node) = .empty,
    /// Non-null on chroot views: points at the root's `nodes_storage`.
    shared_nodes: ?*std.StringHashMapUnmanaged(*Node) = null,
    root_path: []u8,
    temp_seq: u32 = 0,
    /// True when this instance owns `nodes_storage` and all `Node` memory.
    owns_store: bool = true,
    /// Names of still-open files; index stored on `MemFile` for O(1) release.
    open_names: std.ArrayListUnmanaged([]u8) = .empty,
    /// Free indices into `open_names` (empty slots ready for reuse).
    open_name_free: std.ArrayListUnmanaged(usize) = .empty,

    pub fn init(allocator: Allocator) Allocator.Error!Mem {
        var m: Mem = .{
            .allocator = allocator,
            .root_path = try allocator.dupe(u8, "/"),
            .owns_store = true,
            .shared_nodes = null,
        };
        errdefer allocator.free(m.root_path);
        try m.putDir("/");
        return m;
    }

    pub fn deinit(self: *Mem) void {
        for (self.open_names.items) |n| {
            if (n.len > 0) self.allocator.free(n);
        }
        self.open_names.deinit(self.allocator);
        self.open_name_free.deinit(self.allocator);
        if (self.owns_store) {
            var it = self.nodes().iterator();
            while (it.next()) |e| {
                e.value_ptr.*.deinit(self.allocator);
                self.allocator.destroy(e.value_ptr.*);
                self.allocator.free(e.key_ptr.*);
            }
            self.nodes().deinit(self.allocator);
        }
        self.allocator.free(self.root_path);
        self.* = undefined;
    }

    /// Register an owned open-file name; reuses a free slot when available.
    fn registerOpenName(self: *Mem, name_owned: []u8) Allocator.Error!usize {
        if (self.open_name_free.pop()) |idx| {
            self.open_names.items[idx] = name_owned;
            return idx;
        }
        const idx = self.open_names.items.len;
        try self.open_names.append(self.allocator, name_owned);
        return idx;
    }

    /// Free the name at `idx` and recycle the slot.
    fn releaseOpenName(self: *Mem, idx: usize, name: []u8) void {
        if (idx < self.open_names.items.len) {
            const slot = &self.open_names.items[idx];
            if (slot.len > 0 and slot.ptr == name.ptr) {
                self.allocator.free(slot.*);
                slot.* = &.{};
                self.open_name_free.append(self.allocator, idx) catch {
                    // Slot stays empty; next open appends instead of reuse.
                };
                return;
            }
        }
        if (name.len > 0) self.allocator.free(name);
    }

    fn nodes(self: *Mem) *std.StringHashMapUnmanaged(*Node) {
        return self.shared_nodes orelse &self.nodes_storage;
    }
    fn nodesConst(self: *const Mem) *const std.StringHashMapUnmanaged(*Node) {
        return self.shared_nodes orelse &self.nodes_storage;
    }

    pub fn root(self: *const Mem) []const u8 {
        return self.root_path;
    }

    /// Join path elements (always `/` separator; cleans `.` / `..`).
    pub fn joinPath(self: *const Mem, parts: []const []const u8) Allocator.Error![]u8 {
        return try path_mod.join(self.allocator, parts);
    }

    fn toAbs(self: *const Mem, path: []const u8) (Allocator.Error || Error)![]u8 {
        // Billy chroot: reject paths that clean to `..` / `../…` before join.
        if (path_mod.crossesBoundary(path)) return error.CrossedBoundary;

        if (path.len > 0 and path[0] == '/') {
            if (self.root_path.len == 1) return try path_mod.clean(self.allocator, path);
            // Store-absolute path already under this chroot (e.g. MemFile.fileName()):
            // do not re-prefix root_path or rename/open double-joins and 404s.
            if (std.mem.startsWith(u8, path, self.root_path) and
                (path.len == self.root_path.len or path[self.root_path.len] == '/'))
            {
                // Remainder after root must not re-escape via `..`.
                const rest = path[self.root_path.len..];
                if (path_mod.crossesBoundary(rest)) return error.CrossedBoundary;
                return try self.allocator.dupe(u8, path);
            }
            // Billy chroot-absolute: "/foo" means root_path + "/foo".
            return try self.joinPath(&.{ self.root_path, path[1..] });
        }
        if (self.root_path.len == 1) {
            return try self.joinPath(&.{ "/", path });
        }
        return try self.joinPath(&.{ self.root_path, path });
    }

    fn putDir(self: *Mem, abs: []const u8) Allocator.Error!void {
        if (self.nodes().contains(abs)) return;
        if (abs.len > 1) {
            const parent = parentOf(abs);
            try self.putDir(parent);
        }
        const node = try self.allocator.create(Node);
        node.* = .{ .kind = .dir, .mode = 0o040755 };
        const key = self.allocator.dupe(u8, abs) catch |err| {
            self.allocator.destroy(node);
            return err;
        };
        self.nodes().put(self.allocator, key, node) catch |err| {
            self.allocator.free(key);
            self.allocator.destroy(node);
            return err;
        };
        // Map owns `key` + `node`. Roll back on linkChild failure.
        self.linkChild(abs) catch |err| {
            if (self.nodes().fetchRemove(abs)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.destroy(kv.value);
            }
            return err;
        };
    }

    fn linkChild(self: *Mem, abs: []const u8) Allocator.Error!void {
        if (abs.len <= 1) return;
        const parent = parentOf(abs);
        const base = baseOf(abs);
        const pnode = self.nodes().get(parent) orelse return;
        if (pnode.children.contains(base)) return;
        const b = try self.allocator.dupe(u8, base);
        errdefer self.allocator.free(b);
        const c = try self.allocator.dupe(u8, abs);
        errdefer self.allocator.free(c);
        try pnode.children.put(self.allocator, b, c);
    }

    fn parentOf(abs: []const u8) []const u8 {
        if (abs.len <= 1) return "/";
        var i = abs.len - 1;
        while (i > 0 and abs[i] != '/') : (i -= 1) {}
        if (i == 0) return "/";
        return abs[0..i];
    }

    fn baseOf(abs: []const u8) []const u8 {
        if (abs.len <= 1) return abs;
        var i = abs.len - 1;
        while (i > 0 and abs[i] != '/') : (i -= 1) {}
        return abs[i + 1 ..];
    }

    pub fn mkdirAll(self: *Mem, path: []const u8, _: u32) (Allocator.Error || Error)!void {
        const abs = try self.toAbs(path);
        defer self.allocator.free(abs);
        try self.putDir(abs);
    }

    pub fn create(self: *Mem, filename: []const u8) (Allocator.Error || Error)!MemFile {
        return self.openFile(filename, O.RDWR | O.CREATE | O.TRUNC, 0o666);
    }

    pub fn open(self: *Mem, filename: []const u8) (Allocator.Error || Error)!MemFile {
        return self.openFile(filename, O.RDONLY, 0);
    }

    pub fn openFile(
        self: *Mem,
        filename: []const u8,
        flag: u32,
        perm: u32,
    ) (Allocator.Error || Error)!MemFile {
        // `abs` is always freed via `defer`. Do not free it on individual error
        // paths (errdefer + free + return error is a double-free).
        const abs = try self.toAbs(filename);
        defer self.allocator.free(abs);

        var nptr = self.nodes().get(abs);
        if (nptr == null) {
            if (flag & O.CREATE == 0) return error.NotExist;
            try self.putDir(parentOf(abs));
            const node = try self.allocator.create(Node);
            node.* = .{ .kind = .file, .mode = 0o100000 | (perm & 0o777) };
            const key = try self.allocator.dupe(u8, abs);
            // Explicit catch (not errdefer): once put succeeds the map owns key+node;
            // later failures must not free them, and linkChild rollback frees once.
            self.nodes().put(self.allocator, key, node) catch |err| {
                self.allocator.free(key);
                self.allocator.destroy(node);
                return err;
            };
            self.linkChild(abs) catch |err| {
                if (self.nodes().fetchRemove(abs)) |kv| {
                    self.allocator.free(kv.key);
                    self.allocator.destroy(kv.value);
                }
                return err;
            };
            nptr = node;
        } else if (flag & O.EXCL != 0) {
            return error.Exist;
        }

        const node = nptr.?;
        if (node.kind == .dir) return error.IsDir;
        if (flag & O.TRUNC != 0) node.data.clearRetainingCapacity();

        var pos: i64 = 0;
        if (flag & O.APPEND != 0) pos = @intCast(node.data.items.len);

        // Name is freed by MemFile.close via open_name_index.
        const name_owned = try self.allocator.dupe(u8, abs);
        errdefer self.allocator.free(name_owned);
        const name_index = try self.registerOpenName(name_owned);

        return .{
            .mem = self,
            .name = name_owned,
            .open_name_index = name_index,
            .node = node,
            .flag = flag,
            .pos = pos,
        };
    }

    pub fn stat(self: *Mem, filename: []const u8) (Allocator.Error || Error)!FileInfo {
        const abs = try self.toAbs(filename);
        defer self.allocator.free(abs);
        const node = self.nodes().get(abs) orelse return error.NotExist;
        // Base name is not owned; callers that need a stable name should dupe.
        // Empty name avoids dangling into freed `abs`.
        return .{
            .name = "",
            .size = switch (node.kind) {
                .file, .symlink => @intCast(node.data.items.len),
                .dir => 0,
            },
            .mode = node.mode,
        };
    }

    pub fn lstat(self: *Mem, filename: []const u8) (Allocator.Error || Error)!FileInfo {
        return self.stat(filename);
    }

    /// Caller frees with `freeReadDir`.
    pub fn readDir(self: *Mem, path: []const u8) (Allocator.Error || Error)![]FileInfo {
        const abs = try self.toAbs(path);
        defer self.allocator.free(abs);
        const node = self.nodes().get(abs) orelse return error.NotExist;
        if (node.kind != .dir) return error.NotDir;

        var list: std.ArrayList(FileInfo) = .empty;
        errdefer list.deinit(self.allocator);
        var it = node.children.iterator();
        while (it.next()) |e| {
            const child = self.nodes().get(e.value_ptr.*) orelse continue;
            const name_owned = try self.allocator.dupe(u8, e.key_ptr.*);
            try list.append(self.allocator, .{
                .name = name_owned,
                .size = if (child.kind == .file) @intCast(child.data.items.len) else 0,
                .mode = child.mode,
            });
        }
        std.mem.sort(FileInfo, list.items, {}, struct {
            fn less(_: void, a: FileInfo, b: FileInfo) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);
        return try list.toOwnedSlice(self.allocator);
    }

    pub fn freeReadDir(self: *Mem, entries: []FileInfo) void {
        for (entries) |e| {
            if (e.name.len > 0) self.allocator.free(@constCast(e.name));
        }
        // `readDir` returns `toOwnedSlice` or never `&.{}`; empty dirs still
        // hand back a zero-length owned slice that must be freed when capacity
        // was non-zero. Freeing a zero-length non-null slice is a no-op on GPA;
        // free only when len > 0 matches freeHashes / freeAlternates convention
        // (static `&.{}` has undefined ptr — never free it).
        if (entries.len > 0) self.allocator.free(entries);
    }

    pub fn remove(self: *Mem, filename: []const u8) (Allocator.Error || Error)!void {
        const abs = try self.toAbs(filename);
        defer self.allocator.free(abs);
        try self.removeAbs(abs);
    }

    /// Atomic rename within the store (rekey the node; no copy of file bytes).
    ///
    /// Files, symlinks, and directories (with all descendants) move in place.
    /// Destination file/symlink is replaced; directory destination → `IsDir`.
    /// Directory `children` maps store absolute paths and are rebuilt after rekey.
    pub fn rename(self: *Mem, oldpath: []const u8, newpath: []const u8) (Allocator.Error || Error)!void {
        const old_abs = try self.toAbs(oldpath);
        defer self.allocator.free(old_abs);
        const new_abs = try self.toAbs(newpath);
        defer self.allocator.free(new_abs);
        if (std.mem.eql(u8, old_abs, new_abs)) return;

        _ = self.nodes().get(old_abs) orelse return error.NotExist;

        if (self.nodes().get(new_abs)) |dest| {
            if (dest.kind == .dir) return error.IsDir;
            try self.removeAbs(new_abs);
        }

        try self.putDir(parentOf(new_abs));
        try self.rekeyTree(old_abs, new_abs);
    }

    fn removeAbs(self: *Mem, abs: []const u8) (Allocator.Error || Error)!void {
        if (std.mem.eql(u8, abs, "/")) return error.InvalidMode;
        const node = self.nodes().get(abs) orelse return error.NotExist;
        if (node.kind == .dir and node.children.count() > 0) return error.InvalidMode;

        self.unlinkFromParent(abs);
        if (self.nodes().fetchRemove(abs)) |kv| {
            kv.value.deinit(self.allocator);
            self.allocator.destroy(kv.value);
            self.allocator.free(kv.key);
        }
    }

    fn unlinkFromParent(self: *Mem, abs: []const u8) void {
        if (abs.len <= 1) return;
        const parent = parentOf(abs);
        const base = baseOf(abs);
        if (self.nodes().get(parent)) |pnode| {
            if (pnode.children.fetchSwapRemove(base)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }
        }
    }

    fn clearChildrenMap(self: *Mem, node: *Node) void {
        var it = node.children.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        node.children.clearRetainingCapacity();
    }

    /// Rekey `old_abs` and every descendant under `old_abs/` to `new_abs…`.
    ///
    /// Nodes keep `*Node` identity (no content copy). All-or-nothing after detach:
    /// any failure restores every node under its original key. Directory children
    /// maps store absolute paths and are cleared then rebuilt via `linkChild`.
    fn rekeyTree(self: *Mem, old_abs: []const u8, new_abs: []const u8) Allocator.Error!void {
        const Move = struct {
            old_key: []u8,
            new_key: []u8,
            node: *Node,
            /// Map-owned key while inserted; null while detached into the plan.
            inserted_key: ?[]u8 = null,
        };

        var plan: std.ArrayList(Move) = .empty;
        var detached = false;
        defer {
            for (plan.items) |m| {
                self.allocator.free(m.old_key);
                self.allocator.free(m.new_key);
                // inserted_key is owned by the map when non-null — do not free here.
            }
            plan.deinit(self.allocator);
        }

        {
            var it = self.nodes().iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                if (!(std.mem.eql(u8, k, old_abs) or
                    (k.len > old_abs.len and std.mem.startsWith(u8, k, old_abs) and k[old_abs.len] == '/')))
                    continue;
                const old_owned = try self.allocator.dupe(u8, k);
                errdefer self.allocator.free(old_owned);
                const nk = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ new_abs, k[old_abs.len..] });
                errdefer self.allocator.free(nk);
                try plan.append(self.allocator, .{
                    .old_key = old_owned,
                    .new_key = nk,
                    .node = e.value_ptr.*,
                });
            }
        }

        if (plan.items.len == 0) return;

        // On failure after detach: drop any new inserts, restore every node at
        // old_key, then rebuild parent/children links (children maps were cleared).
        errdefer {
            if (detached) {
                for (plan.items) |*m| {
                    if (m.inserted_key) |ik| {
                        if (self.nodes().fetchRemove(ik)) |kv| {
                            self.allocator.free(kv.key);
                        }
                        m.inserted_key = null;
                    }
                }
                for (plan.items) |*m| {
                    const rk = self.allocator.dupe(u8, m.old_key) catch {
                        m.node.deinit(self.allocator);
                        self.allocator.destroy(m.node);
                        continue;
                    };
                    self.nodes().put(self.allocator, rk, m.node) catch {
                        self.allocator.free(rk);
                        m.node.deinit(self.allocator);
                        self.allocator.destroy(m.node);
                        continue;
                    };
                    m.inserted_key = rk;
                }
                for (plan.items) |m| {
                    if (m.inserted_key) |ik| self.linkChild(ik) catch {};
                }
            }
        }

        // Detach longest keys first (children before parents).
        std.mem.sort(Move, plan.items, {}, struct {
            fn less(_: void, a: Move, b: Move) bool {
                return a.old_key.len > b.old_key.len;
            }
        }.less);

        for (plan.items) |*m| {
            self.unlinkFromParent(m.old_key);
            if (self.nodes().fetchRemove(m.old_key)) |kv| {
                self.allocator.free(kv.key);
            }
        }
        detached = true;

        // Children values were absolute paths under old_abs — drop and rebuild.
        for (plan.items) |m| {
            if (m.node.kind == .dir) self.clearChildrenMap(m.node);
        }

        // Insert shortest first so parent dirs exist for linkChild.
        std.mem.sort(Move, plan.items, {}, struct {
            fn less(_: void, a: Move, b: Move) bool {
                return a.new_key.len < b.new_key.len;
            }
        }.less);

        for (plan.items) |*m| {
            const key_for_map = try self.allocator.dupe(u8, m.new_key);
            errdefer self.allocator.free(key_for_map);
            try self.nodes().put(self.allocator, key_for_map, m.node);
            m.inserted_key = key_for_map;
        }
        for (plan.items) |m| {
            try self.linkChild(m.inserted_key.?);
        }
    }

    pub fn tempFile(self: *Mem, dir: []const u8, prefix: []const u8) (Allocator.Error || Error)!MemFile {
        self.temp_seq += 1;
        var buf: [160]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "{s}_{d}", .{ prefix, self.temp_seq }) catch return error.InvalidMode;
        const d = if (dir.len == 0) self.root_path else dir;
        const path = try self.joinPath(&.{ d, name });
        defer self.allocator.free(path);
        return self.openFile(path, O.RDWR | O.CREATE | O.EXCL, 0o600);
    }

    pub fn chroot(self: *Mem, path: []const u8) (Allocator.Error || Error)!Mem {
        // On success, ownership of `abs` transfers to the returned view's root_path.
        // On error, free it once (no errdefer + free pair).
        const abs = try self.toAbs(path);
        const node = self.nodes().get(abs) orelse {
            self.allocator.free(abs);
            return error.NotExist;
        };
        if (node.kind != .dir) {
            self.allocator.free(abs);
            return error.NotDir;
        }
        return .{
            .allocator = self.allocator,
            .shared_nodes = self.nodes(), // root map header (must outlive this view)
            .root_path = abs,
            .temp_seq = self.temp_seq,
            .owns_store = false,
        };
    }

    pub fn symlink(self: *Mem, target: []const u8, link: []const u8) (Allocator.Error || Error)!void {
        const abs = try self.toAbs(link);
        defer self.allocator.free(abs);
        if (self.nodes().contains(abs)) return error.Exist;
        try self.putDir(parentOf(abs));
        const node = try self.allocator.create(Node);
        node.* = .{ .kind = .symlink, .mode = 0o120777 };
        node.data.appendSlice(self.allocator, target) catch |err| {
            self.allocator.destroy(node);
            return err;
        };
        const key = self.allocator.dupe(u8, abs) catch |err| {
            node.deinit(self.allocator);
            self.allocator.destroy(node);
            return err;
        };
        self.nodes().put(self.allocator, key, node) catch |err| {
            self.allocator.free(key);
            node.deinit(self.allocator);
            self.allocator.destroy(node);
            return err;
        };
        self.linkChild(abs) catch |err| {
            if (self.nodes().fetchRemove(abs)) |kv| {
                kv.value.deinit(self.allocator);
                self.allocator.destroy(kv.value);
                self.allocator.free(kv.key);
            }
            return err;
        };
    }

    pub fn readlink(self: *Mem, link: []const u8) (Allocator.Error || Error)![]u8 {
        const abs = try self.toAbs(link);
        defer self.allocator.free(abs);
        const node = self.nodes().get(abs) orelse return error.NotExist;
        if (node.kind != .symlink) return error.NotLink;
        return try self.allocator.dupe(u8, node.data.items);
    }
};

pub const MemFile = struct {
    mem: *Mem,
    name: []u8,
    /// Index into `mem.open_names` for O(1) release on close.
    open_name_index: usize,
    node: *Node,
    flag: u32,
    pos: i64 = 0,
    closed: bool = false,

    pub fn fileName(self: *const MemFile) []const u8 {
        return self.name;
    }

    pub fn read(self: *MemFile, buf: []u8) Error!usize {
        if (self.closed) return error.Closed;
        if (self.flag & O.WRONLY != 0 and self.flag & O.RDWR == 0) return error.InvalidMode;
        const n = try self.readAt(buf, self.pos);
        self.pos += @intCast(n);
        return n;
    }

    pub fn readAt(self: *MemFile, buf: []u8, off: i64) Error!usize {
        if (self.closed) return error.Closed;
        if (off < 0) return error.InvalidMode;
        const o: usize = @intCast(off);
        if (o >= self.node.data.items.len) return 0;
        const n = @min(buf.len, self.node.data.items.len - o);
        @memcpy(buf[0..n], self.node.data.items[o..][0..n]);
        return n;
    }

    pub fn write(self: *MemFile, data: []const u8) (Error || Allocator.Error)!usize {
        if (self.closed) return error.Closed;
        if (self.flag == O.RDONLY) return error.InvalidMode;
        const n = try self.writeAt(data, self.pos);
        self.pos += @intCast(n);
        return n;
    }

    pub fn writeAt(self: *MemFile, data: []const u8, off: i64) (Error || Allocator.Error)!usize {
        if (self.closed) return error.Closed;
        if (off < 0) return error.InvalidMode;
        const o: usize = @intCast(off);
        const end = o + data.len;
        if (self.node.data.items.len < end) try self.node.data.resize(self.mem.allocator, end);
        @memcpy(self.node.data.items[o..][0..data.len], data);
        return data.len;
    }

    pub fn seek(self: *MemFile, offset: i64, whence: enum { start, current, end }) Error!i64 {
        if (self.closed) return error.Closed;
        const new_pos: i64 = switch (whence) {
            .start => offset,
            .current => self.pos + offset,
            .end => @as(i64, @intCast(self.node.data.items.len)) + offset,
        };
        if (new_pos < 0) return error.InvalidMode;
        self.pos = new_pos;
        return self.pos;
    }

    pub fn truncate(self: *MemFile, size: i64) (Error || Allocator.Error)!void {
        if (self.closed) return error.Closed;
        if (size < 0) return error.InvalidMode;
        const s: usize = @intCast(size);
        if (s <= self.node.data.items.len) {
            self.node.data.shrinkRetainingCapacity(s);
        } else {
            try self.node.data.resize(self.mem.allocator, s);
        }
    }

    pub fn lock(_: *MemFile) Error!void {}
    pub fn unlock(_: *MemFile) Error!void {}

    pub fn close(self: *MemFile) Error!void {
        if (self.closed) return error.Closed;
        self.closed = true;
        self.mem.releaseOpenName(self.open_name_index, self.name);
        self.name = &.{};
    }
};

test "Mem round-trip file" {
    const allocator = std.testing.allocator;
    var fs = try Mem.init(allocator);
    defer fs.deinit();

    try fs.mkdirAll("objects/pack", 0o755);
    {
        var f = try fs.create("objects/pack/foo");
        defer f.close() catch {};
        _ = try f.write("hello");
    }
    {
        var f = try fs.open("objects/pack/foo");
        defer f.close() catch {};
        var buf: [8]u8 = undefined;
        const n = try f.read(&buf);
        try std.testing.expectEqualStrings("hello", buf[0..n]);
    }
    const st = try fs.stat("objects/pack/foo");
    try std.testing.expectEqual(@as(i64, 5), st.size);
}

test "Mem readDir sorted" {
    const allocator = std.testing.allocator;
    var fs = try Mem.init(allocator);
    defer fs.deinit();
    try fs.mkdirAll("refs/heads", 0o755);
    {
        var a = try fs.create("refs/heads/b");
        try a.close();
        var b = try fs.create("refs/heads/a");
        try b.close();
    }
    const entries = try fs.readDir("refs/heads");
    defer fs.freeReadDir(entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("a", entries[0].name);
    try std.testing.expectEqualStrings("b", entries[1].name);
}

test "Mem Initialize layout" {
    const allocator = std.testing.allocator;
    var fs = try Mem.init(allocator);
    defer fs.deinit();
    try fs.mkdirAll("objects/info", 0o755);
    try fs.mkdirAll("objects/pack", 0o755);
    try fs.mkdirAll("refs/heads", 0o755);
    try fs.mkdirAll("refs/tags", 0o755);
    const st = try fs.stat("objects/pack");
    try std.testing.expect(st.isDir());
}

// open_name free-list reuses slots across open/close cycles
test "Mem open name slot reuse" {
    const allocator = std.testing.allocator;
    var fs = try Mem.init(allocator);
    defer fs.deinit();

    {
        var f = try fs.create("a");
        try f.close();
    }
    try std.testing.expectEqual(@as(usize, 1), fs.open_name_free.items.len);
    {
        var f = try fs.create("b");
        // Reused the free slot; list did not grow.
        try std.testing.expectEqual(@as(usize, 1), fs.open_names.items.len);
        try f.close();
    }
    try std.testing.expectEqual(@as(usize, 1), fs.open_name_free.items.len);
}

// chroot views share the root node map (no stale HashMap header)
test "Mem chroot shares node store" {
    const allocator = std.testing.allocator;
    var root_fs = try Mem.init(allocator);
    defer root_fs.deinit();
    try root_fs.mkdirAll("objects/pack", 0o755);

    var ch = try root_fs.chroot("objects");
    defer ch.deinit();
    {
        var f = try ch.create("pack/foo");
        defer f.close() catch {};
        _ = try f.write("x");
    }
    // Visible through the root (shared map).
    _ = try root_fs.stat("objects/pack/foo");
    // Store-absolute fileName works under chroot rename/open.
    try std.testing.expect(std.mem.eql(u8, ch.root(), "/objects"));
}

// billy CrossedBoundary: `..` must not escape chroot
test "Mem chroot rejects CrossedBoundary" {
    const allocator = std.testing.allocator;
    var root_fs = try Mem.init(allocator);
    defer root_fs.deinit();
    try root_fs.mkdirAll("objects/pack", 0o755);

    var ch = try root_fs.chroot("objects");
    defer ch.deinit();
    try std.testing.expectError(error.CrossedBoundary, ch.stat(".."));
    try std.testing.expectError(error.CrossedBoundary, ch.stat("../etc"));
    try std.testing.expectError(error.CrossedBoundary, ch.open("../x"));
}

// atomic rename: same node pointer, content preserved, old path gone
test "Mem rename is atomic rekey" {
    const allocator = std.testing.allocator;
    var fs = try Mem.init(allocator);
    defer fs.deinit();
    {
        var f = try fs.create("a");
        defer f.close() catch {};
        _ = try f.write("payload");
    }
    const before = fs.nodes().get("/a").?;
    try fs.rename("a", "b");
    try std.testing.expectError(error.NotExist, fs.stat("a"));
    const after = fs.nodes().get("/b").?;
    try std.testing.expect(before == after);
    try std.testing.expectEqualStrings("payload", after.data.items);
}

// directory rename rebuilds children absolute paths for readDir
test "Mem rename directory rekeys descendants and children maps" {
    const allocator = std.testing.allocator;
    var fs = try Mem.init(allocator);
    defer fs.deinit();
    try fs.mkdirAll("old/sub", 0o755);
    {
        var f = try fs.create("old/sub/file");
        defer f.close() catch {};
        _ = try f.write("nested");
    }
    try fs.rename("old", "new");
    try std.testing.expectError(error.NotExist, fs.stat("old/sub/file"));
    const st = try fs.stat("new/sub/file");
    try std.testing.expect(st.isRegular());

    const entries = try fs.readDir("new/sub");
    defer fs.freeReadDir(entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("file", entries[0].name);

    // Parent children map points at new absolute paths.
    const parent = fs.nodes().get("/new").?;
    try std.testing.expect(parent.children.contains("sub"));
    try std.testing.expectEqualStrings("/new/sub", parent.children.get("sub").?);
}
