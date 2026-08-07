//! Lexical scanner for git revision strings (go-git `internal/revision/scanner.go`).

const std = @import("std");
const unicode = std.unicode;
const Token = @import("token.zig").Token;

/// Maximum length parsed for a revision (go-git `maxRevisionLength` = 128 KiB).
pub const max_revision_length: usize = 128 * 1024;

/// One scan result: token kind and literal slice into the source buffer.
pub const ScanResult = struct {
    tok: Token,
    lit: []const u8,
};

/// Lexical scanner over a revision byte string (go-git unexported `scanner`).
///
/// Literals returned by `scan` borrow from `src` (or static single-char tables).
pub const Scanner = struct {
    src: []const u8,
    pos: usize = 0,

    /// go-git `newScanner` — input is limited to `max_revision_length`.
    pub fn init(src: []const u8) Scanner {
        const limited = if (src.len > max_revision_length) src[0..max_revision_length] else src;
        return .{ .src = limited };
    }

    /// go-git `(*scanner).scan` — next token and its literal.
    pub fn scan(self: *Scanner) ScanResult {
        const ch = self.readRune() orelse return .{ .tok = .eof, .lit = "" };

        switch (ch.cp) {
            0 => return .{ .tok = .eof, .lit = "" },
            ':' => return .{ .tok = .colon, .lit = self.litOf(ch) },
            '~' => return .{ .tok = .tilde, .lit = self.litOf(ch) },
            '^' => return .{ .tok = .caret, .lit = self.litOf(ch) },
            '.' => return .{ .tok = .dot, .lit = self.litOf(ch) },
            '/' => return .{ .tok = .slash, .lit = self.litOf(ch) },
            '{' => return .{ .tok = .obrace, .lit = self.litOf(ch) },
            '}' => return .{ .tok = .cbrace, .lit = self.litOf(ch) },
            '-' => return .{ .tok = .minus, .lit = self.litOf(ch) },
            '@' => return .{ .tok = .at, .lit = self.litOf(ch) },
            '\\' => return .{ .tok = .aslash, .lit = self.litOf(ch) },
            '?' => return .{ .tok = .qmark, .lit = self.litOf(ch) },
            '*' => return .{ .tok = .asterisk, .lit = self.litOf(ch) },
            '[' => return .{ .tok = .obracket, .lit = self.litOf(ch) },
            '!' => return .{ .tok = .emark, .lit = self.litOf(ch) },
            else => {},
        }

        if (isSpace(ch.cp)) return .{ .tok = .space, .lit = self.litOf(ch) };
        if (isControl(ch.cp)) return .{ .tok = .control, .lit = self.litOf(ch) };
        if (isLetter(ch.cp)) return self.tokenizeExpression(ch, .word, isLetter);
        if (isNumber(ch.cp)) return self.tokenizeExpression(ch, .number, isNumber);

        return .{ .tok = .token_error, .lit = self.litOf(ch) };
    }

    const Rune = struct {
        cp: u21,
        start: usize,
        len: usize,
    };

    fn litOf(self: *const Scanner, ch: Rune) []const u8 {
        return self.src[ch.start .. ch.start + ch.len];
    }

    fn readRune(self: *Scanner) ?Rune {
        if (self.pos >= self.src.len) return null;
        const start = self.pos;
        const seq_len = unicode.utf8ByteSequenceLength(self.src[start]) catch {
            // Invalid UTF-8: consume one byte as a raw code unit.
            self.pos += 1;
            return .{ .cp = self.src[start], .start = start, .len = 1 };
        };
        if (start + seq_len > self.src.len) {
            self.pos = self.src.len;
            return .{ .cp = self.src[start], .start = start, .len = 1 };
        }
        const cp = unicode.utf8Decode(self.src[start .. start + seq_len]) catch {
            self.pos += 1;
            return .{ .cp = self.src[start], .start = start, .len = 1 };
        };
        self.pos += seq_len;
        return .{ .cp = cp, .start = start, .len = seq_len };
    }

    fn unreadRune(self: *Scanner, ch: Rune) void {
        self.pos = ch.start;
    }

    fn tokenizeExpression(
        self: *Scanner,
        first: Rune,
        token_type: Token,
        comptime check: *const fn (u21) bool,
    ) ScanResult {
        const start = first.start;
        var end = first.start + first.len;
        while (true) {
            const c = self.readRune() orelse break;
            if (c.cp == 0) break;
            if (check(c.cp)) {
                end = c.start + c.len;
            } else {
                self.unreadRune(c);
                break;
            }
        }
        return .{ .tok = token_type, .lit = self.src[start..end] };
    }
};

// ---------------------------------------------------------------------------
// Character classes (approx. Go `unicode.Is*` for revision use)
// ---------------------------------------------------------------------------

fn isSpace(cp: u21) bool {
    // Go unicode.IsSpace: Latin-1 spaces + Unicode Zs/Zl/Zp subset commonly seen.
    return switch (cp) {
        ' ', '\t', '\n', '\r', '\x0c', '\x0b' => true,
        0x85, 0xA0 => true,
        0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn isControl(cp: u21) bool {
    // Go unicode.IsControl: Cc and Cf roughly.
    if (cp <= 0x1F) return true;
    if (cp >= 0x7F and cp <= 0x9F) return true;
    return switch (cp) {
        0xAD, 0x600...0x605, 0x61C, 0x6DD, 0x70F, 0x180E, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x206F, 0xFEFF, 0xFFF9...0xFFFB => true,
        else => false,
    };
}

fn isLetter(cp: u21) bool {
    if (cp < 128) return std.ascii.isAlphabetic(@intCast(cp));
    // Non-ASCII: treat as letter when not space/control/number (git refs are mostly ASCII).
    if (isSpace(cp) or isControl(cp) or isNumber(cp)) return false;
    // Exclude common punctuation / symbol ranges that Go would not count as letters.
    if (cp < 0xC0) return false;
    return true;
}

fn isNumber(cp: u21) bool {
    if (cp < 128) return std.ascii.isDigit(@intCast(cp));
    // Nd digits (subset).
    return switch (cp) {
        0x660...0x669, 0x6F0...0x6F9, 0x7C0...0x7C9, 0x966...0x96F, 0x9E6...0x9EF, 0xFF10...0xFF19 => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests (go-git scanner_test.go)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectToken(src: []const u8, want_tok: Token, want_lit: []const u8) !void {
    var s = Scanner.init(src);
    const r = s.scan();
    try testing.expectEqual(want_tok, r.tok);
    try testing.expectEqualStrings(want_lit, r.lit);
}

test "scanner colon" {
    try expectToken(":", .colon, ":");
}
test "scanner tilde" {
    try expectToken("~", .tilde, "~");
}
test "scanner caret" {
    try expectToken("^", .caret, "^");
}
test "scanner dot" {
    try expectToken(".", .dot, ".");
}
test "scanner slash" {
    try expectToken("/", .slash, "/");
}
test "scanner eof from null" {
    try expectToken(&[_]u8{0}, .eof, "");
}
test "scanner number" {
    try expectToken("1234", .number, "1234");
}
test "scanner space" {
    try expectToken(" ", .space, " ");
}
test "scanner control" {
    try expectToken(&[_]u8{0x01}, .control, &[_]u8{0x01});
}
test "scanner open brace" {
    try expectToken("{", .obrace, "{");
}
test "scanner close brace" {
    try expectToken("}", .cbrace, "}");
}
test "scanner minus" {
    try expectToken("-", .minus, "-");
}
test "scanner at" {
    try expectToken("@", .at, "@");
}
test "scanner antislash" {
    try expectToken("\\", .aslash, "\\");
}
test "scanner question mark" {
    try expectToken("?", .qmark, "?");
}
test "scanner asterisk" {
    try expectToken("*", .asterisk, "*");
}
test "scanner open bracket" {
    try expectToken("[", .obracket, "[");
}
test "scanner exclamation mark" {
    try expectToken("!", .emark, "!");
}
test "scanner word" {
    try expectToken("abcde", .word, "abcde");
}
test "scanner token error" {
    try expectToken("`", .token_error, "`");
}
test "scanner empty is eof" {
    try expectToken("", .eof, "");
}
