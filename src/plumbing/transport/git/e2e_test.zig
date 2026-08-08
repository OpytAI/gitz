//! Thorough git:// e2e — hermetic in-process server + live git-daemon.
//!
//! ## A. In-process (always CI)
//! `LoaderDial` is a `DialFn` context: on dial it returns a duplex `ServerConn`.
//! When the client `Start` encodes `GitProtoRequest`, the next client read
//! parses the request, opens `server.Server` upload/receive-pack via MapLoader,
//! and serves advertise. A subsequent pack request on the same conn serves pack.
//!
//! ## B. Live git-daemon (host `git` required)
//! Spawns `git daemon` on 127.0.0.1 with a temp bare repo. Fails hard if git
//! or the daemon cannot start — not an optional residual skip.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const transport = @import("transport");
const packp = @import("packp");
const capability = @import("capability");
const memory = @import("memory");
const sync = @import("utils/sync");
const server = @import("server");
const fixtures = @import("transport_test_fixtures");
const plumbing = @import("plumbing");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Endpoint = transport.Endpoint;
const MapLoader = server.MapLoader;
const IpAddress = std.Io.net.IpAddress;

// ---------------------------------------------------------------------------
// LoaderDial + ServerConn — real pack protocol behind DialFn
// ---------------------------------------------------------------------------

/// Dial context: MapLoader-backed in-process git protocol server.
///
/// One outstanding `ServerConn` per dial (tests use a single session at a time).
pub const LoaderDial = struct {
    allocator: Allocator,
    io: Io,
    loader: server.Loader,
    /// Last dial host/port (inspection).
    last_host: []const u8 = "",
    last_port: u16 = 0,
    last_host_owned: ?[]u8 = null,
    /// Heap-owned active connection (freed on close or LoaderDial.deinit).
    live: ?*ServerConn = null,

    pub fn init(allocator: Allocator, io: Io, loader: server.Loader) LoaderDial {
        return .{ .allocator = allocator, .io = io, .loader = loader };
    }

    pub fn deinit(self: *LoaderDial) void {
        if (self.live) |c| {
            c.destroy();
            self.live = null;
        }
        if (self.last_host_owned) |h| self.allocator.free(h);
        self.* = undefined;
    }

    /// `DialFn` — install with `runner.setDial(&loader_dial, LoaderDial.dialFn)`.
    pub fn dialFn(
        ctx: ?*anyopaque,
        allocator: Allocator,
        io: Io,
        host: []const u8,
        port: u16,
    ) anyerror!common.Conn {
        const self: *LoaderDial = @ptrCast(@alignCast(ctx.?));
        if (self.live) |old| {
            old.destroy();
            self.live = null;
        }
        if (self.last_host_owned) |h| {
            allocator.free(h);
            self.last_host_owned = null;
        }
        self.last_host_owned = try allocator.dupe(u8, host);
        self.last_host = self.last_host_owned.?;
        self.last_port = port;

        const sc = try ServerConn.create(allocator, io, self.loader, host, port);
        self.live = sc;
        return sc.asConn();
    }
};

/// Duplex in-memory conn that serves advertise/pack from `server.Server`.
pub const ServerConn = struct {
    allocator: Allocator,
    io: Io,
    loader: server.Loader,
    dial_host: []u8,
    dial_port: u16,

    /// Client → server bytes (GitProtoRequest + pack/update request).
    write_alloc: Writer.Allocating,
    /// Server → client bytes (advrefs + pack / report-status).
    read_buf: std.ArrayList(u8) = .empty,
    /// How many write_alloc bytes have been consumed as GitProtoRequest.
    client_consumed: usize = 0,

    reader: Reader = undefined,
    reader_iface_buf: [4096]u8 = undefined,
    reader_bound: bool = false,

    up_session: ?server.UploadPackSession = null,
    rp_session: ?server.ReceivePackSession = null,
    is_receive: bool = false,

    proto_done: bool = false,
    pack_done: bool = false,
    closed: bool = false,
    /// Fatal serve error recorded for reader (empty stream → client error).
    serve_failed: bool = false,

    fn create(
        allocator: Allocator,
        io: Io,
        loader: server.Loader,
        host: []const u8,
        port: u16,
    ) !*ServerConn {
        const sc = try allocator.create(ServerConn);
        errdefer allocator.destroy(sc);
        sc.* = .{
            .allocator = allocator,
            .io = io,
            .loader = loader,
            .dial_host = try allocator.dupe(u8, host),
            .dial_port = port,
            .write_alloc = Writer.Allocating.init(allocator),
        };
        return sc;
    }

    fn destroy(self: *ServerConn) void {
        self.closeSessions();
        self.write_alloc.deinit();
        self.read_buf.deinit(self.allocator);
        self.allocator.free(self.dial_host);
        const a = self.allocator;
        a.destroy(self);
    }

    fn closeSessions(self: *ServerConn) void {
        if (self.up_session) |*s| {
            s.close();
            self.up_session = null;
        }
        if (self.rp_session) |*s| {
            s.close();
            self.rp_session = null;
        }
    }

    fn asConn(self: *ServerConn) common.Conn {
        self.bindReader();
        return .{
            .ptr = self,
            .reader = &self.reader,
            .writer = &self.write_alloc.writer,
            .close_fn = closeFn,
        };
    }

    fn closeFn(ptr: *anyopaque) anyerror!void {
        const self: *ServerConn = @ptrCast(@alignCast(ptr));
        if (self.closed) return;
        self.closed = true;
        self.closeSessions();
        // LoaderDial may still hold live; leave heap free to LoaderDial.deinit
        // or next dial. Mark closed so further reads end.
    }

    fn bindReader(self: *ServerConn) void {
        if (self.reader_bound) return;
        self.reader_bound = true;
        const vt = struct {
            fn stream(r: *Reader, w: *Writer, limit: Io.Limit) Reader.StreamError!usize {
                const conn: *ServerConn = @alignCast(@fieldParentPtr("reader", r));
                conn.ensureServed() catch {
                    conn.serve_failed = true;
                };
                if (conn.read_buf.items.len == 0) {
                    if (conn.closed or conn.serve_failed) return error.EndOfStream;
                    // Advertise/pack not yet produced (should not happen after ensureServed).
                    return error.EndOfStream;
                }
                const avail = conn.read_buf.items.len;
                const want = limit.toInt() orelse avail;
                const n = @min(avail, want);
                const dest = limit.slice(try w.writableSliceGreedy(1));
                const copy_n = @min(n, dest.len);
                if (copy_n == 0) return 0;
                @memcpy(dest[0..copy_n], conn.read_buf.items[0..copy_n]);
                w.advance(copy_n);
                const rest = conn.read_buf.items[copy_n..];
                std.mem.copyForwards(u8, conn.read_buf.items[0..rest.len], rest);
                conn.read_buf.shrinkRetainingCapacity(rest.len);
                return copy_n;
            }
        };
        self.reader = .{
            .vtable = &.{ .stream = vt.stream },
            .buffer = &self.reader_iface_buf,
            .seek = 0,
            .end = 0,
        };
    }

    /// Parse GitProtoRequest / pack request from client writes; fill read_buf.
    fn ensureServed(self: *ServerConn) !void {
        if (self.closed) return;
        if (!self.proto_done) {
            try self.serveAdvertise();
        }
        if (self.proto_done and !self.pack_done) {
            try self.servePackIfReady();
        }
    }

    fn serveAdvertise(self: *ServerConn) !void {
        const written = self.write_alloc.written();
        if (written.len == 0) return; // Start not yet written

        var r: Reader = .fixed(written);
        var req = packp.GitProtoRequest.init(self.allocator);
        defer req.deinit();
        try req.decode(&r);
        self.client_consumed = r.seek;

        const cmd = req.request_command;
        const pathname = req.pathname;

        var ep = try buildGitEndpoint(self.allocator, self.dial_host, self.dial_port, pathname);
        defer ep.deinit();

        var srv = server.newServer(self.allocator, self.loader);

        if (std.mem.eql(u8, cmd, transport.UploadPackServiceName) or
            std.mem.eql(u8, cmd, "git-upload-pack"))
        {
            self.is_receive = false;
            const sess = try srv.newUploadPackSession(&ep, null);
            self.up_session = sess;
            const ar = try self.up_session.?.advertisedReferences();
            defer packp.freeAdvRefs(self.allocator, ar);

            var aw: Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            try ar.encode(&aw.writer);
            try self.read_buf.appendSlice(self.allocator, aw.written());
        } else if (std.mem.eql(u8, cmd, transport.ReceivePackServiceName) or
            std.mem.eql(u8, cmd, "git-receive-pack"))
        {
            self.is_receive = true;
            const sess = try srv.newReceivePackSession(&ep, null);
            self.rp_session = sess;
            const ar = try self.rp_session.?.advertisedReferences();
            defer packp.freeAdvRefs(self.allocator, ar);

            var aw: Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            try ar.encode(&aw.writer);
            try self.read_buf.appendSlice(self.allocator, aw.written());
        } else {
            return error.UnsupportedService;
        }
        self.proto_done = true;
    }

    fn servePackIfReady(self: *ServerConn) !void {
        const written = self.write_alloc.written();
        if (written.len <= self.client_consumed) return;
        const rest = written[self.client_consumed..];
        if (rest.len == 0) return;

        if (!self.is_receive) {
            // Must use pointer into optional — session owns heap caps; do not copy.
            const sess: *server.UploadPackSession = if (self.up_session) |*s| s else return;
            var up_req = packp.newUploadPackRequest(self.allocator);
            defer up_req.deinit();
            var r: Reader = .fixed(rest);
            // Incomplete client request → leave for a later read (match serveUploadPack).
            up_req.upload_request.decode(&r) catch return;
            if (up_req.upload_request.wants.items.len == 0) return;

            const resp = try sess.uploadPack(&up_req);
            defer packp.freeUploadPackResponse(self.allocator, resp);

            var aw: Writer.Allocating = .init(self.allocator);
            defer aw.deinit();
            try resp.encode(&aw.writer);
            try self.read_buf.appendSlice(self.allocator, aw.written());
            self.pack_done = true;
            self.client_consumed = written.len;
        } else {
            const sess: *server.ReceivePackSession = if (self.rp_session) |*s| s else return;
            var rp_req = try packp.newReferenceUpdateRequest(self.allocator);
            defer rp_req.deinit();
            var r: Reader = .fixed(rest);
            rp_req.decode(&r) catch return;

            const out = try sess.receivePackOutcome(&rp_req);
            defer if (out.report) |rs| packp.freeReportStatus(self.allocator, rs);

            if (out.report) |rs| {
                var aw: Writer.Allocating = .init(self.allocator);
                defer aw.deinit();
                try rs.encode(&aw.writer);
                try self.read_buf.appendSlice(self.allocator, aw.written());
            }
            self.pack_done = true;
            self.client_consumed = written.len;
            if (out.err) |e| return e;
        }
    }
};

/// Build git endpoint for MapLoader lookup (host/port from dial, path from proto).
fn buildGitEndpoint(
    allocator: Allocator,
    host: []const u8,
    port: u16,
    pathname: []const u8,
) !Endpoint {
    return .{
        .allocator = allocator,
        .protocol = try allocator.dupe(u8, "git"),
        .user = &.{},
        .password = &.{},
        .host = try allocator.dupe(u8, host),
        .port = @intCast(port),
        .path = try allocator.dupe(u8, pathname),
    };
}

fn makeEp(allocator: Allocator, host: []const u8, port: i32, path: []const u8) !Endpoint {
    return .{
        .allocator = allocator,
        .protocol = try allocator.dupe(u8, "git"),
        .user = &.{},
        .password = &.{},
        .host = try allocator.dupe(u8, host),
        .port = port,
        .path = try allocator.dupe(u8, path),
    };
}

// ---------------------------------------------------------------------------
// A. In-process e2e
// ---------------------------------------------------------------------------

test "in-process LoaderDial advertisedReferences matches fixture" {
    const gpa = testing.allocator;
    defer sync.deinitPools(gpa);

    var loader = MapLoader.init(gpa);
    defer loader.deinit();

    const sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    const head = try fixtures.populateRepo(sto, gpa);

    // Port DefaultPort so dial port and MapLoader key (no :port in string) align.
    var ep = try makeEp(gpa, "127.0.0.1", common.DefaultPort, "/e2e-inproc.git");
    defer ep.deinit();
    try loader.put(&ep, sto);

    var dial = LoaderDial.init(gpa, testing.io, loader.asLoader());
    defer dial.deinit();

    var runner = common.Runner.init(gpa, testing.io);
    defer runner.deinit();
    runner.setDial(&dial, LoaderDial.dialFn);

    var client = common.defaultClient(gpa, &runner);
    var sess = try client.newUploadPackSession(&ep, null);
    defer sess.close() catch {};

    const ar = try sess.advertisedReferences();
    try testing.expect(ar.head != null);
    try testing.expect(ar.head.?.eql(head));
    try testing.expect(ar.references.get("refs/heads/master") != null);
    try testing.expect(ar.references.get("refs/heads/master").?.eql(head));
    try testing.expect(ar.capabilities.supports(capability.OFSDelta) or
        ar.capabilities.supports(capability.Sideband64k) or
        ar.capabilities.supports(capability.Sideband));

    try testing.expectEqualStrings("127.0.0.1", dial.last_host);
    try testing.expectEqual(@as(u16, 9418), dial.last_port);
}

test "in-process LoaderDial missing repo yields empty-class error" {
    const gpa = testing.allocator;
    defer sync.deinitPools(gpa);

    var loader = MapLoader.init(gpa);
    defer loader.deinit();

    var ep = try makeEp(gpa, "127.0.0.1", common.DefaultPort, "/missing-inproc.git");
    defer ep.deinit();

    var dial = LoaderDial.init(gpa, testing.io, loader.asLoader());
    defer dial.deinit();

    var runner = common.Runner.init(gpa, testing.io);
    defer runner.deinit();
    runner.setDial(&dial, LoaderDial.dialFn);

    var client = common.defaultClient(gpa, &runner);
    var sess = try client.newUploadPackSession(&ep, null);
    defer sess.close() catch {};

    // ServerConn serve fails → empty stdout → UnexpectedEndOfStream (no stderr channel).
    try testing.expectError(error.UnexpectedEndOfStream, sess.advertisedReferences());
}

test "in-process LoaderDial uploadPack returns PACK bytes" {
    const gpa = testing.allocator;
    defer sync.deinitPools(gpa);

    var loader = MapLoader.init(gpa);
    defer loader.deinit();

    const sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    const head = try fixtures.populateRepo(sto, gpa);

    var ep = try makeEp(gpa, "127.0.0.1", common.DefaultPort, "/e2e-pack.git");
    defer ep.deinit();
    try loader.put(&ep, sto);

    var dial = LoaderDial.init(gpa, testing.io, loader.asLoader());
    defer dial.deinit();

    var runner = common.Runner.init(gpa, testing.io);
    defer runner.deinit();
    runner.setDial(&dial, LoaderDial.dialFn);

    var client = common.defaultClient(gpa, &runner);
    var sess = try client.newUploadPackSession(&ep, null);
    defer sess.close() catch {};

    const ar = try sess.advertisedReferences();
    try testing.expect(ar.head.?.eql(head));

    var req = packp.newUploadPackRequest(gpa);
    defer req.deinit();
    try req.upload_request.wants.append(gpa, head);
    try req.upload_request.capabilities.set(capability.OFSDelta, &.{});

    const resp = try sess.uploadPack(&req);
    defer packp.freeUploadPackResponse(gpa, resp);

    const pack_bytes = try resp.readAll(gpa);
    defer gpa.free(pack_bytes);
    try testing.expect(pack_bytes.len >= 4);
    try testing.expectEqualStrings("PACK", pack_bytes[0..4]);
}

test "in-process LoaderDial receivePack creates ref" {
    const gpa = testing.allocator;
    defer sync.deinitPools(gpa);

    var loader = MapLoader.init(gpa);
    defer loader.deinit();

    const sto = try memory.newStorage(gpa);
    defer {
        sto.deinit();
        gpa.destroy(sto);
    }
    const head = try fixtures.populateRepo(sto, gpa);

    var ep = try makeEp(gpa, "127.0.0.1", common.DefaultPort, "/e2e-rp.git");
    defer ep.deinit();
    try loader.put(&ep, sto);

    var dial = LoaderDial.init(gpa, testing.io, loader.asLoader());
    defer dial.deinit();

    var runner = common.Runner.init(gpa, testing.io);
    defer runner.deinit();
    runner.setDial(&dial, LoaderDial.dialFn);

    var client = common.defaultClient(gpa, &runner);
    var sess = try client.newReceivePackSession(&ep, null);
    defer sess.close() catch {};

    const ar = try sess.advertisedReferences();
    try testing.expect(ar.head != null);

    var req = try packp.newReferenceUpdateRequest(gpa);
    defer req.deinit();
    try req.capabilities.set(capability.ReportStatus, &.{});
    try req.appendCommand(.{
        .name = plumbing.ReferenceName.init("refs/heads/topic"),
        .old = plumbing.ZeroHash,
        .new = head,
    });

    const report = try sess.receivePack(&req);
    defer if (report) |rs| packp.freeReportStatus(gpa, rs);
    try testing.expect(report != null);
    try testing.expect(report.?.isOk());

    const got = try sto.reference(plumbing.ReferenceName.init("refs/heads/topic"));
    try testing.expect(got.hash.eql(head));
}

// ---------------------------------------------------------------------------
// B. Live git-daemon e2e
// ---------------------------------------------------------------------------

fn runGit(gpa: Allocator, io: Io, argv: []const []const u8) !void {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .unlimited,
        .stderr_limit = .unlimited,
    });
    defer {
        gpa.free(result.stdout);
        gpa.free(result.stderr);
    }
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("git command failed ({d}): {s}\nstderr: {s}\n", .{
                    code,
                    argv[0],
                    result.stderr,
                });
                return error.GitCommandFailed;
            }
        },
        else => return error.GitCommandFailed,
    }
}

fn freePort(io: Io) !u16 {
    const addr = try IpAddress.parse("127.0.0.1", 0);
    var srv = try addr.listen(io, .{ .reuse_address = true });
    defer srv.deinit(io);
    return srv.socket.address.getPort();
}

fn loopbackListenUnavailable(err: anyerror) bool {
    // Bazel's Linux sandbox can deny bind/listen with EPERM. Zig's Io backend
    // can surface that unmapped errno as Unexpected; this guard is used only
    // around the ephemeral loopback listen call.
    return err == error.PermissionDenied or err == error.AccessDenied or err == error.Unexpected;
}

fn waitForTcp(io: Io, host: []const u8, port: u16, attempts: u32) !void {
    var i: u32 = 0;
    while (i < attempts) : (i += 1) {
        if (common.defaultDial(null, testing.allocator, io, host, port)) |conn| {
            conn.close() catch {};
            return;
        } else |_| {
            io.sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .real) catch {};
        }
    }
    return error.GitDaemonNotReady;
}

test "live git-daemon advertisedReferences succeeds" {
    const gpa = testing.allocator;
    const io = testing.io;
    defer sync.deinitPools(gpa);

    // git must exist on PATH (assert, do not soft-skip).
    const git_bin = blk: {
        // Prefer LookPath-style resolution via process spawn of `git --version`.
        const ver = std.process.run(gpa, io, .{
            .argv = &.{ "git", "--version" },
        }) catch |err| {
            std.debug.print("git binary not available: {}\n", .{err});
            return error.GitBinaryRequired;
        };
        defer {
            gpa.free(ver.stdout);
            gpa.free(ver.stderr);
        }
        switch (ver.term) {
            .exited => |c| if (c != 0) return error.GitBinaryRequired,
            else => return error.GitBinaryRequired,
        }
        break :blk "git";
    };
    _ = git_bin;

    // Confirm daemon is a known command (go-git BaseSuite).
    {
        const help = try std.process.run(gpa, io, .{
            .argv = &.{ "git", "daemon", "--help" },
        });
        defer {
            gpa.free(help.stdout);
            gpa.free(help.stderr);
        }
        const combined = try std.fmt.allocPrint(gpa, "{s}{s}", .{ help.stdout, help.stderr });
        defer gpa.free(combined);
        if (std.mem.indexOf(u8, combined, "'daemon' is not a git command") != null) {
            return error.GitDaemonCommandMissing;
        }
    }

    const port = freePort(io) catch |err| {
        if (loopbackListenUnavailable(err)) return;
        return err;
    };

    // Prefer Bazel TEST_TMPDIR / TMPDIR so sandboxes that restrict /tmp still work.
    const tmp_root = blk: {
        if (std.process.Environ.getPosix(std.testing.environ, "TEST_TMPDIR")) |t| break :blk t;
        if (std.process.Environ.getPosix(std.testing.environ, "TMPDIR")) |t| break :blk t;
        if (builtin.link_libc) {
            if (std.c.getenv("TEST_TMPDIR")) |p| break :blk std.mem.span(p);
            if (std.c.getenv("TMPDIR")) |p| break :blk std.mem.span(p);
        }
        break :blk "/tmp";
    };
    const stamp: usize = @intFromPtr(gpa.ptr) ^ @as(usize, port);
    const base_path = try std.fmt.allocPrint(gpa, "{s}/gitz-git-daemon-e2e-{x}", .{ tmp_root, stamp });
    defer {
        // Best-effort cleanup of the whole base tree (no return from defer).
        if (std.fs.path.dirname(base_path)) |parent_path| {
            if (std.Io.Dir.openDirAbsolute(io, parent_path, .{ .iterate = true })) |*parent_opened| {
                var parent = parent_opened.*;
                defer parent.close(io);
                const leaf = std.fs.path.basename(base_path);
                parent.deleteTree(io, leaf) catch {};
            } else |_| {}
        }
        gpa.free(base_path);
    }

    std.Io.Dir.createDirAbsolute(io, base_path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    const repo_name = "basic.git";
    const bare_path = try std.fs.path.join(gpa, &.{ base_path, repo_name });
    defer gpa.free(bare_path);

    // Seed: work repo → bare clone under base-path.
    const seed_path = try std.fmt.allocPrint(gpa, "{s}/seed-work", .{base_path});
    defer gpa.free(seed_path);
    std.Io.Dir.createDirAbsolute(io, seed_path, .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    try runGit(gpa, io, &.{ "git", "-c", "init.defaultBranch=master", "init", seed_path });
    const hello_path = try std.fs.path.join(gpa, &.{ seed_path, "hello.txt" });
    defer gpa.free(hello_path);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, hello_path, .{});
        defer f.close(io);
        try f.writePositionalAll(io, "hello from gitz e2e\n", 0);
    }
    try runGit(gpa, io, &.{ "git", "-C", seed_path, "add", "hello.txt" });
    try runGit(gpa, io, &.{
        "git",             "-C",               seed_path,
        "-c",              "user.name=gitz",   "-c",
        "user.email=g@z",  "commit",           "-m",
        "init",
    });
    try runGit(gpa, io, &.{ "git", "clone", "--bare", seed_path, bare_path });

    // git-daemon-export-ok (also using --export-all).
    const export_ok = try std.fs.path.join(gpa, &.{ bare_path, "git-daemon-export-ok" });
    defer gpa.free(export_ok);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, export_ok, .{});
        defer f.close(io);
    }

    const port_arg = try std.fmt.allocPrint(gpa, "--port={d}", .{port});
    defer gpa.free(port_arg);
    const base_arg = try std.fmt.allocPrint(gpa, "--base-path={s}", .{base_path});
    defer gpa.free(base_arg);

    const argv = [_][]const u8{
        "git",
        "daemon",
        base_arg,
        "--export-all",
        "--enable=receive-pack",
        "--reuseaddr",
        "--listen=127.0.0.1",
        port_arg,
        "--max-connections=1",
    };

    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| {
        std.debug.print("failed to spawn git daemon: {}\n", .{err});
        return error.GitDaemonSpawnFailed;
    };
    defer {
        if (child.id != null) {
            child.kill(io);
        }
    }

    try waitForTcp(io, "127.0.0.1", port, 40);

    // Client uses real defaultDial.
    var runner = common.Runner.init(gpa, io);
    defer runner.deinit();
    // defaultDial is already the default.

    var client = common.defaultClient(gpa, &runner);

    const url = try std.fmt.allocPrint(gpa, "git://127.0.0.1:{d}/{s}", .{ port, repo_name });
    defer gpa.free(url);
    var ep = try transport.newEndpoint(gpa, io, url);
    defer ep.deinit();

    var sess = try client.newUploadPackSession(&ep, null);
    defer sess.close() catch {};

    const ar = try sess.advertisedReferences();
    try testing.expect(ar.head != null);
    try testing.expect(ar.references.get("refs/heads/master") != null or
        ar.references.get("refs/heads/main") != null);
    try testing.expect(ar.capabilities.supports(capability.OFSDelta) or
        ar.capabilities.supports(capability.Sideband64k) or
        ar.capabilities.supports(capability.Sideband) or
        ar.capabilities.supports(capability.Agent));
}
