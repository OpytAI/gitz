//! Reference update request (push) — port of go-git
//! `plumbing/protocol/packp/updreq.go` (v5.19.2).
//!
//! Wire codec lives in `updreq_encode.zig` / `updreq_decode.zig`.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const plumbing = @import("plumbing");
const pktline = @import("pktline");
const capability = @import("capability");
// sideband.Progress is `*std.Io.Writer` (see sideband demux `progress` field).
const common = @import("common.zig");
const encode_mod = @import("updreq_encode.zig");
const decode_mod = @import("updreq_decode.zig");

const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const ReferenceName = plumbing.ReferenceName;

// ---------------------------------------------------------------------------
// Errors (go-git `ErrEmptyCommands`, `ErrMalformedCommand`, decode extras)
// ---------------------------------------------------------------------------

/// Errors for reference-update request encode/decode/validate.
pub const Error = error{
    /// Commands list is empty (go-git `ErrEmptyCommands`).
    EmptyCommands,
    /// Command is create+delete of zero (go-git `ErrMalformedCommand`).
    MalformedCommand,
    /// Empty update-request message (go-git `ErrEmpty`).
    Empty,
    /// Unexpected EOF before any command (go-git `errNoCommands`).
    NoCommands,
    /// Capabilities NUL delimiter missing (go-git `errMissingCapabilitiesDelimiter`).
    MissingCapabilitiesDelimiter,
    /// Generic malformed request (go-git `errMalformedRequest`).
    MalformedRequest,
    /// Shallow line length is wrong.
    InvalidShallowLineLength,
    /// First command+capabilities line too short.
    InvalidCommandCapabilitiesLineLength,
    /// Subsequent command line too short.
    InvalidCommandLineLength,
    /// Shallow object id is not valid hex.
    InvalidShallowObjId,
    /// Old object id is not valid.
    InvalidOldObjId,
    /// New object id is not valid.
    InvalidNewObjId,
    /// Hash hex length is not 40 (go-git `errInvalidHashSize`).
    InvalidHashSize,
    /// Hash hex is not valid (go-git `errInvalidHash`).
    InvalidHash,
};

// ---------------------------------------------------------------------------
// Action / Command / Option
// ---------------------------------------------------------------------------

/// Command kind derived from old/new hashes (go-git `Action`).
pub const Action = enum {
    create,
    update,
    delete,
    invalid,

    /// go-git `Action` string values.
    pub fn string(self: Action) []const u8 {
        return switch (self) {
            .create => "create",
            .update => "update",
            .delete => "delete",
            .invalid => "invalid",
        };
    }
};

/// One ref update command (go-git `Command`).
pub const Command = struct {
    name: ReferenceName,
    old: Hash = ZeroHash,
    new: Hash = ZeroHash,

    /// go-git `(*Command).Action`.
    pub fn action(self: *const Command) Action {
        if (self.old.isZero() and self.new.isZero()) return .invalid;
        if (self.old.isZero()) return .create;
        if (self.new.isZero()) return .delete;
        return .update;
    }

    /// go-git `(*Command).validate`.
    pub fn validate(self: *const Command) Error!void {
        if (self.action() == .invalid) return error.MalformedCommand;
    }
};

/// Push option key/value (go-git `Option`).
pub const Option = struct {
    key: []const u8,
    value: []const u8,
};

// ---------------------------------------------------------------------------
// ReferenceUpdateRequest
// ---------------------------------------------------------------------------

/// Reference upload/update request (go-git `ReferenceUpdateRequest`).
///
/// Not zero-value safe: use `newReferenceUpdateRequest` or
/// `newReferenceUpdateRequestFromCapabilities`.
pub const ReferenceUpdateRequest = struct {
    allocator: Allocator,
    capabilities: capability.List,
    commands: std.ArrayList(Command) = .empty,
    options: std.ArrayList(Option) = .empty,
    shallow: ?Hash = null,
    /// Optional packfile stream after the command pkt-lines (go-git `Packfile` ReadCloser).
    packfile: ?*Reader = null,
    /// Optional full pack body for in-process server paths (avoids re-streaming).
    /// Not freed by `deinit` — caller owns the slice.
    packfile_bytes: ?[]const u8 = null,
    /// Optional sideband progress sink (go-git `sideband.Progress` / `*Writer`).
    progress: ?*Writer = null,
    /// Owned string storage for decoded command names (and similar).
    owned_strings: std.ArrayList([]u8) = .empty,

    /// go-git `(*ReferenceUpdateRequest).Encode`.
    pub fn encode(self: *ReferenceUpdateRequest, w: *Writer) EncodeError!void {
        return encode_mod.encode(self, w);
    }

    /// go-git `(*ReferenceUpdateRequest).Decode`.
    pub fn decode(self: *ReferenceUpdateRequest, r: *Reader) DecodeError!void {
        return decode_mod.decode(self, r);
    }

    /// go-git `(*ReferenceUpdateRequest).validate`.
    pub fn validate(self: *const ReferenceUpdateRequest) Error!void {
        if (self.commands.items.len == 0) return error.EmptyCommands;
        for (self.commands.items) |*c| {
            try c.validate();
        }
    }

    /// Free owned capability list, command/option slices, and string storage.
    pub fn deinit(self: *ReferenceUpdateRequest) void {
        for (self.owned_strings.items) |s| self.allocator.free(s);
        self.owned_strings.deinit(self.allocator);
        self.commands.deinit(self.allocator);
        self.options.deinit(self.allocator);
        self.capabilities.deinit();
        self.* = undefined;
    }

    /// Append a command whose `name` is borrowed (encode-side / test helpers).
    pub fn appendCommand(self: *ReferenceUpdateRequest, cmd: Command) Allocator.Error!void {
        try self.commands.append(self.allocator, cmd);
    }

    /// Append a command, owning a copy of `name` (decode path).
    pub fn appendCommandOwnedName(
        self: *ReferenceUpdateRequest,
        name: []const u8,
        old: Hash,
        new: Hash,
    ) Allocator.Error!void {
        try self.commands.ensureUnusedCapacity(self.allocator, 1);
        try self.owned_strings.ensureUnusedCapacity(self.allocator, 1);
        const owned = try self.allocator.dupe(u8, name);
        self.owned_strings.appendAssumeCapacity(owned);
        self.commands.appendAssumeCapacity(.{
            .name = ReferenceName.init(owned),
            .old = old,
            .new = new,
        });
    }

    /// Append a push option with borrowed key/value.
    pub fn appendOption(self: *ReferenceUpdateRequest, opt: Option) Allocator.Error!void {
        try self.options.append(self.allocator, opt);
    }
};

/// Errors from encode (validate + pktline + I/O + capability string/set).
pub const EncodeError = Error || pktline.Error || capability.Error || Writer.Error || Reader.Error || Allocator.Error;
/// Errors from decode (pktline + parse + capability decode + validate).
pub const DecodeError = Error || pktline.Error || capability.Error || Reader.Error || Allocator.Error;

/// go-git `NewReferenceUpdateRequest`.
pub fn newReferenceUpdateRequest(allocator: Allocator) Allocator.Error!ReferenceUpdateRequest {
    return .{
        .allocator = allocator,
        .capabilities = capability.List.init(allocator),
    };
}

/// go-git `NewReferenceUpdateRequestFromCapabilities`.
///
/// Fills optimal capabilities from advertised `adv`. Sets agent and
/// report-status when supported. Leaves atomic, side-band, quiet, push-cert
/// for the caller.
pub fn newReferenceUpdateRequestFromCapabilities(
    allocator: Allocator,
    adv: *const capability.List,
) (Allocator.Error || capability.Error)!ReferenceUpdateRequest {
    var r = try newReferenceUpdateRequest(allocator);
    errdefer r.deinit();

    if (adv.supports(capability.Agent)) {
        const agent = try capability.defaultAgent(allocator, null);
        defer allocator.free(agent);
        try r.capabilities.set(capability.Agent, &.{agent});
    }
    if (adv.supports(capability.ReportStatus)) {
        try r.capabilities.set(capability.ReportStatus, &.{});
    }

    return r;
}

// ---------------------------------------------------------------------------
// Tests — updreq_test.go
// ---------------------------------------------------------------------------

test "updreq_test.TestNewReferenceUpdateRequestFromCapabilities" {
    const allocator = testing.allocator;

    {
        var cap_list = capability.List.init(allocator);
        defer cap_list.deinit();
        try cap_list.set(capability.Sideband, &.{});
        try cap_list.set(capability.Sideband64k, &.{});
        try cap_list.set(capability.Quiet, &.{});
        try cap_list.set(capability.ReportStatus, &.{});
        try cap_list.set(capability.DeleteRefs, &.{});
        try cap_list.set(capability.PushCert, &.{"foo"});
        try cap_list.set(capability.Atomic, &.{});
        try cap_list.set(capability.Agent, &.{"foo"});

        var r = try newReferenceUpdateRequestFromCapabilities(allocator, &cap_list);
        defer r.deinit();

        const s = try r.capabilities.string(allocator);
        defer allocator.free(s);
        try testing.expectEqualStrings("agent=go-git/5.x report-status", s);
    }

    {
        var cap_list = capability.List.init(allocator);
        defer cap_list.deinit();
        try cap_list.set(capability.Agent, &.{"foo"});

        var r = try newReferenceUpdateRequestFromCapabilities(allocator, &cap_list);
        defer r.deinit();

        const s = try r.capabilities.string(allocator);
        defer allocator.free(s);
        try testing.expectEqualStrings("agent=go-git/5.x", s);
    }

    {
        var cap_list = capability.List.init(allocator);
        defer cap_list.deinit();

        var r = try newReferenceUpdateRequestFromCapabilities(allocator, &cap_list);
        defer r.deinit();

        const s = try r.capabilities.string(allocator);
        defer allocator.free(s);
        try testing.expectEqualStrings("", s);
    }
}

test "Command.action create update delete invalid" {
    const name = ReferenceName.init("refs/heads/main");
    const h1 = plumbing.newHash("1ecf0ef2c2dffb796033e5a02219af86ec6584e5");
    const h2 = plumbing.newHash("2ecf0ef2c2dffb796033e5a02219af86ec6584e5");

    try testing.expectEqual(Action.create, (Command{ .name = name, .old = ZeroHash, .new = h1 }).action());
    try testing.expectEqual(Action.delete, (Command{ .name = name, .old = h1, .new = ZeroHash }).action());
    try testing.expectEqual(Action.update, (Command{ .name = name, .old = h1, .new = h2 }).action());
    try testing.expectEqual(Action.invalid, (Command{ .name = name, .old = ZeroHash, .new = ZeroHash }).action());

    try testing.expectError(error.MalformedCommand, (Command{ .name = name, .old = ZeroHash, .new = ZeroHash }).validate());
    try (Command{ .name = name, .old = h1, .new = h2 }).validate();
}

test "validate empty commands" {
    const allocator = testing.allocator;
    var r = try newReferenceUpdateRequest(allocator);
    defer r.deinit();
    try testing.expectError(error.EmptyCommands, r.validate());
}

// Pull encode/decode unit tests into this module's test graph.
test {
    _ = common;
    _ = encode_mod;
    _ = decode_mod;
}
