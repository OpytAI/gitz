//! Git config file format codec — port of go-git `plumbing/format/config`.
//!
//! Encodes and decodes `.git/config`-style text (sections, subsections, options).
//! This is the **format** package, not the high-level `config` package.
//!
//! Reference: go-git v5.19.2 `plumbing/format/config/*.go`.
//! Decoder parsing follows github.com/go-git/gcfg `ReadWithCallback` behaviour
//! (go-git v5.19.2 dependency).

const std = @import("std");

const common = @import("common.zig");
const section_mod = @import("section.zig");
const option_mod = @import("option.zig");
const format_mod = @import("format.zig");
const decoder_mod = @import("decoder.zig");
const encoder_mod = @import("encoder.zig");

// --- common ---
pub const Config = common.Config;
pub const Include = common.Include;
pub const Comment = common.Comment;
pub const NoSubsection = common.NoSubsection;

// --- section ---
pub const Section = section_mod.Section;
pub const Subsection = section_mod.Subsection;

// --- option ---
pub const Option = option_mod.Option;
pub const Options = option_mod.Options;
// Option helpers live on slices via option.zig (`get`/`has`/`getAll`);
// call `@import("option.zig")` from package modules rather than dual public names.

// --- format constants ---
pub const RepositoryFormatVersion = format_mod.RepositoryFormatVersion;
pub const Version0 = format_mod.Version0;
pub const Version1 = format_mod.Version1;
pub const DefaultRepositoryFormatVersion = format_mod.DefaultRepositoryFormatVersion;
pub const ObjectFormat = format_mod.ObjectFormat;
pub const SHA1 = format_mod.SHA1;
pub const SHA256 = format_mod.SHA256;
pub const DefaultObjectFormat = format_mod.DefaultObjectFormat;

// --- codec ---
pub const Decoder = decoder_mod.Decoder;
pub const Encoder = encoder_mod.Encoder;
pub const Error = decoder_mod.Error;

test {
    _ = @import("common.zig");
    _ = @import("section.zig");
    _ = @import("option.zig");
    _ = @import("format.zig");
    _ = @import("fixtures.zig");
    _ = @import("decoder.zig");
    _ = @import("encoder.zig");
}

test "format constants" {
    try std.testing.expectEqualStrings("0", Version0);
    try std.testing.expectEqualStrings("1", Version1);
    try std.testing.expectEqualStrings("0", DefaultRepositoryFormatVersion);
    try std.testing.expectEqualStrings("sha1", SHA1);
    try std.testing.expectEqualStrings("sha256", SHA256);
    try std.testing.expectEqualStrings("sha1", DefaultObjectFormat);
}

test "NoSubsection is empty string" {
    try std.testing.expectEqualStrings("", NoSubsection);
}
