//! SSH authentication methods (go-git `plumbing/transport/ssh/auth_method.go`).
//!
//! Pure Zig: no C crypto and no `golang.org/x/crypto/ssh`. Auth types store
//! credentials and expose `clientConfig` as a logical config for the runner.
//!
//! # Separation
//!
//! | Concern | Module |
//! |---------|--------|
//! | Auth methods + `ClientConfig` | this file |
//! | Agent wire protocol | `agent.zig` |
//! | known_hosts match | `known_hosts.zig` |
//! | Dial / `Commander` runner | `common.zig` |
//!
//! # Implemented
//!
//! - **Password / PasswordCallback / KeyboardInteractive**: full config surface
//!   (`password`, callbacks) for the runner and future in-process dialers.
//! - **PEM private keys**: structure parse, encryption detection, OpenSSH key-type
//!   detection, `identity_file` for system-`ssh -i`, and `writeIdentityTempFile`
//!   (mode `0o600`) when only PEM bytes are available.
//! - **SSH agent**: `newSSHAgentAuth` + `SignersCallbackFn` listing identities via
//!   `agent.zig` (not a stub).

const std = @import("std");
const transport = @import("transport");
const agent_mod = @import("agent.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;

// ---------------------------------------------------------------------------
// Constants (go-git)
// ---------------------------------------------------------------------------

/// go-git `DefaultUsername`.
pub const DefaultUsername: []const u8 = "git";

/// go-git auth method name constants.
pub const KeyboardInteractiveName: []const u8 = "ssh-keyboard-interactive";
pub const PasswordName: []const u8 = "ssh-password";
pub const PasswordCallbackName: []const u8 = "ssh-password-callback";
pub const PublicKeysName: []const u8 = "ssh-public-keys";
pub const PublicKeysCallbackName: []const u8 = "ssh-public-key-callback";

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const Error = error{
    /// PEM bytes are not a recognized private-key PEM block.
    InvalidPem,
    /// Encrypted PEM requires a non-empty password (go-git PassphraseMissingError path).
    PassphraseMissing,
    /// SSH agent unavailable (no `SSH_AUTH_SOCK` or empty).
    SSHAgentUnavailable,
    /// Username could not be determined for agent auth.
    UsernameUnavailable,
    /// Known-hosts file list empty / none exist.
    KnownHostsNotFound,
};

// ---------------------------------------------------------------------------
// Host key callback surface
// ---------------------------------------------------------------------------

/// Result of a host-key check (go-git `ssh.HostKeyCallback` returns error or nil).
pub const HostKeyCheckError = error{
    HostKeyMismatch,
    HostKeyUnknown,
    HostKeyCallbackFailed,
};

/// go-git `ssh.HostKeyCallback` as a vtable.
pub const HostKeyCallback = struct {
    ptr: *anyopaque,
    check_fn: *const fn (
        ptr: *anyopaque,
        hostname: []const u8,
        remote_addr: []const u8,
        key_algo: []const u8,
        key_blob: []const u8,
    ) HostKeyCheckError!void,

    pub fn check(
        self: HostKeyCallback,
        hostname: []const u8,
        remote_addr: []const u8,
        key_algo: []const u8,
        key_blob: []const u8,
    ) HostKeyCheckError!void {
        return self.check_fn(self.ptr, hostname, remote_addr, key_algo, key_blob);
    }

    /// go-git `ssh.InsecureIgnoreHostKey` — always accepts.
    pub fn insecureIgnoreHostKey() HostKeyCallback {
        const gen = struct {
            var dummy: u8 = 0;
            fn checkFn(
                _: *anyopaque,
                _: []const u8,
                _: []const u8,
                _: []const u8,
                _: []const u8,
            ) HostKeyCheckError!void {}
        };
        return .{
            .ptr = @ptrCast(&gen.dummy),
            .check_fn = gen.checkFn,
        };
    }
};

/// go-git `HostKeyCallbackHelper`.
pub const HostKeyCallbackHelper = struct {
    host_key_callback: ?HostKeyCallback = null,
    host_key_algorithms: []const []const u8 = &.{},
    /// Injected fallback when callback is null (tests / known_hosts builder).
    fallback: ?*const fn (files: []const []const u8) Error!HostKeyCallback = null,

    /// go-git `SetHostKeyCallbackAndAlgorithms`.
    pub fn setHostKeyCallbackAndAlgorithms(
        self: *HostKeyCallbackHelper,
        cfg: *ClientConfig,
    ) Error!void {
        if (self.host_key_callback) |cb| {
            cfg.host_key_callback = cb;
            cfg.host_key_algorithms = self.host_key_algorithms;
            return;
        }
        if (self.fallback) |fb| {
            const cb = try fb(&.{});
            cfg.host_key_callback = cb;
            cfg.host_key_algorithms = self.host_key_algorithms;
            return;
        }
        // Leave null; runner/connect fills known_hosts when needed (go-git dial path).
        cfg.host_key_algorithms = self.host_key_algorithms;
    }

    /// go-git `SetHostKeyCallback` (alias).
    pub fn setHostKeyCallback(self: *HostKeyCallbackHelper, cfg: *ClientConfig) Error!void {
        return self.setHostKeyCallbackAndAlgorithms(cfg);
    }
};

// ---------------------------------------------------------------------------
// ClientConfig (logical stand-in for golang.org/x/crypto/ssh.ClientConfig)
// ---------------------------------------------------------------------------

/// Kind of auth material attached to a client config.
pub const AuthKind = enum {
    none,
    password,
    password_callback,
    keyboard_interactive,
    public_keys,
    public_keys_callback,
};

/// Logical SSH client configuration used by the transport runner.
pub const ClientConfig = struct {
    user: []const u8 = "",
    auth_kind: AuthKind = .none,
    /// Password when `auth_kind == .password` (caller-owned slice).
    password: []const u8 = "",
    /// PEM private key bytes when public-keys auth (caller-owned or auth-owned).
    pem_bytes: []const u8 = "",
    /// Passphrase for encrypted PEM (may be empty).
    pem_password: []const u8 = "",
    /// Path for system-`ssh -i` when known (caller-owned or auth-owned).
    identity_file: []const u8 = "",
    /// Detected key algorithm name when known (e.g. `ssh-ed25519`).
    key_type: []const u8 = "",
    /// Agent socket path when public-keys-callback / agent (may be empty).
    agent_sock: []const u8 = "",
    host_key_callback: ?HostKeyCallback = null,
    host_key_algorithms: []const []const u8 = &.{},
    /// Opaque pointer for password / keyboard / signer callbacks.
    callback_ctx: ?*anyopaque = null,
    password_callback: ?PasswordCallbackFn = null,
    challenge_fn: ?ChallengeFn = null,
    signers_callback: ?SignersCallbackFn = null,
};

// ---------------------------------------------------------------------------
// Callback function types
// ---------------------------------------------------------------------------

/// go-git `func() (pass string, err error)`.
pub const PasswordCallbackFn = *const fn (ctx: *anyopaque) anyerror![]const u8;

/// Keyboard-interactive challenge (go-git `ssh.KeyboardInteractiveChallenge` subset).
/// Returns owned response strings (caller of challenge frees with `allocator`).
pub const ChallengeFn = *const fn (
    ctx: *anyopaque,
    allocator: Allocator,
    user: []const u8,
    instruction: []const u8,
    questions: []const []const u8,
    echos: []const bool,
) anyerror![]const []const u8;

/// Public-keys callback (go-git agent signers callback).
/// Returns agent identities (caller frees with `agent_mod.freeIdentities`).
pub const SignersCallbackFn = *const fn (ctx: *anyopaque, allocator: Allocator) anyerror![]agent_mod.Identity;

pub const AgentIdentity = agent_mod.Identity;
pub const freeAgentIdentities = agent_mod.freeIdentities;

// ---------------------------------------------------------------------------
// SSH AuthMethod vtable (extends transport.AuthMethod)
// ---------------------------------------------------------------------------

/// go-git SSH `AuthMethod` — `transport.AuthMethod` + `ClientConfig()`.
pub const AuthMethod = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ptr: *anyopaque) []const u8,
        format: *const fn (ptr: *anyopaque, allocator: Allocator) Allocator.Error![]u8,
        client_config: *const fn (ptr: *anyopaque, allocator: Allocator) anyerror!ClientConfig,
    };

    pub fn name(self: AuthMethod) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn format(self: AuthMethod, allocator: Allocator) Allocator.Error![]u8 {
        return self.vtable.format(self.ptr, allocator);
    }

    pub fn clientConfig(self: AuthMethod, allocator: Allocator) anyerror!ClientConfig {
        return self.vtable.client_config(self.ptr, allocator);
    }

};

fn authString(allocator: Allocator, user: []const u8, method_name: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "user: {s}, name: {s}", .{ user, method_name });
}

// ---------------------------------------------------------------------------
// Password
// ---------------------------------------------------------------------------

/// go-git `Password`.
pub const Password = struct {
    user: []const u8 = "",
    password: []const u8 = "",
    host_key: HostKeyCallbackHelper = .{},

    pub fn name(_: *const Password) []const u8 {
        return PasswordName;
    }

    pub fn format(self: *const Password, allocator: Allocator) Allocator.Error![]u8 {
        return authString(allocator, self.user, PasswordName);
    }

    pub fn clientConfig(self: *Password, _: Allocator) Error!ClientConfig {
        var cfg = ClientConfig{
            .user = self.user,
            .auth_kind = .password,
            .password = self.password,
        };
        try self.host_key.setHostKeyCallbackAndAlgorithms(&cfg);
        return cfg;
    }

    pub fn asAuthMethod(self: *Password) AuthMethod {
        const gen = struct {
            fn nameFn(ptr: *anyopaque) []const u8 {
                const s: *Password = @ptrCast(@alignCast(ptr));
                return s.name();
            }
            fn formatFn(ptr: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
                const s: *Password = @ptrCast(@alignCast(ptr));
                return s.format(allocator);
            }
            fn clientConfigFn(ptr: *anyopaque, allocator: Allocator) anyerror!ClientConfig {
                const s: *Password = @ptrCast(@alignCast(ptr));
                return s.clientConfig(allocator);
            }
            const vtable = AuthMethod.VTable{
                .name = nameFn,
                .format = formatFn,
                .client_config = clientConfigFn,
            };
        };
        return .{ .ptr = self, .vtable = &gen.vtable };
    }

    pub fn asTransportAuth(self: *Password) transport.AuthMethod {
        const gen = struct {
            fn nameFn(ptr: *anyopaque) []const u8 {
                const s: *Password = @ptrCast(@alignCast(ptr));
                return s.name();
            }
            fn formatFn(ptr: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
                const s: *Password = @ptrCast(@alignCast(ptr));
                return s.format(allocator);
            }
            const vtable = transport.AuthMethod.VTable{
                .name = nameFn,
                .format = formatFn,
            };
        };
        return .{ .ptr = self, .vtable = &gen.vtable };
    }
};

// ---------------------------------------------------------------------------
// PasswordCallback
// ---------------------------------------------------------------------------

/// go-git `PasswordCallback`.
pub const PasswordCallback = struct {
    user: []const u8 = "",
    callback_ctx: ?*anyopaque = null,
    callback: ?PasswordCallbackFn = null,
    host_key: HostKeyCallbackHelper = .{},

    pub fn name(_: *const PasswordCallback) []const u8 {
        return PasswordCallbackName;
    }

    pub fn format(self: *const PasswordCallback, allocator: Allocator) Allocator.Error![]u8 {
        return authString(allocator, self.user, PasswordCallbackName);
    }

    pub fn clientConfig(self: *PasswordCallback, _: Allocator) Error!ClientConfig {
        var cfg = ClientConfig{
            .user = self.user,
            .auth_kind = .password_callback,
            .callback_ctx = self.callback_ctx,
            .password_callback = self.callback,
        };
        try self.host_key.setHostKeyCallbackAndAlgorithms(&cfg);
        return cfg;
    }

    pub fn asAuthMethod(self: *PasswordCallback) AuthMethod {
        const gen = struct {
            fn nameFn(ptr: *anyopaque) []const u8 {
                const s: *PasswordCallback = @ptrCast(@alignCast(ptr));
                return s.name();
            }
            fn formatFn(ptr: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
                const s: *PasswordCallback = @ptrCast(@alignCast(ptr));
                return s.format(allocator);
            }
            fn clientConfigFn(ptr: *anyopaque, allocator: Allocator) anyerror!ClientConfig {
                const s: *PasswordCallback = @ptrCast(@alignCast(ptr));
                return s.clientConfig(allocator);
            }
            const vtable = AuthMethod.VTable{
                .name = nameFn,
                .format = formatFn,
                .client_config = clientConfigFn,
            };
        };
        return .{ .ptr = self, .vtable = &gen.vtable };
    }

    pub fn asTransportAuth(self: *PasswordCallback) transport.AuthMethod {
        const gen = struct {
            fn nameFn(ptr: *anyopaque) []const u8 {
                const s: *PasswordCallback = @ptrCast(@alignCast(ptr));
                return s.name();
            }
            fn formatFn(ptr: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
                const s: *PasswordCallback = @ptrCast(@alignCast(ptr));
                return s.format(allocator);
            }
            const vtable = transport.AuthMethod.VTable{
                .name = nameFn,
                .format = formatFn,
            };
        };
        return .{ .ptr = self, .vtable = &gen.vtable };
    }
};

// ---------------------------------------------------------------------------
// KeyboardInteractive
// ---------------------------------------------------------------------------

/// go-git `KeyboardInteractive`.
pub const KeyboardInteractive = struct {
    user: []const u8 = "",
    challenge_ctx: ?*anyopaque = null,
    challenge: ?ChallengeFn = null,
    host_key: HostKeyCallbackHelper = .{},

    pub fn name(_: *const KeyboardInteractive) []const u8 {
        return KeyboardInteractiveName;
    }

    pub fn format(self: *const KeyboardInteractive, allocator: Allocator) Allocator.Error![]u8 {
        return authString(allocator, self.user, KeyboardInteractiveName);
    }

    pub fn clientConfig(self: *KeyboardInteractive, _: Allocator) Error!ClientConfig {
        var cfg = ClientConfig{
            .user = self.user,
            .auth_kind = .keyboard_interactive,
            .callback_ctx = self.challenge_ctx,
            .challenge_fn = self.challenge,
        };
        try self.host_key.setHostKeyCallbackAndAlgorithms(&cfg);
        return cfg;
    }

    pub fn asAuthMethod(self: *KeyboardInteractive) AuthMethod {
        const gen = struct {
            fn nameFn(ptr: *anyopaque) []const u8 {
                const s: *KeyboardInteractive = @ptrCast(@alignCast(ptr));
                return s.name();
            }
            fn formatFn(ptr: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
                const s: *KeyboardInteractive = @ptrCast(@alignCast(ptr));
                return s.format(allocator);
            }
            fn clientConfigFn(ptr: *anyopaque, allocator: Allocator) anyerror!ClientConfig {
                const s: *KeyboardInteractive = @ptrCast(@alignCast(ptr));
                return s.clientConfig(allocator);
            }
            const vtable = AuthMethod.VTable{
                .name = nameFn,
                .format = formatFn,
                .client_config = clientConfigFn,
            };
        };
        return .{ .ptr = self, .vtable = &gen.vtable };
    }

    pub fn asTransportAuth(self: *KeyboardInteractive) transport.AuthMethod {
        const gen = struct {
            fn nameFn(ptr: *anyopaque) []const u8 {
                const s: *KeyboardInteractive = @ptrCast(@alignCast(ptr));
                return s.name();
            }
            fn formatFn(ptr: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
                const s: *KeyboardInteractive = @ptrCast(@alignCast(ptr));
                return s.format(allocator);
            }
            const vtable = transport.AuthMethod.VTable{
                .name = nameFn,
                .format = formatFn,
            };
        };
        return .{ .ptr = self, .vtable = &gen.vtable };
    }
};

// ---------------------------------------------------------------------------
// PEM structure + OpenSSH key-type detection
// ---------------------------------------------------------------------------

/// Structural parse of a PEM private key (no live crypto signer).
pub const PemInfo = struct {
    /// PEM label without BEGIN/END (e.g. `RSA PRIVATE KEY`, `OPENSSH PRIVATE KEY`).
    label: []const u8 = "",
    /// True when Proc-Type indicates encryption or OpenSSH bcrypt-marked key.
    encrypted: bool = false,
    /// Base64-decoded body (DER / OpenSSH blob). Owned when from parse helpers.
    body: []const u8 = "",
    owned_body: bool = false,
    /// Detected SSH algorithm name (`ssh-rsa`, `ssh-ed25519`, …) or empty.
    key_type: []const u8 = "",

    pub fn deinit(self: *PemInfo, allocator: Allocator) void {
        if (self.owned_body and self.body.len > 0) {
            allocator.free(self.body);
        }
        self.* = .{};
    }
};

/// Parse PEM private-key structure and detect OpenSSH public key type when present.
pub fn parsePemPrivateKeyStructure(allocator: Allocator, pem_bytes: []const u8) (Allocator.Error || Error)!PemInfo {
    var it = std.mem.splitScalar(u8, pem_bytes, '\n');
    var label: []const u8 = "";
    var in_body = false;
    var encrypted = false;
    var b64: std.ArrayList(u8) = .empty;
    defer b64.deinit(allocator);

    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "-----BEGIN ") and std.mem.endsWith(u8, line, "-----")) {
            const inner = line["-----BEGIN ".len .. line.len - 5];
            if (std.mem.indexOf(u8, inner, "PRIVATE KEY") == null) continue;
            label = inner;
            in_body = true;
            continue;
        }
        if (std.mem.startsWith(u8, line, "-----END ")) break;
        if (!in_body) continue;

        // PEM headers before body.
        if (std.mem.indexOfScalar(u8, line, ':') != null) {
            if (std.mem.startsWith(u8, line, "Proc-Type:") and
                std.mem.indexOf(u8, line, "ENCRYPTED") != null)
            {
                encrypted = true;
            }
            continue;
        }
        try b64.appendSlice(allocator, line);
    }

    if (label.len == 0 or b64.items.len == 0) return error.InvalidPem;

    const dec_len = std.base64.standard.Decoder.calcSizeForSlice(b64.items) catch return error.InvalidPem;
    const body = try allocator.alloc(u8, dec_len);
    errdefer allocator.free(body);
    std.base64.standard.Decoder.decode(body, b64.items) catch return error.InvalidPem;

    if (std.mem.eql(u8, label, "OPENSSH PRIVATE KEY")) {
        if (body.len > 15 and std.mem.startsWith(u8, body, "openssh-key-v1\x00")) {
            const after = body["openssh-key-v1\x00".len..];
            if (after.len >= 4) {
                const n = std.mem.readInt(u32, after[0..4], .big);
                if (4 + n <= after.len) {
                    const cipher = after[4 .. 4 + n];
                    if (!std.mem.eql(u8, cipher, "none")) encrypted = true;
                }
            }
        }
    }

    const key_type = detectKeyType(label, body);

    return .{
        .label = label,
        .encrypted = encrypted,
        .body = body,
        .owned_body = true,
        .key_type = key_type,
    };
}

/// Detect SSH public-key algorithm from PEM label and/or OpenSSH private-key body.
pub fn detectKeyType(label: []const u8, body: []const u8) []const u8 {
    if (std.mem.eql(u8, label, "RSA PRIVATE KEY")) return "ssh-rsa";
    if (std.mem.eql(u8, label, "EC PRIVATE KEY")) return "ecdsa-sha2";
    if (std.mem.eql(u8, label, "DSA PRIVATE KEY")) return "ssh-dss";
    if (std.mem.eql(u8, label, "OPENSSH PRIVATE KEY")) {
        return detectOpensshPublicKeyType(body);
    }
    // PKCS#8 "PRIVATE KEY" / "ENCRYPTED PRIVATE KEY" — type not in PEM label.
    if (std.mem.eql(u8, label, "PRIVATE KEY") or std.mem.eql(u8, label, "ENCRYPTED PRIVATE KEY")) {
        return "";
    }
    return "";
}

/// Read OpenSSH v1 public key section algorithm name (e.g. `ssh-ed25519`).
/// Returns empty slice when the body is incomplete or encrypted layout blocks parse.
pub fn detectOpensshPublicKeyType(body: []const u8) []const u8 {
    const magic = "openssh-key-v1\x00";
    if (!std.mem.startsWith(u8, body, magic)) return "";
    var off: usize = magic.len;

    // ciphername, kdfname, kdfoptions
    _ = skipSshString(body, &off) orelse return "";
    _ = skipSshString(body, &off) orelse return "";
    _ = skipSshString(body, &off) orelse return "";

    // nkeys
    if (off + 4 > body.len) return "";
    const nkeys = std.mem.readInt(u32, body[off..][0..4], .big);
    off += 4;
    if (nkeys == 0) return "";

    // first public key blob
    const pub_blob = skipSshString(body, &off) orelse return "";
    // public key: string algo || ...
    var p_off: usize = 0;
    const algo = skipSshString(pub_blob, &p_off) orelse return "";
    // Return stable static names when recognized; otherwise empty (avoid dangling).
    if (std.mem.eql(u8, algo, "ssh-ed25519")) return "ssh-ed25519";
    if (std.mem.eql(u8, algo, "ssh-rsa")) return "ssh-rsa";
    if (std.mem.eql(u8, algo, "ssh-dss")) return "ssh-dss";
    if (std.mem.eql(u8, algo, "ecdsa-sha2-nistp256")) return "ecdsa-sha2-nistp256";
    if (std.mem.eql(u8, algo, "ecdsa-sha2-nistp384")) return "ecdsa-sha2-nistp384";
    if (std.mem.eql(u8, algo, "ecdsa-sha2-nistp521")) return "ecdsa-sha2-nistp521";
    return "";
}

fn skipSshString(buf: []const u8, off: *usize) ?[]const u8 {
    if (off.* + 4 > buf.len) return null;
    const n = std.mem.readInt(u32, buf[off.*..][0..4], .big);
    off.* += 4;
    if (off.* + n > buf.len) return null;
    const s = buf[off.* .. off.* + n];
    off.* += n;
    return s;
}

// ---------------------------------------------------------------------------
// PublicKeys
// ---------------------------------------------------------------------------

/// go-git `PublicKeys` (PEM-backed; system-`ssh -i` uses path or temp file).
pub const PublicKeys = struct {
    user: []const u8 = "",
    /// Raw PEM bytes (may be owned via `owned_pem`).
    pem_bytes: []const u8 = "",
    password: []const u8 = "",
    owned_pem: ?[]u8 = null,
    pem_info: PemInfo = .{},
    /// Source path when loaded via `newPublicKeysFromFile` (owned if set).
    identity_path: []const u8 = "",
    owned_identity_path: ?[]u8 = null,
    host_key: HostKeyCallbackHelper = .{},
    allocator: ?Allocator = null,

    pub fn deinit(self: *PublicKeys) void {
        if (self.allocator) |a| {
            if (self.owned_pem) |p| a.free(p);
            if (self.owned_identity_path) |p| a.free(p);
            self.pem_info.deinit(a);
        }
        self.owned_pem = null;
        self.owned_identity_path = null;
        self.pem_bytes = "";
        self.identity_path = "";
        self.allocator = null;
    }

    pub fn name(_: *const PublicKeys) []const u8 {
        return PublicKeysName;
    }

    pub fn format(self: *const PublicKeys, allocator: Allocator) Allocator.Error![]u8 {
        return authString(allocator, self.user, PublicKeysName);
    }

    pub fn clientConfig(self: *PublicKeys, _: Allocator) Error!ClientConfig {
        var cfg = ClientConfig{
            .user = self.user,
            .auth_kind = .public_keys,
            .pem_bytes = self.pem_bytes,
            .pem_password = self.password,
            .identity_file = self.identity_path,
            .key_type = self.pem_info.key_type,
        };
        try self.host_key.setHostKeyCallbackAndAlgorithms(&cfg);
        return cfg;
    }

    /// Write PEM bytes to a secure temp file for system-`ssh -i`.
    ///
    /// Creates with mode `0o600` and exclusive create. On write failure the
    /// partial file is deleted. Returns owned absolute path; caller frees the
    /// path string and must delete the file (HostCommand does this on deinit).
    pub fn writeIdentityTempFile(self: *const PublicKeys, allocator: Allocator, io: std.Io) anyerror![]u8 {
        if (self.pem_bytes.len == 0) return error.InvalidPem;

        const tmp_root: []const u8 = "/tmp";
        var attempt: u32 = 0;
        while (attempt < 64) : (attempt += 1) {
            const fname = try std.fmt.allocPrint(
                allocator,
                "gitz-ssh-id-{x}-{d}",
                .{ @intFromPtr(self), attempt },
            );
            defer allocator.free(fname);
            const path = try std.fs.path.join(allocator, &.{ tmp_root, fname });
            errdefer allocator.free(path);

            const file = std.Io.Dir.createFileAbsolute(io, path, .{
                .exclusive = true,
                .permissions = @enumFromInt(0o600),
            }) catch |err| {
                allocator.free(path);
                if (err == error.PathAlreadyExists) continue;
                return err;
            };

            file.writePositionalAll(io, self.pem_bytes, 0) catch |err| {
                file.close(io);
                std.Io.Dir.deleteFileAbsolute(io, path) catch {};
                allocator.free(path);
                return err;
            };
            file.close(io);
            return path;
        }
        return error.PathAlreadyExists;
    }

    pub fn asAuthMethod(self: *PublicKeys) AuthMethod {
        const gen = struct {
            fn nameFn(ptr: *anyopaque) []const u8 {
                const s: *PublicKeys = @ptrCast(@alignCast(ptr));
                return s.name();
            }
            fn formatFn(ptr: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
                const s: *PublicKeys = @ptrCast(@alignCast(ptr));
                return s.format(allocator);
            }
            fn clientConfigFn(ptr: *anyopaque, allocator: Allocator) anyerror!ClientConfig {
                const s: *PublicKeys = @ptrCast(@alignCast(ptr));
                return s.clientConfig(allocator);
            }
            const vtable = AuthMethod.VTable{
                .name = nameFn,
                .format = formatFn,
                .client_config = clientConfigFn,
            };
        };
        return .{ .ptr = self, .vtable = &gen.vtable };
    }

    pub fn asTransportAuth(self: *PublicKeys) transport.AuthMethod {
        const gen = struct {
            fn nameFn(ptr: *anyopaque) []const u8 {
                const s: *PublicKeys = @ptrCast(@alignCast(ptr));
                return s.name();
            }
            fn formatFn(ptr: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
                const s: *PublicKeys = @ptrCast(@alignCast(ptr));
                return s.format(allocator);
            }
            const vtable = transport.AuthMethod.VTable{
                .name = nameFn,
                .format = formatFn,
            };
        };
        return .{ .ptr = self, .vtable = &gen.vtable };
    }
};

/// go-git `NewPublicKeys` — PEM validation + OpenSSH key-type detection.
///
/// Signing for system SSH uses `ssh -i` (identity path or temp file), not an
/// in-process pure-Zig crypto signer.
pub fn newPublicKeys(
    allocator: Allocator,
    user: []const u8,
    pem_bytes: []const u8,
    password: []const u8,
) (Allocator.Error || Error)!PublicKeys {
    var info = try parsePemPrivateKeyStructure(allocator, pem_bytes);
    errdefer info.deinit(allocator);

    if (info.encrypted and password.len == 0) {
        return error.PassphraseMissing;
    }

    const owned = try allocator.dupe(u8, pem_bytes);
    errdefer allocator.free(owned);

    return .{
        .user = user,
        .pem_bytes = owned,
        .password = password,
        .owned_pem = owned,
        .pem_info = info,
        .allocator = allocator,
    };
}

/// go-git `NewPublicKeysFromFile` — read PEM from path via `std.Io`.
/// Stores `identity_path` for system-`ssh -i`.
pub fn newPublicKeysFromFile(
    allocator: Allocator,
    io: std.Io,
    user: []const u8,
    pem_file: []const u8,
    password: []const u8,
) anyerror!PublicKeys {
    const bytes = try readFileBytes(allocator, io, pem_file);
    defer allocator.free(bytes);
    var pk = try newPublicKeys(allocator, user, bytes, password);
    errdefer pk.deinit();
    const path_owned = try allocator.dupe(u8, pem_file);
    pk.owned_identity_path = path_owned;
    pk.identity_path = path_owned;
    return pk;
}

/// Mem-friendly API: build PublicKeys from already-loaded PEM bytes (same as NewPublicKeys).
pub fn newPublicKeysFromBytes(
    allocator: Allocator,
    user: []const u8,
    pem_bytes: []const u8,
    password: []const u8,
) (Allocator.Error || Error)!PublicKeys {
    return newPublicKeys(allocator, user, pem_bytes, password);
}

fn readFileBytes(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    return try file_reader.interface.allocRemaining(allocator, .limited(1 * 1024 * 1024));
}

// ---------------------------------------------------------------------------
// PublicKeysCallback + SSH agent
// ---------------------------------------------------------------------------

/// Heap context for agent signers callback (sock path).
pub const AgentAuthContext = struct {
    sock: []const u8,
};

/// go-git `PublicKeysCallback`.
pub const PublicKeysCallback = struct {
    user: []const u8 = "",
    callback_ctx: ?*anyopaque = null,
    callback: ?SignersCallbackFn = null,
    /// Agent socket path when created via `newSSHAgentAuth` (owned if set).
    agent_sock: []const u8 = "",
    owned_sock: ?[]u8 = null,
    owned_user: ?[]u8 = null,
    owned_agent_ctx: ?*AgentAuthContext = null,
    allocator: ?Allocator = null,
    host_key: HostKeyCallbackHelper = .{},

    pub fn deinit(self: *PublicKeysCallback) void {
        if (self.allocator) |a| {
            if (self.owned_agent_ctx) |ac| a.destroy(ac);
            if (self.owned_sock) |s| a.free(s);
            if (self.owned_user) |u| a.free(u);
        }
        self.owned_agent_ctx = null;
        self.owned_sock = null;
        self.owned_user = null;
        self.allocator = null;
    }

    pub fn name(_: *const PublicKeysCallback) []const u8 {
        return PublicKeysCallbackName;
    }

    pub fn format(self: *const PublicKeysCallback, allocator: Allocator) Allocator.Error![]u8 {
        return authString(allocator, self.user, PublicKeysCallbackName);
    }

    pub fn clientConfig(self: *PublicKeysCallback, _: Allocator) Error!ClientConfig {
        var cfg = ClientConfig{
            .user = self.user,
            .auth_kind = .public_keys_callback,
            .agent_sock = self.agent_sock,
            .callback_ctx = self.callback_ctx,
            .signers_callback = self.callback,
        };
        try self.host_key.setHostKeyCallbackAndAlgorithms(&cfg);
        return cfg;
    }

    pub fn asAuthMethod(self: *PublicKeysCallback) AuthMethod {
        const gen = struct {
            fn nameFn(ptr: *anyopaque) []const u8 {
                const s: *PublicKeysCallback = @ptrCast(@alignCast(ptr));
                return s.name();
            }
            fn formatFn(ptr: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
                const s: *PublicKeysCallback = @ptrCast(@alignCast(ptr));
                return s.format(allocator);
            }
            fn clientConfigFn(ptr: *anyopaque, allocator: Allocator) anyerror!ClientConfig {
                const s: *PublicKeysCallback = @ptrCast(@alignCast(ptr));
                return s.clientConfig(allocator);
            }
            const vtable = AuthMethod.VTable{
                .name = nameFn,
                .format = formatFn,
                .client_config = clientConfigFn,
            };
        };
        return .{ .ptr = self, .vtable = &gen.vtable };
    }

    pub fn asTransportAuth(self: *PublicKeysCallback) transport.AuthMethod {
        const gen = struct {
            fn nameFn(ptr: *anyopaque) []const u8 {
                const s: *PublicKeysCallback = @ptrCast(@alignCast(ptr));
                return s.name();
            }
            fn formatFn(ptr: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
                const s: *PublicKeysCallback = @ptrCast(@alignCast(ptr));
                return s.format(allocator);
            }
            const vtable = transport.AuthMethod.VTable{
                .name = nameFn,
                .format = formatFn,
            };
        };
        return .{ .ptr = self, .vtable = &gen.vtable };
    }
};

fn agentListSigners(ctx: *anyopaque, allocator: Allocator) anyerror![]agent_mod.Identity {
    const ac: *AgentAuthContext = @ptrCast(@alignCast(ctx));
    if (ac.sock.len == 0) return error.SSHAgentUnavailable;
    var client = try agent_mod.AgentClient.connectDefaultIo(allocator, ac.sock);
    defer client.disconnect();
    return try client.listIdentities(allocator);
}

/// Resolve username (go-git `username`).
pub fn usernameFromEnviron(environ: std.process.Environ) Error![]const u8 {
    if (std.process.Environ.getPosix(environ, "USER")) |u| {
        if (u.len > 0) return u;
    }
    if (std.process.Environ.getPosix(environ, "LOGNAME")) |u| {
        if (u.len > 0) return u;
    }
    return error.UsernameUnavailable;
}

/// go-git `NewSSHAgentAuth`.
///
/// When `SSH_AUTH_SOCK` is missing/empty → `error.SSHAgentUnavailable`.
/// When present → returns a `PublicKeysCallback` whose signers callback connects
/// to the agent and lists identities (OpenSSH wire protocol).
pub fn newSSHAgentAuth(
    allocator: Allocator,
    user: []const u8,
    environ: std.process.Environ,
) (Allocator.Error || Error)!PublicKeysCallback {
    const sock = std.process.Environ.getPosix(environ, "SSH_AUTH_SOCK") orelse
        return error.SSHAgentUnavailable;
    if (sock.len == 0) return error.SSHAgentUnavailable;

    var owned_user: ?[]u8 = null;
    errdefer if (owned_user) |ou| allocator.free(ou);
    const u: []const u8 = if (user.len == 0) blk: {
        const resolved = try usernameFromEnviron(environ);
        const dup = try allocator.dupe(u8, resolved);
        owned_user = dup;
        break :blk dup;
    } else user;

    const sock_owned = try allocator.dupe(u8, sock);
    errdefer allocator.free(sock_owned);

    const ac = try allocator.create(AgentAuthContext);
    errdefer allocator.destroy(ac);
    ac.* = .{ .sock = sock_owned };

    return .{
        .user = u,
        .owned_user = owned_user,
        .agent_sock = sock_owned,
        .owned_sock = sock_owned,
        .callback_ctx = ac,
        .callback = agentListSigners,
        .allocator = allocator,
        .owned_agent_ctx = ac,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Password name and string" {
    var a = Password{ .user = "test", .password = "secret" };
    try testing.expectEqualStrings(PasswordName, a.name());
    const s = try a.format(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("user: test, name: ssh-password", s);

    const cfg = try a.clientConfig(testing.allocator);
    try testing.expectEqualStrings("test", cfg.user);
    try testing.expect(cfg.auth_kind == .password);
    try testing.expectEqualStrings("secret", cfg.password);

    const ta = a.asTransportAuth();
    try testing.expectEqualStrings(PasswordName, ta.name());
}

test "PasswordCallback name and string" {
    var a = PasswordCallback{ .user = "test" };
    try testing.expectEqualStrings(PasswordCallbackName, a.name());
    const s = try a.format(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("user: test, name: ssh-password-callback", s);
}

test "KeyboardInteractive name and string" {
    var a = KeyboardInteractive{ .user = "test" };
    try testing.expectEqualStrings(KeyboardInteractiveName, a.name());
    const s = try a.format(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("user: test, name: ssh-keyboard-interactive", s);

    const cfg = try a.clientConfig(testing.allocator);
    try testing.expect(cfg.auth_kind == .keyboard_interactive);
}

test "PublicKeys name and string" {
    var a = PublicKeys{ .user = "test" };
    try testing.expectEqualStrings(PublicKeysName, a.name());
    const s = try a.format(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("user: test, name: ssh-public-keys", s);
}

test "PublicKeysCallback name and string" {
    var a = PublicKeysCallback{ .user = "test" };
    try testing.expectEqualStrings(PublicKeysCallbackName, a.name());
    const s = try a.format(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("user: test, name: ssh-public-key-callback", s);
}

// Minimal synthetic unencrypted PKCS#1-like PEM (structure only; body is dummy base64).
const synthetic_rsa_pem =
    \\-----BEGIN RSA PRIVATE KEY-----
    \\AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4v
    \\MDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5f
    \\-----END RSA PRIVATE KEY-----
;

const synthetic_encrypted_pem =
    \\-----BEGIN RSA PRIVATE KEY-----
    \\Proc-Type: 4,ENCRYPTED
    \\DEK-Info: AES-128-CBC,0123456789ABCDEF0123456789ABCDEF
    \\
    \\AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4v
    \\MDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5f
    \\-----END RSA PRIVATE KEY-----
;

test "NewPublicKeys valid PEM structure" {
    var auth = try newPublicKeys(testing.allocator, "foo", synthetic_rsa_pem, "");
    defer auth.deinit();
    try testing.expectEqualStrings("foo", auth.user);
    try testing.expectEqualStrings(PublicKeysName, auth.name());
    try testing.expect(auth.pem_info.label.len > 0);
    try testing.expect(!auth.pem_info.encrypted);
    try testing.expect(auth.pem_info.body.len > 0);

    const cfg = try auth.clientConfig(testing.allocator);
    try testing.expect(cfg.auth_kind == .public_keys);
    try testing.expect(cfg.pem_bytes.len > 0);
}

test "NewPublicKeys invalid PEM" {
    const result = newPublicKeys(testing.allocator, "foo", "bar", "");
    try testing.expectError(error.InvalidPem, result);
}

test "NewPublicKeys encrypted without password" {
    const result = newPublicKeys(testing.allocator, "foo", synthetic_encrypted_pem, "");
    try testing.expectError(error.PassphraseMissing, result);
}

test "NewPublicKeys encrypted with password" {
    var auth = try newPublicKeys(testing.allocator, "foo", synthetic_encrypted_pem, "secret");
    defer auth.deinit();
    try testing.expect(auth.pem_info.encrypted);
    try testing.expectEqualStrings("secret", auth.password);
}

test "NewPublicKeysFromFile roundtrip" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;

    {
        const file = try tmp.dir.createFile(io, "id_rsa", .{});
        defer file.close(io);
        try file.writePositionalAll(io, synthetic_rsa_pem, 0);
    }

    var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = try tmp.dir.realPath(io, &abs_buf);
    const path = try std.fmt.allocPrint(gpa, "{s}/id_rsa", .{abs_buf[0..abs_len]});
    defer gpa.free(path);

    var auth = try newPublicKeysFromFile(gpa, io, "git", path, "");
    defer auth.deinit();
    try testing.expectEqualStrings("git", auth.user);
    try testing.expect(auth.pem_bytes.len > 0);
}

test "NewSSHAgentAuth no agent" {
    // Empty environ → no SSH_AUTH_SOCK.
    const empty = std.process.Environ.empty;
    const result = newSSHAgentAuth(testing.allocator, "foo", empty);
    try testing.expectError(error.SSHAgentUnavailable, result);
}

test "NewSSHAgentAuth with sock env" {
    const gpa = testing.allocator;
    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();
    try map.put("SSH_AUTH_SOCK", "/tmp/fake-ssh-agent.sock");
    try map.put("USER", "agentuser");
    const environ: std.process.Environ = .{ .block = try map.createPosixBlock(gpa, .{}) };
    defer environ.block.deinit(gpa);

    var auth = try newSSHAgentAuth(gpa, "foo", environ);
    defer auth.deinit();
    try testing.expectEqualStrings("foo", auth.user);
    try testing.expectEqualStrings("/tmp/fake-ssh-agent.sock", auth.agent_sock);
    try testing.expectEqualStrings(PublicKeysCallbackName, auth.name());

    const cfg = try auth.clientConfig(gpa);
    try testing.expect(cfg.auth_kind == .public_keys_callback);
    try testing.expect(cfg.signers_callback != null);
    try testing.expect(cfg.callback_ctx != null);

    // Fake socket path → connect fails (not "not implemented").
    const result = cfg.signers_callback.?(cfg.callback_ctx.?, gpa);
    try testing.expect(std.meta.isError(result));
}

test "NewSSHAgentAuth empty user resolves USER" {
    const gpa = testing.allocator;
    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();
    try map.put("SSH_AUTH_SOCK", "/tmp/agent.sock");
    try map.put("USER", "fromenv");
    const environ: std.process.Environ = .{ .block = try map.createPosixBlock(gpa, .{}) };
    defer environ.block.deinit(gpa);

    var auth = try newSSHAgentAuth(gpa, "", environ);
    defer auth.deinit();
    try testing.expectEqualStrings("fromenv", auth.user);
}

test "HostKeyCallbackHelper keeps existing callback" {
    const cb = HostKeyCallback.insecureIgnoreHostKey();
    var helper = HostKeyCallbackHelper{
        .host_key_callback = cb,
        .host_key_algorithms = &.{"ssh-ed25519"},
    };
    var cfg = ClientConfig{};
    try helper.setHostKeyCallback(&cfg);
    try testing.expect(cfg.host_key_callback != null);
    try testing.expectEqual(@as(usize, 1), cfg.host_key_algorithms.len);
    try testing.expectEqualStrings("ssh-ed25519", cfg.host_key_algorithms[0]);
}

test "HostKeyCallbackHelper fallback" {
    const gen = struct {
        fn fb(_: []const []const u8) Error!HostKeyCallback {
            return HostKeyCallback.insecureIgnoreHostKey();
        }
    };
    var helper = HostKeyCallbackHelper{
        .fallback = gen.fb,
    };
    var cfg = ClientConfig{};
    try helper.setHostKeyCallbackAndAlgorithms(&cfg);
    try testing.expect(cfg.host_key_callback != null);
}

test "DefaultUsername constant" {
    try testing.expectEqualStrings("git", DefaultUsername);
}

test "AuthMethod vtable clientConfig" {
    var pw = Password{ .user = "u", .password = "p" };
    const am = pw.asAuthMethod();
    try testing.expectEqualStrings(PasswordName, am.name());
    const cfg = try am.clientConfig(testing.allocator);
    try testing.expectEqualStrings("p", cfg.password);
}

test "PasswordCallback invokes callback" {
    const Ctx = struct {
        pass: []const u8 = "from-callback",
        fn cb(ptr: *anyopaque) anyerror![]const u8 {
            const c: *@This() = @ptrCast(@alignCast(ptr));
            return c.pass;
        }
    };
    var ctx = Ctx{};
    var a = PasswordCallback{
        .user = "u",
        .callback_ctx = &ctx,
        .callback = Ctx.cb,
    };
    const cfg = try a.clientConfig(testing.allocator);
    try testing.expect(cfg.password_callback != null);
    const got = try cfg.password_callback.?(cfg.callback_ctx.?);
    try testing.expectEqualStrings("from-callback", got);
}

test "KeyboardInteractive challenge vtable" {
    const Ctx = struct {
        fn challenge(
            _: *anyopaque,
            allocator: Allocator,
            _: []const u8,
            _: []const u8,
            questions: []const []const u8,
            _: []const bool,
        ) anyerror![]const []const u8 {
            const out = try allocator.alloc([]const u8, questions.len);
            for (out) |*r| r.* = "answer";
            return out;
        }
    };
    var dummy: u8 = 0;
    var a = KeyboardInteractive{
        .user = "u",
        .challenge_ctx = &dummy,
        .challenge = Ctx.challenge,
    };
    const cfg = try a.clientConfig(testing.allocator);
    try testing.expect(cfg.challenge_fn != null);
    const qs = [_][]const u8{"Password:"};
    const echos = [_]bool{false};
    const answers = try cfg.challenge_fn.?(cfg.callback_ctx.?, testing.allocator, "u", "", &qs, &echos);
    defer testing.allocator.free(answers);
    try testing.expectEqual(@as(usize, 1), answers.len);
    try testing.expectEqualStrings("answer", answers[0]);
}

test "parsePemPrivateKeyStructure OpenSSH encrypted marker" {
    // openssh-key-v1 with cipher != none (aes256-ctr) → encrypted.
    // Wire: magic + u32 len + "aes256-ctr"
    const cipher = "aes256-ctr";
    var raw: [64]u8 = undefined;
    const magic = "openssh-key-v1\x00";
    @memcpy(raw[0..magic.len], magic);
    std.mem.writeInt(u32, raw[magic.len..][0..4], @as(u32, @intCast(cipher.len)), .big);
    @memcpy(raw[magic.len + 4 ..][0..cipher.len], cipher);
    const body_len = magic.len + 4 + cipher.len;

    var b64_buf: [128]u8 = undefined;
    const enc_len = std.base64.standard.Encoder.calcSize(body_len);
    _ = std.base64.standard.Encoder.encode(b64_buf[0..enc_len], raw[0..body_len]);

    var pem_buf: [256]u8 = undefined;
    const pem = try std.fmt.bufPrint(
        &pem_buf,
        "-----BEGIN OPENSSH PRIVATE KEY-----\n{s}\n-----END OPENSSH PRIVATE KEY-----\n",
        .{b64_buf[0..enc_len]},
    );

    var info = try parsePemPrivateKeyStructure(testing.allocator, pem);
    defer info.deinit(testing.allocator);
    try testing.expect(info.encrypted);
    try testing.expectEqualStrings("OPENSSH PRIVATE KEY", info.label);
}

test "detectOpensshPublicKeyType ed25519" {
    // openssh-key-v1: none/none/empty, nkeys=1, pubkey = string "ssh-ed25519" + 32 zero bytes
    var raw: [256]u8 = undefined;
    var o: usize = 0;
    const magic = "openssh-key-v1\x00";
    @memcpy(raw[o..][0..magic.len], magic);
    o += magic.len;
    // cipher "none"
    std.mem.writeInt(u32, raw[o..][0..4], 4, .big);
    o += 4;
    @memcpy(raw[o..][0..4], "none");
    o += 4;
    // kdf "none"
    std.mem.writeInt(u32, raw[o..][0..4], 4, .big);
    o += 4;
    @memcpy(raw[o..][0..4], "none");
    o += 4;
    // kdfoptions empty
    std.mem.writeInt(u32, raw[o..][0..4], 0, .big);
    o += 4;
    // nkeys
    std.mem.writeInt(u32, raw[o..][0..4], 1, .big);
    o += 4;
    // public key blob: algo string + 32-byte key
    const algo = "ssh-ed25519";
    const pub_inner_len: u32 = 4 + algo.len + 4 + 32;
    std.mem.writeInt(u32, raw[o..][0..4], pub_inner_len, .big);
    o += 4;
    std.mem.writeInt(u32, raw[o..][0..4], @intCast(algo.len), .big);
    o += 4;
    @memcpy(raw[o..][0..algo.len], algo);
    o += algo.len;
    std.mem.writeInt(u32, raw[o..][0..4], 32, .big);
    o += 4;
    @memset(raw[o .. o + 32], 0);
    o += 32;

    try testing.expectEqualStrings("ssh-ed25519", detectOpensshPublicKeyType(raw[0..o]));

    var b64_buf: [512]u8 = undefined;
    const enc_len = std.base64.standard.Encoder.calcSize(o);
    _ = std.base64.standard.Encoder.encode(b64_buf[0..enc_len], raw[0..o]);
    var pem_buf: [640]u8 = undefined;
    const pem = try std.fmt.bufPrint(
        &pem_buf,
        "-----BEGIN OPENSSH PRIVATE KEY-----\n{s}\n-----END OPENSSH PRIVATE KEY-----\n",
        .{b64_buf[0..enc_len]},
    );
    var info = try parsePemPrivateKeyStructure(testing.allocator, pem);
    defer info.deinit(testing.allocator);
    try testing.expectEqualStrings("ssh-ed25519", info.key_type);
    try testing.expect(!info.encrypted);
}

test "NewPublicKeysFromFile stores identity_path" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;

    {
        const file = try tmp.dir.createFile(io, "id_rsa", .{});
        defer file.close(io);
        try file.writePositionalAll(io, synthetic_rsa_pem, 0);
    }

    var abs_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_len = try tmp.dir.realPath(io, &abs_buf);
    const path = try std.fmt.allocPrint(gpa, "{s}/id_rsa", .{abs_buf[0..abs_len]});
    defer gpa.free(path);

    var auth = try newPublicKeysFromFile(gpa, io, "git", path, "");
    defer auth.deinit();
    try testing.expectEqualStrings(path, auth.identity_path);
    const cfg = try auth.clientConfig(gpa);
    try testing.expectEqualStrings(path, cfg.identity_file);
    try testing.expectEqualStrings("ssh-rsa", cfg.key_type);
}

test "writeIdentityTempFile" {
    const gpa = testing.allocator;
    const io = testing.io;
    var auth = try newPublicKeys(gpa, "git", synthetic_rsa_pem, "");
    defer auth.deinit();
    const path = try auth.writeIdentityTempFile(gpa, io);
    defer {
        std.Io.Dir.deleteFileAbsolute(io, path) catch {};
        gpa.free(path);
    }
    try testing.expect(std.mem.indexOf(u8, path, "gitz-ssh-id-") != null);
    const bytes = try readFileBytes(gpa, io, path);
    defer gpa.free(bytes);
    try testing.expect(bytes.len == synthetic_rsa_pem.len);
}
