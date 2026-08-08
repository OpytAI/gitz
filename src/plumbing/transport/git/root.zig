//! Package git — git:// TCP transport (go-git `plumbing/transport/git`).
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `DefaultClient` | `defaultClient` / `newClient` |
//! | `DefaultPort` | `DefaultPort` |
//! | `runner` / `command` | `Runner` / `GitCommand` |
//! | `net.Dial` | `DialFn` / `defaultDial` / `BufferConn` (tests) |
//!
//! # Design notes
//!
//! - Auth is always rejected (`transport.Error.InvalidAuthMethod`); git:// has no auth.
//! - `Command` connects at create time (go-git), then `Start` encodes
//!   `packp.GitProtoRequest` with command + pathname + host, then flushes.
//! - Stdin close is a no-op (go-git `WriteNopCloser`); only `Close` drops TCP.
//! - No stderr channel (`stderrPipe` errors; session treats as null).
//! - `defaultDial` is complete: IP literal or hostname, bracket strip, owned
//!   `TcpConnState` freed on `Conn.close`.
//! - Inject `BufferConn.dialFn` (or any `DialFn`) so unit tests never dial.
//!
//! # go-git test map
//!
//! | go-git | Zig |
//! |--------|-----|
//! | DefaultPort | `DefaultPort is 9418` / `connectPort *` |
//! | auth not allowed | `Command rejects auth` |
//! | Start host/path/cmd | `Command Start encodes GitProtoRequest *` |
//! | upload/receive pack suites | hermetic BufferConn session (canned stream) |
//! | UploadPackSuite / ReceivePackSuite | in-process `LoaderDial` e2e + live `git daemon` e2e |
//!
//! # E2e coverage
//!
//! - **Hermetic in-process** (`e2e_test.zig`): `LoaderDial` implements `DialFn`
//!   with duplex buffers. On `GitProtoRequest`, serves real advertise/pack from
//!   `server.Server` + `MapLoader` (fixture memory repos). Always runs in CI.
//! - **Live git-daemon**: spawns host `git daemon` on 127.0.0.1, client uses
//!   `defaultDial`. Asserts success when `git` is on PATH (required on CI host;
//!   hard failure, not an optional residual skip).

const common_mod = @import("common.zig");

pub const DefaultPort = common_mod.DefaultPort;
pub const Conn = common_mod.Conn;
pub const DialFn = common_mod.DialFn;
pub const BufferConn = common_mod.BufferConn;
pub const defaultDial = common_mod.defaultDial;
pub const bareHost = common_mod.bareHost;
pub const Runner = common_mod.Runner;
pub const defaultClient = common_mod.defaultClient;
pub const newClient = common_mod.newClient;
pub const GitCommand = common_mod.GitCommand;
pub const connectPort = common_mod.connectPort;
pub const joinHostPort = common_mod.joinHostPort;
pub const requestHost = common_mod.requestHost;

test {
    _ = @import("common.zig");
    _ = @import("common_test.zig");
    // e2e_test.zig is only in //src/plumbing/transport/git:git_test (extra deps).
}
