//! Package transport — Git transport interfaces and endpoint parsing.
//!
//! Port of go-git v5.19.2 `plumbing/transport` (`common.go`).
//!
//! Zig does not use Go interfaces. Backends implement the method sets below on
//! **concrete types**. The client registry stores a thin `Transport` vtable so
//! heterogeneous protocols can share one map (see `client` package).
//!
//! # Transport method set
//!
//! | Method | Role |
//! |--------|------|
//! | `newUploadPackSession(endpoint, auth)` | Start git-upload-pack for an endpoint |
//! | `newReceivePackSession(endpoint, auth)` | Start git-receive-pack for an endpoint |
//!
//! # Session method set
//!
//! | Method | Role |
//! |--------|------|
//! | `advertisedReferences()` | Ref advertisement; `RepositoryNotFound` / `EmptyRemoteRepository` |
//! | `advertisedReferencesContext(ctx)` | Same with cancellation context |
//! | `close()` | Release session resources (`io.Closer`) |
//!
//! # UploadPackSession method set
//!
//! Extends Session:
//!
//! | Method | Role |
//! |--------|------|
//! | `uploadPack(ctx, request)` | Fetch pack (`*packp.UploadPackRequest` → response) |
//!
//! # ReceivePackSession method set
//!
//! Extends Session:
//!
//! | Method | Role |
//! |--------|------|
//! | `receivePack(ctx, request)` | Push pack (`*packp.ReferenceUpdateRequest` → report-status) |
//!
//! # AuthMethod method set
//!
//! | Method | Role |
//! |--------|------|
//! | `name()` | Auth method name |
//! | `format` / `string` | `fmt.Stringer` — human-readable form |
//!
//! Concrete auth types (HTTP basic, SSH keys, …) live in protocol packages
//! (phase 13). Use `AuthMethod` vtable when a session must store heterogeneous auth.
//!
//! # Errors
//!
//! See `error.zig`. Endpoint parse failures use `InvalidEndpoint` (go-git
//! wraps non-absolute URLs in `plumbing.PermanentError`).

const std = @import("std");
const testing = std.testing;
const capability = @import("capability");

const error_mod = @import("error.zig");
const endpoint_mod = @import("endpoint.zig");
const url_helpers_mod = @import("url_helpers.zig");

// --- error.zig ---
pub const Error = error_mod.Error;

// --- endpoint.zig ---
pub const Endpoint = endpoint_mod.Endpoint;
pub const ProxyOptions = endpoint_mod.ProxyOptions;
pub const newEndpoint = endpoint_mod.newEndpoint;

// --- url helpers (private to package, re-exported for tests) ---
pub const matchesScheme = url_helpers_mod.matchesScheme;
pub const matchesScpLike = url_helpers_mod.matchesScpLike;
pub const findScpLikeComponents = url_helpers_mod.findScpLikeComponents;
pub const isLocalEndpoint = url_helpers_mod.isLocalEndpoint;

// ---------------------------------------------------------------------------
// Service names (go-git constants)
// ---------------------------------------------------------------------------

/// go-git `UploadPackServiceName`.
pub const UploadPackServiceName: []const u8 = "git-upload-pack";

/// go-git `ReceivePackServiceName`.
pub const ReceivePackServiceName: []const u8 = "git-receive-pack";

// ---------------------------------------------------------------------------
// Method-set name tokens (documentation / inventories; not traits)
// ---------------------------------------------------------------------------

pub const method_sets = struct {
    pub const Transport = "Transport";
    pub const Session = "Session";
    pub const UploadPackSession = "UploadPackSession";
    pub const ReceivePackSession = "ReceivePackSession";
    pub const AuthMethod = "AuthMethod";
};

// ---------------------------------------------------------------------------
// AuthMethod vtable (optional heterogeneous storage)
// ---------------------------------------------------------------------------

/// go-git `AuthMethod` as a typed function-pointer interface.
pub const AuthMethod = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// go-git `AuthMethod.Name`.
        name: *const fn (ptr: *anyopaque) []const u8,
        /// go-git `fmt.Stringer` / `String`.
        format: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8,
    };

    pub fn name(self: AuthMethod) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn format(self: AuthMethod, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return self.vtable.format(self.ptr, allocator);
    }
};

// ---------------------------------------------------------------------------
// Transport vtable (client protocol map)
// ---------------------------------------------------------------------------

/// Opaque session handle returned by transport backends until typed sessions
/// are needed by callers. Concrete backends may cast to their session type.
pub const SessionHandle = *anyopaque;

/// go-git `Transport` as a typed function-pointer interface for the client map.
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// go-git `Transport.NewUploadPackSession`.
        newUploadPackSession: *const fn (
            ptr: *anyopaque,
            endpoint: *const Endpoint,
            auth: ?AuthMethod,
        ) anyerror!?SessionHandle,

        /// go-git `Transport.NewReceivePackSession`.
        newReceivePackSession: *const fn (
            ptr: *anyopaque,
            endpoint: *const Endpoint,
            auth: ?AuthMethod,
        ) anyerror!?SessionHandle,
    };

    pub fn newUploadPackSession(
        self: Transport,
        endpoint: *const Endpoint,
        auth: ?AuthMethod,
    ) anyerror!?SessionHandle {
        return self.vtable.newUploadPackSession(self.ptr, endpoint, auth);
    }

    pub fn newReceivePackSession(
        self: Transport,
        endpoint: *const Endpoint,
        auth: ?AuthMethod,
    ) anyerror!?SessionHandle {
        return self.vtable.newReceivePackSession(self.ptr, endpoint, auth);
    }
};

// ---------------------------------------------------------------------------
// Unsupported capabilities (go-git client filter list)
// ---------------------------------------------------------------------------

/// Capabilities not supported by any client implementation
/// (go-git `UnsupportedCapabilities`).
pub const UnsupportedCapabilities = [_]capability.Capability{
    capability.MultiACK,
    capability.MultiACKDetailed,
    capability.ThinPack,
};

/// Remove all `UnsupportedCapabilities` from `list`
/// (go-git `FilterUnsupportedCapabilities`).
pub fn filterUnsupportedCapabilities(list: *capability.List) void {
    for (UnsupportedCapabilities) |c| {
        list.delete(c);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    _ = error_mod;
    _ = endpoint_mod;
    _ = url_helpers_mod;
}

test "service names" {
    try testing.expectEqualStrings("git-upload-pack", UploadPackServiceName);
    try testing.expectEqualStrings("git-receive-pack", ReceivePackServiceName);
}

test "FilterUnsupportedCapabilities" {
    const gpa = testing.allocator;
    var list = capability.List.init(gpa);
    defer list.deinit();

    try list.set(capability.MultiACK, &.{});
    try list.set(capability.OFSDelta, &.{});
    try testing.expect(list.supports(capability.MultiACK));
    try testing.expect(list.supports(capability.OFSDelta));

    filterUnsupportedCapabilities(&list);

    try testing.expect(!list.supports(capability.MultiACK));
    try testing.expect(!list.supports(capability.MultiACKDetailed));
    try testing.expect(!list.supports(capability.ThinPack));
    try testing.expect(list.supports(capability.OFSDelta));
}

test "package surface errors and constructors" {
    // Ensure error set members exist (compile-time surface) without tautology.
    const errs = [_]Error{
        error.RepositoryNotFound,
        error.EmptyRemoteRepository,
        error.AuthenticationRequired,
        error.AuthorizationFailed,
        error.EmptyUploadPackRequest,
        error.InvalidAuthMethod,
        error.AlreadyConnected,
    };
    try testing.expect(errs.len == 7);
    _ = newEndpoint;
    _ = filterUnsupportedCapabilities;
    _ = Transport;
    _ = AuthMethod;
    _ = method_sets.Transport;
}
