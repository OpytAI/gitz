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

/// Author or committer recorded on a merge commit.
///
/// When this is set, the merge does not read repository config or the storage clock.
pub const Identity = struct {
    name: []const u8,
    email: []const u8,
    when: i64,
    tz_offset_minutes: i16 = 0,
};

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
    /// Null keeps the label `HEAD`.
    ours_label: ?[]const u8 = null,
    /// Null keeps the full commit hash, or `theirs` when more than one head is merged.
    theirs_label: ?[]const u8 = null,
    author: ?Identity = null,
    committer: ?Identity = null,
};

/// Options for finishing a merge that already has `MERGE_HEAD`.
pub const ContinueOptions = struct {
    /// Null keeps the stored `MERGE_MSG`.
    message: ?[]const u8 = null,
    author: ?Identity = null,
    committer: ?Identity = null,
};

pub const MergeResult = struct {
    /// False when the index still has conflict stages.
    clean: bool,
    /// Set only when this call wrote a new commit object.
    commit: ?Hash = null,
};
