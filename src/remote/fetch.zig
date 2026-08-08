//! Remote Fetch — port of go-git `(*Remote).Fetch` / `fetch` core.
//!
//! Memory / in-process path: open upload-pack, negotiate wants/haves,
//! ingest pack into local storer, update local refs, optional prune + shallow.

const std = @import("std");
const plumbing = @import("plumbing");
const packp = @import("packp");
const capability = @import("capability");
const packfile = @import("packfile");
const memory = @import("memory");
const storer = @import("storer");
const gitconfig = @import("gitconfig");
const sync = @import("utils/sync");
const transport = @import("transport");
const server = @import("server");

const options_mod = @import("options.zig");
const error_mod = @import("error.zig");
const session = @import("session.zig");
const refs = @import("refs.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const RefSpec = gitconfig.RefSpec;
const FetchOptions = options_mod.FetchOptions;
const TagMode = options_mod.TagMode;
const RemoteError = error_mod.Error;

/// go-git `(*Remote).Fetch`.
///
/// Returns `error.AlreadyUpToDate` when nothing changed (go-git `NoErrAlreadyUpToDate`).
pub fn fetch(
    allocator: Allocator,
    sto: *memory.Storage,
    config: *const memory.RemoteConfig,
    embedded: ?*server.Server,
    o: *FetchOptions,
) !void {
    if (o.remote_name.len == 0) {
        o.remote_name = config.name;
    }
    try o.validate();

    // Own temporary RefSpec list when filled from config / default.
    // Restore empty slice on exit so callers do not keep a dangling pointer.
    const specs_were_empty = o.ref_specs.len == 0;
    var owned_specs: ?[]RefSpec = null;
    defer if (owned_specs) |s| {
        for (s) |rs| allocator.free(rs.raw);
        allocator.free(s);
        if (specs_were_empty) o.ref_specs = &.{};
    };

    if (specs_were_empty) {
        owned_specs = try refSpecsFromConfig(allocator, config);
        o.ref_specs = owned_specs.?;
    }

    if (o.remote_url.len == 0) {
        if (config.urls.len == 0) return RemoteError.EmptyUrls;
        o.remote_url = config.urls[0];
    }

    const sopts = session.SessionOpts.fromClient(o.transport);
    var sess = try session.openUploadPackUrl(allocator, o.remote_url, sopts, embedded);
    defer sess.close();

    const ar = try sess.advertisedReferences();
    defer packp.freeAdvRefs(allocator, ar);

    var req = try packp.newUploadPackRequestFromCapabilities(allocator, &ar.capabilities);
    defer req.deinit();
    try configureUploadPackRequest(&req, o, ar, sto);

    try isSupportedRefSpec(o.ref_specs, ar);

    var remote_refs = try ar.allReferences();
    defer remote_refs.deinit();

    const local_refs = try refs.collectLocalRefs(allocator, sto);
    defer allocator.free(local_refs);

    var calc = try refs.calculateRefs(allocator, o.ref_specs, &remote_refs, o.tags);
    defer calc.deinit();

    const shallow_before = try allocator.dupe(Hash, sto.shallow());
    defer allocator.free(shallow_before);

    const wants = try refs.getWants(allocator, sto, &calc.refs, o.depth);
    defer allocator.free(wants);

    if (wants.len > 0) {
        try req.upload_request.wants.appendSlice(allocator, wants);
        const haves = try refs.getHaves(allocator, local_refs, &remote_refs, sto, o.depth);
        defer allocator.free(haves);
        try req.upload_haves.haves.appendSlice(allocator, haves);

        fetchPack(allocator, sto, &sess, &req, o.depth) catch |err| {
            if (err == transport.Error.EmptyUploadPackRequest) {
                // Everything up-to-date at pack level.
            } else return err;
        };
    }

    var updated_prune = false;
    if (o.prune) {
        updated_prune = try pruneRemotes(allocator, sto, o.ref_specs, local_refs, &remote_refs);
    }

    const updated_refs = try updateLocalReferenceStorage(
        allocator,
        sto,
        o.ref_specs,
        &calc.refs,
        &remote_refs,
        calc.spec_to_refs,
        o.tags,
        o.force,
    );

    var updated = updated_refs;
    if (!updated) {
        updated = try depthChanged(shallow_before, sto);
    }
    if (!updated) {
        for (wants) |h| {
            if (refs.objectExists(sto, h)) {
                updated = true;
                break;
            }
        }
    }

    if (!updated and !updated_prune) {
        return RemoteError.AlreadyUpToDate;
    }
}

fn refSpecsFromConfig(allocator: Allocator, config: *const memory.RemoteConfig) ![]RefSpec {
    if (config.fetch.len == 0) {
        const raw = try std.fmt.allocPrint(allocator, gitconfig.default_fetch_ref_spec, .{config.name});
        errdefer allocator.free(raw);
        const arr = try allocator.alloc(RefSpec, 1);
        arr[0] = RefSpec.init(raw);
        return arr;
    }
    const arr = try allocator.alloc(RefSpec, config.fetch.len);
    var filled: usize = 0;
    errdefer {
        for (arr[0..filled]) |rs| allocator.free(rs.raw);
        allocator.free(arr);
    }
    for (config.fetch) |s| {
        arr[filled] = RefSpec.init(try allocator.dupe(u8, s));
        filled += 1;
    }
    return arr;
}

fn configureUploadPackRequest(
    req: *packp.UploadPackRequest,
    o: *const FetchOptions,
    ar: *const packp.AdvRefs,
    sto: *memory.Storage,
) !void {
    if (o.depth != 0) {
        req.upload_request.depth = .{ .commits = o.depth };
        try req.upload_request.capabilities.set(capability.Shallow, &.{});
        try req.upload_request.shallows.appendSlice(sto.allocator, sto.shallow());
    }

    // go-git: when Progress is nil and remote supports no-progress, request it.
    // When progress is set, do not set NoProgress so the server may send progress.
    if (o.progress == null and ar.capabilities.supports(capability.NoProgress)) {
        try req.upload_request.capabilities.set(capability.NoProgress, &.{});
    }

    var is_wildcard = true;
    for (o.ref_specs) |s| {
        if (!s.isWildcard()) {
            is_wildcard = false;
            break;
        }
    }
    if (is_wildcard and o.tags == .following and ar.capabilities.supports(capability.IncludeTag)) {
        try req.upload_request.capabilities.set(capability.IncludeTag, &.{});
    }
}

fn isSupportedRefSpec(specs: []const RefSpec, ar: *const packp.AdvRefs) !void {
    var contains_exact = false;
    for (specs) |s| {
        if (s.isExactSHA1()) contains_exact = true;
    }
    if (!contains_exact) return;
    if (ar.capabilities.supports(capability.AllowReachableSHA1InWant) or
        ar.capabilities.supports(capability.AllowTipSHA1InWant))
    {
        return;
    }
    return RemoteError.ExactSHA1NotSupported;
}

fn fetchPack(
    allocator: Allocator,
    sto: *memory.Storage,
    sess: *session.SessionUpload,
    req: *const packp.UploadPackRequest,
    depth: i32,
) !void {
    const resp = try sess.uploadPack(req);
    defer packp.freeUploadPackResponse(allocator, resp);

    try updateShallow(allocator, sto, depth, resp);

    const pack_bytes = try resp.readAll(allocator);
    defer allocator.free(pack_bytes);

    if (pack_bytes.len == 0) return;
    try applyPackToStorer(allocator, sto, pack_bytes);
}

/// go-git `(*Remote).updateShallow` — merge response shallows into storer.
fn updateShallow(
    allocator: Allocator,
    sto: *memory.Storage,
    depth: i32,
    resp: *const packp.UploadPackResponse,
) !void {
    if (depth == 0) return;
    const new_shallows = resp.shallow_update.shallows.items;
    if (new_shallows.len == 0) return;

    var set: std.AutoHashMapUnmanaged(Hash, void) = .empty;
    defer set.deinit(allocator);
    for (sto.shallow()) |h| try set.put(allocator, h, {});
    for (new_shallows) |h| try set.put(allocator, h, {});

    var merged: std.ArrayList(Hash) = .empty;
    defer merged.deinit(allocator);
    var it = set.keyIterator();
    while (it.next()) |k| try merged.append(allocator, k.*);
    try sto.setShallow(merged.items);
}

/// go-git `depthChanged` — true when the shallow list changed.
fn depthChanged(before: []const Hash, sto: *const memory.Storage) !bool {
    const after = sto.shallow();
    if (before.len != after.len) return true;
    var set: std.AutoHashMapUnmanaged(Hash, void) = .empty;
    defer set.deinit(sto.allocator);
    for (before) |b| try set.put(sto.allocator, b, {});
    for (after) |a| {
        if (!set.contains(a)) return true;
    }
    return false;
}

/// Ingest pack bytes into memory storage (go-git `packfile.UpdateObjectStorage` path).
fn applyPackToStorer(allocator: Allocator, sto: *memory.Storage, pack_bytes: []const u8) !void {
    var obj_store = packfile.ObjectStore.init(allocator);
    defer obj_store.deinit();

    _ = packfile.updateObjectStorage(allocator, &obj_store, pack_bytes) catch |err| {
        if (err == error.EmptyPackfile) return;
        return err;
    };

    var it = obj_store.map.iterator();
    while (it.next()) |e| {
        const src = e.value_ptr.*;
        const dst = try sto.newEncodedObject();
        errdefer {
            dst.deinit();
            dst.allocator.destroy(dst);
        }
        dst.setType(src.object_type);
        try dst.setContent(src.readerBytes());
        _ = try sto.setEncodedObject(dst);
    }
    sync.deinitPools(allocator);
}

fn pruneRemotes(
    allocator: Allocator,
    sto: *memory.Storage,
    specs: []const RefSpec,
    local_refs: []const Reference,
    remote_refs: *const memory.ReferenceStorage,
) !bool {
    var updated = false;
    for (specs) |spec| {
        const rev_raw = try spec.reverse(allocator);
        defer allocator.free(rev_raw);
        const rev = RefSpec.init(rev_raw);
        for (local_refs) |ref| {
            if (!rev.match(ref.name)) continue;
            const remote_name = try rev.dst(allocator, ref.name);
            defer allocator.free(remote_name.raw);
            _ = remote_refs.reference(remote_name) catch |err| {
                if (err == error.ReferenceNotFound) {
                    sto.removeReference(ref.name);
                    updated = true;
                    continue;
                }
                return err;
            };
        }
    }
    return updated;
}

fn updateLocalReferenceStorage(
    allocator: Allocator,
    sto: *memory.Storage,
    specs: []const RefSpec,
    fetched_refs: *const memory.ReferenceStorage,
    remote_refs: *const memory.ReferenceStorage,
    spec_to_refs: []const []const Reference,
    tag_mode: TagMode,
    force: bool,
) !bool {
    var updated = false;
    var force_needed = false;
    var is_wildcard = true;

    for (specs, 0..) |spec, i| {
        if (!spec.isWildcard()) is_wildcard = false;
        if (i >= spec_to_refs.len) continue;

        for (spec_to_refs[i]) |ref| {
            if (ref.type != .hash) continue;

            const local_name = try spec.dst(allocator, ref.name);
            defer allocator.free(local_name.raw);

            var name_for_set = local_name;
            var branch_owned: ?[]u8 = null;
            defer if (branch_owned) |b| allocator.free(b);

            if (!std.mem.startsWith(u8, local_name.raw, "refs/")) {
                const owned = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{local_name.raw});
                branch_owned = owned;
                name_for_set = ReferenceName.init(owned);
            }

            const old = storer.resolveReference(sto, name_for_set) catch |err| switch (err) {
                error.ReferenceNotFound => null,
                else => return err,
            };

            const new_ref = Reference.newHashReference(name_for_set, ref.hash);

            if (old) |o| {
                if (!o.name.isTag() and !force and !spec.isForceUpdate()) {
                    // Missing objects → not FF (conservative); real errors propagate.
                    const ff = refs.isFastForward(allocator, sto, o.hash, new_ref.hash, null) catch |err| switch (err) {
                        error.ObjectNotFound => false,
                        else => return err,
                    };
                    if (!ff) {
                        force_needed = true;
                        continue;
                    }
                }
            }

            if (try checkAndUpdateReferenceIfNeeded(sto, new_ref, old)) updated = true;
        }
    }

    if (tag_mode == .none) {
        if (force_needed) return RemoteError.ForceNeeded;
        return updated;
    }

    const tags_src: *const memory.ReferenceStorage = if (is_wildcard) remote_refs else fetched_refs;
    if (try buildFetchedTags(sto, tags_src)) updated = true;

    if (force_needed) return RemoteError.ForceNeeded;
    return updated;
}

fn buildFetchedTags(sto: *memory.Storage, refs_store: *const memory.ReferenceStorage) !bool {
    var updated = false;
    var iter = try refs_store.iterReferences();
    defer iter.deinit();
    while (true) {
        const ref = iter.next() catch |err| switch (err) {
            error.EndOfStream => break,
        };
        if (!ref.name.isTag()) continue;
        sto.hasEncodedObject(ref.hash) catch |err| {
            if (err == error.ObjectNotFound) continue;
            return err;
        };
        if (try checkAndUpdateReferenceIfNeeded(sto, ref, null)) updated = true;
    }
    return updated;
}

fn checkAndUpdateReferenceIfNeeded(
    sto: *memory.Storage,
    new_ref: Reference,
    old: ?Reference,
) !bool {
    const cur = sto.reference(new_ref.name) catch |err| switch (err) {
        error.ReferenceNotFound => {
            try sto.checkAndSetReference(new_ref, old);
            return true;
        },
        else => return err,
    };
    if (new_ref.eql(cur)) return false;
    try sto.checkAndSetReference(new_ref, old);
    return true;
}
