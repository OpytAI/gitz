//! Commit-graph file CommitNode backend
//! (go-git `plumbing/object/commitgraph/commitnode_graph.go`).
//!
//! Uses `format/commitgraph` Index when the hash is present; falls back to
//! `ObjectCommitNode` via the object store for commits outside the graph.

const std = @import("std");
const plumbing = @import("plumbing");
const object = @import("object");
const commitgraph = @import("commitgraph");

const commitnode = @import("commitnode.zig");
const object_mod = @import("commitnode_object.zig");

const Hash = plumbing.Hash;
const Allocator = std.mem.Allocator;
const CommitNode = commitnode.CommitNode;
const CommitNodeIndex = commitnode.CommitNodeIndex;
const ObjectCommitNode = object_mod.ObjectCommitNode;
const whenUnixSeconds = commitnode.whenUnixSeconds;

// ---------------------------------------------------------------------------
// Type-erased commit-graph Index adapter
// ---------------------------------------------------------------------------

/// Minimal method set from format commitgraph Index used by graph nodes.
pub const GraphIndex = struct {
    ptr: *anyopaque,
    get_index_by_hash_fn: *const fn (ptr: *anyopaque, h: Hash) anyerror!u32,
    get_commit_data_by_index_fn: *const fn (ptr: *anyopaque, i: u32) anyerror!*commitgraph.CommitData,

    pub fn from(comptime T: type, impl: *T) GraphIndex {
        const gen = struct {
            fn getIndexByHash(ptr: *anyopaque, h: Hash) anyerror!u32 {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.getIndexByHash(h);
            }
            fn getCommitDataByIndex(ptr: *anyopaque, i: u32) anyerror!*commitgraph.CommitData {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.getCommitDataByIndex(i);
            }
        };
        return .{
            .ptr = impl,
            .get_index_by_hash_fn = gen.getIndexByHash,
            .get_commit_data_by_index_fn = gen.getCommitDataByIndex,
        };
    }

    pub fn getIndexByHash(self: GraphIndex, h: Hash) anyerror!u32 {
        return self.get_index_by_hash_fn(self.ptr, h);
    }

    pub fn getCommitDataByIndex(self: GraphIndex, i: u32) anyerror!*commitgraph.CommitData {
        return self.get_commit_data_by_index_fn(self.ptr, i);
    }
};

// ---------------------------------------------------------------------------
// GraphCommitNodeIndex
// ---------------------------------------------------------------------------

/// Index that prefers the commit-graph file and falls back to object storage
/// (go-git `graphCommitNodeIndex`).
pub const GraphCommitNodeIndex = struct {
    allocator: Allocator,
    commit_graph: ?GraphIndex,
    storage: *anyopaque,
    get_commit_fn: *const fn (storage: *anyopaque, allocator: Allocator, hash: Hash) anyerror!*object.Commit,
    get_tree_fn: *const fn (storage: *anyopaque, allocator: Allocator, hash: Hash) anyerror!*object.Tree,

    pub fn init(
        allocator: Allocator,
        commit_graph: ?GraphIndex,
        comptime Storage: type,
        storage: *Storage,
    ) GraphCommitNodeIndex {
        const gen = struct {
            fn getCommit(ptr: *anyopaque, alloc: Allocator, hash: Hash) anyerror!*object.Commit {
                const s: *Storage = @ptrCast(@alignCast(ptr));
                return object.getCommit(alloc, s, hash);
            }
            fn getTree(ptr: *anyopaque, alloc: Allocator, hash: Hash) anyerror!*object.Tree {
                const s: *Storage = @ptrCast(@alignCast(ptr));
                // Prefer storer-backed decode so nested paths work.
                return try object.getTree(alloc, s, hash);
            }
        };
        return .{
            .allocator = allocator,
            .commit_graph = commit_graph,
            .storage = storage,
            .get_commit_fn = gen.getCommit,
            .get_tree_fn = gen.getTree,
        };
    }

    /// go-git `graphCommitNodeIndex.Get`.
    pub fn get(self: *GraphCommitNodeIndex, hash: Hash) anyerror!CommitNode {
        if (self.commit_graph) |g| {
            if (g.getIndexByHash(hash)) |idx| {
                const data = try g.getCommitDataByIndex(idx);
                const node = try self.allocator.create(GraphCommitNode);
                node.* = .{
                    .allocator = self.allocator,
                    .hash = hash,
                    .index = idx,
                    .commit_data = data,
                    .gci = self,
                };
                return node.asNode();
            } else |_| {
                // Not in graph — fall through to object store.
            }
        }

        const commit = try self.get_commit_fn(self.storage, self.allocator, hash);
        errdefer object.freeCommit(self.allocator, commit);

        const node = try self.allocator.create(ObjectCommitNode);
        errdefer self.allocator.destroy(node);
        node.* = .{
            .allocator = self.allocator,
            .node_index = self.asIndex(),
            .commit = commit,
            .owns_commit = true,
        };
        return node.asNode();
    }

    pub fn asIndex(self: *GraphCommitNodeIndex) CommitNodeIndex {
        return .{
            .ptr = self,
            .vtable = &graph_index_vtable,
        };
    }

    pub fn deinit(self: *GraphCommitNodeIndex) void {
        self.allocator.destroy(self);
    }
};

const graph_index_vtable = CommitNodeIndex.VTable{
    .get = graphIndexGet,
    .deinit = graphIndexDeinit,
};

fn graphIndexGet(ptr: *anyopaque, hash: Hash) anyerror!CommitNode {
    const self: *GraphCommitNodeIndex = @ptrCast(@alignCast(ptr));
    return self.get(hash);
}

fn graphIndexDeinit(ptr: *anyopaque) void {
    const self: *GraphCommitNodeIndex = @ptrCast(@alignCast(ptr));
    self.deinit();
}

/// go-git `NewGraphCommitNodeIndex`.
///
/// `commit_graph` may be null to force object-store fallback while still
/// routing `ParentNode` through this index. Free with `CommitNodeIndex.deinit`.
pub fn newGraphCommitNodeIndex(
    allocator: Allocator,
    commit_graph: ?GraphIndex,
    comptime Storage: type,
    storage: *Storage,
) Allocator.Error!CommitNodeIndex {
    const idx = try allocator.create(GraphCommitNodeIndex);
    idx.* = GraphCommitNodeIndex.init(allocator, commit_graph, Storage, storage);
    return idx.asIndex();
}

/// Convenience: wrap a concrete `MemoryIndex` (or any Index-like type).
pub fn newGraphCommitNodeIndexFrom(
    allocator: Allocator,
    comptime Graph: type,
    graph: *Graph,
    comptime Storage: type,
    storage: *Storage,
) Allocator.Error!CommitNodeIndex {
    return newGraphCommitNodeIndex(allocator, GraphIndex.from(Graph, graph), Storage, storage);
}

// ---------------------------------------------------------------------------
// GraphCommitNode
// ---------------------------------------------------------------------------

/// CommitNode backed by commit-graph `CommitData`
/// (go-git `graphCommitNode`).
pub const GraphCommitNode = struct {
    allocator: Allocator,
    hash: Hash,
    index: u32,
    commit_data: *commitgraph.CommitData,
    gci: *GraphCommitNodeIndex,
    /// Cached author time after first full-commit load (author-order walks).
    author_when: ?i64 = null,

    pub fn asNode(self: *GraphCommitNode) CommitNode {
        return .{
            .ptr = self,
            .vtable = &graph_node_vtable,
        };
    }

    pub fn id(self: *const GraphCommitNode) Hash {
        return self.hash;
    }

    pub fn commitTimeSec(self: *const GraphCommitNode) i64 {
        return whenUnixSeconds(self.commit_data.when);
    }

    /// Author time — loads full commit once and caches (graph has committer only).
    pub fn authorTimeSec(self: *GraphCommitNode) i64 {
        if (self.author_when) |t| return t;
        const c = self.commitObj() catch return whenUnixSeconds(self.commit_data.when);
        const t = c.author.when;
        // Graph loads a fresh *Commit — free after reading author time.
        c.deinit();
        self.allocator.destroy(c);
        self.author_when = t;
        return t;
    }

    pub fn numParents(self: *const GraphCommitNode) usize {
        // go-git uses ParentIndexes length.
        if (self.commit_data.parent_indexes.len != 0) {
            return self.commit_data.parent_indexes.len;
        }
        return self.commit_data.parent_hashes.len;
    }

    pub fn parentNode(self: *GraphCommitNode, i: usize) anyerror!CommitNode {
        const data = self.commit_data;
        const n = if (data.parent_indexes.len != 0) data.parent_indexes.len else data.parent_hashes.len;
        if (i >= n) return error.ParentNotFound;

        const g = self.gci.commit_graph orelse return error.ParentNotFound;

        // Ensure parent indexes are resolved (MemoryIndex fills lazily).
        if (data.parent_indexes.len <= i) {
            // Fall back to hash lookup via full graph Get path.
            return try self.gci.get(data.parent_hashes[i]);
        }
        const parent_index = data.parent_indexes[i];

        const parent_data = try g.getCommitDataByIndex(parent_index);
        const node = try self.allocator.create(GraphCommitNode);
        node.* = .{
            .allocator = self.allocator,
            .hash = data.parent_hashes[i],
            .index = parent_index,
            .commit_data = parent_data,
            .gci = self.gci,
        };
        return node.asNode();
    }

    pub fn parentHashes(self: *const GraphCommitNode) []const Hash {
        return self.commit_data.parent_hashes;
    }

    pub fn generation(self: *const GraphCommitNode) u64 {
        return self.commit_data.generation;
    }

    pub fn generationV2(self: *const GraphCommitNode) u64 {
        return self.commit_data.generation_v2;
    }

    pub fn commitObj(self: *GraphCommitNode) anyerror!*object.Commit {
        return self.gci.get_commit_fn(self.gci.storage, self.allocator, self.hash);
    }

    pub fn tree(self: *GraphCommitNode) anyerror!*object.Tree {
        return self.gci.get_tree_fn(self.gci.storage, self.allocator, self.commit_data.tree_hash);
    }

    pub fn deinit(self: *GraphCommitNode) void {
        // CommitData is owned by the format index, not the node.
        self.allocator.destroy(self);
    }
};

const graph_node_vtable = CommitNode.VTable{
    .id = graphNodeId,
    .commit_time_sec = graphNodeCommitTimeSec,
    .author_time_sec = graphNodeAuthorTimeSec,
    .num_parents = graphNodeNumParents,
    .parent_node = graphNodeParentNode,
    .parent_hashes = graphNodeParentHashes,
    .generation = graphNodeGeneration,
    .generation_v2 = graphNodeGenerationV2,
    .commit = graphNodeCommit,
    .tree = graphNodeTree,
    .deinit = graphNodeDeinit,
};

fn graphNodeId(ptr: *anyopaque) Hash {
    const self: *GraphCommitNode = @ptrCast(@alignCast(ptr));
    return self.id();
}

fn graphNodeCommitTimeSec(ptr: *anyopaque) i64 {
    const self: *GraphCommitNode = @ptrCast(@alignCast(ptr));
    return self.commitTimeSec();
}

fn graphNodeAuthorTimeSec(ptr: *anyopaque) i64 {
    const self: *GraphCommitNode = @ptrCast(@alignCast(ptr));
    return self.authorTimeSec();
}

fn graphNodeNumParents(ptr: *anyopaque) usize {
    const self: *GraphCommitNode = @ptrCast(@alignCast(ptr));
    return self.numParents();
}

fn graphNodeParentNode(ptr: *anyopaque, i: usize) anyerror!CommitNode {
    const self: *GraphCommitNode = @ptrCast(@alignCast(ptr));
    return self.parentNode(i);
}

fn graphNodeParentHashes(ptr: *anyopaque) []const Hash {
    const self: *GraphCommitNode = @ptrCast(@alignCast(ptr));
    return self.parentHashes();
}

fn graphNodeGeneration(ptr: *anyopaque) u64 {
    const self: *GraphCommitNode = @ptrCast(@alignCast(ptr));
    return self.generation();
}

fn graphNodeGenerationV2(ptr: *anyopaque) u64 {
    const self: *GraphCommitNode = @ptrCast(@alignCast(ptr));
    return self.generationV2();
}

fn graphNodeCommit(ptr: *anyopaque) anyerror!*object.Commit {
    const self: *GraphCommitNode = @ptrCast(@alignCast(ptr));
    return self.commitObj();
}

fn graphNodeTree(ptr: *anyopaque) anyerror!*object.Tree {
    const self: *GraphCommitNode = @ptrCast(@alignCast(ptr));
    return self.tree();
}

fn graphNodeDeinit(ptr: *anyopaque) void {
    const self: *GraphCommitNode = @ptrCast(@alignCast(ptr));
    self.deinit();
}
