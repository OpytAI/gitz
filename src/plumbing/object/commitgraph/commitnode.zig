//! CommitNode / CommitNodeIndex interfaces and parent iterator
//! (go-git `plumbing/object/commitgraph/commitnode.go`).
//!
//! Zig has no Go interfaces. Runtime polymorphism uses type-erased fat
//! pointers (`CommitNode`, `CommitNodeIndex`, `CommitNodeIter`) so object-store
//! and commit-graph backends can share walkers.

const std = @import("std");
const plumbing = @import("plumbing");
const object = @import("object");

const Hash = plumbing.Hash;

// ---------------------------------------------------------------------------
// CommitNode (go-git CommitNode)
// ---------------------------------------------------------------------------

/// Lightweight commit view for history walks (go-git `CommitNode`).
///
/// Concrete backends: `ObjectCommitNode`, `GraphCommitNode`.
/// Call `deinit` when the node is no longer needed (frees the heap box).
pub const CommitNode = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        id: *const fn (ptr: *anyopaque) Hash,
        commit_time_sec: *const fn (ptr: *anyopaque) i64,
        /// Author time (unix sec). May load a full commit on graph backends.
        author_time_sec: *const fn (ptr: *anyopaque) i64,
        num_parents: *const fn (ptr: *anyopaque) usize,
        parent_node: *const fn (ptr: *anyopaque, i: usize) anyerror!CommitNode,
        parent_hashes: *const fn (ptr: *anyopaque) []const Hash,
        generation: *const fn (ptr: *anyopaque) u64,
        generation_v2: *const fn (ptr: *anyopaque) u64,
        commit: *const fn (ptr: *anyopaque) anyerror!*object.Commit,
        tree: *const fn (ptr: *anyopaque) anyerror!*object.Tree,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// go-git `CommitNode.ID`.
    pub fn id(self: CommitNode) Hash {
        return self.vtable.id(self.ptr);
    }

    /// Committer time as Unix seconds (go-git `CommitNode.CommitTime`).
    pub fn commitTimeSec(self: CommitNode) i64 {
        return self.vtable.commit_time_sec(self.ptr);
    }

    /// Author time as Unix seconds (for `--author-order` walks).
    pub fn authorTimeSec(self: CommitNode) i64 {
        return self.vtable.author_time_sec(self.ptr);
    }

    /// go-git `CommitNode.NumParents`.
    pub fn numParents(self: CommitNode) usize {
        return self.vtable.num_parents(self.ptr);
    }

    /// go-git `CommitNode.ParentNode`.
    pub fn parentNode(self: CommitNode, i: usize) anyerror!CommitNode {
        return self.vtable.parent_node(self.ptr, i);
    }

    /// go-git `CommitNode.ParentHashes`.
    pub fn parentHashes(self: CommitNode) []const Hash {
        return self.vtable.parent_hashes(self.ptr);
    }

    /// go-git `CommitNode.Generation`.
    pub fn generation(self: CommitNode) u64 {
        return self.vtable.generation(self.ptr);
    }

    /// go-git `CommitNode.GenerationV2`.
    pub fn generationV2(self: CommitNode) u64 {
        return self.vtable.generation_v2(self.ptr);
    }

    /// Full commit object (go-git `CommitNode.Commit`).
    /// Always returns a heap-owned `*Commit`; caller must `freeCommit`.
    pub fn commit(self: CommitNode) anyerror!*object.Commit {
        return self.vtable.commit(self.ptr);
    }

    /// Root tree (go-git `CommitNode.Tree`).
    pub fn tree(self: CommitNode) anyerror!*object.Tree {
        return self.vtable.tree(self.ptr);
    }

    /// Free the heap-allocated concrete node.
    pub fn deinit(self: CommitNode) void {
        self.vtable.deinit(self.ptr);
    }

    /// Parent iterator (go-git `CommitNode.ParentNodes`).
    pub fn parentNodes(self: CommitNode) ParentCommitNodeIter {
        return ParentCommitNodeIter.init(self);
    }
};

// ---------------------------------------------------------------------------
// CommitNodeIndex (go-git CommitNodeIndex)
// ---------------------------------------------------------------------------

/// Index that resolves commit hashes to `CommitNode` values
/// (go-git `CommitNodeIndex`).
pub const CommitNodeIndex = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ptr: *anyopaque, hash: Hash) anyerror!CommitNode,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// go-git `CommitNodeIndex.Get`.
    pub fn get(self: CommitNodeIndex, hash: Hash) anyerror!CommitNode {
        return self.vtable.get(self.ptr, hash);
    }

    /// Free the heap-allocated concrete index (not the storer / graph).
    pub fn deinit(self: CommitNodeIndex) void {
        self.vtable.deinit(self.ptr);
    }
};

// ---------------------------------------------------------------------------
// CommitNodeIter (go-git CommitNodeIter)
// ---------------------------------------------------------------------------

/// Closable iterator over commit nodes (go-git `CommitNodeIter`).
pub const CommitNodeIter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        next: *const fn (ptr: *anyopaque) anyerror!CommitNode,
        close: *const fn (ptr: *anyopaque) void,
    };

    /// go-git `CommitNodeIter.Next`. Returns `error.EndOfStream` at end.
    pub fn next(self: CommitNodeIter) anyerror!CommitNode {
        return self.vtable.next(self.ptr);
    }

    /// go-git `CommitNodeIter.ForEach` (R4b: free-after-cb).
    ///
    /// Borrow during callback; free each heap-owned node after the callback
    /// returns including `error.Stop` and other errors. Always `close`s so
    /// unyielded holds are released. Callbacks must **not** free the node.
    /// After `forEach` returns the iterator is closed — do not call `close` again
    /// when the concrete close frees the heap box (CTime/topo walkers).
    pub fn forEach(self: CommitNodeIter, cb: anytype) !void {
        return forEachCommitNode(self, cb);
    }

    /// go-git `CommitNodeIter.Close`.
    pub fn close(self: CommitNodeIter) void {
        self.vtable.close(self.ptr);
    }
};

/// Shared R4b forEach for CommitNode iterators (fat + concrete + parent).
/// Free after callback including Stop/error; always close.
pub fn forEachCommitNode(iter: anytype, cb: anytype) !void {
    defer iter.close();
    while (true) {
        const node = iter.next() catch |err| {
            if (err == error.EndOfStream) return;
            return err;
        };
        var freed = false;
        defer if (!freed) node.deinit();
        cb(node) catch |err| {
            // go-git `storer.ErrStop` — free via defer, then success-return
            if (err == error.Stop) return;
            return err;
        };
        node.deinit();
        freed = true;
    }
}

// ---------------------------------------------------------------------------
// Parent iterator (go-git parentCommitNodeIter)
// ---------------------------------------------------------------------------

/// Iterator over parent nodes of a single `CommitNode`
/// (go-git `parentCommitNodeIter` / `newParentgraphCommitNodeIter`).
pub const ParentCommitNodeIter = struct {
    node: CommitNode,
    i: usize = 0,
    closed: bool = false,

    pub fn init(node: CommitNode) ParentCommitNodeIter {
        return .{ .node = node };
    }

    /// go-git `parentCommitNodeIter.Next`.
    pub fn next(self: *ParentCommitNodeIter) anyerror!CommitNode {
        if (self.closed) return error.EndOfStream;
        const obj = self.node.parentNode(self.i) catch |err| {
            if (err == error.ParentNotFound) return error.EndOfStream;
            return err;
        };
        self.i += 1;
        return obj;
    }

    /// go-git `parentCommitNodeIter.ForEach` (R4b: free-after-cb).
    ///
    /// `next` yields immediately (no unyielded parent stack). Free each yield
    /// after the callback including Stop/error; `close` only marks closed.
    pub fn forEach(self: *ParentCommitNodeIter, cb: anytype) !void {
        return forEachCommitNode(self, cb);
    }

    /// go-git `parentCommitNodeIter.Close`.
    /// No buffered unyielded parents today — only marks closed.
    pub fn close(self: *ParentCommitNodeIter) void {
        self.closed = true;
    }

    pub fn asIter(self: *ParentCommitNodeIter) CommitNodeIter {
        return .{
            .ptr = self,
            .vtable = &parent_iter_vtable,
        };
    }
};

const parent_iter_vtable = CommitNodeIter.VTable{
    .next = parentIterNext,
    .close = parentIterClose,
};

fn parentIterNext(ptr: *anyopaque) anyerror!CommitNode {
    const self: *ParentCommitNodeIter = @ptrCast(@alignCast(ptr));
    return self.next();
}

fn parentIterClose(ptr: *anyopaque) void {
    const self: *ParentCommitNodeIter = @ptrCast(@alignCast(ptr));
    self.close();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Max generation for object-store nodes outside the commit-graph
/// (go-git `math.MaxUint64`).
pub const max_generation: u64 = std.math.maxInt(u64);

/// Extract Unix seconds from Signature / CommitData / Time values.
pub fn whenUnixSeconds(when: anytype) i64 {
    const T = @TypeOf(when);
    if (T == i64 or T == u64 or T == i32 or T == u32) return @intCast(when);
    if (@hasField(T, "when_unix")) return when.when_unix;
    if (@hasField(T, "sec")) return when.sec;
    if (@hasField(T, "when")) {
        const W = @TypeOf(when.when);
        if (W == i64 or W == u64 or W == i32 or W == u32) return @intCast(when.when);
        if (@hasField(W, "sec")) return when.when.sec;
    }
    @compileError("unsupported When/Time type for commitgraph");
}

test "max_generation is MaxUint64" {
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), max_generation);
}
