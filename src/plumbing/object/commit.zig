//! Commit object — port of go-git v5.19.2 `plumbing/object/commit.go` +
//! `commit_scanner.go` (decoder state machine lives in this file).
//!
//! OpenPGP `Verify` uses the pure-Zig verifier in `//src/plumbing/object/openpgp`.

const std = @import("std");
const plumbing = @import("plumbing");
const storer = @import("storer");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const HexSize = plumbing.HexSize;
const MaxHexSize = plumbing.MaxHexSize;
const MemoryObject = plumbing.MemoryObject;
const ObjectType = plumbing.ObjectType;
const ObjectGetter = storer.ObjectGetter;
const EncodedObjectLookupIter = storer.EncodedObjectLookupIter;

fn freeOwned(allocator: Allocator, s: []const u8) void {
    if (s.len > 0) allocator.free(s);
}

const signature_mod = @import("signature.zig");
const error_mod = @import("error.zig");
const openpgp_mod = @import("openpgp");
const tree_mod = @import("tree.zig");
const file_mod = @import("file.zig");
const difftree_mod = @import("difftree.zig");
const patch_mod = @import("patch.zig");
const change_mod = @import("change.zig");

/// Re-export package Signature (go-git `object.Signature`).
pub const Signature = signature_mod.Signature;

const Tree = tree_mod.Tree;
const File = file_mod.File;
const FileIter = tree_mod.FileIter;
const Patch = patch_mod.Patch;
const FileStats = patch_mod.FileStats;

// ---------------------------------------------------------------------------
// Constants / types
// ---------------------------------------------------------------------------

const header_pgp = "gpgsig";
const header_pgp256 = "gpgsig-sha256";
const header_encoding = "encoding";
const header_mergetag = "mergetag";

/// Default commit message encoding (go-git `defaultUtf8CommitMessageEncoding`).
pub const default_utf8_commit_message_encoding: []const u8 = "UTF-8";

/// go-git `MessageEncoding`.
pub const MessageEncoding = []const u8;

/// go-git `ExtraHeader`.
pub const ExtraHeader = struct {
    key: []const u8 = "",
    value: []const u8 = "",

    pub fn deinit(self: *ExtraHeader, allocator: Allocator) void {
        freeOwned(allocator, self.key);
        freeOwned(allocator, self.value);
        self.* = .{};
    }

    /// Write as on-disk header (go-git `ExtraHeader.Format` for `%v` / encode).
    pub fn write(self: ExtraHeader, w: *Writer) Writer.Error!void {
        try w.writeAll(self.key);
        if (self.value.len == 0) return;
        try w.writeAll(" ");
        const value = std.mem.trimEnd(u8, self.value, "\n");
        var first = true;
        var it = std.mem.splitScalar(u8, value, '\n');
        while (it.next()) |line| {
            if (!first) try w.writeAll("\n ");
            first = false;
            try w.writeAll(line);
        }
    }
};

/// Decode / type errors for commit objects.
pub const Error = error{
    /// go-git `ErrUnsupportedObject`.
    UnsupportedObject,
    /// go-git `ErrParentNotFound`.
    ParentNotFound,
    /// go-git `ErrMalformedCommit`.
    MalformedCommit,
    /// go-git `ErrMultipleSignatures`.
    MultipleSignatures,
    /// OpenPGP signature verification failed.
    InvalidSignature,
};

// ---------------------------------------------------------------------------
// Commit
// ---------------------------------------------------------------------------

/// go-git `Commit`.
pub const Commit = struct {
    allocator: Allocator,
    /// Hash of the commit object.
    hash: Hash = ZeroHash,
    author: Signature = .{},
    committer: Signature = .{},
    /// Embedded tag when merging a signed tag (go-git `MergeTag`).
    merge_tag: []const u8 = "",
    /// PGP signature block (go-git `PGPSignature`); not verified here.
    pgp_signature: []const u8 = "",
    message: []const u8 = "",
    tree_hash: Hash = ZeroHash,
    parent_hashes: []Hash = &.{},
    encoding: MessageEncoding = default_utf8_commit_message_encoding,
    extra_headers: []ExtraHeader = &.{},

    /// Object store for Tree/Parent/Parents (type-erased).
    storer: ?ObjectGetter = null,
    /// Source encoded object when populated by Decode (borrowed, not owned).
    src: ?*MemoryObject = null,

    /// Whether `encoding` was heap-allocated (non-default).
    encoding_owned: bool = false,
    /// True when this commit was `allocator.create`d by `getCommit` /
    /// `decodeCommit` / parent loaders. `freeCommit` only destroys when set.
    /// Map/stack test commits stay false.
    heap_owned: bool = false,

    pub fn init(allocator: Allocator) Commit {
        return .{
            .allocator = allocator,
            .encoding = default_utf8_commit_message_encoding,
        };
    }

    pub fn deinit(self: *Commit) void {
        self.author.deinit(self.allocator);
        self.committer.deinit(self.allocator);
        freeOwned(self.allocator, self.merge_tag);
        freeOwned(self.allocator, self.pgp_signature);
        freeOwned(self.allocator, self.message);
        if (self.parent_hashes.len > 0) self.allocator.free(self.parent_hashes);
        if (self.encoding_owned) freeOwned(self.allocator, self.encoding);
        for (self.extra_headers) |*h| h.deinit(self.allocator);
        if (self.extra_headers.len > 0) self.allocator.free(self.extra_headers);
        self.* = undefined;
    }

    fn reset(self: *Commit) void {
        const allocator = self.allocator;
        const s = self.storer;
        const owned = self.heap_owned;
        self.deinit();
        self.* = Commit.init(allocator);
        self.storer = s;
        self.heap_owned = owned;
    }

    /// go-git `Commit.ID`.
    pub fn id(self: *const Commit) Hash {
        return self.hash;
    }

    /// go-git `Commit.Type`.
    pub fn objectType(_: *const Commit) ObjectType {
        return .commit;
    }

    /// go-git `Commit.NumParents`.
    pub fn numParents(self: *const Commit) usize {
        return self.parent_hashes.len;
    }

    /// go-git `Commit.Parent`.
    pub fn parent(self: *const Commit, i: usize) anyerror!*Commit {
        if (self.parent_hashes.len == 0 or i >= self.parent_hashes.len) return error.ParentNotFound;
        const s = self.storer orelse return error.ObjectNotFound;
        return getCommitWithGetter(self.allocator, s, self.parent_hashes[i]);
    }

    /// go-git `Commit.Parents` — iterator over parent commits.
    pub fn parents(self: *const Commit) CommitParentIter {
        return CommitParentIter.init(self);
    }

    /// go-git `Commit.Tree` — load root tree. Caller `freeTree` + destroy ownership
    /// via `tree_mod.freeTree(allocator, t)`.
    pub fn tree(self: *const Commit) anyerror!*Tree {
        const s = self.storer orelse return error.ObjectNotFound;
        return tree_mod.getTree(self.allocator, s, self.tree_hash);
    }

    /// go-git `Commit.File` — file at `path` in this commit's tree.
    pub fn file(self: *const Commit, path: []const u8) anyerror!File {
        const t = try self.tree();
        defer tree_mod.freeTree(self.allocator, t);
        return t.file(path);
    }

    /// go-git `Commit.Files` — recursive file iterator. Owns the root tree;
    /// call `close` (or `forEach`) to free it.
    pub fn files(self: *const Commit) anyerror!FileIter {
        const t = try self.tree();
        errdefer tree_mod.freeTree(self.allocator, t);
        var iter = try t.files();
        iter.owned_root = t;
        return iter;
    }

    /// go-git `Commit.Patch` — diff this commit's tree against `to` (or empty
    /// when `to` is null). Uses default rename detection like go-git 5.1+.
    pub fn patch(self: *const Commit, allocator: Allocator, to: ?*const Commit) anyerror!Patch {
        const from_tree = try self.tree();
        defer tree_mod.freeTree(self.allocator, from_tree);

        var to_tree: ?*Tree = null;
        defer if (to_tree) |tt| tree_mod.freeTree(self.allocator, tt);
        if (to) |other| {
            to_tree = try other.tree();
        }

        var changes = try difftree_mod.diffTreeWithOptions(
            allocator,
            from_tree,
            to_tree,
            change_mod.DiffTreeOptions.default,
        );
        defer changes.deinit();

        return patch_mod.getPatchFromChanges(allocator, "", &changes);
    }

    /// go-git `Commit.Stats` / `StatsContext` — line stats vs first parent, or
    /// vs empty tree when there are no parents.
    ///
    /// Direction matches go-git: `parentTree.Patch(commitTree)` so additions
    /// in this commit appear as inserts.
    pub fn stats(self: *const Commit, allocator: Allocator) anyerror!FileStats {
        const from_tree = try self.tree();
        defer tree_mod.freeTree(self.allocator, from_tree);

        var empty_tree = Tree.init(self.allocator, null);
        defer empty_tree.deinit();

        var parent_tree: ?*Tree = null;
        defer if (parent_tree) |pt| tree_mod.freeTree(self.allocator, pt);

        const to_tree: *Tree = blk: {
            if (self.numParents() == 0) break :blk &empty_tree;
            const first = try self.parent(0);
            defer {
                first.deinit();
                self.allocator.destroy(first);
            }
            parent_tree = try first.tree();
            break :blk parent_tree.?;
        };

        // go-git: toTree.PatchContext(ctx, fromTree) with fromTree=commit, toTree=parent.
        var changes = try difftree_mod.diffTreeWithOptions(
            allocator,
            to_tree,
            from_tree,
            change_mod.DiffTreeOptions.default,
        );
        defer changes.deinit();

        var p = try patch_mod.getPatchFromChanges(allocator, "", &changes);
        defer p.deinit();
        return p.stats();
    }

    /// go-git `Commit.String` — pretty-print like `git log` one-line summary block.
    /// Caller frees the returned slice with `allocator`.
    pub fn format(self: *const Commit, allocator: Allocator) (Allocator.Error || Writer.Error || error{NoSpaceLeft})![]u8 {
        var hex: [MaxHexSize]u8 = undefined;
        var date_buf: [40]u8 = undefined;
        const date = try self.author.formatWhen(&date_buf);

        var aw: Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        const w = &aw.writer;

        try w.print("commit {s}\nAuthor: {s} <{s}>\nDate:   {s}\n\n", .{
            self.hash.string(&hex),
            self.author.name,
            self.author.email,
            date,
        });
        try writeIndentedMessage(w, self.message);
        try w.writeAll("\n");
        return try aw.toOwnedSlice();
    }

    /// go-git `Commit.Decode`.
    pub fn decode(self: *Commit, o: *MemoryObject) (Error || Allocator.Error)!void {
        if (o.object_type != .commit) return error.UnsupportedObject;

        self.reset();
        self.hash = o.hash();
        self.src = o;

        var scanner = CommitScanner{
            .data = o.readerBytes(),
            .commit = self,
        };
        defer scanner.msg_buf.deinit(self.allocator);

        var phase: ScanPhase = .tree;
        while (phase != .done) {
            phase = try stepScanner(&scanner, phase);
        }
        if (!scanner.saw_tree) return error.MalformedCommit;
        self.message = try self.allocator.dupe(u8, scanner.msg_buf.items);
    }

    /// go-git `Commit.Encode` (includes gpgsig when set).
    pub fn encode(self: *const Commit, o: *MemoryObject) (Allocator.Error || Writer.Error)!void {
        return self.encodeInner(o, true);
    }

    /// go-git `Commit.EncodeWithoutSignature`.
    /// Simplified: always re-encodes from struct fields without signature headers.
    pub fn encodeWithoutSignature(self: *const Commit, o: *MemoryObject) (Allocator.Error || Writer.Error)!void {
        return self.encodeInner(o, false);
    }

    fn encodeInner(self: *const Commit, o: *MemoryObject, include_sig: bool) (Allocator.Error || Writer.Error)!void {
        o.setType(.commit);

        var aw: Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;

        var hex: [MaxHexSize]u8 = undefined;
        try w.print("tree {s}\n", .{self.tree_hash.string(&hex)});

        for (self.parent_hashes) |ph| {
            var phex: [MaxHexSize]u8 = undefined;
            try w.print("parent {s}\n", .{ph.string(&phex)});
        }

        try w.writeAll("author ");
        try self.author.encode(w);

        try w.writeAll("\ncommitter ");
        try self.committer.encode(w);

        if (self.merge_tag.len > 0) {
            try w.writeAll("\n");
            try w.writeAll(header_mergetag);
            try w.writeAll(" ");
            try writeContinued(w, self.merge_tag);
        }

        if (self.encoding.len > 0 and !std.mem.eql(u8, self.encoding, default_utf8_commit_message_encoding)) {
            try w.print("\n{s} {s}", .{ header_encoding, self.encoding });
        }

        for (self.extra_headers) |h| {
            if (isStandardHeader(h.key)) continue;
            try w.writeAll("\n");
            try h.write(w);
        }

        if (self.pgp_signature.len > 0 and include_sig) {
            try w.writeAll("\n");
            try w.writeAll(header_pgp);
            try w.writeAll(" ");
            try writeContinued(w, self.pgp_signature);
        }

        try w.print("\n\n{s}", .{self.message});

        try o.setContent(aw.written());
    }

    /// Verifies the detached signature and returns the owned signing entity.
    pub fn verify(self: *const Commit, armored_keyring: []const u8) anyerror!openpgp_mod.Entity {
        if (signature_mod.countSignatureBlocks(self.pgp_signature) > 1) return error.MultipleSignatures;
        if (self.pgp_signature.len == 0) return error.InvalidSignature;

        var encoded = MemoryObject.init(self.allocator);
        defer encoded.deinit();
        try self.encodeWithoutSignature(&encoded);
        const message = encoded.readerBytes();

        const identity = openpgp_mod.checkArmoredDetachedSignature(
            self.allocator,
            armored_keyring,
            message,
            self.pgp_signature,
        ) catch |err| switch (err) {
            error.MultipleSignatures => return error.MultipleSignatures,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSignature,
        };
        return openpgp_mod.entityForFingerprint(self.allocator, armored_keyring, identity.fingerprint);
    }

    /// go-git `Commit.Less`.
    pub fn less(self: *const Commit, rhs: *const Commit) bool {
        if (self.committer.when != rhs.committer.when) {
            return self.committer.when < rhs.committer.when;
        }
        if (self.author.when != rhs.author.when) {
            return self.author.when < rhs.author.when;
        }
        return std.mem.order(u8, &self.hash.bytes, &rhs.hash.bytes) == .lt;
    }
};

fn writeContinued(w: *Writer, text: []const u8) Writer.Error!void {
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    var first = true;
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |line| {
        if (!first) try w.writeAll("\n ");
        first = false;
        try w.writeAll(line);
    }
}

/// go-git `indent` for `Commit.String` — 4 spaces before each non-empty line.
fn writeIndentedMessage(w: *Writer, message: []const u8) Writer.Error!void {
    var first = true;
    var it = std.mem.splitScalar(u8, message, '\n');
    while (it.next()) |line| {
        if (!first) try w.writeAll("\n");
        first = false;
        if (line.len != 0) {
            try w.writeAll("    ");
            try w.writeAll(line);
        }
    }
}

fn isStandardHeader(key: []const u8) bool {
    return std.mem.eql(u8, key, "tree") or
        std.mem.eql(u8, key, "parent") or
        std.mem.eql(u8, key, "author") or
        std.mem.eql(u8, key, "committer") or
        std.mem.eql(u8, key, header_encoding) or
        std.mem.eql(u8, key, header_mergetag) or
        std.mem.eql(u8, key, header_pgp) or
        std.mem.eql(u8, key, header_pgp256);
}

// ---------------------------------------------------------------------------
// getCommit / decodeCommit
// ---------------------------------------------------------------------------

/// Free a heap commit from `getCommit` / walker yield when `heap_owned`.
/// No-op when `heap_owned == false` (stack/map test tips).
/// Signature mirrors `freeTree(allocator, t)`.
pub fn freeCommit(allocator: Allocator, c: *Commit) void {
    if (!c.heap_owned) return;
    std.debug.assert(allocator.ptr == c.allocator.ptr);
    c.deinit();
    allocator.destroy(c);
}

/// go-git `GetCommit`.
pub fn getCommit(allocator: Allocator, s: anytype, h: Hash) !*Commit {
    const o = try s.encodedObject(ObjectType.commit, h);
    return decodeCommit(allocator, s, o);
}

/// go-git `DecodeCommit`.
pub fn decodeCommit(allocator: Allocator, s: anytype, o: *MemoryObject) !*Commit {
    const c = try allocator.create(Commit);
    errdefer {
        c.deinit();
        allocator.destroy(c);
    }
    c.* = Commit.init(allocator);
    c.heap_owned = true;
    c.storer = ObjectGetter.from(@TypeOf(s.*), s);
    try c.decode(o);
    return c;
}

/// Free a heap commit from `getCommit` / walker yield when `heap_owned`.
/// No-op when `heap_owned == false` (stack/map test tips).
/// Signature mirrors `freeTree(allocator, t)`.
pub fn freeCommit(allocator: Allocator, c: *Commit) void {
    if (!c.heap_owned) return;
    c.deinit();
    allocator.destroy(c);
}

fn getCommitWithGetter(allocator: Allocator, s: ObjectGetter, h: Hash) !*Commit {
    const o = try s.encodedObject(.commit, h);
    const c = try allocator.create(Commit);
    errdefer {
        c.deinit();
        allocator.destroy(c);
    }
    c.* = Commit.init(allocator);
    c.heap_owned = true;
    c.storer = s;
    try c.decode(o);
    return c;
}

// ---------------------------------------------------------------------------
// Parent iterator (go-git Commit.Parents / storerCommitIter subset)
// ---------------------------------------------------------------------------

/// Iterator over a commit's parents (go-git `Commit.Parents`).
pub const CommitParentIter = struct {
    commit: *const Commit,
    pos: usize = 0,

    pub fn init(c: *const Commit) CommitParentIter {
        return .{ .commit = c };
    }

    pub fn next(self: *CommitParentIter) !*Commit {
        if (self.pos >= self.commit.parent_hashes.len) return error.EndOfStream;
        const h = self.commit.parent_hashes[self.pos];
        self.pos += 1;
        const s = self.commit.storer orelse return error.ObjectNotFound;
        return getCommitWithGetter(self.commit.allocator, s, h);
    }

    pub fn forEach(self: *CommitParentIter, cb: anytype) !void {
        while (true) {
            const c = self.next() catch |err| switch (err) {
                error.EndOfStream => return,
                else => |e| return e,
            };
            defer freeCommit(self.commit.allocator, c);
            try cb(c);
        }
    }

    pub fn close(self: *CommitParentIter) void {
        self.pos = self.commit.parent_hashes.len;
    }
};

/// go-git `NewCommitIter` — decode each encoded object as a commit.
pub const StorerCommitIter = struct {
    allocator: Allocator,
    storer: ObjectGetter,
    inner: EncodedObjectLookupIter,

    pub fn init(allocator: Allocator, s: ObjectGetter, series: []const Hash) StorerCommitIter {
        return .{
            .allocator = allocator,
            .storer = s,
            .inner = EncodedObjectLookupIter.init(s, .commit, series),
        };
    }

    pub fn next(self: *StorerCommitIter) !*Commit {
        const obj = try self.inner.next();
        return getCommitWithGetter(self.allocator, self.storer, obj.hash());
    }

    pub fn close(self: *StorerCommitIter) void {
        self.inner.close();
    }
};

pub fn newCommitIter(allocator: Allocator, s: ObjectGetter, series: []const Hash) StorerCommitIter {
    return StorerCommitIter.init(allocator, s, series);
}

// ---------------------------------------------------------------------------
// Decoder state machine (go-git commit_scanner.go)
// ---------------------------------------------------------------------------

const ScanPhase = enum {
    tree,
    parents,
    author,
    committer,
    headers,
    mergetag_cont,
    pgp_cont,
    skip_cont,
    extra_cont,
    message,
    done,
};


const CommitScanner = struct {
    data: []const u8,
    offset: usize = 0,
    commit: *Commit,
    msg_buf: std.ArrayList(u8) = .empty,

    pending: ?[]const u8 = null,
    pending_eof: bool = false,

    saw_tree: bool = false,
    saw_author: bool = false,
    saw_committer: bool = false,
    saw_encoding: bool = false,
    saw_mergetag: bool = false,

    extra: ?ExtraHeader = null,

    fn readLine(self: *CommitScanner) struct { []const u8, bool } {
        if (self.pending) |line| {
            const eof = self.pending_eof;
            self.pending = null;
            self.pending_eof = false;
            return .{ line, eof };
        }
        if (self.offset >= self.data.len) return .{ "", true };

        const start = self.offset;
        while (self.offset < self.data.len and self.data[self.offset] != '\n') {
            self.offset += 1;
        }
        var end = self.offset;
        var eof = self.offset >= self.data.len;
        if (self.offset < self.data.len and self.data[self.offset] == '\n') {
            end = self.offset + 1; // include newline in line (go-git ReadBytes)
            self.offset += 1;
            eof = self.offset >= self.data.len;
        }
        return .{ self.data[start..end], eof };
    }

    fn pushBack(self: *CommitScanner, line: []const u8, eof: bool) void {
        self.pending = line;
        self.pending_eof = eof;
    }
};

fn appendExtra(c: *Commit, h: ExtraHeader) Allocator.Error!void {
    const new_len = c.extra_headers.len + 1;
    if (c.extra_headers.len == 0) {
        const slice = try c.allocator.alloc(ExtraHeader, 1);
        slice[0] = h;
        c.extra_headers = slice;
        return;
    }
    const new_slice = try c.allocator.realloc(c.extra_headers, new_len);
    new_slice[new_len - 1] = h;
    c.extra_headers = new_slice;
}

fn appendParent(c: *Commit, h: Hash) Allocator.Error!void {
    const new_len = c.parent_hashes.len + 1;
    if (c.parent_hashes.len == 0) {
        const slice = try c.allocator.alloc(Hash, 1);
        slice[0] = h;
        c.parent_hashes = slice;
        return;
    }
    const new_slice = try c.allocator.realloc(c.parent_hashes, new_len);
    new_slice[new_len - 1] = h;
    c.parent_hashes = new_slice;
}

fn isBlankLine(line: []const u8) bool {
    return line.len == 1 and line[0] == '\n';
}

fn splitHeader(line: []const u8) struct { []const u8, []const u8 } {
    const trimmed = std.mem.trimEnd(u8, line, "\n");
    if (std.mem.indexOfScalar(u8, trimmed, ' ')) |sp| {
        return .{ trimmed[0..sp], trimmed[sp + 1 ..] };
    }
    return .{ trimmed, "" };
}

fn parseObjectIdHex(data: []const u8) Error!Hash {
    if (!plumbing.isHash(data)) return error.MalformedCommit;
    return plumbing.newHash(data);
}

fn parseExtraHeaderLine(line: []const u8) struct { ExtraHeader, bool } {
    const trimmed = std.mem.trimEnd(u8, line, "\n");
    if (std.mem.indexOfScalar(u8, trimmed, ' ')) |sp| {
        return .{
            .{
                .key = trimmed[0..sp],
                .value = trimmed[sp + 1 ..],
            },
            true,
        };
    }
    return .{
        .{
            .key = trimmed,
            .value = "",
        },
        false,
    };
}


fn stepScanner(s: *CommitScanner, phase: ScanPhase) (Error || Allocator.Error)!ScanPhase {
    return switch (phase) {
        .tree => scanTree(s),
        .parents => scanParents(s),
        .author => scanAuthor(s),
        .committer => scanCommitter(s),
        .headers => scanHeaders(s),
        .mergetag_cont => scanMergetagCont(s),
        .pgp_cont => scanPgpCont(s),
        .skip_cont => scanSkipCont(s),
        .extra_cont => scanExtraCont(s),
        .message => scanMessage(s),
        .done => .done,
    };
}

fn scanTree(s: *CommitScanner) (Error || Allocator.Error)!ScanPhase {
    const line, const eof = s.readLine();
    if (line.len == 0 or isBlankLine(line)) return error.MalformedCommit;

    const key, const data = splitHeader(line);
    if (!std.mem.eql(u8, key, "tree")) return error.MalformedCommit;
    s.commit.tree_hash = try parseObjectIdHex(data);
    s.saw_tree = true;
    if (eof) return .done;
    return .parents;
}

fn scanParents(s: *CommitScanner) (Error || Allocator.Error)!ScanPhase {
    const line, const eof = s.readLine();
    if (line.len == 0) return .done;
    if (isBlankLine(line)) return .message;

    const key, const data = splitHeader(line);
    if (std.mem.eql(u8, key, "parent")) {
        const h = try parseObjectIdHex(data);
        try appendParent(s.commit, h);
        if (eof) return .done;
        return .parents;
    }
    s.pushBack(line, eof);
    return .author;
}

fn scanAuthor(s: *CommitScanner) (Error || Allocator.Error)!ScanPhase {
    const line, const eof = s.readLine();
    if (line.len == 0) return .done;
    if (isBlankLine(line)) return .message;

    const key, const data = splitHeader(line);
    if (std.mem.eql(u8, key, "author")) {
        try s.commit.author.decodeOwned(s.commit.allocator, data);
        s.saw_author = true;
        if (eof) return .done;
        return .committer;
    }
    s.pushBack(line, eof);
    return .committer;
}

fn scanCommitter(s: *CommitScanner) (Error || Allocator.Error)!ScanPhase {
    const line, const eof = s.readLine();
    if (line.len == 0) return .done;
    if (isBlankLine(line)) return .message;

    const key, const data = splitHeader(line);
    if (std.mem.eql(u8, key, "committer")) {
        try s.commit.committer.decodeOwned(s.commit.allocator, data);
        s.saw_committer = true;
        if (eof) return .done;
        return .headers;
    }
    s.pushBack(line, eof);
    return .headers;
}

fn scanHeaders(s: *CommitScanner) (Error || Allocator.Error)!ScanPhase {
    const line, const eof = s.readLine();
    if (line.len == 0) return .done;
    if (isBlankLine(line)) return .message;

    const key, const data = splitHeader(line);
    var next: ScanPhase = .headers;

    if (std.mem.eql(u8, key, "tree") or
        std.mem.eql(u8, key, "parent") or
        std.mem.eql(u8, key, "author") or
        std.mem.eql(u8, key, "committer"))
    {
        // Out-of-order standard headers: drop (go-git).
    } else if (std.mem.eql(u8, key, header_encoding)) {
        if (!s.saw_encoding) {
            s.commit.encoding = try s.commit.allocator.dupe(u8, data);
            s.commit.encoding_owned = true;
            s.saw_encoding = true;
        }
    } else if (std.mem.eql(u8, key, header_mergetag)) {
        if (s.saw_mergetag) {
            next = .skip_cont;
        } else {
            try appendOwnedString(s.commit.allocator, &s.commit.merge_tag, data);
            try appendOwnedString(s.commit.allocator, &s.commit.merge_tag, "\n");
            s.saw_mergetag = true;
            next = .mergetag_cont;
        }
    } else if (std.mem.eql(u8, key, header_pgp)) {
        try appendOwnedString(s.commit.allocator, &s.commit.pgp_signature, data);
        try appendOwnedString(s.commit.allocator, &s.commit.pgp_signature, "\n");
        next = .pgp_cont;
    } else if (std.mem.eql(u8, key, header_pgp256)) {
        next = .skip_cont;
    } else {
        const parsed, const multiline = parseExtraHeaderLine(line);
        if (multiline) {
            const key_owned = try s.commit.allocator.dupe(u8, parsed.key);
            errdefer s.commit.allocator.free(key_owned);
            const val_owned = try s.commit.allocator.dupe(u8, parsed.value);
            s.extra = .{ .key = key_owned, .value = val_owned };
            next = .extra_cont;
        } else {
            const key_owned = try s.commit.allocator.dupe(u8, parsed.key);
            errdefer s.commit.allocator.free(key_owned);
            try appendExtra(s.commit, .{ .key = key_owned, .value = "" });
        }
    }

    if (eof) return .done;
    return next;
}

fn appendOwnedString(allocator: Allocator, dst: *[]const u8, more: []const u8) Allocator.Error!void {
    if (more.len == 0) return;
    const old = dst.*;
    const new_len = old.len + more.len;
    const buf = try allocator.alloc(u8, new_len);
    if (old.len > 0) {
        @memcpy(buf[0..old.len], old);
        allocator.free(old);
    }
    @memcpy(buf[old.len..], more);
    dst.* = buf;
}

fn continuationCont(
    s: *CommitScanner,
    dst: *[]const u8,
    self_state: ScanPhase,
) (Error || Allocator.Error)!ScanPhase {
    const line, const eof = s.readLine();
    if (line.len > 0 and line[0] == ' ') {
        try appendOwnedString(s.commit.allocator, dst, line[1..]);
        if (eof) return .done;
        return self_state;
    }
    if (line.len > 0) s.pushBack(line, eof);
    return .headers;
}

fn scanMergetagCont(s: *CommitScanner) (Error || Allocator.Error)!ScanPhase {
    return continuationCont(s, &s.commit.merge_tag, .mergetag_cont);
}

fn scanPgpCont(s: *CommitScanner) (Error || Allocator.Error)!ScanPhase {
    return continuationCont(s, &s.commit.pgp_signature, .pgp_cont);
}

fn scanSkipCont(s: *CommitScanner) (Error || Allocator.Error)!ScanPhase {
    const line, const eof = s.readLine();
    if (line.len > 0 and line[0] == ' ') {
        if (eof) return .done;
        return .skip_cont;
    }
    if (line.len > 0) s.pushBack(line, eof);
    return .headers;
}

fn scanExtraCont(s: *CommitScanner) (Error || Allocator.Error)!ScanPhase {
    const line, const eof = s.readLine();
    if (line.len > 0 and line[0] == ' ') {
        var h = s.extra orelse return error.MalformedCommit;
        try appendOwnedString(s.commit.allocator, &h.value, line[1..]);
        s.extra = h;
        if (eof) {
            try finaliseExtraScanner(s);
            return .done;
        }
        return .extra_cont;
    }
    try finaliseExtraScanner(s);
    if (line.len > 0) s.pushBack(line, eof);
    return .headers;
}

fn finaliseExtraScanner(s: *CommitScanner) Allocator.Error!void {
    var h = s.extra orelse return;
    s.extra = null;
    // Trim trailing newlines on value (go-git TrimRight \n).
    const trimmed = std.mem.trimEnd(u8, h.value, "\n");
    if (trimmed.len != h.value.len) {
        const new_val = try s.commit.allocator.dupe(u8, trimmed);
        s.commit.allocator.free(h.value);
        h.value = new_val;
    }
    try appendExtra(s.commit, h);
}

fn scanMessage(s: *CommitScanner) (Error || Allocator.Error)!ScanPhase {
    while (true) {
        const line, const eof = s.readLine();
        if (line.len > 0) {
            try s.msg_buf.appendSlice(s.commit.allocator, line);
        }
        if (eof) return .done;
    }
}

// ---------------------------------------------------------------------------
// Tests — empty-tree commit fixture round-trip
// ---------------------------------------------------------------------------

/// Empty tree OID (git empty tree).
const empty_tree_hex = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

const empty_tree_commit_raw =
    \\tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904
    \\author John Doe <john.doe@example.com> 1755280730 -0700
    \\committer John Doe <john.doe@example.com> 1755280730 -0700
    \\
    \\initial commit
;

test "empty-tree commit decode encode round-trip" {
    const gpa = std.testing.allocator;

    var src = MemoryObject.init(gpa);
    defer src.deinit();
    src.setType(.commit);
    try src.setContent(empty_tree_commit_raw);

    var commit = Commit.init(gpa);
    defer commit.deinit();
    try commit.decode(&src);

    try std.testing.expect(commit.tree_hash.eql(plumbing.newHash(empty_tree_hex)));
    try std.testing.expectEqualStrings("John Doe", commit.author.name);
    try std.testing.expectEqualStrings("john.doe@example.com", commit.author.email);
    try std.testing.expectEqual(@as(i64, 1755280730), commit.author.when);
    try std.testing.expectEqual(@as(i16, -7 * 60), commit.author.tz_offset_minutes);
    try std.testing.expectEqualStrings("John Doe", commit.committer.name);
    try std.testing.expectEqualStrings("initial commit", commit.message);
    try std.testing.expectEqual(@as(usize, 0), commit.numParents());
    try std.testing.expectEqual(ObjectType.commit, commit.objectType());
    try std.testing.expect(commit.hash.eql(src.hash()));

    var encoded = MemoryObject.init(gpa);
    defer encoded.deinit();
    try commit.encode(&encoded);

    try std.testing.expectEqualStrings(empty_tree_commit_raw, encoded.readerBytes());

    var again = Commit.init(gpa);
    defer again.deinit();
    try again.decode(&encoded);
    try std.testing.expect(again.tree_hash.eql(commit.tree_hash));
    try std.testing.expectEqualStrings(commit.message, again.message);
    try std.testing.expect(Signature.eql(commit.author, again.author));
    try std.testing.expect(Signature.eql(commit.committer, again.committer));
}

test "commit gpgsig decode encode preserves signature" {
    const gpa = std.testing.allocator;
    const raw =
        \\tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904
        \\author John Doe <john.doe@example.com> 1755280730 -0700
        \\committer John Doe <john.doe@example.com> 1755280730 -0700
        \\gpgsig -----BEGIN PGP SIGNATURE-----
        \\ sigline1
        \\ -----END PGP SIGNATURE-----
        \\
        \\initial commit
    ;

    var src = MemoryObject.init(gpa);
    defer src.deinit();
    src.setType(.commit);
    try src.setContent(raw);

    var commit = Commit.init(gpa);
    defer commit.deinit();
    try commit.decode(&src);

    try std.testing.expect(std.mem.indexOf(u8, commit.pgp_signature, "BEGIN PGP SIGNATURE") != null);
    try std.testing.expect(std.mem.indexOf(u8, commit.pgp_signature, "sigline1") != null);

    var encoded = MemoryObject.init(gpa);
    defer encoded.deinit();
    try commit.encode(&encoded);

    var again = Commit.init(gpa);
    defer again.deinit();
    try again.decode(&encoded);
    try std.testing.expectEqualStrings(commit.pgp_signature, again.pgp_signature);

    try std.testing.expectError(error.InvalidSignature, commit.verify("dummy-keyring"));
}

test "commit encode without signature strips gpgsig" {
    const gpa = std.testing.allocator;
    const raw =
        \\tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904
        \\author John Doe <john.doe@example.com> 1755280730 -0700
        \\committer John Doe <john.doe@example.com> 1755280730 -0700
        \\gpgsig -----BEGIN PGP SIGNATURE-----
        \\ sigline1
        \\ -----END PGP SIGNATURE-----
        \\
        \\initial commit
    ;

    var src = MemoryObject.init(gpa);
    defer src.deinit();
    src.setType(.commit);
    try src.setContent(raw);

    var commit = Commit.init(gpa);
    defer commit.deinit();
    try commit.decode(&src);

    var encoded = MemoryObject.init(gpa);
    defer encoded.deinit();
    try commit.encodeWithoutSignature(&encoded);

    const body = encoded.readerBytes();
    try std.testing.expect(std.mem.indexOf(u8, body, "gpgsig") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "initial commit") != null);
}

test "commit decode non-commit is UnsupportedObject" {
    const gpa = std.testing.allocator;
    var blob = MemoryObject.init(gpa);
    defer blob.deinit();
    blob.setType(.blob);
    try blob.setContent("hi");

    var commit = Commit.init(gpa);
    defer commit.deinit();
    try std.testing.expectError(error.UnsupportedObject, commit.decode(&blob));
}

test "commit malformed missing tree" {
    const gpa = std.testing.allocator;
    var src = MemoryObject.init(gpa);
    defer src.deinit();
    src.setType(.commit);
    try src.setContent("parent deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n");

    var commit = Commit.init(gpa);
    defer commit.deinit();
    try std.testing.expectError(error.MalformedCommit, commit.decode(&src));
}

test "commit parent not found without parents" {
    const gpa = std.testing.allocator;
    var commit = Commit.init(gpa);
    defer commit.deinit();
    try std.testing.expectError(error.ParentNotFound, commit.parent(0));
}

test "commit with parent hashes and storage getCommit" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");

    var store = memory.Storage.init(gpa);
    defer store.deinit();

    // Store empty-tree commit as a root, then a child with one parent.
    var root_obj = try store.newEncodedObject();
    root_obj.setType(.commit);
    try root_obj.setContent(empty_tree_commit_raw);
    const root_hash = try store.setEncodedObject(root_obj);

    var root_hex_buf: [MaxHexSize]u8 = undefined;
    const root_hex = root_hash.string(&root_hex_buf);

    // Build child commit text with parent = root.
    var child_body: Writer.Allocating = .init(gpa);
    defer child_body.deinit();
    try child_body.writer.print(
        \\tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904
        \\parent {s}
        \\author Jane Doe <jane@example.com> 1755280800 +0000
        \\committer Jane Doe <jane@example.com> 1755280800 +0000
        \\
        \\child
    , .{root_hex});

    var child_obj = try store.newEncodedObject();
    child_obj.setType(.commit);
    try child_obj.setContent(child_body.written());
    const child_hash = try store.setEncodedObject(child_obj);

    const child = try getCommit(gpa, &store, child_hash);
    defer {
        child.deinit();
        gpa.destroy(child);
    }

    try std.testing.expectEqual(@as(usize, 1), child.numParents());
    try std.testing.expect(child.parent_hashes[0].eql(root_hash));
    try std.testing.expectEqualStrings("child", child.message);

    const parent_c = try child.parent(0);
    defer {
        parent_c.deinit();
        gpa.destroy(parent_c);
    }
    try std.testing.expectEqualStrings("initial commit", parent_c.message);
    try std.testing.expect(parent_c.hash.eql(root_hash));
}

test "commit decode clears existing state" {
    const gpa = std.testing.allocator;
    var commit = Commit.init(gpa);
    defer commit.deinit();

    commit.message = try gpa.dupe(u8, "stale");
    commit.pgp_signature = try gpa.dupe(u8, "stale-sig");
    commit.merge_tag = try gpa.dupe(u8, "stale-tag");
    try appendParent(&commit, plumbing.newHash("3333333333333333333333333333333333333333"));

    var src = MemoryObject.init(gpa);
    defer src.deinit();
    src.setType(.commit);
    try src.setContent(empty_tree_commit_raw);

    try commit.decode(&src);
    try std.testing.expectEqualStrings("initial commit", commit.message);
    try std.testing.expectEqualStrings("", commit.pgp_signature);
    try std.testing.expectEqualStrings("", commit.merge_tag);
    try std.testing.expectEqual(@as(usize, 0), commit.parent_hashes.len);
}

test "commit construct and encode with multi-parent" {
    const gpa = std.testing.allocator;
    var commit = Commit.init(gpa);
    defer commit.deinit();

    commit.tree_hash = plumbing.newHash(empty_tree_hex);
    commit.author = .{
        .name = try gpa.dupe(u8, "Foo"),
        .email = try gpa.dupe(u8, "foo@example.local"),
        .when = 1136239445,
        .tz_offset_minutes = -7 * 60,
        .owned = true,
    };
    commit.committer = .{
        .name = try gpa.dupe(u8, "Bar"),
        .email = try gpa.dupe(u8, "bar@example.local"),
        .when = 1136239445,
        .tz_offset_minutes = -7 * 60,
        .owned = true,
    };
    commit.message = try gpa.dupe(u8, "Message\n");
    const parents_arr = try gpa.alloc(Hash, 2);
    parents_arr[0] = plumbing.newHash("f000000000000000000000000000000000000004");
    parents_arr[1] = plumbing.newHash("f000000000000000000000000000000000000005");
    commit.parent_hashes = parents_arr;

    var encoded = MemoryObject.init(gpa);
    defer encoded.deinit();
    try commit.encode(&encoded);

    var decoded = Commit.init(gpa);
    defer decoded.deinit();
    try decoded.decode(&encoded);

    try std.testing.expectEqual(@as(usize, 2), decoded.numParents());
    try std.testing.expectEqualStrings("Foo", decoded.author.name);
    try std.testing.expectEqualStrings("Bar", decoded.committer.name);
    try std.testing.expectEqualStrings("Message\n", decoded.message);
}

test "commit.file via memory store with tree" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");
    const filemode = @import("filemode");

    var store = memory.Storage.init(gpa);
    defer store.deinit();

    const blob_obj = try store.newEncodedObject();
    blob_obj.setType(.blob);
    try blob_obj.setContent("hello-content");
    const blob_h = try store.setEncodedObject(blob_obj);

    var tree = tree_mod.Tree.init(gpa, ObjectGetter.from(@TypeOf(store), &store));
    defer tree.deinit();
    try tree.appendEntry("hello.txt", filemode.Regular, blob_h);
    tree.sortEntries();
    const tree_obj = try store.newEncodedObject();
    try tree.encode(tree_obj);
    const tree_h = try store.setEncodedObject(tree_obj);

    var hex: [MaxHexSize]u8 = undefined;
    var body: Writer.Allocating = .init(gpa);
    defer body.deinit();
    try body.writer.print(
        \\tree {s}
        \\author John Doe <john.doe@example.com> 1755280730 -0700
        \\committer John Doe <john.doe@example.com> 1755280730 -0700
        \\
        \\with file
    , .{tree_h.string(&hex)});

    var commit_obj = try store.newEncodedObject();
    commit_obj.setType(.commit);
    try commit_obj.setContent(body.written());
    const commit_h = try store.setEncodedObject(commit_obj);

    const c = try getCommit(gpa, &store, commit_h);
    defer {
        c.deinit();
        gpa.destroy(c);
    }

    const f = try c.file("hello.txt");
    try std.testing.expectEqualStrings("hello.txt", f.name);
    try std.testing.expectEqualStrings("hello-content", f.blob.readerBytes());
    try std.testing.expectError(error.FileNotFound, c.file("missing.txt"));
}

test "commit.patch insert between empty and file tree" {
    const gpa = std.testing.allocator;
    const memory = @import("memory");
    const filemode = @import("filemode");

    var store = memory.Storage.init(gpa);
    defer store.deinit();
    const getter = ObjectGetter.from(@TypeOf(store), &store);

    // Empty tree commit.
    var empty_tree = tree_mod.Tree.init(gpa, getter);
    defer empty_tree.deinit();
    empty_tree.sortEntries();
    const empty_tree_obj = try store.newEncodedObject();
    try empty_tree.encode(empty_tree_obj);
    const empty_tree_h = try store.setEncodedObject(empty_tree_obj);

    var empty_hex: [MaxHexSize]u8 = undefined;
    var empty_body: Writer.Allocating = .init(gpa);
    defer empty_body.deinit();
    try empty_body.writer.print(
        \\tree {s}
        \\author A <a@e> 1000 +0000
        \\committer A <a@e> 1000 +0000
        \\
        \\empty
    , .{empty_tree_h.string(&empty_hex)});
    var empty_commit_obj = try store.newEncodedObject();
    empty_commit_obj.setType(.commit);
    try empty_commit_obj.setContent(empty_body.written());
    const empty_commit_h = try store.setEncodedObject(empty_commit_obj);

    // Commit with one file.
    const blob_obj = try store.newEncodedObject();
    blob_obj.setType(.blob);
    try blob_obj.setContent("line1\n");
    const blob_h = try store.setEncodedObject(blob_obj);

    var file_tree = tree_mod.Tree.init(gpa, getter);
    defer file_tree.deinit();
    try file_tree.appendEntry("new.txt", filemode.Regular, blob_h);
    file_tree.sortEntries();
    const file_tree_obj = try store.newEncodedObject();
    try file_tree.encode(file_tree_obj);
    const file_tree_h = try store.setEncodedObject(file_tree_obj);

    var file_hex: [MaxHexSize]u8 = undefined;
    var file_body: Writer.Allocating = .init(gpa);
    defer file_body.deinit();
    try file_body.writer.print(
        \\tree {s}
        \\author A <a@e> 2000 +0000
        \\committer A <a@e> 2000 +0000
        \\
        \\add file
    , .{file_tree_h.string(&file_hex)});
    var file_commit_obj = try store.newEncodedObject();
    file_commit_obj.setType(.commit);
    try file_commit_obj.setContent(file_body.written());
    const file_commit_h = try store.setEncodedObject(file_commit_obj);

    const empty_c = try getCommit(gpa, &store, empty_commit_h);
    defer {
        empty_c.deinit();
        gpa.destroy(empty_c);
    }
    const file_c = try getCommit(gpa, &store, file_commit_h);
    defer {
        file_c.deinit();
        gpa.destroy(file_c);
    }

    // Diff empty → file tree: insert.
    var p = try empty_c.patch(gpa, file_c);
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, 1), p.file_patches.len);
    try std.testing.expect(p.file_patches[0].from.empty());
    try std.testing.expect(!p.file_patches[0].to.empty());
    try std.testing.expectEqualStrings("new.txt", p.file_patches[0].to.path);

    const s = try p.string();
    defer gpa.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "new file mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "+line1") != null);
}

test "commit.format contains author and indented message" {
    const gpa = std.testing.allocator;
    var commit = Commit.init(gpa);
    defer commit.deinit();
    commit.hash = plumbing.newHash("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    commit.author = .{
        .name = try gpa.dupe(u8, "John Doe"),
        .email = try gpa.dupe(u8, "john.doe@example.com"),
        .when = 1755280730,
        .tz_offset_minutes = -7 * 60,
        .owned = true,
    };
    commit.message = try gpa.dupe(u8, "initial commit");

    const text = try commit.format(gpa);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "commit aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Author: John Doe <john.doe@example.com>") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "    initial commit") != null);
}

// go-git SuiteCommit.TestVerify fixture (Ed25519 key + detached sig).
test "commit Verify go-git TestVerify fixture" {
    const gpa = std.testing.allocator;

    var commit = Commit.init(gpa);
    defer commit.deinit();
    commit.hash = plumbing.newHash("1eca38290a3131d0c90709496a9b2207a872631e");
    commit.tree_hash = plumbing.newHash("52a266a58f2c028ad7de4dfd3a72fdf76b0d4e24");
    commit.author = .{
        .name = try gpa.dupe(u8, "go-git"),
        .email = try gpa.dupe(u8, "go-git@example.com"),
        .when = 1617402711,
        .tz_offset_minutes = 0,
        .owned = true,
    };
    commit.committer = .{
        .name = try gpa.dupe(u8, "go-git"),
        .email = try gpa.dupe(u8, "go-git@example.com"),
        .when = 1617402711,
        .tz_offset_minutes = 0,
        .owned = true,
    };
    commit.message = try gpa.dupe(u8, "test\n");
    const parents = try gpa.alloc(Hash, 1);
    parents[0] = plumbing.newHash("e4fbb611cd14149c7a78e9c08425f59f4b736a9a");
    commit.parent_hashes = parents;
    commit.pgp_signature = try gpa.dupe(u8,
        \\
        \\-----BEGIN PGP SIGNATURE-----
        \\
        \\iHUEABYKAB0WIQTMqU0ycQ3f6g3PMoWMmmmF4LuV8QUCYGebVwAKCRCMmmmF4LuV
        \\8VtyAP9LbuXAhtK6FQqOjKybBwlV70rLcXVP24ubDuz88VVwSgD+LuObsasWq6/U
        \\TssDKHUR2taa53bQYjkZQBpvvwOrLgc=
        \\=YQUf
        \\-----END PGP SIGNATURE-----
        \\
    );

    const armored_keyring =
        \\
        \\-----BEGIN PGP PUBLIC KEY BLOCK-----
        \\
        \\mDMEYGeSihYJKwYBBAHaRw8BAQdAIs9A3YD/EghhAOkHDkxlUkpqYrXUXebLfmmX
        \\+pdEK6C0D2dvLWdpdCB0ZXN0IGtleYiPBBMWCgA3FiEEzKlNMnEN3+oNzzKFjJpp
        \\heC7lfEFAmBnkooCGyMECwkIBwUVCgkICwUWAwIBAAIeAQIXgAAKCRCMmmmF4LuV
        \\8a3jAQCi4hSqjj6J3ch290FvQaYPGwR+EMQTMBG54t+NN6sDfgD/aZy41+0dnFKl
        \\qM/wLW5Wr9XvwH+1zXXbuSvfxasHowq4OARgZ5KKEgorBgEEAZdVAQUBAQdAXoQz
        \\VTYug16SisAoSrxFnOmxmFu6efYgCAwXu0ZuvzsDAQgHiHgEGBYKACAWIQTMqU0y
        \\cQ3f6g3PMoWMmmmF4LuV8QUCYGeSigIbDAAKCRCMmmmF4LuV8Q4QAQCKW5FnEdWW
        \\lHYKeByw3JugnlZ0U3V/R20bCwDglst5UQEAtkN2iZkHtkPly9xapsfNqnrt2gTt
        \\YIefGtzXfldDxg4=
        \\=Psht
        \\-----END PGP PUBLIC KEY BLOCK-----
        \\
    ;

    var entity = try commit.verify(armored_keyring);
    defer entity.deinit();
    try std.testing.expect(!std.mem.allEqual(u8, &entity.primary.fingerprint, 0));
}
