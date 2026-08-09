//! Index (dircache) decoder — port of go-git
//! `plumbing/format/index/decoder.go` (v5.19.2).
//!
//! `NewDecoder` → `Decoder.init(reader)`; `Decode` → `decode(*Index)`.
//! Versions 2–4; extensions TREE / REUC / EOIE; optional unknown `A`–`Z`.

const std = @import("std");
const plumbing = @import("plumbing");
const hash_pkg = @import("hash");
const binary = @import("binary");

const index = @import("index.zig");
const err_mod = @import("error.zig");

const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;

const Error = err_mod.Error;
const Index = index.Index;
const Entry = index.Entry;
const Stage = index.Stage;
const Tree = index.Tree;
const TreeEntry = index.TreeEntry;
const ResolveUndo = index.ResolveUndo;
const ResolveUndoEntry = index.ResolveUndoEntry;
const EndOfIndexEntry = index.EndOfIndexEntry;
const Time = index.Time;
const Hash = plumbing.Hash;

/// Supported index version range (go-git `DecodeVersionSupported`).
/// go-git: `struct{ Min, Max uint32 }{Min: 2, Max: 4}`.
pub const DecodeVersionSupported = struct {
    /// go-git `DecodeVersionSupported.Min`.
    pub const min: u32 = 2;
    /// go-git `DecodeVersionSupported.Max`.
    pub const max: u32 = 4;
};

/// Fixed entry header before path: 10×u32 + OID + flags (go-git `entryHeaderLength`).
/// OID width follows the active object format (20 SHA-1 / 32 SHA-256).
fn entryHeaderLength() usize {
    return 40 + plumbing.digestSize() + 2;
}
const entry_extended: u16 = 0x4000;
const name_mask: u16 = 0xfff;
const intent_to_add_mask: u16 = 1 << 13;
const skip_work_tree_mask: u16 = 1 << 14;
/// Generous defensive limits for attacker-controlled, streaming index data.
/// Normal Git paths and extensions are far smaller; the limits prevent a tiny
/// prefix from forcing unbounded allocation before the body is available.
const max_path_bytes: usize = 1024 * 1024;
const max_extension_bytes: u32 = 64 * 1024 * 1024;

/// Reads and decodes index files from an input stream (go-git `Decoder`).
pub const Decoder = struct {
    reader: *Reader,
    hasher: hash_pkg.Hasher,
    /// Name of the previous entry (for V4 prefix compression). Points into
    /// the last successfully decoded entry's owned `name` slice.
    last_entry_name: []const u8 = "",

    /// go-git `NewDecoder`.
    pub fn init(reader: *Reader) Decoder {
        return .{
            .reader = reader,
            .hasher = hash_pkg.new(hash_pkg.objectFormat()),
            .last_entry_name = "",
        };
    }

    /// Decode the whole index into `idx` (go-git `Decode`).
    pub fn decode(self: *Decoder, idx: *Index) DecodeError!void {
        idx.version = try self.validateHeader();

        const entry_count = try self.readHashedUint32();
        try self.readEntries(idx, entry_count);
        try self.readExtensions(idx);
    }

    fn validateHeader(self: *Decoder) DecodeError!u32 {
        var sig: [4]u8 = undefined;
        try self.readHashed(&sig);
        if (!std.mem.eql(u8, &sig, &index.index_signature)) {
            return Error.MalformedSignature;
        }

        const version = try self.readHashedUint32();
        if (version < DecodeVersionSupported.min or version > DecodeVersionSupported.max) {
            return Error.UnsupportedVersion;
        }
        return version;
    }

    fn readEntries(self: *Decoder, idx: *Index, count: u32) DecodeError!void {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            var e = try self.readEntry(idx);
            errdefer e.deinit(idx.allocator);
            try idx.entries.append(idx.allocator, e);
            self.last_entry_name = idx.entries.items[idx.entries.items.len - 1].name;
        }
    }

    fn readEntry(self: *Decoder, idx: *Index) DecodeError!Entry {
        var e: Entry = .{};

        const sec = try self.readHashedUint32();
        const nsec = try self.readHashedUint32();
        const msec = try self.readHashedUint32();
        const mnsec = try self.readHashedUint32();
        e.dev = try self.readHashedUint32();
        e.inode = try self.readHashedUint32();
        e.mode = try self.readHashedUint32();
        e.uid = try self.readHashedUint32();
        e.gid = try self.readHashedUint32();
        e.size = try self.readHashedUint32();

        var hash_bytes: [plumbing.MaxSize]u8 = .{0} ** plumbing.MaxSize;
        const oid_len = plumbing.digestSize();
        try self.readHashed(hash_bytes[0..oid_len]);
        e.hash = Hash.fromBytes(hash_bytes[0..oid_len]);

        const flags = try self.readHashedUint16();
        var read: usize = entryHeaderLength();

        if (sec != 0 or nsec != 0) {
            e.created_at = Time.unix(@intCast(sec), @intCast(nsec));
        }
        if (msec != 0 or mnsec != 0) {
            e.modified_at = Time.unix(@intCast(msec), @intCast(mnsec));
        }

        e.stage = @as(Stage, @intCast((flags >> 12) & 0x3));

        if (flags & entry_extended != 0) {
            const extended = try self.readHashedUint16();
            read += 2;
            e.intent_to_add = extended & intent_to_add_mask != 0;
            e.skip_worktree = extended & skip_work_tree_mask != 0;
        }

        const name_consumed = try self.readEntryName(idx, &e, flags);
        errdefer e.deinit(idx.allocator);
        try self.padEntry(idx, &e, read, name_consumed);
        return e;
    }

    /// Returns stream bytes consumed for the name portion (V2/V3).
    fn readEntryName(self: *Decoder, idx: *Index, e: *Entry, flags: u16) DecodeError!usize {
        switch (idx.version) {
            2, 3 => {
                const name_len = flags & name_mask;
                const result = try self.doReadEntryName(idx.allocator, name_len);
                e.name = result.name;
                return result.consumed;
            },
            4 => {
                e.name = try self.doReadEntryNameV4(idx.allocator);
                return 0; // V4 has no padding; consumed unused
            },
            else => return Error.UnsupportedVersion,
        }
    }

    const NameRead = struct {
        name: []u8,
        consumed: usize,
    };

    /// V2/V3 path. When `name_len == name_mask` (0xFFF), scan for NUL
    /// (C Git `strlen(name)` fallback).
    fn doReadEntryName(self: *Decoder, allocator: Allocator, name_len: u16) DecodeError!NameRead {
        if (name_len == name_mask) {
            const name = try self.readUntilHashed(allocator, 0);
            return .{ .name = name, .consumed = name.len + 1 };
        }

        const name = try allocator.alloc(u8, name_len);
        errdefer allocator.free(name);
        try self.readHashed(name);
        return .{ .name = name, .consumed = name_len };
    }

    fn doReadEntryNameV4(self: *Decoder, allocator: Allocator) DecodeError![]u8 {
        const strip = try self.readVariableWidthIntHashed();

        var base: []const u8 = "";
        if (self.last_entry_name.len != 0) {
            if (strip < 0 or @as(usize, @intCast(strip)) > self.last_entry_name.len) {
                return Error.MalformedIndexFile;
            }
            const keep = self.last_entry_name.len - @as(usize, @intCast(strip));
            base = self.last_entry_name[0..keep];
        } else if (strip > 0) {
            return Error.MalformedIndexFile;
        }

        const suffix = try self.readUntilHashed(allocator, 0);
        defer allocator.free(suffix);

        const full = try allocator.alloc(u8, base.len + suffix.len);
        @memcpy(full[0..base.len], base);
        @memcpy(full[base.len..], suffix);
        return full;
    }

    fn padEntry(self: *Decoder, idx: *Index, e: *const Entry, read: usize, name_consumed: usize) DecodeError!void {
        if (idx.version == 4) return;

        const entry_size = read + e.name.len;
        var pad_len: isize = @intCast(8 - entry_size % 8);
        pad_len -= @as(isize, @intCast(name_consumed)) - @as(isize, @intCast(e.name.len));
        if (pad_len > 0) {
            try self.readHashedDiscard(@intCast(pad_len));
        }
    }

    fn readExtensions(self: *Decoder, idx: *Index) DecodeError!void {
        // Peek for extension header (4) + length (4) + trailing hash.
        // If fewer bytes remain, only the checksum is left.
        const peek_len = 4 + 4 + plumbing.digestSize();
        var expected: Hash = .{};

        while (true) {
            expected = hashSum(&self.hasher);
            _ = self.reader.peek(peek_len) catch |e| switch (e) {
                error.EndOfStream => break,
                else => return e,
            };
            try self.readExtension(idx);
        }

        try self.readChecksum(expected);
    }

    fn readExtension(self: *Decoder, idx: *Index) DecodeError!void {
        var header: [4]u8 = undefined;
        try self.readHashed(&header);

        const ext_len = try self.readHashedUint32();
        if (ext_len > max_extension_bytes) return Error.MalformedIndexFile;
        var body_list: std.ArrayList(u8) = .empty;
        defer body_list.deinit(idx.allocator);
        var remaining: usize = ext_len;
        var chunk: [4096]u8 = undefined;
        while (remaining > 0) {
            const n = @min(remaining, chunk.len);
            try self.readHashed(chunk[0..n]);
            try body_list.appendSlice(idx.allocator, chunk[0..n]);
            remaining -= n;
        }
        const body = body_list.items;

        var body_reader = Reader.fixed(body);

        if (std.mem.eql(u8, &header, &index.tree_ext_signature)) {
            const tree = try idx.allocator.create(Tree);
            tree.* = .{};
            errdefer {
                tree.deinit(idx.allocator);
                idx.allocator.destroy(tree);
            }
            try decodeTreeExtension(&body_reader, tree, idx.allocator);
            idx.cache = tree;
        } else if (std.mem.eql(u8, &header, &index.resolve_undo_ext_signature)) {
            const ru = try idx.allocator.create(ResolveUndo);
            ru.* = .{};
            errdefer {
                ru.deinit(idx.allocator);
                idx.allocator.destroy(ru);
            }
            try decodeResolveUndoExtension(&body_reader, ru, idx.allocator);
            idx.resolve_undo = ru;
        } else if (std.mem.eql(u8, &header, &index.end_of_index_entry_ext_signature)) {
            const eoie = try idx.allocator.create(EndOfIndexEntry);
            errdefer idx.allocator.destroy(eoie);
            eoie.* = try decodeEndOfIndexEntry(&body_reader);
            idx.end_of_index_entry = eoie;
        } else {
            // Optional extensions: first byte 'A'..'Z'. Else mandatory → error.
            // Body already consumed (skipped).
            if (header[0] < 'A' or header[0] > 'Z') {
                return Error.UnknownExtension;
            }
        }
    }

    fn readChecksum(self: *Decoder, expected: Hash) DecodeError!void {
        var h: [plumbing.MaxSize]u8 = undefined;
        const n = plumbing.digestSize();
        // Trailing checksum is not part of the hashed content for comparison.
        try self.reader.readSliceAll(h[0..n]);
        if (!std.mem.eql(u8, h[0..n], expected.slice())) {
            return Error.InvalidChecksum;
        }
    }

    // -----------------------------------------------------------------------
    // Hashed I/O (content before checksum is hashed like go-git TeeReader)
    // -----------------------------------------------------------------------

    fn readHashed(self: *Decoder, buf: []u8) DecodeError!void {
        self.reader.readSliceAll(buf) catch |e| return mapReaderError(e);
        self.hasher.update(buf);
    }

    fn readHashedByte(self: *Decoder) DecodeError!u8 {
        const b = self.reader.takeByte() catch |e| return mapReaderError(e);
        self.hasher.update(&[_]u8{b});
        return b;
    }

    fn readHashedUint32(self: *Decoder) DecodeError!u32 {
        var buf: [4]u8 = undefined;
        try self.readHashed(&buf);
        return std.mem.readInt(u32, &buf, .big);
    }

    fn readHashedUint16(self: *Decoder) DecodeError!u16 {
        var buf: [2]u8 = undefined;
        try self.readHashed(&buf);
        return std.mem.readInt(u16, &buf, .big);
    }

    fn readHashedDiscard(self: *Decoder, n: usize) DecodeError!void {
        var left = n;
        var buf: [256]u8 = undefined;
        while (left > 0) {
            const chunk = @min(left, buf.len);
            try self.readHashed(buf[0..chunk]);
            left -= chunk;
        }
    }

    /// Bytes until `delim` (exclusive); delimiter is consumed and hashed.
    fn readUntilHashed(self: *Decoder, allocator: Allocator, delim: u8) DecodeError![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        while (true) {
            const b = try self.readHashedByte();
            if (b == delim) return try list.toOwnedSlice(allocator);
            if (list.items.len >= max_path_bytes) return Error.MalformedIndexFile;
            try list.append(allocator, b);
        }
    }

    /// Git offset VLQ with hashing (go-git `binary.ReadVariableWidthInt`).
    fn readVariableWidthIntHashed(self: *Decoder) DecodeError!i64 {
        const mask_continue: u8 = 128;
        const mask_length: u8 = 127;
        const length_bits: u6 = 7;

        var c = try self.readHashedByte();
        var v: i64 = c & mask_length;

        while (c & mask_continue != 0) {
            if (v >= (std.math.maxInt(i64) - @as(i64, mask_length)) >> length_bits) {
                return binary.Error.IntegerOverflow;
            }
            v += 1;
            c = try self.readHashedByte();
            v = (v << length_bits) + @as(i64, c & mask_length);
        }
        return v;
    }
};

pub const DecodeError = Error || Allocator.Error || Reader.Error || binary.Error;

fn mapReaderError(e: Reader.Error) DecodeError {
    return e;
}

/// Clone hasher and finalise (go-git `hash.Sum` does not consume the stream hash).
fn hashSum(hasher: *const hash_pkg.Hasher) Hash {
    var tmp = hasher.*;
    var out: [hash_pkg.MaxSize]u8 = .{0} ** hash_pkg.MaxSize;
    const n = tmp.digestSize();
    tmp.final(out[0..n]);
    return Hash.fromBytes(out[0..n]);
}

// ---------------------------------------------------------------------------
// Extension payload parsers (go-git treeExtensionDecoder / …)
// ---------------------------------------------------------------------------

fn decodeTreeExtension(r: *Reader, t: *Tree, allocator: Allocator) DecodeError!void {
    while (true) {
        const maybe = readTreeEntry(r, allocator) catch |e| switch (e) {
            error.EndOfStream => return,
            else => |err| return err,
        };
        if (maybe) |te| {
            try t.entries.append(allocator, te);
        }
    }
}

fn readTreeEntry(r: *Reader, allocator: Allocator) DecodeError!?TreeEntry {
    const path = try readUntilPlain(r, allocator, 0);
    errdefer allocator.free(path);

    const count_raw = try readUntilPlain(r, allocator, ' ');
    defer allocator.free(count_raw);
    const entry_count = std.fmt.parseInt(i32, count_raw, 10) catch return Error.MalformedIndexFile;

    const trees_raw = try readUntilPlain(r, allocator, '\n');
    defer allocator.free(trees_raw);
    const subtrees = std.fmt.parseInt(i32, trees_raw, 10) catch return Error.MalformedIndexFile;

    // Invalidated: negative entry_count, no object name follows.
    if (entry_count < 0) {
        allocator.free(path);
        return null;
    }

    var hash_bytes: [plumbing.MaxSize]u8 = .{0} ** plumbing.MaxSize;
    const oid_len = plumbing.digestSize();
    r.readSliceAll(hash_bytes[0..oid_len]) catch |e| return mapReaderError(e);

    return TreeEntry{
        .path = path,
        .entries = entry_count,
        .trees = subtrees,
        .hash = Hash.fromBytes(hash_bytes[0..oid_len]),
    };
}

fn decodeResolveUndoExtension(r: *Reader, ru: *ResolveUndo, allocator: Allocator) DecodeError!void {
    while (true) {
        const e = readResolveUndoEntry(r, allocator) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e2| return e2,
        };
        try ru.entries.append(allocator, e);
    }
}

fn readResolveUndoEntry(r: *Reader, allocator: Allocator) DecodeError!ResolveUndoEntry {
    const path = try readUntilPlain(r, allocator, 0);
    errdefer allocator.free(path);

    var e = ResolveUndoEntry{ .path = path };

    // Stages 1..3: NUL-terminated octal mode; "0" means absent.
    var present: [3]Stage = undefined;
    var present_n: usize = 0;
    var s: Stage = 1;
    while (s <= 3) : (s += 1) {
        const ascii = try readUntilPlain(r, allocator, 0);
        defer allocator.free(ascii);
        const mode = std.fmt.parseInt(i64, ascii, 8) catch return Error.MalformedIndexFile;
        if (mode != 0) {
            e.setStage(s, plumbing.ZeroHash);
            present[present_n] = s;
            present_n += 1;
        }
    }

    // Hashes written in stage order 1→2→3 for present stages only.
    const oid_len = plumbing.digestSize();
    for (present[0..present_n]) |st| {
        var hash_bytes: [plumbing.MaxSize]u8 = .{0} ** plumbing.MaxSize;
        r.readSliceAll(hash_bytes[0..oid_len]) catch |err| return mapReaderError(err);
        e.setStage(st, Hash.fromBytes(hash_bytes[0..oid_len]));
    }

    return e;
}

fn decodeEndOfIndexEntry(r: *Reader) DecodeError!EndOfIndexEntry {
    const offset = r.takeInt(u32, .big) catch |e| return mapReaderError(e);
    var hash_bytes: [plumbing.MaxSize]u8 = .{0} ** plumbing.MaxSize;
    const oid_len = plumbing.digestSize();
    r.readSliceAll(hash_bytes[0..oid_len]) catch |e| return mapReaderError(e);
    return .{
        .offset = offset,
        .hash = Hash.fromBytes(hash_bytes[0..oid_len]),
    };
}

/// Read until `delim` (exclusive); delimiter consumed. No hashing.
fn readUntilPlain(r: *Reader, allocator: Allocator, delim: u8) DecodeError![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    while (true) {
        const b = r.takeByte() catch |e| return mapReaderError(e);
        if (b == delim) return try list.toOwnedSlice(allocator);
        if (list.items.len >= max_path_bytes) return Error.MalformedIndexFile;
        try list.append(allocator, b);
    }
}

// ===========================================================================
// Tests — major cases from go-git decoder_test.go (embedded fixtures)
// ===========================================================================

/// Build an index trailer: digest of `content` with the active object format.
fn indexFooter(content: []const u8) Hash {
    var h = hash_pkg.new(hash_pkg.objectFormat());
    h.update(content);
    var out: [hash_pkg.MaxSize]u8 = .{0} ** hash_pkg.MaxSize;
    const n = h.digestSize();
    h.final(out[0..n]);
    return Hash.fromBytes(out[0..n]);
}

fn appendBe32(list: *std.ArrayList(u8), allocator: Allocator, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .big);
    try list.appendSlice(allocator, &buf);
}

fn appendBe16(list: *std.ArrayList(u8), allocator: Allocator, v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .big);
    try list.appendSlice(allocator, &buf);
}

/// Minimal fixed-length V2 entry (no extended flags).
fn appendV2Entry(
    list: *std.ArrayList(u8),
    allocator: Allocator,
    name: []const u8,
    hash: Hash,
    size: u32,
    stage: Stage,
    ctime_sec: u32,
    ctime_nsec: u32,
    mtime_sec: u32,
    mtime_nsec: u32,
    mode: u32,
) !void {
    try appendBe32(list, allocator, ctime_sec);
    try appendBe32(list, allocator, ctime_nsec);
    try appendBe32(list, allocator, mtime_sec);
    try appendBe32(list, allocator, mtime_nsec);
    try appendBe32(list, allocator, 0); // dev
    try appendBe32(list, allocator, 0); // inode
    try appendBe32(list, allocator, mode);
    try appendBe32(list, allocator, 0); // uid
    try appendBe32(list, allocator, 0); // gid
    try appendBe32(list, allocator, size);
    try list.appendSlice(allocator, hash.slice());

    var flags: u16 = @as(u16, @intCast(stage & 0x3)) << 12;
    if (name.len < name_mask) {
        flags |= @intCast(name.len);
    } else {
        flags |= name_mask;
    }
    try appendBe16(list, allocator, flags);
    try list.appendSlice(allocator, name);

    // Pad to multiple of 8 (encoder: padLen = 8 - wrote%8).
    const wrote = entryHeaderLength() + name.len;
    const pad = 8 - wrote % 8;
    try list.appendNTimes(allocator, 0, pad);
}

/// V3 entry with extended flags (intent-to-add / skip-worktree).
fn appendV3EntryExtended(
    list: *std.ArrayList(u8),
    allocator: Allocator,
    name: []const u8,
    hash: Hash,
    size: u32,
    intent_to_add: bool,
    skip_worktree: bool,
) !void {
    try appendBe32(list, allocator, 1);
    try appendBe32(list, allocator, 0);
    try appendBe32(list, allocator, 1);
    try appendBe32(list, allocator, 0);
    try appendBe32(list, allocator, 0);
    try appendBe32(list, allocator, 0);
    try appendBe32(list, allocator, 0o100644);
    try appendBe32(list, allocator, 0);
    try appendBe32(list, allocator, 0);
    try appendBe32(list, allocator, size);
    try list.appendSlice(allocator, hash.slice());

    var flags: u16 = entry_extended;
    if (name.len < name_mask) {
        flags |= @intCast(name.len);
    } else {
        flags |= name_mask;
    }
    try appendBe16(list, allocator, flags);

    var ext: u16 = 0;
    if (intent_to_add) ext |= intent_to_add_mask;
    if (skip_worktree) ext |= skip_work_tree_mask;
    try appendBe16(list, allocator, ext);
    try list.appendSlice(allocator, name);

    const wrote = entryHeaderLength() + 2 + name.len;
    const pad = 8 - wrote % 8;
    try list.appendNTimes(allocator, 0, pad);
}

/// V4 entry with prefix compression against `prev_name`.
fn appendV4Entry(
    list: *std.ArrayList(u8),
    allocator: Allocator,
    name: []const u8,
    prev_name: []const u8,
    hash: Hash,
    size: u32,
    intent_to_add: bool,
) !void {
    try appendBe32(list, allocator, 1);
    try appendBe32(list, allocator, 0);
    try appendBe32(list, allocator, 1);
    try appendBe32(list, allocator, 0);
    try appendBe32(list, allocator, 0);
    try appendBe32(list, allocator, 0);
    try appendBe32(list, allocator, 0o100644);
    try appendBe32(list, allocator, 0);
    try appendBe32(list, allocator, 0);
    try appendBe32(list, allocator, size);
    try list.appendSlice(allocator, hash.slice());

    var flags: u16 = 0;
    if (intent_to_add) flags |= entry_extended;
    // V4 still stores name_mask bits but decoder ignores them for path.
    if (name.len < name_mask) {
        flags |= @intCast(name.len);
    } else {
        flags |= name_mask;
    }
    try appendBe16(list, allocator, flags);

    if (intent_to_add) {
        try appendBe16(list, allocator, intent_to_add_mask);
    }

    // strip length = len(prev) - common_prefix
    var prefix: usize = 0;
    const n = @min(prev_name.len, name.len);
    while (prefix < n and prev_name[prefix] == name[prefix]) : (prefix += 1) {}
    const strip: i64 = if (prev_name.len == 0) 0 else @intCast(prev_name.len - prefix);

    var vlq_buf: [16]u8 = undefined;
    var vlq_w: std.Io.Writer = .fixed(&vlq_buf);
    try binary.writeVariableWidthInt(&vlq_w, strip);
    try list.appendSlice(allocator, vlq_w.buffered());

    try list.appendSlice(allocator, name[prefix..]);
    try list.append(allocator, 0);
}

fn finishIndex(list: *std.ArrayList(u8), allocator: Allocator) !void {
    const sum = indexFooter(list.items);
    try list.appendSlice(allocator, sum.slice());
}

fn decodeBytes(allocator: Allocator, raw: []const u8) !Index {
    var r = Reader.fixed(raw);
    var dec = Decoder.init(&r);
    var idx = Index.init(allocator);
    errdefer idx.deinit();
    try dec.decode(&idx);
    return idx;
}

// ---- TestDecode / TestDecodeEntries (minimal synthetic basic index) ----

test "IndexSuite.TestDecode" {
    // go-git TestDecode / TestDecodeEntries (structure; synthetic fixture)
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, &index.index_signature);
    try appendBe32(&buf, allocator, 2);
    try appendBe32(&buf, allocator, 1);

    const h = plumbing.newHash("32858aad3c383ed1ff0a0f9bdf231d54a00c9e88");
    try appendV2Entry(&buf, allocator, ".gitignore", h, 189, 0, 1480626693, 498593596, 1480626693, 498593596, 0o100644);
    try finishIndex(&buf, allocator);

    var idx = try decodeBytes(allocator, buf.items);
    defer idx.deinit();

    try std.testing.expectEqual(@as(u32, 2), idx.version);
    try std.testing.expectEqual(@as(usize, 1), idx.entries.items.len);
    const e = idx.entries.items[0];
    try std.testing.expectEqualStrings(".gitignore", e.name);
    try std.testing.expectEqual(@as(u32, 189), e.size);
    try std.testing.expectEqual(@as(i64, 1480626693), e.created_at.sec);
    try std.testing.expectEqual(@as(i32, 498593596), e.created_at.nsec);
    try std.testing.expectEqual(@as(i64, 1480626693), e.modified_at.sec);
    try std.testing.expectEqual(@as(i32, 498593596), e.modified_at.nsec);
    try std.testing.expect(e.hash.eql(h));
    try std.testing.expectEqual(@as(u32, 0o100644), e.mode);
}

test "IndexSuite.TestDecodeEntries" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, &index.index_signature);
    try appendBe32(&buf, allocator, 2);
    try appendBe32(&buf, allocator, 2);

    const h0 = plumbing.ZeroHash;
    try appendV2Entry(&buf, allocator, ".gitignore", h0, 1, 0, 1, 0, 1, 0, 0o100644);
    try appendV2Entry(&buf, allocator, "CHANGELOG", h0, 2, 0, 1, 0, 1, 0, 0o100644);
    try finishIndex(&buf, allocator);

    var idx = try decodeBytes(allocator, buf.items);
    defer idx.deinit();
    try std.testing.expectEqual(@as(usize, 2), idx.entries.items.len);
    try std.testing.expectEqualStrings(".gitignore", idx.entries.items[0].name);
    try std.testing.expectEqualStrings("CHANGELOG", idx.entries.items[1].name);
}

// ---- TestDecodeCacheTree ----

test "IndexSuite.TestDecodeCacheTree" {
    // go-git TestDecodeCacheTree (synthetic TREE payload)
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, &index.index_signature);
    try appendBe32(&buf, allocator, 2);
    try appendBe32(&buf, allocator, 0); // no entries

    // TREE body: root + one child
    var tree_body: std.ArrayList(u8) = .empty;
    defer tree_body.deinit(allocator);
    // path="" entry_count=9 trees=1
    try tree_body.append(allocator, 0);
    try tree_body.appendSlice(allocator, "9 1\n");
    const root_hash = plumbing.newHash("a8d315b2b1c615d43042c3a62402b8a54288cf5c");
    try tree_body.appendSlice(allocator, root_hash.slice());
    // path="go" entry_count=1 trees=0
    try tree_body.appendSlice(allocator, "go");
    try tree_body.append(allocator, 0);
    try tree_body.appendSlice(allocator, "1 0\n");
    const go_hash = plumbing.newHash("a39771a7651f97faf5c72e08224d857fc35133db");
    try tree_body.appendSlice(allocator, go_hash.slice());

    try buf.appendSlice(allocator, &index.tree_ext_signature);
    try appendBe32(&buf, allocator, @intCast(tree_body.items.len));
    try buf.appendSlice(allocator, tree_body.items);
    try finishIndex(&buf, allocator);

    var idx = try decodeBytes(allocator, buf.items);
    defer idx.deinit();

    try std.testing.expect(idx.cache != null);
    try std.testing.expectEqual(@as(usize, 2), idx.cache.?.entries.items.len);
    try std.testing.expectEqualStrings("", idx.cache.?.entries.items[0].path);
    try std.testing.expectEqual(@as(i32, 9), idx.cache.?.entries.items[0].entries);
    try std.testing.expectEqual(@as(i32, 1), idx.cache.?.entries.items[0].trees);
    try std.testing.expect(idx.cache.?.entries.items[0].hash.eql(root_hash));
    try std.testing.expectEqualStrings("go", idx.cache.?.entries.items[1].path);
    try std.testing.expectEqual(@as(i32, 1), idx.cache.?.entries.items[1].entries);
    try std.testing.expect(idx.cache.?.entries.items[1].hash.eql(go_hash));
}

// ---- TestTreeExtensionInvalidatedEntry ----

test "TestTreeExtensionInvalidatedEntry" {
    // go-git TestTreeExtensionInvalidatedEntry
    const allocator = std.testing.allocator;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    const oid_len = plumbing.digestSize();

    // Entry 1 valid root
    try body.append(allocator, 0);
    try body.appendSlice(allocator, "5 2\n");
    var root_hash: [plumbing.MaxSize]u8 = .{0} ** plumbing.MaxSize;
    root_hash[0] = 0xaa;
    try body.appendSlice(allocator, root_hash[0..oid_len]);

    // Entry 2 invalidated
    try body.appendSlice(allocator, "stale");
    try body.append(allocator, 0);
    try body.appendSlice(allocator, "-1 0\n");

    // Entry 3 valid
    try body.appendSlice(allocator, "good");
    try body.append(allocator, 0);
    try body.appendSlice(allocator, "2 0\n");
    var good_hash: [plumbing.MaxSize]u8 = .{0} ** plumbing.MaxSize;
    good_hash[0] = 0xbb;
    try body.appendSlice(allocator, good_hash[0..oid_len]);

    var r = Reader.fixed(body.items);
    var tree: Tree = .{};
    defer tree.deinit(allocator);
    try decodeTreeExtension(&r, &tree, allocator);

    try std.testing.expectEqual(@as(usize, 2), tree.entries.items.len);
    try std.testing.expectEqualStrings("", tree.entries.items[0].path);
    try std.testing.expectEqual(@as(i32, 5), tree.entries.items[0].entries);
    try std.testing.expectEqual(@as(i32, 2), tree.entries.items[0].trees);
    try std.testing.expectEqualSlices(u8, root_hash[0..oid_len], tree.entries.items[0].hash.slice());
    try std.testing.expectEqualStrings("good", tree.entries.items[1].path);
    try std.testing.expectEqual(@as(i32, 2), tree.entries.items[1].entries);
    try std.testing.expectEqualSlices(u8, good_hash[0..oid_len], tree.entries.items[1].hash.slice());
}

// ---- TestDecodeMergeConflict ----

test "IndexSuite.TestDecodeMergeConflict" {
    // go-git TestDecodeMergeConflict (stages on same path)
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, &index.index_signature);
    try appendBe32(&buf, allocator, 2);
    try appendBe32(&buf, allocator, 3);

    const h1 = plumbing.newHash("880cd14280f4b9b6ed3986d6671f907d7cc2a198");
    const h2 = plumbing.newHash("d499a1a0b79b7d87a35155afd0c1cce78b37a91c");
    const h3 = plumbing.newHash("14f8e368114f561c38e134f6e68ea6fea12d77ed");
    // Zero ctime/mtime/dev/inode/uid/gid/size for conflict stages
    try appendV2Entry(&buf, allocator, "go/example.go", h1, 0, index.AncestorMode, 0, 0, 0, 0, 0o100644);
    try appendV2Entry(&buf, allocator, "go/example.go", h2, 0, index.OurMode, 0, 0, 0, 0, 0o100644);
    try appendV2Entry(&buf, allocator, "go/example.go", h3, 0, index.TheirMode, 0, 0, 0, 0, 0o100644);
    try finishIndex(&buf, allocator);

    var idx = try decodeBytes(allocator, buf.items);
    defer idx.deinit();

    try std.testing.expectEqual(@as(usize, 3), idx.entries.items.len);
    try std.testing.expectEqual(index.AncestorMode, idx.entries.items[0].stage);
    try std.testing.expectEqual(index.OurMode, idx.entries.items[1].stage);
    try std.testing.expectEqual(index.TheirMode, idx.entries.items[2].stage);
    try std.testing.expect(idx.entries.items[0].created_at.isZero());
    try std.testing.expect(idx.entries.items[0].modified_at.isZero());
    try std.testing.expectEqual(@as(u32, 0), idx.entries.items[0].dev);
    try std.testing.expectEqual(@as(u32, 0), idx.entries.items[0].size);
    try std.testing.expect(idx.entries.items[0].hash.eql(h1));
    try std.testing.expect(idx.entries.items[1].hash.eql(h2));
    try std.testing.expect(idx.entries.items[2].hash.eql(h3));
    try std.testing.expectEqualStrings("go/example.go", idx.entries.items[0].name);
}

// ---- TestDecodeExtendedV3 ----

test "IndexSuite.TestDecodeExtendedV3" {
    // go-git TestDecodeExtendedV3
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, &index.index_signature);
    try appendBe32(&buf, allocator, 3);
    try appendBe32(&buf, allocator, 1);

    try appendV3EntryExtended(&buf, allocator, "intent-to-add", plumbing.ZeroHash, 0, true, false);
    try finishIndex(&buf, allocator);

    var idx = try decodeBytes(allocator, buf.items);
    defer idx.deinit();

    try std.testing.expectEqual(@as(u32, 3), idx.version);
    try std.testing.expectEqual(@as(usize, 1), idx.entries.items.len);
    try std.testing.expectEqualStrings("intent-to-add", idx.entries.items[0].name);
    try std.testing.expect(idx.entries.items[0].intent_to_add);
    try std.testing.expect(!idx.entries.items[0].skip_worktree);
}

// ---- TestDecodeResolveUndo ----

test "IndexSuite.TestDecodeResolveUndo" {
    // go-git TestDecodeResolveUndo (synthetic REUC payload)
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, &index.index_signature);
    try appendBe32(&buf, allocator, 2);
    try appendBe32(&buf, allocator, 0);

    var reuc: std.ArrayList(u8) = .empty;
    defer reuc.deinit(allocator);

    // path go/example.go — all 3 stages present
    try reuc.appendSlice(allocator, "go/example.go");
    try reuc.append(allocator, 0);
    try reuc.appendSlice(allocator, "100644"); // stage 1
    try reuc.append(allocator, 0);
    try reuc.appendSlice(allocator, "100644"); // stage 2
    try reuc.append(allocator, 0);
    try reuc.appendSlice(allocator, "100644"); // stage 3
    try reuc.append(allocator, 0);
    const ha = plumbing.newHash("1111111111111111111111111111111111111111");
    const hb = plumbing.newHash("2222222222222222222222222222222222222222");
    const hc = plumbing.newHash("3333333333333333333333333333333333333333");
    try reuc.appendSlice(allocator, ha.slice());
    try reuc.appendSlice(allocator, hb.slice());
    try reuc.appendSlice(allocator, hc.slice());

    // path haskal/haskal.hs — stages 2 and 3 only
    try reuc.appendSlice(allocator, "haskal/haskal.hs");
    try reuc.append(allocator, 0);
    try reuc.appendSlice(allocator, "0"); // stage 1 absent
    try reuc.append(allocator, 0);
    try reuc.appendSlice(allocator, "100644");
    try reuc.append(allocator, 0);
    try reuc.appendSlice(allocator, "100644");
    try reuc.append(allocator, 0);
    try reuc.appendSlice(allocator, hb.slice());
    try reuc.appendSlice(allocator, hc.slice());

    try buf.appendSlice(allocator, &index.resolve_undo_ext_signature);
    try appendBe32(&buf, allocator, @intCast(reuc.items.len));
    try buf.appendSlice(allocator, reuc.items);
    try finishIndex(&buf, allocator);

    var idx = try decodeBytes(allocator, buf.items);
    defer idx.deinit();

    try std.testing.expect(idx.resolve_undo != null);
    const ru = idx.resolve_undo.?;
    try std.testing.expectEqual(@as(usize, 2), ru.entries.items.len);
    try std.testing.expectEqualStrings("go/example.go", ru.entries.items[0].path);
    try std.testing.expectEqual(@as(usize, 3), ru.entries.items[0].stageCount());
    try std.testing.expect(ru.entries.items[0].getStage(index.AncestorMode) != null);
    try std.testing.expect(!ru.entries.items[0].getStage(index.AncestorMode).?.isZero());
    try std.testing.expect(ru.entries.items[0].getStage(index.OurMode).?.eql(hb));
    try std.testing.expect(ru.entries.items[0].getStage(index.TheirMode).?.eql(hc));
    try std.testing.expectEqualStrings("haskal/haskal.hs", ru.entries.items[1].path);
    try std.testing.expectEqual(@as(usize, 2), ru.entries.items[1].stageCount());
    try std.testing.expect(ru.entries.items[1].getStage(index.AncestorMode) == null);
    try std.testing.expect(ru.entries.items[1].getStage(index.OurMode) != null);
    try std.testing.expect(ru.entries.items[1].getStage(index.TheirMode) != null);
}

// ---- TestDecodeV4 ----

test "IndexSuite.TestDecodeV4" {
    // go-git TestDecodeV4 (synthetic names with compression)
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const names = [_][]const u8{ ".gitignore", "CHANGELOG", "intent-to-add" };

    try buf.appendSlice(allocator, &index.index_signature);
    try appendBe32(&buf, allocator, 4);
    try appendBe32(&buf, allocator, @intCast(names.len));

    var prev: []const u8 = "";
    for (names, 0..) |name, i| {
        const ita = std.mem.eql(u8, name, "intent-to-add");
        try appendV4Entry(&buf, allocator, name, prev, plumbing.ZeroHash, @intCast(i + 1), ita);
        prev = name;
    }
    try finishIndex(&buf, allocator);

    var idx = try decodeBytes(allocator, buf.items);
    defer idx.deinit();

    try std.testing.expectEqual(@as(u32, 4), idx.version);
    try std.testing.expectEqual(names.len, idx.entries.items.len);
    for (names, 0..) |name, i| {
        try std.testing.expectEqualStrings(name, idx.entries.items[i].name);
    }
    try std.testing.expect(idx.entries.items[2].intent_to_add);
    try std.testing.expect(!idx.entries.items[2].skip_worktree);
}

// ---- TestDecodeEndOfIndexEntry ----

test "IndexSuite.TestDecodeEndOfIndexEntry" {
    // go-git TestDecodeEndOfIndexEntry
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, &index.index_signature);
    try appendBe32(&buf, allocator, 2);
    try appendBe32(&buf, allocator, 0);

    var eoie_body: std.ArrayList(u8) = .empty;
    defer eoie_body.deinit(allocator);
    try appendBe32(&eoie_body, allocator, 716);
    const eh = plumbing.newHash("922e89d9ffd7cefce93a211615b2053c0f42bd78");
    try eoie_body.appendSlice(allocator, eh.slice());

    try buf.appendSlice(allocator, &index.end_of_index_entry_ext_signature);
    try appendBe32(&buf, allocator, @intCast(eoie_body.items.len));
    try buf.appendSlice(allocator, eoie_body.items);
    try finishIndex(&buf, allocator);

    var idx = try decodeBytes(allocator, buf.items);
    defer idx.deinit();

    try std.testing.expect(idx.end_of_index_entry != null);
    try std.testing.expectEqual(@as(u32, 716), idx.end_of_index_entry.?.offset);
    try std.testing.expect(idx.end_of_index_entry.?.hash.eql(eh));
}

// ---- TestDecodeUnknownOptionalExt / TestDecodeUnknownMandatoryExt ----

test "IndexSuite.TestDecodeUnknownOptionalExt" {
    // go-git TestDecodeUnknownOptionalExt
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, &index.index_signature);
    try appendBe32(&buf, allocator, 2);
    try appendBe32(&buf, allocator, 0);

    try buf.appendSlice(allocator, "TEST");
    try appendBe32(&buf, allocator, 8);
    try buf.appendSlice(allocator, "testdata");
    try finishIndex(&buf, allocator);

    var idx = try decodeBytes(allocator, buf.items);
    defer idx.deinit();
    try std.testing.expectEqual(@as(u32, 2), idx.version);
}

test "IndexSuite.TestDecodeUnknownMandatoryExt" {
    // go-git TestDecodeUnknownMandatoryExt
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, &index.index_signature);
    try appendBe32(&buf, allocator, 2);
    try appendBe32(&buf, allocator, 0);

    try buf.appendSlice(allocator, "test"); // lowercase → mandatory
    try appendBe32(&buf, allocator, 8);
    try buf.appendSlice(allocator, "testdata");
    try finishIndex(&buf, allocator);

    var r = Reader.fixed(buf.items);
    var dec = Decoder.init(&r);
    var idx = Index.init(allocator);
    defer idx.deinit();
    try std.testing.expectError(Error.UnknownExtension, dec.decode(&idx));
}

// ---- TestDecodeTruncatedExt ----

test "IndexSuite.TestDecodeTruncatedExt" {
    // go-git TestDecodeTruncatedExt
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, &index.index_signature);
    try appendBe32(&buf, allocator, 2);
    try appendBe32(&buf, allocator, 0);

    try buf.appendSlice(allocator, "TEST");
    try appendBe32(&buf, allocator, 100); // claims 100 bytes
    try buf.appendSlice(allocator, "truncated"); // only 9
    try finishIndex(&buf, allocator);

    var r = Reader.fixed(buf.items);
    var dec = Decoder.init(&r);
    var idx = Index.init(allocator);
    defer idx.deinit();
    try std.testing.expectError(error.EndOfStream, dec.decode(&idx));
}

// ---- TestDecodeInvalidHash ----

test "IndexSuite.TestDecodeInvalidHash" {
    // go-git TestDecodeInvalidHash
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, &index.index_signature);
    try appendBe32(&buf, allocator, 2);
    try appendBe32(&buf, allocator, 0);
    try buf.appendSlice(allocator, "TEST");
    try appendBe32(&buf, allocator, 8);
    try buf.appendSlice(allocator, "testdata");
    // Wrong checksum
    try buf.appendSlice(allocator, &([_]u8{0} ** 20));

    var r = Reader.fixed(buf.items);
    var dec = Decoder.init(&r);
    var idx = Index.init(allocator);
    defer idx.deinit();
    try std.testing.expectError(Error.InvalidChecksum, dec.decode(&idx));
}

// ---- malformed signature / unsupported version ----

test "IndexSuite.TestDecodeMalformedSignature" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "XXXX");
    try appendBe32(&buf, allocator, 2);
    try appendBe32(&buf, allocator, 0);
    try finishIndex(&buf, allocator);

    var r = Reader.fixed(buf.items);
    var dec = Decoder.init(&r);
    var idx = Index.init(allocator);
    defer idx.deinit();
    try std.testing.expectError(Error.MalformedSignature, dec.decode(&idx));
}

test "IndexSuite.TestDecodeUnsupportedVersion" {
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, &index.index_signature);
    try appendBe32(&buf, allocator, 1); // v1 unsupported
    try appendBe32(&buf, allocator, 0);
    try finishIndex(&buf, allocator);

    var r = Reader.fixed(buf.items);
    var dec = Decoder.init(&r);
    var idx = Index.init(allocator);
    defer idx.deinit();
    try std.testing.expectError(Error.UnsupportedVersion, dec.decode(&idx));
}

// ---- TestDecodeV4StripLength ----

test "TestDecodeV4StripLength" {
    // go-git TestDecodeV4StripLength
    const allocator = std.testing.allocator;

    const Case = struct {
        strip: u8,
        first_entry: bool,
        want_err: bool,
    };
    const cases = [_]Case{
        .{ .strip = 3, .first_entry = false, .want_err = false }, // equal name len "abc"
        .{ .strip = 4, .first_entry = false, .want_err = true },
        .{ .strip = 100, .first_entry = false, .want_err = true },
        .{ .strip = 1, .first_entry = true, .want_err = true },
    };

    for (cases) |tc| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);

        try buf.appendSlice(allocator, &index.index_signature);
        try appendBe32(&buf, allocator, 4);
        try appendBe32(&buf, allocator, 2);

        try appendV4Entry(&buf, allocator, "abc", "", plumbing.ZeroHash, 1, false);
        try appendV4Entry(&buf, allocator, "abd", "abc", plumbing.ZeroHash, 2, false);

        // Locate strip varint offsets (same layout as go-git test).
        const hash_size = plumbing.digestSize();
        const entry_fixed = 40 + hash_size + 2;
        const entry1_strip = 12 + entry_fixed;
        const entry1_len = entry_fixed + 1 + 4; // varint(0) + "abc\0"
        const entry2_strip = 12 + entry1_len + entry_fixed;

        const off: usize = if (tc.first_entry) entry1_strip else entry2_strip;
        try std.testing.expect(off < buf.items.len);
        buf.items[off] = tc.strip;

        // Recompute checksum without the old footer; rebuild footer.
        // Current buf still has old footer — strip it first.
        // Actually appendV4Entry path didn't add footer yet... we need finish then patch.
        // Rebuild: content is everything before we call finishIndex.
        // We already have only content (no footer). Patch strip, then finish.
        // Wait — we never called finishIndex. Good.
        try finishIndex(&buf, allocator);

        // But finishIndex hashed after patch... we patched before finish. Good.
        // Re-patch after finish? No — we patched before finishIndex. Correct.

        // Actually look at flow: we patched strip, then finishIndex hashes full content
        // including patched strip. Good.

        var r = Reader.fixed(buf.items);
        var dec = Decoder.init(&r);
        var idx = Index.init(allocator);
        defer idx.deinit();
        if (tc.want_err) {
            try std.testing.expectError(Error.MalformedIndexFile, dec.decode(&idx));
        } else {
            try dec.decode(&idx);
            try std.testing.expectEqual(@as(usize, 2), idx.entries.items.len);
        }
    }
}

// ---- TestDecodeNameLength0xFFF ----

test "TestDecodeNameLength0xFFF" {
    // go-git TestDecodeNameLength0xFFF (subset of lengths)
    const allocator = std.testing.allocator;

    const lengths = [_]usize{ 4094, 4095, 4096, 5000 };
    for (lengths) |name_len| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);

        const name = try allocator.alloc(u8, name_len);
        defer allocator.free(name);
        @memset(name, 'x');

        try buf.appendSlice(allocator, &index.index_signature);
        try appendBe32(&buf, allocator, 2);
        try appendBe32(&buf, allocator, 1);
        try appendV2Entry(&buf, allocator, name, plumbing.ZeroHash, 1, 0, 1, 0, 1, 0, 0o100644);
        try finishIndex(&buf, allocator);

        var idx = try decodeBytes(allocator, buf.items);
        defer idx.deinit();
        try std.testing.expectEqual(@as(usize, 1), idx.entries.items.len);
        try std.testing.expectEqual(name_len, idx.entries.items[0].name.len);
        try std.testing.expectEqualStrings(name, idx.entries.items[0].name);
    }
}

test "TestDecodeNameLength0xFFF long then short" {
    // go-git TestDecodeNameLength0xFFF "long name then short name"
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const long_name = try allocator.alloc(u8, 5000);
    defer allocator.free(long_name);
    @memset(long_name, 'a');

    try buf.appendSlice(allocator, &index.index_signature);
    try appendBe32(&buf, allocator, 2);
    try appendBe32(&buf, allocator, 2);
    try appendV2Entry(&buf, allocator, long_name, plumbing.ZeroHash, 1, 0, 1, 0, 1, 0, 0o100644);
    try appendV2Entry(&buf, allocator, "zzz", plumbing.ZeroHash, 2, 0, 1, 0, 1, 0, 0o100644);
    try finishIndex(&buf, allocator);

    var idx = try decodeBytes(allocator, buf.items);
    defer idx.deinit();
    try std.testing.expectEqual(@as(usize, 2), idx.entries.items.len);
    try std.testing.expectEqual(@as(usize, 5000), idx.entries.items[0].name.len);
    try std.testing.expectEqualStrings("zzz", idx.entries.items[1].name);
}

// ---- TestDecodeNameLength0xFFFPatchedFlags ----

test "TestDecodeNameLength0xFFFPatchedFlags" {
    // go-git TestDecodeNameLength0xFFFPatchedFlags
    const allocator = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, &index.index_signature);
    try appendBe32(&buf, allocator, 2);
    try appendBe32(&buf, allocator, 1);
    try appendV2Entry(&buf, allocator, "hello", plumbing.ZeroHash, 42, 0, 1, 0, 1, 0, 0o100644);

    // Flags at: 12 + 40 + hashSize
    const flags_off = 12 + 40 + plumbing.digestSize();
    const orig_lo = buf.items[flags_off + 1];
    try std.testing.expectEqual(@as(u8, 5), orig_lo); // len("hello")

    // Force lower 12 bits to 0xFFF
    buf.items[flags_off] = (buf.items[flags_off] & 0xF0) | 0x0F;
    buf.items[flags_off + 1] = 0xFF;

    try finishIndex(&buf, allocator);

    var idx = try decodeBytes(allocator, buf.items);
    defer idx.deinit();
    try std.testing.expectEqual(@as(usize, 1), idx.entries.items.len);
    try std.testing.expectEqualStrings("hello", idx.entries.items[0].name);
    try std.testing.expectEqual(@as(u32, 42), idx.entries.items[0].size);
}

test "DecodeVersionSupported range" {
    try std.testing.expectEqual(@as(u32, 2), DecodeVersionSupported.min);
    try std.testing.expectEqual(@as(u32, 4), DecodeVersionSupported.max);
}

// ---- Round-trips via sibling encoder (go-git encode→decode paths) ----

const encoder_mod = @import("encoder.zig");

test "round-trip encode decode V2 multi entry" {
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    idx.version = 2;

    const names = [_][]const u8{ ".gitignore", "CHANGELOG", "LICENSE" };
    for (names, 0..) |n, i| {
        const owned = try allocator.dupe(u8, n);
        try idx.entries.append(allocator, .{
            .name = owned,
            .size = @intCast(i + 1),
            .mode = 0o100644,
            .created_at = Time.unix(1480626693, 498593596),
            .modified_at = Time.unix(1480626693, 498593596),
            .hash = plumbing.newHash("32858aad3c383ed1ff0a0f9bdf231d54a00c9e88"),
        });
    }

    var storage: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&storage);
    var enc = encoder_mod.Encoder.init(&w);
    try enc.encode(&idx);

    var out = try decodeBytes(allocator, w.buffered());
    defer out.deinit();
    try std.testing.expectEqual(@as(u32, 2), out.version);
    try std.testing.expectEqual(@as(usize, 3), out.entries.items.len);
    for (names, 0..) |n, i| {
        try std.testing.expectEqualStrings(n, out.entries.items[i].name);
        try std.testing.expectEqual(@as(u32, @intCast(i + 1)), out.entries.items[i].size);
    }
}

test "round-trip V4 names and intent-to-add" {
    // go-git TestDecodeV4 style via encoder
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    idx.version = 4;

    const names = [_][]const u8{
        ".gitignore", "CHANGELOG", "LICENSE", "binary.jpg", "go/example.go",
        "haskal/haskal.hs", "intent-to-add", "json/long.json",
        "json/short.json", "php/crappy.php", "vendor/foo.go",
    };
    for (names, 0..) |n, i| {
        const owned = try allocator.dupe(u8, n);
        try idx.entries.append(allocator, .{
            .name = owned,
            .size = @intCast(i + 1),
            .intent_to_add = std.mem.eql(u8, n, "intent-to-add"),
            .created_at = Time.unix(1, 0),
            .modified_at = Time.unix(2, 0),
        });
    }

    var storage: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&storage);
    var enc = encoder_mod.Encoder.init(&w);
    try enc.encode(&idx);

    var out = try decodeBytes(allocator, w.buffered());
    defer out.deinit();
    try std.testing.expectEqual(@as(u32, 4), out.version);
    try std.testing.expectEqual(names.len, out.entries.items.len);
    for (names, 0..) |n, i| {
        try std.testing.expectEqualStrings(n, out.entries.items[i].name);
    }
    try std.testing.expect(out.entries.items[6].intent_to_add);
    try std.testing.expect(!out.entries.items[6].skip_worktree);
}

test "round-trip name length 0xFFF via encoder" {
    // go-git TestDecodeNameLength0xFFF
    const allocator = std.testing.allocator;
    const cases = [_]struct { version: u32, len: usize }{
        .{ .version = 2, .len = 4094 },
        .{ .version = 2, .len = 4095 },
        .{ .version = 2, .len = 4096 },
        .{ .version = 2, .len = 5000 },
        .{ .version = 3, .len = 4095 },
    };
    for (cases) |tc| {
        var idx = Index.init(allocator);
        defer idx.deinit();
        idx.version = tc.version;

        const name = try allocator.alloc(u8, tc.len);
        @memset(name, 'x');
        try idx.entries.append(allocator, .{
            .name = name,
            .size = 1,
            .created_at = Time.unix(1, 0),
            .modified_at = Time.unix(2, 0),
        });

        var storage: [16 * 1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&storage);
        var enc = encoder_mod.Encoder.init(&w);
        try enc.encode(&idx);

        var out = try decodeBytes(allocator, w.buffered());
        defer out.deinit();
        try std.testing.expectEqual(@as(usize, 1), out.entries.items.len);
        try std.testing.expectEqual(tc.len, out.entries.items[0].name.len);
    }
}

test "round-trip 0xFFF patched flags via encoder" {
    // go-git TestDecodeNameLength0xFFFPatchedFlags
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    idx.version = 2;

    const name = try allocator.dupe(u8, "hello");
    try idx.entries.append(allocator, .{
        .name = name,
        .size = 42,
        .created_at = Time.unix(1, 0),
        .modified_at = Time.unix(2, 0),
    });

    var storage: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&storage);
    var enc = encoder_mod.Encoder.init(&w);
    try enc.encode(&idx);

    // Copy to mutable buffer for patching.
    var raw = try allocator.dupe(u8, w.buffered());
    defer allocator.free(raw);

    const oid_len = plumbing.digestSize();
    const flags_off = 12 + 40 + oid_len;
    raw[flags_off] = (raw[flags_off] & 0xF0) | 0x0F;
    raw[flags_off + 1] = 0xFF;

    const sum = indexFooter(raw[0 .. raw.len - oid_len]);
    @memcpy(raw[raw.len - oid_len ..], sum.slice());

    var out = try decodeBytes(allocator, raw);
    defer out.deinit();
    try std.testing.expectEqualStrings("hello", out.entries.items[0].name);
    try std.testing.expectEqual(@as(u32, 42), out.entries.items[0].size);
}

test "round-trip optional extension via encodeWithoutFooter" {
    // go-git TestDecodeUnknownOptionalExt
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    idx.version = 2;

    var storage: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&storage);
    var enc = encoder_mod.Encoder.init(&w);
    try enc.encodeWithoutFooter(&idx);
    try enc.encodeRawExtension("TEST", "testdata");
    try enc.encodeFooter();

    var out = try decodeBytes(allocator, w.buffered());
    defer out.deinit();
    try std.testing.expectEqual(@as(u32, 2), out.version);
}

test "round-trip mandatory extension fails" {
    // go-git TestDecodeUnknownMandatoryExt
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    idx.version = 2;

    var storage: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&storage);
    var enc = encoder_mod.Encoder.init(&w);
    try enc.encodeWithoutFooter(&idx);
    try enc.encodeRawExtension("test", "testdata");
    try enc.encodeFooter();

    var r = Reader.fixed(w.buffered());
    var dec = Decoder.init(&r);
    var out = Index.init(allocator);
    defer out.deinit();
    try std.testing.expectError(Error.UnknownExtension, dec.decode(&out));
}

test "SHA-256 index encode decode round-trip one entry" {
    // Dual object-format: 32-byte OIDs and trailer under setObjectFormat(.sha256).
    defer plumbing.setObjectFormat(.sha1);
    plumbing.setObjectFormat(.sha256);

    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    idx.version = 2;

    var oid: [plumbing.MaxSize]u8 = undefined;
    for (&oid, 0..) |*b, i| b.* = @intCast(i);
    const h = Hash.fromBytes(oid[0..32]);

    const name = try allocator.dupe(u8, "sha256-blob");
    try idx.entries.append(allocator, .{
        .name = name,
        .size = 7,
        .mode = 0o100644,
        .hash = h,
        .created_at = Time.unix(1, 0),
        .modified_at = Time.unix(2, 0),
    });

    var storage: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&storage);
    var enc = encoder_mod.Encoder.init(&w);
    try enc.encode(&idx);

    const out_raw = w.buffered();
    const n = plumbing.digestSize();
    try std.testing.expectEqual(@as(usize, 32), n);
    // Trailer is 32 bytes; body hashes to it with SHA-256.
    try std.testing.expect(out_raw.len >= 12 + n);
    var chk = hash_pkg.new(hash_pkg.objectFormat());
    chk.update(out_raw[0 .. out_raw.len - n]);
    var sum: [plumbing.MaxSize]u8 = undefined;
    chk.final(sum[0..n]);
    try std.testing.expectEqualSlices(u8, sum[0..n], out_raw[out_raw.len - n ..]);

    var decoded = try decodeBytes(allocator, out_raw);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 1), decoded.entries.items.len);
    try std.testing.expectEqualStrings("sha256-blob", decoded.entries.items[0].name);
    try std.testing.expect(decoded.entries.items[0].hash.eql(h));
    try std.testing.expectEqual(@as(usize, 32), decoded.entries.items[0].hash.slice().len);
}

// ---- TestDecodeAllIndexFixtures (local fixtures; no go-git-fixtures network) ----

const fixtures_mod = @import("fixtures.zig");

test "TestDecodeAllIndexFixtures" {
    // go-git TestDecodeAllIndexFixtures — want versions {2,3,4} from fixture set.
    // Uses package-local embedded fixtures instead of fixtures.ByTag(".git") network.
    const allocator = std.testing.allocator;

    var want: [5]bool = .{false} ** 5;
    want[2] = true;
    want[3] = true;
    want[4] = true;
    var got: [5]bool = .{false} ** 5;

    for (fixtures_mod.all) |fx| {
        var idx = try decodeBytes(allocator, fx.data);
        defer idx.deinit();

        try std.testing.expectEqual(fx.version, idx.version);
        try std.testing.expect(idx.version >= DecodeVersionSupported.min);
        try std.testing.expect(idx.version <= DecodeVersionSupported.max);
        try std.testing.expect(idx.entries.items.len > 0);
        got[idx.version] = true;

        // Spot-check fixture-specific expectations.
        if (std.mem.eql(u8, fx.name, "v2_simple")) {
            try std.testing.expectEqual(@as(usize, 3), idx.entries.items.len);
            try std.testing.expectEqualStrings(".gitignore", idx.entries.items[0].name);
            try std.testing.expectEqualStrings("CHANGELOG", idx.entries.items[1].name);
            try std.testing.expectEqualStrings("README.md", idx.entries.items[2].name);
            try std.testing.expect(!idx.entries.items[0].intent_to_add);
            try std.testing.expect(!idx.entries.items[0].skip_worktree);
        } else if (std.mem.eql(u8, fx.name, "v3_intent")) {
            try std.testing.expectEqual(@as(usize, 4), idx.entries.items.len);
            // Sorted: a.txt, intent-to-add, skip-me, z-both
            try std.testing.expectEqualStrings("intent-to-add", idx.entries.items[1].name);
            try std.testing.expect(idx.entries.items[1].intent_to_add);
            try std.testing.expect(!idx.entries.items[1].skip_worktree);
            try std.testing.expectEqualStrings("skip-me", idx.entries.items[2].name);
            try std.testing.expect(idx.entries.items[2].skip_worktree);
            try std.testing.expect(idx.entries.items[3].intent_to_add);
            try std.testing.expect(idx.entries.items[3].skip_worktree);
        } else if (std.mem.eql(u8, fx.name, "v4_prefix")) {
            try std.testing.expectEqual(@as(usize, 7), idx.entries.items.len);
            try std.testing.expectEqualStrings(".gitignore", idx.entries.items[0].name);
            try std.testing.expectEqualStrings("src/bar.go", idx.entries.items[1].name);
            try std.testing.expectEqualStrings("src/bar/baz.go", idx.entries.items[2].name);
            try std.testing.expectEqualStrings("vendor/foo/bar.go", idx.entries.items[6].name);
        }
    }

    // Every of versions {2,3,4} appears (mirrors go-git want map).
    try std.testing.expectEqualSlices(bool, &want, &got);
}

test "TestDecodeAllIndexFixtures data accessors" {
    // Same fixture set via packfile-style data() helpers.
    const allocator = std.testing.allocator;
    const cases = [_]struct { name: []const u8, version: u32, data: *const fn () []const u8 }{
        .{ .name = "v2_simple", .version = 2, .data = fixtures_mod.v2_simple },
        .{ .name = "v3_intent", .version = 3, .data = fixtures_mod.v3_intent },
        .{ .name = "v4_prefix", .version = 4, .data = fixtures_mod.v4_prefix },
    };
    var got: [5]bool = .{false} ** 5;
    for (cases) |c| {
        const raw = c.data();
        var idx = try decodeBytes(allocator, raw);
        defer idx.deinit();
        try std.testing.expectEqual(c.version, idx.version);
        got[idx.version] = true;
    }
    try std.testing.expect(got[2] and got[3] and got[4]);
}

test "decoder rejects oversized extension before allocation" {
    const allocator = std.testing.allocator;
    var raw: [4 + 4 + 4 + 4 + 4 + plumbing.MaxSize]u8 = .{0} ** (4 + 4 + 4 + 4 + 4 + plumbing.MaxSize);
    @memcpy(raw[0..4], &index.index_signature);
    std.mem.writeInt(u32, raw[4..8], 2, .big);
    std.mem.writeInt(u32, raw[8..12], 0, .big);
    @memcpy(raw[12..16], "ABCD");
    std.mem.writeInt(u32, raw[16..20], max_extension_bytes + 1, .big);

    var reader = Reader.fixed(raw[0 .. 20 + plumbing.digestSize()]);
    var decoder = Decoder.init(&reader);
    var idx = Index.init(allocator);
    defer idx.deinit();
    try std.testing.expectError(Error.MalformedIndexFile, decoder.decode(&idx));
}
