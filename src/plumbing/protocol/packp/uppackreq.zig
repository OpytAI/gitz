//! Upload-pack request (go-git `plumbing/protocol/packp/uppackreq.go`).
//!
//! Combines `UploadRequest` with client `have` lines (`UploadHaves`).
//! Pin: go-git v5.19.2.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const plumbing = @import("plumbing");
const pktline = @import("pktline");
const capability = @import("capability");

const ulreq = @import("ulreq.zig");
const UploadRequest = ulreq.UploadRequest;
const Hash = ulreq.Hash;

// ---------------------------------------------------------------------------
// UploadHaves
// ---------------------------------------------------------------------------

/// Client "have" hashes for upload-pack negotiation (go-git `UploadHaves`).
/// Prefer `UploadPackRequest` over using this alone.
pub const UploadHaves = struct {
    haves: std.ArrayList(Hash) = .empty,

    pub fn deinit(self: *UploadHaves, allocator: Allocator) void {
        self.haves.deinit(allocator);
    }

    /// go-git `(*UploadHaves).Encode`.
    ///
    /// Sorts and deduplicates haves. When `flush` is true and there is at least
    /// one have, appends a flush-pkt after the have lines.
    pub fn encode(self: *UploadHaves, w: *Writer, flush: bool) !void {
        var pe = pktline.Encoder.init(w);
        ulreq.hashesSort(self.haves.items);

        var last: Hash = plumbing.ZeroHash;
        var have_last = false;
        for (self.haves.items) |have| {
            if (have_last and last.eql(have)) continue;
            var hex: [plumbing.MaxHexSize]u8 = undefined;
            const h = have.string(&hex);
            try pe.encodef("have {s}\n", .{h});
            last = have;
            have_last = true;
        }

        if (flush and self.haves.items.len != 0) {
            try pe.flush();
        }
    }
};

// ---------------------------------------------------------------------------
// UploadPackRequest
// ---------------------------------------------------------------------------

/// Full upload-pack request (go-git `UploadPackRequest`).
///
/// Composition mirrors Go embedding: use `upload_request.*` fields and
/// `upload_haves.haves` directly (no thin getters).
/// Not zero-value safe — use `init` / `initFromCapabilities`.
pub const UploadPackRequest = struct {
    upload_request: UploadRequest,
    upload_haves: UploadHaves = .{},

    /// go-git `NewUploadPackRequest`.
    pub fn init(allocator: Allocator) UploadPackRequest {
        return .{
            .upload_request = UploadRequest.init(allocator),
            .upload_haves = .{},
        };
    }

    /// go-git `NewUploadPackRequestFromCapabilities`.
    pub fn initFromCapabilities(allocator: Allocator, adv: *const capability.List) !UploadPackRequest {
        return .{
            .upload_request = try UploadRequest.initFromCapabilities(allocator, adv),
            .upload_haves = .{},
        };
    }

    pub fn deinit(self: *UploadPackRequest) void {
        self.upload_haves.deinit(self.upload_request.allocator);
        self.upload_request.deinit();
    }

    /// go-git `(*UploadPackRequest).IsEmpty`.
    ///
    /// Empty when every want is also in haves, and there are no shallows.
    pub fn isEmpty(self: *const UploadPackRequest) bool {
        return isSubset(self.upload_request.wants.items, self.upload_haves.haves.items) and
            self.upload_request.shallows.items.len == 0;
    }

    /// go-git `(*UploadRequest).Validate` via embedded request.
    pub fn validate(self: *const UploadPackRequest) !void {
        return self.upload_request.validate();
    }

    /// Depth from the embedded upload-request.
    pub fn depth(self: *const UploadPackRequest) ulreq.Depth {
        return self.upload_request.depth;
    }
};

fn isSubset(needle: []const Hash, haystack: []const Hash) bool {
    for (needle) |h| {
        var found = false;
        for (haystack) |oh| {
            if (h.eql(oh)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests — port of uppackreq_test.go
// ---------------------------------------------------------------------------

test "NewUploadPackRequestFromCapabilities agent" {
    const gpa = testing.allocator;
    var adv = capability.List.init(gpa);
    defer adv.deinit();
    try adv.set(capability.Agent, &.{"foo"});

    var r = try UploadPackRequest.initFromCapabilities(gpa, &adv);
    defer r.deinit();

    const s = try r.upload_request.capabilities.string(gpa);
    defer gpa.free(s);
    try testing.expectEqualStrings("agent=go-git/5.x", s);
}

test "IsEmpty" {
    const gpa = testing.allocator;

    {
        var r = UploadPackRequest.init(gpa);
        defer r.deinit();
        try r.upload_request.wants.append(gpa, plumbing.newHash("d82f291cde9987322c8a0c81a325e1ba6159684c"));
        try r.upload_request.wants.append(gpa, plumbing.newHash("2b41ef280fdb67a9b250678686a0c3e03b0a9989"));
        try r.upload_haves.haves.append(gpa, plumbing.newHash("6ecf0ef2c2dffb796033e5a02219af86ec6584e5"));
        try testing.expect(!r.isEmpty());
    }

    {
        var r = UploadPackRequest.init(gpa);
        defer r.deinit();
        try r.upload_request.wants.append(gpa, plumbing.newHash("d82f291cde9987322c8a0c81a325e1ba6159684c"));
        try r.upload_request.wants.append(gpa, plumbing.newHash("2b41ef280fdb67a9b250678686a0c3e03b0a9989"));
        try r.upload_haves.haves.append(gpa, plumbing.newHash("d82f291cde9987322c8a0c81a325e1ba6159684c"));
        try testing.expect(!r.isEmpty());
    }

    {
        var r = UploadPackRequest.init(gpa);
        defer r.deinit();
        try r.upload_request.wants.append(gpa, plumbing.newHash("d82f291cde9987322c8a0c81a325e1ba6159684c"));
        try r.upload_haves.haves.append(gpa, plumbing.newHash("d82f291cde9987322c8a0c81a325e1ba6159684c"));
        try testing.expect(r.isEmpty());
    }

    {
        var r = UploadPackRequest.init(gpa);
        defer r.deinit();
        try r.upload_request.wants.append(gpa, plumbing.newHash("d82f291cde9987322c8a0c81a325e1ba6159684c"));
        try r.upload_haves.haves.append(gpa, plumbing.newHash("d82f291cde9987322c8a0c81a325e1ba6159684c"));
        try r.upload_request.shallows.append(gpa, plumbing.newHash("2b41ef280fdb67a9b250678686a0c3e03b0a9989"));
        try testing.expect(!r.isEmpty());
    }
}

test "UploadHaves.Encode sorts dedupes and flush" {
    const gpa = testing.allocator;
    var uh: UploadHaves = .{};
    defer uh.deinit(gpa);
    try uh.haves.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    try uh.haves.append(gpa, plumbing.newHash("3333333333333333333333333333333333333333"));
    try uh.haves.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));
    try uh.haves.append(gpa, plumbing.newHash("2222222222222222222222222222222222222222"));
    try uh.haves.append(gpa, plumbing.newHash("1111111111111111111111111111111111111111"));

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try uh.encode(&aw.writer, true);

    const expected =
        "0032have 1111111111111111111111111111111111111111\n" ++
        "0032have 2222222222222222222222222222222222222222\n" ++
        "0032have 3333333333333333333333333333333333333333\n" ++
        "0000";
    try testing.expectEqualStrings(expected, aw.written());
}

test "UploadHaves.Encode no flush when empty" {
    const gpa = testing.allocator;
    var uh: UploadHaves = .{};
    defer uh.deinit(gpa);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try uh.encode(&aw.writer, true);
    try testing.expectEqualStrings("", aw.written());
}
