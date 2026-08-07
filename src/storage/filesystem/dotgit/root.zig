//! Package `dotgit` — go-git `storage/filesystem/dotgit` port.
//!
//! DotGit layout helpers over `//src/fs` (`Mem` and `Os`). The layout type is
//! monomorphised: `DotGitFor(Fs)`. Default `DotGit` / `DotGitMem` is `Mem`.

const std = @import("std");
const fs_mod = @import("fs");
const plumbing = @import("plumbing");
const sync = @import("utils/sync");

const error_mod = @import("error.zig");
const writers_mod = @import("writers.zig");
const reader_mod = @import("reader.zig");
const repo_fs_mod = @import("repository_filesystem.zig");
const dotgit_mod = @import("dotgit.zig");

pub const Error = error_mod.Error;

/// Generic factory: `DotGitFor(fs.Mem)` / `DotGitFor(fs.Os)`.
pub const DotGitFor = dotgit_mod.DotGit;
/// Generic object writer: `ObjectWriterFor(fs.Mem)` / `ObjectWriterFor(fs.Os)`.
pub const ObjectWriterFor = writers_mod.ObjectWriter;
/// Generic pack writer: `PackWriterFor(fs.Mem)` / `PackWriterFor(fs.Os)`.
pub const PackWriterFor = writers_mod.PackWriter;

/// Default DotGit over in-memory filesystem (existing call sites).
pub const DotGitMem = DotGitFor(fs_mod.Mem);
/// DotGit over real OS filesystem via `std.Io`.
pub const DotGitOs = DotGitFor(fs_mod.Os);
/// Default export — Mem specialisation (backward compatible).
pub const DotGit = DotGitMem;
/// Default Options (Mem specialisation; go-git `dotgit.Options`).
pub const Options = DotGitMem.Options;

/// Default ObjectWriter over Mem.
pub const ObjectWriter = ObjectWriterFor(fs_mod.Mem);
/// ObjectWriter over Os.
pub const ObjectWriterOs = ObjectWriterFor(fs_mod.Os);

/// Default PackWriter over Mem.
pub const PackWriter = PackWriterFor(fs_mod.Mem);
/// PackWriter over Os.
pub const PackWriterOs = PackWriterFor(fs_mod.Os);

pub const EncodedObject = reader_mod.EncodedObject;
pub const EncodedObjectOs = reader_mod.EncodedObjectOs;
pub const EncodedObjectReader = reader_mod.EncodedObjectReader;
pub const EncodedObjectFor = reader_mod.EncodedObjectFor;
pub const newEncodedObject = reader_mod.newEncodedObject;
pub const newEncodedObjectOs = reader_mod.newEncodedObjectOs;
pub const newEncodedObjectFor = reader_mod.newEncodedObjectFor;

pub const freeRef = dotgit_mod.freeRef;
pub const freeRefs = dotgit_mod.freeRefs;
pub const freeHashes = dotgit_mod.freeHashes;
/// Free slice from `DotGit.alternates` (Mem specialisation).
pub const freeAlternates = DotGitMem.freeAlternates;
/// Free slice from `DotGitOs.alternates`.
pub const freeAlternatesOs = DotGitOs.freeAlternates;
pub const readFileAll = dotgit_mod.readFileAll;

pub const RepositoryFilesystemFor = repo_fs_mod.RepositoryFilesystemFor;
pub const RepositoryFilesystemMem = repo_fs_mod.RepositoryFilesystemMem;
pub const RepositoryFilesystemOs = repo_fs_mod.RepositoryFilesystemOs;
/// Default RepositoryFilesystem — Mem specialisation.
pub const RepositoryFilesystem = repo_fs_mod.RepositoryFilesystem;
pub const newRepositoryFilesystem = repo_fs_mod.RepositoryFilesystem.newRepositoryFilesystem;

// Error set members match go-git names: NotFound, IdxNotFound, PackfileNotFound,
// ConfigNotFound, PackedRefsDuplicatedRef, PackedRefsBadFormat, EmptyRefFile,
// ReferenceNameEscape, ModuleNameEscape, IsDir, ReferenceHasChanged.

test {
    _ = error_mod;
    _ = writers_mod;
    _ = reader_mod;
    _ = repo_fs_mod;
    _ = dotgit_mod;
}
