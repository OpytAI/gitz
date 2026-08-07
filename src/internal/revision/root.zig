//! Git revision string parser — port of go-git `internal/revision` (v5.19.2).
//!
//! Extracts revision components from strings per gitrevisions(7):
//! https://www.kernel.org/pub/software/scm/git/docs/gitrevisions.html
//!
//! # go-git surface
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `ErrInvalidRevision` | `ErrInvalidRevision` / `error.InvalidRevision` |
//! | `Revisioner` | `Revisioner` (tagged union) |
//! | `Ref` | `Ref` |
//! | `TildePath` | `TildePath` |
//! | `CaretPath` | `CaretPath` |
//! | `CaretReg` | `CaretReg` (pattern string, not compiled regexp) |
//! | `CaretType` | `CaretType` |
//! | `AtReflog` | `AtReflog` |
//! | `AtCheckout` | `AtCheckout` |
//! | `AtUpstream` | `AtUpstream` |
//! | `AtPush` | `AtPush` |
//! | `AtDate` | `AtDate` |
//! | `ColonReg` | `ColonReg` |
//! | `ColonPath` | `ColonPath` |
//! | `ColonStagePath` | `ColonStagePath` |
//! | `Parser` | `Parser` |
//! | `NewParserFromString` | `newParserFromString` / `Parser.initFromString` |
//! | `NewParser` | `newParser` / `Parser.init` |
//! | `(*Parser).Parse` | `Parser.parse` |
//! | scanner / tokens | `Scanner`, `Token` |

const std = @import("std");
const Allocator = std.mem.Allocator;

const token_mod = @import("token.zig");
const scanner_mod = @import("scanner.zig");
const parser_mod = @import("parser.zig");

pub const Token = token_mod.Token;

pub const Scanner = scanner_mod.Scanner;
pub const ScanResult = scanner_mod.ScanResult;
pub const max_revision_length = scanner_mod.max_revision_length;

pub const ErrInvalidRevision = parser_mod.ErrInvalidRevision;
pub const Error = parser_mod.Error;
pub const Ref = parser_mod.Ref;
pub const TildePath = parser_mod.TildePath;
pub const CaretPath = parser_mod.CaretPath;
pub const CaretReg = parser_mod.CaretReg;
pub const CaretType = parser_mod.CaretType;
pub const AtReflog = parser_mod.AtReflog;
pub const AtCheckout = parser_mod.AtCheckout;
pub const AtUpstream = parser_mod.AtUpstream;
pub const AtPush = parser_mod.AtPush;
pub const AtDate = parser_mod.AtDate;
pub const ColonReg = parser_mod.ColonReg;
pub const ColonPath = parser_mod.ColonPath;
pub const ColonStagePath = parser_mod.ColonStagePath;
pub const Revisioner = parser_mod.Revisioner;
pub const Parser = parser_mod.Parser;
pub const freeRevisioners = parser_mod.freeRevisioners;

/// go-git `NewParserFromString`.
pub fn newParserFromString(allocator: Allocator, s: []const u8) Parser {
    return Parser.initFromString(allocator, s);
}

/// go-git `NewParser` over a revision string (caller supplies full buffer).
pub fn newParser(allocator: Allocator, s: []const u8) Parser {
    return Parser.init(allocator, s);
}

/// Convenience: parse a revision string and return owned components.
pub fn parse(allocator: Allocator, s: []const u8) Error![]Revisioner {
    var p = newParserFromString(allocator, s);
    defer p.deinit();
    return p.parse();
}

test {
    _ = token_mod;
    _ = scanner_mod;
    _ = parser_mod;
}
