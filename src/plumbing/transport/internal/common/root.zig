//! Package common — pluggable pack protocol over Command pipes
//! (go-git `plumbing/transport/internal/common`).
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `Commander` / `Command` / `CommandKiller` | `Commander` / `Command` |
//! | `NewClient` | `newClient` |
//! | session upload/receive-pack | `Session` |
//! | `ServeUploadPack` / `ServeReceivePack` | `serveUploadPack` / `serveReceivePack` |
//! | `MockCommand` / `MockCommander` | `mocks.zig` |
//! | `isRepoNotFoundError` | `isRepoNotFoundError` |
//!
//! # Notes
//!
//! - No multi_ack (matches go-git UnsupportedCapabilities + task constraint).
//! - Stderr first-line collection is synchronous (no goroutine).
//! - Timeout on stderr is not wall-clock enforced; empty stderr returns immediately.
//!
//! # go-git test map
//!
//! | go-git | Zig |
//! |--------|-----|
//! | TestIsRepoNotFoundError* | `isRepoNotFoundError *` |
//! | TestCheckNotFoundError | `ensureFirstErrLine empty stderr` |
//! | TestAdvertisedReferencesWithRemoteError | `AdvertisedReferences * stderr` |

const common_mod = @import("common.zig");
const server_mod = @import("server.zig");
const mocks_mod = @import("mocks.zig");

pub const Error = common_mod.Error;
pub const Commander = common_mod.Commander;
pub const Command = common_mod.Command;
pub const WriteCloser = common_mod.WriteCloser;
pub const Client = common_mod.Client;
pub const newClient = common_mod.newClient;
pub const Session = common_mod.Session;
pub const decodeUploadPackResponse = common_mod.decodeUploadPackResponse;
pub const isRepoNotFoundError = common_mod.isRepoNotFoundError;
pub const stdErrSkipLine = common_mod.stdErrSkipLine;

pub const ServerCommand = server_mod.ServerCommand;
pub const serveUploadPack = server_mod.serveUploadPack;
pub const serveReceivePack = server_mod.serveReceivePack;

pub const MockCommand = mocks_mod.MockCommand;
pub const MockCommander = mocks_mod.MockCommander;

test {
    _ = @import("common.zig");
    _ = @import("server.zig");
    _ = @import("mocks.zig");
    _ = @import("common_test.zig");
}
