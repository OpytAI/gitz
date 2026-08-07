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
        try self.writer.print("[", .{});
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
// Tests (go-git encoder_test.go / fixtures)
// ---------------------------------------------------------------------------

test "Encoder empty config" {
    const gpa = std.testing.allocator;
    var cfg = common.Config.init(gpa);
    defer cfg.deinit();
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = Encoder.init(&aw.writer);
    try enc.encode(&cfg);
    try std.testing.expectEqualStrings("", aw.written());
}

test "Encoder core repositoryformatversion" {
    const gpa = std.testing.allocator;
    var cfg = common.Config.init(gpa);
    defer cfg.deinit();
    _ = try cfg.addOption("core", common.NoSubsection, "repositoryformatversion", "0");
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = Encoder.init(&aw.writer);
    try enc.encode(&cfg);
    try std.testing.expectEqualStrings("[core]\n\trepositoryformatversion = 0\n", aw.written());
}

test "Encoder special option values" {
    const gpa = std.testing.allocator;
    var cfg = common.Config.init(gpa);
    defer cfg.deinit();
    _ = try cfg.addOption("section", "", "option1", "has # hash");
    _ = try cfg.addOption("section", "", "option2", "has \" quote");
    _ = try cfg.addOption("section", "", "option3", "has \\ backslash");
    _ = try cfg.addOption("section", "", "option4", "has ; semicolon");
    _ = try cfg.addOption("section", "", "option5", "has \n line-feed");
    _ = try cfg.addOption("section", "", "option6", "has \t tab");
    _ = try cfg.addOption("section", "", "option7", "  has leading spaces");
    _ = try cfg.addOption("section", "", "option8", "has trailing spaces  ");
    _ = try cfg.addOption("section", "", "option9", "has no special characters");
    _ = try cfg.addOption("section", "", "option10", "has unusual \x01\x7f\u{0200} characters");

    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = Encoder.init(&aw.writer);
    try enc.encode(&cfg);

    // Tab-indented options (multiline string literals cannot embed raw tab in Zig 0.16).
    const expected = "[section]\n" ++
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
    try std.testing.expectEqualStrings(expected, aw.written());
}

test "Encoder sections and subsections" {
    const gpa = std.testing.allocator;
    var cfg = common.Config.init(gpa);
    defer cfg.deinit();
    _ = try cfg.addOption("sect1", "", "opt1", "value1");
    _ = try cfg.addOption("sect1", "subsect1", "opt2", "value2");
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var enc = Encoder.init(&aw.writer);
    try enc.encode(&cfg);
    const expected = "[sect1]\n" ++
        "\topt1 = value1\n" ++
        "[sect1 \"subsect1\"]\n" ++
        "\topt2 = value2\n";
    try std.testing.expectEqualStrings(expected, aw.written());
}
