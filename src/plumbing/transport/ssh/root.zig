//! Package ssh — SSH transport auth + client surface
//! (go-git `plumbing/transport/ssh`, pin v5.19.2).
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `Password` / `PasswordCallback` | `auth_method.zig` |
//! | `KeyboardInteractive` | `KeyboardInteractive` + `ChallengeFn` |
//! | `PublicKeys` / `NewPublicKeys` / `NewPublicKeysFromFile` | same |
//! | `PublicKeysCallback` / `NewSSHAgentAuth` | agent wire protocol (`agent.zig`) |
//! | `HostKeyCallbackHelper` / known_hosts | `known_hosts.zig` |
//! | `DefaultClient` / `NewClient` | `defaultClient` / `newClient` (native dial) |
//! | `DefaultPort` | `DefaultPort` (22) |
//! | `runner` | `Runner` + `CommandPlan` / dial modes |
//! | `endpointToCommand` / `writeShellQuote` | same |
//!
//! # Module layout
//!
//! | File | Role |
//! |------|------|
//! | `auth_method.zig` | Auth methods + `ClientConfig` + PEM helpers |
//! | `agent.zig` | OpenSSH agent wire protocol (list / sign) |
//! | `known_hosts.zig` | known_hosts path discovery + pure-Zig match |
//! | `ssh_wire.zig` | Binary packet framing, AES-CTR, name-lists |
//! | `native_ssh.zig` | Pure-Zig SSH client (KEX, userauth, channel) |
//! | `common.zig` | Plan, dial modes, `Runner`, client |
//!
//! # Design
//!
//! Pure Zig — no C crypto libraries and no libssh. Production `newClient`
//! uses the **native** in-process SSH dial path (`DialMode.native`):
//! curve25519-sha256 KEX, ssh-ed25519 host keys, password and OpenSSH
//! ed25519 publickey userauth, session channel + exec for pack protocol.
//!
//! **System `ssh`** (`DialMode.system_ssh` / `newClientSystemSsh`) remains an
//! alternate path. Unit tests use `use_system_ssh=false` → `plan_only`.
//!
//! # Dial modes
//!
//! | Mode | API | Behavior |
//! |------|-----|----------|
//! | `native` | `newClient` default | Pure-Zig SSH client |
//! | `system_ssh` | `newClientSystemSsh` / `dial_mode` | Spawn host `ssh` |
//! | `plan_only` | `use_system_ssh=false` | In-memory plan (tests) |
//!
//! # Implemented
//!
//! - **Native dial**: TCP + version exchange + binary packets + KEX
//!   (`curve25519-sha256`) + host-key verify (`ssh-ed25519`) + NEWKEYS +
//!   password / publickey (ed25519) userauth + session exec. Channel stdio
//!   bridges to pack-protocol pipes.
//! - **System-ssh dial**: `HostCommand` spawns `ssh` with port, user, optional
//!   `-i`, optional insecure host-key options. Missing binary → `SshBinaryNotFound`.
//! - **SSH agent**: OpenSSH wire protocol over `SSH_AUTH_SOCK` (list + sign).
//! - **PEM keys**: structure parse, OpenSSH type detection, identity path and
//!   mode-`0o600` temp file for system-`ssh -i`; native path loads openssh-key-v1
//!   ed25519 for publickey auth.
//! - **known_hosts**: path discovery + host/algo/blob matching, including
//!   hashed host entries (`|1|salt|mac`) via HMAC-SHA1 (OpenSSH format).
//!
//! Platform limit: process spawn is unavailable on WASI / freestanding
//! (`SpawnUnsupported`) for the system-ssh path only.
//!
//! # go-git test map
//!
//! | go-git | Zig |
//! |--------|-----|
//! | TestPasswordName/String | `Password name and string` |
//! | TestKeyboardInteractive* | `KeyboardInteractive name and string` |
//! | TestPublicKeys* | `PublicKeys name and string` / `NewPublicKeys *` |
//! | TestNewSSHAgentAuthNoAgent | `NewSSHAgentAuth no agent` |
//! | TestEndpointToCommand | `endpointToCommand *` |
//! | TestDefaultSSHConfig* | `getHostWithPort *` |
//! | TestInvalidAuthMethod | `runner rejects non-ssh auth` |

const auth_mod = @import("auth_method.zig");
const common_mod = @import("common.zig");
const agent_mod = @import("agent.zig");
const known_hosts_mod = @import("known_hosts.zig");
const native_ssh_mod = @import("native_ssh.zig");
const ssh_wire_mod = @import("ssh_wire.zig");

// --- auth_method.zig ---
pub const DefaultUsername = auth_mod.DefaultUsername;
pub const KeyboardInteractiveName = auth_mod.KeyboardInteractiveName;
pub const PasswordName = auth_mod.PasswordName;
pub const PasswordCallbackName = auth_mod.PasswordCallbackName;
pub const PublicKeysName = auth_mod.PublicKeysName;
pub const PublicKeysCallbackName = auth_mod.PublicKeysCallbackName;

pub const Error = auth_mod.Error;
pub const HostKeyCheckError = auth_mod.HostKeyCheckError;
pub const HostKeyCallback = auth_mod.HostKeyCallback;
pub const HostKeyCallbackHelper = auth_mod.HostKeyCallbackHelper;
pub const AuthKind = auth_mod.AuthKind;
pub const ClientConfig = auth_mod.ClientConfig;
pub const PasswordCallbackFn = auth_mod.PasswordCallbackFn;
pub const ChallengeFn = auth_mod.ChallengeFn;
pub const SignersCallbackFn = auth_mod.SignersCallbackFn;
pub const AuthMethod = auth_mod.AuthMethod;
pub const Password = auth_mod.Password;
pub const PasswordCallback = auth_mod.PasswordCallback;
pub const KeyboardInteractive = auth_mod.KeyboardInteractive;
pub const PemInfo = auth_mod.PemInfo;
pub const parsePemPrivateKeyStructure = auth_mod.parsePemPrivateKeyStructure;
pub const detectKeyType = auth_mod.detectKeyType;
pub const detectOpensshPublicKeyType = auth_mod.detectOpensshPublicKeyType;
pub const PublicKeys = auth_mod.PublicKeys;
pub const newPublicKeys = auth_mod.newPublicKeys;
pub const newPublicKeysFromFile = auth_mod.newPublicKeysFromFile;
pub const newPublicKeysFromBytes = auth_mod.newPublicKeysFromBytes;
pub const PublicKeysCallback = auth_mod.PublicKeysCallback;
pub const usernameFromEnviron = auth_mod.usernameFromEnviron;
pub const newSSHAgentAuth = auth_mod.newSSHAgentAuth;
pub const AgentAuthContext = auth_mod.AgentAuthContext;
pub const AgentIdentity = auth_mod.AgentIdentity;
pub const freeAgentIdentities = auth_mod.freeAgentIdentities;

// --- known_hosts.zig ---
pub const defaultKnownHostsFiles = known_hosts_mod.defaultKnownHostsFiles;
pub const freeKnownHostsFiles = known_hosts_mod.freeKnownHostsFiles;
pub const filterKnownHostsFiles = known_hosts_mod.filterKnownHostsFiles;
pub const newKnownHostsCallback = known_hosts_mod.newKnownHostsCallback;
pub const newKnownHostsCallbackOwned = known_hosts_mod.newKnownHostsCallbackOwned;
pub const freeKnownHostsDb = known_hosts_mod.freeKnownHostsDb;
pub const KnownHostEntry = known_hosts_mod.KnownHostEntry;
pub const KnownHostsDb = known_hosts_mod.KnownHostsDb;
pub const freeKnownHostEntries = known_hosts_mod.freeKnownHostEntries;
pub const parseKnownHostsLine = known_hosts_mod.parseKnownHostsLine;
pub const parseKnownHostsFile = known_hosts_mod.parseKnownHostsFile;
pub const hostFieldMatches = known_hosts_mod.hostFieldMatches;
pub const entryHostMatches = known_hosts_mod.entryHostMatches;
pub const checkKnownHosts = known_hosts_mod.checkKnownHosts;
pub const loadKnownHostsDb = known_hosts_mod.loadKnownHostsDb;

// --- agent.zig ---
pub const AgentClient = agent_mod.AgentClient;
pub const parseIdentitiesAnswer = agent_mod.parseIdentitiesAnswer;
pub const parseSignResponse = agent_mod.parseSignResponse;
pub const buildRequest = agent_mod.buildRequest;
pub const buildSignRequestPayload = agent_mod.buildSignRequestPayload;
pub const AgentError = agent_mod.Error;
pub const max_message_len = agent_mod.max_message_len;
pub const max_identities = agent_mod.max_identities;
pub const max_string_len = agent_mod.max_string_len;

// --- native_ssh.zig / ssh_wire.zig ---
pub const DialMode = common_mod.DialMode;
pub const NativeCommand = native_ssh_mod.NativeCommand;
pub const NativeDialParams = native_ssh_mod.NativeDialParams;
pub const NativeConn = native_ssh_mod.NativeConn;
pub const NativeSshError = native_ssh_mod.Error;
pub const loadEd25519PrivateKey = native_ssh_mod.loadEd25519PrivateKey;
pub const client_version = native_ssh_mod.client_version;
pub const WireError = ssh_wire_mod.Error;
pub const encodePacket = ssh_wire_mod.encodePacket;
pub const decodePacket = ssh_wire_mod.decodePacket;
pub const buildKexInit = ssh_wire_mod.buildKexInit;
pub const generateKeyMaterial = ssh_wire_mod.generateKeyMaterial;

// --- common.zig ---
pub const DefaultPort = common_mod.DefaultPort;
pub const ClientOptions = common_mod.ClientOptions;
pub const SshConfig = common_mod.SshConfig;
pub const AuthBuilderFn = common_mod.AuthBuilderFn;
pub const defaultAuthBuilder = common_mod.defaultAuthBuilder;
pub const CommandPlan = common_mod.CommandPlan;
pub const buildSshArgv = common_mod.buildSshArgv;
pub const freeSshArgv = common_mod.freeSshArgv;
pub const lookPath = common_mod.lookPath;
pub const writeShellQuote = common_mod.writeShellQuote;
pub const endpointToCommand = common_mod.endpointToCommand;
pub const joinHostPort = common_mod.joinHostPort;
pub const getHostWithPort = common_mod.getHostWithPort;
pub const effectiveUser = common_mod.effectiveUser;
pub const PlanCommand = common_mod.PlanCommand;
pub const HostCommand = common_mod.HostCommand;
pub const isSshAuthMethod = common_mod.isSshAuthMethod;
pub const Runner = common_mod.Runner;
pub const overrideConfig = common_mod.overrideConfig;
pub const Client = common_mod.Client;
pub const newClient = common_mod.newClient;
pub const newClientSystemSsh = common_mod.newClientSystemSsh;
pub const defaultClient = common_mod.defaultClient;
pub const newClientWithCommander = common_mod.newClientWithCommander;
pub const CommonError = common_mod.Error;

/// Package-level SSH config hook (go-git `DefaultSSHConfig`). Null ignores config.
pub fn getDefaultSshConfig() ?common_mod.SshConfig {
    return common_mod.default_ssh_config;
}

pub fn setDefaultSshConfig(cfg: ?common_mod.SshConfig) void {
    common_mod.default_ssh_config = cfg;
}

/// Package-level default auth builder (go-git `DefaultAuthBuilder`).
pub fn getDefaultAuthBuilder() common_mod.AuthBuilderFn {
    return common_mod.DefaultAuthBuilder;
}

pub fn setDefaultAuthBuilder(fn_ptr: common_mod.AuthBuilderFn) void {
    common_mod.DefaultAuthBuilder = fn_ptr;
}

test {
    _ = @import("auth_method.zig");
    _ = @import("common.zig");
    _ = @import("agent.zig");
    _ = @import("known_hosts.zig");
    _ = @import("ssh_wire.zig");
    _ = @import("native_ssh.zig");
}
