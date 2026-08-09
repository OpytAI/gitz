//! Annotated tag object (go-git `plumbing/object/tag.go` + `tag_scanner.go`).
//!
//! Lightweight tags are plain refs and are not represented here.
//!
//! Pin: go-git v5.19.2.
//!
//! # go-git test map
//!
//! | go-git | Zig |
//! |--------|-----|
//! | TestTagEncodeDecodeIdempotent | `Tag encode/decode round-trip` |
//! | TestTagEncodeOmitsZeroTagger | `Tag encode omits zero tagger` |
//! | TestTagDecodeWrongType | `Tag decode wrong type` |
//! | TestDecodeRequiresHeaders (subset) | `Tag decode requires headers` |
//! | TestTagDecodeSignatures | `Tag decode peels trailing PGP` |
//! | TestDecodeFirstOccurrenceWins (gpgsig) | `Tag decode skips gpgsig-sha256` |
//! | TestCommitError (type check) | `Tag.commit rejects non-commit` |

const std = @import("std");
const plumbing = @import("plumbing");
const storer = @import("storer");

const signature_mod = @import("signature.zig");
const commit_mod = @import("commit.zig");
const object_err = @import("error.zig");
const error_mod = @import("error.zig");
const openpgp_mod = @import("openpgp");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Hash = plumbing.Hash;
const ZeroHash = plumbing.ZeroHash;
const HexSize = plumbing.HexSize;
const MaxHexSize = plumbing.MaxHexSize;
const ObjectType = plumbing.ObjectType;
const MemoryObject = plumbing.MemoryObject;
const Signature = signature_mod.Signature;
const ObjectGetter = storer.ObjectGetter;

/// go-git `headerpgp256` — recognized and skipped on tags (no field in v5).
const header_pgp256 = "gpgsig-sha256";

/// Decode/type errors for tag objects (go-git `ErrMalformedTag` / `ErrUnsupportedObject`).
pub const Error = error{
    UnsupportedObject,
    MalformedTag,
    InvalidType,
};

// ---------------------------------------------------------------------------
// Tag
// ---------------------------------------------------------------------------

/// Annotated tag object (go-git `Tag`).
///
/// Points at a single object of any type (usually commit or blob). Not used for
/// lightweight tags.
///
/// Owned strings (`name`, `message`, `pgp_signature`, `tagger.name`,
/// `tagger.email`) are freed by `deinit`.
pub const Tag = struct {
    allocator: Allocator,
    /// Hash of the tag object itself (go-git `Hash`).
    hash: Hash = ZeroHash,
    /// Tag name (go-git `Name`).
    name: []const u8 = "",
    /// Who created the tag (go-git `Tagger`).
    tagger: Signature = .{},
    /// Tag message body (go-git `Message`).
    message: []const u8 = "",
    /// Trailing inline PGP/SSH signature block (go-git `PGPSignature`).
    pgp_signature: []const u8 = "",
    /// Object type of the target (go-git `TargetType`).
    target_type: ObjectType = .invalid,
    /// Hash of the target object (go-git `Target`).
    target: Hash = ZeroHash,

    /// Storer for target resolution (go-git unexported `s`).
    storage: ?ObjectGetter = null,
    /// Source encoded object for `encodeWithoutSignature` (go-git `src`).
    src: ?*MemoryObject = null,

    /// Construct an empty tag that owns strings via `allocator`.
    pub fn init(allocator: Allocator) Tag {
        return .{ .allocator = allocator };
    }

    /// Free owned string fields. Does not free `src` or storer-owned objects.
    pub fn deinit(self: *Tag) void {
        self.freeOwned();
        self.* = undefined;
    }

    fn freeOwned(self: *Tag) void {
        freeSlice(self.allocator, self.name);
        freeSlice(self.allocator, self.message);
        freeSlice(self.allocator, self.pgp_signature);
        freeSlice(self.allocator, self.tagger.name);
        freeSlice(self.allocator, self.tagger.email);
        self.name = "";
        self.message = "";
        self.pgp_signature = "";
        self.tagger = .{};
    }

    /// go-git `(*Tag).reset` — clear fields, keep allocator and storage.
    fn reset(self: *Tag) void {
        const alloc = self.allocator;
        const storage = self.storage;
        self.freeOwned();
        self.* = .{
            .allocator = alloc,
            .storage = storage,
        };
    }

    /// go-git `(*Tag).ID`.
    pub fn id(self: *const Tag) Hash {
        return self.hash;
    }

    /// go-git `(*Tag).Type` — always `.tag`.
    pub fn objectType(_: *const Tag) ObjectType {
        return .tag;
    }

    /// go-git `(*Tag).Decode` — parse an encoded tag object into `self`.
    pub fn decode(self: *Tag, o: *MemoryObject) (Error || Allocator.Error)!void {
        if (o.object_type != .tag) return error.UnsupportedObject;

        self.reset();
        self.hash = o.hash();
        self.src = o;

        var scanner = TagScanner{
            .content = o.readerBytes(),
            .tag = self,
        };
        defer scanner.msgbuf.deinit(self.allocator);

        var state: ?TagState = .object;
        while (state) |s| {
            state = try dispatchState(s, &scanner);
        }

        const data = scanner.msgbuf.items;
        const peeled = signature_mod.parseSignedBytes(data);
        if (peeled.pos) |sm| {
            self.pgp_signature = try self.allocator.dupe(u8, data[sm..]);
            errdefer freeSlice(self.allocator, self.pgp_signature);
            self.message = try self.allocator.dupe(u8, data[0..sm]);
        } else {
            self.message = try self.allocator.dupe(u8, data);
        }
    }

    /// go-git `(*Tag).Encode` — write annotated tag format including signature.
    pub fn encode(self: *const Tag, o: *MemoryObject) (Allocator.Error || Writer.Error)!void {
        return self.encodeInner(o, true);
    }

    /// go-git `(*Tag).EncodeWithoutSignature`.
    ///
    /// When the tag still matches its source object, stream raw bytes with
    /// signature headers and the trailing inline signature stripped. Otherwise
    /// encode from struct fields without `pgp_signature`.
    pub fn encodeWithoutSignature(self: *const Tag, o: *MemoryObject) (Allocator.Error || Writer.Error)!void {
        if (self.matchesSource()) {
            try signature_mod.stripObjectSignatures(o, self.src.?, .tag);
            return;
        }
        return self.encodeInner(o, false);
    }

    /// Verifies the detached signature and returns the owned signing entity.
    pub fn verify(self: *const Tag, armored_keyring: []const u8) anyerror!openpgp_mod.Entity {
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

    fn matchesSource(self: *const Tag) bool {
        const src = self.src orelse return false;
        var fresh = Tag.init(self.allocator);
        defer fresh.deinit();
        fresh.decode(src) catch return false;
        if (!self.hash.eql(fresh.hash)) return false;
        if (!std.mem.eql(u8, self.name, fresh.name)) return false;
        if (!signatureEqual(self.tagger, fresh.tagger)) return false;
        if (!std.mem.eql(u8, self.message, fresh.message)) return false;
        if (self.target_type != fresh.target_type) return false;
        if (!self.target.eql(fresh.target)) return false;
        return true;
    }

    fn encodeInner(self: *const Tag, o: *MemoryObject, include_sig: bool) (Allocator.Error || Writer.Error)!void {
        o.setType(.tag);

        var aw: Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        const w = &aw.writer;

        var hex: [MaxHexSize]u8 = undefined;
        try w.print("object {s}\n", .{self.target.string(&hex)});
        try w.print("type {s}\n", .{self.target_type.bytes()});
        try w.print("tag {s}\n", .{self.name});

        if (!isZeroSignature(self.tagger)) {
            try w.writeAll("tagger ");
            try self.tagger.encode(w);
            try w.writeAll("\n");
        }

        try w.writeAll("\n");
        try w.writeAll(self.message);

        // Message must already end with a newline before a trailing signature
        // (go-git documents this as caller responsibility).
        if (include_sig) {
            try w.writeAll(self.pgp_signature);
        }

        try o.setContent(aw.written());
    }

    /// go-git `(*Tag).Commit` — resolve target when `target_type == .commit`.
    ///
    /// Caller owns the returned `*Commit` (`deinit` + `destroy`).
    pub fn commit(self: *const Tag) anyerror!*commit_mod.Commit {
        if (self.target_type != .commit) return error.UnsupportedObject;
        const storage = self.storage orelse return error.ObjectNotFound;
        const o = try storage.encodedObject(.commit, self.target);
        const c = try self.allocator.create(commit_mod.Commit);
        errdefer {
            c.deinit();
            self.allocator.destroy(c);
        }
        c.* = commit_mod.Commit.init(self.allocator);
        c.storer = storage;
        try c.decode(o);
        return c;
    }
};

// ---------------------------------------------------------------------------
// Free functions (go-git GetTag / DecodeTag)
// ---------------------------------------------------------------------------

/// go-git `GetTag` — load and decode a tag by hash.
pub fn getTag(allocator: Allocator, s: anytype, h: Hash) anyerror!Tag {
    const o = try s.encodedObject(ObjectType.tag, h);
    return decodeTag(allocator, s, o);
}

/// go-git `DecodeTag` — decode `o` and attach storer for later resolution.
///
/// `s` must be a pointer to a type with `encodedObject` (same as `decodeCommit`).
pub fn decodeTag(allocator: Allocator, s: anytype, o: *MemoryObject) (Error || Allocator.Error)!Tag {
    var t = Tag.init(allocator);
    errdefer t.deinit();
    t.storage = ObjectGetter.from(@TypeOf(s.*), s);
    try t.decode(o);
    return t;
}

/// Decode without attaching a storer (unit tests / pure codec path).
pub fn decodeTagOnly(allocator: Allocator, o: *MemoryObject) (Error || Allocator.Error)!Tag {
    var t = Tag.init(allocator);
    errdefer t.deinit();
    try t.decode(o);
    return t;
}

// ---------------------------------------------------------------------------
// TagIter (go-git NewTagIter)
// ---------------------------------------------------------------------------

/// Iterator over tag objects from an encoded-object iterator (go-git `TagIter`).
///
/// Non-tag objects are skipped (matches go-git comment / BlobIter pattern).
pub const TagIter = struct {
    allocator: Allocator,
    storage: ObjectGetter,
    encoded_iter: storer.EncodedObjectIter,

    /// go-git `NewTagIter`.
    pub fn init(allocator: Allocator, s: ObjectGetter, iter: storer.EncodedObjectIter) TagIter {
        return .{
            .allocator = allocator,
            .storage = s,
            .encoded_iter = iter,
        };
    }

    /// Next tag or `error.EndOfStream`. Caller owns the returned `Tag` (`deinit`).
    pub fn next(self: *TagIter) anyerror!Tag {
        while (true) {
            const obj = try self.encoded_iter.next();
            if (obj.object_type != .tag) continue;
            var t = Tag.init(self.allocator);
            errdefer t.deinit();
            t.storage = self.storage;
            try t.decode(obj);
            return t;
        }
    }

    /// Call `cb(*const Tag)` for each tag; `error.Stop` ends successfully.
    /// Closes the underlying iterator (go-git `ForEach`).
    pub fn forEach(self: *TagIter, cb: anytype) !void {
        defer self.close();
        while (true) {
            var t = self.next() catch |err| {
                if (err == error.EndOfStream) return;
                return err;
            };
            defer t.deinit();
            @call(.auto, cb, .{&t}) catch |err| {
                const e: anyerror = err;
                if (e == error.Stop) return;
                return e;
            };
        }
    }

    /// go-git `Close`.
    pub fn close(self: *TagIter) void {
        self.encoded_iter.close();
    }
};

/// Free-function alias for `TagIter.init` (go-git `NewTagIter`).
///
/// `s` is `ObjectGetter` or a pointer to a type with `encodedObject`.
pub fn newTagIter(allocator: Allocator, s: anytype, iter: storer.EncodedObjectIter) TagIter {
    const getter: ObjectGetter = if (@TypeOf(s) == ObjectGetter)
        s
    else
        ObjectGetter.from(@TypeOf(s.*), s);
    return TagIter.init(allocator, getter, iter);
}

// ---------------------------------------------------------------------------
// Signature field helpers
// ---------------------------------------------------------------------------

fn freeSlice(allocator: Allocator, s: []const u8) void {
    if (s.len > 0) allocator.free(s);
}

/// Own a Signature whose name/email currently borrow `data` (or any buffer).
fn ownSignature(allocator: Allocator, borrowed: Signature) Allocator.Error!Signature {
    const name = try allocator.dupe(u8, borrowed.name);
    errdefer freeSlice(allocator, name);
    const email = try allocator.dupe(u8, borrowed.email);
    return .{
        .name = name,
        .email = email,
        .when = borrowed.when,
        .tz_offset_minutes = borrowed.tz_offset_minutes,
    };
}

/// go-git `isZeroSignature`.
fn isZeroSignature(s: Signature) bool {
    // go-git: empty Name, Email, and When.IsZero(). Ported as zero unix + zero tz
    // with empty identity (zero `time.Time` maps to when=0, offset=0 here).
    return s.name.len == 0 and s.email.len == 0 and s.when == 0 and s.tz_offset_minutes == 0;
}

fn signatureEqual(a: Signature, b: Signature) bool {
    return std.mem.eql(u8, a.name, b.name) and
        std.mem.eql(u8, a.email, b.email) and
        a.when == b.when and
        a.tz_offset_minutes == b.tz_offset_minutes;
}

// ---------------------------------------------------------------------------
// Tag scanner state machine (go-git tag_scanner.go)
// ---------------------------------------------------------------------------

const TagState = enum {
    object,
    type_line,
    name,
    tagger,
    headers,
    skip_cont,
    message,
};

const TagScanner = struct {
    content: []const u8,
    pos: usize = 0,
    tag: *Tag,
    msgbuf: std.ArrayList(u8) = .empty,
    pending: ?[]const u8 = null,
    pending_eof: bool = false,

    fn readLine(self: *TagScanner) struct { []const u8, bool } {
        if (self.pending) |p| {
            const line = p;
            const eof = self.pending_eof;
            self.pending = null;
            self.pending_eof = false;
            return .{ line, eof };
        }
        if (self.pos >= self.content.len) {
            return .{ "", true };
        }
        const rest = self.content[self.pos..];
        if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            const line = rest[0 .. nl + 1];
            self.pos += nl + 1;
            return .{ line, false };
        }
        const line = rest;
        self.pos = self.content.len;
        return .{ line, true };
    }

    fn pushBack(self: *TagScanner, line: []const u8, eof: bool) void {
        self.pending = line;
        self.pending_eof = eof;
    }
};

fn dispatchState(state: TagState, s: *TagScanner) (Error || Allocator.Error)!?TagState {
    return switch (state) {
        .object => scanTagObject(s),
        .type_line => scanTagType(s),
        .name => scanTagName(s),
        .tagger => scanTagTagger(s),
        .headers => scanTagHeaders(s),
        .skip_cont => scanTagSkipCont(s),
        .message => scanTagMessage(s),
    };
}

fn scanTagObject(s: *TagScanner) (Error || Allocator.Error)!?TagState {
    const line, const eof = s.readLine();
    if (line.len == 0 or isBlankLine(line)) return error.MalformedTag;
    const key, const data = splitHeader(line);
    if (!std.mem.eql(u8, key, "object")) return error.MalformedTag;
    s.tag.target = try parseObjectIDHex(data);
    if (eof) return null;
    return .type_line;
}

fn scanTagType(s: *TagScanner) (Error || Allocator.Error)!?TagState {
    const line, const eof = s.readLine();
    if (line.len == 0 or isBlankLine(line)) return error.MalformedTag;
    const key, const data = splitHeader(line);
    if (!std.mem.eql(u8, key, "type")) return error.MalformedTag;
    s.tag.target_type = ObjectType.parse(data) catch return error.InvalidType;
    if (eof) return null;
    return .name;
}

fn scanTagName(s: *TagScanner) (Error || Allocator.Error)!?TagState {
    const line, const eof = s.readLine();
    if (line.len == 0 or isBlankLine(line)) return error.MalformedTag;
    const key, const data = splitHeader(line);
    if (!std.mem.eql(u8, key, "tag")) return error.MalformedTag;
    s.tag.name = try s.tag.allocator.dupe(u8, data);
    if (eof) return null;
    return .tagger;
}

fn scanTagTagger(s: *TagScanner) (Error || Allocator.Error)!?TagState {
    const line, const eof = s.readLine();
    if (line.len == 0) return null;
    if (isBlankLine(line)) return .message;

    const key, const data = splitHeader(line);
    if (std.mem.eql(u8, key, "tagger")) {
        var borrowed: Signature = .{};
        borrowed.decode(data);
        s.tag.tagger = try ownSignature(s.tag.allocator, borrowed);
        if (eof) return null;
        return .headers;
    }
    s.pushBack(line, eof);
    return .headers;
}

fn scanTagHeaders(s: *TagScanner) (Error || Allocator.Error)!?TagState {
    const line, const eof = s.readLine();
    if (line.len == 0) return null;
    if (isBlankLine(line)) return .message;

    const key, _ = splitHeader(line);
    var next: TagState = .headers;
    if (std.mem.eql(u8, key, "object") or
        std.mem.eql(u8, key, "type") or
        std.mem.eql(u8, key, "tag") or
        std.mem.eql(u8, key, "tagger"))
    {
        // Out-of-position duplicates: drop (go-git parse_tag_buffer).
    } else if (std.mem.eql(u8, key, header_pgp256)) {
        next = .skip_cont;
    } else {
        // Unknown header: drop (Tag has no ExtraHeaders).
    }
    if (eof) return null;
    return next;
}

fn scanTagSkipCont(s: *TagScanner) (Error || Allocator.Error)!?TagState {
    const line, const eof = s.readLine();
    if (line.len > 0 and line[0] == ' ') {
        if (eof) return null;
        return .skip_cont;
    }
    if (line.len > 0) s.pushBack(line, eof);
    return .headers;
}

fn scanTagMessage(s: *TagScanner) (Error || Allocator.Error)!?TagState {
    while (true) {
        const line, const eof = s.readLine();
        if (line.len > 0) {
            try s.msgbuf.appendSlice(s.tag.allocator, line);
        }
        if (eof) return null;
    }
}

// ---------------------------------------------------------------------------
// Header helpers (go-git commit_scanner.go)
// ---------------------------------------------------------------------------

fn isBlankLine(line: []const u8) bool {
    return line.len == 1 and line[0] == '\n';
}

fn splitHeader(line: []const u8) struct { []const u8, []const u8 } {
    const trimmed = std.mem.trimEnd(u8, line, "\n");
    if (std.mem.indexOfScalar(u8, trimmed, ' ')) |sp| {
        return .{ trimmed[0..sp], trimmed[sp + 1 ..] };
    }
    return .{ trimmed, &[_]u8{} };
}

fn parseObjectIDHex(data: []const u8) error{MalformedTag}!Hash {
    if (!plumbing.isHash(data)) return error.MalformedTag;
    return plumbing.parseHash(data) catch return error.MalformedTag;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Tag encode/decode round-trip" {
    const gpa = std.testing.allocator;

    const raw =
        \\object b029517f6300c2da0f4b651b8642506cd6aaf45d
        \\type blob
        \\tag foo
        \\tagger Foo <foo@example.local> 1136239445 -0700
        \\
        \\Message
        \\
        \\Foo
        \\Bar
        \\Baz
        \\
        \\
    ;

    var obj = MemoryObject.init(gpa);
    defer obj.deinit();
    obj.setType(.tag);
    _ = try obj.write(raw);

    var tag = try decodeTagOnly(gpa, &obj);
    defer tag.deinit();

    try std.testing.expectEqualStrings("foo", tag.name);
    try std.testing.expectEqualStrings("Message\n\nFoo\nBar\nBaz\n\n", tag.message);
    try std.testing.expect(tag.target_type == .blob);
    var hex: [MaxHexSize]u8 = undefined;
    try std.testing.expectEqualStrings(
        "b029517f6300c2da0f4b651b8642506cd6aaf45d",
        tag.target.string(&hex),
    );
    try std.testing.expectEqualStrings("Foo", tag.tagger.name);
    try std.testing.expectEqualStrings("foo@example.local", tag.tagger.email);
    try std.testing.expectEqual(@as(i64, 1136239445), tag.tagger.when);
    try std.testing.expectEqual(@as(i16, -7 * 60), tag.tagger.tz_offset_minutes);
    try std.testing.expectEqualStrings("", tag.pgp_signature);

    var encoded = MemoryObject.init(gpa);
    defer encoded.deinit();
    try tag.encode(&encoded);

    var again = try decodeTagOnly(gpa, &encoded);
    defer again.deinit();

    try std.testing.expectEqualStrings(tag.name, again.name);
    try std.testing.expectEqualStrings(tag.message, again.message);
    try std.testing.expect(tag.target_type == again.target_type);
    try std.testing.expect(tag.target.eql(again.target));
    try std.testing.expectEqualStrings(tag.tagger.name, again.tagger.name);
    try std.testing.expectEqualStrings(tag.tagger.email, again.tagger.email);
    try std.testing.expectEqual(tag.tagger.when, again.tagger.when);
    try std.testing.expectEqual(tag.tagger.tz_offset_minutes, again.tagger.tz_offset_minutes);
    try std.testing.expectEqualStrings(raw, encoded.readerBytes());
}

test "Tag encode omits zero tagger" {
    const gpa = std.testing.allocator;
    const raw =
        \\object c029517f6300c2da0f4b651b8642506cd6aaf45e
        \\type commit
        \\tag v1
        \\
        \\msg
        \\
    ;

    var obj = MemoryObject.init(gpa);
    defer obj.deinit();
    obj.setType(.tag);
    _ = try obj.write(raw);

    var tag = try decodeTagOnly(gpa, &obj);
    defer tag.deinit();
    try std.testing.expect(isZeroSignature(tag.tagger));

    var encoded = MemoryObject.init(gpa);
    defer encoded.deinit();
    try tag.encode(&encoded);
    try std.testing.expectEqualStrings(raw, encoded.readerBytes());
}

test "Tag decode wrong type" {
    const gpa = std.testing.allocator;
    var obj = MemoryObject.init(gpa);
    defer obj.deinit();
    obj.setType(.blob);

    var tag = Tag.init(gpa);
    defer tag.deinit();
    try std.testing.expectError(error.UnsupportedObject, tag.decode(&obj));
}

test "Tag decode requires headers" {
    const gpa = std.testing.allocator;
    const cases = [_][]const u8{
        "",
        "type commit\ntag v1\n\nmsg\n",
        "type commit\nobject c029517f6300c2da0f4b651b8642506cd6aaf45e\ntag v1\n\nmsg\n",
        "object c029517f6300c2da0f4b651b8642506cd6aaf45e\ntag v1\n\nmsg\n",
        "object c029517f6300c2da0f4b651b8642506cd6aaf45e\ntype commit\ntagger Foo <f@e> 1 +0000\n\nmsg\n",
        "object zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\ntype commit\ntag v1\n\nmsg\n",
        "object abcd\ntype commit\ntag v1\n\nmsg\n",
        "object c029517f6300c2da0f4b651b8642506cd6aaf45e00\ntype commit\ntag v1\n\nmsg\n",
        "object c029517f6300c2da0f4b651b8642506cd6aaf45e\n",
        "object c029517f6300c2da0f4b651b8642506cd6aaf45e\ntype commit\n",
    };

    for (cases) |raw| {
        var obj = MemoryObject.init(gpa);
        defer obj.deinit();
        obj.setType(.tag);
        _ = try obj.write(raw);

        var tag = Tag.init(gpa);
        defer tag.deinit();
        const result = tag.decode(&obj);
        try std.testing.expect(std.meta.isError(result));
        if (result) |_| unreachable else |err| {
            try std.testing.expect(err == error.MalformedTag or err == error.InvalidType);
        }
    }
}

test "Tag decode peels trailing PGP" {
    const gpa = std.testing.allocator;
    const inline_sig =
        \\-----BEGIN PGP SIGNATURE-----
        \\
        \\inlineline1
        \\inlineline2
        \\-----END PGP SIGNATURE-----
        \\
    ;
    const raw = "object c029517f6300c2da0f4b651b8642506cd6aaf45e\n" ++
        "type commit\n" ++
        "tag t\n" ++
        "tagger Foo <foo@example.local> 1500000000 +0000\n" ++
        "\n" ++
        "Tag body\n" ++
        inline_sig;

    var obj = MemoryObject.init(gpa);
    defer obj.deinit();
    obj.setType(.tag);
    _ = try obj.write(raw);

    var tag = try decodeTagOnly(gpa, &obj);
    defer tag.deinit();

    try std.testing.expectEqualStrings("Tag body\n", tag.message);
    try std.testing.expectEqualStrings(inline_sig, tag.pgp_signature);
}

test "Tag decode skips gpgsig-sha256 header" {
    const gpa = std.testing.allocator;
    const raw =
        \\object c029517f6300c2da0f4b651b8642506cd6aaf45e
        \\type commit
        \\tag v1
        \\tagger Alice <alice@example.local> 1500000000 +0000
        \\gpgsig-sha256 firstline
        \\ morefirst
        \\
        \\msg
        \\
    ;

    var obj = MemoryObject.init(gpa);
    defer obj.deinit();
    obj.setType(.tag);
    _ = try obj.write(raw);

    var tag = try decodeTagOnly(gpa, &obj);
    defer tag.deinit();

    try std.testing.expectEqualStrings("v1", tag.name);
    try std.testing.expectEqualStrings("msg\n", tag.message);
    try std.testing.expectEqualStrings("", tag.pgp_signature);
    try std.testing.expectEqualStrings("Alice", tag.tagger.name);
}

test "Tag.commit rejects non-commit" {
    const gpa = std.testing.allocator;
    var tag = Tag.init(gpa);
    defer tag.deinit();
    tag.target_type = .blob;
    try std.testing.expectError(error.UnsupportedObject, tag.commit());
}

test "Tag id and objectType" {
    const gpa = std.testing.allocator;
    var tag = Tag.init(gpa);
    defer tag.deinit();
    tag.hash = plumbing.newHash("b742a2a9fa0afcfa9a6fad080980fbc26b007c69");
    try std.testing.expect(tag.id().eql(tag.hash));
    try std.testing.expect(tag.objectType() == .tag);
}

test "Tag encode/decode signed round-trip" {
    const gpa = std.testing.allocator;
    const raw =
        \\object c029517f6300c2da0f4b651b8642506cd6aaf45e
        \\type commit
        \\tag signed
        \\tagger Foo <foo@example.local> 1500000000 +0000
        \\
        \\Signed tag
        \\-----BEGIN PGP SIGNATURE-----
        \\
        \\inlineSig=
        \\-----END PGP SIGNATURE-----
        \\
    ;

    var obj = MemoryObject.init(gpa);
    defer obj.deinit();
    obj.setType(.tag);
    _ = try obj.write(raw);

    var tag = try decodeTagOnly(gpa, &obj);
    defer tag.deinit();

    try std.testing.expectEqualStrings("Signed tag\n", tag.message);
    try std.testing.expect(std.mem.indexOf(u8, tag.pgp_signature, "BEGIN PGP") != null);

    var encoded = MemoryObject.init(gpa);
    defer encoded.deinit();
    try tag.encode(&encoded);

    var again = try decodeTagOnly(gpa, &encoded);
    defer again.deinit();
    try std.testing.expectEqualStrings(tag.message, again.message);
    try std.testing.expectEqualStrings(tag.pgp_signature, again.pgp_signature);
    try std.testing.expectEqualStrings(tag.name, again.name);
    try std.testing.expectEqualStrings(raw, encoded.readerBytes());
}

test "TagIter skips non-tags and decodes tags" {
    const gpa = std.testing.allocator;

    var blob_obj = MemoryObject.init(gpa);
    defer blob_obj.deinit();
    blob_obj.setType(.blob);
    _ = try blob_obj.write("not a tag");

    const tag_raw =
        \\object c029517f6300c2da0f4b651b8642506cd6aaf45e
        \\type commit
        \\tag v1
        \\
        \\msg
        \\
    ;
    var tag_obj = MemoryObject.init(gpa);
    defer tag_obj.deinit();
    tag_obj.setType(.tag);
    _ = try tag_obj.write(tag_raw);

    var series = [_]*MemoryObject{ &blob_obj, &tag_obj };
    var slice_iter = storer.EncodedObjectSliceIter.init(&series);
    const memory = @import("memory");
    var store = memory.Storage.init(gpa);
    defer store.deinit();
    var iter = newTagIter(gpa, &store, slice_iter.asIter());

    var tag = try iter.next();
    defer tag.deinit();
    try std.testing.expectEqualStrings("v1", tag.name);
    try std.testing.expectEqualStrings("msg\n", tag.message);
    try std.testing.expectError(error.EndOfStream, iter.next());
}

test "Tag decode clears existing state" {
    const gpa = std.testing.allocator;
    const raw =
        \\object c029517f6300c2da0f4b651b8642506cd6aaf45e
        \\type commit
        \\tag fresh
        \\
        \\fresh message
        \\
    ;

    var tag = Tag.init(gpa);
    defer tag.deinit();
    tag.hash = plumbing.newHash("1111111111111111111111111111111111111111");
    tag.name = try gpa.dupe(u8, "stale");
    tag.tagger = try ownSignature(gpa, .{
        .name = "Stale",
        .email = "stale@example.local",
        .when = 1,
        .tz_offset_minutes = 0,
    });
    tag.message = try gpa.dupe(u8, "stale message");
    tag.pgp_signature = try gpa.dupe(u8, "stale signature");
    tag.target_type = .blob;
    tag.target = plumbing.newHash("2222222222222222222222222222222222222222");

    var obj = MemoryObject.init(gpa);
    defer obj.deinit();
    obj.setType(.tag);
    _ = try obj.write(raw);

    try tag.decode(&obj);
    try std.testing.expect(tag.hash.eql(obj.hash()));
    try std.testing.expectEqualStrings("fresh", tag.name);
    try std.testing.expect(isZeroSignature(tag.tagger));
    try std.testing.expectEqualStrings("fresh message\n", tag.message);
    try std.testing.expectEqualStrings("", tag.pgp_signature);
    try std.testing.expect(tag.target_type == .commit);
    var hex: [MaxHexSize]u8 = undefined;
    try std.testing.expectEqualStrings(
        "c029517f6300c2da0f4b651b8642506cd6aaf45e",
        tag.target.string(&hex),
    );
}

test "Tag encodeWithoutSignature strips trailing PGP" {
    const gpa = std.testing.allocator;
    const raw =
        \\object 1eca38290a3131d0c90709496a9b2207a872631e
        \\type commit
        \\tag v1
        \\tagger Test Tagger <tagger@example.local> 1700000000 +0000
        \\
        \\tag message
        \\-----BEGIN PGP SIGNATURE-----
        \\
        \\inlineline1
        \\inlineline2
        \\-----END PGP SIGNATURE-----
        \\
    ;
    const expected =
        \\object 1eca38290a3131d0c90709496a9b2207a872631e
        \\type commit
        \\tag v1
        \\tagger Test Tagger <tagger@example.local> 1700000000 +0000
        \\
        \\tag message
        \\
    ;

    var obj = MemoryObject.init(gpa);
    defer obj.deinit();
    obj.setType(.tag);
    _ = try obj.write(raw);

    var tag = try decodeTagOnly(gpa, &obj);
    defer tag.deinit();

    var encoded = MemoryObject.init(gpa);
    defer encoded.deinit();
    try tag.encodeWithoutSignature(&encoded);
    try std.testing.expectEqualStrings(expected, encoded.readerBytes());
}

// Silence unused import if object_err is only for documentation.
comptime {
    _ = object_err.Error;
}
