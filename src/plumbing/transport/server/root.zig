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
//! - Upload-pack encodes the pack into an allocated buffer (no goroutine pipe).
//! - Receive-pack unpacks via `packfile.updateObjectStorage` then copies objects
//!   into the session storer and applies ref create/update/delete.
//! - `as_client` (NewClient) returns `EmptyRemoteRepository` when advertise is empty.
//!
//! # go-git test map
//!
//! | go-git | Zig |
//! |--------|-----|
//! | MapLoader load | `MapLoader load and miss` |
//! | Advertise refs + caps | `advertise refs on memory storage` |
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

test {
    _ = @import("loader.zig");
    _ = @import("server.zig");
    _ = @import("server_test.zig");
}
