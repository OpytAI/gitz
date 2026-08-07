//! Encode a Config tree as git-config text.
//!
//! Port of go-git v5.19.2 `plumbing/format/config/encoder.go`.

const std = @import("std");
const Writer = std.Io.Writer;
const common = @import("common.zig");
const section_mod = @import("section.zig");
const option_mod = @import("option.zig");

const Config = common.Config;
const Section = section_mod.Section;
const Subsection = section_mod.Subsection;
const Options = option_mod.Options;

/// Writes config files to an output stream.
pub const Encoder = struct {
    writer: *Writer,

    pub fn init(w: *Writer) Encoder {
        return .{ .writer = w };
    }

    /// Encode `cfg` in git config format.
    pub fn encode(self: *Encoder, cfg: *const Config) Writer.Error!void {
        for (cfg.sections.items) |s| {
            try self.encodeSection(s);
        }
    }

    fn encodeSection(self: *Encoder, s: *const Section) Writer.Error!void {
        if (s.options.items.len > 0) {
            try self.writer.print("[{s}]\n", .{s.name});
            try self.encodeOptions(&s.options);
        }
        for (s.subsections.items) |ss| {
            try self.encodeSubsection(s.name, ss);
        }
    }

    fn encodeSubsection(self: *Encoder, section_name: []const u8, s: *const Subsection) Writer.Error!void {
        // [section "subsection"] with subsection escapes for " and \.
        try self.writer.writeAll("[");
        try self.writer.writeAll(section_name);
        try self.writer.writeAll(" \"");
        try writeEscapedSubsection(self.writer, s.name);
        try self.writer.writeAll("\"]\n");
        try self.encodeOptions(&s.options);
    }

    fn encodeOptions(self: *Encoder, opts: *const Options) Writer.Error!void {
        for (opts.items) |o| {
            try self.writer.writeAll("\t");
            try self.writer.writeAll(o.key);
            try self.writer.writeAll(" = ");
            try writeValue(self.writer, o.value);
            try self.writer.writeAll("\n");
        }
    }
};

/// go-git `subsectionReplacer`: `"` -> `\"`, `\` -> `\\`.
fn writeEscapedSubsection(w: *Writer, name: []const u8) Writer.Error!void {
    for (name) |c| {
        switch (c) {
            '"', '\\' => {
                try w.writeByte('\\');
                try w.writeByte(c);
            },
            else => try w.writeByte(c),
        }
    }
}

/// go-git: quote when value contains `#;"\t\n\` or leading/trailing space.
fn needsQuotes(value: []const u8) bool {
    if (value.len == 0) return false;
    if (value[0] == ' ' or value[value.len - 1] == ' ') return true;
    for (value) |c| {
        switch (c) {
            '#', ';', '"', '\t', '\n', '\\' => return true,
            else => {},
        }
    }
    return false;
}

/// go-git `valueReplacer` inside quotes: `" \ n t b`.
fn writeValue(w: *Writer, value: []const u8) Writer.Error!void {
    if (!needsQuotes(value)) {
        try w.writeAll(value);
        return;
    }
    try w.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"), // backspace
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

// ---------------------------------------------------------------------------
// Tests (go-git encoder_test.go — every fixture Text)
// ---------------------------------------------------------------------------

test "Encoder.Encode all fixtures" {
    const fixtures_mod = @import("fixtures.zig");
    const gpa = std.testing.allocator;
    for (fixtures_mod.fixtures, 0..) |fixture, idx| {
        var cfg = common.Config.init(gpa);
        defer cfg.deinit();
        try fixture.fill(&cfg);

        var aw: Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var enc = Encoder.init(&aw.writer);
        try enc.encode(&cfg);
        try std.testing.expectEqualStrings(fixture.text, aw.written());
        _ = idx;
    }
}

test "Encoder subsection quote and backslash escape" {
    const gpa = std.testing.allocator;
    var cfg = common.Config.init(gpa);
    defer cfg.deinit();
    _ = try cfg.addOption("remote", "ori\"gin\\x", "url", "u");

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = Encoder.init(&aw.writer);
    try enc.encode(&cfg);
    const expected = "[remote \"ori\\\"gin\\\\x\"]\n" ++ "\turl = u\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}

test "Encoder quotes value with backspace when other special present" {
    const gpa = std.testing.allocator;
    var cfg = common.Config.init(gpa);
    defer cfg.deinit();
    // `#` forces quotes; `\b` must be escaped inside.
    _ = try cfg.addOption("s", "", "k", "a#b\x08c");

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = Encoder.init(&aw.writer);
    try enc.encode(&cfg);
    const expected = "[s]\n" ++ "\tk = \"a#b\\bc\"\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}
