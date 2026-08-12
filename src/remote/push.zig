//! Remote Push — port of go-git `(*Remote).Push` / `PushContext` core.
//!
//! Opens receive-pack, builds reference-update commands from local refs +
//! refspecs, encodes a pack of missing objects, sends the request, then
//! updates remote-tracking refs from the remote's fetch config.

const std = @import("std");
const plumbing = @import("plumbing");
const packp = @import("packp");
const capability = @import("capability");
const packfile = @import("packfile");
const revlist = @import("revlist");
const memory = @import("memory");
const gitconfig = @import("gitconfig");
const sync = @import("utils/sync");
const server = @import("server");
const objpkg = @import("object");

const options_mod = @import("options.zig");
const error_mod = @import("error.zig");
const session = @import("session.zig");
const refs = @import("refs.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const RefSpec = gitconfig.RefSpec;
const PushOptions = options_mod.PushOptions;
const ForceWithLease = options_mod.ForceWithLease;
const RemoteError = error_mod.Error;

/// Options for reusable wants/haves pack construction.
pub const PackBuildOptions = struct {
    /// Use REF deltas instead of OFS deltas. Push selects this from the
    /// receiver capability set; host-mediated callers can choose explicitly.
    use_ref_deltas: bool = false,
};

pub const PackBuildResult = struct {
    bytes: []u8,
    object_count: usize,

    pub fn deinit(self: *PackBuildResult, allocator: Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Build a pack containing objects reachable from `wants` but not `haves`.
///
/// This is the transport-independent primitive used by push. The caller owns
/// the returned bytes and can expose them through a bounded stream ABI.
pub fn buildPack(
    allocator: Allocator,
    sto: anytype,
    wants: []const Hash,
    haves: []const Hash,
    options: PackBuildOptions,
) !PackBuildResult {
    const Storage = @TypeOf(sto.*);
    var adapter = StoreAdapter(Storage){ .inner = sto };
    const hashes = try revlist.objects(allocator, &adapter, wants, haves);
    defer allocator.free(hashes);

    return .{
        .bytes = try encodePack(allocator, sto, hashes, options.use_ref_deltas),
        .object_count = hashes.len,
    };
}

/// go-git `(*Remote).Push`.
///
/// Returns `error.AlreadyUpToDate` when there are no commands to send.
pub fn push(
    allocator: Allocator,
    sto: *memory.Storage,
    config: *const memory.RemoteConfig,
    embedded: ?*server.Server,
    o: *PushOptions,
) !void {
    // Default push refspec (go-git `PushOptions.Validate` injects this).
    const specs_were_empty = o.ref_specs.len == 0;
    var owned_default: ?[]u8 = null;
    defer if (owned_default) |s| {
        allocator.free(s);
        if (specs_were_empty) o.ref_specs = &.{};
    };
    var owned_specs_buf: [1]RefSpec = undefined;
    if (specs_were_empty) {
        owned_default = try allocator.dupe(u8, gitconfig.default_push_ref_spec);
        owned_specs_buf[0] = RefSpec.init(owned_default.?);
        o.ref_specs = owned_specs_buf[0..1];
    }

    try o.validate();

    if (!std.mem.eql(u8, o.remote_name, config.name)) {
        return RemoteError.RemoteNameMismatch;
    }

    if (o.remote_url.len == 0) {
        if (config.urls.len == 0) return RemoteError.EmptyUrls;
        // go-git uses the last URL for push.
        o.remote_url = config.urls[config.urls.len - 1];
    }

    // Apply Force: rewrite refspecs with '+' prefix (local view only).
    const caller_specs = o.ref_specs;
    var force_owned: std.ArrayList([]u8) = .empty;
    defer {
        for (force_owned.items) |s| allocator.free(s);
        force_owned.deinit(allocator);
    }
    var force_specs: ?[]RefSpec = null;
    defer if (force_specs) |s| {
        allocator.free(s);
        o.ref_specs = caller_specs;
    };

    if (o.force) {
        const arr = try allocator.alloc(RefSpec, o.ref_specs.len);
        errdefer allocator.free(arr);
        for (o.ref_specs, 0..) |rs, i| {
            if (!rs.isForceUpdate() and !rs.isDelete()) {
                const raw = try std.fmt.allocPrint(allocator, "+{s}", .{rs.raw});
                try force_owned.append(allocator, raw);
                arr[i] = RefSpec.init(raw);
            } else {
                arr[i] = rs;
            }
        }
        force_specs = arr;
        o.ref_specs = arr;
    }

    const sopts = session.SessionOpts.fromClient(o.transport);
    var sess = try session.openReceivePackUrl(allocator, o.remote_url, sopts, embedded);
    defer sess.close();

    const ar = try sess.advertisedReferences();
    defer packp.freeAdvRefs(allocator, ar);

    var remote_refs = try ar.allReferences();
    defer remote_refs.deinit();

    try checkRequireRemoteRefs(allocator, o.require_remote_refs, &remote_refs);

    var is_delete = false;
    var all_delete = true;
    for (o.ref_specs) |rs| {
        if (rs.isDelete()) {
            is_delete = true;
        } else {
            all_delete = false;
        }
        if (is_delete and !all_delete) break;
    }

    if (is_delete and !ar.capabilities.supports(capability.DeleteRefs)) {
        return RemoteError.DeleteRefNotSupported;
    }

    const local_refs = try refs.collectLocalRefs(allocator, sto);
    defer allocator.free(local_refs);

    var req = try packp.newReferenceUpdateRequestFromCapabilities(allocator, &ar.capabilities);
    defer req.deinit();

    // go-git `newReferenceUpdateRequest`: wire progress + sideband when set.
    if (o.progress) |p| {
        req.progress = p;
        if (ar.capabilities.supports(capability.Sideband64k)) {
            try req.capabilities.set(capability.Sideband64k, &.{});
        } else if (ar.capabilities.supports(capability.Sideband)) {
            try req.capabilities.set(capability.Sideband, &.{});
        }
    }

    if (ar.capabilities.supports(capability.PushOptions)) {
        try req.capabilities.set(capability.PushOptions, &.{});
        for (o.options) |opt| {
            try req.appendOption(.{ .key = opt.key, .value = opt.value });
        }
    }
    if (o.atomic and ar.capabilities.supports(capability.Atomic)) {
        try req.capabilities.set(capability.Atomic, &.{});
    }

    try addReferencesToUpdate(
        allocator,
        sto,
        config,
        o.ref_specs,
        local_refs,
        &remote_refs,
        &req,
        o.prune,
        o.force_with_lease,
    );

    if (o.follow_tags) {
        try addReachableTags(allocator, sto, local_refs, &remote_refs, &req);
    }

    if (req.commands.items.len == 0) {
        return RemoteError.AlreadyUpToDate;
    }

    const objects = try objectsToPush(allocator, req.commands.items);
    defer allocator.free(objects);

    const haves = try referencesToHashes(allocator, &remote_refs);
    defer allocator.free(haves);

    var haves_all: std.ArrayList(Hash) = .empty;
    defer haves_all.deinit(allocator);
    try haves_all.appendSlice(allocator, haves);
    try haves_all.appendSlice(allocator, sto.shallow());

    var hashes_to_push: ?[]Hash = null;
    defer if (hashes_to_push) |h| allocator.free(h);

    var pack_all_delete = all_delete;
    if (!all_delete) {
        var adapter = StoreAdapter(memory.Storage){ .inner = sto };
        const hs = try revlist.objects(allocator, &adapter, objects, haves_all.items);
        hashes_to_push = hs;
        if (hs.len == 0) {
            pack_all_delete = true;
            for (req.commands.items) |cmd| {
                if (cmd.action() != .delete) {
                    pack_all_delete = false;
                    break;
                }
            }
        }
    }

    const use_ref_deltas = !ar.capabilities.supports(capability.OFSDelta);

    if (!pack_all_delete) {
        const pack_bytes = try encodePack(
            allocator,
            sto,
            hashes_to_push orelse &.{},
            use_ref_deltas,
        );
        defer allocator.free(pack_bytes);
        req.packfile_bytes = pack_bytes;
        try receiveAndFinish(allocator, sto, config, &sess, &req);
    } else {
        req.packfile_bytes = null;
        try receiveAndFinish(allocator, sto, config, &sess, &req);
    }
}

fn receiveAndFinish(
    allocator: Allocator,
    sto: *memory.Storage,
    config: *const memory.RemoteConfig,
    sess: *session.SessionReceive,
    req: *packp.ReferenceUpdateRequest,
) !void {
    const out = try sess.receivePackOutcome(req);
    defer if (out.report) |rs| packp.freeReportStatus(allocator, rs);
    if (out.err) |e| return e;
    if (out.report) |rs| {
        if (!rs.isOk()) return server.Error.UpdateReference;
    }
    try updateRemoteReferenceStorage(allocator, sto, config, req);
}

fn StoreAdapter(comptime Storage: type) type {
    return struct {
        const Self = @This();
        inner: *Storage,

        pub fn encodedObject(self: *Self, t: plumbing.ObjectType, h: Hash) anyerror!*plumbing.MemoryObject {
            return self.inner.encodedObject(t, h);
        }
    };
}

fn encodePack(
    allocator: Allocator,
    sto: anytype,
    hashes: []const Hash,
    use_ref_deltas: bool,
) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    const Storage = @TypeOf(sto.*);
    var adapter = StoreAdapter(Storage){ .inner = sto };
    var enc = packfile.Encoder.initFrom(
        allocator,
        &aw.writer,
        StoreAdapter(Storage),
        &adapter,
        use_ref_deltas,
    );
    defer sync.deinitPools(allocator);
    _ = try enc.encode(hashes, gitconfig.default_pack_window);
    return try aw.toOwnedSlice();
}

fn objectsToPush(allocator: Allocator, commands: []const packp.Command) ![]Hash {
    var list: std.ArrayList(Hash) = .empty;
    errdefer list.deinit(allocator);
    for (commands) |cmd| {
        if (cmd.new.isZero()) continue;
        try list.append(allocator, cmd.new);
    }
    return try list.toOwnedSlice(allocator);
}

fn referencesToHashes(allocator: Allocator, store: *const memory.ReferenceStorage) ![]Hash {
    var list: std.ArrayList(Hash) = .empty;
    errdefer list.deinit(allocator);
    var iter = try store.iterReferences();
    defer iter.deinit();
    while (true) {
        const ref = iter.next() catch |err| switch (err) {
            error.EndOfStream => break,
        };
        if (ref.type != .hash) continue;
        try list.append(allocator, ref.hash);
    }
    return try list.toOwnedSlice(allocator);
}

fn checkRequireRemoteRefs(
    allocator: Allocator,
    specs: []const RefSpec,
    remote_refs: *const memory.ReferenceStorage,
) !void {
    for (specs) |require| {
        if (require.isWildcard()) return RemoteError.RequireRemoteRefsFailed;

        const name = try require.dst(allocator, ReferenceName.init(""));
        defer allocator.free(name.raw);

        const remote_ref = remote_refs.reference(name) catch |err| {
            if (err == error.ReferenceNotFound) return RemoteError.RequireRemoteRefsFailed;
            return err;
        };

        var require_hash: Hash = undefined;
        if (require.isExactSHA1()) {
            require_hash = plumbing.newHash(require.src());
        } else {
            const target = remote_refs.reference(ReferenceName.init(require.src())) catch {
                return RemoteError.RequireRemoteRefsFailed;
            };
            if (target.type == .symbolic) {
                const resolved = remote_refs.reference(target.target) catch {
                    return RemoteError.RequireRemoteRefsFailed;
                };
                require_hash = resolved.hash;
            } else {
                require_hash = target.hash;
            }
        }

        if (!remote_ref.hash.eql(require_hash)) {
            return RemoteError.RequireRemoteRefsFailed;
        }
    }
}

// ---------------------------------------------------------------------------
// Build update commands (go-git addReferencesToUpdate family)
// ---------------------------------------------------------------------------

fn addReferencesToUpdate(
    allocator: Allocator,
    sto: *memory.Storage,
    config: *const memory.RemoteConfig,
    refspecs: []const RefSpec,
    local_refs: []const Reference,
    remote_refs: *const memory.ReferenceStorage,
    req: *packp.ReferenceUpdateRequest,
    prune: bool,
    force_with_lease: ?ForceWithLease,
) !void {
    var dict: std.StringHashMapUnmanaged(Reference) = .empty;
    defer dict.deinit(allocator);
    for (local_refs) |ref| {
        try dict.put(allocator, ref.name.raw, ref);
    }

    for (refspecs) |rs| {
        if (rs.isDelete()) {
            try deleteReferences(allocator, rs, remote_refs, &dict, req, false);
        } else {
            try addOrUpdateReferences(allocator, sto, config, rs, local_refs, &dict, remote_refs, req, force_with_lease);
            if (prune) {
                try deleteReferences(allocator, rs, remote_refs, &dict, req, true);
            }
        }
    }
}

fn addOrUpdateReferences(
    allocator: Allocator,
    sto: *memory.Storage,
    config: *const memory.RemoteConfig,
    rs: RefSpec,
    local_refs: []const Reference,
    dict: *const std.StringHashMapUnmanaged(Reference),
    remote_refs: *const memory.ReferenceStorage,
    req: *packp.ReferenceUpdateRequest,
    force_with_lease: ?ForceWithLease,
) !void {
    if (!rs.isWildcard()) {
        if (dict.get(rs.src())) |ref| {
            try addReferenceIfRefSpecMatches(allocator, sto, config, rs, remote_refs, ref, req, force_with_lease);
            return;
        }
        if (rs.isExactSHA1()) {
            const h = plumbing.newHash(rs.src());
            try addCommit(allocator, sto, rs, remote_refs, h, req);
        }
        return;
    }
    for (local_refs) |ref| {
        try addReferenceIfRefSpecMatches(allocator, sto, config, rs, remote_refs, ref, req, force_with_lease);
    }
}

fn deleteReferences(
    allocator: Allocator,
    rs: RefSpec,
    remote_refs: *const memory.ReferenceStorage,
    dict: *const std.StringHashMapUnmanaged(Reference),
    req: *packp.ReferenceUpdateRequest,
    prune: bool,
) !void {
    var iter = try remote_refs.iterReferences();
    defer iter.deinit();
    while (true) {
        const ref = iter.next() catch |err| switch (err) {
            error.EndOfStream => break,
        };
        if (ref.type != .hash) continue;

        if (prune) {
            const rev_raw = try rs.reverse(allocator);
            defer allocator.free(rev_raw);
            const rev = RefSpec.init(rev_raw);
            if (!rev.match(ref.name)) continue;
            const local_name = try rev.dst(allocator, ref.name);
            defer allocator.free(local_name.raw);
            if (dict.contains(local_name.raw)) continue;
        } else {
            const dst = try rs.dst(allocator, ReferenceName.init(""));
            defer allocator.free(dst.raw);
            if (!dst.eql(ref.name)) continue;
        }

        try req.appendCommandOwnedName(ref.name.raw, ref.hash, ZeroHash);
    }
}

fn addCommit(
    allocator: Allocator,
    sto: *memory.Storage,
    rs: RefSpec,
    remote_refs: *const memory.ReferenceStorage,
    local_commit: Hash,
    req: *packp.ReferenceUpdateRequest,
) !void {
    if (rs.isWildcard()) return error.RefSpecMalformedWildcard;

    const dst = try rs.dst(allocator, ReferenceName.init(""));
    defer allocator.free(dst.raw);

    var cmd = packp.Command{
        .name = dst,
        .old = ZeroHash,
        .new = local_commit,
    };

    if (remote_refs.reference(cmd.name)) |remote_ref| {
        if (remote_ref.type != .hash) return;
        cmd.old = remote_ref.hash;
    } else |err| {
        if (err != error.ReferenceNotFound) return err;
    }

    if (cmd.old.eql(cmd.new)) return;
    if (!rs.isForceUpdate()) {
        try checkFastForwardUpdate(allocator, sto, remote_refs, &cmd);
    }
    try req.appendCommandOwnedName(cmd.name.raw, cmd.old, cmd.new);
}

fn addReferenceIfRefSpecMatches(
    allocator: Allocator,
    sto: *memory.Storage,
    config: *const memory.RemoteConfig,
    rs: RefSpec,
    remote_refs: *const memory.ReferenceStorage,
    local_ref: Reference,
    req: *packp.ReferenceUpdateRequest,
    force_with_lease: ?ForceWithLease,
) !void {
    if (local_ref.type != .hash) return;
    if (!rs.match(local_ref.name)) return;

    const dst = try rs.dst(allocator, local_ref.name);
    defer allocator.free(dst.raw);

    var cmd = packp.Command{
        .name = dst,
        .old = ZeroHash,
        .new = local_ref.hash,
    };

    if (remote_refs.reference(cmd.name)) |remote_ref| {
        if (remote_ref.type != .hash) return;
        cmd.old = remote_ref.hash;
    } else |err| {
        if (err != error.ReferenceNotFound) return err;
    }

    if (cmd.old.eql(cmd.new)) return;

    if (force_with_lease) |fwl| {
        try checkForceWithLease(allocator, sto, config, local_ref, &cmd, fwl);
    } else if (!rs.isForceUpdate()) {
        try checkFastForwardUpdate(allocator, sto, remote_refs, &cmd);
    }

    try req.appendCommandOwnedName(cmd.name.raw, cmd.old, cmd.new);
}

fn checkForceWithLease(
    allocator: Allocator,
    sto: *memory.Storage,
    config: *const memory.RemoteConfig,
    local_ref: Reference,
    cmd: *const packp.Command,
    force_with_lease: ForceWithLease,
) !void {
    const short = if (std.mem.startsWith(u8, local_ref.name.raw, "refs/heads/"))
        local_ref.name.raw["refs/heads/".len..]
    else
        local_ref.name.short();

    const track_name = try std.fmt.allocPrint(
        allocator,
        "refs/remotes/{s}/{s}",
        .{ config.name, short },
    );
    defer allocator.free(track_name);

    const track = sto.reference(ReferenceName.init(track_name)) catch {
        return RemoteError.ForceWithLeaseRejected;
    };

    if (force_with_lease.ref_name.raw.len == 0 or force_with_lease.ref_name.eql(cmd.name)) {
        var expected = track.hash;
        if (!force_with_lease.hash.isZero()) {
            expected = force_with_lease.hash;
        }
        if (!cmd.old.eql(expected)) {
            return RemoteError.ForceWithLeaseRejected;
        }
    }
}

fn checkFastForwardUpdate(
    allocator: Allocator,
    sto: *memory.Storage,
    remote_refs: *const memory.ReferenceStorage,
    cmd: *const packp.Command,
) !void {
    if (cmd.old.isZero()) {
        _ = remote_refs.reference(cmd.name) catch |err| {
            if (err == error.ReferenceNotFound) return;
            return err;
        };
        return RemoteError.ForceNeeded;
    }
    const ff = try refs.isFastForward(allocator, sto, cmd.old, cmd.new, null);
    if (!ff) return RemoteError.ForceNeeded;
}

/// go-git `updateRemoteReferenceStorage` — mirror pushed tips into fetch tracking refs.
fn updateRemoteReferenceStorage(
    allocator: Allocator,
    sto: *memory.Storage,
    config: *const memory.RemoteConfig,
    req: *const packp.ReferenceUpdateRequest,
) !void {
    var specs: std.ArrayList(RefSpec) = .empty;
    defer {
        for (specs.items) |rs| allocator.free(rs.raw);
        specs.deinit(allocator);
    }
    for (config.fetch) |s| {
        try specs.append(allocator, RefSpec.init(try allocator.dupe(u8, s)));
    }
    if (specs.items.len == 0 and config.name.len > 0) {
        const raw = try std.fmt.allocPrint(allocator, gitconfig.default_fetch_ref_spec, .{config.name});
        try specs.append(allocator, RefSpec.init(raw));
    }

    for (specs.items) |spec| {
        for (req.commands.items) |c| {
            if (!spec.match(c.name)) continue;
            const local = try spec.dst(allocator, c.name);
            defer allocator.free(local.raw);
            switch (c.action()) {
                .create, .update => {
                    const ref = Reference.newHashReference(local, c.new);
                    try sto.setReference(ref);
                },
                .delete => {
                    sto.removeReference(local);
                },
                .invalid => {},
            }
        }
    }
}

/// go-git `(*Remote).addReachableTags` — push annotated tags whose target commit
/// is an ancestor of a tip already being pushed.
fn addReachableTags(
    allocator: Allocator,
    sto: *memory.Storage,
    local_refs: []const Reference,
    remote_refs: *const memory.ReferenceStorage,
    req: *packp.ReferenceUpdateRequest,
) !void {
    for (local_refs) |ref| {
        if (!ref.name.isTag()) continue;

        if (remote_refs.reference(ref.name)) |_| {
            continue;
        } else |err| {
            if (err != error.ReferenceNotFound) return err;
        }

        // Only annotated tags (object type `.tag`); lightweight tags skip.
        var tag = objpkg.getTag(allocator, sto, ref.hash) catch continue;
        defer tag.deinit();
        if (tag.target_type != .commit) continue;

        const tag_commit = objpkg.getCommit(allocator, sto, tag.target) catch continue;
        defer freeHeapCommit(tag_commit);

        for (req.commands.items) |cmd| {
            if (cmd.name.eql(ref.name)) continue;
            if (std.mem.startsWith(u8, cmd.name.raw, "refs/tags")) continue;
            if (cmd.new.isZero()) continue;

            const tip = objpkg.getCommit(allocator, sto, cmd.new) catch continue;
            defer freeHeapCommit(tip);

            if (try objpkg.isAncestor(tag_commit, tip)) {
                try req.appendCommandOwnedName(ref.name.raw, ZeroHash, ref.hash);
                break;
            }
        }
    }
}

fn freeHeapCommit(c: *objpkg.Commit) void {
    objpkg.freeCommit(c.allocator, c);
}

test "objectsToPush skips deletes" {
    const cmds = [_]packp.Command{
        .{ .name = ReferenceName.init("refs/heads/a"), .old = ZeroHash, .new = plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") },
        .{ .name = ReferenceName.init("refs/heads/b"), .old = plumbing.newHash("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), .new = ZeroHash },
    };
    const hs = try objectsToPush(std.testing.allocator, &cmds);
    defer std.testing.allocator.free(hs);
    try std.testing.expectEqual(@as(usize, 1), hs.len);
}
