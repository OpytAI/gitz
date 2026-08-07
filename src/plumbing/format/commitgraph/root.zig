//! plumbing/format/commitgraph — Git commit-graph file format (go-git v2 API).
//!
//! Port of go-git v5.19.2 `plumbing/format/commitgraph/v2` folded into a single
//! package. Deprecated v1 types from the package root are not exported.
//!
//! # Surface
//!
//! | go-git v2 | Zig |
//! |-----------|-----|
//! | `CommitData` | `CommitData` |
//! | `Index` | `MemoryIndex` / `FileIndex` methods |
//! | `MemoryIndex` | `MemoryIndex` |
//! | `OpenFileIndex` | `FileIndex.open` / `FileIndex.openReader` |
//! | `Encoder` / `NewEncoder` | `Encoder` / `Encoder.init` |
//! | `ChunkType` | `ChunkType` |

const error_mod = @import("error.zig");
const commitgraph_mod = @import("commitgraph.zig");
const chunk_mod = @import("chunk.zig");
const memory_mod = @import("memory.zig");
const file_mod = @import("file.zig");
const encoder_mod = @import("encoder.zig");

// --- Errors ---
pub const Error = error_mod.Error;

// --- Constants / CommitData ---
pub const commit_file_signature = commitgraph_mod.commit_file_signature;
pub const parent_none = commitgraph_mod.parent_none;
pub const parent_octopus_used = commitgraph_mod.parent_octopus_used;
pub const parent_octopus_mask = commitgraph_mod.parent_octopus_mask;
pub const parent_last = commitgraph_mod.parent_last;
pub const sz_uint32 = commitgraph_mod.sz_uint32;
pub const sz_uint64 = commitgraph_mod.sz_uint64;
pub const sz_signature = commitgraph_mod.sz_signature;
pub const sz_header = commitgraph_mod.sz_header;
pub const sz_commit_data = commitgraph_mod.sz_commit_data;
pub const len_fanout = commitgraph_mod.len_fanout;
pub const hash_size = commitgraph_mod.hash_size;

pub const CommitData = commitgraph_mod.CommitData;

// --- Chunks ---
pub const ChunkType = chunk_mod.ChunkType;
pub const chunk_signatures = chunk_mod.chunk_signatures;
pub const sz_chunk_sig = chunk_mod.sz_chunk_sig;

// --- Index implementations ---
pub const MemoryIndex = memory_mod.MemoryIndex;
pub const FileIndex = file_mod.FileIndex;

// --- Encoder ---
pub const Encoder = encoder_mod.Encoder;

test {
    _ = @import("error.zig");
    _ = @import("chunk.zig");
    _ = @import("commitgraph.zig");
    _ = @import("memory.zig");
    _ = @import("file.zig");
    _ = @import("encoder.zig");
}
