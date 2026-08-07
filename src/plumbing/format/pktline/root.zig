//! pkt-line encode and scan — port of go-git `plumbing/format/pktline` (v5.19.2).
//!
//! A pkt-line is a 4-byte hexadecimal length (including the length field) followed
//! by a payload. Length `0000` is a flush-pkt (empty payload).
//!
//! I/O uses Zig 0.16 `std.Io.Reader` / `std.Io.Writer`.

const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const testing = std.testing;

// ---------------------------------------------------------------------------
// Constants (go-git names)
// ---------------------------------------------------------------------------

/// Maximum payload size of a pkt-line in bytes (encode limit).
pub const MaxPayloadSize: usize = 65516;

/// Longer payload accepted by the scanner for Git compatibility.
pub const OversizePayloadMax: usize = 65520;

const len_size: usize = 4;

/// Contents of a flush-pkt pkt-line (`0000`).
pub const FlushPkt = [_]u8{ '0', '0', '0', '0' };

/// Payload to use with `encode` / `encodeLine` for a flush-pkt (empty).
pub const Flush: []const u8 = &.{};

/// Payload to use with `encodeString` for a flush-pkt (empty string).
pub const FlushString: []const u8 = "";

const err_prefix = "ERR ";

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const Error = error{
    /// Payload longer than `MaxPayloadSize` (go-git `ErrPayloadTooLong`).
    PayloadTooLong,
    /// Invalid pkt-len field (go-git `ErrInvalidPktLen`).
    InvalidPktLen,
    /// Packet was not an error-line (go-git `ErrInvalidErrorLine`).
    InvalidErrorLine,
    /// Stream carried an `ERR ` payload (go-git `*ErrorLine` as error).
    ErrorLine,
};

// ---------------------------------------------------------------------------
// Encoder
// ---------------------------------------------------------------------------

/// Writes pkt-lines to an output stream (go-git `Encoder`).
pub const Encoder = struct {
    w: *Writer,

    /// go-git `NewEncoder`.
    pub fn init(w: *Writer) Encoder {
        return .{ .w = w };
    }

    /// Encodes a flush-pkt (`0000`).
    pub fn flush(self: *Encoder) Writer.Error!void {
        try self.w.writeAll(&FlushPkt);
    }

    /// Encodes each payload as its own pkt-line.
    /// Empty payload encodes a flush-pkt.
    pub fn encode(self: *Encoder, payloads: []const []const u8) (Error || Writer.Error)!void {
        for (payloads) |p| {
            try self.encodeLine(p);
        }
    }

    /// Encodes one pkt-line. Empty `p` encodes a flush-pkt.
    pub fn encodeLine(self: *Encoder, p: []const u8) (Error || Writer.Error)!void {
        if (p.len > MaxPayloadSize) return error.PayloadTooLong;
        if (p.len == 0) return self.flush();

        const n = p.len + len_size;
        var hex: [len_size]u8 = undefined;
        asciiHex16(n, &hex);
        try self.w.writeAll(&hex);
        try self.w.writeAll(p);
    }

    /// Like `encode` but payloads are strings (go-git `EncodeString`).
    pub fn encodeString(self: *Encoder, payloads: []const []const u8) (Error || Writer.Error)!void {
        return self.encode(payloads);
    }

    /// Encodes one pkt-line from a format string (go-git `Encodef`).
    pub fn encodef(self: *Encoder, comptime fmt: []const u8, args: anytype) (Error || Writer.Error)!void {
        var buf: [MaxPayloadSize]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, fmt, args) catch return error.PayloadTooLong;
        try self.encodeLine(formatted);
    }
};


// ---------------------------------------------------------------------------
// Scanner
// ---------------------------------------------------------------------------

/// Reads payloads from a series of pkt-lines (go-git `Scanner`).
///
/// After each successful `scan`, `bytes` returns the payload on a shared
/// buffer (size ≤ `OversizePayloadMax`). Flush pkt-lines yield empty slices.
///
/// Scanning stops at end-of-stream or the first I/O / format error.
pub const Scanner = struct {
    r: *Reader,
    /// Sticky format/I/O error. End-of-stream is not sticky.
    sticky: ?(Error || Reader.Error) = null,
    payload_buf: [OversizePayloadMax]u8 = undefined,
    payload_len: usize = 0,
    /// Start index of trimmed ERR text inside `payload_buf` when `has_error_line`.
    err_text_start: usize = 0,
    err_text_len: usize = 0,
    has_error_line: bool = false,

    /// go-git `NewScanner`.
    pub fn init(r: *Reader) Scanner {
        return .{ .r = r };
    }

    /// First sticky error, or null. End-of-stream is not an error.
    pub fn err(self: *const Scanner) ?(Error || Reader.Error) {
        return self.sticky;
    }

    /// Most recent payload from `scan`. Overwritten by the next `scan`.
    pub fn bytes(self: *const Scanner) []const u8 {
        return self.payload_buf[0..self.payload_len];
    }

    /// Text of the last `ERR ` line when `err()` is `error.ErrorLine`.
    pub fn errorLineText(self: *const Scanner) []const u8 {
        if (!self.has_error_line) return "";
        return self.payload_buf[self.err_text_start .. self.err_text_start + self.err_text_len];
    }

    /// Advances to the next pkt-line. Returns false at EOS or on error.
    pub fn scan(self: *Scanner) bool {
        self.has_error_line = false;
        self.err_text_start = 0;
        self.err_text_len = 0;

        const plen = self.readPayloadLen() catch |e| {
            if (e == error.EndOfStream) {
                self.sticky = null;
                return false;
            }
            self.sticky = e;
            return false;
        };

        if (plen > 0) {
            self.r.readSliceAll(self.payload_buf[0..plen]) catch |e| {
                self.sticky = e;
                return false;
            };
        }
        self.payload_len = plen;

        if (std.mem.startsWith(u8, self.bytes(), err_prefix)) {
            // Trim ASCII whitespace like go-git `strings.TrimSpace` for ERR text.
            var start: usize = err_prefix.len;
            var end: usize = self.payload_len;
            while (start < end and isASCIISpace(self.payload_buf[start])) : (start += 1) {}
            while (end > start and isASCIISpace(self.payload_buf[end - 1])) : (end -= 1) {}
            self.err_text_start = start;
            self.err_text_len = end - start;
            self.has_error_line = true;
            self.sticky = error.ErrorLine;
            return false;
        }

        self.sticky = null;
        return true;
    }

    fn readPayloadLen(self: *Scanner) (Error || Reader.Error)!usize {
        var len_buf: [len_size]u8 = undefined;
        const n = try self.r.readSliceShort(&len_buf);
        if (n == 0) return error.EndOfStream;
        if (n < len_size) return error.InvalidPktLen;

        const total = try hexDecode(len_buf);
        if (total == 0) return 0;
        if (total <= len_size) return error.InvalidPktLen;
        if (total > OversizePayloadMax + len_size) return error.InvalidPktLen;
        return total - len_size;
    }
};


// ---------------------------------------------------------------------------
// ErrorLine
// ---------------------------------------------------------------------------

/// Packet line that contains an error message (go-git `ErrorLine`).
/// Once sent, the data transfer process is terminated.
pub const ErrorLine = struct {
    text: []const u8 = "",
    /// Owned storage filled by `decode` so `text` can outlive the scanner buffer.
    owned: [256]u8 = undefined,
    owned_len: usize = 0,

    /// Error message string (go-git `Error()`).
    pub fn errorMessage(self: *const ErrorLine) []const u8 {
        return self.text;
    }

    /// Encodes as `ERR <text>\n` pkt-line.
    pub fn encode(self: *const ErrorLine, w: *Writer) (Error || Writer.Error)!void {
        var enc = Encoder.init(w);
        try enc.encodef("{s}{s}\n", .{ err_prefix, self.text });
    }

    /// Decodes one pkt-line into this error line.
    ///
    /// When the stream carries an `ERR ` payload, go-git returns `*ErrorLine`
    /// as the scan error. This port fills `self` and returns `error.ErrorLine`.
    pub fn decode(self: *ErrorLine, r: *Reader) (Error || Reader.Error)!void {
        var sc = Scanner.init(r);
        if (!sc.scan()) {
            if (sc.err()) |e| {
                if (e == error.ErrorLine) {
                    self.setOwned(sc.errorLineText());
                    return error.ErrorLine;
                }
                return e;
            }
            self.text = "";
            self.owned_len = 0;
            return;
        }
        const line = sc.bytes();
        if (!std.mem.startsWith(u8, line, err_prefix)) return error.InvalidErrorLine;
        self.setOwned(std.mem.trim(u8, line[err_prefix.len..], " \t\r\n"));
    }

    fn setOwned(self: *ErrorLine, t: []const u8) void {
        const n = @min(t.len, self.owned.len);
        @memcpy(self.owned[0..n], t[0..n]);
        self.owned_len = n;
        self.text = self.owned[0..self.owned_len];
    }
};

// ---------------------------------------------------------------------------
// Hex helpers (go-git private asciiHex16 / hexDecode)
// ---------------------------------------------------------------------------

/// Hexadecimal ASCII of the 16 least significant bits of `n` (always 4 bytes).
fn asciiHex16(n: usize, out: *[len_size]u8) void {
    out[0] = byteToASCIIHex(@truncate((n & 0xf000) >> 12));
    out[1] = byteToASCIIHex(@truncate((n & 0x0f00) >> 8));
    out[2] = byteToASCIIHex(@truncate((n & 0x00f0) >> 4));
    out[3] = byteToASCIIHex(@truncate(n & 0x000f));
}

fn byteToASCIIHex(n: u8) u8 {
    if (n < 10) return '0' + n;
    return 'a' - 10 + n;
}

fn hexDecode(buf: [len_size]u8) Error!usize {
    var ret: usize = 0;
    for (buf) |b| {
        const n = asciiHexToByte(b) catch return error.InvalidPktLen;
        ret = 16 * ret + n;
    }
    return ret;
}

fn asciiHexToByte(b: u8) Error!u8 {
    switch (b) {
        '0'...'9' => return b - '0',
        'a'...'f' => return b - 'a' + 10,
        'A'...'F' => return b - 'A' + 10,
        else => return error.InvalidPktLen,
    }
}

fn isASCIISpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0b' or c == '\x0c';
}

// ---------------------------------------------------------------------------
// Tests — vectors from go-git encoder_test.go / scanner_test.go
// ---------------------------------------------------------------------------

test "flush encodes 0000" {
    var storage: [8]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var e = Encoder.init(&w);
    try e.flush();
    try testing.expectEqualSlices(u8, &FlushPkt, w.buffered());
}

test "encode single and multi payloads" {
    {
        var storage: [32]u8 = undefined;
        var w: Writer = .fixed(&storage);
        var e = Encoder.init(&w);
        try e.encode(&.{"hello\n"});
        try testing.expectEqualSlices(u8, "000ahello\n", w.buffered());
    }
    {
        var storage: [32]u8 = undefined;
        var w: Writer = .fixed(&storage);
        var e = Encoder.init(&w);
        try e.encode(&.{ "hello\n", Flush });
        try testing.expectEqualSlices(u8, "000ahello\n0000", w.buffered());
    }
    {
        var storage: [64]u8 = undefined;
        var w: Writer = .fixed(&storage);
        var e = Encoder.init(&w);
        try e.encode(&.{ "hello\n", "world!\n", "foo" });
        try testing.expectEqualSlices(u8, "000ahello\n000bworld!\n0007foo", w.buffered());
    }
    {
        var storage: [64]u8 = undefined;
        var w: Writer = .fixed(&storage);
        var e = Encoder.init(&w);
        try e.encode(&.{ "hello\n", Flush, "world!\n", "foo", Flush });
        try testing.expectEqualSlices(u8, "000ahello\n0000000bworld!\n0007foo0000", w.buffered());
    }
}

test "encode max payload size fff0" {
    const payload = try testing.allocator.alloc(u8, MaxPayloadSize);
    defer testing.allocator.free(payload);
    @memset(payload, 'a');

    const out = try testing.allocator.alloc(u8, MaxPayloadSize + len_size);
    defer testing.allocator.free(out);
    var w: Writer = .fixed(out);
    var e = Encoder.init(&w);
    try e.encode(&.{payload});

    const got = w.buffered();
    try testing.expectEqual(@as(usize, MaxPayloadSize + len_size), got.len);
    try testing.expectEqualSlices(u8, "fff0", got[0..4]);
    try testing.expectEqualSlices(u8, payload, got[4..]);
}

test "encode two max payloads" {
    const a = try testing.allocator.alloc(u8, MaxPayloadSize);
    defer testing.allocator.free(a);
    const b = try testing.allocator.alloc(u8, MaxPayloadSize);
    defer testing.allocator.free(b);
    @memset(a, 'a');
    @memset(b, 'b');

    const out = try testing.allocator.alloc(u8, 2 * (MaxPayloadSize + len_size));
    defer testing.allocator.free(out);
    var w: Writer = .fixed(out);
    var e = Encoder.init(&w);
    try e.encode(&.{ a, b });

    const got = w.buffered();
    try testing.expectEqual(@as(usize, 2 * (MaxPayloadSize + len_size)), got.len);
    try testing.expectEqualSlices(u8, "fff0", got[0..4]);
    try testing.expectEqualSlices(u8, a, got[4 .. 4 + MaxPayloadSize]);
    const off = MaxPayloadSize + len_size;
    try testing.expectEqualSlices(u8, "fff0", got[off .. off + 4]);
    try testing.expectEqualSlices(u8, b, got[off + 4 ..]);
}

test "encode ErrPayloadTooLong" {
    const too = try testing.allocator.alloc(u8, MaxPayloadSize + 1);
    defer testing.allocator.free(too);
    @memset(too, 'a');

    var storage: [32]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var e = Encoder.init(&w);
    try testing.expectError(error.PayloadTooLong, e.encode(&.{too}));
    try testing.expectError(error.PayloadTooLong, e.encode(&.{ "hello world!", too }));
    try testing.expectError(error.PayloadTooLong, e.encode(&.{ "hello world!", too, "foo" }));
}

test "encodeString vectors" {
    {
        var storage: [32]u8 = undefined;
        var w: Writer = .fixed(&storage);
        var e = Encoder.init(&w);
        try e.encodeString(&.{"hello\n"});
        try testing.expectEqualSlices(u8, "000ahello\n", w.buffered());
    }
    {
        var storage: [32]u8 = undefined;
        var w: Writer = .fixed(&storage);
        var e = Encoder.init(&w);
        try e.encodeString(&.{ "hello\n", FlushString });
        try testing.expectEqualSlices(u8, "000ahello\n0000", w.buffered());
    }
    {
        var storage: [64]u8 = undefined;
        var w: Writer = .fixed(&storage);
        var e = Encoder.init(&w);
        try e.encodeString(&.{ "hello\n", "world!\n", "foo" });
        try testing.expectEqualSlices(u8, "000ahello\n000bworld!\n0007foo", w.buffered());
    }
}

test "encodef" {
    var storage: [32]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var e = Encoder.init(&w);
    try e.encodef(" {s} {d}\n", .{ "foo", @as(i32, 42) });
    try testing.expectEqualSlices(u8, "000c foo 42\n", w.buffered());
}

test "scanner invalid pkt-len" {
    const cases = [_][]const u8{
        "0001",     "0002",     "0003",     "0004",
        "0001asdfsadf", "0004foo",
        "fff5",     "ffff",
        "FFF5",     "FFFF",
        "gorka",
        "0",        "003",
        "   5a",    "5   a",    "5   \n",
        "-001",     "-000",
    };
    for (cases) |data| {
        var r: Reader = .fixed(data);
        var sc = Scanner.init(&r);
        _ = sc.scan();
        try testing.expect(sc.err() != null);
        try testing.expect(sc.err().? == error.InvalidPktLen);
    }
}

test "scanner oversize pkt-lines accepted" {
    // go-git accepts fff1..fff4 (payload up to OversizePayloadMax).
    const totals = [_]usize{ 0xfff1, 0xfff2, 0xfff3, 0xfff4 };
    for (totals) |total| {
        const payload_len = total - len_size;
        const buf = try testing.allocator.alloc(u8, total);
        defer testing.allocator.free(buf);
        var hex: [4]u8 = undefined;
        asciiHex16(total, &hex);
        @memcpy(buf[0..4], &hex);
        @memset(buf[4..], 'a');

        var r: Reader = .fixed(buf);
        var sc = Scanner.init(&r);
        try testing.expect(sc.scan());
        try testing.expect(sc.err() == null);
        try testing.expectEqual(payload_len, sc.bytes().len);
    }
}

test "scanner valid pkt sizes mixed case" {
    const totals = [_]usize{ 0x01fe, 0x00b5 };
    for (totals) |total| {
        // lowercase
        {
            const buf = try testing.allocator.alloc(u8, total);
            defer testing.allocator.free(buf);
            var hex: [4]u8 = undefined;
            asciiHex16(total, &hex);
            @memcpy(buf[0..4], &hex);
            @memset(buf[4..], 'a');
            var r: Reader = .fixed(buf);
            var sc = Scanner.init(&r);
            try testing.expect(sc.scan());
            try testing.expect(sc.err() == null);
            try testing.expectEqualSlices(u8, buf[4..], sc.bytes());
        }
        // uppercase length digits
        {
            const buf = try testing.allocator.alloc(u8, total);
            defer testing.allocator.free(buf);
            var hex: [4]u8 = undefined;
            asciiHex16(total, &hex);
            for (&hex) |*c| {
                if (c.* >= 'a' and c.* <= 'f') c.* = c.* - 'a' + 'A';
            }
            @memcpy(buf[0..4], &hex);
            @memset(buf[4..], 'a');
            var r: Reader = .fixed(buf);
            var sc = Scanner.init(&r);
            try testing.expect(sc.scan());
            try testing.expect(sc.err() == null);
            try testing.expectEqualSlices(u8, buf[4..], sc.bytes());
        }
    }
}

test "scanner empty reader" {
    var r: Reader = .fixed(&.{});
    var sc = Scanner.init(&r);
    try testing.expect(!sc.scan());
    try testing.expect(sc.err() == null);
}

test "scanner flush round-trip" {
    var storage: [8]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var e = Encoder.init(&w);
    try e.flush();

    var r: Reader = .fixed(w.buffered());
    var sc = Scanner.init(&r);
    try testing.expect(sc.scan());
    try testing.expectEqual(@as(usize, 0), sc.bytes().len);
    try testing.expect(sc.err() == null);
}

test "scanner pkt-line too short" {
    var r: Reader = .fixed("010cfoobar");
    var sc = Scanner.init(&r);
    try testing.expect(!sc.scan());
    try testing.expect(sc.err() != null);
    try testing.expect(sc.err().? == error.EndOfStream);
}

test "scan and payload round-trip" {
    const cases = [_][]const u8{
        "a",
        "a\n",
        "aaaaaaaaaa",
        "aaaaaaaaaa\n",
    };
    for (cases) |payload| {
        var storage: [64]u8 = undefined;
        var w: Writer = .fixed(&storage);
        var e = Encoder.init(&w);
        try e.encodeString(&.{payload});

        var r: Reader = .fixed(w.buffered());
        var sc = Scanner.init(&r);
        try testing.expect(sc.scan());
        try testing.expectEqualSlices(u8, payload, sc.bytes());
    }

    // Max payload
    {
        const payload = try testing.allocator.alloc(u8, MaxPayloadSize);
        defer testing.allocator.free(payload);
        @memset(payload, 'a');

        const out = try testing.allocator.alloc(u8, MaxPayloadSize + len_size);
        defer testing.allocator.free(out);
        var w: Writer = .fixed(out);
        var e = Encoder.init(&w);
        try e.encode(&.{payload});

        var r: Reader = .fixed(w.buffered());
        var sc = Scanner.init(&r);
        try testing.expect(sc.scan());
        try testing.expectEqualSlices(u8, payload, sc.bytes());
    }
}

test "scanner skip lines" {
    var storage: [64]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var e = Encoder.init(&w);
    try e.encodeString(&.{ "first", "second", "third" });

    var r: Reader = .fixed(w.buffered());
    var sc = Scanner.init(&r);
    try testing.expect(sc.scan()); // first
    try testing.expect(sc.scan()); // second
    try testing.expectEqualSlices(u8, "second", sc.bytes());
    try testing.expect(sc.scan()); // third
    try testing.expectEqualSlices(u8, "third", sc.bytes());
}

test "scanner EOF clears error" {
    var storage: [64]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var e = Encoder.init(&w);
    try e.encodeString(&.{ "first", "second" });

    var r: Reader = .fixed(w.buffered());
    var sc = Scanner.init(&r);
    while (sc.scan()) {}
    try testing.expect(sc.err() == null);
}

test "scanner sections with flush" {
    var storage: [256]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var e = Encoder.init(&w);

    // 2 sections × 4 lines + flush each
    var section: usize = 0;
    while (section < 2) : (section += 1) {
        var line: usize = 0;
        while (line < 4) : (line += 1) {
            var line_buf: [16]u8 = undefined;
            const s = try std.fmt.bufPrint(&line_buf, " {d}.{d}\n", .{ section, line });
            try e.encodeString(&.{s});
        }
        try e.flush();
    }

    var r: Reader = .fixed(w.buffered());
    var sc = Scanner.init(&r);
    var section_counter: usize = 0;
    var line_counter: usize = 0;
    while (sc.scan()) {
        if (sc.bytes().len == 0) section_counter += 1;
        line_counter += 1;
    }
    try testing.expect(sc.err() == null);
    try testing.expectEqual(@as(usize, 2), section_counter);
    try testing.expectEqual(@as(usize, (1 + 4) * 2), line_counter);
}

test "ErrorLine encode" {
    {
        var storage: [32]u8 = undefined;
        var w: Writer = .fixed(&storage);
        var el = ErrorLine{ .text = "something" };
        try el.encode(&w);
        try testing.expectEqualSlices(u8, "0012ERR something\n", w.buffered());
    }
    {
        var storage: [32]u8 = undefined;
        var w: Writer = .fixed(&storage);
        var el = ErrorLine{};
        try el.encode(&w);
        // "ERR \n" = 5 payload + 4 header = 9 = 0009
        try testing.expectEqualSlices(u8, "0009ERR \n", w.buffered());
    }
}

test "ErrorLine decode via scanner ERR" {
    var r: Reader = .fixed("000eERR foobar");
    var sc = Scanner.init(&r);
    try testing.expect(!sc.scan());
    try testing.expect(sc.err().? == error.ErrorLine);
    try testing.expectEqualSlices(u8, "foobar", sc.errorLineText());
}

test "ErrorLine decode with newline" {
    var r: Reader = .fixed("000fERR foobar\n");
    var el: ErrorLine = .{};
    const result = el.decode(&r);
    try testing.expectError(error.ErrorLine, result);
    try testing.expectEqualSlices(u8, "foobar", el.text);
}


test "constants" {
    try testing.expectEqual(@as(usize, 65516), MaxPayloadSize);
    try testing.expectEqual(@as(usize, 65520), OversizePayloadMax);
    try testing.expectEqualSlices(u8, "0000", &FlushPkt);
    try testing.expectEqual(@as(usize, 0), Flush.len);
    try testing.expectEqual(@as(usize, 0), FlushString.len);
}
