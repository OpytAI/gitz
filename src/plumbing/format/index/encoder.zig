//! Index encoder — port of go-git v5.19.2 `plumbing/format/index/encoder.go`.
//!
//! Writes a Git index (dircache) to an output stream: header, sorted entries
//! (v2/v3/v4 names), optional TREE/REUC/EOIE extensions, and SHA-1 footer.
//!
//! go-git `Encode` currently has a TODO for extensions; this port writes
//! `cache` / `resolve_undo` / `end_of_index_entry` when set on the Index so
//! encode/decode can round-trip the extensions the decoder already understands.

const std = @import("std");
const plumbing = @import("plumbing");
const hash_pkg = @import("hash");
const binary = @import("binary");

const index_mod = @import("index.zig");
const err_mod = @import("error.zig");

const Writer = std.Io.Writer;
const Index = index_mod.Index;
const Entry = index_mod.Entry;
const Tree = index_mod.Tree;
const ResolveUndo = index_mod.ResolveUndo;
const ResolveUndoEntry = index_mod.ResolveUndoEntry;
const EndOfIndexEntry = index_mod.EndOfIndexEntry;
const Time = index_mod.Time;
const Stage = index_mod.Stage;
const Error = err_mod.Error;

// ---------------------------------------------------------------------------
// Wire constants (go-git decoder.go / encoder.go)
// ---------------------------------------------------------------------------

/// Highest index version this encoder accepts (go-git `EncodeVersionSupported uint32 = 4`).
/// go-git comments call this a “range”; the value is the maximum only (min is not gated).
pub const encode_version_supported: u32 = 4;
/// go-git exported name for `encode_version_supported`.
pub const EncodeVersionSupported = encode_version_supported;

/// Fixed entry header before path: 10×u32 + OID + flags (go-git `entryHeaderLength`).
/// OID width follows the active object format (20 SHA-1 / 32 SHA-256).
fn entryHeaderLength() usize {
    return 40 + plumbing.digestSize() + 2;
}
/// Flags bit: extended 16-bit flags follow (go-git `entryExtended`).
const entry_extended: u16 = 0x4000;
/// 12-bit name-length field mask; 0xFFF means “scan for NUL” (go-git `nameMask`).
const name_mask: u16 = 0xfff;
/// Extended-flags bit: intent-to-add (go-git `intentToAddMask`).
const intent_to_add_mask: u16 = 1 << 13;
/// Extended-flags bit: skip-worktree (go-git `skipWorkTreeMask`).
const skip_work_tree_mask: u16 = 1 << 14;

pub const EncodeError = Error || Writer.Error;

/// Writes an Index to an output stream (go-git `Encoder`).
///
/// Construct with `init`. One encode finalises the running SHA-1; create a new
/// Encoder for each index file.
pub const Encoder = struct {
    writer: *Writer,
    hasher: hash_pkg.Hasher,
    last_entry: ?*const Entry = null,
    /// Total bytes written into the stream (and hashed), excluding the footer.
    bytes_written: usize = 0,

    /// go-git `NewEncoder`.
    pub fn init(writer: *Writer) Encoder {
        return .{
            .writer = writer,
            .hasher = hash_pkg.new(hash_pkg.objectFormat()),
        };
    }

    /// Encode `idx` with footer (go-git `Encode`).
    pub fn encode(self: *Encoder, idx: *Index) EncodeError!void {
        return self.encodeInner(idx, true);
    }

    /// Encode header + entries + extensions without the SHA-1 trailer.
    /// Used by tests that append raw extensions, then call `encodeFooter`.
    /// go-git unexported `encode(idx, false)`.
    pub fn encodeWithoutFooter(self: *Encoder, idx: *Index) EncodeError!void {
        return self.encodeInner(idx, false);
    }

    fn encodeInner(self: *Encoder, idx: *Index, footer: bool) EncodeError!void {
        // go-git: TODO support extensions — we write known extensions when set.
        if (idx.version > encode_version_supported) {
            return Error.UnsupportedVersion;
        }

        self.last_entry = null;

        try self.encodeHeader(idx);
        try self.encodeEntries(idx);
        try self.encodeExtensions(idx);

        if (footer) {
            try self.encodeFooter();
        }
    }

    fn encodeHeader(self: *Encoder, idx: *const Index) Writer.Error!void {
        try self.writeAll(&index_mod.index_signature);
        try self.writeUint32(idx.version);
        try self.writeUint32(@intCast(idx.entries.items.len));
    }

    fn encodeEntries(self: *Encoder, idx: *Index) EncodeError!void {
        // go-git `sort.Sort(byName(idx.Entries))` — name only, ascending bytes.
        std.mem.sort(Entry, idx.entries.items, {}, entryNameLess);

        for (idx.entries.items) |*entry| {
            try self.encodeEntry(idx, entry);

            var entry_length: usize = entryHeaderLength();
            if (entry.intent_to_add or entry.skip_worktree) {
                entry_length += 2;
            }
            const wrote = entry_length + entry.name.len;
            try self.padEntry(idx, wrote);
        }
    }

    fn encodeEntry(self: *Encoder, idx: *const Index, entry: *const Entry) EncodeError!void {
        const c = try timeToUint32(entry.created_at);
        const m = try timeToUint32(entry.modified_at);

        var flags: u16 = @as(u16, @intCast(entry.stage & 0x3)) << 12;
        if (entry.name.len < name_mask) {
            flags |= @intCast(entry.name.len);
        } else {
            flags |= name_mask;
        }

        try self.writeUint32(c.sec);
        try self.writeUint32(c.nsec);
        try self.writeUint32(m.sec);
        try self.writeUint32(m.nsec);
        try self.writeUint32(entry.dev);
        try self.writeUint32(entry.inode);
        try self.writeUint32(entry.mode);
        try self.writeUint32(entry.uid);
        try self.writeUint32(entry.gid);
        try self.writeUint32(entry.size);
        try self.writeAll(entry.hash.slice());

        if (entry.intent_to_add or entry.skip_worktree) {
            var extended_flags: u16 = 0;
            if (entry.intent_to_add) extended_flags |= intent_to_add_mask;
            if (entry.skip_worktree) extended_flags |= skip_work_tree_mask;
            try self.writeUint16(flags | entry_extended);
            try self.writeUint16(extended_flags);
        } else {
            try self.writeUint16(flags);
        }

        switch (idx.version) {
            2, 3 => try self.encodeEntryName(entry),
            4 => try self.encodeEntryNameV4(entry),
            else => return Error.UnsupportedVersion,
        }
    }

    fn encodeEntryName(self: *Encoder, entry: *const Entry) Writer.Error!void {
        try self.writeAll(entry.name);
    }

    fn encodeEntryNameV4(self: *Encoder, entry: *const Entry) Writer.Error!void {
        // V4 prefix compression: strip common prefix with previous name, then
        // write varint(strip_len) + suffix + NUL.
        var prefix: usize = 0;
        var strip_len: usize = 0;
        if (self.last_entry) |prev| {
            prefix = commonPrefixLen(prev.name, entry.name);
            strip_len = prev.name.len - prefix;
        }
        self.last_entry = entry;

        // Buffer VLQ then writeAll so it is hashed and counted once.
        var vlq_buf: [16]u8 = undefined;
        var vw: Writer = .fixed(&vlq_buf);
        try binary.writeVariableWidthInt(&vw, @intCast(strip_len));
        try self.writeAll(vw.buffered());

        const suffix = entry.name[prefix..];
        try self.writeAll(suffix);
        try self.writeAll(&[_]u8{0});
    }

    /// Write a raw extension block (go-git `encodeRawExtension`).
    /// `signature` must be exactly 4 bytes.
    pub fn encodeRawExtension(self: *Encoder, signature: *const [4]u8, data: []const u8) Writer.Error!void {
        try self.writeAll(signature[0..]);
        try self.writeUint32(@intCast(data.len));
        try self.writeAll(data);
    }

    fn encodeExtensions(self: *Encoder, idx: *const Index) Writer.Error!void {
        // Offset to the first extension = end of entries (EOIE.Offset).
        const entries_end: u32 = @intCast(self.bytes_written);

        // EOIE hash covers extension types + sizes (not payloads) of extensions
        // that precede EOIE.
        var eoie_hasher = hash_pkg.new(hash_pkg.objectFormat());

        if (idx.cache) |cache| {
            try self.encodeTreeExtension(cache, &eoie_hasher);
        }
        if (idx.resolve_undo) |ru| {
            try self.encodeResolveUndoExtension(ru, &eoie_hasher);
        }
        if (idx.end_of_index_entry) |eoie| {
            // Prefer a computed offset when the stored one is zero (fresh encode).
            const offset: u32 = if (eoie.offset != 0) eoie.offset else entries_end;
            var hash = eoie.hash;
            if (hash.isZero()) {
                var sum: [hash_pkg.MaxSize]u8 = .{0} ** hash_pkg.MaxSize;
                const n = eoie_hasher.digestSize();
                eoie_hasher.final(sum[0..n]);
                hash = plumbing.Hash.fromBytes(sum[0..n]);
            }
            try self.encodeEndOfIndexEntry(offset, hash);
        }
    }

    fn encodeTreeExtension(self: *Encoder, tree: *const Tree, eoie_hasher: *hash_pkg.Hasher) Writer.Error!void {
        const payload_len = treePayloadSize(tree);
        try self.writeExtensionHeader(&index_mod.tree_ext_signature, payload_len, eoie_hasher);

        for (tree.entries.items) |*te| {
            try self.writeAll(te.path);
            try self.writeAll(&[_]u8{0});

            var num_buf: [24]u8 = undefined;
            const entries_s = std.fmt.bufPrint(&num_buf, "{d}", .{te.entries}) catch unreachable;
            try self.writeAll(entries_s);
            try self.writeAll(" ");

            var trees_buf: [24]u8 = undefined;
            const trees_s = std.fmt.bufPrint(&trees_buf, "{d}", .{te.trees}) catch unreachable;
            try self.writeAll(trees_s);
            try self.writeAll("\n");

            // Invalidated entry (negative entry count): no object name.
            if (te.entries >= 0) {
                try self.writeAll(te.hash.slice());
            }
        }
    }

    fn encodeResolveUndoExtension(self: *Encoder, ru: *const ResolveUndo, eoie_hasher: *hash_pkg.Hasher) Writer.Error!void {
        const payload_len = resolveUndoPayloadSize(ru);
        try self.writeExtensionHeader(&index_mod.resolve_undo_ext_signature, payload_len, eoie_hasher);

        for (ru.entries.items) |*e| {
            try self.writeAll(e.path);
            try self.writeAll(&[_]u8{0});

            // Three NUL-terminated octal modes for stages 1..3 ("0" = missing).
            var s: Stage = 1;
            while (s <= 3) : (s += 1) {
                if (e.getStage(s) != null) {
                    // Mode is not retained on the in-memory type; any non-zero
                    // octal marks the stage present (decoder only checks != 0).
                    try self.writeAll("100644");
                } else {
                    try self.writeAll("0");
                }
                try self.writeAll(&[_]u8{0});
            }

            // Hashes for present stages in order 1..3.
            s = 1;
            while (s <= 3) : (s += 1) {
                if (e.getStage(s)) |h| {
                    try self.writeAll(h.slice());
                }
            }
        }
    }

    fn encodeEndOfIndexEntry(self: *Encoder, offset: u32, hash: plumbing.Hash) Writer.Error!void {
        // EOIE is last; its type/size are not included in its own hash.
        try self.writeAll(&index_mod.end_of_index_entry_ext_signature);
        // payload = offset (4) + active OID
        try self.writeUint32(@intCast(4 + plumbing.digestSize()));
        try self.writeUint32(offset);
        try self.writeAll(hash.slice());
    }

    fn writeExtensionHeader(
        self: *Encoder,
        signature: *const [4]u8,
        payload_len: u32,
        eoie_hasher: *hash_pkg.Hasher,
    ) Writer.Error!void {
        try self.writeAll(signature[0..]);
        try self.writeUint32(payload_len);

        // EOIE hash material: signature + big-endian size (not payload).
        eoie_hasher.update(signature[0..]);
        var size_be: [4]u8 = undefined;
        std.mem.writeInt(u32, &size_be, payload_len, .big);
        eoie_hasher.update(&size_be);
    }

    /// Trailing digest over all bytes written so far (go-git `encodeFooter`).
    pub fn encodeFooter(self: *Encoder) Writer.Error!void {
        var sum: [hash_pkg.MaxSize]u8 = undefined;
        const n = self.hasher.digestSize();
        self.hasher.final(sum[0..n]);
        // Footer itself is not hashed.
        try self.writer.writeAll(sum[0..n]);
    }

    fn padEntry(self: *Encoder, idx: *const Index, wrote: usize) Writer.Error!void {
        if (idx.version == 4) return;

        // Always 1..8 NUL bytes so the name is NUL-terminated and the entry
        // size is a multiple of 8 (go-git `padEntry`).
        const pad_len = 8 - (wrote % 8);
        const zeros = [_]u8{0} ** 8;
        try self.writeAll(zeros[0..pad_len]);
    }

    fn writeAll(self: *Encoder, data: []const u8) Writer.Error!void {
        try self.writer.writeAll(data);
        self.hasher.update(data);
        self.bytes_written += data.len;
    }

    fn writeUint32(self: *Encoder, value: u32) Writer.Error!void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .big);
        try self.writeAll(&buf);
    }

    fn writeUint16(self: *Encoder, value: u16) Writer.Error!void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, value, .big);
        try self.writeAll(&buf);
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn entryNameLess(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// go-git `timeToUint32`.
fn timeToUint32(t: Time) Error!struct { sec: u32, nsec: u32 } {
    if (t.isZero()) return .{ .sec = 0, .nsec = 0 };
    if (t.sec < 0 or t.nsec < 0) return Error.InvalidTimestamp;
    return .{
        .sec = @intCast(t.sec),
        .nsec = @intCast(t.nsec),
    };
}

/// Longest common byte prefix length (go-git `commonPrefixLen`).
fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return i;
    }
    return n;
}

fn treePayloadSize(tree: *const Tree) u32 {
    var n: usize = 0;
    for (tree.entries.items) |*te| {
        n += te.path.len + 1; // path + NUL
        n += decimalLen(te.entries) + 1; // count + space
        n += decimalLen(te.trees) + 1; // trees + newline
        if (te.entries >= 0) n += plumbing.digestSize();
    }
    return @intCast(n);
}

fn resolveUndoPayloadSize(ru: *const ResolveUndo) u32 {
    var n: usize = 0;
    const oid_len = plumbing.digestSize();
    for (ru.entries.items) |*e| {
        n += e.path.len + 1;
        var s: Stage = 1;
        while (s <= 3) : (s += 1) {
            if (e.getStage(s) != null) {
                n += 6 + 1; // "100644" + NUL
            } else {
                n += 1 + 1; // "0" + NUL
            }
        }
        s = 1;
        while (s <= 3) : (s += 1) {
            if (e.getStage(s) != null) n += oid_len;
        }
    }
    return @intCast(n);
}

fn decimalLen(v: i32) usize {
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    return s.len;
}

// ---------------------------------------------------------------------------
// Tests — map from go-git encoder_test.go
// ---------------------------------------------------------------------------

test "IndexSuite.TestEncodeUnsupportedVersion" {
    // go-git IndexSuite.TestEncodeUnsupportedVersion
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    idx.version = 5;

    var storage: [64]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var e = Encoder.init(&w);
    try std.testing.expectError(Error.UnsupportedVersion, e.encode(&idx));
}

test "IndexSuite.TestEncode" {
    // go-git IndexSuite.TestEncode — sort order after round-trip
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    idx.version = 2;

    const n_foo = try allocator.dupe(u8, "foo");
    try idx.entries.append(allocator, .{
        .name = n_foo,
        .size = 42,
        .stage = index_mod.TheirMode,
        .hash = plumbing.newHash("e25b29c8946e0e192fae2edc1dabf7be71e8ecf3"),
        .dev = 4242,
        .inode = 424242,
        .uid = 84,
        .gid = 8484,
        .created_at = Time.unix(1_700_000_000, 123),
        .modified_at = Time.unix(1_700_000_001, 456),
    });
    const n_bar = try allocator.dupe(u8, "bar");
    try idx.entries.append(allocator, .{
        .name = n_bar,
        .size = 82,
        .created_at = Time.unix(1_700_000_000, 0),
        .modified_at = Time.unix(1_700_000_001, 0),
    });
    const spaces = try allocator.alloc(u8, 20);
    @memset(spaces, ' ');
    try idx.entries.append(allocator, .{
        .name = spaces,
        .size = 82,
        .created_at = Time.unix(1_700_000_000, 0),
        .modified_at = Time.unix(1_700_000_001, 0),
    });

    var storage: [4096]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var enc = Encoder.init(&w);
    try enc.encode(&idx);

    // Sorted in-place by name: " "*20, "bar", "foo"
    try std.testing.expectEqualStrings(spaces, idx.entries.items[0].name);
    try std.testing.expectEqualStrings("bar", idx.entries.items[1].name);
    try std.testing.expectEqualStrings("foo", idx.entries.items[2].name);

    const out = w.buffered();
    // Header
    try std.testing.expectEqualSlices(u8, "DIRC", out[0..4]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, out[4..8], .big));
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, out[8..12], .big));
    // Trailer present (active digest size; default SHA-1 → 20)
    const n = plumbing.digestSize();
    try std.testing.expect(out.len >= 12 + n);
    var h = hash_pkg.new(hash_pkg.objectFormat());
    h.update(out[0 .. out.len - n]);
    var sum: [hash_pkg.MaxSize]u8 = undefined;
    h.final(sum[0..n]);
    try std.testing.expectEqualSlices(u8, sum[0..n], out[out.len - n ..]);
}

test "TestEncodeLongName" {
    // go-git TestEncodeLongName — name length ≥ 4095 sets flags name field to 0xFFF
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    idx.version = 2;

    const long_name = try allocator.alloc(u8, 5000);
    @memset(long_name, 'a');
    try idx.entries.append(allocator, .{
        .name = long_name,
        .size = 1,
        .created_at = Time.unix(10, 0),
        .modified_at = Time.unix(11, 0),
    });
    const short = try allocator.dupe(u8, "short");
    try idx.entries.append(allocator, .{
        .name = short,
        .size = 2,
        .created_at = Time.unix(10, 0),
        .modified_at = Time.unix(11, 0),
    });

    var storage: [16 * 1024]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var enc = Encoder.init(&w);
    try enc.encode(&idx);

    const out = w.buffered();
    try std.testing.expectEqualSlices(u8, "DIRC", out[0..4]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, out[4..8], .big));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, out[8..12], .big));

    // First entry after sort is the long name ("a"*5000 < "short").
    // Flags sit at end of fixed header (after 10×u32 + OID).
    const flags_off = 12 + entryHeaderLength() - 2;
    const flags = std.mem.readInt(u16, out[flags_off..][0..2], .big);
    try std.testing.expectEqual(@as(u16, name_mask), flags & name_mask);

    // Name bytes follow flags
    try std.testing.expectEqualSlices(u8, long_name[0..16], out[flags_off + 2 ..][0..16]);
}

test "TestEncodeV4" {
    // go-git TestEncodeV4 — deterministic names with shared prefixes
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    idx.version = 4;

    const names = [_][]const u8{ "foo", "bar", "baz/bar", "baz/bar/bar" };
    for (names) |n| {
        const owned = try allocator.dupe(u8, n);
        try idx.entries.append(allocator, .{
            .name = owned,
            .size = 82,
            .created_at = Time.unix(1, 0),
            .modified_at = Time.unix(2, 0),
        });
    }

    var storage: [4096]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var enc = Encoder.init(&w);
    try enc.encode(&idx);

    // Sorted: bar, baz/bar, baz/bar/bar, foo
    try std.testing.expectEqualStrings("bar", idx.entries.items[0].name);
    try std.testing.expectEqualStrings("baz/bar", idx.entries.items[1].name);
    try std.testing.expectEqualStrings("baz/bar/bar", idx.entries.items[2].name);
    try std.testing.expectEqualStrings("foo", idx.entries.items[3].name);

    const out = w.buffered();
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, out[4..8], .big));
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, out[8..12], .big));

    // First v4 entry name starts after header(12) + fixed fields(entryHeaderLength):
    // strip_len varint 0, then "bar\0"
    const name0 = out[12 + entryHeaderLength() ..];
    try std.testing.expectEqual(@as(u8, 0), name0[0]); // strip 0
    try std.testing.expectEqualSlices(u8, "bar\x00", name0[1..5]);
}

test "IndexSuite.TestEncodeWithIntentToAdd" {
    // go-git IndexSuite.TestEncodeWithIntentToAddUnsupportedVersion
    // Despite the go-git name, this is a successful v3 encode/decode of IntentToAdd
    // (not an UnsupportedVersion error). Extended flags are written when the bit is
    // set; go-git does not auto-bump version 2 → 3.
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    idx.version = 3;

    const n = try allocator.dupe(u8, "x");
    try idx.entries.append(allocator, .{
        .name = n,
        .intent_to_add = true,
    });

    var storage: [512]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var enc = Encoder.init(&w);
    try enc.encode(&idx);

    const out = w.buffered();
    // flags at end of fixed header (before name)
    const flags_off = 12 + entryHeaderLength() - 2;
    const flags = std.mem.readInt(u16, out[flags_off..][0..2], .big);
    try std.testing.expect((flags & entry_extended) != 0);
    try std.testing.expectEqual(@as(u16, 1), flags & name_mask);
    const ext = std.mem.readInt(u16, out[flags_off + 2 ..][0..2], .big);
    try std.testing.expect((ext & intent_to_add_mask) != 0);
    try std.testing.expect((ext & skip_work_tree_mask) == 0);

    // Full round-trip like go-git (decode and assert IntentToAdd).
    const decoder_mod = @import("decoder.zig");
    var r: std.Io.Reader = .fixed(out);
    var dec = decoder_mod.Decoder.init(&r);
    var out_idx = Index.init(allocator);
    defer out_idx.deinit();
    try dec.decode(&out_idx);
    try std.testing.expectEqual(@as(u32, 3), out_idx.version);
    try std.testing.expectEqual(@as(usize, 1), out_idx.entries.items.len);
    try std.testing.expect(out_idx.entries.items[0].intent_to_add);
    try std.testing.expect(!out_idx.entries.items[0].skip_worktree);
}

test "IndexSuite.TestEncodeWithSkipWorktree" {
    // go-git IndexSuite.TestEncodeWithSkipWorktreeUnsupportedVersion
    // Same naming quirk as IntentToAdd: successful v3 round-trip of SkipWorktree.
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    idx.version = 3;

    const n = try allocator.dupe(u8, "y");
    try idx.entries.append(allocator, .{
        .name = n,
        .skip_worktree = true,
    });

    var storage: [512]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var enc = Encoder.init(&w);
    try enc.encode(&idx);

    const out = w.buffered();
    const flags_off = 12 + entryHeaderLength() - 2;
    const flags = std.mem.readInt(u16, out[flags_off..][0..2], .big);
    try std.testing.expect((flags & entry_extended) != 0);
    const ext = std.mem.readInt(u16, out[flags_off + 2 ..][0..2], .big);
    try std.testing.expect((ext & skip_work_tree_mask) != 0);
    try std.testing.expect((ext & intent_to_add_mask) == 0);

    const decoder_mod = @import("decoder.zig");
    var r: std.Io.Reader = .fixed(out);
    var dec = decoder_mod.Decoder.init(&r);
    var out_idx = Index.init(allocator);
    defer out_idx.deinit();
    try dec.decode(&out_idx);
    try std.testing.expectEqual(@as(u32, 3), out_idx.version);
    try std.testing.expectEqual(@as(usize, 1), out_idx.entries.items.len);
    try std.testing.expect(out_idx.entries.items[0].skip_worktree);
    try std.testing.expect(!out_idx.entries.items[0].intent_to_add);
}

test "IndexSuite.TestEncodeInvalidTimestamp" {
    // go-git ErrInvalidTimestamp
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    idx.version = 2;

    const n = try allocator.dupe(u8, "z");
    try idx.entries.append(allocator, .{
        .name = n,
        .created_at = .{ .sec = -1, .nsec = 0 },
    });

    var storage: [256]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var enc = Encoder.init(&w);
    try std.testing.expectError(Error.InvalidTimestamp, enc.encode(&idx));
}

test "IndexSuite.TestEncodeTREEAndEOIE" {
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    idx.version = 2;

    // Empty entries → header only before extensions
    const tree = try allocator.create(Tree);
    tree.* = .{};
    const te_path = try allocator.dupe(u8, "");
    try tree.entries.append(allocator, .{
        .path = te_path,
        .entries = 0,
        .trees = 0,
        .hash = plumbing.newHash("e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"),
    });
    idx.cache = tree;

    const eoie = try allocator.create(EndOfIndexEntry);
    eoie.* = .{}; // offset/hash filled by encoder
    idx.end_of_index_entry = eoie;

    var storage: [1024]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var enc = Encoder.init(&w);
    try enc.encode(&idx);

    const out = w.buffered();
    // After header (12): TREE signature
    try std.testing.expectEqualSlices(u8, "TREE", out[12..16]);
    // Find EOIE
    const eoie_pos = std.mem.indexOf(u8, out, "EOIE") orelse {
        try std.testing.expect(false); // must contain EOIE
        return;
    };
    try std.testing.expectEqual(@as(u8, 'E'), out[eoie_pos]);
    // Offset field = 12 (end of header / entries for empty index)
    const eoie_payload = out[eoie_pos + 8 ..];
    const offset = std.mem.readInt(u32, eoie_payload[0..4], .big);
    try std.testing.expectEqual(@as(u32, 12), offset);

    // Footer checksum
    const n = plumbing.digestSize();
    var h = hash_pkg.new(hash_pkg.objectFormat());
    h.update(out[0 .. out.len - n]);
    var sum: [hash_pkg.MaxSize]u8 = undefined;
    h.final(sum[0..n]);
    try std.testing.expectEqualSlices(u8, sum[0..n], out[out.len - n ..]);
}

test "IndexSuite.TestEncodeWithoutFooterRawExt" {
    // go-git buildIndexWithExtension pattern
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    idx.version = 2;

    var storage: [512]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var enc = Encoder.init(&w);
    try enc.encodeWithoutFooter(&idx);
    try enc.encodeRawExtension("TEST", "testdata");
    try enc.encodeFooter();

    const out = w.buffered();
    try std.testing.expectEqualSlices(u8, "DIRC", out[0..4]);
    try std.testing.expect(std.mem.indexOf(u8, out, "TEST") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "testdata") != null);

    const digest_n = plumbing.digestSize();
    var h = hash_pkg.new(hash_pkg.objectFormat());
    h.update(out[0 .. out.len - digest_n]);
    var sum: [hash_pkg.MaxSize]u8 = undefined;
    h.final(sum[0..digest_n]);
    try std.testing.expectEqualSlices(u8, sum[0..digest_n], out[out.len - digest_n ..]);
}

test "IndexSuite.TestEncodeV2Padding" {
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    idx.version = 2;

    const name = try allocator.dupe(u8, "ab"); // len 2 → wrote multiple of 8 after pad
    try idx.entries.append(allocator, .{ .name = name });

    var storage: [256]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var enc = Encoder.init(&w);
    try enc.encode(&idx);

    const out = w.buffered();
    // body without footer must be 12 + multiple-of-8 entry
    const body_len = out.len - plumbing.digestSize();
    try std.testing.expectEqual(@as(usize, 0), (body_len - 12) % 8);
}

test "commonPrefixLen" {
    try std.testing.expectEqual(@as(usize, 0), commonPrefixLen("", "a"));
    try std.testing.expectEqual(@as(usize, 2), commonPrefixLen("abc", "abd"));
    try std.testing.expectEqual(@as(usize, 3), commonPrefixLen("abc", "abc"));
    try std.testing.expectEqual(@as(usize, 4), commonPrefixLen("baz/", "baz/bar"));
}

test "EncodeVersionSupported is 4" {
    try std.testing.expectEqual(@as(u32, 4), encode_version_supported);
    try std.testing.expectEqual(encode_version_supported, EncodeVersionSupported);
}

test "encode merge conflict stages round-trip stage flags" {
    // Stage bits live in flags>>12; decoder TestDecodeMergeConflict covers
    // synthetic decode; this exercises the encoder path + round-trip.
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    idx.version = 2;

    const h1 = plumbing.newHash("880cd14280f4b9b6ed3986d6671f907d7cc2a198");
    const h2 = plumbing.newHash("d499a1a0b79b7d87a35155afd0c1cce78b37a91c");
    const h3 = plumbing.newHash("14f8e368114f561c38e134f6e68ea6fea12d77ed");
    // Distinct names so go-git byName sort (name-only, unstable on ties) is not
    // an issue; stages still exercise flags packing.
    const stages = [_]struct { name: []const u8, stage: Stage, hash: plumbing.Hash }{
        .{ .name = "a", .stage = index_mod.AncestorMode, .hash = h1 },
        .{ .name = "b", .stage = index_mod.OurMode, .hash = h2 },
        .{ .name = "c", .stage = index_mod.TheirMode, .hash = h3 },
    };
    for (stages) |s| {
        const owned = try allocator.dupe(u8, s.name);
        try idx.entries.append(allocator, .{
            .name = owned,
            .stage = s.stage,
            .hash = s.hash,
            .mode = 0o100644,
        });
    }

    var storage: [1024]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var enc = Encoder.init(&w);
    try enc.encode(&idx);

    const decoder_mod = @import("decoder.zig");
    var r: std.Io.Reader = .fixed(w.buffered());
    var dec = decoder_mod.Decoder.init(&r);
    var out = Index.init(allocator);
    defer out.deinit();
    try dec.decode(&out);

    try std.testing.expectEqual(@as(usize, 3), out.entries.items.len);
    try std.testing.expectEqual(index_mod.AncestorMode, (try out.entry("a")).stage);
    try std.testing.expectEqual(index_mod.OurMode, (try out.entry("b")).stage);
    try std.testing.expectEqual(index_mod.TheirMode, (try out.entry("c")).stage);
    try std.testing.expect((try out.entry("a")).hash.eql(h1));
    try std.testing.expect((try out.entry("b")).hash.eql(h2));
    try std.testing.expect((try out.entry("c")).hash.eql(h3));
}

test "encode REUC resolve undo round-trip" {
    // Encoder writes REUC (beyond go-git Encode TODO); decoder already covers
    // synthetic REUC. Round-trip exercises encodeResolveUndoExtension payload.
    const allocator = std.testing.allocator;
    var idx = Index.init(allocator);
    defer idx.deinit();
    idx.version = 2;

    const ru = try allocator.create(ResolveUndo);
    ru.* = .{};
    idx.resolve_undo = ru;

    const path = try allocator.dupe(u8, "go/example.go");
    var e = ResolveUndoEntry{ .path = path };
    const ha = plumbing.newHash("1111111111111111111111111111111111111111");
    const hb = plumbing.newHash("2222222222222222222222222222222222222222");
    const hc = plumbing.newHash("3333333333333333333333333333333333333333");
    e.setStage(1, ha);
    e.setStage(2, hb);
    e.setStage(3, hc);
    try ru.entries.append(allocator, e);

    var storage: [512]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var enc = Encoder.init(&w);
    try enc.encode(&idx);

    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "REUC") != null);

    const decoder_mod = @import("decoder.zig");
    var r: std.Io.Reader = .fixed(out);
    var dec = decoder_mod.Decoder.init(&r);
    var decoded = Index.init(allocator);
    defer decoded.deinit();
    try dec.decode(&decoded);

    try std.testing.expect(decoded.resolve_undo != null);
    const dru = decoded.resolve_undo.?;
    try std.testing.expectEqual(@as(usize, 1), dru.entries.items.len);
    try std.testing.expectEqualStrings("go/example.go", dru.entries.items[0].path);
    try std.testing.expect(dru.entries.items[0].getStage(1).?.eql(ha));
    try std.testing.expect(dru.entries.items[0].getStage(2).?.eql(hb));
    try std.testing.expect(dru.entries.items[0].getStage(3).?.eql(hc));
}
