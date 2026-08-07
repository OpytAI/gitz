//! Binary helpers (go-git `utils/binary`): Git offset VLQ and big-endian integers.
//!
//! Used by packfile and related plumbing. I/O uses Zig 0.16 `std.Io.Reader` /
//! `std.Io.Writer`.

const std = @import("std");

const read_mod = @import("read.zig");
const write_mod = @import("write.zig");

pub const Error = read_mod.Error;
/// Inventory / go-git name for overflow.
pub const ErrIntegerOverflow = read_mod.ErrIntegerOverflow;

pub const readVariableWidthInt = read_mod.readVariableWidthInt;
pub const writeVariableWidthInt = write_mod.writeVariableWidthInt;
pub const readUint32 = read_mod.readUint32;
pub const writeUint32 = write_mod.writeUint32;
pub const readUint64 = read_mod.readUint64;
pub const writeUint64 = write_mod.writeUint64;

test {
    _ = @import("read.zig");
    _ = @import("write.zig");
}

test "VLQ round-trip known vectors" {
    const Reader = std.Io.Reader;
    const Writer = std.Io.Writer;

    const cases = [_]i64{ 0, 19, 127, 128, 366, 16511, 16512, 2113663 };
    for (cases) |want| {
        var buf: [16]u8 = undefined;
        var w: Writer = .fixed(&buf);
        try writeVariableWidthInt(&w, want);
        const encoded = w.buffered();
        var r: Reader = .fixed(encoded);
        try std.testing.expectEqual(want, try readVariableWidthInt(&r));
    }
}
