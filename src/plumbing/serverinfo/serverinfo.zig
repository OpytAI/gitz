//! Update dumb-HTTP server info files (go-git `plumbing/serverinfo`).
//!
//! Port of go-git v5.19.2 `plumbing/serverinfo/serverinfo.go`.
//!
//! Writes:
//! - `info/refs` — sorted refs (skip symbolic HEAD; peel annotated tags)
//! - `objects/info/packs` — `P pack-<hash>.pack` lines plus a trailing newline
//!
//! The storer must implement **PackedObjectStorer** (`objectPacks`). When the
//! method is absent, returns `error.PackedObjectsNotSupported`
//! (go-git `git.ErrPackedObjectsNotSupported`).

const std = @import("std");
const plumbing = @import("plumbing");
const object = @import("object");
const internal_reference = @import("internal_reference");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const MaxHexSize = plumbing.MaxHexSize;

/// Package errors for UpdateServerInfo.
pub const Error = error{
    /// Storer does not implement packed-object support
    /// (go-git `git.ErrPackedObjectsNotSupported` / "packed objects not supported").
    PackedObjectsNotSupported,
};

/// go-git `UpdateServerInfo` — write `info/refs` and `objects/info/packs`.
///
/// `s` must provide:
/// - `iterReferences()` → iterator with `next` / `deinit` (and hash refs)
/// - `reference(name)` → resolve symbolic targets
/// - `encodedObject(type, hash)` → used by `object.getTag` for peeling
/// - `objectPacks()` → `[]const Hash` or `![]const Hash` (PackedObjectStorer)
///
/// `fs` must provide billy-style `create(path) !File` where File has
/// `write([]const u8)` and `close()`.
///
/// Pack hashes returned by `objectPacks` with non-zero length are freed with
/// `s.allocator` when that field exists (filesystem backends). Memory returns
/// an empty static slice and is not freed.
pub fn updateServerInfo(allocator: Allocator, s: anytype, fs: anytype) !void {
    const S = @TypeOf(s.*);
    if (comptime !@hasDecl(S, "objectPacks")) {
        return error.PackedObjectsNotSupported;
    }

    try writeInfoRefs(allocator, s, fs);
    try writeInfoPacks(allocator, s, fs);
}

// ---------------------------------------------------------------------------
// info/refs
// ---------------------------------------------------------------------------

/// Format: `<40-hex-hash>\t<refname>\n` and for annotated tags
/// `<target-hex>\t<refname>^{}\n` (go-git `fmt.Fprintf(..., "%s\t%s\n", ...)`).
fn writeInfoRefs(allocator: Allocator, s: anytype, fs: anytype) !void {
    var info_refs = try fs.create("info/refs");
    defer info_refs.close() catch {};

    var refs = try collectReferences(allocator, s);
    defer refs.deinit(allocator);

    internal_reference.sort(refs.items);

    for (refs.items) |ref| {
        const name = ref.name;
        var hash = ref.hash;

        switch (ref.type) {
            .symbolic => {
                // go-git skips symbolic HEAD only.
                if (name.eql(plumbing.HEAD)) continue;

                const target_ref = try s.reference(ref.target);
                hash = target_ref.hash;
                try writeRefLine(allocator, &info_refs, hash, name.raw);
                try maybeWritePeeledTag(allocator, s, &info_refs, hash, name);
            },
            .hash => {
                try writeRefLine(allocator, &info_refs, hash, name.raw);
                try maybeWritePeeledTag(allocator, s, &info_refs, hash, name);
            },
            .invalid => {},
        }
    }
}

fn collectReferences(allocator: Allocator, s: anytype) !std.ArrayList(Reference) {
    var list: std.ArrayList(Reference) = .empty;
    errdefer list.deinit(allocator);

    var iter = try s.iterReferences();
    defer iter.deinit();

    while (true) {
        const ref = iter.next() catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        try list.append(allocator, ref);
    }
    return list;
}

fn writeRefLine(allocator: Allocator, file: anytype, hash: Hash, name: []const u8) !void {
    var hex_buf: [MaxHexSize]u8 = undefined;
    const hex = hash.string(&hex_buf);
    const line = try std.fmt.allocPrint(allocator, "{s}\t{s}\n", .{ hex, name });
    defer allocator.free(line);
    _ = try file.write(line);
}

/// When `hash` is an annotated tag object, append the peeled line
/// (`name^{}` → tag.Target). Lightweight tags (hash is commit/etc.) are skipped
/// silently, matching go-git `object.GetTag` error ignore.
fn maybeWritePeeledTag(
    allocator: Allocator,
    s: anytype,
    file: anytype,
    hash: Hash,
    name: ReferenceName,
) !void {
    if (!name.isTag()) return;

    var tag = object.getTag(allocator, s, hash) catch return;
    defer tag.deinit();

    var hex_buf: [MaxHexSize]u8 = undefined;
    const hex = tag.target.string(&hex_buf);
    // go-git: fmt.Fprintf(infoRefs, "%s\t%s^{}\n", tag.Target, name)
    const line = try std.fmt.allocPrint(allocator, "{s}\t{s}^{{}}\n", .{ hex, name.raw });
    defer allocator.free(line);
    _ = try file.write(line);
}

// ---------------------------------------------------------------------------
// objects/info/packs
// ---------------------------------------------------------------------------

/// Format: `P pack-<hash>.pack\n` per pack, then a final blank line
/// (go-git `fmt.Fprintln` after the loop).
fn writeInfoPacks(allocator: Allocator, s: anytype, fs: anytype) !void {
    var info_packs = try fs.create("objects/info/packs");
    defer info_packs.close() catch {};

    const packs = try callObjectPacks(s);
    defer freeObjectPacks(allocator, s, packs);

    for (packs) |p| {
        var hex_buf: [MaxHexSize]u8 = undefined;
        const hex = p.string(&hex_buf);
        const line = try std.fmt.allocPrint(allocator, "P pack-{s}.pack\n", .{hex});
        defer allocator.free(line);
        _ = try info_packs.write(line);
    }

    // go-git: fmt.Fprintln(infoPacks) → trailing newline even when empty.
    _ = try info_packs.write("\n");
}

/// Call `objectPacks` whether it returns a plain slice or an error union.
fn callObjectPacks(s: anytype) ![]const Hash {
    const result = s.objectPacks();
    if (comptime @typeInfo(@TypeOf(result)) == .error_union) {
        return try result;
    }
    return result;
}

/// Free non-empty pack lists from `objectPacks`.
///
/// Prefers `s.allocator` when present (filesystem / memory Storage). Falls back
/// to the caller's `allocator` for thin wrappers. Zero-length slices (memory
/// empty packs, static `&.{}`) are never freed.
///
/// `objectPacks` returns `[]const Hash` but ownership of a non-empty heap
/// slice still transfers to the caller (go-git frees the pack list). Cast away
/// const only for that free.
fn freeObjectPacks(allocator: Allocator, s: anytype, packs: []const Hash) void {
    if (packs.len == 0) return;
    const a = if (comptime @hasField(@TypeOf(s.*), "allocator"))
        s.allocator
    else
        allocator;
    a.free(@constCast(packs));
}
