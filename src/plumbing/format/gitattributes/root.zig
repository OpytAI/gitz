//! Gitattributes parsing and matching — port of go-git `plumbing/format/gitattributes`.
//!
//! Reference: go-git v5.19.2 `plumbing/format/gitattributes/*.go`.

const attributes_mod = @import("attributes.zig");
const pattern_mod = @import("pattern.zig");
const matcher_mod = @import("matcher.zig");
const dir_mod = @import("dir.zig");

// --- attributes ---
pub const Attribute = attributes_mod.Attribute;
pub const MatchAttribute = attributes_mod.MatchAttribute;
pub const Error = attributes_mod.Error;
pub const ErrMacroNotAllowed = attributes_mod.ErrMacroNotAllowed;
pub const ErrInvalidAttributeName = attributes_mod.ErrInvalidAttributeName;
pub const freeMatchAttributes = attributes_mod.freeMatchAttributes;
pub const readAttributes = attributes_mod.readAttributes;
pub const parseAttributesLine = attributes_mod.parseAttributesLine;

// --- pattern ---
pub const Pattern = pattern_mod.Pattern;
pub const parsePattern = pattern_mod.parsePattern;

// --- matcher ---
pub const Matcher = matcher_mod.Matcher;
pub const MatcherOptions = matcher_mod.MatcherOptions;
pub const newMatcher = matcher_mod.newMatcher;

// --- dir ---
pub const readAttributesFile = dir_mod.readAttributesFile;
pub const readPatterns = dir_mod.readPatterns;
pub const loadGlobalPatterns = dir_mod.loadGlobalPatterns;
pub const loadSystemPatterns = dir_mod.loadSystemPatterns;

// go-git PascalCase aliases
pub const ParseAttributesLine = parseAttributesLine;
pub const ReadAttributes = readAttributes;
pub const ParsePattern = parsePattern;
pub const NewMatcher = newMatcher;
pub const ReadAttributesFile = readAttributesFile;
pub const ReadPatterns = readPatterns;
pub const LoadGlobalPatterns = loadGlobalPatterns;
pub const LoadSystemPatterns = loadSystemPatterns;
pub const FreeMatchAttributes = freeMatchAttributes;

test {
    _ = @import("attributes.zig");
    _ = @import("pattern.zig");
    _ = @import("matcher.zig");
    _ = @import("dir.zig");
}
