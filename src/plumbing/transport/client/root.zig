//! Package client — protocol registry and `NewClient`.
//!
//! Port of go-git v5.19.2 `plumbing/transport/client`.
//!
//! # Concurrency
//!
//! The `Protocols` map is **single-threaded**. Concurrent mutation or lookup
//! from multiple threads is unsupported (same model as go-git free lists /
//! package-level maps used without locks). Call `init` once before use.
//!
//! # Defaults
//!
//! After `init` + `installDefaults` (or `initWithDefaults`), schemes
//! `http`/`https`/`ssh`/`git`/`file` are registered like go-git's package-level
//! `Protocols` map. Tests may still `installProtocol` to replace a scheme
//! (e.g. MapLoader server).
//!
//! # Process lifecycle (hosts)
//!
//! The registry and default clients are **process-scoped**. After any network
//! (or `init` / `installDefaults`) use, call `deinit()` at host/engine shutdown
//! with the same process lifetime as `init`:
//!
//! 1. Tear down remotes / sessions that still borrow transports.
//! 2. `client.deinit()` — frees scheme keys, default clients, and clears the map.
//! 3. `utils/sync.deinitPools(allocator)` — drains zlib/buffer free lists used
//!    during pack encode/decode (same allocator as get/put).
//!
//! Do **not** call `deinit` from repository teardown (`PlainRepository.deinit`
//! or free of `RepositoryFor` storage): one registry serves the whole process.
//! Memory `RepositoryFor` has no `deinit` method. Multi-repo hosts shut the
//! registry down once at process exit.
//!
//! Freestanding wasm demos in this tree never call `init` / `installDefaults`,
//! so they do not call `client.deinit` (docs-only for those hosts). Native GPA
//! tests that call `initWithDefaults` must `defer deinit()`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const transport = @import("transport");
const transport_http = @import("transport_http");
const transport_ssh = @import("transport_ssh");
const transport_file = @import("transport_file");
const transport_git = @import("transport_git");

pub const Endpoint = transport.Endpoint;
pub const Transport = transport.Transport;
pub const AuthMethod = transport.AuthMethod;
pub const Error = transport.Error;

/// Protocols supported by the client registry (go-git `Protocols`).
///
/// Not thread-safe — single-threaded use only.
var protocols: std.StringHashMapUnmanaged(Transport) = .empty;
var protocols_allocator: ?Allocator = null;

// Owned default clients (freed in deinitDefaults / deinit).
var default_http: ?*transport_http.Client = null;
var default_ssh: ?*transport_ssh.Client = null;
var default_file: ?*transport_file.FileClient = null;
var default_git_runner: ?*transport_git.Runner = null;
var default_git_client: ?*transport_git.Client = null;
var defaults_installed: bool = false;

/// Initialize the protocol map allocator (Zig needs an allocator for keys).
/// The first allocator owns the registry and lazy default clients until
/// `deinit`; later calls keep that owner rather than mixing allocator lifetimes.
pub fn init(allocator: Allocator) void {
    if (protocols_allocator == null) {
        protocols_allocator = allocator;
    }
}

/// `init` then `installDefaults` (go-git package-load behavior).
pub fn initWithDefaults(allocator: Allocator) !void {
    init(allocator);
    try installDefaults(allocator);
}

/// Register default file/git/http/https/ssh clients (go-git `Protocols` defaults).
///
/// Idempotent. Heap-owns clients until `deinit`. Does not replace schemes that
/// are already registered (so tests can install mocks before calling this, or
/// call `installProtocol` after to override).
pub fn installDefaults(allocator: Allocator) !void {
    init(allocator);
    if (defaults_installed) return;
    const owner = protocols_allocator.?;
    var added_http = false;
    var added_https = false;
    var added_ssh = false;
    var added_file = false;
    var added_git = false;
    errdefer {
        if (added_http) installProtocol("http", null) catch {};
        if (added_https) installProtocol("https", null) catch {};
        if (added_ssh) installProtocol("ssh", null) catch {};
        if (added_file) installProtocol("file", null) catch {};
        if (added_git) installProtocol("git", null) catch {};
        deinitDefaults(owner);
    }

    // http + https share one client (go-git).
    if (!hasProtocol("http") or !hasProtocol("https")) {
        const hc = try owner.create(transport_http.Client);
        errdefer owner.destroy(hc);
        hc.* = try transport_http.defaultClient(owner);
        default_http = hc;
        const t = transport_http.asTransport(hc);
        if (!hasProtocol("http")) {
            try installProtocol("http", t);
            added_http = true;
        }
        if (!hasProtocol("https")) {
            try installProtocol("https", t);
            added_https = true;
        }
    }

    if (!hasProtocol("ssh")) {
        const sc = try owner.create(transport_ssh.Client);
        errdefer owner.destroy(sc);
        sc.* = try transport_ssh.defaultClient(owner);
        default_ssh = sc;
        try installProtocol("ssh", sc.asTransport());
        added_ssh = true;
    }

    if (!hasProtocol("file")) {
        const fc = try owner.create(transport_file.FileClient);
        errdefer owner.destroy(fc);
        fc.* = try transport_file.defaultClient(owner);
        default_file = fc;
        try installProtocol("file", fc.asTransport());
        added_file = true;
    }

    if (!hasProtocol("git")) {
        const runner = try owner.create(transport_git.Runner);
        errdefer owner.destroy(runner);
        // Single-threaded Io for default git dial (same pattern as remote/session).
        const Holder = struct {
            threadlocal var threaded: std.Io.Threaded = .init_single_threaded;
        };
        runner.* = transport_git.Runner.init(owner, Holder.threaded.io());
        default_git_runner = runner;
        const gc = try owner.create(transport_git.Client);
        errdefer owner.destroy(gc);
        gc.* = transport_git.defaultClient(owner, runner);
        default_git_client = gc;
        try installProtocol("git", gc.asTransport());
        added_git = true;
    }

    defaults_installed = true;
}

fn deinitDefaults(allocator: Allocator) void {
    if (default_http) |c| {
        c.deinit();
        allocator.destroy(c);
        default_http = null;
    }
    if (default_ssh) |c| {
        c.deinit();
        allocator.destroy(c);
        default_ssh = null;
    }
    if (default_file) |c| {
        c.deinit();
        allocator.destroy(c);
        default_file = null;
    }
    if (default_git_client) |c| {
        allocator.destroy(c);
        default_git_client = null;
    }
    if (default_git_runner) |r| {
        r.deinit();
        allocator.destroy(r);
        default_git_runner = null;
    }
    defaults_installed = false;
}

/// Free default clients, registered scheme keys, and clear the map.
///
/// Host/process shutdown hook (not repository teardown). Safe when `init` was
/// never called. After this, call `init` again before further registry use.
pub fn deinit() void {
    const a = protocols_allocator orelse return;
    deinitDefaults(a);
    var it = protocols.iterator();
    while (it.next()) |entry| {
        a.free(entry.key_ptr.*);
    }
    protocols.deinit(a);
    protocols = .empty;
    protocols_allocator = null;
}

/// go-git `InstallProtocol` — add or replace a scheme. Pass `null` to remove.
pub fn installProtocol(scheme: []const u8, c: ?Transport) Allocator.Error!void {
    const a = protocols_allocator orelse return error.OutOfMemory;
    if (c) |client| {
        if (protocols.getEntry(scheme)) |entry| {
            entry.value_ptr.* = client;
            return;
        }
        const key = try a.dupe(u8, scheme);
        errdefer a.free(key);
        try protocols.put(a, key, client);
    } else {
        if (protocols.fetchRemove(scheme)) |kv| {
            a.free(kv.key);
        }
    }
}

/// Look up a registered transport (test/helper; go-git exposes `Protocols` map).
pub fn getProtocol(scheme: []const u8) ?Transport {
    return protocols.get(scheme);
}

/// True when `scheme` is present in the map.
pub fn hasProtocol(scheme: []const u8) bool {
    return protocols.contains(scheme);
}

/// go-git `NewClient` — transport for `endpoint.Protocol`, or error.
pub fn newClient(endpoint: *const Endpoint) Error!Transport {
    const client = protocols.get(endpoint.protocol) orelse {
        return error.UnsupportedScheme;
    };
    return client;
}

// ---------------------------------------------------------------------------
// Tests adapted from go-git plumbing/transport/client/client_test.go.
// ---------------------------------------------------------------------------

const DummyTransport = struct {
    fn newUploadPackSession(
        _: *anyopaque,
        _: *const Endpoint,
        _: ?AuthMethod,
    ) anyerror!transport.UploadPackSession {
        return error.NotImplemented;
    }

    fn newReceivePackSession(
        _: *anyopaque,
        _: *const Endpoint,
        _: ?AuthMethod,
    ) anyerror!transport.ReceivePackSession {
        return error.NotImplemented;
    }

    const vtable = transport.Transport.VTable{
        .newUploadPackSession = newUploadPackSession,
        .newReceivePackSession = newReceivePackSession,
    };

    fn asTransport(self: *DummyTransport) Transport {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

test "InstallProtocol and NewClient" {
    const gpa = testing.allocator;
    init(gpa);
    defer deinit();

    var dummy: DummyTransport = .{};
    try installProtocol("newscheme", dummy.asTransport());
    try testing.expect(hasProtocol("newscheme"));
    try testing.expect(getProtocol("newscheme") != null);

    var ep = try transport.newEndpoint(gpa, testing.io, "newscheme://github.com/src-d/go-git");
    defer ep.deinit();

    const client = try newClient(&ep);
    try testing.expect(client.ptr == dummy.asTransport().ptr);
}

test "InstallProtocol nil removes scheme" {
    const gpa = testing.allocator;
    init(gpa);
    defer deinit();

    var dummy: DummyTransport = .{};
    try installProtocol("newscheme", dummy.asTransport());
    try installProtocol("newscheme", null);
    try testing.expect(!hasProtocol("newscheme"));
}

test "NewClient unknown scheme" {
    const gpa = testing.allocator;
    init(gpa);
    defer deinit();

    var ep = try transport.newEndpoint(gpa, testing.io, "unknown://github.com/src-d/go-git");
    defer ep.deinit();
    try testing.expectError(error.UnsupportedScheme, newClient(&ep));
}

test "Protocols empty before installDefaults" {
    const gpa = testing.allocator;
    init(gpa);
    defer deinit();
    try testing.expect(!hasProtocol("http"));
    try testing.expect(!hasProtocol("https"));
    try testing.expect(!hasProtocol("ssh"));
    try testing.expect(!hasProtocol("git"));
    try testing.expect(!hasProtocol("file"));
}

test "installDefaults registers http https ssh git file" {
    const gpa = testing.allocator;
    try initWithDefaults(gpa);
    defer deinit();
    try testing.expect(hasProtocol("http"));
    try testing.expect(hasProtocol("https"));
    try testing.expect(hasProtocol("ssh"));
    try testing.expect(hasProtocol("git"));
    try testing.expect(hasProtocol("file"));

    var ep = try transport.newEndpoint(gpa, testing.io, "https://example.com/repo.git");
    defer ep.deinit();
    _ = try newClient(&ep);
}
