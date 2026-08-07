//! Decode git-config text into a Config tree.
//!
//! Port of go-git v5.19.2 `plumbing/format/config/decoder.go`, with lexer /
//! callback logic aligned to github.com/go-git/gcfg (ReadWithCallback).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const common = @import("common.zig");

const Config = common.Config;

/// Parse / decode error (any non-nil go-git/gcfg error maps here).
pub const Error = error{
    ParseError,
    OutOfMemory,
    ReadFailed,
    StreamTooLong,
};

/// Reads and decodes config files from an input stream.
pub const Decoder = struct {
    reader: *Reader,

    pub fn init(r: *Reader) Decoder {
        return .{ .reader = r };
    }

    /// Read the whole config from the input and store it in `config`.
    pub fn decode(self: *Decoder, config: *Config) Error!void {
        const src = self.reader.allocRemaining(config.allocator, .unlimited) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed => return error.ReadFailed,
            error.StreamTooLong => return error.StreamTooLong,
        };
        defer config.allocator.free(src);
        try parseInto(config, src);
    }
};

// ---------------------------------------------------------------------------
// Lexer tokens (gcfg token package subset)
// ---------------------------------------------------------------------------

const Token = enum {
    eof,
    comment,
    ident,
    string,
    assign,
    lbrack,
    rbrack,
    eol,
    illegal,
};

const Lexeme = struct {
    tok: Token,
    lit: []const u8 = "",
};

const Scanner = struct {
    src: []const u8,
    offset: usize = 0,
    /// After '=', next token is a value string (gcfg `nextVal`).
    next_val: bool = false,
    err_count: usize = 0,

    fn init(src: []const u8) Scanner {
        return .{ .src = src };
    }

    fn peek(self: *const Scanner) u8 {
        if (self.offset >= self.src.len) return 0;
        return self.src[self.offset];
    }

    fn atEnd(self: *const Scanner) bool {
        return self.offset >= self.src.len;
    }

    fn advance(self: *Scanner) void {
        if (self.offset < self.src.len) self.offset += 1;
    }

    fn skipWhitespace(self: *Scanner) void {
        while (!self.atEnd()) {
            switch (self.peek()) {
                ' ', '\t', '\r' => self.advance(),
                else => break,
            }
        }
    }

    fn isLetter(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch >= 0x80;
    }

    fn isDigit(ch: u8) bool {
        return ch >= '0' and ch <= '9';
    }

    fn isIdentChar(ch: u8) bool {
        return isLetter(ch) or isDigit(ch) or ch == '-';
    }

    fn scan(self: *Scanner) Lexeme {
        self.skipWhitespace();
        if (self.atEnd()) return .{ .tok = .eof };

        if (self.next_val) {
            self.next_val = false;
            return self.scanValString();
        }

        const ch = self.peek();
        if (isLetter(ch)) {
            return self.scanIdentifier();
        }

        self.advance();
        switch (ch) {
            '\n' => return .{ .tok = .eol },
            '"' => return self.scanQuotedString(),
            '[' => return .{ .tok = .lbrack },
            ']' => return .{ .tok = .rbrack },
            ';', '#' => {
                // Skip comment to end of line (gcfg without ScanComments).
                while (!self.atEnd() and self.peek() != '\n') self.advance();
                return .{ .tok = .comment };
            },
            '=' => {
                self.next_val = true;
                return .{ .tok = .assign };
            },
            else => {
                self.err_count += 1;
                return .{ .tok = .illegal, .lit = self.src[self.offset - 1 .. self.offset] };
            },
        }
    }

    fn scanIdentifier(self: *Scanner) Lexeme {
        const start = self.offset;
        while (!self.atEnd() and isIdentChar(self.peek())) self.advance();
        return .{ .tok = .ident, .lit = self.src[start..self.offset] };
    }

    fn scanQuotedString(self: *Scanner) Lexeme {
        // Opening '"' already consumed.
        const start = self.offset - 1;
        while (!self.atEnd() and self.peek() != '"') {
            const c = self.peek();
            self.advance();
            if (c == '\n') {
                self.err_count += 1;
                break;
            }
            if (c == '\\') {
                if (self.atEnd()) {
                    self.err_count += 1;
                    break;
                }
                // Escape: consume next (validated loosely; unquote re-checks).
                self.advance();
            }
        }
        if (!self.atEnd() and self.peek() == '"') {
            self.advance();
        } else {
            self.err_count += 1;
        }
        return .{ .tok = .string, .lit = self.src[start..self.offset] };
    }

    fn scanValString(self: *Scanner) Lexeme {
        const start = self.offset;
        var end = start;
        var in_quote = false;
        while (!self.atEnd()) {
            const c = self.peek();
            if (!in_quote and (c == '\n' or c == ';' or c == '#')) break;
            self.advance();
            switch (c) {
                '\\' => {
                    if (in_quote) {
                        if (!self.atEnd()) self.advance();
                    } else {
                        // Line continuation: \ [CR] LF
                        if (!self.atEnd() and self.peek() == '\r') self.advance();
                        if (!self.atEnd() and self.peek() == '\n') {
                            self.advance();
                        } else if (!self.atEnd()) {
                            self.advance(); // escape char
                        }
                    }
                },
                '"' => in_quote = !in_quote,
                '\n' => {
                    if (in_quote) {
                        self.err_count += 1;
                    }
                    // Value cannot contain raw newline outside quotes handling above.
                    break;
                },
                else => {},
            }
            // Track last non-whitespace when not in quotes (trim trailing ws).
            if (in_quote or (c != ' ' and c != '\t' and c != '\r')) {
                end = self.offset;
            }
        }
        if (in_quote) self.err_count += 1;
        return .{ .tok = .string, .lit = self.src[start..end] };
    }
};

/// Unquote a gcfg STRING literal (subsection header or value).
/// Mirrors gcfg `unquote`.
fn unquote(allocator: Allocator, s: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var q = false;
    var esc = false;
    for (s) |c| {
        if (esc) {
            const mapped: ?u8 = switch (c) {
                '\\' => '\\',
                '"' => '"',
                'n' => '\n',
                't' => '\t',
                'b' => 0x08,
                '\n' => null, // line continuation outside quotes: drop
                else => return error.ParseError,
            };
            if (mapped) |m| {
                try out.append(allocator, m);
            } else if (q) {
                // `\n` inside quotes is newline via 'n' case; bare newline after \ outside handled.
                return error.ParseError;
            }
            // When !q and c == '\n', drop (continuation).
            esc = false;
            continue;
        }
        switch (c) {
            '"' => q = !q,
            '\\' => esc = true,
            else => try out.append(allocator, c),
        }
    }
    if (q or esc) return error.ParseError;
    return try out.toOwnedSlice(allocator);
}

fn parseInto(config: *Config, src: []const u8) Error!void {
    var sc = Scanner.init(src);
    var sect: []const u8 = "";
    var sectsub: []const u8 = "";
    // Owned copies of current section/subsection names for the scan lifetime.
    var sect_owned: ?[]u8 = null;
    var sectsub_owned: ?[]u8 = null;
    defer {
        if (sect_owned) |p| config.allocator.free(p);
        if (sectsub_owned) |p| config.allocator.free(p);
    }

    var lex = sc.scan();
    while (true) {
        if (sc.err_count > 0) return error.ParseError;

        switch (lex.tok) {
            .eof => return,
            .eol, .comment => {
                lex = sc.scan();
            },
            .lbrack => {
                lex = sc.scan();
                if (sc.err_count > 0) return error.ParseError;
                if (lex.tok != .ident) return error.ParseError;

                // Replace current section name.
                if (sect_owned) |p| config.allocator.free(p);
                sect_owned = try config.allocator.dupe(u8, lex.lit);
                sect = sect_owned.?;
                if (sectsub_owned) |p| {
                    config.allocator.free(p);
                    sectsub_owned = null;
                }
                sectsub = "";

                lex = sc.scan();
                if (sc.err_count > 0) return error.ParseError;

                if (lex.tok == .string) {
                    const raw = try unquote(config.allocator, lex.lit);
                    defer config.allocator.free(raw);
                    if (raw.len == 0) return error.ParseError;
                    if (sectsub_owned) |p| config.allocator.free(p);
                    sectsub_owned = try config.allocator.dupe(u8, raw);
                    sectsub = sectsub_owned.?;
                    lex = sc.scan();
                    if (sc.err_count > 0) return error.ParseError;
                }

                if (lex.tok != .rbrack) return error.ParseError;

                lex = sc.scan();
                if (lex.tok != .eol and lex.tok != .eof and lex.tok != .comment) {
                    return error.ParseError;
                }

                // Ensure section/subsection container exists (gcfg callback).
                if (sectsub.len == 0) {
                    _ = try config.section(sect);
                } else {
                    _ = try (try config.section(sect)).subsection(sectsub);
                }
            },
            .ident => {
                if (sect.len == 0) return error.ParseError;
                const key = lex.lit;
                lex = sc.scan();
                if (sc.err_count > 0) return error.ParseError;

                const blank = lex.tok == .eof or lex.tok == .eol or lex.tok == .comment;
                var value_owned: ?[]u8 = null;
                defer if (value_owned) |v| config.allocator.free(v);

                if (!blank) {
                    if (lex.tok != .assign) return error.ParseError;
                    lex = sc.scan();
                    if (sc.err_count > 0) return error.ParseError;
                    if (lex.tok != .string) return error.ParseError;
                    value_owned = try unquote(config.allocator, lex.lit);
                    lex = sc.scan();
                    if (sc.err_count > 0) return error.ParseError;
                    if (lex.tok != .eol and lex.tok != .eof and lex.tok != .comment) {
                        return error.ParseError;
                    }
                }

                const value: []const u8 = if (value_owned) |v| v else "";
                // blank flag ignored by go-git decoder — store empty value.
                _ = try config.addOption(sect, sectsub, key, value);
            },
            else => {
                if (sect.len == 0) return error.ParseError;
                return error.ParseError;
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Equality helpers for tests
// ---------------------------------------------------------------------------

fn configsEqual(a: *const Config, b: *const Config) bool {
    if (a.sections.items.len != b.sections.items.len) return false;
    for (a.sections.items, b.sections.items) |sa, sb| {
        if (!std.mem.eql(u8, sa.name, sb.name)) return false;
        if (sa.options.items.len != sb.options.items.len) return false;
        for (sa.options.items, sb.options.items) |oa, ob| {
            if (!std.mem.eql(u8, oa.key, ob.key)) return false;
            if (!std.mem.eql(u8, oa.value, ob.value)) return false;
        }
        if (sa.subsections.items.len != sb.subsections.items.len) return false;
        for (sa.subsections.items, sb.subsections.items) |ssa, ssb| {
            if (!std.mem.eql(u8, ssa.name, ssb.name)) return false;
            if (ssa.options.items.len != ssb.options.items.len) return false;
            for (ssa.options.items, ssb.options.items) |oa, ob| {
                if (!std.mem.eql(u8, oa.key, ob.key)) return false;
                if (!std.mem.eql(u8, oa.value, ob.value)) return false;
            }
        }
    }
    return true;
}

fn decodeString(allocator: Allocator, text: []const u8) Error!Config {
    var r = Reader.fixed(text);
    var d = Decoder.init(&r);
    var cfg = common.Config.init(allocator);
    errdefer cfg.deinit();
    try d.decode(&cfg);
    return cfg;
}

fn decodeFails(allocator: Allocator, text: []const u8) !void {
    var r = Reader.fixed(text);
    var d = Decoder.init(&r);
    var cfg = common.Config.init(allocator);
    defer cfg.deinit();
    try std.testing.expectError(error.ParseError, d.decode(&cfg));
}

// ---------------------------------------------------------------------------
// Tests (go-git decoder_test.go + fixtures_test.go)
// ---------------------------------------------------------------------------

test "Decoder empty and comments only" {
    const gpa = std.testing.allocator;
    {
        var cfg = try decodeString(gpa, "");
        defer cfg.deinit();
        try std.testing.expectEqual(@as(usize, 0), cfg.sections.items.len);
    }
    {
        var cfg = try decodeString(gpa, ";Comments only");
        defer cfg.deinit();
        try std.testing.expectEqual(@as(usize, 0), cfg.sections.items.len);
    }
    {
        var cfg = try decodeString(gpa, "#Comments only");
        defer cfg.deinit();
        try std.testing.expectEqual(@as(usize, 0), cfg.sections.items.len);
    }
}

test "Decoder core repositoryformatversion" {
    const gpa = std.testing.allocator;
    const raws = [_][]const u8{
        "[core]\nrepositoryformatversion=0",
        "[core]\n\trepositoryformatversion = 0\n",
        ";Commment\n[core]\n;Comment\nrepositoryformatversion = 0\n",
        "#Commment\n#Comment\n[core]\n#Comment\nrepositoryformatversion = 0\n",
    };
    for (raws) |raw| {
        var cfg = try decodeString(gpa, raw);
        defer cfg.deinit();
        var expected = common.Config.init(gpa);
        defer expected.deinit();
        _ = try expected.addOption("core", "", "repositoryformatversion", "0");
        try std.testing.expect(configsEqual(&cfg, &expected));
    }
}

test "Decoder special characters" {
    const gpa = std.testing.allocator;
    // Indent with real tabs via double-quoted escapes (multiline \\ cannot hold raw tabs).
    const raw = "[section]\n" ++
        "\toption1 = \"has # hash\"\n" ++
        "\toption2 = \"has \\\" quote\"\n" ++
        "\toption3 = \"has \\\\ backslash\"\n" ++
        "\toption4 = \"has ; semicolon\"\n" ++
        "\toption5 = \"has \\n line-feed\"\n" ++
        "\toption6 = \"has \\t tab\"\n" ++
        "\toption7 = \"  has leading spaces\"\n" ++
        "\toption8 = \"has trailing spaces  \"\n" ++
        "\toption9 = has no special characters\n" ++
        "\toption10 = has unusual \x01\x7f\u{0200} characters\n";
    var cfg = try decodeString(gpa, raw);
    defer cfg.deinit();
    var expected = common.Config.init(gpa);
    defer expected.deinit();
    _ = try expected.addOption("section", "", "option1", "has # hash");
    _ = try expected.addOption("section", "", "option2", "has \" quote");
    _ = try expected.addOption("section", "", "option3", "has \\ backslash");
    _ = try expected.addOption("section", "", "option4", "has ; semicolon");
    _ = try expected.addOption("section", "", "option5", "has \n line-feed");
    _ = try expected.addOption("section", "", "option6", "has \t tab");
    _ = try expected.addOption("section", "", "option7", "  has leading spaces");
    _ = try expected.addOption("section", "", "option8", "has trailing spaces  ");
    _ = try expected.addOption("section", "", "option9", "has no special characters");
    _ = try expected.addOption("section", "", "option10", "has unusual \x01\x7f\u{0200} characters");
    try std.testing.expect(configsEqual(&cfg, &expected));
}

test "Decoder sections subsections multi" {
    const gpa = std.testing.allocator;
    {
        const raw =
            \\[sect1]
            \\opt1 = value1
            \\[sect1 "subsect1"]
            \\opt2 = value2
            \\
        ;
        var cfg = try decodeString(gpa, raw);
        defer cfg.deinit();
        var expected = common.Config.init(gpa);
        defer expected.deinit();
        _ = try expected.addOption("sect1", "", "opt1", "value1");
        _ = try expected.addOption("sect1", "subsect1", "opt2", "value2");
        try std.testing.expect(configsEqual(&cfg, &expected));
    }
    {
        const raw =
            \\[sect1]
            \\opt1 = value1
            \\[sect1 "subsect1"]
            \\opt2 = value2
            \\[sect1]
            \\opt1 = value1b
            \\[sect1 "subsect1"]
            \\opt2 = value2b
            \\[sect1 "subsect2"]
            \\opt2 = value2
            \\
        ;
        var cfg = try decodeString(gpa, raw);
        defer cfg.deinit();
        var expected = common.Config.init(gpa);
        defer expected.deinit();
        _ = try expected.addOption("sect1", "", "opt1", "value1");
        _ = try expected.addOption("sect1", "", "opt1", "value1b");
        _ = try expected.addOption("sect1", "subsect1", "opt2", "value2");
        _ = try expected.addOption("sect1", "subsect1", "opt2", "value2b");
        _ = try expected.addOption("sect1", "subsect2", "opt2", "value2");
        try std.testing.expect(configsEqual(&cfg, &expected));
    }
    {
        const raw =
            \\[sect1]
            \\opt1 = value1
            \\opt1 = value2
            \\
        ;
        var cfg = try decodeString(gpa, raw);
        defer cfg.deinit();
        var expected = common.Config.init(gpa);
        defer expected.deinit();
        _ = try expected.addOption("sect1", "", "opt1", "value1");
        _ = try expected.addOption("sect1", "", "opt1", "value2");
        try std.testing.expect(configsEqual(&cfg, &expected));
    }
}

test "Decoder failure cases" {
    const gpa = std.testing.allocator;
    try decodeFails(gpa, "key=value\n[section]\nkey=value\n");
    try decodeFails(gpa, "[]\nkey=value\n");
    try decodeFails(gpa, "[remote \"\"]\nkey=value\n");
    try decodeFails(gpa, "[remote origin\"]\nkey=value\n");
    try decodeFails(gpa, "[remote \"origin]\nkey=value\n");
    try decodeFails(gpa, "[remote]garbage\nkey=value\n");
    try decodeFails(gpa, "[remote \"origin\"]garbage\nkey=value\n");
    try decodeFails(gpa, "---");
    try decodeFails(gpa, "????");
    try decodeFails(gpa, "[sect\nkey=value");
    try decodeFails(gpa, "sect]\nkey=value");
    try decodeFails(gpa, "[section]key=\"value");
    try decodeFails(gpa, "[section]key=value\"");
}

test "Decoder round-trip with Encoder" {
    const gpa = std.testing.allocator;
    const encoder = @import("encoder.zig");
    const Writer = std.Io.Writer;

    var cfg = common.Config.init(gpa);
    defer cfg.deinit();
    _ = try cfg.addOption("sect1", "", "opt1", "value1");
    _ = try cfg.addOption("sect1", "", "opt1", "value1b");
    _ = try cfg.addOption("sect1", "subsect1", "opt2", "value2");
    _ = try cfg.addOption("sect1", "subsect1", "opt2", "value2b");
    _ = try cfg.addOption("sect1", "subsect2", "opt2", "value2");

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = encoder.Encoder.init(&aw.writer);
    try enc.encode(&cfg);

    const expected_text = "[sect1]\n" ++
        "\topt1 = value1\n" ++
        "\topt1 = value1b\n" ++
        "[sect1 \"subsect1\"]\n" ++
        "\topt2 = value2\n" ++
        "\topt2 = value2b\n" ++
        "[sect1 \"subsect2\"]\n" ++
        "\topt2 = value2\n";
    try std.testing.expectEqualStrings(expected_text, aw.written());

    var decoded = try decodeString(gpa, aw.written());
    defer decoded.deinit();
    try std.testing.expect(configsEqual(&cfg, &decoded));
}
