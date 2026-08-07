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
//! # Phase 8
//!
//! `Protocols` starts **empty**. HTTP/HTTPS/SSH/git/file transports register
//! in phase 13. Tests install a mock transport then call `newClient`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const transport = @import("transport");

pub const Endpoint = transport.Endpoint;
pub const Transport = transport.Transport;
pub const AuthMethod = transport.AuthMethod;
pub const Error = transport.Error;

/// Protocols supported by the client registry (go-git `Protocols`).
///
/// Phase 8: empty map. Use `installProtocol` to register schemes.
/// Not thread-safe — single-threaded use only.
var protocols: std.StringHashMapUnmanaged(Transport) = .empty;
var protocols_allocator: ?Allocator = null;

/// Initialize the protocol map allocator (Zig needs an allocator for keys).
/// Idempotent when called with the same allocator; call once per process/test.
pub fn init(allocator: Allocator) void {
    if (protocols_allocator == null) {
        protocols_allocator = allocator;
    }
}

/// Free all registered scheme keys and clear the map.
pub fn deinit() void {
    const a = protocols_allocator orelse return;
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
// Tests (go-git plumbing/transport/client/client_test.go adapted for phase 8)
// ---------------------------------------------------------------------------

const DummyTransport = struct {
    fn newUploadPackSession(
        _: *anyopaque,
        _: *const Endpoint,
        _: ?AuthMethod,
    ) anyerror!?transport.SessionHandle {
        return null;
    }

    fn newReceivePackSession(
        _: *anyopaque,
        _: *const Endpoint,
        _: ?AuthMethod,
    ) anyerror!?transport.SessionHandle {
        return null;
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

test "Protocols empty by default (phase 8)" {
    const gpa = testing.allocator;
    init(gpa);
    defer deinit();
    try testing.expect(!hasProtocol("http"));
    try testing.expect(!hasProtocol("https"));
    try testing.expect(!hasProtocol("ssh"));
    try testing.expect(!hasProtocol("git"));
    try testing.expect(!hasProtocol("file"));
}
