//! Gitignore pattern matching — port of go-git `plumbing/format/gitignore`.
//!
//! Reference: go-git v5.19.2 `plumbing/format/gitignore/*.go`.

const pattern_mod = @import("pattern.zig");
const matcher_mod = @import("matcher.zig");
const dir_mod = @import("dir.zig");

// --- pattern ---
pub const MatchResult = pattern_mod.MatchResult;
pub const Pattern = pattern_mod.Pattern;
pub const parsePattern = pattern_mod.parsePattern;

// --- matcher ---
pub const Matcher = matcher_mod.Matcher;
pub const newMatcher = matcher_mod.newMatcher;

// --- dir / loaders ---
pub const freePatterns = dir_mod.freePatterns;
pub const readPatterns = dir_mod.readPatterns;
pub const loadGlobalPatterns = dir_mod.loadGlobalPatterns;
pub const loadSystemPatterns = dir_mod.loadSystemPatterns;

// go-git exported names (PascalCase aliases for inventory / call-site parity).
pub const ParsePattern = parsePattern;
pub const NewMatcher = newMatcher;
pub const ReadPatterns = readPatterns;
pub const LoadGlobalPatterns = loadGlobalPatterns;
pub const LoadSystemPatterns = loadSystemPatterns;
pub const FreePatterns = freePatterns;

test {
    _ = @import("pattern.zig");
    _ = @import("matcher.zig");
    _ = @import("dir.zig");
}
