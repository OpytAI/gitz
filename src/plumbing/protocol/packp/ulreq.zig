//! Upload-request message (go-git `plumbing/protocol/packp/ulreq.go`).
//!
//! Low-level type; prefer `UploadPackRequest` (`uppackreq.zig`) for clients.
//!
//! Pin: go-git v5.19.2.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const plumbing = @import("plumbing");
const capability = @import("capability");
const filter_mod = @import("filter.zig");

const encode_mod = @import("ulreq_encode.zig");
const decode_mod = @import("ulreq_decode.zig");

pub const Hash = plumbing.Hash;
pub const Filter = filter_mod.Filter;

// ---------------------------------------------------------------------------
// Depth (go-git Depth / DepthCommits / DepthSince / DepthReference)
// ---------------------------------------------------------------------------

/// Desired depth of the requested packfile.
///
/// - `commits`: max commits; **0 means infinite** (no `deepen` line on encode).
/// - `since`: Unix seconds UTC (`deepen-since`).
/// - `reference`: ref name for `deepen-not`.
///
/// Default for a new request is `.{ .commits = 0 }` (infinite depth).
pub const Depth = union(enum) {
    commits: i32,
    since: i64,
    reference: []const u8,

    /// go-git `Depth.IsZero`.
    pub fn isZero(self: Depth) bool {
        return switch (self) {
            .commits => |n| n == 0,
            // go-git uses `time.Time.IsZero()` (year 1). Unix epoch 0 is not zero
            // there; we treat literal 0 as zero for the i64 mapping used here.
            .since => |t| t == 0,
            .reference => |r| r.len == 0,
        };
    }
};

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const Error = error{
    /// No wants in the request (`want can't be empty` / `empty wants provided`).
    EmptyWants,
    /// Required capability missing for shallows / depth.
    MissingCapability,
    /// Mutually exclusive capabilities both present.
    ConflictingCapabilities,
    /// Unexpected or malformed pkt-line payload while decoding.
    UnexpectedData,
    /// Hash field too short.
    MalformedHash,
    /// Hash hex is not valid.
    InvalidHash,
    /// `deepen` with a negative value.
    NegativeDepth,
    /// Unsupported depth variant on encode.
    UnsupportedDepth,
};

// ---------------------------------------------------------------------------
// UploadRequest
// ---------------------------------------------------------------------------

/// Upload-request message (go-git `UploadRequest`).
///
/// Not zero-value safe: use `init` / `initFromCapabilities`.
pub const UploadRequest = struct {
    allocator: Allocator,
    capabilities: capability.List,
    wants: std.ArrayList(Hash) = .empty,
    shallows: std.ArrayList(Hash) = .empty,
    depth: Depth = .{ .commits = 0 },
    filter: Filter = "",
    /// When true, `deinit` frees `depth.reference`.
    owns_depth_ref: bool = false,
    /// When true, `deinit` frees `filter`.
    owns_filter: bool = false,

    /// go-git `NewUploadRequest`.
    pub fn init(allocator: Allocator) UploadRequest {
        return .{
            .allocator = allocator,
            .capabilities = capability.List.init(allocator),
        };
    }

    /// go-git `NewUploadRequestFromCapabilities`.
    ///
    /// Fills optimal request capabilities from advertised `adv`.
    /// No wants/shallows; infinite depth.
    pub fn initFromCapabilities(allocator: Allocator, adv: *const capability.List) !UploadRequest {
        var r = init(allocator);
        errdefer r.deinit();

        if (adv.supports(capability.MultiACKDetailed)) {
            try r.capabilities.set(capability.MultiACKDetailed, &.{});
        } else if (adv.supports(capability.MultiACK)) {
            try r.capabilities.set(capability.MultiACK, &.{});
        }

        if (adv.supports(capability.Sideband64k)) {
            try r.capabilities.set(capability.Sideband64k, &.{});
        } else if (adv.supports(capability.Sideband)) {
            try r.capabilities.set(capability.Sideband, &.{});
        }

        if (adv.supports(capability.ThinPack)) {
            try r.capabilities.set(capability.ThinPack, &.{});
        }

        if (adv.supports(capability.OFSDelta)) {
            try r.capabilities.set(capability.OFSDelta, &.{});
        }

        if (adv.supports(capability.Agent)) {
            // go-git DefaultAgent(); ignore GO_GIT_USER_AGENT_EXTRA here by
            // passing null extra (matches default test environment).
            const agent = try capability.defaultAgent(allocator, null);
            defer allocator.free(agent);
            try r.capabilities.set(capability.Agent, &.{agent});
        }

        return r;
    }

    pub fn deinit(self: *UploadRequest) void {
        self.capabilities.deinit();
        self.wants.deinit(self.allocator);
        self.shallows.deinit(self.allocator);
        if (self.owns_depth_ref) {
            switch (self.depth) {
                .reference => |r| self.allocator.free(r),
                else => {},
            }
            self.owns_depth_ref = false;
        }
        if (self.owns_filter and self.filter.len != 0) {
            self.allocator.free(self.filter);
            self.owns_filter = false;
        }
        self.filter = "";
        self.depth = .{ .commits = 0 };
    }

    /// go-git `(*UploadRequest).Encode`.
    pub fn encode(self: *UploadRequest, w: *Writer) !void {
        return encode_mod.encode(self, w);
    }

    /// go-git `(*UploadRequest).Decode`.
    pub fn decode(self: *UploadRequest, r: *Reader) !void {
        return decode_mod.decode(self, r);
    }

    /// go-git `(*UploadRequest).Validate`.
    pub fn validate(self: *const UploadRequest) Error!void {
        if (self.wants.items.len == 0) return error.EmptyWants;
        try self.validateRequiredCapabilities();
        try self.validateConflictCapabilities();
    }

    fn validateRequiredCapabilities(self: *const UploadRequest) Error!void {
        if (self.shallows.items.len != 0 and !self.capabilities.supports(capability.Shallow)) {
            return error.MissingCapability;
        }

        switch (self.depth) {
            .commits => |n| {
                if (n != 0 and !self.capabilities.supports(capability.Shallow)) {
                    return error.MissingCapability;
                }
            },
            .since => {
                if (!self.capabilities.supports(capability.DeepenSince)) {
                    return error.MissingCapability;
                }
            },
            .reference => {
                if (!self.capabilities.supports(capability.DeepenNot)) {
                    return error.MissingCapability;
                }
            },
        }
    }

    fn validateConflictCapabilities(self: *const UploadRequest) Error!void {
        if (self.capabilities.supports(capability.Sideband) and
            self.capabilities.supports(capability.Sideband64k))
        {
            return error.ConflictingCapabilities;
        }
        if (self.capabilities.supports(capability.MultiACK) and
            self.capabilities.supports(capability.MultiACKDetailed))
        {
            return error.ConflictingCapabilities;
        }
    }
};

// ---------------------------------------------------------------------------
// Helpers shared by encode/decode
// ---------------------------------------------------------------------------

/// Alphabetical (byte-order) sort of hashes — go-git `plumbing.HashesSort`.
pub fn hashesSort(hashes: []Hash) void {
    std.mem.sort(Hash, hashes, {}, struct {
        fn less(_: void, a: Hash, b: Hash) bool {
            return std.mem.order(u8, &a.bytes, &b.bytes) == .lt;
        }
    }.less);
}

// ---------------------------------------------------------------------------
// Tests — port of ulreq_test.go
// ---------------------------------------------------------------------------

test "NewUploadRequestFromCapabilities prefers detailed multi_ack and 64k sideband" {
    const gpa = testing.allocator;
    var adv = capability.List.init(gpa);
    defer adv.deinit();

    try adv.set(capability.Sideband, &.{});
    try adv.set(capability.Sideband64k, &.{});
    try adv.set(capability.MultiACK, &.{});
    try adv.set(capability.MultiACKDetailed, &.{});
    try adv.set(capability.ThinPack, &.{});
    try adv.set(capability.OFSDelta, &.{});
    try adv.set(capability.Agent, &.{"foo"});

    var r = try UploadRequest.initFromCapabilities(gpa, &adv);
    defer r.deinit();

    const s = try r.capabilities.string(gpa);
    defer gpa.free(s);
    try testing.expectEqualStrings(
        "multi_ack_detailed side-band-64k thin-pack ofs-delta agent=go-git/5.x",
        s,
    );
}

test "Validate wants required" {
    const gpa = testing.allocator;
    var r = UploadRequest.init(gpa);
    defer r.deinit();

    try testing.expectError(error.EmptyWants, r.validate());

    try r.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    try r.validate();
}

test "Validate shallows require shallow capability" {
    const gpa = testing.allocator;
    var r = UploadRequest.init(gpa);
    defer r.deinit();

    try r.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    try r.shallows.append(gpa, plumbing.newHash("2222222222222222222222222222222222222222"));
    try testing.expectError(error.MissingCapability, r.validate());

    try r.capabilities.set(capability.Shallow, &.{});
    try r.validate();
}

test "Validate DepthCommits require shallow" {
    const gpa = testing.allocator;
    var r = UploadRequest.init(gpa);
    defer r.deinit();

    try r.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    r.depth = .{ .commits = 42 };
    try testing.expectError(error.MissingCapability, r.validate());

    try r.capabilities.set(capability.Shallow, &.{});
    try r.validate();
}

test "Validate DepthReference require deepen-not" {
    const gpa = testing.allocator;
    var r = UploadRequest.init(gpa);
    defer r.deinit();

    try r.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    r.depth = .{ .reference = "1111111111111111111111111111111111111111" };
    try testing.expectError(error.MissingCapability, r.validate());

    try r.capabilities.set(capability.DeepenNot, &.{});
    try r.validate();
}

test "Validate DepthSince require deepen-since" {
    const gpa = testing.allocator;
    var r = UploadRequest.init(gpa);
    defer r.deinit();

    try r.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    r.depth = .{ .since = 1_700_000_000 }; // non-zero unix time (DepthSince)
    try testing.expectError(error.MissingCapability, r.validate());

    try r.capabilities.set(capability.DeepenSince, &.{});
    try r.validate();
}

test "Validate conflict sideband" {
    const gpa = testing.allocator;
    var r = UploadRequest.init(gpa);
    defer r.deinit();

    try r.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    try r.capabilities.set(capability.Sideband, &.{});
    try r.capabilities.set(capability.Sideband64k, &.{});
    try testing.expectError(error.ConflictingCapabilities, r.validate());
}

test "Validate conflict multi_ack" {
    const gpa = testing.allocator;
    var r = UploadRequest.init(gpa);
    defer r.deinit();

    try r.wants.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    try r.capabilities.set(capability.MultiACK, &.{});
    try r.capabilities.set(capability.MultiACKDetailed, &.{});
    try testing.expectError(error.ConflictingCapabilities, r.validate());
}

test "Depth.isZero" {
    try testing.expect((Depth{ .commits = 0 }).isZero());
    try testing.expect(!(Depth{ .commits = 1 }).isZero());
    try testing.expect((Depth{ .since = 0 }).isZero());
    try testing.expect(!(Depth{ .since = 1 }).isZero());
    try testing.expect((Depth{ .reference = "" }).isZero());
    try testing.expect(!(Depth{ .reference = "refs/heads/main" }).isZero());
}
