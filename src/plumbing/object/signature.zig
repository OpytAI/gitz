//! Author/committer identity and armored signature block helpers.
//!
//! - `Signature` + Decode/Encode: go-git `plumbing/object/object.go`
//! - Armored parse helpers: go-git `plumbing/object/signature.go`
//!
//! Pin: go-git v5.19.2.

const std = @import("std");
const plumbing = @import("plumbing");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const MemoryObject = plumbing.MemoryObject;
const ObjectType = plumbing.ObjectType;

// ---------------------------------------------------------------------------
// Date format (go-git documentation constant; Go layout string)
// ---------------------------------------------------------------------------

/// go-git `DateFormat` — original git author-date layout (Go reference time).
/// Zig does not use this string for formatting; encode uses unix + ±HHMM.
pub const DateFormat = "Mon Jan 02 15:04:05 2006 -0700";

// ---------------------------------------------------------------------------
// Signature (author / committer / tagger)
// ---------------------------------------------------------------------------

/// Who and when created a commit or tag (go-git `Signature`).
///
/// # Ownership
///
/// - `decode` borrows `name`/`email` from the input buffer. Keep that buffer
///   alive for the lifetime of the slices.
/// - `decodeOwned` copies `name`/`email` with `allocator`. Call `deinit` then.
/// - Fields set by the caller may be literals or owned; only free what you own.
///
/// `when` is unix seconds (UTC instant). `tz_offset_minutes` is the recorded
/// zone offset east of UTC in minutes (go-git `time.Time` location offset / 60).
pub const Signature = struct {
    name: []const u8 = "",
    email: []const u8 = "",
    /// Unix timestamp in seconds (go-git `When.Unix()`).
    when: i64 = 0,
    /// Timezone offset from UTC in minutes (east positive).
    tz_offset_minutes: i16 = 0,
    /// True when `name`/`email` were allocated by `decodeOwned`.
    owned: bool = false,

    /// Free owned name/email from `decodeOwned`. No-op when `owned` is false.
    pub fn deinit(self: *Signature, allocator: Allocator) void {
        if (self.owned) {
            allocator.free(self.name);
            allocator.free(self.email);
        }
        self.* = .{};
    }

    /// Decode a git author line (`Name <email> unix ±HHMM`) borrowing from `b`.
    /// go-git `(*Signature).Decode` — silent on malformed input (partial fill).
    pub fn decode(self: *Signature, b: []const u8) void {
        self.* = .{};
        self.fillFrom(b);
    }

    /// Like `decode` but copies name/email with `allocator` (for long-lived commits/tags).
    pub fn decodeOwned(self: *Signature, allocator: Allocator, b: []const u8) Allocator.Error!void {
        self.deinit(allocator);

        var tmp: Signature = .{};
        tmp.fillFrom(b);

        self.when = tmp.when;
        self.tz_offset_minutes = tmp.tz_offset_minutes;
        self.name = try allocator.dupe(u8, tmp.name);
        errdefer allocator.free(self.name);
        self.email = try allocator.dupe(u8, tmp.email);
        errdefer allocator.free(self.email);
        self.owned = true;
    }

    fn fillFrom(self: *Signature, b: []const u8) void {
        const open = std.mem.lastIndexOfScalar(u8, b, '<') orelse return;
        const close = std.mem.lastIndexOfScalar(u8, b, '>') orelse return;
        if (close < open) return;

        self.name = std.mem.trim(u8, b[0..open], " ");
        self.email = b[open + 1 .. close];

        if (close + 2 < b.len) {
            self.decodeTimeAndTimeZone(b[close + 2 ..]);
        }
    }

    /// Encode as `Name <email> unix ±HHMM` (go-git `(*Signature).Encode`).
    pub fn encode(self: *const Signature, w: *Writer) Writer.Error!void {
        try w.print("{s} <{s}> ", .{ self.name, self.email });
        try self.encodeTimeAndTimeZone(w);
    }

    /// `Name <email>` only (go-git `(*Signature).String`).
    pub fn formatNameEmail(self: *const Signature, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s} <{s}>", .{ self.name, self.email });
    }

    /// Format `When` with go-git `DateFormat` in the recorded timezone.
    /// Writes into `buf` (needs ≥32 bytes). Returns the formatted slice.
    pub fn formatWhen(self: *const Signature, buf: []u8) ![]const u8 {
        return formatDateTime(self.when, self.tz_offset_minutes, buf);
    }

    /// Structural equality (go-git field compare).
    pub fn eql(a: Signature, b: Signature) bool {
        return std.mem.eql(u8, a.name, b.name) and
            std.mem.eql(u8, a.email, b.email) and
            a.when == b.when and
            a.tz_offset_minutes == b.tz_offset_minutes;
    }

    fn decodeTimeAndTimeZone(self: *Signature, b: []const u8) void {
        const space = std.mem.indexOfScalar(u8, b, ' ') orelse b.len;

        const ts = std.fmt.parseInt(i64, b[0..space], 10) catch return;
        self.when = ts;
        self.tz_offset_minutes = 0;

        const tz_start = space + 1;
        const time_zone_length: usize = 5;
        if (tz_start >= b.len or tz_start + time_zone_length > b.len) return;

        const timezone = b[tz_start .. tz_start + time_zone_length];
        // go-git: hours = timezone[0:3] (signed), mins = timezone[3:] (2 digits).
        const tzhours = std.fmt.parseInt(i64, timezone[0..3], 10) catch return;
        var tzmins = std.fmt.parseInt(i64, timezone[3..], 10) catch return;
        if (tzhours < 0) tzmins *= -1;

        const offset_min: i64 = tzhours * 60 + tzmins;
        self.tz_offset_minutes = std.math.cast(i16, offset_min) orelse 0;
    }

    fn encodeTimeAndTimeZone(self: *const Signature, w: *Writer) Writer.Error!void {
        var u = self.when;
        if (u < 0) u = 0;
        var tz_buf: [5]u8 = undefined;
        const tz = formatTzOffset(self.tz_offset_minutes, &tz_buf);
        try w.print("{d} {s}", .{ u, tz });
    }
};

/// Format offset minutes as go-git/time `Format("-0700")` (±HHMM).
fn formatTzOffset(offset_minutes: i16, buf: *[5]u8) []const u8 {
    const off: i32 = offset_minutes;
    const negative = off < 0;
    const abs: u32 = @intCast(if (negative) -off else off);
    const hours = abs / 60;
    const mins = abs % 60;
    buf[0] = if (negative) '-' else '+';
    buf[1] = '0' + @as(u8, @intCast((hours / 10) % 10));
    buf[2] = '0' + @as(u8, @intCast(hours % 10));
    buf[3] = '0' + @as(u8, @intCast((mins / 10) % 10));
    buf[4] = '0' + @as(u8, @intCast(mins % 10));
    return buf[0..5];
}

const weekday_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// go-git `time.Time.Format(DateFormat)` for unix `when` + offset minutes.
/// Layout: `Mon Jan 02 15:04:05 2006 -0700`.
///
/// Buffer must hold at least 32 bytes.
pub fn formatDateTime(when: i64, tz_offset_minutes: i16, buf: []u8) error{NoSpaceLeft}![]const u8 {
    const offset_secs: i64 = @as(i64, tz_offset_minutes) * 60;
    const local = when + offset_secs;
    var tz_buf: [5]u8 = undefined;
    const tz = formatTzOffset(tz_offset_minutes, &tz_buf);

    if (local < 0) {
        return std.fmt.bufPrint(buf, "Thu Jan 01 00:00:00 1970 {s}", .{tz});
    }

    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(local) };
    const day_secs = es.getDaySeconds();
    const epoch_day = es.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    // 1970-01-01 was Thursday; Go `time.Weekday` Sunday=0.
    const weekday: usize = @intCast(@mod(@as(i64, @intCast(epoch_day.day)) + 4, 7));
    const month_idx: usize = @intFromEnum(month_day.month) - 1;

    return std.fmt.bufPrint(buf, "{s} {s} {d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {d} {s}", .{
        weekday_names[weekday],
        month_names[month_idx],
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
        year_day.year,
        tz,
    });
}

// ---------------------------------------------------------------------------
// Armored signature formats (go-git signature.go)
// ---------------------------------------------------------------------------

/// Kind of armored signature block (go-git unexported `signatureType`).
pub const SignatureType = enum(i8) {
    unknown = 0,
    openpgp = 1,
    x509 = 2,
    ssh = 3,
};

const openpgp_begins = [_][]const u8{
    "-----BEGIN PGP SIGNATURE-----",
    "-----BEGIN PGP MESSAGE-----",
};
const x509_begins = [_][]const u8{
    "-----BEGIN CERTIFICATE-----",
    "-----BEGIN SIGNED MESSAGE-----",
};
const ssh_begins = [_][]const u8{
    "-----BEGIN SSH SIGNATURE-----",
};

const header_pgp = "gpgsig";
const header_pgp256 = "gpgsig-sha256";

/// go-git `typeForSignature`.
pub fn typeForSignature(b: []const u8) SignatureType {
    for (openpgp_begins) |begin| {
        if (std.mem.startsWith(u8, b, begin)) return .openpgp;
    }
    for (x509_begins) |begin| {
        if (std.mem.startsWith(u8, b, begin)) return .x509;
    }
    for (ssh_begins) |begin| {
        if (std.mem.startsWith(u8, b, begin)) return .ssh;
    }
    return .unknown;
}

/// Position of the last armored signature block start, and its type.
///
/// `pos == null` when no signature block is found (go-git returns -1).
/// Any trailing bytes after that start are part of the signature payload.
///
/// go-git `parseSignedBytes` — matches git `gpg-interface.c:parse_signed_buffer`.
pub fn parseSignedBytes(b: []const u8) struct { pos: ?usize, typ: SignatureType } {
    var n: usize = 0;
    var match: ?usize = null;
    var t: SignatureType = .unknown;
    while (n < b.len) {
        const i = b[n..];
        const st = typeForSignature(i);
        if (st != .unknown) {
            match = n;
            t = st;
        }
        if (std.mem.indexOfScalar(u8, i, '\n')) |eol| {
            n += eol + 1;
            continue;
        }
        break;
    }
    return .{ .pos = match, .typ = t };
}

/// Count distinct armored signature blocks at line boundaries (go-git `countSignatureBlocks`).
pub fn countSignatureBlocks(b: []const u8) usize {
    var n: usize = 0;
    var count: usize = 0;
    while (n < b.len) {
        const i = b[n..];
        if (typeForSignature(i) != .unknown) count += 1;
        if (std.mem.indexOfScalar(u8, i, '\n')) |eol| {
            n += eol + 1;
            continue;
        }
        break;
    }
    return count;
}

/// go-git `isSignatureHeader`.
pub fn isSignatureHeader(line: []const u8) bool {
    return std.mem.startsWith(u8, line, header_pgp ++ " ") or
        std.mem.startsWith(u8, line, header_pgp256 ++ " ");
}

/// Drop canonical `gpgsig` / `gpgsig-sha256` headers (and continuations) from
/// object text; for tags also truncate trailing armored signature.
///
/// Writes the signature-free bytes into `dst` (type set to `obj_type`).
/// go-git `stripObjectSignatures`.
pub fn stripObjectSignatures(
    dst: *MemoryObject,
    src: *const MemoryObject,
    obj_type: ObjectType,
) Allocator.Error!void {
    dst.setType(obj_type);

    var data = src.readerBytes();
    if (obj_type == .tag) {
        const r = parseSignedBytes(data);
        if (r.pos) |p| data = data[0..p];
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(dst.allocator);
    try stripHeaderSignatures(&out, dst.allocator, data);
    try dst.setContent(out.items);
    out.deinit(dst.allocator);
}

/// Copy `data` to `out`, dropping signature header lines (go-git `stripHeaderSignatures`).
fn stripHeaderSignatures(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    data: []const u8,
) Allocator.Error!void {
    var in_body = false;
    var skipping = false;
    var rest = data;
    while (rest.len > 0) {
        const eol_opt = std.mem.indexOfScalar(u8, rest, '\n');
        const line: []const u8 = if (eol_opt) |eol| rest[0 .. eol + 1] else rest;
        rest = if (eol_opt) |eol| rest[eol + 1 ..] else rest[rest.len..];

        var write = true;
        if (!in_body) {
            if (skipping and line.len > 0 and line[0] == ' ') {
                write = false;
            } else if (isSignatureHeader(line)) {
                skipping = true;
                write = false;
            } else if (line.len == 1 and line[0] == '\n') {
                skipping = false;
                in_body = true;
            } else {
                skipping = false;
            }
        }

        if (write and line.len > 0) {
            try out.appendSlice(allocator, line);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Signature decode known author lines" {
    // Cases from go-git object_test.go TestParseSignature.
    const Case = struct {
        raw: []const u8,
        name: []const u8,
        email: []const u8,
        when: i64,
        tz: i16,
    };
    const cases = [_]Case{
        .{
            .raw = "Foo Bar <foo@bar.com> 1257894000 +0100",
            .name = "Foo Bar",
            .email = "foo@bar.com",
            .when = 1257894000,
            .tz = 60,
        },
        .{
            .raw = "Foo Bar <foo@bar.com> 1257894000 -0700",
            .name = "Foo Bar",
            .email = "foo@bar.com",
            .when = 1257894000,
            .tz = -7 * 60,
        },
        .{
            .raw = "Foo Bar <> 1257894000 +0100",
            .name = "Foo Bar",
            .email = "",
            .when = 1257894000,
            .tz = 60,
        },
        .{
            .raw = " <> 1257894000",
            .name = "",
            .email = "",
            .when = 1257894000,
            .tz = 0,
        },
        .{
            .raw = "Foo Bar <foo@bar.com>",
            .name = "Foo Bar",
            .email = "foo@bar.com",
            .when = 0,
            .tz = 0,
        },
        .{
            .raw = "crap> <foo@bar.com> 1257894000 +1000",
            .name = "crap>",
            .email = "foo@bar.com",
            .when = 1257894000,
            .tz = 10 * 60,
        },
        .{ .raw = "><", .name = "", .email = "", .when = 0, .tz = 0 },
        .{ .raw = "", .name = "", .email = "", .when = 0, .tz = 0 },
        .{ .raw = "<", .name = "", .email = "", .when = 0, .tz = 0 },
    };

    for (cases) |c| {
        var got: Signature = .{};
        got.decode(c.raw);
        try std.testing.expectEqualStrings(c.name, got.name);
        try std.testing.expectEqualStrings(c.email, got.email);
        try std.testing.expectEqual(c.when, got.when);
        try std.testing.expectEqual(c.tz, got.tz_offset_minutes);
    }
}

test "Signature encode decode round trip" {
    const gpa = std.testing.allocator;
    const sig = Signature{
        .name = "Foo Bar",
        .email = "foo@bar.com",
        .when = 1257894000,
        .tz_offset_minutes = 60,
    };

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try sig.encode(&aw.writer);
    const encoded = aw.written();
    try std.testing.expectEqualStrings("Foo Bar <foo@bar.com> 1257894000 +0100", encoded);

    var back: Signature = .{};
    back.decode(encoded);
    try std.testing.expectEqualStrings(sig.name, back.name);
    try std.testing.expectEqualStrings(sig.email, back.email);
    try std.testing.expectEqual(sig.when, back.when);
    try std.testing.expectEqual(sig.tz_offset_minutes, back.tz_offset_minutes);
}

test "Signature encode clamps negative unix to zero" {
    const gpa = std.testing.allocator;
    const sig = Signature{
        .name = "A",
        .email = "a@b.c",
        .when = -100,
        .tz_offset_minutes = 0,
    };
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try sig.encode(&aw.writer);
    try std.testing.expectEqualStrings("A <a@b.c> 0 +0000", aw.written());
}

test "Signature formatNameEmail" {
    const sig = Signature{ .name = "N", .email = "e@x" };
    var buf: [32]u8 = undefined;
    const s = try sig.formatNameEmail(&buf);
    try std.testing.expectEqualStrings("N <e@x>", s);
}

test "Signature decodeOwned owns strings" {
    const gpa = std.testing.allocator;
    var sig: Signature = .{};
    try sig.decodeOwned(gpa, "Foo <foo@bar.com> 1257894000 +0100");
    defer sig.deinit(gpa);
    try std.testing.expect(sig.owned);
    try std.testing.expectEqualStrings("Foo", sig.name);
    try std.testing.expectEqualStrings("foo@bar.com", sig.email);
    try std.testing.expectEqual(@as(i64, 1257894000), sig.when);
    try std.testing.expectEqual(@as(i16, 60), sig.tz_offset_minutes);
}

test "typeForSignature known formats" {
    try std.testing.expect(typeForSignature("-----BEGIN PGP SIGNATURE-----\n") == .openpgp);
    try std.testing.expect(typeForSignature("-----BEGIN PGP MESSAGE-----\n") == .openpgp);
    try std.testing.expect(typeForSignature("-----BEGIN SSH SIGNATURE-----\n") == .ssh);
    try std.testing.expect(typeForSignature("-----BEGIN CERTIFICATE-----\n") == .x509);
    try std.testing.expect(typeForSignature("-----BEGIN SIGNED MESSAGE-----\n") == .x509);
    try std.testing.expect(typeForSignature("-----BEGIN ARBITRARY SIGNATURE-----\n") == .unknown);
}

test "parseSignedBytes last block and trailing data" {
    const msg =
        \\signed tag
        \\-----BEGIN PGP SIGNATURE-----
        \\abc
        \\-----END PGP SIGNATURE-----
        \\-----BEGIN SSH SIGNATURE-----
        \\def
        \\-----END SSH SIGNATURE-----
    ;
    const r = parseSignedBytes(msg);
    try std.testing.expect(r.pos != null);
    try std.testing.expect(r.typ == .ssh);
    try std.testing.expect(std.mem.startsWith(u8, msg[r.pos.?..], "-----BEGIN SSH SIGNATURE-----"));

    const none = parseSignedBytes("Some message");
    try std.testing.expect(none.pos == null);
    try std.testing.expect(none.typ == .unknown);
}

test "countSignatureBlocks" {
    const two =
        \\-----BEGIN PGP SIGNATURE-----
        \\a
        \\-----END PGP SIGNATURE-----
        \\-----BEGIN SSH SIGNATURE-----
        \\b
        \\-----END SSH SIGNATURE-----
    ;
    try std.testing.expectEqual(@as(usize, 2), countSignatureBlocks(two));
    try std.testing.expectEqual(@as(usize, 0), countSignatureBlocks("no sig"));
}

test "stripObjectSignatures drops gpgsig header" {
    const gpa = std.testing.allocator;
    var src = MemoryObject.init(gpa);
    defer src.deinit();
    const body =
        \\tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904
        \\author A <a@b> 1 +0000
        \\committer A <a@b> 1 +0000
        \\gpgsig -----BEGIN PGP SIGNATURE-----
        \\ 
        \\ data
        \\ -----END PGP SIGNATURE-----
        \\
        \\message
    ;
    try src.setContent(body);
    src.setType(.commit);

    var dst = MemoryObject.init(gpa);
    defer dst.deinit();
    try stripObjectSignatures(&dst, &src, .commit);

    const out = dst.readerBytes();
    try std.testing.expect(std.mem.indexOf(u8, out, "gpgsig") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "message") != null);
    try std.testing.expect(dst.object_type == .commit);
}
