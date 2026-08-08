//! Package remote — go-git root `remote.go` + `options.go` remote types.
//!
//! Import as `@import("remote")`.
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `Remote` / `NewRemote` | `Remote` / `newRemote` / `newRemoteEmbedded` |
//! | `FetchOptions` / `PushOptions` / `ListOptions` | `options.zig` |
//! | `NoErrAlreadyUpToDate` / force-with-lease errors | `error.zig` |
//! | `DefaultRemoteName` | `default_remote_name` |
//! | `newSendPackSession` | `openReceivePack` |

const error_mod = @import("error.zig");
const options_mod = @import("options.zig");
const remote_mod = @import("remote.zig");
const session_mod = @import("session.zig");
const refs_mod = @import("refs.zig");
const list_mod = @import("list.zig");

// --- error.zig ---
pub const Error = error_mod.Error;

// --- options.zig ---
pub const default_remote_name = options_mod.default_remote_name;
pub const default_list_timeout_sec = options_mod.default_list_timeout_sec;
pub const TagMode = options_mod.TagMode;
pub const PeelingOption = options_mod.PeelingOption;
pub const ForceWithLease = options_mod.ForceWithLease;
pub const PushOption = options_mod.PushOption;
pub const FetchOptions = options_mod.FetchOptions;
pub const PushOptions = options_mod.PushOptions;
pub const ListOptions = options_mod.ListOptions;

// --- remote.zig ---
pub const Remote = remote_mod.Remote;
pub const newRemote = remote_mod.newRemote;
pub const newRemoteEmbedded = remote_mod.newRemoteEmbedded;
pub const freeReferences = remote_mod.freeReferences;

// --- session.zig ---
pub const SessionOpts = session_mod.SessionOpts;
pub const SessionUpload = session_mod.SessionUpload;
pub const SessionReceive = session_mod.SessionReceive;
pub const transportFromServer = session_mod.transportFromServer;
pub const openUploadPack = session_mod.openUploadPack;
pub const openReceivePack = session_mod.openReceivePack;

// --- refs.zig ---
pub const calculateRefs = refs_mod.calculateRefs;
pub const CalculateRefsResult = refs_mod.CalculateRefsResult;
pub const getWants = refs_mod.getWants;
pub const getHaves = refs_mod.getHaves;
pub const objectExists = refs_mod.objectExists;
pub const collectLocalRefs = refs_mod.collectLocalRefs;
pub const isFastForward = refs_mod.isFastForward;

// Unit tests (including MapLoader e2e) are pulled in by `test_root.zig`
// (//src/remote:remote_test). Keep this production root free of test-only imports
// so dependents (//src/repo) do not require tests.zig / transport fixtures.
test {
    _ = @import("error.zig");
    _ = @import("options.zig");
    _ = @import("session.zig");
    _ = @import("refs.zig");
    _ = @import("list.zig");
    _ = @import("fetch.zig");
    _ = @import("push.zig");
    _ = @import("remote.zig");
}
