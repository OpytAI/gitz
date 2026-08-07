//! ANSI color escape strings — port of go-git `plumbing/color`.
//!
//! Colors. See https://github.com/git/git/blob/v2.26.2/color.h#L24-L53
//! and go-git `plumbing/color/color.go`.

const std = @import("std");

// --- Public API (go-git names) ---

/// Empty string (no color).
pub const Normal = "";

/// Reset all attributes: ESC [ m
pub const Reset = "\x1b[m";

/// Bold: ESC [ 1 m
pub const Bold = "\x1b[1m";

/// Red foreground: ESC [ 31 m
pub const Red = "\x1b[31m";

/// Green foreground: ESC [ 32 m
pub const Green = "\x1b[32m";

/// Yellow foreground: ESC [ 33 m
pub const Yellow = "\x1b[33m";

/// Blue foreground: ESC [ 34 m
pub const Blue = "\x1b[34m";

/// Magenta foreground: ESC [ 35 m
pub const Magenta = "\x1b[35m";

/// Cyan foreground: ESC [ 36 m
pub const Cyan = "\x1b[36m";

/// White foreground: ESC [ 37 m (inventory / common ANSI; not in go-git const block).
pub const White = "\x1b[37m";

/// Bold red: ESC [ 1;31 m
pub const BoldRed = "\x1b[1;31m";

/// Bold green: ESC [ 1;32 m
pub const BoldGreen = "\x1b[1;32m";

/// Bold yellow: ESC [ 1;33 m
pub const BoldYellow = "\x1b[1;33m";

/// Bold blue: ESC [ 1;34 m
pub const BoldBlue = "\x1b[1;34m";

/// Bold magenta: ESC [ 1;35 m
pub const BoldMagenta = "\x1b[1;35m";

/// Bold cyan: ESC [ 1;36 m
pub const BoldCyan = "\x1b[1;36m";

/// Faint red: ESC [ 2;31 m
pub const FaintRed = "\x1b[2;31m";

/// Faint green: ESC [ 2;32 m
pub const FaintGreen = "\x1b[2;32m";

/// Faint yellow: ESC [ 2;33 m
pub const FaintYellow = "\x1b[2;33m";

/// Faint blue: ESC [ 2;34 m
pub const FaintBlue = "\x1b[2;34m";

/// Faint magenta: ESC [ 2;35 m
pub const FaintMagenta = "\x1b[2;35m";

/// Faint cyan: ESC [ 2;36 m
pub const FaintCyan = "\x1b[2;36m";

/// Red background: ESC [ 41 m
pub const BgRed = "\x1b[41m";

/// Green background: ESC [ 42 m
pub const BgGreen = "\x1b[42m";

/// Yellow background: ESC [ 43 m
pub const BgYellow = "\x1b[43m";

/// Blue background: ESC [ 44 m
pub const BgBlue = "\x1b[44m";

/// Magenta background: ESC [ 45 m
pub const BgMagenta = "\x1b[45m";

/// Cyan background: ESC [ 46 m
pub const BgCyan = "\x1b[46m";

/// Faint: ESC [ 2 m
pub const Faint = "\x1b[2m";

/// Faint italic: ESC [ 2;3 m
pub const FaintItalic = "\x1b[2;3m";

/// Reverse video: ESC [ 7 m
pub const Reverse = "\x1b[7m";

test "ansi escape values match go-git" {
    try std.testing.expectEqualStrings("", Normal);
    try std.testing.expectEqualStrings("\x1b[m", Reset);
    try std.testing.expectEqualStrings("\x1b[1m", Bold);
    try std.testing.expectEqualStrings("\x1b[31m", Red);
    try std.testing.expectEqualStrings("\x1b[32m", Green);
    try std.testing.expectEqualStrings("\x1b[33m", Yellow);
    try std.testing.expectEqualStrings("\x1b[34m", Blue);
    try std.testing.expectEqualStrings("\x1b[35m", Magenta);
    try std.testing.expectEqualStrings("\x1b[36m", Cyan);
    try std.testing.expectEqualStrings("\x1b[37m", White);
    try std.testing.expectEqualStrings("\x1b[1;31m", BoldRed);
    try std.testing.expectEqualStrings("\x1b[1;32m", BoldGreen);
    try std.testing.expectEqualStrings("\x1b[1;33m", BoldYellow);
    try std.testing.expectEqualStrings("\x1b[1;34m", BoldBlue);
    try std.testing.expectEqualStrings("\x1b[1;35m", BoldMagenta);
    try std.testing.expectEqualStrings("\x1b[1;36m", BoldCyan);
    try std.testing.expectEqualStrings("\x1b[2;31m", FaintRed);
    try std.testing.expectEqualStrings("\x1b[2;32m", FaintGreen);
    try std.testing.expectEqualStrings("\x1b[2;33m", FaintYellow);
    try std.testing.expectEqualStrings("\x1b[2;34m", FaintBlue);
    try std.testing.expectEqualStrings("\x1b[2;35m", FaintMagenta);
    try std.testing.expectEqualStrings("\x1b[2;36m", FaintCyan);
    try std.testing.expectEqualStrings("\x1b[41m", BgRed);
    try std.testing.expectEqualStrings("\x1b[42m", BgGreen);
    try std.testing.expectEqualStrings("\x1b[43m", BgYellow);
    try std.testing.expectEqualStrings("\x1b[44m", BgBlue);
    try std.testing.expectEqualStrings("\x1b[45m", BgMagenta);
    try std.testing.expectEqualStrings("\x1b[46m", BgCyan);
    try std.testing.expectEqualStrings("\x1b[2m", Faint);
    try std.testing.expectEqualStrings("\x1b[2;3m", FaintItalic);
    try std.testing.expectEqualStrings("\x1b[7m", Reverse);
}
