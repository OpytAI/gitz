//! Commit-graph chain file parsing — port of go-git
//! `plumbing/format/commitgraph/v2/chain.go` OpenChainFile (v5.19.2).
//!
//! Chain files list graph file hashes (oldest to newest), one hex OID per line.
//! See https://git-scm.com/docs/commit-graph
//!
//! billy.Filesystem-based `OpenChainIndex` / `OpenChainOrFileIndex` are not
//! ported here. Prefer pure helpers:
//! - `openChainFile` — parse chain bytes → hashes
//! - `FileIndex.openWithParent` / `openChainIndexFromBytes` — coalesce graph bytes

const std = @import("std");
const plumbing = @import("plumbing");
const fs_pkg = @import("fs");
const file_mod = @import("file.zig");

const err_mod = @import("error.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Error = err_mod.Error;

/// Read a commit-graph chain file body and return hashes oldest-to-newest
/// (go-git `OpenChainFile`).
///
/// Lines must end with `\n`. Each non-empty line must be a valid full hex hash
/// (`plumbing.isHash`). Malformed lines yield `error.MalformedCommitGraphFile`.
/// Empty input yields an empty slice. Caller frees the returned slice with
/// `allocator.free`.
pub fn openChainFile(allocator: Allocator, data: []const u8) Error![]Hash {
    var list: std.ArrayListUnmanaged(Hash) = .empty;
    errdefer list.deinit(allocator);

    var rest = data;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse {
            // go-git ReadSlice('\n') stops on EOF without a trailing newline —
            // the incomplete final line is ignored.
            break;
        };
        const line = rest[0..nl];
        rest = rest[nl + 1 ..];

        if (!plumbing.isHash(line)) {
            return Error.MalformedCommitGraphFile;
        }
        const h = plumbing.parseHash(line) catch return Error.MalformedCommitGraphFile;
        list.append(allocator, h) catch return Error.MalformedCommitGraphFile;
    }

    return list.toOwnedSlice(allocator) catch return Error.MalformedCommitGraphFile;
}

/// go-git `OpenChainIndex`, monomorphised over the billy-style backend.
pub fn openChainIndexFor(comptime Fs: type, allocator: Allocator, backend: *Fs) anyerror!file_mod.FileIndex {
    const chain_bytes = try readFile(allocator, backend, "objects/info/commit-graphs/commit-graph-chain");
    defer allocator.free(chain_bytes);
    const hashes = try openChainFile(allocator, chain_bytes);
    defer allocator.free(hashes);
    if (hashes.len == 0) return error.MalformedCommitGraphFile;

    var graph_bodies: std.ArrayList([]u8) = .empty;
    defer {
        for (graph_bodies.items) |body| allocator.free(body);
        graph_bodies.deinit(allocator);
    }
    for (hashes) |hash| {
        var hex_buf: [plumbing.MaxHexSize]u8 = undefined;
        const hex = hash.string(&hex_buf);
        const path = try std.fmt.allocPrint(allocator, "objects/info/commit-graphs/graph-{s}.graph", .{hex});
        defer allocator.free(path);
        try graph_bodies.append(allocator, try readFile(allocator, backend, path));
    }
    return file_mod.FileIndex.openChainIndexFromBytes(allocator, graph_bodies.items);
}

/// Prefer the monolithic commit-graph, then fall back to its chain.
pub fn openChainOrFileIndexFor(comptime Fs: type, allocator: Allocator, backend: *Fs) anyerror!file_mod.FileIndex {
    const raw = readFile(allocator, backend, "objects/info/commit-graph") catch {
        return openChainIndexFor(Fs, allocator, backend);
    };
    defer allocator.free(raw);
    return file_mod.FileIndex.open(allocator, raw);
}

fn readFile(allocator: Allocator, backend: anytype, path: []const u8) anyerror![]u8 {
    var file = try backend.open(path);
    defer file.close() catch {};
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
    }
    return out.toOwnedSlice(allocator);
}

test "openChainFile valid hashes" {
    const gpa = std.testing.allocator;
    const body =
        \\c336d16298a017486c4164c40f8acb28afe64e84
        \\31eae7b619d166c366bf5df4991f04ba8cebea0a
        \\
    ;
    const chain = try openChainFile(gpa, body);
    defer gpa.free(chain);
    try std.testing.expectEqual(@as(usize, 2), chain.len);
    var hex0: [plumbing.MaxHexSize]u8 = undefined;
    var hex1: [plumbing.MaxHexSize]u8 = undefined;
    try std.testing.expectEqualStrings(
        "c336d16298a017486c4164c40f8acb28afe64e84",
        chain[0].formatHex(&hex0),
    );
    try std.testing.expectEqualStrings(
        "31eae7b619d166c366bf5df4991f04ba8cebea0a",
        chain[1].formatHex(&hex1),
    );
}

test "filesystem chain helper reports missing chain" {
    const gpa = std.testing.allocator;
    var mem = try fs_pkg.Mem.init(gpa);
    defer mem.deinit();
    try std.testing.expectError(error.NotExist, openChainIndexFor(fs_pkg.Mem, gpa, &mem));
}

test "openChainFile empty" {
    const gpa = std.testing.allocator;
    const chain = try openChainFile(gpa, "");
    defer gpa.free(chain);
    try std.testing.expectEqual(@as(usize, 0), chain.len);
}

test "openChainFile malformed empty lines" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        Error.MalformedCommitGraphFile,
        openChainFile(gpa, "\n\n\n"),
    );
}

test "openChainFile invalid hash" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        Error.MalformedCommitGraphFile,
        openChainFile(gpa, "not-a-valid-git-object-id-hash-here!!\n"),
    );
}

test "openChainFile ignores trailing partial line" {
    const gpa = std.testing.allocator;
    // One complete line + incomplete tail (no final newline) — only complete lines count.
    const body = "c336d16298a017486c4164c40f8acb28afe64e84\npartial";
    const chain = try openChainFile(gpa, body);
    defer gpa.free(chain);
    try std.testing.expectEqual(@as(usize, 1), chain.len);
}
