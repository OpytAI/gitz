//! Errors from `Worktree.merge`. An error means HEAD, the index, and the
//! worktree were left unchanged. A conflict is a `MergeResult` with
//! `clean == false`, not an error, except `OctopusConflict` (Git refuses
//! the merge and writes nothing).

pub const Error = error{
    /// No commits were passed to merge.
    NoMergeHeads,
    /// HEAD does not name a commit yet.
    UnbornHead,
    /// `MERGE_HEAD` is already present.
    MergeInProgress,
    /// `mergeAbort` / `mergeContinue` found no merge to finish.
    MergeNotInProgress,
    /// `MERGE_HEAD` is present but `ORIG_HEAD` or `MERGE_MSG` is not.
    CorruptMergeState,
    /// A tracked index path does not match HEAD.
    DirtyIndex,
    /// A tracked worktree path does not match the index bytes.
    DirtyWorktree,
    /// The histories share no ancestor and the caller did not allow that.
    UnrelatedHistories,
    /// A needed parent is missing and the repository is shallow.
    ShallowHistory,
    /// `merge --ff-only` and HEAD is not an ancestor of the incoming commit.
    NotFastForward,
    /// The strategy does not accept this head count or option.
    StrategyOptionNotSupported,
    /// Octopus could not be done with trivial per-path takes.
    OctopusConflict,
    /// `-s subtree` found zero or several root directories to shift.
    SubtreeShiftNotFound,
    /// Virtual merge-base recursion passed 32 levels.
    VirtualMergeDepth,
    /// `mergeContinue` has no `user.name` / `user.email`.
    MissingAuthor,
    /// Index still has a stage other than 0.
    UnmergedPaths,
    /// Git file name was empty, too long, or contained a separator.
    InvalidGitFileName,
};
