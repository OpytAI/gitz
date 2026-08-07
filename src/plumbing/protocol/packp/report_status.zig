//! Report-status message for receive-pack.
//! Port of go-git `plumbing/protocol/packp/report_status.go` (v5.19.2).

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const plumbing = @import("plumbing");
const pktline = @import("pktline");
const common = @import("common.zig");

const ReferenceName = plumbing.ReferenceName;

const ok_status: []const u8 = "ok";

/// Report-status message (go-git `ReportStatus`).
pub const ReportStatus = struct {
    allocator: Allocator,
    unpack_status: []const u8 = "",
    command_statuses: std.ArrayListUnmanaged(CommandStatus) = .empty,
    /// When true, `unpack_status` and command string fields are owned.
    owns_strings: bool = false,

    /// go-git `NewReportStatus`.
    pub fn init(allocator: Allocator) ReportStatus {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ReportStatus) void {
        if (self.owns_strings) {
            self.allocator.free(self.unpack_status);
            for (self.command_statuses.items) |*cs| {
                cs.deinit(self.allocator);
            }
        }
        self.command_statuses.deinit(self.allocator);
        self.* = undefined;
    }

    /// First error if unpack or any command failed (go-git `Error`).
    /// Returns null when status is fully successful.
    pub fn err(self: *const ReportStatus) ?[]const u8 {
        if (!std.mem.eql(u8, self.unpack_status, ok_status)) {
            return "unpack error";
        }
        for (self.command_statuses.items) |cs| {
            if (cs.err() != null) return "command error";
        }
        return null;
    }

    /// Whether the report indicates full success (unpack + all commands ok).
    pub fn isOk(self: *const ReportStatus) bool {
        return self.err() == null;
    }

    /// Set unpack status, taking ownership of a copied string.
    pub fn setUnpackStatus(self: *ReportStatus, msg: []const u8) Allocator.Error!void {
        if (self.owns_strings and self.unpack_status.len != 0) {
            self.allocator.free(self.unpack_status);
        }
        self.unpack_status = try self.allocator.dupe(u8, msg);
        self.owns_strings = true;
    }

    /// Append a command status with owned name and status strings.
    pub fn addCommandStatus(self: *ReportStatus, name: []const u8, msg: []const u8) Allocator.Error!void {
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);
        const status_owned = try self.allocator.dupe(u8, msg);
        errdefer self.allocator.free(status_owned);
        try self.command_statuses.append(self.allocator, .{
            .reference_name = ReferenceName.init(name_owned),
            .status = status_owned,
            .owns = true,
        });
        self.owns_strings = true;
    }

    /// Encodes unpack + command statuses + flush (go-git `Encode`).
    pub fn encode(self: *const ReportStatus, w: *Writer) (pktline.Error || Writer.Error)!void {
        var enc = pktline.Encoder.init(w);
        try enc.encodef("unpack {s}\n", .{self.unpack_status});
        for (self.command_statuses.items) |cs| {
            try cs.encode(w);
        }
        try enc.flush();
    }

    /// Decodes a report-status message (go-git `Decode`).
    pub fn decode(self: *ReportStatus, r: *Reader) (common.Error || pktline.Error || Reader.Error || Allocator.Error)!void {
        self.clearOwned();

        var sc = pktline.Scanner.init(r);
        try scanFirstLine(&sc);

        try self.decodeReportStatus(sc.bytes());
        // Own allocations from here so `deinit` frees on later errors.
        self.owns_strings = true;

        var flushed = false;
        while (sc.scan()) {
            const b = sc.bytes();
            if (common.isFlush(b)) {
                flushed = true;
                break;
            }
            try self.decodeCommandStatus(b);
        }

        if (!flushed) return error.MissingFlush;
        if (sc.err()) |e| return e;
    }

    fn clearOwned(self: *ReportStatus) void {
        if (self.owns_strings) {
            self.allocator.free(self.unpack_status);
            for (self.command_statuses.items) |*cs| {
                cs.deinit(self.allocator);
            }
        }
        self.command_statuses.clearRetainingCapacity();
        self.unpack_status = "";
        self.owns_strings = false;
    }

    fn scanFirstLine(sc: *pktline.Scanner) (common.Error || pktline.Error || Reader.Error)!void {
        if (sc.scan()) return;
        if (sc.err()) |e| return e;
        return error.UnexpectedEof;
    }

    fn decodeReportStatus(self: *ReportStatus, b: []const u8) (common.Error || Allocator.Error)!void {
        if (common.isFlush(b)) return error.PrematureFlush;

        const line = std.mem.trimEnd(u8, b, "\n");
        var it = std.mem.splitScalar(u8, line, ' ');
        const first = it.next() orelse return error.MalformedUnpackStatus;
        const second = it.next() orelse return error.MalformedUnpackStatus;
        if (!std.mem.eql(u8, first, "unpack")) return error.MalformedUnpackStatus;
        // Rest of line after first space (status may contain spaces).
        const status_start = first.len + 1;
        if (status_start > line.len) return error.MalformedUnpackStatus;
        _ = second;
        self.unpack_status = try self.allocator.dupe(u8, line[status_start..]);
    }

    fn decodeCommandStatus(self: *ReportStatus, b: []const u8) (common.Error || Allocator.Error)!void {
        const line = std.mem.trimEnd(u8, b, "\n");
        var fields: [3][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, line, ' ');
        while (it.next()) |f| {
            if (n < 3) {
                fields[n] = f;
                n += 1;
            } else {
                // Status may contain spaces: rejoin remainder into fields[2].
                // With SplitScalar we only get first 3 tokens; rebuild status from line.
                break;
            }
        }

        var status: []const u8 = ok_status;
        var ref_name: []const u8 = undefined;

        if (n == 3 and std.mem.eql(u8, fields[0], "ng")) {
            // "ng <ref> <status...>" — status is everything after second field.
            ref_name = fields[1];
            const prefix_len = fields[0].len + 1 + fields[1].len + 1;
            if (prefix_len > line.len) return error.MalformedCommandStatus;
            status = line[prefix_len..];
        } else if (n == 2 and std.mem.eql(u8, fields[0], "ok")) {
            ref_name = fields[1];
            status = ok_status;
        } else {
            return error.MalformedCommandStatus;
        }

        const name_owned = try self.allocator.dupe(u8, ref_name);
        errdefer self.allocator.free(name_owned);
        const status_owned = try self.allocator.dupe(u8, status);
        errdefer self.allocator.free(status_owned);

        try self.command_statuses.append(self.allocator, .{
            .reference_name = ReferenceName.init(name_owned),
            .status = status_owned,
            .owns = true,
        });
    }
};

/// Status of one reference update (go-git `CommandStatus`).
pub const CommandStatus = struct {
    reference_name: ReferenceName,
    status: []const u8 = ok_status,
    /// When true, `reference_name.raw` and `status` are allocator-owned.
    owns: bool = false,

    pub fn deinit(self: *CommandStatus, allocator: Allocator) void {
        if (self.owns) {
            allocator.free(self.reference_name.raw);
            allocator.free(self.status);
            self.owns = false;
        }
    }

    /// go-git `(*CommandStatus).Error` — null when status is `"ok"`.
    pub fn err(self: *const CommandStatus) ?[]const u8 {
        if (std.mem.eql(u8, self.status, ok_status)) return null;
        return self.status;
    }

    /// Encodes one command status pkt-line (go-git `encode`).
    pub fn encode(self: *const CommandStatus, w: *Writer) (pktline.Error || Writer.Error)!void {
        var enc = pktline.Encoder.init(w);
        if (self.err() == null) {
            return enc.encodef("ok {s}\n", .{self.reference_name.string()});
        }
        return enc.encodef("ng {s} {s}\n", .{ self.reference_name.string(), self.status });
    }
};

// ---------------------------------------------------------------------------
// Tests — report_status_test.go
// ---------------------------------------------------------------------------

fn encodeLines(allocator: Allocator, lines: []const []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var enc = pktline.Encoder.init(&aw.writer);
    try enc.encodeString(lines);
    return try aw.toOwnedSlice();
}

test "Error unpack and command" {
    var rs = ReportStatus.init(testing.allocator);
    defer rs.deinit();
    rs.unpack_status = "ok";
    try testing.expect(rs.isOk());

    rs.unpack_status = "OK";
    try testing.expect(rs.err() != null);

    rs.unpack_status = "";
    try testing.expect(rs.err() != null);

    rs.unpack_status = "ok";
    try rs.command_statuses.append(testing.allocator, .{
        .reference_name = ReferenceName.init("ref"),
        .status = "ok",
    });
    try testing.expect(rs.isOk());

    rs.command_statuses.items[0].status = "OK";
    try testing.expect(rs.err() != null);

    rs.command_statuses.items[0].status = "";
    try testing.expect(rs.err() != null);
}

test "encode decode one reference ok" {
    var rs = ReportStatus.init(testing.allocator);
    defer rs.deinit();
    rs.unpack_status = "ok";
    try rs.command_statuses.append(testing.allocator, .{
        .reference_name = ReferenceName.init("refs/heads/master"),
        .status = "ok",
    });

    var storage: [128]u8 = undefined;
    var w: Writer = .fixed(&storage);
    try rs.encode(&w);

    var r: Reader = .fixed(w.buffered());
    var got = ReportStatus.init(testing.allocator);
    defer got.deinit();
    try got.decode(&r);
    try testing.expectEqualStrings("ok", got.unpack_status);
    try testing.expectEqual(@as(usize, 1), got.command_statuses.items.len);
    try testing.expectEqualStrings("refs/heads/master", got.command_statuses.items[0].reference_name.string());
    try testing.expectEqualStrings("ok", got.command_statuses.items[0].status);
}

test "encode decode one reference failed" {
    var rs = ReportStatus.init(testing.allocator);
    defer rs.deinit();
    rs.unpack_status = "my error";
    try rs.command_statuses.append(testing.allocator, .{
        .reference_name = ReferenceName.init("refs/heads/master"),
        .status = "command error",
    });

    var storage: [128]u8 = undefined;
    var w: Writer = .fixed(&storage);
    try rs.encode(&w);

    var r: Reader = .fixed(w.buffered());
    var got = ReportStatus.init(testing.allocator);
    defer got.deinit();
    try got.decode(&r);
    try testing.expectEqualStrings("my error", got.unpack_status);
    try testing.expectEqualStrings("command error", got.command_statuses.items[0].status);
}

test "encode decode more references" {
    var rs = ReportStatus.init(testing.allocator);
    defer rs.deinit();
    rs.unpack_status = "ok";
    try rs.command_statuses.append(testing.allocator, .{
        .reference_name = ReferenceName.init("refs/heads/master"),
        .status = "ok",
    });
    try rs.command_statuses.append(testing.allocator, .{
        .reference_name = ReferenceName.init("refs/heads/a"),
        .status = "ok",
    });
    try rs.command_statuses.append(testing.allocator, .{
        .reference_name = ReferenceName.init("refs/heads/b"),
        .status = "ok",
    });

    var storage: [256]u8 = undefined;
    var w: Writer = .fixed(&storage);
    try rs.encode(&w);

    var r: Reader = .fixed(w.buffered());
    var got = ReportStatus.init(testing.allocator);
    defer got.deinit();
    try got.decode(&r);
    try testing.expectEqual(@as(usize, 3), got.command_statuses.items.len);
}

test "encode decode more references failed" {
    var rs = ReportStatus.init(testing.allocator);
    defer rs.deinit();
    rs.unpack_status = "my error";
    try rs.command_statuses.append(testing.allocator, .{
        .reference_name = ReferenceName.init("refs/heads/master"),
        .status = "ok",
    });
    try rs.command_statuses.append(testing.allocator, .{
        .reference_name = ReferenceName.init("refs/heads/a"),
        .status = "command error",
    });
    try rs.command_statuses.append(testing.allocator, .{
        .reference_name = ReferenceName.init("refs/heads/b"),
        .status = "ok",
    });

    var storage: [256]u8 = undefined;
    var w: Writer = .fixed(&storage);
    try rs.encode(&w);

    const expected = try encodeLines(testing.allocator, &.{
        "unpack my error\n",
        "ok refs/heads/master\n",
        "ng refs/heads/a command error\n",
        "ok refs/heads/b\n",
        pktline.FlushString,
    });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "encode decode no references" {
    var rs = ReportStatus.init(testing.allocator);
    defer rs.deinit();
    rs.unpack_status = "ok";

    var storage: [64]u8 = undefined;
    var w: Writer = .fixed(&storage);
    try rs.encode(&w);

    var r: Reader = .fixed(w.buffered());
    var got = ReportStatus.init(testing.allocator);
    defer got.deinit();
    try got.decode(&r);
    try testing.expectEqualStrings("ok", got.unpack_status);
    try testing.expectEqual(@as(usize, 0), got.command_statuses.items.len);
}

test "decode missing flush" {
    const raw = try encodeLines(testing.allocator, &.{
        "unpack ok\n",
        "ok refs/heads/master\n",
    });
    defer testing.allocator.free(raw);
    var r: Reader = .fixed(raw);
    var rs = ReportStatus.init(testing.allocator);
    defer rs.deinit();
    try testing.expectError(error.MissingFlush, rs.decode(&r));
}

test "decode empty unexpected EOF" {
    var r: Reader = .fixed(&.{});
    var rs = ReportStatus.init(testing.allocator);
    defer rs.deinit();
    try testing.expectError(error.UnexpectedEof, rs.decode(&r));
}

test "decode malformed unpack status" {
    const raw = try encodeLines(testing.allocator, &.{
        "unpackok\n",
        pktline.FlushString,
    });
    defer testing.allocator.free(raw);
    var r: Reader = .fixed(raw);
    var rs = ReportStatus.init(testing.allocator);
    defer rs.deinit();
    try testing.expectError(error.MalformedUnpackStatus, rs.decode(&r));
}

test "decode malformed unpack status UNPACK" {
    const raw = try encodeLines(testing.allocator, &.{
        "UNPACK OK\n",
        pktline.FlushString,
    });
    defer testing.allocator.free(raw);
    var r: Reader = .fixed(raw);
    var rs = ReportStatus.init(testing.allocator);
    defer rs.deinit();
    try testing.expectError(error.MalformedUnpackStatus, rs.decode(&r));
}

test "decode malformed command status" {
    const raw = try encodeLines(testing.allocator, &.{
        "unpack ok\n",
        "ko refs/heads/master\n",
        pktline.FlushString,
    });
    defer testing.allocator.free(raw);
    var r: Reader = .fixed(raw);
    var rs = ReportStatus.init(testing.allocator);
    defer rs.deinit();
    try testing.expectError(error.MalformedCommandStatus, rs.decode(&r));
}

test "decode malformed command status ng without message" {
    const raw = try encodeLines(testing.allocator, &.{
        "unpack ok\n",
        "ng refs/heads/master\n",
        pktline.FlushString,
    });
    defer testing.allocator.free(raw);
    var r: Reader = .fixed(raw);
    var rs = ReportStatus.init(testing.allocator);
    defer rs.deinit();
    try testing.expectError(error.MalformedCommandStatus, rs.decode(&r));
}

test "decode premature flush" {
    const raw = try encodeLines(testing.allocator, &.{
        pktline.FlushString,
    });
    defer testing.allocator.free(raw);
    var r: Reader = .fixed(raw);
    var rs = ReportStatus.init(testing.allocator);
    defer rs.deinit();
    try testing.expectError(error.PrematureFlush, rs.decode(&r));
}
