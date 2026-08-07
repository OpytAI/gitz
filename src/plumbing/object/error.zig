//! Shared error set for `plumbing/object` (go-git package-level `Err*`).
//!
//! Reference: go-git v5.19.2 `plumbing/object/{object,tree,tag}.go`.

const std = @import("std");

/// Package errors for logical object decode/walk (go-git `Err*` names in comments).
pub const Error = error{
    /// Non-blob/tree/commit/tag (or wrong type) during decode (`ErrUnsupportedObject`).
    UnsupportedObject,
    /// Tree path did not resolve to a file (`ErrFileNotFound`).
    FileNotFound,
    /// Tree path did not resolve to a directory (`ErrDirectoryNotFound`).
    DirectoryNotFound,
    /// Named entry missing from a tree (`ErrEntryNotFound`).
    EntryNotFound,
    /// Tree entries are not in git sort order (`ErrEntriesNotSorted`).
    EntriesNotSorted,
    /// Tree object body cannot be decoded (`ErrMalformedTree`).
    MalformedTree,
    /// Tree walk exceeded maximum depth (`ErrMaxTreeDepth`).
    MaxTreeDepth,
    /// Tag object body cannot be decoded (`ErrMalformedTag`).
    MalformedTag,
    /// Commit body missing required headers.
    MalformedCommit,
    /// Parent index out of range or missing (`ErrParentNotFound`).
    ParentNotFound,
    /// Malformed empty Change (go-git Action on empty From+To).
    MalformedChange,
    /// Operation canceled (go-git `ErrCanceled`).
    Canceled,
    /// Commit has more than one armored signature block.
    MultipleSignatures,
    /// Signature verification failed (bad key / bad signature).
    InvalidSignature,
};

test "Error set matches go-git object Err* names" {
    try std.testing.expect(Error.UnsupportedObject == error.UnsupportedObject);
    try std.testing.expect(Error.FileNotFound == error.FileNotFound);
    try std.testing.expect(Error.DirectoryNotFound == error.DirectoryNotFound);
    try std.testing.expect(Error.EntryNotFound == error.EntryNotFound);
    try std.testing.expect(Error.EntriesNotSorted == error.EntriesNotSorted);
    try std.testing.expect(Error.MalformedTree == error.MalformedTree);
    try std.testing.expect(Error.MaxTreeDepth == error.MaxTreeDepth);
    try std.testing.expect(Error.MalformedTag == error.MalformedTag);
    try std.testing.expect(Error.MalformedCommit == error.MalformedCommit);
    try std.testing.expect(Error.ParentNotFound == error.ParentNotFound);
    try std.testing.expect(Error.MalformedChange == error.MalformedChange);
    try std.testing.expect(Error.Canceled == error.Canceled);
    try std.testing.expect(Error.MultipleSignatures == error.MultipleSignatures);
    try std.testing.expect(Error.InvalidSignature == error.InvalidSignature);
}
