//! Server and client capabilities — port of go-git
//! `plumbing/protocol/packp/capability/capability.go` (v5.19.2).

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// Capability describes a server or client capability (go-git `Capability`).
pub const Capability = []const u8;

// ---------------------------------------------------------------------------
// Known capability name constants (go-git names)
// ---------------------------------------------------------------------------

/// multi_ack — early ACK continue during negotiation.
pub const MultiACK: Capability = "multi_ack";
/// multi_ack_detailed — extension of multi_ack with more state detail.
pub const MultiACKDetailed: Capability = "multi_ack_detailed";
/// no-done — smart HTTP may send pack after first ACK ready.
pub const NoDone: Capability = "no-done";
/// thin-pack — deltas may reference bases outside the pack.
pub const ThinPack: Capability = "thin-pack";
/// side-band — multiplexed progress/error with ~1000-byte packets.
pub const Sideband: Capability = "side-band";
/// side-band-64k — multiplexed sideband with larger packets.
pub const Sideband64k: Capability = "side-band-64k";
/// ofs-delta — OBJ_OFS_DELTA in packfiles.
pub const OFSDelta: Capability = "ofs-delta";
/// agent — optional agent=version string.
pub const Agent: Capability = "agent";
/// shallow — shallow clone protocol commands.
pub const Shallow: Capability = "shallow";
/// deepen-since — shallow cut at a timestamp.
pub const DeepenSince: Capability = "deepen-since";
/// deepen-not — shallow cut excluding a revision.
pub const DeepenNot: Capability = "deepen-not";
/// deepen-relative — deepen depth is relative to shallow boundary.
pub const DeepenRelative: Capability = "deepen-relative";
/// no-progress — client does not want sideband stream 2.
pub const NoProgress: Capability = "no-progress";
/// include-tag — pack annotated tags pointing at sent objects.
pub const IncludeTag: Capability = "include-tag";
/// report-status — receive-pack reports unpack/ref update status.
pub const ReportStatus: Capability = "report-status";
/// delete-refs — server accepts zero-id ref deletes.
pub const DeleteRefs: Capability = "delete-refs";
/// quiet — receive-pack can silence progress output.
pub const Quiet: Capability = "quiet";
/// atomic — atomic multi-ref push.
pub const Atomic: Capability = "atomic";
/// push-options — push options before pack stream.
pub const PushOptions: Capability = "push-options";
/// allow-tip-sha1-in-want — want unadvertised tip SHAs.
pub const AllowTipSHA1InWant: Capability = "allow-tip-sha1-in-want";
/// allow-reachable-sha1-in-want — want unadvertised reachable SHAs.
pub const AllowReachableSHA1InWant: Capability = "allow-reachable-sha1-in-want";
/// push-cert — signed push certificate (argument is nonce).
pub const PushCert: Capability = "push-cert";
/// symref — symbolic reference advertisement (may repeat).
pub const SymRef: Capability = "symref";
/// object-format — hash algorithm argument.
pub const ObjectFormat: Capability = "object-format";
/// filter — partial clone/fetch filter command.
pub const Filter: Capability = "filter";

/// Base user-agent string (go-git package-private `userAgent`).
pub const user_agent: []const u8 = "go-git/5.x";

/// Environment variable for an optional agent suffix (go-git).
pub const env_user_agent_extra: []const u8 = "GO_GIT_USER_AGENT_EXTRA";

// ---------------------------------------------------------------------------
// known / requiresArgument / multipleArgument (go-git package maps)
// ---------------------------------------------------------------------------

const known_map = std.StaticStringMap(void).initComptime(.{
    .{MultiACK},
    .{MultiACKDetailed},
    .{NoDone},
    .{ThinPack},
    .{Sideband},
    .{Sideband64k},
    .{OFSDelta},
    .{Agent},
    .{Shallow},
    .{DeepenSince},
    .{DeepenNot},
    .{DeepenRelative},
    .{NoProgress},
    .{IncludeTag},
    .{ReportStatus},
    .{DeleteRefs},
    .{Quiet},
    .{Atomic},
    .{PushOptions},
    .{AllowTipSHA1InWant},
    .{AllowReachableSHA1InWant},
    .{PushCert},
    .{SymRef},
    .{ObjectFormat},
    .{Filter},
});

const requires_argument_map = std.StaticStringMap(void).initComptime(.{
    .{Agent},
    .{PushCert},
    .{SymRef},
    .{ObjectFormat},
});

const multiple_argument_map = std.StaticStringMap(void).initComptime(.{
    .{SymRef},
});

/// True if `c` is a known capability name (go-git `known` map).
pub fn isKnown(c: Capability) bool {
    return known_map.has(c);
}

/// True if `c` requires at least one argument (go-git `requiresArgument`).
pub fn requiresArgument(c: Capability) bool {
    return requires_argument_map.has(c);
}

/// True if `c` may take multiple arguments (go-git `multipleArgument`).
pub fn multipleArgument(c: Capability) bool {
    return multiple_argument_map.has(c);
}

// ---------------------------------------------------------------------------
// DefaultAgent
// ---------------------------------------------------------------------------

/// Format the default agent string (go-git `DefaultAgent` body).
///
/// When `extra` is null, returns a copy of `user_agent` (`"go-git/5.x"`).
/// When non-null (value of `GO_GIT_USER_AGENT_EXTRA`), returns
/// `"go-git/5.x {extra}"`. Caller owns the returned slice.
pub fn defaultAgent(allocator: Allocator, extra: ?[]const u8) Allocator.Error![]u8 {
    if (extra) |e| {
        return try std.fmt.allocPrint(allocator, "{s} {s}", .{ user_agent, e });
    }
    return try allocator.dupe(u8, user_agent);
}

/// Like go-git `DefaultAgent`: read `GO_GIT_USER_AGENT_EXTRA` from `environ`.
///
/// Uses `std.process.Environ.getPosix` (POSIX). Caller owns the returned slice.
pub fn defaultAgentFromEnviron(allocator: Allocator, environ: std.process.Environ) Allocator.Error![]u8 {
    const extra = std.process.Environ.getPosix(environ, env_user_agent_extra);
    return defaultAgent(allocator, extra);
}

// ---------------------------------------------------------------------------
// Tests (capability_test.go)
// ---------------------------------------------------------------------------

test "capability_test.TestDefaultAgent" {
    const ua = try defaultAgent(testing.allocator, null);
    defer testing.allocator.free(ua);
    try testing.expectEqualStrings(user_agent, ua);
    try testing.expectEqualStrings("go-git/5.x", ua);
}

test "capability_test.TestEnvAgent" {
    const ua = try defaultAgent(testing.allocator, "abc xyz");
    defer testing.allocator.free(ua);
    try testing.expectEqualStrings("go-git/5.x abc xyz", ua);
}

test "capability constants match go-git wire names" {
    try testing.expectEqualStrings("multi_ack", MultiACK);
    try testing.expectEqualStrings("multi_ack_detailed", MultiACKDetailed);
    try testing.expectEqualStrings("no-done", NoDone);
    try testing.expectEqualStrings("thin-pack", ThinPack);
    try testing.expectEqualStrings("side-band", Sideband);
    try testing.expectEqualStrings("side-band-64k", Sideband64k);
    try testing.expectEqualStrings("ofs-delta", OFSDelta);
    try testing.expectEqualStrings("agent", Agent);
    try testing.expectEqualStrings("shallow", Shallow);
    try testing.expectEqualStrings("deepen-since", DeepenSince);
    try testing.expectEqualStrings("deepen-not", DeepenNot);
    try testing.expectEqualStrings("deepen-relative", DeepenRelative);
    try testing.expectEqualStrings("no-progress", NoProgress);
    try testing.expectEqualStrings("include-tag", IncludeTag);
    try testing.expectEqualStrings("report-status", ReportStatus);
    try testing.expectEqualStrings("delete-refs", DeleteRefs);
    try testing.expectEqualStrings("quiet", Quiet);
    try testing.expectEqualStrings("atomic", Atomic);
    try testing.expectEqualStrings("push-options", PushOptions);
    try testing.expectEqualStrings("allow-tip-sha1-in-want", AllowTipSHA1InWant);
    try testing.expectEqualStrings("allow-reachable-sha1-in-want", AllowReachableSHA1InWant);
    try testing.expectEqualStrings("push-cert", PushCert);
    try testing.expectEqualStrings("symref", SymRef);
    try testing.expectEqualStrings("object-format", ObjectFormat);
    try testing.expectEqualStrings("filter", Filter);
}

test "known requiresArgument multipleArgument maps" {
    try testing.expect(isKnown(ThinPack));
    try testing.expect(isKnown(Agent));
    try testing.expect(isKnown(SymRef));
    try testing.expect(isKnown(Filter));
    try testing.expect(!isKnown("foo"));
    try testing.expect(!isKnown("oldref"));

    try testing.expect(requiresArgument(Agent));
    try testing.expect(requiresArgument(PushCert));
    try testing.expect(requiresArgument(SymRef));
    try testing.expect(requiresArgument(ObjectFormat));
    try testing.expect(!requiresArgument(ThinPack));
    try testing.expect(!requiresArgument(OFSDelta));

    try testing.expect(multipleArgument(SymRef));
    try testing.expect(!multipleArgument(Agent));
    try testing.expect(!multipleArgument(ThinPack));
}
