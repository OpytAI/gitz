//! Decode/encode fixtures — port of go-git v5.19.2 `fixtures_test.go`.
//!
//! Each fixture has:
//! - `raw`: text accepted by Decoder (success cases)
//! - `text`: exact Encoder output for the built Config
//! - `fill`: populates a Config the same way go-git `New().AddOption(...)` does

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common.zig");

const Config = common.Config;
const NoSubsection = common.NoSubsection;

pub const Fixture = struct {
    raw: []const u8,
    text: []const u8,
    fill: *const fn (*Config) Allocator.Error!void,
};

fn fillEmpty(_: *Config) Allocator.Error!void {}

fn fillCore(cfg: *Config) Allocator.Error!void {
    _ = try cfg.addOption("core", NoSubsection, "repositoryformatversion", "0");
}

fn fillSpecial(cfg: *Config) Allocator.Error!void {
    _ = try cfg.addOption("section", NoSubsection, "option1", "has # hash");
    _ = try cfg.addOption("section", NoSubsection, "option2", "has \" quote");
    _ = try cfg.addOption("section", NoSubsection, "option3", "has \\ backslash");
    _ = try cfg.addOption("section", NoSubsection, "option4", "has ; semicolon");
    _ = try cfg.addOption("section", NoSubsection, "option5", "has \n line-feed");
    _ = try cfg.addOption("section", NoSubsection, "option6", "has \t tab");
    _ = try cfg.addOption("section", NoSubsection, "option7", "  has leading spaces");
    _ = try cfg.addOption("section", NoSubsection, "option8", "has trailing spaces  ");
    _ = try cfg.addOption("section", NoSubsection, "option9", "has no special characters");
    _ = try cfg.addOption("section", NoSubsection, "option10", "has unusual \x01\x7f\u{0200} characters");
}

fn fillSectSub(cfg: *Config) Allocator.Error!void {
    _ = try cfg.addOption("sect1", NoSubsection, "opt1", "value1");
    _ = try cfg.addOption("sect1", "subsect1", "opt2", "value2");
}

fn fillSectSubMulti(cfg: *Config) Allocator.Error!void {
    _ = try cfg.addOption("sect1", NoSubsection, "opt1", "value1");
    _ = try cfg.addOption("sect1", NoSubsection, "opt1", "value1b");
    _ = try cfg.addOption("sect1", "subsect1", "opt2", "value2");
    _ = try cfg.addOption("sect1", "subsect1", "opt2", "value2b");
    _ = try cfg.addOption("sect1", "subsect2", "opt2", "value2");
}

fn fillDupOpt(cfg: *Config) Allocator.Error!void {
    _ = try cfg.addOption("sect1", NoSubsection, "opt1", "value1");
    _ = try cfg.addOption("sect1", NoSubsection, "opt1", "value2");
}

/// Special-character fixture raw (tabs via "\t"; escapes match go-git raw string + concat).
const special_raw = "[section]\n" ++
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

const special_text = special_raw;

/// go-git fixtures in order (fixtures_test.go).
pub const fixtures = [_]Fixture{
    .{
        .raw = "",
        .text = "",
        .fill = fillEmpty,
    },
    .{
        .raw = ";Comments only",
        .text = "",
        .fill = fillEmpty,
    },
    .{
        .raw = "#Comments only",
        .text = "",
        .fill = fillEmpty,
    },
    .{
        .raw = "[core]\nrepositoryformatversion=0",
        .text = "[core]\n" ++ "\trepositoryformatversion = 0\n",
        .fill = fillCore,
    },
    .{
        .raw = "[core]\n" ++ "\trepositoryformatversion = 0\n",
        .text = "[core]\n" ++ "\trepositoryformatversion = 0\n",
        .fill = fillCore,
    },
    .{
        .raw = ";Commment\n[core]\n;Comment\nrepositoryformatversion = 0\n",
        .text = "[core]\n" ++ "\trepositoryformatversion = 0\n",
        .fill = fillCore,
    },
    .{
        .raw = "#Commment\n#Comment\n[core]\n#Comment\nrepositoryformatversion = 0\n",
        .text = "[core]\n" ++ "\trepositoryformatversion = 0\n",
        .fill = fillCore,
    },
    .{
        .raw = special_raw,
        .text = special_text,
        .fill = fillSpecial,
    },
    .{
        // go-git uses indented raw; leading whitespace is insignificant.
        // Use spaces (not raw tab bytes) inside string literals.
        .raw = "\n" ++
            "   [sect1]\n" ++
            "   opt1 = value1\n" ++
            "   [sect1 \"subsect1\"]\n" ++
            "   opt2 = value2\n" ++
            "  ",
        .text = "[sect1]\n" ++
            "\topt1 = value1\n" ++
            "[sect1 \"subsect1\"]\n" ++
            "\topt2 = value2\n",
        .fill = fillSectSub,
    },
    .{
        .raw = "\n" ++
            "   [sect1]\n" ++
            "   opt1 = value1\n" ++
            "   [sect1 \"subsect1\"]\n" ++
            "   opt2 = value2\n" ++
            "   [sect1]\n" ++
            "   opt1 = value1b\n" ++
            "   [sect1 \"subsect1\"]\n" ++
            "   opt2 = value2b\n" ++
            "   [sect1 \"subsect2\"]\n" ++
            "   opt2 = value2\n" ++
            "  ",
        .text = "[sect1]\n" ++
            "\topt1 = value1\n" ++
            "\topt1 = value1b\n" ++
            "[sect1 \"subsect1\"]\n" ++
            "\topt2 = value2\n" ++
            "\topt2 = value2b\n" ++
            "[sect1 \"subsect2\"]\n" ++
            "\topt2 = value2\n",
        .fill = fillSectSubMulti,
    },
    .{
        .raw = "\n" ++
            "   [sect1]\n" ++
            "   opt1 = value1\n" ++
            "   opt1 = value2\n" ++
            "   ",
        .text = "[sect1]\n" ++
            "\topt1 = value1\n" ++
            "\topt1 = value2\n",
        .fill = fillDupOpt,
    },
};

/// Build a Config for fixture `idx` (caller must `deinit`).
pub fn buildConfig(allocator: Allocator, idx: usize) Allocator.Error!Config {
    var cfg = Config.init(allocator);
    errdefer cfg.deinit();
    try fixtures[idx].fill(&cfg);
    return cfg;
}

test "fixtures count matches go-git" {
    // go-git fixtures_test.go has 11 fixtures (indices 0..10).
    try std.testing.expectEqual(@as(usize, 11), fixtures.len);
}
