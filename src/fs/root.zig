//! Abstract filesystem (go-billy v5.9.0 subset) for gitz storage.
//!
//! go-git uses `github.com/go-git/go-billy/v5`. This package provides a pure-Zig
//! equivalent: concrete `Mem` and `Os` backends with matching method sets
//! (duck-typed `anytype` at call sites — no vtable interface).
//!
//! | Backend | Role |
//! |---------|------|
//! | `Mem` | Hermetic in-memory FS for tests and pure storage logic |
//! | `Os` | Host FS via Zig 0.16 `std.Io` (`Dir` / `File` / `Threaded`) |
//!
//! # Method sets (billy)
//!
//! **Basic:** create, open, openFile, stat, rename, remove, joinPath
//! **Dir:** readDir, mkdirAll
//! **TempFile:** tempFile
//! **Symlink:** lstat, symlink, readlink
//! **Chroot:** chroot, root
//! **Durability:** file sync, directory sync, full-tree sync
//! **File:** fileName, read, readAt, write, seek, close, truncate, lock, unlock, sync
//!
//! Logical path separator is always `/`. `Os` resolves relative to an open root
//! directory handle; platform separators appear only inside `std.Io` calls.
//!
//! # Design notes
//!
//! - No interface type: storage is monomorphised over `Fs` (`ObjectStorageFor`,
//!   `DotGitFor`, …). Method sets must stay aligned between `Mem` and `Os`.
//! - `FileInfo.name` is owned only for `readDir` results (`freeReadDir`);
//!   `stat`/`lstat` always leave `name` empty (no dangling path views).
//! - Open-file names use a free-list of slots so long-lived FS instances do not
//!   grow `open_names` unboundedly across open/close cycles.

const error_mod = @import("error.zig");
const fileinfo_mod = @import("fileinfo.zig");
const path_mod = @import("path.zig");
const mem_mod = @import("mem.zig");
const os_mod = @import("os.zig");

pub const Error = error_mod.Error;

pub const FileInfo = fileinfo_mod.FileInfo;
pub const path = path_mod;

/// Open flags (subset of POSIX / Go os flags).
pub const O = struct {
    pub const RDONLY: u32 = 0;
    pub const WRONLY: u32 = 1;
    pub const RDWR: u32 = 2;
    pub const CREATE: u32 = 0x40;
    pub const EXCL: u32 = 0x80;
    pub const TRUNC: u32 = 0x200;
    pub const APPEND: u32 = 0x400;
};

/// File mode bits (Unix-style).
pub const Mode = struct {
    pub const file: u32 = 0o666;
    pub const dir: u32 = 0o755;
    pub const dir_flag: u32 = 0o040000;
    pub const symlink_flag: u32 = 0o120000;
};

/// go-billy `Capability` bit flags.
pub const Capability = u64;
pub const WriteCapability: Capability = 1 << 0;
pub const ReadCapability: Capability = 1 << 1;
pub const ReadAndWriteCapability: Capability = 1 << 2;
pub const SeekCapability: Capability = 1 << 3;
pub const TruncateCapability: Capability = 1 << 4;
pub const LockCapability: Capability = 1 << 5;
pub const DefaultCapabilities: Capability = WriteCapability | ReadCapability |
    ReadAndWriteCapability | SeekCapability | TruncateCapability | LockCapability;
pub const AllCapabilities = DefaultCapabilities;

/// go-billy `CapabilityCheck`; concrete gitz backends expose `capabilities`.
pub fn capabilityCheck(backend: anytype, wanted: Capability) bool {
    const have = backend.capabilities();
    return have & wanted == wanted;
}

pub const Mem = mem_mod.Mem;
pub const MemFile = mem_mod.MemFile;
pub const Os = os_mod.Os;
pub const OsFile = os_mod.OsFile;

test "capabilityCheck requires every requested bit" {
    const Fake = struct {
        fn capabilities(_: *@This()) Capability {
            return ReadCapability | SeekCapability;
        }
    };
    var fake = Fake{};
    try @import("std").testing.expect(capabilityCheck(&fake, ReadCapability));
    try @import("std").testing.expect(capabilityCheck(&fake, ReadCapability | SeekCapability));
    try @import("std").testing.expect(!capabilityCheck(&fake, WriteCapability));
}

test {
    _ = @import("error.zig");
    _ = @import("fileinfo.zig");
    _ = @import("path.zig");
    _ = @import("mem.zig");
    _ = @import("os.zig");
}
