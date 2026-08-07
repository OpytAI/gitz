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
    var hex0: [plumbing.HexSize]u8 = undefined;
    var hex1: [plumbing.HexSize]u8 = undefined;
    try std.testing.expectEqualStrings(
        "c336d16298a017486c4164c40f8acb28afe64e84",
        chain[0].formatHex(&hex0),
    );
    try std.testing.expectEqualStrings(
        "31eae7b619d166c366bf5df4991f04ba8cebea0a",
        chain[1].formatHex(&hex1),
    );
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
