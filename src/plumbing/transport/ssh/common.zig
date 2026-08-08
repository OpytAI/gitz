//! SSH transport client + runner (go-git `plumbing/transport/ssh/common.go`).
//!
//! Pure Zig dial paths (no libssh / no C):
//!
//! 1. Builds a **command plan** (owned host/user/command strings + auth view).
//! 2. Implements `transport_common.Commander` via `Runner`.
//! 3. Accepts an injectable test commander (mock `Command`) for unit tests.
//! 4. **Native** in-process SSH client (`DialMode.native`, default for `newClient`)
//!    with curve25519-sha256 KEX, aes256/128-ctr, hmac-sha2-512/256, ed25519 and
//!    rsa-sha2-256 host-key verify.
//! 5. **System `ssh`** spawn via `HostCommand` (`DialMode.system_ssh`).
//! 6. **Plan-only** (`DialMode.plan_only` / `use_system_ssh=false`) for unit tests.
//!
//! # Dial modes
//!
//! | Mode | When | Behavior | Ownership after `command` |
//! |------|------|----------|---------------------------|
//! | `native` | `newClient` default | Pure-Zig SSH client | `NativeCommand` → `NativeDialParams` |
//! | `system_ssh` | `dial_mode=.system_ssh` | Spawns host `ssh` | `HostCommand` → `CommandPlan` |
//! | `plan_only` | `use_system_ssh=false` | In-memory plan only | `PlanCommand` → `CommandPlan` |
//! | mock | `test_commander` set | Plan built then mock | plan discarded after build |
//!
//! Host and user are always heap-copied so the plan/command outlives `Endpoint`.
//!
//! System `ssh` uses ambient `SSH_AUTH_SOCK` for agent auth and `-i` for
//! `ClientConfig.identity_file` / temp PEM. Native dial uses password and
//! OpenSSH ed25519 PEM publickey auth in-process.
//!
//! # go-git map
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `DefaultClient` | `defaultClient` / `DefaultClient` factory |
//! | `NewClient` | `newClient` (native dial) |
//! | `DefaultPort` | `DefaultPort` |
//! | `runner` | `Runner` |
//! | `endpointToCommand` / `writeShellQuote` | same |
//! | `DefaultAuthBuilder` | `DefaultAuthBuilder` / `defaultAuthBuilder` |

const std = @import("std");
const builtin = @import("builtin");
const transport = @import("transport");
const transport_common = @import("transport_common");
const auth_mod = @import("auth_method.zig");
const native_ssh = @import("native_ssh.zig");

const Allocator = std.mem.Allocator;
const Endpoint = transport.Endpoint;
const testing = std.testing;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Io = std.Io;
const File = std.Io.File;

pub const DefaultPort: i32 = 22;

/// How the runner opens a remote git pack command over SSH.
pub const DialMode = enum {
    /// Pure Zig SSH client (default for production `newClient`).
    native,
    /// Spawn host `ssh` binary.
    system_ssh,
    /// PlanCommand only (unit tests).
    plan_only,
};

pub const Error = error{
    /// go-git `ErrInvalidAuthMethod` — auth is not an SSH AuthMethod tag.
    InvalidAuthMethod,
    /// go-git `ErrAlreadyConnected`.
    AlreadyConnected,
    /// System `ssh` binary not found on PATH.
    SshBinaryNotFound,
    /// Process spawn is not supported on this platform (e.g. some WASI targets).
    SpawnUnsupported,
    /// Command failed to start / plan incomplete.
    CommandFailed,
    /// Endpoint requested a proxy while using the system-ssh dialer.
    ProxyUnsupported,
};

fn singleThreadedIo() Io {
    const Holder = struct {
        threadlocal var threaded: Io.Threaded = .init_single_threaded;
    };
    return Holder.threaded.io();
}

// ---------------------------------------------------------------------------
// Client options (subset of ssh.ClientConfig overrides)
// ---------------------------------------------------------------------------

/// Optional overrides applied on top of auth `ClientConfig` (go-git NewClient config).
pub const ClientOptions = struct {
    user: []const u8 = "",
    host_key_callback: ?auth_mod.HostKeyCallback = null,
    host_key_algorithms: []const []const u8 = &.{},
    /// When true, force insecure host key callback if none set.
    insecure_ignore_host_key: bool = false,
};

// ---------------------------------------------------------------------------
// SSH config reader (go-git DefaultSSHConfig)
// ---------------------------------------------------------------------------

/// go-git `sshConfig` interface.
pub const SshConfig = struct {
    ptr: *anyopaque,
    get_fn: *const fn (ptr: *anyopaque, alias: []const u8, key: []const u8) []const u8,

    pub fn get(self: SshConfig, alias: []const u8, key: []const u8) []const u8 {
        return self.get_fn(self.ptr, alias, key);
    }

    pub fn from(comptime T: type, impl: *T) SshConfig {
        const gen = struct {
            fn getFn(ptr: *anyopaque, alias: []const u8, key: []const u8) []const u8 {
                const s: *T = @ptrCast(@alignCast(ptr));
                return s.get(alias, key);
            }
        };
        return .{ .ptr = impl, .get_fn = gen.getFn };
    }
};

/// Package-level SSH config (nil → ignore ssh_config). Tests may replace.
pub var default_ssh_config: ?SshConfig = null;

// ---------------------------------------------------------------------------
// Default auth builder
// ---------------------------------------------------------------------------

pub const AuthBuilderFn = *const fn (
    allocator: Allocator,
    user: []const u8,
    environ: std.process.Environ,
) anyerror!auth_mod.PublicKeysCallback;

/// go-git `DefaultAuthBuilder` — SSH agent auth by default.
pub fn defaultAuthBuilder(
    allocator: Allocator,
    user: []const u8,
    environ: std.process.Environ,
) anyerror!auth_mod.PublicKeysCallback {
    return auth_mod.newSSHAgentAuth(allocator, user, environ);
}

pub var DefaultAuthBuilder: AuthBuilderFn = defaultAuthBuilder;

// ---------------------------------------------------------------------------
// Command plan (testable SSH surface without libssh)
// ---------------------------------------------------------------------------

/// Built description of an SSH remote invocation.
///
/// # Ownership (no UAF when Endpoint goes out of scope after `command`)
///
/// | Field | Owner |
/// |-------|--------|
/// | `remote_command`, `host_with_port`, `ssh_args`, `identity_path` | plan |
/// | `owned_host` / `host` | plan (`host` views owned bytes) |
/// | `owned_user` / `user` | plan when `owned_user` set (always from runner) |
/// | `auth_name`, `key_type` | static / borrowed (immortal or auth-owned) |
/// | `client_config` string slices (`password`, `pem_bytes`, …) | **borrowed**
///   from caller-owned auth; auth must outlive dial/userauth |
///
/// Dial modes transfer owned fields into `PlanCommand` / `HostCommand` /
/// `NativeDialParams` and clear them on the plan so `deinit` is safe.
pub const CommandPlan = struct {
    allocator: Allocator,
    /// Remote shell command: `git-upload-pack '/path'`.
    remote_command: []u8 = &.{},
    /// `host:port` (or `[host]:port` for IPv6 when needed).
    host_with_port: []u8 = &.{},
    /// Owned host name (runner always sets this; tests may leave null + set `host`).
    owned_host: ?[]u8 = null,
    /// Host view used for argv / dial.
    host: []const u8 = "",
    port: i32 = DefaultPort,
    user: []const u8 = "",
    /// When set, plan owns `user` (runner always snapshots user).
    owned_user: ?[]u8 = null,
    auth_name: []const u8 = "",
    auth_kind: auth_mod.AuthKind = .none,
    /// Suggested system `ssh` argv after binary name (owned strings).
    /// Ownership: each `[]u8` and the outer slice — free via `deinit` or
    /// never free partial results from `buildSshArgv` without `freeSshArgv`.
    ssh_args: []const []u8 = &.{},
    /// Identity file path for `-i` when known (owned when non-empty).
    identity_path: []u8 = &.{},
    /// Detected key algorithm from PEM when known (borrowed).
    key_type: []const u8 = "",
    /// When true, emit StrictHostKeyChecking=no for system ssh.
    insecure_ignore_host_key: bool = false,
    /// Snapshot of auth config (slices may be borrowed from caller-owned auth).
    client_config: auth_mod.ClientConfig = .{},
    /// Normalized SOCKS5 proxy URL. Empty means direct dial.
    proxy_url: []u8 = &.{},

    pub fn deinit(self: *CommandPlan) void {
        const a = self.allocator;
        if (self.remote_command.len > 0) a.free(self.remote_command);
        if (self.host_with_port.len > 0) a.free(self.host_with_port);
        for (self.ssh_args) |arg| a.free(arg);
        if (self.ssh_args.len > 0) a.free(self.ssh_args);
        if (self.identity_path.len > 0) a.free(self.identity_path);
        if (self.owned_host) |h| a.free(h);
        if (self.owned_user) |u| a.free(u);
        if (self.proxy_url.len > 0) a.free(self.proxy_url);
        self.* = .{ .allocator = a };
    }
};

/// Build full system-`ssh` argv including `"ssh"` as argv[0].
///
/// Layout: `ssh -p PORT [-i path] [-o StrictHostKeyChecking=no]
///          [-o UserKnownHostsFile=/dev/null] -l USER HOST remote_command`
///
/// Ownership: returns a slice of owned `[]u8` strings. Free with
/// `freeSshArgv(allocator, argv)` only (frees each element then the slice).
/// On error, no allocation is leaked.
pub fn buildSshArgv(
    allocator: Allocator,
    plan: *const CommandPlan,
    identity_path: ?[]const u8,
) Allocator.Error![]const []u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |a| allocator.free(a);
        list.deinit(allocator);
    }

    try list.append(allocator, try allocator.dupe(u8, "ssh"));
    try list.append(allocator, try allocator.dupe(u8, "-p"));
    try list.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{plan.port}));

    const id = identity_path orelse (if (plan.identity_path.len > 0) plan.identity_path else null);
    if (id) |path| {
        if (path.len > 0) {
            try list.append(allocator, try allocator.dupe(u8, "-i"));
            try list.append(allocator, try allocator.dupe(u8, path));
        }
    }

    if (plan.insecure_ignore_host_key) {
        try list.append(allocator, try allocator.dupe(u8, "-o"));
        try list.append(allocator, try allocator.dupe(u8, "StrictHostKeyChecking=no"));
        try list.append(allocator, try allocator.dupe(u8, "-o"));
        try list.append(allocator, try allocator.dupe(u8, "UserKnownHostsFile=/dev/null"));
    }

    try list.append(allocator, try allocator.dupe(u8, "-l"));
    try list.append(allocator, try allocator.dupe(u8, plan.user));
    try list.append(allocator, try allocator.dupe(u8, plan.host));
    try list.append(allocator, try allocator.dupe(u8, plan.remote_command));

    return try list.toOwnedSlice(allocator);
}

/// Free a slice from `buildSshArgv`.
pub fn freeSshArgv(allocator: Allocator, argv: []const []u8) void {
    for (argv) |a| allocator.free(a);
    allocator.free(argv);
}

const default_path: []const u8 = "/usr/local/bin:/bin:/usr/bin";

/// Look up `name` on PATH (existence only). Returns owned path string or null.
pub fn lookPath(allocator: Allocator, io: Io, name: []const u8) Allocator.Error!?[]u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null or std.fs.path.isAbsolute(name)) {
        if (fileExists(io, name)) return try allocator.dupe(u8, name);
        return null;
    }
    const path_env: []const u8 = blk: {
        if (builtin.link_libc) {
            if (std.c.getenv("PATH")) |p| {
                const s = std.mem.span(p);
                if (s.len > 0) break :blk s;
            }
        }
        break :blk default_path;
    };
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = try std.fs.path.join(allocator, &.{ dir, name });
        defer allocator.free(full);
        if (fileExists(io, full)) return try allocator.dupe(u8, full);
    }
    return null;
}

fn fileExists(io: Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
        return true;
    }
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// Shell quote + endpoint command (go-git)
// ---------------------------------------------------------------------------

/// go-git / Git `sq_quote_buf`: wrap in `'…'`; for `'` write `'\''`; for `!` write `'\!'`.
pub fn writeShellQuote(w: *Writer, s: []const u8) anyerror!void {
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') {
            try w.writeAll("'\\''");
            continue;
        }
        if (c == '!') {
            try w.writeAll("'\\!'");
            continue;
        }
        try w.writeByte(c);
    }
    try w.writeByte('\'');
}

/// go-git `endpointToCommand`.
pub fn endpointToCommand(allocator: Allocator, cmd: []const u8, ep: *const Endpoint) Allocator.Error![]u8 {
    var aw: Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    w.writeAll(cmd) catch return error.OutOfMemory;
    w.writeByte(' ') catch return error.OutOfMemory;
    writeShellQuote(w, ep.path) catch return error.OutOfMemory;
    return aw.toOwnedSlice() catch return error.OutOfMemory;
}

/// Join host and port (go-git `net.JoinHostPort` subset).
pub fn joinHostPort(allocator: Allocator, host: []const u8, port: i32) Allocator.Error![]u8 {
    // IPv6 literals: wrap in [] when host contains ':'.
    if (std.mem.indexOfScalar(u8, host, ':') != null) {
        return std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ host, port });
    }
    return std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, port });
}

/// Resolve host:port from endpoint + optional ssh_config (go-git `getHostWithPort`).
pub fn getHostWithPort(
    allocator: Allocator,
    ep: *const Endpoint,
    ssh_cfg: ?SshConfig,
) Allocator.Error![]u8 {
    if (ssh_cfg) |cfg| {
        if (try doGetHostWithPortFromSSHConfig(allocator, ep, cfg)) |addr| {
            return addr;
        }
    }

    const host = ep.host;
    var port = ep.port;
    if (port <= 0) port = DefaultPort;
    return joinHostPort(allocator, host, port);
}

fn doGetHostWithPortFromSSHConfig(
    allocator: Allocator,
    ep: *const Endpoint,
    cfg: SshConfig,
) Allocator.Error!?[]u8 {
    const config_host = cfg.get(ep.host, "Hostname");
    if (config_host.len == 0) return null;

    var port = ep.port;
    if (port <= 0) port = DefaultPort;

    const config_port = cfg.get(ep.host, "Port");
    if (config_port.len > 0) {
        if (std.fmt.parseInt(i32, config_port, 10)) |p| {
            port = p;
        } else |_| {}
    }
    return try joinHostPort(allocator, config_host, port);
}

/// Effective user for a plan (endpoint user → config user → DefaultUsername).
pub fn effectiveUser(ep: *const Endpoint, cfg: *const auth_mod.ClientConfig, options: *const ClientOptions) []const u8 {
    if (options.user.len > 0) return options.user;
    if (cfg.user.len > 0) return cfg.user;
    if (ep.user.len > 0) return ep.user;
    return auth_mod.DefaultUsername;
}

// ---------------------------------------------------------------------------
// PlanCommand — in-memory plan (no spawn; unit tests)
// ---------------------------------------------------------------------------

/// In-memory command backed by a `CommandPlan` (tests with `use_system_ssh=false`).
pub const PlanCommand = struct {
    allocator: Allocator,
    plan: CommandPlan,
    connected: bool = false,
    started: bool = false,
    stdin_writer: Writer.Allocating = undefined,
    stdin_writer_live: bool = false,
    stdin_closed: bool = false,
    stdout_reader: Reader = undefined,
    stderr_reader: Reader = undefined,
    stdout_data: []const u8 = "",
    stderr_data: []const u8 = "",

    pub fn deinit(self: *PlanCommand) void {
        if (self.stdin_writer_live and !self.stdin_closed) {
            self.stdin_writer.deinit();
        }
        self.plan.deinit();
        self.* = undefined;
    }

    pub fn stderrPipe(self: *PlanCommand) anyerror!*Reader {
        self.stderr_reader = Reader.fixed(self.stderr_data);
        return &self.stderr_reader;
    }

    pub fn stdinPipe(self: *PlanCommand) anyerror!transport_common.WriteCloser {
        self.stdin_writer = Writer.Allocating.init(self.allocator);
        self.stdin_writer_live = true;
        const gen = struct {
            fn closeFn(ptr: *anyopaque) anyerror!void {
                const s: *PlanCommand = @ptrCast(@alignCast(ptr));
                if (s.stdin_closed) return;
                s.stdin_writer.deinit();
                s.stdin_closed = true;
                s.stdin_writer_live = false;
            }
        };
        return .{
            .ptr = self,
            .writer = &self.stdin_writer.writer,
            .close_fn = gen.closeFn,
        };
    }

    pub fn stdoutPipe(self: *PlanCommand) anyerror!*Reader {
        self.stdout_reader = Reader.fixed(self.stdout_data);
        return &self.stdout_reader;
    }

    pub fn start(self: *PlanCommand) anyerror!void {
        if (self.connected) return Error.AlreadyConnected;
        self.connected = true;
        self.started = true;
    }

    pub fn close(self: *PlanCommand) anyerror!void {
        self.connected = false;
    }

    pub fn kill(self: *PlanCommand) anyerror!void {
        return self.close();
    }

    pub fn asCommand(self: *PlanCommand) transport_common.Command {
        return transport_common.Command.from(PlanCommand, self);
    }
};

// ---------------------------------------------------------------------------
// HostCommand — system `ssh` spawn
// ---------------------------------------------------------------------------

/// Whether this target can attempt `std.process.spawn`.
/// WASI and freestanding builds report `SpawnUnsupported` at ensureSpawned.
fn spawnSupportedComptime() bool {
    return switch (builtin.os.tag) {
        .wasi, .freestanding => false,
        else => true,
    };
}

/// Real SSH command via system `ssh` binary (pack protocol over stdin/stdout).
///
/// Heap-owned by `Runner` (freed in `Runner.deinit`). Lifecycle matches file
/// transport `HostCommand`:
/// - `ensureSpawned` owns the child until `close`/`kill`/`deinit`.
/// - Stdin close flushes and closes the write end (child sees EOF).
/// - `close` waits and reaps; `kill` terminates then reaps.
/// - Temp PEM identity files (mode 0o600) are deleted in `deinit`.
/// - Do not read pipes after `close`/`kill` (no UAF use of reaped FDs).
pub const HostCommand = struct {
    allocator: Allocator,
    io: Io,
    plan: CommandPlan,
    /// Owned identity path when written as temp PEM file (deleted on deinit).
    temp_identity: ?[]u8 = null,
    /// Resolved `ssh` binary path (owned).
    ssh_bin: []u8 = &.{},
    child: ?std.process.Child = null,
    connected: bool = false,
    started: bool = false,
    closed: bool = false,
    stdin_closed: bool = false,

    stdin_writer_impl: File.Writer = undefined,
    stdout_reader_impl: File.Reader = undefined,
    stderr_reader_impl: File.Reader = undefined,
    stdin_buf: [4096]u8 = undefined,
    stdout_buf: [8192]u8 = undefined,
    stderr_buf: [4096]u8 = undefined,
    pipes_ready: bool = false,

    pub fn deinit(self: *HostCommand) void {
        self.reapKill();
        self.cleanupTempIdentity();
        if (self.ssh_bin.len > 0) self.allocator.free(self.ssh_bin);
        self.plan.deinit();
        self.* = undefined;
    }

    fn cleanupTempIdentity(self: *HostCommand) void {
        if (self.temp_identity) |p| {
            std.Io.Dir.deleteFileAbsolute(self.io, p) catch {};
            self.allocator.free(p);
            self.temp_identity = null;
        }
    }

    /// Kill and reap if still live; clear child and pipes_ready.
    fn reapKill(self: *HostCommand) void {
        self.closeStdin() catch {};
        if (self.child) |*c| {
            if (c.id != null) {
                c.kill(self.io);
            }
            self.child = null;
        }
        self.pipes_ready = false;
        self.connected = false;
        self.started = false;
        self.stdin_closed = true;
    }

    /// Wait and reap if still live; clear child and pipes_ready.
    fn reapWait(self: *HostCommand) void {
        self.closeStdin() catch {};
        if (self.child) |*c| {
            if (c.id != null) {
                _ = c.wait(self.io) catch {};
            }
            self.child = null;
        }
        self.pipes_ready = false;
        self.connected = false;
        self.started = false;
    }

    fn ensureSpawned(self: *HostCommand) anyerror!void {
        if (self.pipes_ready) return;
        if (self.closed) return Error.CommandFailed;

        if (comptime !spawnSupportedComptime()) {
            return Error.SpawnUnsupported;
        }

        // Resolve identity: plan path, else write temp from PEM (0o600).
        var identity: ?[]const u8 = if (self.plan.identity_path.len > 0)
            self.plan.identity_path
        else if (self.plan.client_config.identity_file.len > 0)
            self.plan.client_config.identity_file
        else
            null;
        if (identity == null and self.plan.client_config.pem_bytes.len > 0) {
            var pk = auth_mod.PublicKeys{
                .pem_bytes = self.plan.client_config.pem_bytes,
            };
            const path = try pk.writeIdentityTempFile(self.allocator, self.io);
            self.temp_identity = path;
            identity = path;
        }

        const argv_owned = try buildSshArgv(self.allocator, &self.plan, identity);
        defer freeSshArgv(self.allocator, argv_owned);

        // argv for spawn: prefer resolved binary as argv[0].
        var argv_ptrs = try self.allocator.alloc([]const u8, argv_owned.len);
        defer self.allocator.free(argv_ptrs);
        for (argv_owned, 0..) |a, i| argv_ptrs[i] = a;
        if (self.ssh_bin.len > 0) argv_ptrs[0] = self.ssh_bin;

        var child = std.process.spawn(self.io, .{
            .argv = argv_ptrs,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |err| {
            // Spawn failed after optional temp identity write — leave cleanup to deinit.
            if (err == error.OperationUnsupported) return Error.SpawnUnsupported;
            if (err == error.FileNotFound) return Error.SshBinaryNotFound;
            return err;
        };
        errdefer if (child.id != null) child.kill(self.io);

        const stdin = child.stdin orelse return Error.CommandFailed;
        const stdout = child.stdout orelse return Error.CommandFailed;
        const stderr = child.stderr orelse return Error.CommandFailed;

        self.stdin_writer_impl = File.Writer.initStreaming(stdin, self.io, &self.stdin_buf);
        self.stdout_reader_impl = File.Reader.initStreaming(stdout, self.io, &self.stdout_buf);
        self.stderr_reader_impl = File.Reader.initStreaming(stderr, self.io, &self.stderr_buf);

        self.child = child;
        self.connected = true;
        self.pipes_ready = true;
    }

    pub fn stderrPipe(self: *HostCommand) anyerror!*Reader {
        try self.ensureSpawned();
        return &self.stderr_reader_impl.interface;
    }

    pub fn stdinPipe(self: *HostCommand) anyerror!transport_common.WriteCloser {
        try self.ensureSpawned();
        const gen = struct {
            fn closeFn(ptr: *anyopaque) anyerror!void {
                const s: *HostCommand = @ptrCast(@alignCast(ptr));
                try s.closeStdin();
            }
        };
        return .{
            .ptr = self,
            .writer = &self.stdin_writer_impl.interface,
            .close_fn = gen.closeFn,
        };
    }

    pub fn stdoutPipe(self: *HostCommand) anyerror!*Reader {
        try self.ensureSpawned();
        return &self.stdout_reader_impl.interface;
    }

    fn closeStdin(self: *HostCommand) anyerror!void {
        if (self.stdin_closed) return;
        self.stdin_closed = true;
        if (!self.pipes_ready) return;
        self.stdin_writer_impl.interface.flush() catch {};
        if (self.child) |*c| {
            if (c.stdin) |f| {
                f.close(self.io);
                c.stdin = null;
            }
        }
    }

    pub fn start(self: *HostCommand) anyerror!void {
        if (self.started) return Error.AlreadyConnected;
        if (self.closed) return Error.CommandFailed;
        try self.ensureSpawned();
        self.started = true;
    }

    /// Wait for the child (go-git `Close`). Pipe FDs are invalid after return.
    pub fn close(self: *HostCommand) anyerror!void {
        if (self.closed) return;
        self.closed = true;
        self.reapWait();
    }

    /// Terminate then reap (go-git `CommandKiller.Kill`). Pipe FDs invalid after.
    pub fn kill(self: *HostCommand) anyerror!void {
        if (self.closed and self.child == null) return;
        self.closed = true;
        self.reapKill();
    }

    pub fn asCommand(self: *HostCommand) transport_common.Command {
        return transport_common.Command.from(HostCommand, self);
    }
};

// ---------------------------------------------------------------------------
// Runner (go-git runner)
// ---------------------------------------------------------------------------

/// Marker interface: auth is valid for SSH when name starts with `ssh-`.
pub fn isSshAuthMethod(auth: transport.AuthMethod) bool {
    const n = auth.name();
    return std.mem.startsWith(u8, n, "ssh-");
}

/// go-git `runner`.
pub const Runner = struct {
    allocator: Allocator,
    io: Io = undefined,
    options: ClientOptions = .{},
    /// When set, `command` delegates after plan build (unit tests).
    test_commander: ?transport_common.Commander = null,
    /// Production dial mode. `newClient` sets `.native`.
    dial_mode: DialMode = .native,
    /// Back-compat: when `false`, forces `plan_only` regardless of `dial_mode`.
    /// Prefer setting `dial_mode` for new code. Default `true` so production
    /// native/system paths are not blocked.
    use_system_ssh: bool = true,
    /// Last built plan (owned by runner; replaced each command).
    last_plan: ?CommandPlan = null,
    /// Owned PlanCommands when not using system ssh / test_commander.
    owned_cmds: std.ArrayListUnmanaged(*PlanCommand) = .empty,
    owned_host_cmds: std.ArrayListUnmanaged(*HostCommand) = .empty,
    owned_native_cmds: std.ArrayListUnmanaged(*native_ssh.NativeCommand) = .empty,
    last_auth_name: []const u8 = "",
    /// When set, `command` uses full SSH `clientConfig` (takes precedence).
    ssh_auth: ?auth_mod.AuthMethod = null,
    environ: std.process.Environ = std.process.Environ.empty,

    pub fn init(allocator: Allocator, options: ClientOptions) Runner {
        return .{
            .allocator = allocator,
            .io = singleThreadedIo(),
            .options = options,
            .dial_mode = .native,
        };
    }

    /// Effective dial mode: `use_system_ssh=false` forces plan_only (unit tests).
    pub fn effectiveDialMode(self: *const Runner) DialMode {
        if (!self.use_system_ssh) return .plan_only;
        return self.dial_mode;
    }

    pub fn deinit(self: *Runner) void {
        if (self.last_plan) |*p| p.deinit();
        self.last_plan = null;
        for (self.owned_cmds.items) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
        self.owned_cmds.deinit(self.allocator);
        for (self.owned_host_cmds.items) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
        self.owned_host_cmds.deinit(self.allocator);
        for (self.owned_native_cmds.items) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
        self.owned_native_cmds.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn asCommander(self: *Runner) transport_common.Commander {
        return transport_common.Commander.from(Runner, self);
    }

    /// go-git `runner.Command`.
    pub fn command(
        self: *Runner,
        cmd: []const u8,
        ep: *const Endpoint,
        auth: ?transport.AuthMethod,
    ) anyerror!transport_common.Command {
        if (ep.proxy.url.len != 0) try ep.proxy.validate();
        var cfg = auth_mod.ClientConfig{};
        var auth_name: []const u8 = "";
        // Owned user snapshot when default agent auth resolves USER from environ.
        var owned_user: ?[]u8 = null;
        errdefer if (owned_user) |u| self.allocator.free(u);

        if (self.ssh_auth) |sa| {
            if (auth) |a| {
                if (!isSshAuthMethod(a)) return transport.Error.InvalidAuthMethod;
            }
            cfg = try sa.clientConfig(self.allocator);
            auth_name = sa.name();
        } else if (auth) |a| {
            if (!isSshAuthMethod(a)) return transport.Error.InvalidAuthMethod;
            auth_name = a.name();
            cfg = try clientConfigFromTransport(a, self.allocator);
        } else {
            // Default: SSH agent (go-git DefaultAuthBuilder). Snapshot only
            // stable fields — system ssh uses ambient SSH_AUTH_SOCK; do not
            // retain pointers into the temporary PublicKeysCallback.
            var agent = try DefaultAuthBuilder(self.allocator, ep.user, self.environ);
            defer agent.deinit();
            const user_src = if (agent.user.len > 0) agent.user else auth_mod.DefaultUsername;
            owned_user = try self.allocator.dupe(u8, user_src);
            cfg = .{
                .user = owned_user.?,
                .auth_kind = .public_keys_callback,
                // Signers callback is not kept: system ssh talks to the agent.
                // Agent sock path is not required for dial; ambient env is used.
                .agent_sock = "",
            };
            auth_name = auth_mod.PublicKeysCallbackName;
        }

        overrideConfig(&self.options, &cfg);

        if (cfg.host_key_callback == null and self.options.insecure_ignore_host_key) {
            cfg.host_key_callback = auth_mod.HostKeyCallback.insecureIgnoreHostKey();
        }

        // buildPlan always takes ownership of owned_user (frees on error).
        const user_for_plan = owned_user;
        owned_user = null;
        var plan = try self.buildPlan(cmd, ep, &cfg, auth_name, user_for_plan);
        errdefer plan.deinit();

        if (self.last_plan) |*old| old.deinit();
        self.last_plan = try clonePlan(self.allocator, &plan);
        self.last_auth_name = auth_name;

        if (self.test_commander) |tc| {
            plan.deinit();
            return tc.command(cmd, ep, auth);
        }

        switch (self.effectiveDialMode()) {
            .plan_only => {
                const pc = try self.allocator.create(PlanCommand);
                errdefer self.allocator.destroy(pc);
                pc.* = .{
                    .allocator = self.allocator,
                    .plan = plan,
                };
                plan = .{ .allocator = self.allocator }; // moved; disarm errdefer plan.deinit
                errdefer pc.deinit();
                try self.owned_cmds.append(self.allocator, pc);
                return pc.asCommand();
            },
            .native => {
                const nc = try self.allocator.create(native_ssh.NativeCommand);
                errdefer self.allocator.destroy(nc);
                // Move plan fields into NativeDialParams (owned host/user/command).
                const params = planToNativeParams(self.allocator, &plan);
                plan = .{ .allocator = self.allocator }; // transferred; disarm errdefer
                nc.* = .{
                    .allocator = self.allocator,
                    .io = self.io,
                    .params = params,
                };
                errdefer nc.deinit();
                try self.owned_native_cmds.append(self.allocator, nc);
                return nc.asCommand();
            },
            .system_ssh => {
                if (plan.proxy_url.len != 0) return Error.ProxyUnsupported;
                // Miss: leave `plan` to outer errdefer.
                const bin_opt = try lookPath(self.allocator, self.io, "ssh");
                const bin_owned = bin_opt orelse return Error.SshBinaryNotFound;

                const hc = self.allocator.create(HostCommand) catch |err| {
                    self.allocator.free(bin_owned);
                    return err;
                };
                hc.* = .{
                    .allocator = self.allocator,
                    .io = self.io,
                    .plan = plan,
                    .ssh_bin = bin_owned,
                };
                plan = .{ .allocator = self.allocator }; // moved into hc
                self.owned_host_cmds.append(self.allocator, hc) catch |err| {
                    hc.deinit(); // plan + ssh_bin + temp identity
                    self.allocator.destroy(hc);
                    return err;
                };
                return hc.asCommand();
            },
        }
    }

    /// Transfer owned plan fields into native dial params; free argv / identity leftovers.
    ///
    /// After return, `plan` only retains the allocator (safe for `deinit`).
    /// `client_config` credential slices remain borrowed from caller auth.
    fn planToNativeParams(allocator: Allocator, plan: *CommandPlan) native_ssh.NativeDialParams {
        // Free fields native dial does not need (system-ssh argv / identity path).
        for (plan.ssh_args) |a| allocator.free(a);
        if (plan.ssh_args.len > 0) allocator.free(plan.ssh_args);
        plan.ssh_args = &.{};

        if (plan.identity_path.len > 0) {
            allocator.free(plan.identity_path);
            plan.identity_path = &.{};
        }

        const remote = plan.remote_command;
        const host_port = plan.host_with_port;
        const owned_host = plan.owned_host;
        const host = plan.host;
        const owned_user = plan.owned_user;
        const port = plan.port;
        const user = plan.user;
        const insecure = plan.insecure_ignore_host_key;
        const proxy_url = plan.proxy_url;
        var cfg = plan.client_config;
        if (owned_user) |u| cfg.user = u;
        cfg.identity_file = "";

        // Prevent plan.deinit from double-freeing transferred fields.
        plan.remote_command = &.{};
        plan.host_with_port = &.{};
        plan.owned_host = null;
        plan.host = "";
        plan.owned_user = null;
        plan.user = "";
        plan.client_config = .{};
        plan.proxy_url = &.{};

        return .{
            .allocator = allocator,
            .remote_command = remote,
            .host_with_port = host_port,
            .owned_host = owned_host,
            .host = host,
            .port = port,
            .user = user,
            .owned_user = owned_user,
            .insecure_ignore_host_key = insecure,
            .client_config = cfg,
            .proxy_url = proxy_url,
        };
    }

    fn buildPlan(
        self: *Runner,
        cmd: []const u8,
        ep: *const Endpoint,
        cfg: *const auth_mod.ClientConfig,
        auth_name: []const u8,
        owned_user_in: ?[]u8,
    ) !CommandPlan {
        // Single errdefer owns all heap fields. Take owned_user_in immediately
        // so error paths never leak the caller's snapshot.
        var draft: CommandPlan = .{ .allocator = self.allocator };
        draft.owned_user = owned_user_in;
        if (owned_user_in) |u| draft.user = u;
        errdefer draft.deinit();

        draft.remote_command = try endpointToCommand(self.allocator, cmd, ep);
        draft.host_with_port = try getHostWithPort(self.allocator, ep, default_ssh_config);

        // Always own host so Command/plan outlives the Endpoint pointer.
        const host_owned = try self.allocator.dupe(u8, ep.host);
        draft.owned_host = host_owned;
        draft.host = host_owned;

        var port = ep.port;
        if (port <= 0) port = DefaultPort;
        if (parsePortFromHostPort(draft.host_with_port)) |p| {
            port = p;
        }
        draft.port = port;

        // Always own user (agent path may already provide owned_user_in).
        if (draft.owned_user == null) {
            const u = try self.allocator.dupe(u8, effectiveUser(ep, cfg, &self.options));
            draft.owned_user = u;
            draft.user = u;
        }

        draft.insecure_ignore_host_key = self.options.insecure_ignore_host_key or
            (cfg.host_key_callback != null and isInsecureCallback(cfg.host_key_callback.?));

        if (ep.proxy.url.len != 0) {
            draft.proxy_url = try ep.proxy.fullURL(self.allocator);
        }

        if (cfg.identity_file.len > 0) {
            draft.identity_path = try self.allocator.dupe(u8, cfg.identity_file);
        }

        // Stable client_config: borrowed credential slices need caller-owned auth.
        var plan_cfg = cfg.*;
        plan_cfg.user = draft.user;
        plan_cfg.identity_file = if (draft.identity_path.len > 0) draft.identity_path else cfg.identity_file;
        plan_cfg.key_type = cfg.key_type;
        draft.auth_name = auth_name;
        draft.auth_kind = cfg.auth_kind;
        draft.key_type = cfg.key_type;
        draft.client_config = plan_cfg;

        const full_argv = try buildSshArgv(
            self.allocator,
            &draft,
            if (draft.identity_path.len > 0) draft.identity_path else null,
        );
        defer freeSshArgv(self.allocator, full_argv);

        var args_list: std.ArrayList([]u8) = .empty;
        errdefer {
            for (args_list.items) |a| self.allocator.free(a);
            args_list.deinit(self.allocator);
        }
        // Skip "ssh" binary name for plan.ssh_args (historical layout).
        for (full_argv[1..]) |a| {
            try args_list.append(self.allocator, try self.allocator.dupe(u8, a));
        }
        draft.ssh_args = try args_list.toOwnedSlice(self.allocator);

        // Success: transfer draft out without errdefer deinit.
        const out = draft;
        draft = .{ .allocator = self.allocator };
        return out;
    }
};

/// Parse port from `host:port` or `[ipv6]:port`. Returns null if not parseable.
fn parsePortFromHostPort(host_port: []const u8) ?i32 {
    if (host_port.len == 0) return null;
    // Prefer `]:port` for IPv6 bracket form.
    if (std.mem.lastIndexOfScalar(u8, host_port, ']')) |rb| {
        if (rb + 1 < host_port.len and host_port[rb + 1] == ':') {
            return std.fmt.parseInt(i32, host_port[rb + 2 ..], 10) catch null;
        }
        return null;
    }
    if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |idx| {
        return std.fmt.parseInt(i32, host_port[idx + 1 ..], 10) catch null;
    }
    return null;
}

fn isInsecureCallback(cb: auth_mod.HostKeyCallback) bool {
    // Heuristic: compare function pointer to insecureIgnoreHostKey.
    const insecure = auth_mod.HostKeyCallback.insecureIgnoreHostKey();
    return cb.check_fn == insecure.check_fn;
}

fn clientConfigFromTransport(auth: transport.AuthMethod, allocator: Allocator) !auth_mod.ClientConfig {
    const credentials = auth.protocolCredentials("ssh") orelse
        return transport.Error.InvalidAuthMethod;
    const name = auth.name();
    if (std.mem.eql(u8, name, auth_mod.PasswordName)) {
        const value: *auth_mod.Password = @ptrCast(@alignCast(credentials));
        return value.clientConfig(allocator);
    }
    if (std.mem.eql(u8, name, auth_mod.PasswordCallbackName)) {
        const value: *auth_mod.PasswordCallback = @ptrCast(@alignCast(credentials));
        return value.clientConfig(allocator);
    }
    if (std.mem.eql(u8, name, auth_mod.KeyboardInteractiveName)) {
        const value: *auth_mod.KeyboardInteractive = @ptrCast(@alignCast(credentials));
        return value.clientConfig(allocator);
    }
    if (std.mem.eql(u8, name, auth_mod.PublicKeysName)) {
        const value: *auth_mod.PublicKeys = @ptrCast(@alignCast(credentials));
        return value.clientConfig(allocator);
    }
    if (std.mem.eql(u8, name, auth_mod.PublicKeysCallbackName)) {
        const value: *auth_mod.PublicKeysCallback = @ptrCast(@alignCast(credentials));
        return value.clientConfig(allocator);
    }
    return transport.Error.InvalidAuthMethod;
}

fn clonePlan(allocator: Allocator, src: *const CommandPlan) Allocator.Error!CommandPlan {
    var out: CommandPlan = .{ .allocator = allocator };
    errdefer out.deinit();

    out.remote_command = try allocator.dupe(u8, src.remote_command);
    out.host_with_port = try allocator.dupe(u8, src.host_with_port);

    // Always own host in the clone (src.host may view src.owned_host).
    const host_src = if (src.owned_host) |h| h else src.host;
    if (host_src.len > 0) {
        const h = try allocator.dupe(u8, host_src);
        out.owned_host = h;
        out.host = h;
    }

    var args: std.ArrayList([]u8) = .empty;
    errdefer {
        for (args.items) |a| allocator.free(a);
        args.deinit(allocator);
    }
    for (src.ssh_args) |a| {
        try args.append(allocator, try allocator.dupe(u8, a));
    }

    if (src.identity_path.len > 0) {
        out.identity_path = try allocator.dupe(u8, src.identity_path);
    }
    if (src.proxy_url.len > 0) {
        out.proxy_url = try allocator.dupe(u8, src.proxy_url);
    }

    // Always snapshot user into owned_user for last_plan independence.
    const user_src = if (src.owned_user) |u| u else src.user;
    if (user_src.len > 0) {
        const u = try allocator.dupe(u8, user_src);
        out.owned_user = u;
        out.user = u;
    }

    var cfg = src.client_config;
    if (out.owned_user) |u| cfg.user = u;
    if (out.identity_path.len > 0) cfg.identity_file = out.identity_path;

    out.port = src.port;
    out.auth_name = src.auth_name;
    out.auth_kind = src.auth_kind;
    out.ssh_args = try args.toOwnedSlice(allocator);
    out.key_type = src.key_type;
    out.insecure_ignore_host_key = src.insecure_ignore_host_key;
    out.client_config = cfg;

    const result = out;
    out = .{ .allocator = allocator }; // disarm errdefer
    return result;
}

/// Apply ClientOptions onto auth ClientConfig (go-git `overrideConfig` subset).
pub fn overrideConfig(options: *const ClientOptions, cfg: *auth_mod.ClientConfig) void {
    if (options.user.len > 0) cfg.user = options.user;
    if (options.host_key_callback) |cb| cfg.host_key_callback = cb;
    if (options.host_key_algorithms.len > 0) cfg.host_key_algorithms = options.host_key_algorithms;
}

// ---------------------------------------------------------------------------
// Client (go-git NewClient / DefaultClient)
// ---------------------------------------------------------------------------

/// SSH transport client wrapping `transport_common.Client` + owned `Runner`.
pub const Client = struct {
    allocator: Allocator,
    runner: *Runner,
    inner: transport_common.Client,

    pub fn deinit(self: *Client) void {
        self.runner.deinit();
        self.allocator.destroy(self.runner);
        self.* = undefined;
    }

    pub fn newUploadPackSession(
        self: *Client,
        ep: *const Endpoint,
        auth: ?transport.AuthMethod,
    ) !transport_common.Session {
        return self.inner.newUploadPackSession(ep, auth);
    }

    pub fn newReceivePackSession(
        self: *Client,
        ep: *const Endpoint,
        auth: ?transport.AuthMethod,
    ) !transport_common.Session {
        return self.inner.newReceivePackSession(ep, auth);
    }

    pub fn asTransport(self: *Client) transport.Transport {
        return self.inner.asTransport();
    }

    /// Access underlying runner (plans / test hooks).
    pub fn getRunner(self: *Client) *Runner {
        return self.runner;
    }
};

/// go-git `NewClient` — pure-Zig native SSH dial by default.
pub fn newClient(allocator: Allocator, options: ?ClientOptions) Allocator.Error!Client {
    const runner = try allocator.create(Runner);
    errdefer allocator.destroy(runner);
    runner.* = Runner.init(allocator, options orelse .{});
    runner.dial_mode = .native;
    runner.use_system_ssh = true; // do not force plan_only; dial_mode selects path
    return .{
        .allocator = allocator,
        .runner = runner,
        .inner = transport_common.newClient(allocator, runner.asCommander()),
    };
}

/// Create a client that spawns system `ssh` (HostCommand path).
pub fn newClientSystemSsh(allocator: Allocator, options: ?ClientOptions) Allocator.Error!Client {
    var c = try newClient(allocator, options);
    c.runner.dial_mode = .system_ssh;
    return c;
}

/// go-git `DefaultClient` factory (no config overrides).
pub fn defaultClient(allocator: Allocator) Allocator.Error!Client {
    return newClient(allocator, null);
}

/// Create a client with an injected test commander (mock Command path).
pub fn newClientWithCommander(
    allocator: Allocator,
    options: ?ClientOptions,
    test_commander: transport_common.Commander,
) Allocator.Error!Client {
    var c = try newClient(allocator, options);
    c.runner.test_commander = test_commander;
    return c;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "DefaultPort is 22" {
    try testing.expectEqual(@as(i32, 22), DefaultPort);
}

test "endpointToCommand plain path" {
    var ep = Endpoint{
        .allocator = testing.allocator,
        .path = @constCast("/repo.git"),
    };
    const s = try endpointToCommand(testing.allocator, "git-upload-pack", &ep);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("git-upload-pack '/repo.git'", s);
}

test "endpointToCommand quote injection" {
    var ep = Endpoint{
        .allocator = testing.allocator,
        .path = @constCast("/repo.git'; touch /tmp/x ; #"),
    };
    const s = try endpointToCommand(testing.allocator, "git-upload-pack", &ep);
    defer testing.allocator.free(s);
    // Path is single-quoted; embedded `'` becomes the `'\''` sequence so `;` is not
    // executed by a shell. Accept either POSIX form with full `'\''` or `\'` re-open.
    try testing.expect(std.mem.startsWith(u8, s, "git-upload-pack '"));
    try testing.expect(std.mem.indexOf(u8, s, "touch") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\\'") != null or std.mem.indexOf(u8, s, "'\\''") != null);
}

test "endpointToCommand bang escape" {
    var ep = Endpoint{
        .allocator = testing.allocator,
        .path = @constCast("/repo!.git"),
    };
    const s = try endpointToCommand(testing.allocator, "git-upload-pack", &ep);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("git-upload-pack '/repo'\\!'.git'", s);
}

test "endpointToCommand mixed quote and bang" {
    var ep = Endpoint{
        .allocator = testing.allocator,
        .path = @constCast("/a'b!c"),
    };
    const s = try endpointToCommand(testing.allocator, "git-upload-pack", &ep);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("git-upload-pack '/a'\\''b'\\!'c'", s);
}

test "endpointToCommand inert metacharacters" {
    var ep = Endpoint{
        .allocator = testing.allocator,
        .path = @constCast("/a\\b\"c$d`e"),
    };
    const s = try endpointToCommand(testing.allocator, "git-upload-pack", &ep);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("git-upload-pack '/a\\b\"c$d`e'", s);
}

test "getHostWithPort default port" {
    var ep = Endpoint{
        .allocator = testing.allocator,
        .host = @constCast("github.com"),
        .port = 0,
    };
    const s = try getHostWithPort(testing.allocator, &ep, null);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("github.com:22", s);
}

test "getHostWithPort custom port" {
    var ep = Endpoint{
        .allocator = testing.allocator,
        .host = @constCast("github.com"),
        .port = 2222,
    };
    const s = try getHostWithPort(testing.allocator, &ep, null);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("github.com:2222", s);
}

test "getHostWithPort from ssh_config" {
    const MockCfg = struct {
        fn get(_: *@This(), _: []const u8, key: []const u8) []const u8 {
            if (std.mem.eql(u8, key, "Hostname")) return "foo.local";
            if (std.mem.eql(u8, key, "Port")) return "42";
            return "";
        }
    };
    var mock = MockCfg{};
    const cfg = SshConfig.from(MockCfg, &mock);

    var ep = Endpoint{
        .allocator = testing.allocator,
        .host = @constCast("github.com"),
        .port = 0,
    };
    const s = try getHostWithPort(testing.allocator, &ep, cfg);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("foo.local:42", s);
}

test "runner rejects non-ssh auth" {
    const BadAuth = struct {
        fn nameFn(_: *anyopaque) []const u8 {
            return "http-basic";
        }
        fn formatFn(_: *anyopaque, allocator: Allocator) Allocator.Error![]u8 {
            return allocator.dupe(u8, "http-basic");
        }
        const vtable = transport.AuthMethod.VTable{
            .name = nameFn,
            .format = formatFn,
        };
    };
    var dummy: u8 = 0;
    const bad = transport.AuthMethod{ .ptr = &dummy, .vtable = &BadAuth.vtable };

    var runner = Runner.init(testing.allocator, .{});
    defer runner.deinit();

    var ep = Endpoint{
        .allocator = testing.allocator,
        .host = @constCast("example.com"),
        .path = @constCast("/repo.git"),
        .user = @constCast("git"),
    };

    const result = runner.command("git-upload-pack", &ep, bad);
    try testing.expectError(transport.Error.InvalidAuthMethod, result);
}

test "runner builds plan with password auth" {
    var runner = Runner.init(testing.allocator, .{});
    defer runner.deinit();
    runner.use_system_ssh = false;

    var pw = auth_mod.Password{ .user = "git", .password = "s3cr3t" };
    runner.ssh_auth = pw.asAuthMethod();
    const auth = pw.asTransportAuth();

    var ep = Endpoint{
        .allocator = testing.allocator,
        .host = @constCast("example.com"),
        .path = @constCast("/repo.git"),
        .user = @constCast("git"),
        .port = 0,
    };

    const cmd = try runner.command("git-upload-pack", &ep, auth);
    _ = cmd;

    const plan = runner.last_plan orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("git-upload-pack '/repo.git'", plan.remote_command);
    try testing.expectEqualStrings("example.com:22", plan.host_with_port);
    try testing.expectEqualStrings(auth_mod.PasswordName, plan.auth_name);
    try testing.expect(plan.auth_kind == .password);
    try testing.expectEqualStrings("s3cr3t", plan.client_config.password);
    try testing.expectEqual(@as(i32, 22), plan.port);
    try testing.expectEqualStrings("git", plan.user);
    // ssh_args: -p 22 -l git example.com remote
    try testing.expect(plan.ssh_args.len >= 6);
}

test "transport password auth carries credentials without runner override" {
    var runner = Runner.init(testing.allocator, .{});
    defer runner.deinit();
    runner.use_system_ssh = false;
    var password = auth_mod.Password{ .user = "remote-user", .password = "remote-secret" };
    var ep = Endpoint{
        .allocator = testing.allocator,
        .host = @constCast("example.com"),
        .path = @constCast("/repo.git"),
    };

    _ = try runner.command("git-upload-pack", &ep, password.asTransportAuth());
    const plan = runner.last_plan orelse return error.TestUnexpectedResult;
    try testing.expect(plan.auth_kind == .password);
    try testing.expectEqualStrings("remote-user", plan.user);
    try testing.expectEqualStrings("remote-secret", plan.client_config.password);
}

test "buildSshArgv basic" {
    var plan = CommandPlan{
        .allocator = testing.allocator,
        .remote_command = try testing.allocator.dupe(u8, "git-upload-pack '/r.git'"),
        .host_with_port = try testing.allocator.dupe(u8, "h:22"),
        .host = "example.com",
        .port = 22,
        .user = "git",
    };
    defer plan.deinit();

    const argv = try buildSshArgv(testing.allocator, &plan, null);
    defer freeSshArgv(testing.allocator, argv);
    try testing.expectEqualStrings("ssh", argv[0]);
    try testing.expectEqualStrings("-p", argv[1]);
    try testing.expectEqualStrings("22", argv[2]);
    try testing.expectEqualStrings("-l", argv[3]);
    try testing.expectEqualStrings("git", argv[4]);
    try testing.expectEqualStrings("example.com", argv[5]);
    try testing.expectEqualStrings("git-upload-pack '/r.git'", argv[6]);
}

test "buildSshArgv identity and insecure" {
    var plan = CommandPlan{
        .allocator = testing.allocator,
        .remote_command = try testing.allocator.dupe(u8, "cmd"),
        .host_with_port = try testing.allocator.dupe(u8, "h:2222"),
        .host = "h",
        .port = 2222,
        .user = "u",
        .insecure_ignore_host_key = true,
    };
    defer plan.deinit();

    const argv = try buildSshArgv(testing.allocator, &plan, "/home/u/.ssh/id_ed25519");
    defer freeSshArgv(testing.allocator, argv);

    try testing.expectEqualStrings("ssh", argv[0]);
    // Find -i and StrictHostKeyChecking
    var saw_i = false;
    var saw_strict = false;
    for (argv, 0..) |a, i| {
        if (std.mem.eql(u8, a, "-i") and i + 1 < argv.len) {
            try testing.expectEqualStrings("/home/u/.ssh/id_ed25519", argv[i + 1]);
            saw_i = true;
        }
        if (std.mem.eql(u8, a, "StrictHostKeyChecking=no")) saw_strict = true;
    }
    try testing.expect(saw_i);
    try testing.expect(saw_strict);
}

test "runner with mock commander" {
    var mock = transport_common.MockCommander.init(testing.allocator);
    defer mock.deinit();

    var runner = Runner.init(testing.allocator, .{});
    defer runner.deinit();
    runner.test_commander = mock.asCommander();

    var pw = auth_mod.Password{ .user = "u", .password = "p" };
    var ep = Endpoint{
        .allocator = testing.allocator,
        .host = @constCast("h"),
        .path = @constCast("/r"),
        .user = @constCast("u"),
    };

    const cmd = try runner.command("git-upload-pack", &ep, pw.asTransportAuth());
    try cmd.start();
    try testing.expect(mock.last != null);
    try testing.expect(mock.last.?.started);
}

test "newClient and defaultClient" {
    var c = try newClient(testing.allocator, .{ .insecure_ignore_host_key = true });
    defer c.deinit();
    try testing.expect(c.getRunner().options.insecure_ignore_host_key);

    var d = try defaultClient(testing.allocator);
    defer d.deinit();
    _ = d.getRunner();
}

test "ClientOptions override user" {
    var opts = ClientOptions{ .user = "override" };
    var cfg = auth_mod.ClientConfig{ .user = "from-auth" };
    overrideConfig(&opts, &cfg);
    try testing.expectEqualStrings("override", cfg.user);
}

test "isSshAuthMethod" {
    var pw = auth_mod.Password{ .user = "x" };
    try testing.expect(isSshAuthMethod(pw.asTransportAuth()));
}

test "effectiveUser preference order" {
    var ep = Endpoint{
        .allocator = testing.allocator,
        .user = @constCast("from-ep"),
    };
    const cfg = auth_mod.ClientConfig{ .user = "from-cfg" };
    const opts_empty = ClientOptions{};
    try testing.expectEqualStrings("from-cfg", effectiveUser(&ep, &cfg, &opts_empty));

    const opts_override = ClientOptions{ .user = "from-opts" };
    try testing.expectEqualStrings("from-opts", effectiveUser(&ep, &cfg, &opts_override));

    const cfg_empty = auth_mod.ClientConfig{};
    try testing.expectEqualStrings("from-ep", effectiveUser(&ep, &cfg_empty, &opts_empty));

    var ep2 = Endpoint{ .allocator = testing.allocator };
    try testing.expectEqualStrings(auth_mod.DefaultUsername, effectiveUser(&ep2, &cfg_empty, &opts_empty));
}

test "newClientWithCommander builds plan and uses mock" {
    var mock = transport_common.MockCommander.init(testing.allocator);
    defer mock.deinit();

    var c = try newClientWithCommander(testing.allocator, .{}, mock.asCommander());
    defer c.deinit();

    var pw = auth_mod.Password{ .user = "git", .password = "x" };
    c.getRunner().ssh_auth = pw.asAuthMethod();

    var ep = Endpoint{
        .allocator = testing.allocator,
        .host = @constCast("h.example"),
        .path = @constCast("/r.git"),
        .user = @constCast("git"),
        .port = 22,
    };

    // Exercise runner via commander path (does not open a full pack session).
    const cmd = try c.getRunner().command("git-upload-pack", &ep, pw.asTransportAuth());
    try cmd.start();
    try testing.expect(mock.last != null);

    const plan = c.getRunner().last_plan orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("h.example:22", plan.host_with_port);
}

test "parsePortFromHostPort ipv4 and ipv6" {
    try testing.expectEqual(@as(i32, 22), parsePortFromHostPort("github.com:22").?);
    try testing.expectEqual(@as(i32, 2222), parsePortFromHostPort("[::1]:2222").?);
    try testing.expect(parsePortFromHostPort("no-port") == null);
}

test "runner PlanCommand when use_system_ssh false" {
    var runner = Runner.init(testing.allocator, .{});
    defer runner.deinit();
    runner.use_system_ssh = false;

    var pw = auth_mod.Password{ .user = "git", .password = "p" };
    runner.ssh_auth = pw.asAuthMethod();

    var ep = Endpoint{
        .allocator = testing.allocator,
        .host = @constCast("example.com"),
        .path = @constCast("/r.git"),
        .user = @constCast("git"),
    };

    const cmd = try runner.command("git-upload-pack", &ep, pw.asTransportAuth());
    try cmd.start();
    try testing.expectEqual(@as(usize, 1), runner.owned_cmds.items.len);
    try testing.expectEqual(@as(usize, 0), runner.owned_host_cmds.items.len);
}

test "runner PublicKeys identity_file and key_type on plan" {
    var runner = Runner.init(testing.allocator, .{});
    defer runner.deinit();
    runner.use_system_ssh = false;

    const pem =
        \\-----BEGIN RSA PRIVATE KEY-----
        \\AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4v
        \\MDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5f
        \\-----END RSA PRIVATE KEY-----
    ;
    var pk = try auth_mod.newPublicKeys(testing.allocator, "git", pem, "");
    defer pk.deinit();
    // Simulate path-backed identity (from-file) without touching the FS again.
    const id_path = try testing.allocator.dupe(u8, "/home/git/.ssh/id_rsa");
    pk.owned_identity_path = id_path;
    pk.identity_path = id_path;

    runner.ssh_auth = pk.asAuthMethod();

    var ep = Endpoint{
        .allocator = testing.allocator,
        .host = @constCast("example.com"),
        .path = @constCast("/r.git"),
        .user = @constCast("git"),
    };

    _ = try runner.command("git-upload-pack", &ep, pk.asTransportAuth());
    const plan = runner.last_plan orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("/home/git/.ssh/id_rsa", plan.identity_path);
    try testing.expectEqualStrings("ssh-rsa", plan.key_type);
    try testing.expectEqualStrings("ssh-rsa", plan.client_config.key_type);
    // ssh_args must include -i path
    var saw_i = false;
    for (plan.ssh_args, 0..) |a, i| {
        if (std.mem.eql(u8, a, "-i") and i + 1 < plan.ssh_args.len) {
            try testing.expectEqualStrings("/home/git/.ssh/id_rsa", plan.ssh_args[i + 1]);
            saw_i = true;
        }
    }
    try testing.expect(saw_i);
}

test "runner default agent auth snapshots user without UAF" {
    var runner = Runner.init(testing.allocator, .{});
    defer runner.deinit();
    runner.use_system_ssh = false;

    const gpa = testing.allocator;
    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();
    try map.put("SSH_AUTH_SOCK", "/tmp/gitz-test-agent.sock");
    try map.put("USER", "agentuser");
    const environ: std.process.Environ = .{ .block = try map.createPosixBlock(gpa, .{}) };
    defer environ.block.deinit(gpa);
    runner.environ = environ;

    var ep = Endpoint{
        .allocator = testing.allocator,
        .host = @constCast("example.com"),
        .path = @constCast("/r.git"),
        // empty endpoint user → agent resolves USER
        .user = @constCast(""),
    };

    _ = try runner.command("git-upload-pack", &ep, null);
    const plan = runner.last_plan orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("agentuser", plan.user);
    try testing.expect(plan.owned_user != null);
    try testing.expect(plan.auth_kind == .public_keys_callback);
    try testing.expectEqualStrings(auth_mod.PublicKeysCallbackName, plan.auth_name);
}

test "freeSshArgv frees all elements" {
    var plan = CommandPlan{
        .allocator = testing.allocator,
        .remote_command = try testing.allocator.dupe(u8, "cmd"),
        .host_with_port = try testing.allocator.dupe(u8, "h:22"),
        .host = "h",
        .port = 22,
        .user = "u",
    };
    defer plan.deinit();
    const argv = try buildSshArgv(testing.allocator, &plan, "/id");
    // Must not leak under testing allocator.
    freeSshArgv(testing.allocator, argv);
}

test "joinHostPort ipv6 brackets" {
    const s = try joinHostPort(testing.allocator, "::1", 22);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("[::1]:22", s);
}

test "effectiveDialMode plan_only from use_system_ssh false" {
    var runner = Runner.init(testing.allocator, .{});
    defer runner.deinit();
    runner.dial_mode = .native;
    runner.use_system_ssh = false;
    try testing.expect(runner.effectiveDialMode() == .plan_only);
}

test "effectiveDialMode native default" {
    var runner = Runner.init(testing.allocator, .{});
    defer runner.deinit();
    try testing.expect(runner.effectiveDialMode() == .native);
}

test "SSH endpoint SOCKS5 proxy is preserved in native command plan" {
    const allocator = testing.allocator;
    var runner = Runner.init(allocator, .{});
    defer runner.deinit();
    var ep = try transport.newEndpoint(allocator, testing.io, "ssh://git@example.com/repo.git");
    defer ep.deinit();
    ep.proxy = .{ .url = "socks5://127.0.0.1:1080" };
    var password = auth_mod.Password{ .user = "git", .password = "secret" };
    runner.ssh_auth = password.asAuthMethod();
    runner.use_system_ssh = false;
    _ = try runner.command("git-upload-pack", &ep, null);
    const plan = runner.last_plan orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("socks5://127.0.0.1:1080/", plan.proxy_url);
}

test "system SSH rejects proxy instead of dialing around it" {
    const allocator = testing.allocator;
    var runner = Runner.init(allocator, .{});
    defer runner.deinit();
    runner.dial_mode = .system_ssh;
    var password = auth_mod.Password{ .user = "git", .password = "secret" };
    runner.ssh_auth = password.asAuthMethod();
    var ep = try transport.newEndpoint(allocator, testing.io, "ssh://git@example.com/repo.git");
    defer ep.deinit();
    ep.proxy = .{ .url = "socks5://127.0.0.1:1080" };
    try testing.expectError(Error.ProxyUnsupported, runner.command("git-upload-pack", &ep, null));
}

test "newClient defaults to native dial mode" {
    var c = try newClient(testing.allocator, null);
    defer c.deinit();
    try testing.expect(c.getRunner().dial_mode == .native);
    try testing.expect(c.getRunner().use_system_ssh);
}

test "runner native dial closed port returns connect error" {
    var runner = Runner.init(testing.allocator, .{ .insecure_ignore_host_key = true });
    defer runner.deinit();
    runner.dial_mode = .native;
    runner.use_system_ssh = true;

    var pw = auth_mod.Password{ .user = "git", .password = "x" };
    runner.ssh_auth = pw.asAuthMethod();

    var ep = Endpoint{
        .allocator = testing.allocator,
        .host = @constCast("127.0.0.1"),
        .path = @constCast("/r.git"),
        .user = @constCast("git"),
        .port = 1,
    };

    const cmd = try runner.command("git-upload-pack", &ep, pw.asTransportAuth());
    try testing.expectEqual(@as(usize, 1), runner.owned_native_cmds.items.len);
    const result = cmd.start();
    try testing.expectError(native_ssh.Error.SshConnectFailed, result);
}

test "plan owns host and user independent of Endpoint lifetime" {
    var runner = Runner.init(testing.allocator, .{});
    defer runner.deinit();
    runner.use_system_ssh = false;

    var pw = auth_mod.Password{ .user = "planuser", .password = "p" };
    runner.ssh_auth = pw.asAuthMethod();

    // Stack-local host buffer that will be overwritten after command().
    var host_buf = "example.com".*;
    var ep = Endpoint{
        .allocator = testing.allocator,
        .host = &host_buf,
        .path = @constCast("/r.git"),
        .user = @constCast("planuser"),
    };

    _ = try runner.command("git-upload-pack", &ep, pw.asTransportAuth());
    // Mutate original endpoint host storage — plan must keep its own copy.
    @memset(&host_buf, 'X');

    const plan = runner.last_plan orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("example.com", plan.host);
    try testing.expect(plan.owned_host != null);
    try testing.expectEqualStrings("planuser", plan.user);
    try testing.expect(plan.owned_user != null);
}

test "newClientSystemSsh sets system_ssh dial mode" {
    var c = try newClientSystemSsh(testing.allocator, null);
    defer c.deinit();
    try testing.expect(c.getRunner().dial_mode == .system_ssh);
    try testing.expect(c.getRunner().effectiveDialMode() == .system_ssh);
}
