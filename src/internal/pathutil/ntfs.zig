//! NTFS path-component security helpers — go-git internal/pathutil/ntfs.go.

const std = @import("std");
const dotgit = @import("dotgit.zig");

fn asciiToLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + ('a' - 'A');
    return c;
}

/// Ports upstream Git's is_ntfs_dotgit. Detects path components that NTFS
/// would resolve to ".git": the canonical name itself and its 8.3 short-name
/// alias "git~1", each followed by any number of trailing spaces or periods
/// and an optional Alternate Data Stream suffix (":\<stream>").
///
/// Port of go-git `pathutil.IsNTFSDotGit`.
pub fn isNTFSDotGit(part: []const u8) bool {
    var i: usize = 0;
    if (part.len >= 4 and part[0] == '.' and
        asciiToLower(part[1]) == 'g' and
        asciiToLower(part[2]) == 'i' and
        asciiToLower(part[3]) == 't')
    {
        i = 4;
    } else if (part.len >= 5 and
        asciiToLower(part[0]) == 'g' and
        asciiToLower(part[1]) == 'i' and
        asciiToLower(part[2]) == 't' and
        part[3] == '~' and part[4] == '1')
    {
        i = 5;
    } else {
        return false;
    }

    while (i < part.len) : (i += 1) {
        const c = part[i];
        if (c == ':') return true;
        if (c != '.' and c != ' ') return false;
    }
    return true;
}

/// Reports whether part is a valid Windows / NTFS path component for the
/// worktree filesystem abstraction. Rejects NTFS-disguised variants of
/// `.git` / `git~1` (trailing spaces, periods, ADS) and Windows reserved
/// device names. Bare `.git` and `git~1` are allowed at this layer.
///
/// Port of go-git `pathutil.WindowsValidPath`.
pub fn windowsValidPath(part: []const u8) bool {
    if (isNTFSDotGit(part) and !dotgit.isDotGitName(part)) {
        return false;
    }
    return !isWindowsReservedName(part);
}

/// Windows reserved device names. A path component is reserved if its base
/// name (ignoring trailing spaces, extensions, and NTFS ADS) matches one of
/// these case-insensitively.
const windows_reserved_names = [_][]const u8{
    "CON",   "PRN",   "AUX",   "NUL",
    "COM1",  "COM2",  "COM3",  "COM4",  "COM5",  "COM6",  "COM7",  "COM8",  "COM9",
    "LPT1",  "LPT2",  "LPT3",  "LPT4",  "LPT5",  "LPT6",  "LPT7",  "LPT8",  "LPT9",
    "CONIN$", "CONOUT$",
};

fn isWindowsReservedName(part: []const u8) bool {
    for (windows_reserved_names) |name| {
        if (part.len < name.len) continue;
        if (!std.ascii.eqlIgnoreCase(part[0..name.len], name)) continue;
        // Exact match or followed by space, dot, colon (ADS).
        if (part.len == name.len) return true;
        switch (part[name.len]) {
            ' ', '.', ':' => return true,
            else => {},
        }
    }
    return false;
}

/// Ports upstream Git's is_ntfs_dot_generic. Detects NTFS path-component
/// variants of a dotfile name that attackers can use to bypass
/// case-insensitive comparisons against the canonical name on Windows.
///
/// `dotgit` is the lowercase name without the leading dot (e.g. "gitmodules");
/// `shortname_prefix` is the canonical 6-character NTFS short-name prefix
/// used as a fall-back match (e.g. "gi7eba" for ".gitmodules").
///
/// Port of go-git `pathutil.IsNTFSDot`.
pub fn isNTFSDot(name: []const u8, dotgit_name: []const u8, shortname_prefix: []const u8) bool {
    // onlySpacesAndPeriods: suffix from start is only trailing spaces/periods,
    // possibly terminated by an NTFS ADS colon.
    const onlySpacesAndPeriods = struct {
        fn call(s: []const u8, start: usize) bool {
            var i = start;
            while (i < s.len) : (i += 1) {
                const c = s[i];
                if (c == ':') return true;
                if (c != ' ' and c != '.') return false;
            }
            return true;
        }
    }.call;

    // Pattern 1: ".<dotgit>" prefix + trailing spaces / periods / ADS.
    if (name.len >= dotgit_name.len + 1 and name[0] == '.' and
        std.ascii.eqlIgnoreCase(name[1 .. 1 + dotgit_name.len], dotgit_name))
    {
        if (onlySpacesAndPeriods(name, dotgit_name.len + 1)) return true;
    }

    // Pattern 2: standard NTFS short name <dotgit[:6]>~[1-4].
    if (dotgit_name.len >= 6 and name.len >= 8 and
        std.ascii.eqlIgnoreCase(name[0..6], dotgit_name[0..6]) and
        name[6] == '~' and name[7] >= '1' and name[7] <= '4')
    {
        if (onlySpacesAndPeriods(name, 8)) return true;
    }

    // Pattern 3: fall-back NTFS short name keyed by shortname_prefix.
    if (shortname_prefix.len < 6 or name.len < 8) return false;
    var saw_tilde = false;
    var i: usize = 0;
    while (i < 8) {
        if (i >= name.len) return false;
        const c = name[i];
        if (saw_tilde) {
            if (c < '0' or c > '9') return false;
        } else if (c == '~') {
            i += 1;
            if (i >= name.len or name[i] < '1' or name[i] > '9') return false;
            saw_tilde = true;
        } else if (i >= 6) {
            return false;
        } else if (c & 0x80 != 0) {
            return false;
        } else {
            if (asciiToLower(c) != shortname_prefix[i]) return false;
        }
        i += 1;
    }
    return onlySpacesAndPeriods(name, 8);
}

/// Reports whether part is an NTFS-equivalent of ".gitmodules".
/// Short-name prefix "gi7eba" mirrors upstream Git's is_ntfs_dotgitmodules.
///
/// Port of go-git `pathutil.IsNTFSDotGitmodules`.
pub fn isNTFSDotGitmodules(part: []const u8) bool {
    return isNTFSDot(part, "gitmodules", "gi7eba");
}

// ---------------------------------------------------------------------------
// Tests (from ntfs_test.go)
// ---------------------------------------------------------------------------

test "WindowsValidPath table" {
    const Case = struct { path: []const u8, want: bool };
    const cases = [_]Case{
        .{ .path = ".git", .want = true },
        .{ .path = ".git . . .", .want = false },
        .{ .path = ".git ", .want = false },
        .{ .path = ".git  ", .want = false },
        .{ .path = ".git . .", .want = false },
        .{ .path = ".git::$INDEX_ALLOCATION", .want = false },
        .{ .path = ".git:", .want = false },
        .{ .path = "git~1 ", .want = false },
        .{ .path = "git~1.", .want = false },
        .{ .path = "GIT~1 ", .want = false },
        .{ .path = "git~1::$DATA", .want = false },
        .{ .path = "CON", .want = false },
        .{ .path = "con", .want = false },
        .{ .path = "CON.txt", .want = false },
        .{ .path = "CON:ads", .want = false },
        .{ .path = "CON ", .want = false },
        .{ .path = "PRN", .want = false },
        .{ .path = "AUX", .want = false },
        .{ .path = "NUL", .want = false },
        .{ .path = "COM1", .want = false },
        .{ .path = "COM9", .want = false },
        .{ .path = "LPT1", .want = false },
        .{ .path = "LPT9", .want = false },
        .{ .path = "CONIN$", .want = false },
        .{ .path = "CONOUT$", .want = false },
        .{ .path = "a", .want = true },
        .{ .path = "a\\b", .want = true },
        .{ .path = "a/b", .want = true },
        .{ .path = ".gitm", .want = true },
        .{ .path = "CONNECT", .want = true },
        .{ .path = "comic", .want = true },
        .{ .path = "COM", .want = true },
        .{ .path = "COM0", .want = true },
        .{ .path = "LPT0", .want = true },
        .{ .path = "git~1", .want = true },
    };
    for (cases) |tc| {
        try std.testing.expectEqual(tc.want, windowsValidPath(tc.path));
    }
}

test "IsNTFSDotGit table" {
    const Case = struct { part: []const u8, want: bool };
    const cases = [_]Case{
        .{ .part = ".git", .want = true },
        .{ .part = ".GIT", .want = true },
        .{ .part = "git~1", .want = true },
        .{ .part = "GIT~1", .want = true },
        .{ .part = ".git ", .want = true },
        .{ .part = ".git.", .want = true },
        .{ .part = ".git . . .", .want = true },
        .{ .part = ".git::$INDEX_ALLOCATION", .want = true },
        .{ .part = ".git:foo", .want = true },
        .{ .part = "git~1 ", .want = true },
        .{ .part = "git~1.", .want = true },
        .{ .part = "git~1 . ", .want = true },
        .{ .part = "git~1::$DATA", .want = true },
        .{ .part = "GIT~1.", .want = true },
        .{ .part = ".gitignore", .want = false },
        .{ .part = ".gitmodules", .want = false },
        .{ .part = "gitfoo", .want = false },
        .{ .part = "git~2", .want = false },
        .{ .part = "git~10", .want = false },
        .{ .part = "git", .want = false },
        .{ .part = "", .want = false },
        .{ .part = ".", .want = false },
        .{ .part = "readme.md", .want = false },
    };
    for (cases) |tc| {
        try std.testing.expectEqual(tc.want, isNTFSDotGit(tc.part));
    }
}

test "IsNTFSDot table" {
    const Case = struct {
        part: []const u8,
        dotgit_name: []const u8,
        shortname_prefix: []const u8,
        want: bool,
    };
    const cases = [_]Case{
        .{ .part = ".gitmodules", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = true },
        .{ .part = ".GITMODULES", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = true },
        .{ .part = ".GitModules", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = true },
        .{ .part = ".gitmodules ", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = true },
        .{ .part = ".gitmodules.", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = true },
        .{ .part = ".gitmodules .", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = true },
        .{ .part = ".gitmodules   ", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = true },
        .{ .part = ".gitmodules:foo", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = true },
        .{ .part = "gitmod~1", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = true },
        .{ .part = "gitmod~4", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = true },
        .{ .part = "GITMOD~1", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = true },
        .{ .part = "gitmod~5", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = false },
        .{ .part = "gitmod~1:foo", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = true },
        .{ .part = "gi7eba~1", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = true },
        .{ .part = "gi7ebaXY", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = false },
        .{ .part = "gi7eba1X", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = false },
        .{ .part = ".gitmodulesfoo", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = false },
        .{ .part = ".gitignore", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = false },
        .{ .part = "readme.md", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = false },
        .{ .part = "", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = false },
        .{ .part = ".", .dotgit_name = "gitmodules", .shortname_prefix = "gi7eba", .want = false },
    };
    for (cases) |tc| {
        try std.testing.expectEqual(
            tc.want,
            isNTFSDot(tc.part, tc.dotgit_name, tc.shortname_prefix),
        );
    }
}

test "IsNTFSDotGitmodules table" {
    const Case = struct { part: []const u8, want: bool };
    const cases = [_]Case{
        .{ .part = ".gitmodules", .want = true },
        .{ .part = ".GITMODULES", .want = true },
        .{ .part = ".gitmodules ", .want = true },
        .{ .part = ".gitmodules.", .want = true },
        .{ .part = ".gitmodules .", .want = true },
        .{ .part = ".gitmodules:foo", .want = true },
        .{ .part = "gitmod~1", .want = true },
        .{ .part = "GITMOD~4", .want = true },
        .{ .part = "gi7eba~1", .want = true },
        .{ .part = ".gitmodulesfoo", .want = false },
        .{ .part = ".gitignore", .want = false },
        .{ .part = "readme.md", .want = false },
        .{ .part = "", .want = false },
    };
    for (cases) |tc| {
        try std.testing.expectEqual(tc.want, isNTFSDotGitmodules(tc.part));
    }
}
