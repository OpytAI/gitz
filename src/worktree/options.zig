//! Worktree operation options (go-git `options.go` worktree-related).

const std = @import("std");
const plumbing = @import("plumbing");
const objpkg = @import("object");
const remote = @import("remote");
const transport = @import("transport");

const error_mod = @import("error.zig");
const status_types = @import("status_types.zig");

const Hash = plumbing.Hash;
const ReferenceName = plumbing.ReferenceName;
const Signature = objpkg.Signature;
const ZeroHash = plumbing.ZeroHash;

pub const StatusOptions = status_types.StatusOptions;
pub const StatusStrategy = status_types.StatusStrategy;

/// go-git `CheckoutOptions`.
pub const CheckoutOptions = struct {
    hash: Hash = ZeroHash,
    /// Empty until `validate` defaults to `master` (go-git empty zero value).
    branch: ReferenceName = ReferenceName.init(""),
    create: bool = false,
    force: bool = false,
    keep: bool = false,
    sparse_checkout_directories: []const []const u8 = &.{},

    pub fn validate(self: *CheckoutOptions) !void {
        if (self.force and self.keep) return error_mod.Error.CheckoutForceKeepExclusive;
        // go-git order: exclusivity check uses pre-default Branch; empty Branch
        // with Hash alone is allowed (then Branch defaults to master).
        if (!self.create and !self.hash.isZero() and self.branch.raw.len > 0) {
            return error_mod.Error.BranchHashExclusive;
        }
        if (self.create and self.branch.raw.len == 0) return error_mod.Error.CreateRequiresBranch;
        if (self.branch.raw.len == 0) self.branch = plumbing.master;
    }
};

/// go-git `ResetMode`.
pub const ResetMode = enum {
    mixed,
    hard,
    merge,
    soft,
};

/// go-git `ResetOptions`.
pub const ResetOptions = struct {
    commit: Hash = ZeroHash,
    mode: ResetMode = .mixed,
    files: []const []const u8 = &.{},
};

/// go-git `AddOptions`.
pub const AddOptions = struct {
    all: bool = false,
    path: []const u8 = "",
    glob: []const u8 = "",
    skip_status: bool = false,

    pub fn validate(self: *const AddOptions) !void {
        if (self.path.len > 0 and self.glob.len > 0) return error_mod.Error.AddPathGlobExclusive;
    }
};

/// go-git `CommitOptions` (signer/amend subset; SignKey = openpgp Entity).
pub const CommitOptions = struct {
    all: bool = false,
    allow_empty_commits: bool = false,
    author: ?Signature = null,
    committer: ?Signature = null,
    parents: []const Hash = &.{},
    sign_key: ?*objpkg.Entity = null,
    amend: bool = false,

    pub fn validate(self: *const CommitOptions) !void {
        if (self.all and self.amend) return error_mod.Error.CommitAllAmendExclusive;
        if (self.amend and self.parents.len > 0) return error_mod.Error.CommitParentsAmendExclusive;
    }
};

/// go-git `PullOptions`.
pub const PullOptions = struct {
    remote_name: []const u8 = "",
    remote_url: []const u8 = "",
    reference_name: ReferenceName = plumbing.HEAD,
    single_branch: bool = false,
    depth: i32 = 0,
    force: bool = false,
    transport: remote.TransportClientOpts = .{},
    progress: ?*std.Io.Writer = null,

    pub fn validate(self: *PullOptions) !void {
        if (self.remote_name.len == 0) self.remote_name = remote.default_remote_name;
        if (self.reference_name.raw.len == 0) self.reference_name = plumbing.HEAD;
    }
};

/// go-git `CloneOptions` (subset used by PlainClone).
pub const CloneOptions = struct {
    url: []const u8 = "",
    remote_name: []const u8 = "",
    reference_name: ReferenceName = plumbing.HEAD,
    single_branch: bool = false,
    no_checkout: bool = false,
    depth: i32 = 0,
    tags: remote.TagMode = .all,
    mirror: bool = false,
    bare: bool = false,
    force: bool = false,
    transport: remote.TransportClientOpts = .{},
    progress: ?*std.Io.Writer = null,

    pub fn validate(self: *CloneOptions) !void {
        if (self.url.len == 0) return error_mod.Error.MissingURL;
        if (self.remote_name.len == 0) self.remote_name = remote.default_remote_name;
        if (self.reference_name.raw.len == 0) self.reference_name = plumbing.HEAD;
        if (self.tags == .invalid) self.tags = .all;
    }
};

/// go-git `CleanOptions`.
pub const CleanOptions = struct {
    dir: bool = false,
};

test "AddOptions path glob exclusive" {
    const o = AddOptions{ .path = "a", .glob = "*" };
    try std.testing.expectError(error_mod.Error.AddPathGlobExclusive, o.validate());
}
