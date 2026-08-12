//! Object-store CommitNode backend
//! (go-git `plumbing/object/commitgraph/commitnode_object.go`).
//!
//! Loads full `object.Commit` values from an EncodedObjectStorer and presents
//! them as `CommitNode`. Generation is always `max_generation` so graph nodes
//! are preferred for reachability when mixed.

const std = @import("std");
const plumbing = @import("plumbing");
const object = @import("object");

const commitnode = @import("commitnode.zig");

const Hash = plumbing.Hash;
const Allocator = std.mem.Allocator;
const CommitNode = commitnode.CommitNode;
const CommitNodeIndex = commitnode.CommitNodeIndex;
const max_generation = commitnode.max_generation;
const whenUnixSeconds = commitnode.whenUnixSeconds;

// ---------------------------------------------------------------------------
// ObjectCommitNodeIndex
// ---------------------------------------------------------------------------

/// CommitNodeIndex backed only by the object store
/// (go-git `objectCommitNodeIndex`).
pub const ObjectCommitNodeIndex = struct {
    allocator: Allocator,
    storage: *anyopaque,
    get_commit_fn: *const fn (storage: *anyopaque, allocator: Allocator, hash: Hash) anyerror!*object.Commit,

    /// Build an index over any storer that `object.getCommit` accepts.
    pub fn init(allocator: Allocator, comptime Storage: type, storage: *Storage) ObjectCommitNodeIndex {
        const gen = struct {
            fn getCommit(ptr: *anyopaque, alloc: Allocator, hash: Hash) anyerror!*object.Commit {
                const s: *Storage = @ptrCast(@alignCast(ptr));
                return object.getCommit(alloc, s, hash);
            }
        };
        return .{
            .allocator = allocator,
            .storage = storage,
            .get_commit_fn = gen.getCommit,
        };
    }

    /// go-git `objectCommitNodeIndex.Get`.
    pub fn get(self: *ObjectCommitNodeIndex, hash: Hash) anyerror!CommitNode {
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

    pub fn asIndex(self: *ObjectCommitNodeIndex) CommitNodeIndex {
        return .{
            .ptr = self,
            .vtable = &object_index_vtable,
        };
    }

    pub fn deinit(self: *ObjectCommitNodeIndex) void {
        self.allocator.destroy(self);
    }
};

const object_index_vtable = CommitNodeIndex.VTable{
    .get = objectIndexGet,
    .deinit = objectIndexDeinit,
};

fn objectIndexGet(ptr: *anyopaque, hash: Hash) anyerror!CommitNode {
    const self: *ObjectCommitNodeIndex = @ptrCast(@alignCast(ptr));
    return self.get(hash);
}

fn objectIndexDeinit(ptr: *anyopaque) void {
    const self: *ObjectCommitNodeIndex = @ptrCast(@alignCast(ptr));
    self.deinit();
}

/// go-git `NewObjectCommitNodeIndex` — heap-allocates the index box.
///
/// Free with `CommitNodeIndex.deinit`. Does not free `storage`.
pub fn newObjectCommitNodeIndex(
    allocator: Allocator,
    comptime Storage: type,
    storage: *Storage,
) Allocator.Error!CommitNodeIndex {
    const idx = try allocator.create(ObjectCommitNodeIndex);
    idx.* = ObjectCommitNodeIndex.init(allocator, Storage, storage);
    return idx.asIndex();
}

// ---------------------------------------------------------------------------
// ObjectCommitNode
// ---------------------------------------------------------------------------

/// CommitNode wrapping a decoded `object.Commit`
/// (go-git `objectCommitNode`).
pub const ObjectCommitNode = struct {
    allocator: Allocator,
    node_index: CommitNodeIndex,
    commit: *object.Commit,
    /// When true, `deinit` frees `commit`.
    owns_commit: bool = true,

    pub fn asNode(self: *ObjectCommitNode) CommitNode {
        return .{
            .ptr = self,
            .vtable = &object_node_vtable,
        };
    }

    pub fn id(self: *const ObjectCommitNode) Hash {
        return self.commit.id();
    }

    pub fn commitTimeSec(self: *const ObjectCommitNode) i64 {
        return whenUnixSeconds(self.commit.committer);
    }

    pub fn numParents(self: *const ObjectCommitNode) usize {
        return self.commit.numParents();
    }

    pub fn parentNode(self: *ObjectCommitNode, i: usize) anyerror!CommitNode {
        const parents = self.commit.parent_hashes;
        if (i >= parents.len) return error.ParentNotFound;
        // Route through the index so a mixed graph can take over
        // (go-git comment on ParentNode).
        return self.node_index.get(parents[i]);
    }

    pub fn parentHashes(self: *const ObjectCommitNode) []const Hash {
        return self.commit.parent_hashes;
    }

    pub fn generation(_: *const ObjectCommitNode) u64 {
        return max_generation;
    }

    pub fn generationV2(_: *const ObjectCommitNode) u64 {
        return max_generation;
    }

    /// Always returns a fresh heap-owned `*Commit`; caller must `freeCommit`.
    /// Reloads from the storer so callers never free the node's cached commit.
    pub fn commitObj(self: *ObjectCommitNode) anyerror!*object.Commit {
        const getter = self.commit.storer orelse return error.ObjectNotFound;
        return object.getCommitFromGetter(self.allocator, getter, self.commit.hash);
    }

    pub fn tree(self: *ObjectCommitNode) anyerror!*object.Tree {
        // Load via the commit's ObjectGetter (go-git `commit.Tree`).
        const getter = self.commit.storer orelse return error.ObjectNotFound;
        const o = try getter.encodedObject(.tree, self.commit.tree_hash);
        // decodeTreeNoStore returns heap `*Tree` (caller owns).
        return try object.decodeTreeNoStore(self.allocator, o);
    }

    pub fn deinit(self: *ObjectCommitNode) void {
        if (self.owns_commit) {
            object.freeCommit(self.allocator, self.commit);
        }
        self.allocator.destroy(self);
    }
};

const object_node_vtable = CommitNode.VTable{
    .id = objectNodeId,
    .commit_time_sec = objectNodeCommitTimeSec,
    .author_time_sec = objectNodeAuthorTimeSec,
    .num_parents = objectNodeNumParents,
    .parent_node = objectNodeParentNode,
    .parent_hashes = objectNodeParentHashes,
    .generation = objectNodeGeneration,
    .generation_v2 = objectNodeGenerationV2,
    .commit = objectNodeCommit,
    .tree = objectNodeTree,
    .deinit = objectNodeDeinit,
};

fn objectNodeId(ptr: *anyopaque) Hash {
    const self: *ObjectCommitNode = @ptrCast(@alignCast(ptr));
    return self.id();
}

fn objectNodeCommitTimeSec(ptr: *anyopaque) i64 {
    const self: *ObjectCommitNode = @ptrCast(@alignCast(ptr));
    return self.commitTimeSec();
}

fn objectNodeAuthorTimeSec(ptr: *anyopaque) i64 {
    const self: *ObjectCommitNode = @ptrCast(@alignCast(ptr));
    return self.commit.author.when;
}

fn objectNodeNumParents(ptr: *anyopaque) usize {
    const self: *ObjectCommitNode = @ptrCast(@alignCast(ptr));
    return self.numParents();
}

fn objectNodeParentNode(ptr: *anyopaque, i: usize) anyerror!CommitNode {
    const self: *ObjectCommitNode = @ptrCast(@alignCast(ptr));
    return self.parentNode(i);
}

fn objectNodeParentHashes(ptr: *anyopaque) []const Hash {
    const self: *ObjectCommitNode = @ptrCast(@alignCast(ptr));
    return self.parentHashes();
}

fn objectNodeGeneration(ptr: *anyopaque) u64 {
    const self: *ObjectCommitNode = @ptrCast(@alignCast(ptr));
    return self.generation();
}

fn objectNodeGenerationV2(ptr: *anyopaque) u64 {
    const self: *ObjectCommitNode = @ptrCast(@alignCast(ptr));
    return self.generationV2();
}

fn objectNodeCommit(ptr: *anyopaque) anyerror!*object.Commit {
    const self: *ObjectCommitNode = @ptrCast(@alignCast(ptr));
    return self.commitObj();
}

fn objectNodeTree(ptr: *anyopaque) anyerror!*object.Tree {
    const self: *ObjectCommitNode = @ptrCast(@alignCast(ptr));
    return self.tree();
}

fn objectNodeDeinit(ptr: *anyopaque) void {
    const self: *ObjectCommitNode = @ptrCast(@alignCast(ptr));
    self.deinit();
}
