//! Package server — in-process git server protocol (go-git `plumbing/transport/server`).
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `Loader` / `MapLoader` / `FilesystemLoader` | `loader.zig` |
//! | `NewServer` / `NewClient` | `newServer` / `newClient` |
//! | upload-pack / receive-pack sessions | `UploadPackSession` / `ReceivePackSession` |
//!
//! # Design notes
//!
//! - Storers are type-erased via `RepoStorer` (memory + filesystem backends).
//! - `RepoStorer.reference` always returns **caller-owned** name/target strings;
//!   free with `freeReference` (erases memory-borrowed vs FS-owned backends).
//! - `FilesystemLoader` chroots into `.git` for non-bare endpoints so DotGit
//!   sees `config`/`objects`/`refs` at the FS root (go-git leaves the worktree).
//! - Advertise peels annotated tags under `refs/tags/*` (go-git still TODOs this).
//! - Upload-pack encodes the pack into an allocated buffer (no goroutine pipe).
//! - Receive-pack unpacks via `packfile.updateObjectStorage` then copies objects
//!   into the session storer and applies ref create/update/delete.
//! - `as_client` (NewClient) returns `EmptyRemoteRepository` when advertise is empty.
//! - Cross-package serve e2e lives in `//src/plumbing/transport/test` (not here).
//!
//! # go-git test map
//!
//! | go-git | Zig |
//! |--------|-----|
//! | MapLoader load | `MapLoader load and miss` |
//! | FilesystemLoader bare/non-bare | `FilesystemLoaderMem *` |
//! | Advertise refs + caps + peel | `advertise refs *` / `advertise peels *` |
//! | asClient empty repo | `asClient empty repo` |
//! | UploadPack encode | `upload-pack roundtrip pack objects` |
//! | ReceivePack ref update | `receive-pack create update delete refs` |

const loader_mod = @import("loader.zig");
const server_mod = @import("server.zig");

pub const RepoStorer = loader_mod.RepoStorer;
pub const Loader = loader_mod.Loader;
pub const MapLoader = loader_mod.MapLoader;
pub const FilesystemLoader = loader_mod.FilesystemLoader;
pub const FilesystemLoaderMem = loader_mod.FilesystemLoaderMem;
pub const FilesystemLoaderOs = loader_mod.FilesystemLoaderOs;
pub const newFilesystemLoaderOs = loader_mod.newFilesystemLoaderOs;
pub const newFilesystemLoaderMem = loader_mod.newFilesystemLoaderMem;
pub const newDefaultLoader = loader_mod.newDefaultLoader;
pub const endpointKey = loader_mod.endpointKey;

pub const Server = server_mod.Server;
pub const newServer = server_mod.newServer;
pub const newClient = server_mod.newClient;
pub const UploadPackSession = server_mod.UploadPackSession;
pub const ReceivePackSession = server_mod.ReceivePackSession;
pub const ReceivePackOutcome = server_mod.ReceivePackOutcome;
pub const Error = server_mod.Error;

// Unit tests for this package are pulled in by `server_test_root.zig`
// (//server:server_test). Keep the production root free of test-only imports
// so dependents do not require `server_test.zig` / fixtures.
test {
    _ = @import("loader.zig");
    _ = @import("server.zig");
}
