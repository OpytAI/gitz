//! plumbing/filemode — Git tree entry modes (port of go-git plumbing/filemode).
//!
//! A FileMode represents the kind of tree entries used by git. It resembles
//! regular file-system modes, although FileModes are considerably simpler, and
//! some modes (Empty, Submodule) have no file-system equivalent.
//!
//! Reference: go-git v5.19.2 `plumbing/filemode/filemode.go`.

const std = @import("std");

// ---------------------------------------------------------------------------
// FileMode type and git constants
// ---------------------------------------------------------------------------

/// Kind of a git tree entry (mode field). Stored as a 32-bit unsigned value
/// matching go-git `FileMode` / git packfile tree-entry modes.
pub const FileMode = u32;

/// Empty is used as the FileMode of tree elements when comparing trees in the
/// following situations:
///
/// - the mode of tree elements before their creation
/// - the mode of tree elements after their deletion
/// - the mode of unmerged elements when checking the index
///
/// Empty has no file system equivalent. As Empty is the zero value of FileMode,
/// it is also the failure stand-in for `new` / `newFromOSFileMode` in go-git
/// (Zig returns an error union instead).
pub const Empty: FileMode = 0;
/// Directory.
pub const Dir: FileMode = 0o040000;
/// Non-executable regular file (not the same as "regular" in OS APIs, which
/// often include executables).
pub const Regular: FileMode = 0o100644;
/// Deprecated non-executable file with the group-writable bit set. Supported
/// for reading old packfiles; treated as Regular when interfacing outward.
pub const Deprecated: FileMode = 0o100664;
/// Executable file.
pub const Executable: FileMode = 0o100755;
/// Symbolic link.
pub const Symlink: FileMode = 0o120000;
/// Git submodule (no file-system equivalent).
pub const Submodule: FileMode = 0o160000;

// ---------------------------------------------------------------------------
// OS file mode (Go os.FileMode bit layout)
// ---------------------------------------------------------------------------

/// OS file mode bits using Go's `os.FileMode` layout (permission in the low
/// 9 bits; type/flag bits in the high half). Used by `newFromOSFileMode` and
/// `toOSFileMode` so table tests match go-git. Callers that have Unix `mode_t`
/// values should map them into this layout (or a later helper) before calling.
pub const OSFileMode = u32;

/// Permission mask (Go `os.ModePerm`).
pub const os_mode_perm: OSFileMode = 0o777;

// Go os.FileMode type/flag bits (1 << (32 - 1 - iota) from ModeDir).
pub const os_mode_dir: OSFileMode = 1 << 31;
pub const os_mode_append: OSFileMode = 1 << 30;
pub const os_mode_exclusive: OSFileMode = 1 << 29;
pub const os_mode_temporary: OSFileMode = 1 << 28;
pub const os_mode_symlink: OSFileMode = 1 << 27;
pub const os_mode_device: OSFileMode = 1 << 26;
pub const os_mode_named_pipe: OSFileMode = 1 << 25;
pub const os_mode_socket: OSFileMode = 1 << 24;
pub const os_mode_setuid: OSFileMode = 1 << 23;
pub const os_mode_setgid: OSFileMode = 1 << 22;
pub const os_mode_char_device: OSFileMode = 1 << 21;
pub const os_mode_sticky: OSFileMode = 1 << 20;
pub const os_mode_irregular: OSFileMode = 1 << 19;

/// Type bits (Go `os.ModeType`). No type bits set ⇒ regular file.
const os_mode_type: OSFileMode = os_mode_dir | os_mode_symlink | os_mode_named_pipe |
    os_mode_socket | os_mode_device | os_mode_char_device | os_mode_irregular;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

pub const Error = error{
    /// Octal string could not be parsed as a 32-bit unsigned value.
    InvalidFileMode,
    /// OS mode has no equivalent git FileMode (socket, pipe, temporary, …).
    NoEquivalentGitMode,
    /// FileMode is malformed and cannot map to an OS mode (Empty, unknown).
    MalformedMode,
};

// ---------------------------------------------------------------------------
// Constructors
// ---------------------------------------------------------------------------

/// Parse an octal string representation of a FileMode.
///
/// Example: `"40000"` → Dir, `"100644"` → Regular.
///
/// Does not validate that the mode is a well-known git mode. For instance,
/// `"1"` yields `FileMode(1)` with no error. On parse failure, returns
/// `error.InvalidFileMode` (go-git returns `(Empty, err)`).
pub fn new(s: []const u8) Error!FileMode {
    // Match strconv.ParseUint: reject empty, signs, and non-octal digits.
    if (s.len == 0) return Error.InvalidFileMode;
    if (s[0] == '+' or s[0] == '-') return Error.InvalidFileMode;
    for (s) |c| {
        if (c < '0' or c > '7') return Error.InvalidFileMode;
    }
    return std.fmt.parseInt(FileMode, s, 8) catch Error.InvalidFileMode;
}

/// Map an OS file mode (Go `os.FileMode` layout) to a git FileMode.
///
/// Returns `error.NoEquivalentGitMode` when the mode cannot be mapped (as with
/// sockets, named pipes, temporary files, or character devices).
///
/// Deprecated and Submodule cannot be produced from OS modes; Empty is only
/// returned together with an error in go-git — here the error alone is enough.
pub fn newFromOSFileMode(m: OSFileMode) Error!FileMode {
    if (isOSRegular(m)) {
        if (isSetTemporary(m)) return Error.NoEquivalentGitMode;
        if (isSetCharDevice(m)) return Error.NoEquivalentGitMode;
        if (isSetUserExecutable(m)) return Executable;
        return Regular;
    }
    if (isOSDir(m)) return Dir;
    if (isSetSymLink(m)) return Symlink;
    return Error.NoEquivalentGitMode;
}

fn isOSRegular(m: OSFileMode) bool {
    return m & os_mode_type == 0;
}

fn isOSDir(m: OSFileMode) bool {
    return m & os_mode_dir != 0;
}

fn isSetCharDevice(m: OSFileMode) bool {
    return m & os_mode_char_device != 0;
}

fn isSetTemporary(m: OSFileMode) bool {
    return m & os_mode_temporary != 0;
}

fn isSetUserExecutable(m: OSFileMode) bool {
    return m & 0o100 != 0;
}

fn isSetSymLink(m: OSFileMode) bool {
    return m & os_mode_symlink != 0;
}

// ---------------------------------------------------------------------------
// FileMode methods (free functions taking FileMode, Zig style)
// ---------------------------------------------------------------------------

/// Return 4 bytes with the mode in little-endian encoding (go-git `Bytes`).
pub fn bytes(m: FileMode) [4]u8 {
    var ret: [4]u8 = undefined;
    std.mem.writeInt(u32, &ret, m, .little);
    return ret;
}

/// True if the mode should not appear in a git packfile: Empty or any value
/// other than the package constants.
pub fn isMalformed(m: FileMode) bool {
    return m != Dir and
        m != Regular and
        m != Deprecated and
        m != Executable and
        m != Symlink and
        m != Submodule;
}

/// Octal string in standard git format: 7 digits, zero-padded.
/// Example: Regular → `"0100644"`, Empty → `"0000000"`.
/// Writes into `buf` (must hold at least 16 bytes); returns the written slice.
pub fn string(m: FileMode, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{o:0>7}", .{m}) catch unreachable;
}

/// True if the mode is a regular non-executable file: Regular or Deprecated.
/// Executable is not regular here; see `isFile`.
pub fn isRegular(m: FileMode) bool {
    return m == Regular or m == Deprecated;
}

/// True if the mode is a file: Regular, Deprecated, Executable, or Symlink.
pub fn isFile(m: FileMode) bool {
    return m == Regular or
        m == Deprecated or
        m == Executable or
        m == Symlink;
}

/// Map a git FileMode to an OS file mode (Go `os.FileMode` layout).
///
/// Does not apply umask. Submodule maps like Dir. Malformed modes return
/// `error.MalformedMode` (go-git: `(0, "malformed mode …")`).
pub fn toOSFileMode(m: FileMode) Error!OSFileMode {
    return switch (m) {
        Dir, Submodule => os_mode_perm | os_mode_dir,
        Regular, Deprecated => 0o644,
        Executable => 0o755,
        Symlink => os_mode_perm | os_mode_symlink,
        else => Error.MalformedMode,
    };
}

// ---------------------------------------------------------------------------
// Tests (tables from go-git plumbing/filemode/filemode_test.go)
// ---------------------------------------------------------------------------

test "new parses packfile and git-output modes" {
    const cases = [_]struct { input: []const u8, expected: FileMode }{
        // packfile tree-entry codification
        .{ .input = "40000", .expected = Dir },
        .{ .input = "100644", .expected = Regular },
        .{ .input = "100664", .expected = Deprecated },
        .{ .input = "100755", .expected = Executable },
        .{ .input = "120000", .expected = Symlink },
        .{ .input = "160000", .expected = Submodule },
        // often appear in git outputs (e.g. diff-tree)
        .{ .input = "000000", .expected = Empty },
        .{ .input = "040000", .expected = Dir },
        // valid but unusual
        .{ .input = "0", .expected = Empty },
        .{ .input = "42", .expected = @as(FileMode, 0o42) },
        .{ .input = "00000000000100644", .expected = Regular },
    };
    for (cases) |tc| {
        const obtained = try new(tc.input);
        try std.testing.expectEqual(tc.expected, obtained);
    }
}

test "new rejects non-octal input" {
    const bad = [_][]const u8{
        "0x81a4",
        "-rw-r--r--",
        "",
        "-42",
        "9",
        "09",
        "mode",
        "-100644",
        "+100644",
    };
    for (bad) |input| {
        try std.testing.expectError(Error.InvalidFileMode, new(input));
    }
}

test "newFromOSFileMode simple permissions" {
    const cases = [_]struct { input: OSFileMode, expected: FileMode }{
        .{ .input = 0o755 | os_mode_dir, .expected = Dir },
        .{ .input = 0o700 | os_mode_dir, .expected = Dir },
        .{ .input = 0o500 | os_mode_dir, .expected = Dir },
        .{ .input = 0o644, .expected = Regular },
        .{ .input = 0o660, .expected = Regular },
        .{ .input = 0o640, .expected = Regular },
        .{ .input = 0o600, .expected = Regular },
        .{ .input = 0o400, .expected = Regular },
        .{ .input = 0o000, .expected = Regular },
        .{ .input = 0o755, .expected = Executable },
        .{ .input = 0o700, .expected = Executable },
        .{ .input = 0o500, .expected = Executable },
        .{ .input = 0o744, .expected = Executable },
        .{ .input = 0o540, .expected = Executable },
        .{ .input = 0o550, .expected = Executable },
        .{ .input = 0o777 | os_mode_symlink, .expected = Symlink },
    };
    for (cases) |tc| {
        const obtained = try newFromOSFileMode(tc.input);
        try std.testing.expectEqual(tc.expected, obtained);
    }
}

test "newFromOSFileMode append exclusive setuid setgid sticky" {
    try std.testing.expectEqual(Regular, try newFromOSFileMode(0o644 | os_mode_append));
    try std.testing.expectEqual(Regular, try newFromOSFileMode(0o644 | os_mode_exclusive));
    try std.testing.expectEqual(Executable, try newFromOSFileMode(0o755 | os_mode_exclusive));
    try std.testing.expectEqual(Executable, try newFromOSFileMode(0o755 | os_mode_setuid));
    try std.testing.expectEqual(Regular, try newFromOSFileMode(0o644 | os_mode_setgid));
    try std.testing.expectEqual(Executable, try newFromOSFileMode(0o755 | os_mode_setgid));
    try std.testing.expectEqual(Dir, try newFromOSFileMode(0o755 | os_mode_dir | os_mode_sticky));
}

test "newFromOSFileMode rejects unmappable types" {
    const bad = [_]OSFileMode{
        0o644 | os_mode_temporary,
        0o755 | os_mode_temporary,
        0o644 | os_mode_device,
        0o644 | os_mode_named_pipe,
        0o644 | os_mode_socket,
        0o644 | os_mode_char_device,
    };
    for (bad) |input| {
        try std.testing.expectError(Error.NoEquivalentGitMode, newFromOSFileMode(input));
    }
}

test "bytes little-endian encoding" {
    const cases = [_]struct { input: FileMode, expected: [4]u8 }{
        .{ .input = 0, .expected = .{ 0x00, 0x00, 0x00, 0x00 } },
        .{ .input = 1, .expected = .{ 0x01, 0x00, 0x00, 0x00 } },
        .{ .input = 15, .expected = .{ 0x0f, 0x00, 0x00, 0x00 } },
        .{ .input = 16, .expected = .{ 0x10, 0x00, 0x00, 0x00 } },
        .{ .input = 255, .expected = .{ 0xff, 0x00, 0x00, 0x00 } },
        .{ .input = 256, .expected = .{ 0x00, 0x01, 0x00, 0x00 } },
        .{ .input = Empty, .expected = .{ 0x00, 0x00, 0x00, 0x00 } },
        .{ .input = Dir, .expected = .{ 0x00, 0x40, 0x00, 0x00 } },
        .{ .input = Regular, .expected = .{ 0xa4, 0x81, 0x00, 0x00 } },
        .{ .input = Deprecated, .expected = .{ 0xb4, 0x81, 0x00, 0x00 } },
        .{ .input = Executable, .expected = .{ 0xed, 0x81, 0x00, 0x00 } },
        .{ .input = Symlink, .expected = .{ 0x00, 0xa0, 0x00, 0x00 } },
        .{ .input = Submodule, .expected = .{ 0x00, 0xe0, 0x00, 0x00 } },
    };
    for (cases) |tc| {
        try std.testing.expectEqualSlices(u8, &tc.expected, &bytes(tc.input));
    }
}

test "isMalformed" {
    const cases = [_]struct { mode: FileMode, expected: bool }{
        .{ .mode = Empty, .expected = true },
        .{ .mode = Dir, .expected = false },
        .{ .mode = Regular, .expected = false },
        .{ .mode = Deprecated, .expected = false },
        .{ .mode = Executable, .expected = false },
        .{ .mode = Symlink, .expected = false },
        .{ .mode = Submodule, .expected = false },
        .{ .mode = 0o1, .expected = true },
        .{ .mode = 0o10, .expected = true },
        .{ .mode = 0o100, .expected = true },
        .{ .mode = 0o1000, .expected = true },
        .{ .mode = 0o10000, .expected = true },
        .{ .mode = 0o100000, .expected = true },
    };
    for (cases) |tc| {
        try std.testing.expectEqual(tc.expected, isMalformed(tc.mode));
    }
}

test "string zero-padded octal" {
    const cases = [_]struct { mode: FileMode, expected: []const u8 }{
        .{ .mode = Empty, .expected = "0000000" },
        .{ .mode = Dir, .expected = "0040000" },
        .{ .mode = Regular, .expected = "0100644" },
        .{ .mode = Deprecated, .expected = "0100664" },
        .{ .mode = Executable, .expected = "0100755" },
        .{ .mode = Symlink, .expected = "0120000" },
        .{ .mode = Submodule, .expected = "0160000" },
        .{ .mode = 0o1, .expected = "0000001" },
        .{ .mode = 0o10, .expected = "0000010" },
        .{ .mode = 0o100, .expected = "0000100" },
        .{ .mode = 0o1000, .expected = "0001000" },
        .{ .mode = 0o10000, .expected = "0010000" },
        .{ .mode = 0o100000, .expected = "0100000" },
    };
    var buf: [16]u8 = undefined;
    for (cases) |tc| {
        const s = string(tc.mode, &buf);
        try std.testing.expectEqualStrings(tc.expected, s);
    }
}

test "isRegular" {
    const cases = [_]struct { mode: FileMode, expected: bool }{
        .{ .mode = Empty, .expected = false },
        .{ .mode = Dir, .expected = false },
        .{ .mode = Regular, .expected = true },
        .{ .mode = Deprecated, .expected = true },
        .{ .mode = Executable, .expected = false },
        .{ .mode = Symlink, .expected = false },
        .{ .mode = Submodule, .expected = false },
        .{ .mode = 0o1, .expected = false },
        .{ .mode = 0o10, .expected = false },
        .{ .mode = 0o100, .expected = false },
        .{ .mode = 0o1000, .expected = false },
        .{ .mode = 0o10000, .expected = false },
        .{ .mode = 0o100000, .expected = false },
    };
    for (cases) |tc| {
        try std.testing.expectEqual(tc.expected, isRegular(tc.mode));
    }
}

test "isFile" {
    const cases = [_]struct { mode: FileMode, expected: bool }{
        .{ .mode = Empty, .expected = false },
        .{ .mode = Dir, .expected = false },
        .{ .mode = Regular, .expected = true },
        .{ .mode = Deprecated, .expected = true },
        .{ .mode = Executable, .expected = true },
        .{ .mode = Symlink, .expected = true },
        .{ .mode = Submodule, .expected = false },
        .{ .mode = 0o1, .expected = false },
        .{ .mode = 0o10, .expected = false },
        .{ .mode = 0o100, .expected = false },
        .{ .mode = 0o1000, .expected = false },
        .{ .mode = 0o10000, .expected = false },
        .{ .mode = 0o100000, .expected = false },
    };
    for (cases) |tc| {
        try std.testing.expectEqual(tc.expected, isFile(tc.mode));
    }
}

test "toOSFileMode" {
    const cases = [_]struct {
        input: FileMode,
        expected: OSFileMode,
        ok: bool,
    }{
        .{ .input = Empty, .expected = 0, .ok = false },
        .{ .input = Dir, .expected = os_mode_perm | os_mode_dir, .ok = true },
        .{ .input = Regular, .expected = 0o644, .ok = true },
        .{ .input = Deprecated, .expected = 0o644, .ok = true },
        .{ .input = Executable, .expected = 0o755, .ok = true },
        .{ .input = Symlink, .expected = os_mode_perm | os_mode_symlink, .ok = true },
        .{ .input = Submodule, .expected = os_mode_perm | os_mode_dir, .ok = true },
        .{ .input = 0o1, .expected = 0, .ok = false },
        .{ .input = 0o10, .expected = 0, .ok = false },
        .{ .input = 0o100, .expected = 0, .ok = false },
        .{ .input = 0o1000, .expected = 0, .ok = false },
        .{ .input = 0o10000, .expected = 0, .ok = false },
        .{ .input = 0o100000, .expected = 0, .ok = false },
    };
    for (cases) |tc| {
        if (tc.ok) {
            const obtained = try toOSFileMode(tc.input);
            try std.testing.expectEqual(tc.expected, obtained);
        } else {
            try std.testing.expectError(Error.MalformedMode, toOSFileMode(tc.input));
        }
    }
}

