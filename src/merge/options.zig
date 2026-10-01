//! Public merge options. These types are the worktree API. They are not the
//! `Repository.merge` fast-forward enum.

const plumbing = @import("plumbing");

const Hash = plumbing.Hash;

/// Built-in `git merge -s` strategy. `recursive` runs the same code as `ort`.
pub const Strategy = enum { ort, recursive, resolve, octopus, ours, subtree };

/// Fast-forward mode (`--ff`, `--no-ff`, `--ff-only`). Not a strategy.
pub const FastForward = enum { ff, no_ff, ff_only };

/// `-X ours` / `-X theirs`. Only `ort`, `recursive`, and `subtree` accept these.
pub const Favor = enum { none, ours, theirs };

/// `-X diff-algorithm`. `minimal` is Myers with no deadline.
pub const DiffAlgorithm = enum { histogram, myers, minimal, patience };

/// Conflict marker style. Taken from this struct, not from stored config.
pub const ConflictStyle = enum { merge, diff3, zdiff3 };

pub const MergeOptions = struct {
    strategy: ?Strategy = null,
    fast_forward: FastForward = .ff,
    message: ?[]const u8 = null,
    no_commit: bool = false,
    allow_unrelated_histories: bool = false,
    favor: Favor = .none,
    diff_algorithm: DiffAlgorithm = .histogram,
    find_renames: bool = true,
    rename_threshold: u8 = 50,
    conflict_style: ConflictStyle = .merge,
    /// `subtree` shift prefix. Null asks the engine to pick one root directory.
    subtree_path: ?[]const u8 = null,
};

pub const MergeResult = struct {
    /// False when the index still has conflict stages.
    clean: bool,
    /// Set only when this call wrote a new commit object.
    commit: ?Hash = null,
};
