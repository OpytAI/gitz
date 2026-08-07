//! Transactional index storer (go-git `storage/transactional` IndexStorage).
//!
//! After `setIndex`, reads come from temporal. `commit` copies temporal → base
//! (cloned for Zig ownership of the heap `*Index`).

const std = @import("std");
const memory = @import("memory");

const Allocator = std.mem.Allocator;
const Index = memory.Index;

/// go-git `transactional.IndexStorage`.
pub const IndexStorage = struct {
    base: *memory.Storage,
    temporal: *memory.Storage,
    /// True after a successful SetIndex (go-git `set`).
    set: bool = false,

    pub fn init(base: *memory.Storage, temporal: *memory.Storage) IndexStorage {
        return .{ .base = base, .temporal = temporal };
    }

    /// go-git `SetIndex` — write temporal; mark set.
    pub fn setIndex(self: *IndexStorage, idx: *Index) void {
        self.temporal.setIndex(idx);
        self.set = true;
    }

    /// go-git `Index` — temporal when set, else base.
    pub fn index(self: *IndexStorage) Allocator.Error!*Index {
        if (!self.set) return self.base.index();
        return self.temporal.index();
    }

    /// go-git `Commit` — copy temporal index into base when set.
    pub fn commit(self: *IndexStorage) Allocator.Error!void {
        if (!self.set) return;

        const src = try self.temporal.index();
        const copy = try cloneIndex(self.base.allocator, src);
        self.base.setIndex(copy);
    }
};

/// go-git `NewIndexStorage(base, temporal)`.
pub fn newIndexStorage(base: *memory.Storage, temporal: *memory.Storage) IndexStorage {
    return IndexStorage.init(base, temporal);
}

fn cloneIndex(allocator: Allocator, src: *const Index) Allocator.Error!*Index {
    const dst = try allocator.create(Index);
    dst.* = Index.init(allocator);
    errdefer {
        dst.deinit();
        allocator.destroy(dst);
    }
    dst.version = src.version;
    for (src.entries.items) |e| {
        const entry = try dst.add(e.name);
        entry.hash = e.hash;
        entry.created_at = e.created_at;
        entry.modified_at = e.modified_at;
        entry.dev = e.dev;
        entry.inode = e.inode;
        entry.mode = e.mode;
        entry.uid = e.uid;
        entry.gid = e.gid;
        entry.size = e.size;
        entry.stage = e.stage;
        entry.skip_worktree = e.skip_worktree;
        entry.intent_to_add = e.intent_to_add;
        // `add` already owns a dup of the path name.
    }
    return dst;
}

// ---------------------------------------------------------------------------
// Tests (go-git index_test.go)
// ---------------------------------------------------------------------------

test "Index reads base when not set" {
    const allocator = std.testing.allocator;
    const base = try memory.newStorage(allocator);
    defer {
        base.deinit();
        allocator.destroy(base);
    }
    const temporal = try memory.newStorage(allocator);
    defer {
        temporal.deinit();
        allocator.destroy(temporal);
    }

    const idx = try allocator.create(Index);
    idx.* = Index.init(allocator);
    idx.version = 2;
    base.setIndex(idx);

    var cs = IndexStorage.init(base, temporal);
    const got = try cs.index();
    try std.testing.expectEqual(@as(u32, 2), got.version);
}

test "Index Commit copies temporal version to base" {
    const allocator = std.testing.allocator;
    const base = try memory.newStorage(allocator);
    defer {
        base.deinit();
        allocator.destroy(base);
    }
    const temporal = try memory.newStorage(allocator);
    defer {
        temporal.deinit();
        allocator.destroy(temporal);
    }

    const idx_base = try allocator.create(Index);
    idx_base.* = Index.init(allocator);
    idx_base.version = 2;
    base.setIndex(idx_base);

    const idx_tmp = try allocator.create(Index);
    idx_tmp.* = Index.init(allocator);
    idx_tmp.version = 3;

    var is = IndexStorage.init(base, temporal);
    is.setIndex(idx_tmp);
    try is.commit();

    const base_index = try base.index();
    try std.testing.expectEqual(@as(u32, 3), base_index.version);
}
