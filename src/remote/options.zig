//! Fetch / Push / List options (go-git `options.go` remote-related types).

const std = @import("std");
const plumbing = @import("plumbing");
const gitconfig = @import("gitconfig");
const transport = @import("transport");

const RefSpec = gitconfig.RefSpec;
const Hash = plumbing.Hash;
const ReferenceName = plumbing.ReferenceName;
const AuthMethod = transport.AuthMethod;
const ProxyOptions = transport.ProxyOptions;

/// go-git `DefaultRemoteName`.
pub const default_remote_name: []const u8 = "origin";

/// go-git default ListOptions.Timeout when the field is zero (seconds).
/// Applied when opening network transports; in-process MapLoader
/// ignores deadlines.
pub const default_list_timeout_sec: i32 = 10;

/// Shared auth / TLS / proxy fields for List, Fetch, and Push options.
///
/// Matches go-git's repeated ClientCert / ClientKey / CABundle / ProxyOptions
/// / Auth / InsecureSkipTLS on each options struct, without triplicating the
/// field list in three places for session open.
pub const TransportClientOpts = struct {
    auth: ?AuthMethod = null,
    insecure_skip_tls: bool = false,
    client_cert: []const u8 = "",
    client_key: []const u8 = "",
    ca_bundle: []const u8 = "",
    proxy: ProxyOptions = .{},
    /// Cooperative cancellation/deadline hook checked before advertised-ref
    /// and pack operations. Blocking OS calls still require an I/O deadline.
    operation_context: transport.OperationContext = .{},
};

/// go-git `TagMode`.
pub const TagMode = enum {
    /// go-git `InvalidTagMode` — treated as `.following` by `validate`.
    invalid,
    /// go-git `TagFollowing`.
    following,
    /// go-git `AllTags`.
    all,
    /// go-git `NoTags`.
    none,
};

/// go-git `PeelingOption` for `ListOptions`.
pub const PeelingOption = enum(u8) {
    /// Ignore peeled refs (go-git default for plain list).
    ignore_peeled = 0,
    /// Only peeled refs.
    only_peeled = 1,
    /// Append peeled refs after regular refs.
    append_peeled = 2,
};

/// go-git `ForceWithLease`.
pub const ForceWithLease = struct {
    /// When non-empty, only this remote ref is protected; empty protects all.
    ref_name: ReferenceName = ReferenceName.init(""),
    /// Expected object id on the remote advertisement (`ZeroHash` → use tracking).
    hash: Hash = plumbing.ZeroHash,
};

/// One server-side push option (go-git push-options map entry).
pub const PushOption = struct {
    key: []const u8 = "",
    value: []const u8 = "",
};

/// go-git `FetchOptions`.
pub const FetchOptions = struct {
    remote_name: []const u8 = "",
    remote_url: []const u8 = "",
    ref_specs: []const RefSpec = &.{},
    depth: i32 = 0,
    /// Auth, TLS, mTLS, proxy (go-git flat fields on FetchOptions).
    transport: TransportClientOpts = .{},
    /// Human-readable server progress (go-git `sideband.Progress`). When null
    /// and the remote supports it, `no-progress` is requested.
    progress: ?*std.Io.Writer = null,
    /// Tag fetch mode (default `.following` after `validate`).
    tags: TagMode = .invalid,
    force: bool = false,
    prune: bool = false,

    /// go-git `FetchOptions.Validate`.
    pub fn validate(self: *FetchOptions) !void {
        if (self.remote_name.len == 0) self.remote_name = default_remote_name;
        if (self.tags == .invalid) self.tags = .following;
        for (self.ref_specs) |rs| try rs.validate();
    }

    // Flat accessors matching go-git field names for callers that set TLS
    // without nesting (and for inventory semantic IDs).

    pub fn auth(self: *const FetchOptions) ?AuthMethod {
        return self.transport.auth;
    }
    pub fn insecureSkipTls(self: *const FetchOptions) bool {
        return self.transport.insecure_skip_tls;
    }
    pub fn clientCert(self: *const FetchOptions) []const u8 {
        return self.transport.client_cert;
    }
    pub fn clientKey(self: *const FetchOptions) []const u8 {
        return self.transport.client_key;
    }
    pub fn caBundle(self: *const FetchOptions) []const u8 {
        return self.transport.ca_bundle;
    }
    pub fn proxy(self: *const FetchOptions) ProxyOptions {
        return self.transport.proxy;
    }
};

/// go-git `PushOptions`.
pub const PushOptions = struct {
    remote_name: []const u8 = "",
    remote_url: []const u8 = "",
    ref_specs: []const RefSpec = &.{},
    transport: TransportClientOpts = .{},
    /// Human-readable server progress (go-git `sideband.Progress`).
    progress: ?*std.Io.Writer = null,
    prune: bool = false,
    force: bool = false,
    require_remote_refs: []const RefSpec = &.{},
    follow_tags: bool = false,
    force_with_lease: ?ForceWithLease = null,
    /// Server push options (empty by default).
    options: []const PushOption = &.{},
    atomic: bool = false,

    /// go-git `PushOptions.Validate`.
    ///
    /// Does **not** inject the default push refspec: that needs an owned string
    /// the caller can free. `push.zig` fills an empty `ref_specs` after validate.
    pub fn validate(self: *PushOptions) !void {
        if (self.remote_name.len == 0) self.remote_name = default_remote_name;
        for (self.ref_specs) |rs| try rs.validate();
        for (self.require_remote_refs) |rs| try rs.validate();
    }
};

/// go-git `ListOptions`.
pub const ListOptions = struct {
    transport: TransportClientOpts = .{},
    peeling: PeelingOption = .ignore_peeled,
    /// Timeout in seconds. `0` means default (`default_list_timeout_sec`);
    /// negative is `error.InvalidTimeout`.
    timeout_sec: i32 = 0,

    /// Resolved timeout seconds after applying the zero → default rule.
    pub fn effectiveTimeoutSec(self: ListOptions) i32 {
        if (self.timeout_sec == 0) return default_list_timeout_sec;
        return self.timeout_sec;
    }
};

test "FetchOptions validate defaults" {
    var o: FetchOptions = .{};
    try o.validate();
    try std.testing.expectEqualStrings(default_remote_name, o.remote_name);
    try std.testing.expect(o.tags == .following);
}

test "PushOptions validate defaults name" {
    var o: PushOptions = .{};
    try o.validate();
    try std.testing.expectEqualStrings(default_remote_name, o.remote_name);
}

test "ListOptions effectiveTimeoutSec" {
    try std.testing.expectEqual(@as(i32, 10), (ListOptions{}).effectiveTimeoutSec());
    try std.testing.expectEqual(@as(i32, 30), (ListOptions{ .timeout_sec = 30 }).effectiveTimeoutSec());
}

test "PeelingOption values match go-git" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(PeelingOption.ignore_peeled));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(PeelingOption.only_peeled));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(PeelingOption.append_peeled));
}

test "TransportClientOpts nested on options" {
    var fo: FetchOptions = .{
        .transport = .{
            .insecure_skip_tls = true,
            .client_cert = "c",
            .client_key = "k",
            .ca_bundle = "a",
        },
    };
    try fo.validate();
    try std.testing.expect(fo.transport.insecure_skip_tls);
    try std.testing.expectEqualStrings("c", fo.clientCert());
    try std.testing.expect(fo.progress == null);

    const po = PushOptions{};
    try std.testing.expectEqualStrings("", po.transport.client_cert);

    const lo = ListOptions{ .transport = .{ .client_cert = "list" } };
    try std.testing.expectEqualStrings("list", lo.transport.client_cert);
}

test "TransportClientOpts carries operation cancellation" {
    const State = struct {
        cancelled: bool,
        fn check(ptr: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            return self.cancelled;
        }
    };
    var state = State{ .cancelled = true };
    const opts = TransportClientOpts{
        .operation_context = .{ .ptr = &state, .cancelled_fn = State.check },
    };
    try std.testing.expectError(error.Cancelled, opts.operation_context.check());
}
