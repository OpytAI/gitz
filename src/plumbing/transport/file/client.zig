//! File (local path) transport client
//! (go-git `plumbing/transport/file/client.go`).
//!
//! # Dual path (priority order)
//!
//! go-git always spawns host `git-upload-pack` / `git-receive-pack` via
//! LookPath + subprocess. gitz supports that path plus a hermetic in-process
//! path. `Runner.command` chooses exactly one path per call:
//!
//! 1. **Hermetic loader** — `loader != null` (`FileClient.setLoader`).
//!    Returns `LocalCommand` and serves advertise/pack in-process
//!    (MapLoader / FilesystemLoader). No LookPath, no host binary.
//! 2. **Host spawn** — `loader == null` and `use_host_spawn == true` (default).
//!    Resolves the service binary with `lookPath`, then go-git
//!    `prefixExecPath` (`git --exec-path` + join) on miss, then returns
//!    `HostCommand` (`std.process.spawn`, argv = `{ bin, path }`).
//! 3. **Unit dry** — `loader == null` and `use_host_spawn == false`.
//!    Returns `LocalCommand` without serve. Unit tests exercise Commander
//!    wiring without PATH binaries or subprocesses.
//!
//! Loader always wins while non-null. Clearing the loader restores path 2 or 3
//! from the current `use_host_spawn` flag. Auth is ignored on all paths
//! (go-git emptyAuth).
//!
//! For in-process remotes that do not need the Commander session path, use
//! `server.newClient` + MapLoader directly.

const std = @import("std");
const transport = @import("transport");
const common = @import("transport_common");
const server = @import("server");
const packp = @import("packp");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Endpoint = transport.Endpoint;
const AuthMethod = transport.AuthMethod;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Command = common.Command;
const Commander = common.Commander;
const WriteCloser = common.WriteCloser;
const Child = std.process.Child;
const Environ = std.process.Environ;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const Error = error{
    /// Binary label not configured / not found (go-git `LookPath` miss).
    CommandNotFound,
    /// Endpoint path empty or unusable for local serve.
    InvalidEndpoint,
};

const Service = enum { upload_pack, receive_pack };

/// Default PATH when environ has no PATH (Zig `Io.Threaded.default_PATH`).
pub const default_path: []const u8 = std.Io.Threaded.default_PATH;

// ---------------------------------------------------------------------------
// Io / environ helpers
// ---------------------------------------------------------------------------

fn singleThreadedIo() Io {
    const Holder = struct {
        threadlocal var threaded: Io.Threaded = .init_single_threaded;
        threadlocal var patched: bool = false;

        fn get() Io {
            if (!patched) {
                // init_single_threaded has empty environ on POSIX; attach libc
                // environ so host git sees a normal environment and PATH works.
                if (builtin.link_libc) {
                    if (std.c.environ) |c_environ| {
                        var n: usize = 0;
                        while (c_environ[n] != null) : (n += 1) {}
                        threaded.environ = .{
                            .process_environ = .{ .block = .{ .slice = c_environ[0..n :null] } },
                        };
                        threaded.environ_initialized = n == 0;
                    }
                }
                patched = true;
            }
            return threaded.io();
        }
    };
    return Holder.get();
}

fn processEnvironFromC() Environ {
    if (builtin.link_libc) {
        if (std.c.environ) |c_environ| {
            var n: usize = 0;
            while (c_environ[n] != null) : (n += 1) {}
            return .{ .block = .{ .slice = c_environ[0..n :null] } };
        }
    }
    return .empty;
}

fn defaultIo() Io {
    if (builtin.is_test) return std.testing.io;
    return singleThreadedIo();
}

fn defaultEnviron() Environ {
    if (builtin.is_test) return std.testing.environ;
    return processEnvironFromC();
}

// ---------------------------------------------------------------------------
// Windows path adjust (go-git `adjustPathForWindows`)
// ---------------------------------------------------------------------------

fn isDriveLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

/// On Windows, strip a leading `/` before a drive letter (`/C:/...` → `C:/...`).
/// On non-Windows, returns `p` unchanged.
pub fn adjustPathForWindows(p: []const u8) []const u8 {
    if (builtin.os.tag != .windows) return p;
    if (p.len >= 3 and p[0] == '/' and isDriveLetter(p[1]) and p[2] == ':') {
        return p[1..];
    }
    return p;
}

// ---------------------------------------------------------------------------
// lookPath (go-git `execabs.LookPath`)
// ---------------------------------------------------------------------------

fn pathHasSeparator(file: []const u8) bool {
    if (std.mem.indexOfScalar(u8, file, '/') != null) return true;
    if (builtin.os.tag == .windows and std.mem.indexOfScalar(u8, file, '\\') != null) return true;
    return false;
}

fn accessExecutable(io: Io, path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch {
            // Fall back to existence: some fixtures are not marked +x.
            try std.Io.Dir.accessAbsolute(io, path, .{});
        };
        return;
    }
    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch {
        try std.Io.Dir.cwd().access(io, path, .{});
    };
}

/// Resolve `file` to an existing path (absolute or relative).
///
/// - Absolute path or path with separator: check that file; return a dupe.
/// - Bare name: walk `PATH` from `environ` (then libc `PATH`, then
///   `default_path`); return an owned path for the first hit.
/// - PATH separator is platform-correct (`:` POSIX, `;` Windows).
/// - Empty PATH components are skipped (no cwd false-positive).
/// - Miss: `error.CommandNotFound` (go-git LookPath miss → Runner.Command error).
pub fn lookPath(
    allocator: Allocator,
    io: Io,
    environ: Environ,
    file: []const u8,
) (Error || Allocator.Error)![]u8 {
    if (file.len == 0) return Error.CommandNotFound;

    if (pathHasSeparator(file) or std.fs.path.isAbsolute(file)) {
        accessExecutable(io, file) catch return Error.CommandNotFound;
        return try allocator.dupe(u8, file);
    }

    const path_env: []const u8 = blk: {
        if (Environ.getPosix(environ, "PATH")) |p| {
            if (p.len > 0) break :blk p;
        }
        if (builtin.link_libc) {
            if (std.c.getenv("PATH")) |p| {
                const s = std.mem.span(p);
                if (s.len > 0) break :blk s;
            }
        }
        break :blk default_path;
    };

    var it = std.mem.tokenizeScalar(u8, path_env, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue; // skip empty; never treat as cwd
        const candidate = std.fs.path.join(allocator, &.{ dir, file }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer allocator.free(candidate);
        accessExecutable(io, candidate) catch continue;
        return try allocator.dupe(u8, candidate);
    }
    return Error.CommandNotFound;
}

/// go-git `prefixExecPath`: resolve `cmd` under `git --exec-path` when PATH
/// LookPath misses (e.g. `git-upload-pack` only in `/usr/lib/git-core`).
///
/// Spawns `git --exec-path`, reads one line, reaps the child, then joins the
/// path with `cmd` and re-checks via `lookPath`. Always reaps (wait, else kill)
/// so the temporary child never leaks.
fn prefixExecPath(
    allocator: Allocator,
    io: Io,
    environ: Environ,
    cmd: []const u8,
) (Error || Allocator.Error)![]u8 {
    const git_bin = lookPath(allocator, io, environ, "git") catch return Error.CommandNotFound;
    defer allocator.free(git_bin);

    var child = std.process.spawn(io, .{
        .argv = &.{ git_bin, "--exec-path" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return Error.CommandNotFound;
    // Reap on every exit: wait clears id and closes pipe FDs; kill if still live.
    defer if (child.id != null) child.kill(io);

    var line_buf: [512]u8 = undefined;
    var n: usize = 0;
    if (child.stdout) |out| {
        var file_buf: [256]u8 = undefined;
        var r = out.readerStreaming(io, &file_buf);
        while (n < line_buf.len) {
            const b = r.interface.takeByte() catch break;
            if (b == '\n' or b == '\r') break;
            line_buf[n] = b;
            n += 1;
        }
    }

    // Prefer wait (go-git Wait); defer kill only if wait never ran.
    if (child.id != null) _ = child.wait(io) catch {};

    var exec_path = line_buf[0..n];
    while (exec_path.len > 0) {
        const c = exec_path[exec_path.len - 1];
        if (c == ' ' or c == '\t') {
            exec_path = exec_path[0 .. exec_path.len - 1];
        } else break;
    }
    if (exec_path.len == 0) return Error.CommandNotFound;

    const candidate = try std.fs.path.join(allocator, &.{ exec_path, cmd });
    defer allocator.free(candidate);
    // lookPath on absolute/with-separator only access-checks and dupes.
    return lookPath(allocator, io, environ, candidate);
}

// ---------------------------------------------------------------------------
// LocalCommand — pipe-backed Command (hermetic / unit dry, no subprocess)
// ---------------------------------------------------------------------------

/// In-process command with stdio buffers; optional server-backed serve.
///
/// Used for dual-path cases 1 (loader hermetic) and 3 (unit dry).
/// Stdin close triggers the pack phase when a loader session is live.
pub const LocalCommand = struct {
    allocator: Allocator,
    service: Service,
    /// Owned endpoint clone used for loader lookup / path.
    endpoint: Endpoint,
    /// Borrowed loader from Runner (optional hermetic serve).
    loader: ?server.Loader = null,

    stdin_writer: Writer.Allocating = undefined,
    stdin_writer_live: bool = false,
    stdin_closed: bool = false,
    stdin_buf: std.ArrayList(u8) = .empty,

    stdout_buf: std.ArrayList(u8) = .empty,
    stdout_reader: Reader = undefined,

    stderr_buf: std.ArrayList(u8) = .empty,
    stderr_reader: Reader = undefined,

    started: bool = false,
    closed: bool = false,

    up_session: ?server.UploadPackSession = null,
    rp_session: ?server.ReceivePackSession = null,

    pub fn deinit(self: *LocalCommand) void {
        if (self.up_session) |*s| {
            s.close();
            self.up_session = null;
        }
        if (self.rp_session) |*s| {
            s.close();
            self.rp_session = null;
        }

        if (self.stdin_writer_live and !self.stdin_closed) {
            self.stdin_writer.deinit();
            self.stdin_writer_live = false;
            self.stdin_closed = true;
        }
        self.stdin_buf.deinit(self.allocator);
        self.stdout_buf.deinit(self.allocator);
        self.stderr_buf.deinit(self.allocator);
        self.endpoint.deinit();
        self.* = undefined;
    }

    pub fn asCommand(self: *LocalCommand) Command {
        return Command.from(LocalCommand, self);
    }

    pub fn stderrPipe(self: *LocalCommand) anyerror!*Reader {
        if (self.stderr_buf.items.len == 0) {
            self.stderr_reader = Reader.fixed(&.{});
        } else {
            self.stderr_reader = Reader.fixed(self.stderr_buf.items);
        }
        return &self.stderr_reader;
    }

    pub fn stdinPipe(self: *LocalCommand) anyerror!WriteCloser {
        // Idempotent: Session asks once; guard against double-init leaks.
        if (!self.stdin_writer_live) {
            if (self.stdin_closed) return error.CommandFailed;
            self.stdin_writer = Writer.Allocating.init(self.allocator);
            self.stdin_writer_live = true;
        }
        const gen = struct {
            fn closeFn(ptr: *anyopaque) anyerror!void {
                const s: *LocalCommand = @ptrCast(@alignCast(ptr));
                if (s.stdin_closed) return;
                const written = s.stdin_writer.written();
                try s.stdin_buf.appendSlice(s.allocator, written);
                s.stdin_writer.deinit();
                s.stdin_closed = true;
                s.stdin_writer_live = false;
                // Client closed stdin → run pack phase when serving.
                try s.onStdinClosed();
            }
        };
        return .{
            .ptr = self,
            .writer = &self.stdin_writer.writer,
            .close_fn = gen.closeFn,
        };
    }

    pub fn stdoutPipe(self: *LocalCommand) anyerror!*Reader {
        if (self.stdout_buf.items.len == 0) {
            self.stdout_reader = Reader.fixed(&.{});
        } else {
            self.stdout_reader = Reader.fixed(self.stdout_buf.items);
        }
        return &self.stdout_reader;
    }

    pub fn start(self: *LocalCommand) anyerror!void {
        if (self.started) return;
        self.started = true;

        const loader = self.loader orelse {
            // Dry path: empty pipes, no error (Commander wiring only).
            self.stdout_reader = Reader.fixed(&.{});
            self.stderr_reader = Reader.fixed(&.{});
            return;
        };

        var srv = server.newServer(self.allocator, loader);

        switch (self.service) {
            .upload_pack => {
                const sess = srv.newUploadPackSession(&self.endpoint, null) catch {
                    try self.writeRepoNotFound();
                    return;
                };
                self.up_session = sess;
                const ar = self.up_session.?.advertisedReferences() catch {
                    try self.writeRepoNotFound();
                    return;
                };
                defer packp.freeAdvRefs(self.allocator, ar);

                var aw: Writer.Allocating = .init(self.allocator);
                defer aw.deinit();
                try ar.encode(&aw.writer);
                try self.stdout_buf.appendSlice(self.allocator, aw.written());
                self.stdout_reader = Reader.fixed(self.stdout_buf.items);
            },
            .receive_pack => {
                const sess = srv.newReceivePackSession(&self.endpoint, null) catch {
                    try self.writeRepoNotFound();
                    return;
                };
                self.rp_session = sess;
                const ar = self.rp_session.?.advertisedReferences() catch {
                    try self.writeRepoNotFound();
                    return;
                };
                defer packp.freeAdvRefs(self.allocator, ar);

                var aw: Writer.Allocating = .init(self.allocator);
                defer aw.deinit();
                try ar.encode(&aw.writer);
                try self.stdout_buf.appendSlice(self.allocator, aw.written());
                self.stdout_reader = Reader.fixed(self.stdout_buf.items);
            },
        }
        self.stderr_reader = Reader.fixed(self.stderr_buf.items);
    }

    fn writeRepoNotFound(self: *LocalCommand) !void {
        // Phrase matches common.isRepoNotFoundError local_repo_not_found_err.
        try self.stderr_buf.appendSlice(
            self.allocator,
            "fatal: does not appear to be a git repository\n",
        );
        self.stderr_reader = Reader.fixed(self.stderr_buf.items);
        self.stdout_reader = Reader.fixed(&.{});
    }

    /// Extend stdout after advertise with pack / report-status (same *Reader).
    fn rebuildStdoutReaderPreservingSeek(self: *LocalCommand) void {
        const seek = self.stdout_reader.seek;
        self.stdout_reader = Reader.fixed(self.stdout_buf.items);
        if (seek <= self.stdout_buf.items.len) {
            self.stdout_reader.seek = seek;
        }
    }

    fn onStdinClosed(self: *LocalCommand) anyerror!void {
        if (self.loader == null) return;

        switch (self.service) {
            .upload_pack => {
                var sess = self.up_session orelse return;
                var req = packp.newUploadPackRequest(self.allocator);
                defer req.deinit();

                var stdin_r: Reader = .fixed(self.stdin_buf.items);
                // Match common.serveUploadPack: decode upload-request wants.
                try req.upload_request.decode(&stdin_r);

                const resp = try sess.uploadPack(&req);
                defer packp.freeUploadPackResponse(self.allocator, resp);

                var aw: Writer.Allocating = .init(self.allocator);
                defer aw.deinit();
                try resp.encode(&aw.writer);
                try self.stdout_buf.appendSlice(self.allocator, aw.written());
                self.rebuildStdoutReaderPreservingSeek();
            },
            .receive_pack => {
                var sess = self.rp_session orelse return;
                var req = try packp.newReferenceUpdateRequest(self.allocator);
                defer req.deinit();

                var stdin_r: Reader = .fixed(self.stdin_buf.items);
                try req.decode(&stdin_r);

                const out = try sess.receivePackOutcome(&req);
                defer if (out.report) |rs| packp.freeReportStatus(self.allocator, rs);

                if (out.report) |rs| {
                    var aw: Writer.Allocating = .init(self.allocator);
                    defer aw.deinit();
                    try rs.encode(&aw.writer);
                    try self.stdout_buf.appendSlice(self.allocator, aw.written());
                    self.rebuildStdoutReaderPreservingSeek();
                }
                if (out.err) |e| return e;
            },
        }
    }

    pub fn close(self: *LocalCommand) anyerror!void {
        if (self.closed) return;
        self.closed = true;
        if (self.up_session) |*s| {
            s.close();
            self.up_session = null;
        }
        if (self.rp_session) |*s| {
            s.close();
            self.rp_session = null;
        }
    }

    pub fn kill(self: *LocalCommand) anyerror!void {
        return self.close();
    }
};

// ---------------------------------------------------------------------------
// HostCommand — LookPath + subprocess (go-git `command`)
// ---------------------------------------------------------------------------

/// Host subprocess command: spawns `bin path` with stdio pipes.
///
/// Heap-owned by `Runner` (freed in `Runner.deinit`). Implements
/// `transport_common.Command`. Spawns on first pipe access or `start` so the
/// Session order (pipes then start) works with Zig's atomic `process.spawn`.
///
/// # Ownership
///
/// - Takes ownership of `bin_owned` and `path_owned` at `init`.
/// - `deinit` always reaps the child (kill) then frees both strings.
/// - `Runner.command` must `errdefer hc.deinit()` until `owned` retains `hc`.
///
/// # Lifecycle
///
/// - `ensureSpawned` owns the child until `close` / `kill` / `deinit`.
/// - Stdin close flushes and closes the write end (child sees EOF).
/// - `close` waits and reaps; `kill` terminates then reaps.
/// - Zig `Child.wait` / `Child.kill` close remaining pipe FDs (cleanup).
/// - After wait/kill, do not read `stdoutPipe` / `stderrPipe` (FD closed).
pub const HostCommand = struct {
    allocator: Allocator,
    io: Io,
    /// Owned absolute/resolved binary path.
    bin_owned: []u8,
    /// Owned repository path argument.
    path_owned: []u8,
    /// argv[0]=bin, argv[1]=path (slices into owned fields). Matches go-git
    /// `execabs.Command(cmd, adjustPathForWindows(ep.Path))`.
    argv: [2][]const u8 = .{ "", "" },

    child: ?Child = null,

    stdin_file_writer: std.Io.File.Writer = undefined,
    stdin_buf: [4096]u8 = undefined,
    stdin_closed: bool = false,

    stdout_file_reader: std.Io.File.Reader = undefined,
    stdout_buf: [8192]u8 = undefined,

    stderr_file_reader: std.Io.File.Reader = undefined,
    stderr_buf: [4096]u8 = undefined,

    pipes_ready: bool = false,
    started: bool = false,
    closed: bool = false,

    /// Takes ownership of `bin_owned` and `path_owned` (freed in `deinit`).
    pub fn init(
        allocator: Allocator,
        io: Io,
        bin_owned: []u8,
        path_owned: []u8,
    ) HostCommand {
        var hc: HostCommand = .{
            .allocator = allocator,
            .io = io,
            .bin_owned = bin_owned,
            .path_owned = path_owned,
        };
        hc.argv = .{ bin_owned, path_owned };
        return hc;
    }

    pub fn deinit(self: *HostCommand) void {
        // Always kill-reap on destroy so abandoned commands do not leak.
        self.closed = true;
        self.closeStdin() catch {};
        self.reapKill();
        self.allocator.free(self.bin_owned);
        self.allocator.free(self.path_owned);
        self.* = undefined;
    }

    pub fn asCommand(self: *HostCommand) Command {
        return Command.from(HostCommand, self);
    }

    /// Kill and reap if still live; clear child and pipes_ready.
    ///
    /// After this, `child` is null and pipe FDs owned by Child are closed.
    /// File.Reader/Writer copies must not be used.
    fn reapKill(self: *HostCommand) void {
        if (self.child) |*c| {
            if (c.id != null) {
                c.kill(self.io);
            } else {
                // Already reaped (id null ⇒ wait/kill cleaned pipes).
            }
            self.child = null;
        }
        self.pipes_ready = false;
    }

    /// Wait and reap if still live; clear child and pipes_ready.
    fn reapWait(self: *HostCommand) void {
        if (self.child) |*c| {
            if (c.id != null) {
                // wait always runs Child cleanup (closes remaining pipe FDs).
                _ = c.wait(self.io) catch {
                    // If wait fails after partial progress, force kill+cleanup.
                    if (c.id != null) c.kill(self.io);
                };
            }
            self.child = null;
        }
        self.pipes_ready = false;
    }

    /// Ensure child is spawned and File readers/writers are live.
    fn ensureSpawned(self: *HostCommand) anyerror!void {
        if (self.pipes_ready) return;
        if (self.closed) return error.CommandFailed;

        var child = try std.process.spawn(self.io, .{
            .argv = &self.argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        errdefer if (child.id != null) child.kill(self.io);

        const stdin = child.stdin orelse return error.CommandFailed;
        const stdout = child.stdout orelse return error.CommandFailed;
        const stderr = child.stderr orelse return error.CommandFailed;

        // Pipes do not support seek — use streaming File readers/writers.
        // Handles are borrowed from Child until wait/kill closes them.
        self.stdin_file_writer = std.Io.File.Writer.initStreaming(stdin, self.io, &self.stdin_buf);
        self.stdout_file_reader = std.Io.File.Reader.initStreaming(stdout, self.io, &self.stdout_buf);
        self.stderr_file_reader = std.Io.File.Reader.initStreaming(stderr, self.io, &self.stderr_buf);

        self.child = child;
        self.pipes_ready = true;
    }

    pub fn stderrPipe(self: *HostCommand) anyerror!*Reader {
        try self.ensureSpawned();
        return &self.stderr_file_reader.interface;
    }

    pub fn stdinPipe(self: *HostCommand) anyerror!WriteCloser {
        try self.ensureSpawned();
        const gen = struct {
            fn closeFn(ptr: *anyopaque) anyerror!void {
                const s: *HostCommand = @ptrCast(@alignCast(ptr));
                try s.closeStdin();
            }
        };
        return .{
            .ptr = self,
            .writer = &self.stdin_file_writer.interface,
            .close_fn = gen.closeFn,
        };
    }

    pub fn stdoutPipe(self: *HostCommand) anyerror!*Reader {
        try self.ensureSpawned();
        return &self.stdout_file_reader.interface;
    }

    fn closeStdin(self: *HostCommand) anyerror!void {
        if (self.stdin_closed) return;
        self.stdin_closed = true;
        if (!self.pipes_ready) return;
        // Flush buffered writes, then close the write end so the child sees EOF.
        // Null Child.stdin so later wait/kill cleanup does not double-close.
        self.stdin_file_writer.interface.flush() catch {};
        if (self.child) |*c| {
            if (c.stdin) |f| {
                f.close(self.io);
                c.stdin = null;
            }
        }
    }

    pub fn start(self: *HostCommand) anyerror!void {
        if (self.started) return;
        try self.ensureSpawned();
        self.started = true;
    }

    /// Wait for the child (go-git `Close`). Exit status is ignored the same way
    /// go-git ignores `*os.PathError` and `*exec.ExitError` (e.g. exit 128 for
    /// missing repos). Pipe FDs are invalid after return.
    pub fn close(self: *HostCommand) anyerror!void {
        if (self.closed) return;
        self.closed = true;
        self.closeStdin() catch {};
        self.reapWait();
    }

    /// Terminate then reap (go-git `CommandKiller.Kill`). Pipe FDs invalid after.
    pub fn kill(self: *HostCommand) anyerror!void {
        if (self.closed and self.child == null) return;
        self.closed = true;
        self.closeStdin() catch {};
        self.reapKill();
    }
};

// ---------------------------------------------------------------------------
// Runner (go-git `runner`)
// ---------------------------------------------------------------------------

/// Owned command variants retained until `Runner.deinit`.
pub const OwnedCmd = union(enum) {
    local: *LocalCommand,
    host: *HostCommand,

    fn release(self: OwnedCmd, allocator: Allocator) void {
        switch (self) {
            .local => |c| {
                c.deinit();
                allocator.destroy(c);
            },
            .host => |c| {
                c.deinit();
                allocator.destroy(c);
            },
        }
    }
};

/// Creates local Commands (go-git `file.runner` + `Commander`).
pub const Runner = struct {
    allocator: Allocator,
    io: Io,
    environ: Environ = .empty,
    /// go-git `UploadPackBin` — binary label or absolute path.
    upload_pack_bin: []const u8,
    /// go-git `ReceivePackBin`.
    receive_pack_bin: []const u8,
    /// Optional in-process loader for hermetic serve (MapLoader / FS).
    loader: ?server.Loader = null,
    /// When true and loader is null, spawn host binaries via LookPath.
    /// Default true (go-git behavior). Set false for unit tests without host git.
    use_host_spawn: bool = true,
    owned: std.ArrayListUnmanaged(OwnedCmd) = .empty,

    pub fn init(
        allocator: Allocator,
        upload_pack_bin: []const u8,
        receive_pack_bin: []const u8,
    ) Runner {
        return .{
            .allocator = allocator,
            .io = defaultIo(),
            .environ = defaultEnviron(),
            .upload_pack_bin = upload_pack_bin,
            .receive_pack_bin = receive_pack_bin,
        };
    }

    /// Explicit Io / Environ (tests or custom hosts).
    pub fn initWithIo(
        allocator: Allocator,
        io: Io,
        environ: Environ,
        upload_pack_bin: []const u8,
        receive_pack_bin: []const u8,
    ) Runner {
        return .{
            .allocator = allocator,
            .io = io,
            .environ = environ,
            .upload_pack_bin = upload_pack_bin,
            .receive_pack_bin = receive_pack_bin,
        };
    }

    pub fn deinit(self: *Runner) void {
        for (self.owned.items) |c| c.release(self.allocator);
        self.owned.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn asCommander(self: *Runner) Commander {
        return Commander.from(Runner, self);
    }

    /// go-git `(*runner).Command`.
    ///
    /// Auth is ignored (go-git file transport never validates auth).
    ///
    /// Path selection: loader → LocalCommand; else use_host_spawn → HostCommand;
    /// else LocalCommand dry. See module dual-path docs.
    pub fn command(
        self: *Runner,
        cmd: []const u8,
        ep: *const Endpoint,
        auth: ?AuthMethod,
    ) anyerror!Command {
        _ = auth; // go-git: auth unused for file (emptyAuth always accepted)

        // Reject endpoints with no location at all. Host-only `file://name` keys
        // (MapLoader tests) have empty path but non-empty host and are valid.
        if (ep.path.len == 0 and ep.host.len == 0) return Error.InvalidEndpoint;

        const path = adjustPathForWindows(ep.path);

        // --- Path 1: hermetic loader → LocalCommand ---
        if (self.loader != null) {
            const mapped = try self.mapService(cmd);
            return try self.ownLocal(mapped.service, ep, path, self.loader);
        }

        // --- Path 2: host spawn → LookPath + HostCommand ---
        if (self.use_host_spawn) {
            const resolved = try self.resolveBinary(cmd);
            // Host spawn always owns the resolved path (lookPath / prefixExecPath).
            const bin_owned = switch (resolved.bin) {
                .owned => |b| b,
                .borrowed => unreachable,
            };
            const path_owned = self.allocator.dupe(u8, path) catch |err| {
                self.allocator.free(bin_owned);
                return err;
            };
            const hc = self.allocator.create(HostCommand) catch |err| {
                self.allocator.free(bin_owned);
                self.allocator.free(path_owned);
                return err;
            };
            hc.* = HostCommand.init(self.allocator, self.io, bin_owned, path_owned);
            // HostCommand owns bin/path; deinit frees them and reaps any child.
            errdefer {
                hc.deinit();
                self.allocator.destroy(hc);
            }
            try self.owned.append(self.allocator, .{ .host = hc });
            return hc.asCommand();
        }

        // --- Path 3: unit dry → LocalCommand, no serve ---
        const mapped = try self.mapService(cmd);
        return try self.ownLocal(mapped.service, ep, path, null);
    }

    fn ownLocal(
        self: *Runner,
        service: Service,
        ep: *const Endpoint,
        path: []const u8,
        loader: ?server.Loader,
    ) !Command {
        const lc = try self.allocator.create(LocalCommand);
        errdefer self.allocator.destroy(lc);
        lc.* = .{
            .allocator = self.allocator,
            .service = service,
            .endpoint = try cloneEndpoint(self.allocator, ep, path),
            .loader = loader,
        };
        errdefer lc.deinit();
        try self.owned.append(self.allocator, .{ .local = lc });
        return lc.asCommand();
    }

    const Mapped = struct {
        bin: []const u8,
        service: Service,
    };

    /// Binary resolution result. Host spawn always yields `.owned`; dry path yields `.borrowed`.
    pub const Resolved = struct {
        service: Service,
        bin: Bin,
        pub const Bin = union(enum) {
            /// Configured label (not LookPath'd); do not free.
            borrowed: []const u8,
            /// lookPath / prefixExecPath result; caller owns (or transfer to HostCommand).
            owned: []u8,

            pub fn bytes(self: Bin) []const u8 {
                return switch (self) {
                    .borrowed => |b| b,
                    .owned => |b| b,
                };
            }

            pub fn isOwned(self: Bin) bool {
                return self == .owned;
            }
        };
    };

    /// Map service name → configured bin label (no host LookPath).
    pub fn mapService(self: *const Runner, cmd: []const u8) Error!Mapped {
        if (std.mem.eql(u8, cmd, transport.UploadPackServiceName)) {
            return .{ .bin = self.upload_pack_bin, .service = .upload_pack };
        }
        if (std.mem.eql(u8, cmd, transport.ReceivePackServiceName)) {
            return .{ .bin = self.receive_pack_bin, .service = .receive_pack };
        }
        // Non-service name: only accept if it is exactly a configured bin.
        if (std.mem.eql(u8, cmd, self.upload_pack_bin)) {
            return .{ .bin = cmd, .service = .upload_pack };
        }
        if (std.mem.eql(u8, cmd, self.receive_pack_bin)) {
            return .{ .bin = cmd, .service = .receive_pack };
        }
        return Error.CommandNotFound;
    }

    /// Map service → bin. LookPath only when host spawn is active.
    ///
    /// On LookPath miss, try go-git `prefixExecPath` (`git --exec-path` join).
    /// Still missing → `Error.CommandNotFound`.
    /// When `bin` is `.owned`, caller must free or transfer into `HostCommand`.
    pub fn resolveBinary(self: *const Runner, cmd: []const u8) (Error || Allocator.Error)!Resolved {
        const mapped = try self.mapService(cmd);
        if (!self.use_host_spawn) {
            return .{ .service = mapped.service, .bin = .{ .borrowed = mapped.bin } };
        }
        const found = lookPath(self.allocator, self.io, self.environ, mapped.bin) catch |err| switch (err) {
            Error.CommandNotFound => try prefixExecPath(self.allocator, self.io, self.environ, mapped.bin),
            else => |e| return e,
        };
        return .{ .service = mapped.service, .bin = .{ .owned = found } };
    }
};

fn cloneEndpoint(allocator: Allocator, ep: *const Endpoint, path: []const u8) !Endpoint {
    const protocol = try dupeOrEmpty(allocator, ep.protocol);
    errdefer freeOwned(allocator, protocol);
    const user = try dupeOrEmpty(allocator, ep.user);
    errdefer freeOwned(allocator, user);
    const password = try dupeOrEmpty(allocator, ep.password);
    errdefer freeOwned(allocator, password);
    const host = try dupeOrEmpty(allocator, ep.host);
    errdefer freeOwned(allocator, host);
    const path_owned = try dupeOrEmpty(allocator, path);
    errdefer freeOwned(allocator, path_owned);
    return .{
        .allocator = allocator,
        .protocol = protocol,
        .user = user,
        .password = password,
        .host = host,
        .port = ep.port,
        .path = path_owned,
        .insecure_skip_tls = ep.insecure_skip_tls,
        .client_cert = ep.client_cert,
        .client_key = ep.client_key,
        .ca_bundle = ep.ca_bundle,
        .proxy = ep.proxy,
    };
}

fn dupeOrEmpty(allocator: Allocator, s: []const u8) ![]u8 {
    if (s.len == 0) return &.{};
    return try allocator.dupe(u8, s);
}

fn freeOwned(allocator: Allocator, s: []u8) void {
    if (s.len != 0) allocator.free(s);
}

// ---------------------------------------------------------------------------
// FileClient (go-git `common.NewClient` + file runner)
// ---------------------------------------------------------------------------

/// Local-path pack-protocol client (go-git file transport).
///
/// ## Mode controls
///
/// | Call | Effect |
/// |------|--------|
/// | `setLoader(L)` | Path 1: hermetic LocalCommand (ignores host spawn) |
/// | `setLoader(null)` | Clear loader; path 2 or 3 from `use_host_spawn` |
/// | `setUseHostSpawn(true)` | Path 2 when no loader (default) |
/// | `setUseHostSpawn(false)` | Path 3 when no loader (unit dry) |
///
/// Loader always wins while non-null.
pub const FileClient = struct {
    allocator: Allocator,
    runner: *Runner,
    client: common.Client,

    pub fn deinit(self: *FileClient) void {
        self.runner.deinit();
        self.allocator.destroy(self.runner);
        self.* = undefined;
    }

    /// Attach an in-process loader for hermetic MapLoader/FS serve.
    /// While set, `Runner.command` always returns LocalCommand (path 1).
    pub fn setLoader(self: *FileClient, loader: ?server.Loader) void {
        self.runner.loader = loader;
    }

    /// Enable or disable host LookPath + subprocess spawn (default true).
    /// Only applies when no loader is set.
    pub fn setUseHostSpawn(self: *FileClient, use: bool) void {
        self.runner.use_host_spawn = use;
    }

    pub fn newUploadPackSession(
        self: *FileClient,
        ep: *const Endpoint,
        auth: ?AuthMethod,
    ) !common.Session {
        return self.client.newUploadPackSession(ep, auth);
    }

    pub fn newReceivePackSession(
        self: *FileClient,
        ep: *const Endpoint,
        auth: ?AuthMethod,
    ) !common.Session {
        return self.client.newReceivePackSession(ep, auth);
    }

    /// Expose as `transport.Transport` vtable for `client.installProtocol("file", ...)`.
    pub fn asTransport(self: *FileClient) transport.Transport {
        return self.client.asTransport();
    }
};

/// go-git `NewClient` — local client using the given binary labels.
///
/// Default mode is host spawn (`use_host_spawn=true`). Attach a loader for
/// hermetic serve, or call `setUseHostSpawn(false)` for pipe-only unit tests.
pub fn newClient(
    allocator: Allocator,
    upload_pack_bin: []const u8,
    receive_pack_bin: []const u8,
) !FileClient {
    const runner = try allocator.create(Runner);
    errdefer allocator.destroy(runner);
    runner.* = Runner.init(allocator, upload_pack_bin, receive_pack_bin);
    return .{
        .allocator = allocator,
        .runner = runner,
        .client = common.newClient(allocator, runner.asCommander()),
    };
}

/// go-git `DefaultClient` — standard `git-upload-pack` / `git-receive-pack` labels.
pub fn defaultClient(allocator: Allocator) !FileClient {
    return newClient(
        allocator,
        transport.UploadPackServiceName,
        transport.ReceivePackServiceName,
    );
}
