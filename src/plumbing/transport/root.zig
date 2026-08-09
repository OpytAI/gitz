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
//! Use the `AuthMethod` vtable when a session must store heterogeneous auth.
//!
//! # Errors
//!
//! See `error.zig`. Endpoint parse failures use `InvalidEndpoint` (go-git
//! wraps non-absolute URLs in `plumbing.PermanentError`).

const std = @import("std");
const testing = std.testing;
const capability = @import("capability");
const packp = @import("packp");

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
        /// Optional protocol-specific credential view. Implementations return
        /// their original typed object only for a matching protocol name.
        protocol_credentials: ?*const fn (ptr: *anyopaque, protocol: []const u8) ?*anyopaque = null,
    };

    pub fn name(self: AuthMethod) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn format(self: AuthMethod, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return self.vtable.format(self.ptr, allocator);
    }

    pub fn protocolCredentials(self: AuthMethod, protocol: []const u8) ?*anyopaque {
        const get = self.vtable.protocol_credentials orelse return null;
        return get(self.ptr, protocol);
    }
};

// ---------------------------------------------------------------------------
// Transport vtable (client protocol map)
// ---------------------------------------------------------------------------

/// Cooperative operation control for synchronous transports.
///
/// Backends check this value before each advertised-refs or pack operation. It
/// can stop work between protocol operations. It cannot preempt an
/// operating-system call that is already blocked; callers that need that
/// guarantee must also configure an I/O deadline on their dialer/client.
pub const OperationContext = struct {
    ptr: ?*anyopaque = null,
    cancelled_fn: ?*const fn (?*anyopaque) bool = null,
    deadline_exceeded_fn: ?*const fn (?*anyopaque) bool = null,

    pub fn check(self: OperationContext) error{ Cancelled, DeadlineExceeded }!void {
        if (self.cancelled_fn) |f| {
            if (f(self.ptr)) return error.Cancelled;
        }
        if (self.deadline_exceeded_fn) |f| {
            if (f(self.ptr)) return error.DeadlineExceeded;
        }
    }
};

pub const ReceivePackOutcome = struct {
    report: ?*packp.ReportStatus,
    err: ?anyerror,
};

/// Type-erased, owned upload-pack session.
///
/// `close` closes the concrete session and frees the allocation that stores it.
pub const UploadPackSession = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        close: *const fn (*anyopaque) void,
        advertised_references: *const fn (*anyopaque, OperationContext) anyerror!*packp.AdvRefs,
        upload_pack: *const fn (*anyopaque, OperationContext, *const packp.UploadPackRequest) anyerror!*packp.UploadPackResponse,
        set_auth: *const fn (*anyopaque, ?AuthMethod) anyerror!void,
    };

    pub fn close(self: *UploadPackSession) void {
        self.vtable.close(self.ptr);
        self.* = undefined;
    }

    /// Caller owns the returned refs and frees them with `packp.freeAdvRefs`.
    pub fn advertisedReferences(self: UploadPackSession) !*packp.AdvRefs {
        return self.advertisedReferencesContext(.{});
    }

    pub fn advertisedReferencesContext(self: UploadPackSession, ctx: OperationContext) !*packp.AdvRefs {
        try ctx.check();
        return self.vtable.advertised_references(self.ptr, ctx);
    }

    pub fn uploadPack(self: UploadPackSession, req: *const packp.UploadPackRequest) !*packp.UploadPackResponse {
        return self.uploadPackContext(.{}, req);
    }

    pub fn uploadPackContext(self: UploadPackSession, ctx: OperationContext, req: *const packp.UploadPackRequest) !*packp.UploadPackResponse {
        try ctx.check();
        return self.vtable.upload_pack(self.ptr, ctx, req);
    }

    pub fn setAuth(self: UploadPackSession, auth: ?AuthMethod) !void {
        return self.vtable.set_auth(self.ptr, auth);
    }
};

/// Type-erased, owned receive-pack session.
pub const ReceivePackSession = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        close: *const fn (*anyopaque) void,
        advertised_references: *const fn (*anyopaque, OperationContext) anyerror!*packp.AdvRefs,
        receive_pack: *const fn (*anyopaque, OperationContext, *const packp.ReferenceUpdateRequest) anyerror!ReceivePackOutcome,
        set_auth: *const fn (*anyopaque, ?AuthMethod) anyerror!void,
    };

    pub fn close(self: *ReceivePackSession) void {
        self.vtable.close(self.ptr);
        self.* = undefined;
    }

    /// Caller owns the returned refs and frees them with `packp.freeAdvRefs`.
    pub fn advertisedReferences(self: ReceivePackSession) !*packp.AdvRefs {
        return self.advertisedReferencesContext(.{});
    }

    pub fn advertisedReferencesContext(self: ReceivePackSession, ctx: OperationContext) !*packp.AdvRefs {
        try ctx.check();
        return self.vtable.advertised_references(self.ptr, ctx);
    }

    pub fn receivePack(self: ReceivePackSession, req: *const packp.ReferenceUpdateRequest) !ReceivePackOutcome {
        return self.receivePackContext(.{}, req);
    }

    pub fn receivePackContext(self: ReceivePackSession, ctx: OperationContext, req: *const packp.ReferenceUpdateRequest) !ReceivePackOutcome {
        try ctx.check();
        return self.vtable.receive_pack(self.ptr, ctx, req);
    }

    pub fn setAuth(self: ReceivePackSession, auth: ?AuthMethod) !void {
        return self.vtable.set_auth(self.ptr, auth);
    }
};

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
        ) anyerror!UploadPackSession,

        /// go-git `Transport.NewReceivePackSession`.
        newReceivePackSession: *const fn (
            ptr: *anyopaque,
            endpoint: *const Endpoint,
            auth: ?AuthMethod,
        ) anyerror!ReceivePackSession,
    };

    pub fn newUploadPackSession(
        self: Transport,
        endpoint: *const Endpoint,
        auth: ?AuthMethod,
    ) anyerror!UploadPackSession {
        return self.vtable.newUploadPackSession(self.ptr, endpoint, auth);
    }

    pub fn newReceivePackSession(
        self: Transport,
        endpoint: *const Endpoint,
        auth: ?AuthMethod,
    ) anyerror!ReceivePackSession {
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

test "OperationContext reports cancellation and deadline independently" {
    const State = struct {
        cancelled: bool = false,
        expired: bool = false,

        fn isCancelled(ptr: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            return self.cancelled;
        }

        fn isExpired(ptr: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            return self.expired;
        }
    };

    var state: State = .{};
    const ctx = OperationContext{
        .ptr = &state,
        .cancelled_fn = State.isCancelled,
        .deadline_exceeded_fn = State.isExpired,
    };
    try ctx.check();
    state.cancelled = true;
    try testing.expectError(error.Cancelled, ctx.check());
    state.cancelled = false;
    state.expired = true;
    try testing.expectError(error.DeadlineExceeded, ctx.check());
}
