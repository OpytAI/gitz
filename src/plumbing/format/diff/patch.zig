//! Patch / FilePatch / File / Chunk types — port of go-git `plumbing/format/diff/patch.go`.
//!
//! go-git exposes these as interfaces. This port uses concrete structs that carry
//! the data UnifiedEncoder needs. Callers may fill them from object-layer diffs.

const plumbing = @import("plumbing");
const filemode = @import("filemode");

/// Operation defines the operation of a diff item (go-git `Operation`).
pub const Operation = enum(u8) {
    /// Equal item represents an equals diff.
    equal = 0,
    /// Add item represents an insert diff.
    add = 1,
    /// Delete item represents a delete diff.
    delete = 2,
};

/// File contains all the file metadata necessary to print some patch formats
/// (go-git `File` interface).
pub const File = struct {
    hash: plumbing.Hash = plumbing.ZeroHash,
    mode: filemode.FileMode = filemode.Empty,
    /// Complete path to the file, including the filename (not owned).
    path: []const u8 = "",

    pub fn getHash(self: File) plumbing.Hash {
        return self.hash;
    }

    pub fn getMode(self: File) filemode.FileMode {
        return self.mode;
    }

    pub fn getPath(self: File) []const u8 {
        return self.path;
    }
};

/// Chunk represents a portion of a file transformation into another
/// (go-git `Chunk` interface).
pub const Chunk = struct {
    /// Portion of the file content for this operation.
    content: []const u8 = "",
    /// Operation to apply with this chunk.
    op: Operation = .equal,

    pub fn getContent(self: Chunk) []const u8 {
        return self.content;
    }

    pub fn getType(self: Chunk) Operation {
        return self.op;
    }
};

/// FilePatch represents the necessary steps to transform one file into another
/// (go-git `FilePatch` interface).
pub const FilePatch = struct {
    /// From side; null when the patch creates a new file.
    from: ?File = null,
    /// To side; null when the patch deletes a file.
    to: ?File = null,
    /// Ordered changes; empty for binary (and mode-only) patches.
    chunks: []const Chunk = &.{},
    /// True when this patch represents a binary file.
    is_binary: bool = false,

    pub fn isBinary(self: FilePatch) bool {
        return self.is_binary;
    }

    pub fn files(self: FilePatch) struct { ?File, ?File } {
        return .{ self.from, self.to };
    }

    pub fn getChunks(self: FilePatch) []const Chunk {
        return self.chunks;
    }
};

/// Patch represents a collection of steps to transform several files
/// (go-git `Patch` interface).
pub const Patch = struct {
    /// Optional message at the top of the patch representation.
    message: []const u8 = "",
    /// Per-file patches.
    file_patches: []const FilePatch = &.{},

    pub fn filePatches(self: Patch) []const FilePatch {
        return self.file_patches;
    }

    pub fn getMessage(self: Patch) []const u8 {
        return self.message;
    }
};
