//! plumbing/object — logical Git objects (go-git `plumbing/object`).
//!
//! Blob, Tree, Commit, Tag, walkers, and decode helpers over EncodedObjectStorer
//! backends (`*MemoryObject` storage).

const error_mod = @import("error.zig");
const signature_mod = @import("signature.zig");
const blob_mod = @import("blob.zig");
const file_mod = @import("file.zig");
const tree_mod = @import("tree.zig");
const commit_mod = @import("commit.zig");
const tag_mod = @import("tag.zig");
const object_mod = @import("object.zig");
const walker_mod = @import("commit_walker.zig");
const merge_base_mod = @import("merge_base.zig");
const change_mod = @import("change.zig");
const difftree_mod = @import("difftree.zig");
const rename_mod = @import("rename.zig");
const similarity_mod = @import("similarity.zig");
const patch_mod = @import("patch.zig");
const openpgp_mod = @import("openpgp.zig");

pub const Error = error_mod.Error;

pub const Signature = signature_mod.Signature;
pub const DateFormat = signature_mod.DateFormat;

pub const Blob = blob_mod.Blob;
pub const getBlob = blob_mod.getBlob;
pub const decodeBlob = blob_mod.decodeBlob;
pub const BlobIter = blob_mod.BlobIter;

pub const File = file_mod.File;
pub const newFile = file_mod.newFile;

pub const Tree = tree_mod.Tree;
pub const TreeEntry = tree_mod.TreeEntry;
pub const getTree = tree_mod.getTree;
pub const decodeTree = tree_mod.decodeTree;
pub const decodeTreeNoStore = tree_mod.decodeTreeNoStore;
pub const freeTree = tree_mod.freeTree;

pub const Commit = commit_mod.Commit;
pub const getCommit = commit_mod.getCommit;
pub const decodeCommit = commit_mod.decodeCommit;
pub const MessageEncoding = commit_mod.MessageEncoding;
pub const newCommitIter = commit_mod.newCommitIter;
pub const StorerCommitIter = commit_mod.StorerCommitIter;
pub const CommitParentIter = commit_mod.CommitParentIter;

pub const Tag = tag_mod.Tag;
pub const getTag = tag_mod.getTag;
pub const decodeTag = tag_mod.decodeTag;
pub const TagIter = tag_mod.TagIter;
pub const newTagIter = tag_mod.newTagIter;

pub const getObject = object_mod.getObject;
pub const decodeObject = object_mod.decodeObject;

pub const CommitIter = walker_mod.CommitIter;
pub const HashSet = walker_mod.HashSet;
pub const CommitFilter = walker_mod.CommitFilter;
pub const CTimeIter = walker_mod.CTimeIter;
pub const LimitIter = walker_mod.LimitIter;
pub const LogLimitOptions = walker_mod.LogLimitOptions;
pub const PathFilter = walker_mod.PathFilter;
pub const PathIter = walker_mod.PathIter;
pub const AllIter = walker_mod.AllIter;
pub const FilterCommitIter = walker_mod.FilterCommitIter;
pub const newCommitPreorderIter = walker_mod.newCommitPreorderIter;
pub const newCommitPostorderIter = walker_mod.newCommitPostorderIter;
pub const newCommitIterBsf = walker_mod.newCommitIterBsf;
pub const newCommitIterCTime = walker_mod.newCommitIterCTime;
pub const newFilterCommitIter = walker_mod.newFilterCommitIter;
pub const newCommitPathIterFromIter = walker_mod.newCommitPathIterFromIter;
pub const newCommitFileIterFromIter = walker_mod.newCommitFileIterFromIter;
pub const newCommitLimitIterFromIter = walker_mod.newCommitLimitIterFromIter;
pub const newCommitAllIterFromTips = walker_mod.newCommitAllIterFromTips;
pub const newCommitAllIterFromHashes = walker_mod.newCommitAllIterFromHashes;
/// go-git `NewCommitAllIter` — alias of tip-based all-refs walk.
pub const newCommitAllIter = walker_mod.newCommitAllIterFromTips;

pub const mergeBase = merge_base_mod.mergeBase;
pub const isAncestor = merge_base_mod.isAncestor;
pub const independents = merge_base_mod.independents;

pub const Change = change_mod.Change;
pub const ChangeEntry = change_mod.ChangeEntry;
pub const Changes = change_mod.Changes;
pub const Action = change_mod.Action;
pub const DiffTreeOptions = change_mod.DiffTreeOptions;
pub const DiffError = difftree_mod.DiffError;
/// go-git `DiffTree` (Zig name: `diffTree`).
pub const DiffTree = difftree_mod.diffTree;
pub const diffTree = difftree_mod.diffTree;
pub const diffTreeWithOptions = difftree_mod.diffTreeWithOptions;
pub const detectRenames = rename_mod.detectRenames;

pub const Patch = patch_mod.Patch;
pub const FilePatch = patch_mod.FilePatch;
pub const FileStats = patch_mod.FileStats;
pub const FileStat = patch_mod.FileStat;
pub const Operation = patch_mod.Operation;
pub const getPatch = patch_mod.getPatch;
pub const getPatchFromChanges = patch_mod.getPatchFromChanges;
pub const changePatch = patch_mod.changePatch;

pub const FileIter = tree_mod.FileIter;

test {
    _ = error_mod;
    _ = signature_mod;
    _ = blob_mod;
    _ = file_mod;
    _ = tree_mod;
    _ = commit_mod;
    _ = tag_mod;
    _ = object_mod;
    _ = walker_mod;
    _ = merge_base_mod;
    _ = change_mod;
    _ = difftree_mod;
    _ = rename_mod;
    _ = similarity_mod;
    _ = patch_mod;
    _ = openpgp_mod;
}
