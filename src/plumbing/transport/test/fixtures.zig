//! Shared hermetic fixtures for transport tests (memory repos, endpoints).
//!
//! Import as `transport_test_fixtures` from unit or e2e packages.

const std = @import("std");
const plumbing = @import("plumbing");
const transport = @import("transport");
const memory = @import("memory");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Reference = plumbing.Reference;

pub fn makeEndpoint(allocator: Allocator, url: []const u8) !transport.Endpoint {
    return transport.newEndpoint(allocator, std.testing.io, url);
}

pub fn storeBlob(s: *memory.Storage, content: []const u8) !Hash {
    const obj = try s.newEncodedObject();
    obj.setType(.blob);
    _ = try obj.write(content);
    return s.setEncodedObject(obj);
}

pub fn storeTree(s: *memory.Storage, allocator: Allocator, blob: Hash, name: []const u8) !Hash {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "100644 ");
    try buf.appendSlice(allocator, name);
    try buf.append(allocator, 0);
    try buf.appendSlice(allocator, blob.slice());
    const obj = try s.newEncodedObject();
    obj.setType(.tree);
    _ = try obj.write(buf.items);
    return s.setEncodedObject(obj);
}

pub fn storeCommit(s: *memory.Storage, allocator: Allocator, tree: Hash, msg: []const u8) !Hash {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var tree_hex: [plumbing.MaxHexSize]u8 = undefined;
    try buf.appendSlice(allocator, "tree ");
    try buf.appendSlice(allocator, tree.string(&tree_hex));
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, "author A <a@b> 1 +0000\n");
    try buf.appendSlice(allocator, "committer A <a@b> 1 +0000\n");
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, msg);
    const obj = try s.newEncodedObject();
    obj.setType(.commit);
    _ = try obj.write(buf.items);
    return s.setEncodedObject(obj);
}

/// Blob → tree → commit + `refs/heads/master` + symbolic HEAD.
pub fn populateRepo(s: *memory.Storage, allocator: Allocator) !Hash {
    const blob = try storeBlob(s, "hello");
    const tree = try storeTree(s, allocator, blob, "hello.txt");
    const commit = try storeCommit(s, allocator, tree, "init\n");
    try s.setReference(Reference.newHashReference(plumbing.master, commit));
    try s.setReference(Reference.newSymbolicReference(plumbing.HEAD, plumbing.master));
    return commit;
}

/// Annotated tag object body pointing at `target` (`target_type` e.g. "commit" / "tag").
pub fn storeAnnotatedTag(
    s: *memory.Storage,
    allocator: Allocator,
    target: Hash,
    target_type: []const u8,
    name: []const u8,
) !Hash {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var hex: [plumbing.MaxHexSize]u8 = undefined;
    try buf.appendSlice(allocator, "object ");
    try buf.appendSlice(allocator, target.string(&hex));
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, "type ");
    try buf.appendSlice(allocator, target_type);
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, "tag ");
    try buf.appendSlice(allocator, name);
    try buf.append(allocator, '\n');
    try buf.appendSlice(allocator, "tagger A <a@b> 1 +0000\n\n");
    try buf.appendSlice(allocator, "annotated tag\n");
    const obj = try s.newEncodedObject();
    obj.setType(.tag);
    _ = try obj.write(buf.items);
    return s.setEncodedObject(obj);
}
