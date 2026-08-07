//! HFS+ path-component security helpers — go-git internal/pathutil/hfs.go.

const std = @import("std");

/// Unicode code points that HFS+ ignores during path normalisation.
/// See upstream Git utf8.c next_hfs_char (v2.54.0).
fn isHfsIgnoredCodepoint(r: u21) bool {
    return switch (r) {
        0x200c, // ZERO WIDTH NON-JOINER
        0x200d, // ZERO WIDTH JOINER
        0x200e, // LEFT-TO-RIGHT MARK
        0x200f, // RIGHT-TO-LEFT MARK
        0x202a, // LEFT-TO-RIGHT EMBEDDING
        0x202b, // RIGHT-TO-LEFT EMBEDDING
        0x202c, // POP DIRECTIONAL FORMATTING
        0x202d, // LEFT-TO-RIGHT OVERRIDE
        0x202e, // RIGHT-TO-LEFT OVERRIDE
        0x206a, // INHIBIT SYMMETRIC SWAPPING
        0x206b, // ACTIVATE SYMMETRIC SWAPPING
        0x206c, // INHIBIT ARABIC FORM SHAPING
        0x206d, // ACTIVATE ARABIC FORM SHAPING
        0x206e, // NATIONAL DIGIT SHAPES
        0x206f, // NOMINAL DIGIT SHAPES
        0xfeff, // ZERO WIDTH NO-BREAK SPACE
        => true,
        else => false,
    };
}

const Decoded = struct { r: u21, n: usize };

/// Decode one UTF-8 rune. Invalid sequences yield U+FFFD with n=1 (Go []rune).
fn decodeRune(s: []const u8) Decoded {
    if (s.len == 0) return .{ .r = 0xFFFD, .n = 0 };
    const seq_len = std.unicode.utf8ByteSequenceLength(s[0]) catch {
        return .{ .r = 0xFFFD, .n = 1 };
    };
    if (seq_len > s.len) return .{ .r = 0xFFFD, .n = 1 };
    const r = std.unicode.utf8Decode(s[0..seq_len]) catch {
        return .{ .r = 0xFFFD, .n = 1 };
    };
    return .{ .r = r, .n = seq_len };
}

/// Skip ignored HFS+ code points starting at `pos` in `part`. Returns new index.
fn skipIgnored(part: []const u8, pos: usize) usize {
    var i = pos;
    while (i < part.len) {
        const d = decodeRune(part[i..]);
        if (d.n == 0) break;
        if (!isHfsIgnoredCodepoint(d.r)) break;
        i += d.n;
    }
    return i;
}

/// Reports whether part would be treated as ".\<needle>" on an HFS+ filesystem
/// after stripping ignored Unicode code points and folding ASCII to lower case.
/// `needle` is the lowercase ASCII suffix without the leading dot
/// (e.g. "git", "gitmodules").
///
/// Port of go-git `pathutil.IsHFSDot`.
pub fn isHFSDot(part: []const u8, needle: []const u8) bool {
    var i: usize = 0;

    // skip ignored code points, then expect '.'
    i = skipIgnored(part, i);
    if (i >= part.len) return false;
    const d0 = decodeRune(part[i..]);
    if (d0.r != '.') return false;
    i += d0.n;

    // match needle case-insensitively, skipping ignored code points
    for (needle) |expected| {
        i = skipIgnored(part, i);
        if (i >= part.len) return false;
        const d = decodeRune(part[i..]);
        if (d.r > 127) return false;
        const lower: u8 = if (d.r >= 'A' and d.r <= 'Z')
            @intCast(d.r + ('a' - 'A'))
        else
            @intCast(d.r);
        if (lower != expected) return false;
        i += d.n;
    }

    // skip trailing ignored code points
    i = skipIgnored(part, i);

    // must be at end of component
    return i == part.len;
}

/// Reports whether part is an HFS+ equivalent of ".git".
/// Port of go-git `pathutil.IsHFSDotGit`.
pub fn isHFSDotGit(part: []const u8) bool {
    return isHFSDot(part, "git");
}

/// Reports whether part is an HFS+ equivalent of ".gitmodules".
/// Port of go-git `pathutil.IsHFSDotGitmodules`.
pub fn isHFSDotGitmodules(part: []const u8) bool {
    return isHFSDot(part, "gitmodules");
}

// ---------------------------------------------------------------------------
// Tests (from hfs_test.go)
// ---------------------------------------------------------------------------

test "IsHFSDotGit table" {
    const Case = struct { part: []const u8, want: bool };
    // Unicode escapes as UTF-8 byte sequences matching Go test strings.
    const zwnj = "\u{200c}";
    const zwj = "\u{200d}";
    const zwsp = "\u{feff}";
    const lrm = "\u{200e}";

    const cases = [_]Case{
        .{ .part = ".git", .want = true },
        .{ .part = ".Git", .want = true },
        .{ .part = ".GIT", .want = true },
        .{ .part = ".gIt", .want = true },
        .{ .part = ".g" ++ zwnj ++ "it", .want = true },
        .{ .part = ".gi" ++ zwj ++ "t", .want = true },
        .{ .part = ".gi" ++ zwsp ++ "t", .want = true },
        .{ .part = lrm ++ ".git", .want = true },
        .{ .part = ".g" ++ zwnj ++ "i" ++ zwj ++ "t", .want = true },
        .{ .part = ".gitmodules", .want = false },
        .{ .part = ".gitignore", .want = false },
        .{ .part = ".git2", .want = false },
        .{ .part = "git", .want = false },
        .{ .part = ".gxt", .want = false },
        .{ .part = "", .want = false },
        .{ .part = ".", .want = false },
        .{ .part = ".g\x80it", .want = false },
    };
    for (cases) |tc| {
        try std.testing.expectEqual(tc.want, isHFSDotGit(tc.part));
    }
}

test "IsHFSDot table" {
    const zwnj = "\u{200c}";
    const zwj = "\u{200d}";
    const zwsp = "\u{feff}";
    const lrm = "\u{200e}";

    const Case = struct { part: []const u8, needle: []const u8, want: bool };
    const cases = [_]Case{
        .{ .part = ".git", .needle = "git", .want = true },
        .{ .part = ".g" ++ zwj ++ "it", .needle = "git", .want = true },
        .{ .part = ".g" ++ zwnj ++ "it", .needle = "git", .want = true },
        .{ .part = lrm ++ ".git", .needle = "git", .want = true },
        .{ .part = ".gitmodules", .needle = "git", .want = false },
        .{ .part = "", .needle = "git", .want = false },
        .{ .part = ".gitmodules", .needle = "gitmodules", .want = true },
        .{ .part = ".GITMODULES", .needle = "gitmodules", .want = true },
        .{ .part = ".g" ++ zwnj ++ "itmodules", .needle = "gitmodules", .want = true },
        .{ .part = ".gitmod" ++ zwj ++ "ules", .needle = "gitmodules", .want = true },
        .{ .part = ".gitmodules" ++ zwsp, .needle = "gitmodules", .want = true },
        .{ .part = lrm ++ ".gitmodules", .needle = "gitmodules", .want = true },
        .{ .part = ".gitmodulesfoo", .needle = "gitmodules", .want = false },
        .{ .part = ".git", .needle = "gitmodules", .want = false },
        .{ .part = "readme.md", .needle = "gitmodules", .want = false },
        .{ .part = "", .needle = "gitmodules", .want = false },
        .{ .part = ".", .needle = "gitmodules", .want = false },
        .{ .part = ".g\x80itmodules", .needle = "gitmodules", .want = false },
    };
    for (cases) |tc| {
        try std.testing.expectEqual(tc.want, isHFSDot(tc.part, tc.needle));
    }
}

test "IsHFSDotGitmodules table" {
    const zwnj = "\u{200c}";
    const zwj = "\u{200d}";
    const zwsp = "\u{feff}";
    const lrm = "\u{200e}";

    const Case = struct { part: []const u8, want: bool };
    const cases = [_]Case{
        .{ .part = ".gitmodules", .want = true },
        .{ .part = ".GITMODULES", .want = true },
        .{ .part = ".g" ++ zwnj ++ "itmodules", .want = true },
        .{ .part = ".gitmod" ++ zwj ++ "ules", .want = true },
        .{ .part = lrm ++ ".gitmodules", .want = true },
        .{ .part = ".gitmodules" ++ zwsp, .want = true },
        .{ .part = ".gitmodulesfoo", .want = false },
        .{ .part = ".git", .want = false },
        .{ .part = "readme.md", .want = false },
        .{ .part = "", .want = false },
    };
    for (cases) |tc| {
        try std.testing.expectEqual(tc.want, isHFSDotGitmodules(tc.part));
    }
}
