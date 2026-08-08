//! Fetch / Push / List options (go-git `options.go` remote-related types).

const std = @import("std");
const plumbing = @import("plumbing");
const gitconfig = @import("gitconfig");
const transport = @import("transport");

const RefSpec = gitconfig.RefSpec;
const Hash = plumbing.Hash;
const ReferenceName = plumbing.ReferenceName;

/// go-git `DefaultRemoteName`.
pub const default_remote_name: []const u8 = "origin";

/// go-git default ListOptions.Timeout when the field is zero (seconds).
/// Not enforced in-process (MapLoader / embedded server); reserved for phase-13
/// network transports that honor deadlines.
pub const default_list_timeout_sec: i32 = 10;

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
pub const PeelingOption = enum {
    /// Ignore peeled refs (go-git default for plain list).
    ignore_peeled,
    /// Append peeled refs after regular refs.
    append_peeled,
    /// Only peeled refs.
    only_peeled,
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
    auth: ?transport.AuthMethod = null,
    /// Tag fetch mode (default `.following` after `validate`).
    tags: TagMode = .invalid,
    force: bool = false,
    prune: bool = false,
    insecure_skip_tls: bool = false,
    proxy: transport.ProxyOptions = .{},

    /// go-git `FetchOptions.Validate`.
    pub fn validate(self: *FetchOptions) !void {
        if (self.remote_name.len == 0) self.remote_name = default_remote_name;
        if (self.tags == .invalid) self.tags = .following;
        for (self.ref_specs) |rs| try rs.validate();
    }
};

/// go-git `PushOptions`.
pub const PushOptions = struct {
    remote_name: []const u8 = "",
    remote_url: []const u8 = "",
    ref_specs: []const RefSpec = &.{},
    auth: ?transport.AuthMethod = null,
    prune: bool = false,
    force: bool = false,
    require_remote_refs: []const RefSpec = &.{},
    follow_tags: bool = false,
    force_with_lease: ?ForceWithLease = null,
    /// Server push options (empty by default).
    options: []const PushOption = &.{},
    atomic: bool = false,
    insecure_skip_tls: bool = false,
    proxy: transport.ProxyOptions = .{},

    /// go-git `PushOptions.Validate`.
    ///
    /// Does **not** inject the default push refspec: that needs a owned string
    /// the caller can free. `push.zig` fills an empty `ref_specs` after validate.
    pub fn validate(self: *PushOptions) !void {
        if (self.remote_name.len == 0) self.remote_name = default_remote_name;
        for (self.ref_specs) |rs| try rs.validate();
        for (self.require_remote_refs) |rs| try rs.validate();
    }
};

/// go-git `ListOptions`.
pub const ListOptions = struct {
    auth: ?transport.AuthMethod = null,
    insecure_skip_tls: bool = false,
    peeling: PeelingOption = .ignore_peeled,
    /// Timeout in seconds. `0` means default (`default_list_timeout_sec`);
    /// negative is `error.InvalidTimeout`. Network enforcement is phase 13.
    timeout_sec: i32 = 0,
    proxy: transport.ProxyOptions = .{},

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
