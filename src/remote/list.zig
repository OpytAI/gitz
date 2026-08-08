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
    for (refs) |r| {
        if (r.name.raw.len > 0) allocator.free(r.name.raw);
        if (r.type == .symbolic and r.target.raw.len > 0) allocator.free(r.target.raw);
    }
    allocator.free(refs);
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
    // effectiveTimeoutSec is reserved for phase-13 network deadlines.
    _ = o.effectiveTimeoutSec();

    if (config.urls.len == 0) return RemoteError.EmptyUrls;

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const sopts = session.sessionOptsFrom(
        o.auth,
        o.insecure_skip_tls,
        o.client_cert,
        o.client_key,
        o.ca_bundle,
        o.proxy,
    );
    var sess = try session.openUploadPack(allocator, io, config.urls[0], sopts, embedded);
    defer sess.close();

    const ar = try sess.advertisedReferences();
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

fn freeReferenceList(allocator: Allocator, refs_list: *std.ArrayList(Reference)) void {
    for (refs_list.items) |r| {
        if (r.name.raw.len > 0) allocator.free(r.name.raw);
        if (r.type == .symbolic and r.target.raw.len > 0) allocator.free(r.target.raw);
    }
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
    try std.testing.expect(@intFromEnum(PeelingOption.append_peeled) == 1);
    try std.testing.expect(@intFromEnum(PeelingOption.only_peeled) == 2);
}
