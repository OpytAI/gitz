//! Remote List — port of go-git `(*Remote).List` / `list`.
//!
//! Opens an upload-pack session, reads advertised references, and applies
//! `PeelingOption`. Returns an owned `[]Reference` freed via `freeReferences`.

const std = @import("std");
const plumbing = @import("plumbing");
const packp = @import("packp");
const memory = @import("memory");
const server = @import("server");

const options_mod = @import("options.zig");
const error_mod = @import("error.zig");
const session = @import("session.zig");

const Allocator = std.mem.Allocator;
const Reference = plumbing.Reference;
const ListOptions = options_mod.ListOptions;
const PeelingOption = options_mod.PeelingOption;
const RemoteError = error_mod.Error;

/// Free a slice returned by `list` (names/targets owned by the slice).
pub fn freeReferences(allocator: Allocator, refs: []Reference) void {
    freeReferenceOwned(allocator, refs);
    allocator.free(refs);
}

fn freeReferenceOwned(allocator: Allocator, refs: []const Reference) void {
    for (refs) |r| {
        if (r.name.raw.len > 0) allocator.free(r.name.raw);
        if (r.type == .symbolic and r.target.raw.len > 0) allocator.free(r.target.raw);
    }
}

/// go-git `(*Remote).List` / `list`.
///
/// Caller frees the result with `freeReferences`.
pub fn list(
    allocator: Allocator,
    config: *const memory.RemoteConfig,
    embedded: ?*server.Server,
    o: ListOptions,
) ![]Reference {
    if (o.timeout_sec < 0) return RemoteError.InvalidTimeout;
    if (config.urls.len == 0) return RemoteError.EmptyUrls;

    const sopts = session.SessionOpts.fromClient(o.transport);
    const ar = try advertisedReferencesWithTimeout(
        allocator,
        config.urls[0],
        sopts,
        embedded,
        o.effectiveTimeoutSec(),
    );
    defer packp.freeAdvRefs(allocator, ar);

    var all_refs = try ar.allReferences();
    defer all_refs.deinit();

    var out: std.ArrayList(Reference) = .empty;
    errdefer freeReferenceList(allocator, &out);

    if (o.peeling == .append_peeled or o.peeling == .ignore_peeled) {
        try appendStorageRefs(allocator, &out, &all_refs);
    }
    if (o.peeling == .append_peeled or o.peeling == .only_peeled) {
        try appendPeeledRefs(allocator, &out, ar);
    }

    return try out.toOwnedSlice(allocator);
}

const TimedAdvertisement = union(enum) {
    advertisement: anyerror!*packp.AdvRefs,
    deadline: std.Io.Cancelable!void,
};

/// Enforce go-git's List timeout around both the transport connect and the
/// advertised-reference read. Canceling the operation interrupts its next
/// std.Io cancellation point, including socket connect/read/write operations.
fn advertisedReferencesWithTimeout(
    allocator: Allocator,
    url: []const u8,
    opts: session.SessionOpts,
    embedded: ?*server.Server,
    timeout_sec: i32,
) !*packp.AdvRefs {
    const io = session.defaultIo();
    var results: [2]TimedAdvertisement = undefined;
    var select = std.Io.Select(TimedAdvertisement).init(io, &results);
    select.async(.advertisement, openAndReadAdvertisement, .{ allocator, io, url, opts, embedded });
    select.async(.deadline, waitForDeadline, .{ io, std.Io.Duration.fromSeconds(timeout_sec) });

    const first = try select.await();
    switch (first) {
        .advertisement => |result| {
            // Only the timer remains and it owns no resources.
            select.cancelDiscard();
            return result;
        },
        .deadline => |deadline_result| {
            // A spontaneous timer error is not a timeout. Preserve it.
            try deadline_result;
            // Drain the canceled operation. It may have completed at the same
            // instant as the timer and returned an allocation that we own.
            while (select.cancel()) |remaining| switch (remaining) {
                .advertisement => |result| if (result) |refs| {
                    packp.freeAdvRefs(allocator, refs);
                } else |_| {},
                .deadline => {},
            };
            return RemoteError.ListTimeout;
        },
    }
}

fn openAndReadAdvertisement(
    allocator: Allocator,
    io: std.Io,
    url: []const u8,
    opts: session.SessionOpts,
    embedded: ?*server.Server,
) anyerror!*packp.AdvRefs {
    var sess = try session.openUploadPack(allocator, io, url, opts, embedded);
    defer sess.close();
    return sess.advertisedReferences();
}

fn waitForDeadline(io: std.Io, duration: std.Io.Duration) std.Io.Cancelable!void {
    return std.Io.sleep(io, duration, .real);
}

fn freeReferenceList(allocator: Allocator, refs_list: *std.ArrayList(Reference)) void {
    freeReferenceOwned(allocator, refs_list.items);
    refs_list.deinit(allocator);
}

fn appendStorageRefs(
    allocator: Allocator,
    out: *std.ArrayList(Reference),
    store: *const memory.ReferenceStorage,
) !void {
    var iter = try store.iterReferences();
    defer iter.deinit();
    while (true) {
        const ref = iter.next() catch |err| switch (err) {
            error.EndOfStream => break,
        };
        try out.append(allocator, try cloneReference(allocator, ref));
    }
}

fn appendPeeledRefs(
    allocator: Allocator,
    out: *std.ArrayList(Reference),
    ar: *const packp.AdvRefs,
) !void {
    var it = ar.peeled.iterator();
    while (it.next()) |e| {
        try out.ensureUnusedCapacity(allocator, 1);
        const name_owned = try std.fmt.allocPrint(allocator, "{s}{s}", .{ e.key_ptr.*, packp.peeled });
        out.appendAssumeCapacity(Reference.newHashReference(
            plumbing.ReferenceName.init(name_owned),
            e.value_ptr.*,
        ));
    }
}

fn cloneReference(allocator: Allocator, ref: Reference) !Reference {
    const name = try allocator.dupe(u8, ref.name.raw);
    errdefer allocator.free(name);
    switch (ref.type) {
        .hash => return Reference.newHashReference(plumbing.ReferenceName.init(name), ref.hash),
        .symbolic => {
            const target = try allocator.dupe(u8, ref.target.raw);
            return Reference.newSymbolicReference(
                plumbing.ReferenceName.init(name),
                plumbing.ReferenceName.init(target),
            );
        },
        .invalid => {
            allocator.free(name);
            return ref;
        },
    }
}

test "PeelingOption values" {
    try std.testing.expect(@intFromEnum(PeelingOption.ignore_peeled) == 0);
    try std.testing.expect(@intFromEnum(PeelingOption.only_peeled) == 1);
    try std.testing.expect(@intFromEnum(PeelingOption.append_peeled) == 2);
}

test "List deadline task is an actual monotonic timer" {
    try waitForDeadline(std.testing.io, .fromNanoseconds(0));
}
