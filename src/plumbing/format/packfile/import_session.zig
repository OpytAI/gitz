//! Bounded incremental pack-input lifecycle.
//!
//! Chunks are retained up to the caller's explicit cap. `finish` consumes them
//! through the parser's non-seekable reader and releases each raw chunk as it
//! advances. The parser writes directly into the supplied object sink, so the
//! complete pack and complete decoded repository do not remain live together.

const std = @import("std");
const plumbing = @import("plumbing");
const parser_mod = @import("parser.zig");
const scanner_mod = @import("scanner.zig");

const Allocator = std.mem.Allocator;
const IoReader = std.Io.Reader;
const IoWriter = std.Io.Writer;
const Limit = std.Io.Limit;

pub const ImportLimits = struct {
    max_pack_bytes: usize,
    max_objects: u32,
};

pub const ImportSession = struct {
    allocator: Allocator,
    limits: ImportLimits,
    chunks: std.ArrayListUnmanaged([]u8) = .empty,
    byte_count: usize = 0,
    header_bytes: [12]u8 = undefined,
    header_len: usize = 0,
    finished: bool = false,

    pub fn init(allocator: Allocator, limits: ImportLimits) ImportSession {
        return .{ .allocator = allocator, .limits = limits };
    }

    pub fn deinit(self: *ImportSession) void {
        self.freeChunks();
        self.chunks.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn write(self: *ImportSession, chunk: []const u8) !void {
        if (self.finished) return error.ImportFinished;
        if (chunk.len > self.limits.max_pack_bytes -| self.byte_count) {
            return error.PackTooLarge;
        }
        if (chunk.len == 0) return;

        const copy = try self.allocator.dupe(u8, chunk);
        errdefer self.allocator.free(copy);
        try self.chunks.append(self.allocator, copy);

        const header_count = @min(chunk.len, self.header_bytes.len - self.header_len);
        @memcpy(self.header_bytes[self.header_len..][0..header_count], chunk[0..header_count]);
        self.header_len += header_count;
        self.byte_count += chunk.len;
    }

    pub fn finish(self: *ImportSession, store: parser_mod.EncodedObjectStore) !plumbing.Hash {
        if (self.finished) return error.ImportFinished;
        const digest_len = plumbing.digestSize();
        if (self.byte_count < self.header_bytes.len + digest_len) return error.MalformedPackFile;

        var header_scanner = scanner_mod.Scanner.initSeekable(&self.header_bytes);
        const header = try header_scanner.header();
        if (header[1] > self.limits.max_objects) return error.TooManyObjects;

        var source = ChunkReader.init(self);
        var scanner = scanner_mod.Scanner.init(&source.reader);
        var parser = try parser_mod.Parser.initWithStore(self.allocator, &scanner, store, &.{});
        defer parser.deinit();
        const checksum = try parser.parse();
        self.finished = true;
        return checksum;
    }

    /// Discard input and make this session reusable immediately.
    pub fn abort(self: *ImportSession) void {
        self.freeChunks();
        self.chunks.clearRetainingCapacity();
        self.byte_count = 0;
        self.header_len = 0;
        self.finished = false;
    }

    pub fn byteCount(self: *const ImportSession) usize {
        return self.byte_count;
    }

    fn freeChunks(self: *ImportSession) void {
        for (self.chunks.items) |chunk| {
            if (chunk.len > 0) self.allocator.free(chunk);
        }
    }
};

const ChunkReader = struct {
    session: *ImportSession,
    chunk_index: usize = 0,
    chunk_offset: usize = 0,
    reader: IoReader,

    fn init(session: *ImportSession) ChunkReader {
        return .{
            .session = session,
            .reader = .{
                .vtable = &vtable,
                .buffer = &.{},
                .seek = 0,
                .end = 0,
            },
        };
    }

    const vtable: IoReader.VTable = .{
        .stream = stream,
    };

    fn stream(r: *IoReader, w: *IoWriter, limit: Limit) IoReader.StreamError!usize {
        const self: *ChunkReader = @alignCast(@fieldParentPtr("reader", r));
        while (self.chunk_index < self.session.chunks.items.len) {
            const chunk = self.session.chunks.items[self.chunk_index];
            if (self.chunk_offset == chunk.len) {
                if (chunk.len > 0) self.session.allocator.free(chunk);
                self.session.chunks.items[self.chunk_index] = &.{};
                self.chunk_index += 1;
                self.chunk_offset = 0;
                continue;
            }

            const available = chunk.len - self.chunk_offset;
            const count = limit.minInt(available);
            if (count == 0) return 0;
            w.writeAll(chunk[self.chunk_offset..][0..count]) catch return error.WriteFailed;
            self.chunk_offset += count;
            if (self.chunk_offset == chunk.len) {
                self.session.allocator.free(chunk);
                self.session.chunks.items[self.chunk_index] = &.{};
                self.chunk_index += 1;
                self.chunk_offset = 0;
            }
            return count;
        }
        return error.EndOfStream;
    }
};

test "bounded uneven writes abort and retry" {
    var session = ImportSession.init(std.testing.allocator, .{ .max_pack_bytes = 5, .max_objects = 5 });
    defer session.deinit();
    try session.write("ab");
    try session.write("c");
    try std.testing.expectError(error.PackTooLarge, session.write("def"));
    session.abort();
    try session.write("12345");
    try std.testing.expectEqual(@as(usize, 5), session.byteCount());
}
