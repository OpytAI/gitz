//! Package file — local path / `file://` Git transport
//! (go-git `plumbing/transport/file`).
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `DefaultClient` | `defaultClient` |
//! | `NewClient` | `newClient` |
//! | `runner` / `Command` | `Runner` / `LocalCommand` + `HostCommand` |
//! | `LookPath` (via execabs) | `lookPath` |
//! | `prefixExecPath` | (internal, via `resolveBinary`) |
//! | `ServeUploadPack` / `ServeReceivePack` | `serveUploadPack` / `serveReceivePack` |
//! | `adjustPathForWindows` | `adjustPathForWindows` |
//!
//! # Dual path
//!
//! 1. **Hermetic** — `FileClient.setLoader` → `LocalCommand` (in-process server).
//! 2. **Host spawn** — no loader + `use_host_spawn` (default) → `lookPath` /
//!    `prefixExecPath` + `HostCommand` (`std.process.spawn`, argv `bin path`).
//! 3. **Unit dry** — no loader + `setUseHostSpawn(false)` → `LocalCommand`
//!    without serve (Commander wiring only).
//!
//! Loader wins while set. Host spawn is the go-git default.
//!
//! # go-git test map
//!
//! | go-git | Zig |
//! |--------|-----|
//! | DefaultClient non-nil | `DefaultClient non-null` |
//! | NewClient | `NewClient builds FileClient` |
//! | TestCommand valid/invalid | `runner Command *` |
//! | TestNonExistentCommand | `runner absolute missing bin CommandNotFound` |
//! | auth ignored | `runner Command ignores auth` |
//! | empty path | `runner invalid empty location` |

const client_mod = @import("client.zig");
const server_mod = @import("server.zig");

pub const Error = client_mod.Error;
pub const LocalCommand = client_mod.LocalCommand;
pub const HostCommand = client_mod.HostCommand;
pub const OwnedCmd = client_mod.OwnedCmd;
pub const Runner = client_mod.Runner;
pub const FileClient = client_mod.FileClient;
pub const lookPath = client_mod.lookPath;
pub const default_path = client_mod.default_path;
pub const newClient = client_mod.newClient;
/// go-git `NewClient` PascalCase alias (inventory / call-site parity).
pub const NewClient = client_mod.newClient;
pub const defaultClient = client_mod.defaultClient;
/// go-git package-level `DefaultClient` (factory; Zig needs an allocator).
pub const DefaultClient = client_mod.defaultClient;
pub const adjustPathForWindows = client_mod.adjustPathForWindows;

pub const serveUploadPack = server_mod.serveUploadPack;
pub const serveReceivePack = server_mod.serveReceivePack;
pub const serveUploadPackWithLoader = server_mod.serveUploadPackWithLoader;
pub const serveReceivePackWithLoader = server_mod.serveReceivePackWithLoader;

test {
    _ = @import("client.zig");
    _ = @import("server.zig");
    _ = @import("client_test.zig");
}
