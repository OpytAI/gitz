//! Worktree Pull — port of go-git `(*Worktree).Pull` / `PullContext` (FF only).
//!
//! Flow:
//! 1. Validate `PullOptions`
//! 2. Build `Remote` from storer config remotes (embedded when `w.embedded` set)
//! 3. `Fetch` with options derived from pull options
//! 4. Resolve fetched ref from remote advertisement (list → reference map)
//! 5. Fast-forward check via `remote.isFastForward`
//! 6. Non-FF without force → `error.NonFastForwardUpdate`
//! 7. Update branch tip (`updateHEAD`) + `Reset` (MergeReset) worktree files
//!
//! `error.AlreadyUpToDate` from fetch is handled like go-git `NoErrAlreadyUpToDate`.

const std = @import("std");
const plumbing = @import("plumbing");
const storer = @import("storer");
const memory = @import("memory");
const remote = @import("remote");
const server = @import("server");
const sync = @import("utils/sync");
const transport = @import("transport");

const worktree_mod = @import("worktree.zig");
const options_mod = @import("options.zig");
const error_mod = @import("error.zig");
const reset_mod = @import("reset.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const Worktree = worktree_mod.Worktree;
const PullOptions = options_mod.PullOptions;
const FetchOptions = remote.FetchOptions;
const RemoteError = remote.Error;
const WorktreeError = error_mod.Error;

// go-git `(*Worktree).Pull` / `PullContext` (no context; transport is sync).
//
// Returns `error.AlreadyUpToDate` when the branch is already current and
// fetch reported no updates (go-git `NoErrAlreadyUpToDate`).
pub fn pull(w: *Worktree, o: *PullOptions) !void {
    try o.validate();

    const cfg = try w.storer.config();
    const remote_cfg = cfg.remotes.getPtr(o.remote_name) orelse return error.RemoteNotFound;

    var rem: remote.Remote = if (w.embedded) |srv|
        remote.newRemoteEmbedded(w.storer, remote_cfg, srv)
    else
        remote.newRemote(w.storer, remote_cfg);

    var fetch_opts: FetchOptions = .{
        .remote_name = o.remote_name,
        .remote_url = o.remote_url,
        .depth = o.depth,
        .force = o.force,
        .transport = o.transport,
        .progress = o.progress,
    };

    var updated = true;
    rem.fetch(&fetch_opts) catch |err| {
        if (err == RemoteError.AlreadyUpToDate or err == error.AlreadyUpToDate) {
            updated = false;
        } else {
            return err;
        }
    };

    // go-git reuses the fetch session's advertised refs as `fetchHead`.
    // Our Fetch API does not return them; re-list the remote advertisement.
    const remote_refs = try listRemoteRefs(w.allocator, &rem, o);
    defer remote.freeReferences(w.allocator, remote_refs);

    var fetch_head = memory.ReferenceStorage.init(w.allocator);
    defer fetch_head.deinit();
    for (remote_refs) |r| {
        try fetch_head.setReference(r);
    }

    const ref = try storer.resolveReference(&fetch_head, o.reference_name);

    const head_or_err = storer.resolveReference(w.storer, plumbing.HEAD);
    if (head_or_err) |head| {
        const shallow_list = w.storer.shallow();
        const earliest_shallow: ?Hash = if (shallow_list.len > 0) shallow_list[0] else null;

        // isFastForward(old=ref, new=head) ⇒ head is at or ahead of ref.
        const head_ahead_of_ref = try remote.isFastForward(
            w.allocator,
            w.storer,
            ref.hash,
            head.hash,
            earliest_shallow,
        );

        if (!updated and head_ahead_of_ref) {
            return RemoteError.AlreadyUpToDate;
        }

        // isFastForward(old=head, new=ref) ⇒ ref descends from head (FF pull).
        const ff = try remote.isFastForward(
            w.allocator,
            w.storer,
            head.hash,
            ref.hash,
            earliest_shallow,
        );

        // go-git always errors on non-FF; PullOptions.Force documents allowing
        // non-FF branch update (also matches this port's task contract).
        if (!ff and !o.force) {
            return WorktreeError.NonFastForwardUpdate;
        }
    } else |err| {
        if (err != error.ReferenceNotFound) return err;
    }

    try updateHEAD(w, ref.hash);

    try reset_mod.reset(w, .{
        .commit = ref.hash,
        .mode = .merge,
    });

    if (o.recurse_submodules > 0) {
        const updater = o.submodule_updater orelse return error.SubmoduleUpdateNotConfigured;
        try updater.update(
            w.allocator,
            w.storer,
            w.filesystem,
            w.embedded,
            o.recurse_submodules,
            0,
            o.transport.auth,
            o.transport.operation_context,
        );
    }
}

/// Package-level go-git `PullContext` equivalent.
pub fn pullContext(
    w: *Worktree,
    context: transport.OperationContext,
    o: *const PullOptions,
) !void {
    var opts = o.*;
    opts.transport.operation_context = context;
    return pull(w, &opts);
}

// go-git `(*Worktree).updateHEAD` — move the current branch tip (or detached HEAD).
fn updateHEAD(w: *Worktree, commit: Hash) !void {
    const head = try w.storer.reference(plumbing.HEAD);
    var name: ReferenceName = plumbing.HEAD;
    if (head.type != .hash) {
        name = head.target;
    }
    try w.storer.setReference(Reference.newHashReference(name, commit));
}

// List advertised remote refs (fetchHead substitute). Honors `remote_url` override.
fn listRemoteRefs(allocator: Allocator, rem: *const remote.Remote, o: *const PullOptions) ![]Reference {
    const list_opts: remote.ListOptions = .{
        .transport = o.transport,
    };

    if (o.remote_url.len == 0) {
        return rem.list(list_opts);
    }

    // List uses config.urls[0]; when PullOptions.remote_url overrides fetch,
    // list against the same URL via a temporary config view.
    const url_owned = try allocator.dupe(u8, o.remote_url);
    defer allocator.free(url_owned);
    var urls = [_][]u8{url_owned};
    const tmp_cfg = memory.RemoteConfig{
        .name = rem.config.name,
        .urls = urls[0..],
        .fetch = rem.config.fetch,
        .mirror = rem.config.mirror,
    };
    // `Remote.list` only needs config + embedded; reconstruct a handle.
    const list_rem = if (rem.embedded) |srv|
        remote.newRemoteEmbedded(rem.storer, &tmp_cfg, srv)
    else
        remote.newRemote(rem.storer, &tmp_cfg);
    return list_rem.list(list_opts);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "PullOptions validate defaults remote name and HEAD" {
    var o: PullOptions = .{};
    try o.validate();
    try std.testing.expectEqualStrings(remote.default_remote_name, o.remote_name);
    try std.testing.expectEqualStrings(plumbing.HEAD.raw, o.reference_name.raw);
}

test "pull missing remote → RemoteNotFound" {
    const allocator = std.testing.allocator;
    const sto = try memory.newStorage(allocator);
    defer {
        sto.deinit();
        allocator.destroy(sto);
    }
    var mem_fs = try @import("fs").Mem.init(allocator);
    defer mem_fs.deinit();

    var w = worktree_mod.newWorktree(allocator, sto, &mem_fs);
    var o: PullOptions = .{};
    try std.testing.expectError(error.RemoteNotFound, pull(&w, &o));
}

// MapLoader + embedded server e2e (same pattern as `src/remote/tests.zig`).
//
// Needs:
// - `//src/plumbing/transport/test:fixtures` (`populateRepo`, `makeEndpoint`)
// - `server.MapLoader` + `server.newClient` bound via `newWorktreeEmbedded`
// - remote entry in memory config with fetch refspec
// - local `HEAD` → `refs/heads/master` (branch tip may be absent before first pull)
// - `reset.zig` MergeReset to materialize worktree files after tip update
test "pull via MapLoader embedded fetches and updates branch tip" {
    const allocator = std.testing.allocator;
    defer sync.deinitPools(allocator);

    const fixtures = @import("transport_test_fixtures");
    const fs_pkg = @import("fs");

    var loader = server.MapLoader.init(allocator);
    defer loader.deinit();

    const remote_sto = try memory.newStorage(allocator);
    defer {
        remote_sto.deinit();
        allocator.destroy(remote_sto);
    }
    const remote_head = try fixtures.populateRepo(remote_sto, allocator);

    const local_sto = try memory.newStorage(allocator);
    defer {
        local_sto.deinit();
        allocator.destroy(local_sto);
    }
    // Empty local with symbolic HEAD (go-git Init style).
    try local_sto.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));

    const cfg = try local_sto.config();
    try cfg.putRemoteFull(
        "origin",
        &[_][]const u8{"file://pull-remote"},
        &[_][]const u8{"+refs/heads/*:refs/remotes/origin/*"},
        false,
    );
    try local_sto.setConfig(cfg);

    var ep = try fixtures.makeEndpoint(allocator, "file://pull-remote");
    defer ep.deinit();
    try loader.put(&ep, remote_sto);

    var client = server.newClient(allocator, loader.asLoader());
    var mem_fs = try fs_pkg.Mem.init(allocator);
    defer mem_fs.deinit();

    var w = worktree_mod.newWorktreeEmbedded(allocator, local_sto, &mem_fs, &client);
    const Hook = struct {
        fn update(
            context: ?*anyopaque,
            _: Allocator,
            _: *memory.Storage,
            _: *@import("fs").Mem,
            _: ?*server.Server,
            recurse: u32,
            _: i32,
            _: ?@import("transport").AuthMethod,
            _: @import("transport").OperationContext,
        ) anyerror!void {
            const called: *bool = @ptrCast(@alignCast(context.?));
            try std.testing.expectEqual(@as(u32, 2), recurse);
            called.* = true;
        }
    };
    var submodules_updated = false;
    var o: PullOptions = .{
        .recurse_submodules = 2,
        .submodule_updater = .{
            .context = &submodules_updated,
            .update_fn = Hook.update,
        },
    };
    try pull(&w, &o);
    try std.testing.expect(submodules_updated);

    const master = try local_sto.reference(plumbing.master);
    try std.testing.expect(master.hash.eql(remote_head));

    const tracking = try local_sto.reference(plumbing.ReferenceName.init("refs/remotes/origin/master"));
    try std.testing.expect(tracking.hash.eql(remote_head));

    // Second pull is AlreadyUpToDate when tip matches remote.
    var o2: PullOptions = .{};
    try std.testing.expectError(RemoteError.AlreadyUpToDate, pull(&w, &o2));
}
