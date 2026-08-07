//! Object types (go-git `plumbing/object.go`).

const std = @import("std");
const err = @import("error.zig");

/// Internal object type. Pack integers 1–4 and 6–7 match git; `any` is -127.
pub const ObjectType = enum(i8) {
    invalid = 0,
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    // 5 reserved
    ofs_delta = 6,
    ref_delta = 7,
    any = -127,

    /// go-git `ObjectType.String`.
    pub fn string(self: ObjectType) []const u8 {
        return switch (self) {
            .commit => "commit",
            .tree => "tree",
            .blob => "blob",
            .tag => "tag",
            .ofs_delta => "ofs-delta",
            .ref_delta => "ref-delta",
            .any => "any",
            .invalid => "unknown",
        };
    }

    /// go-git `ObjectType.Bytes` (same as string for these types).
    pub fn bytes(self: ObjectType) []const u8 {
        return self.string();
    }

    /// Packed object types Commit…REFDelta inclusive (go-git `Valid`).
    pub fn valid(self: ObjectType) bool {
        const v = @intFromEnum(self);
        return v >= @intFromEnum(ObjectType.commit) and v <= @intFromEnum(ObjectType.ref_delta);
    }

    pub fn isDelta(self: ObjectType) bool {
        return self == .ofs_delta or self == .ref_delta;
    }

    /// Parse a type name. Rejects `"any"` / `"unknown"` (go-git `ParseObjectType`).
    pub fn parse(value: []const u8) err.Error!ObjectType {
        const table = [_]struct { []const u8, ObjectType }{
            .{ "commit", .commit },
            .{ "tree", .tree },
            .{ "blob", .blob },
            .{ "tag", .tag },
            .{ "ofs-delta", .ofs_delta },
            .{ "ref-delta", .ref_delta },
        };
        for (table) |row| {
            if (std.mem.eql(u8, value, row[0])) return row[1];
        }
        return error.InvalidType;
    }
};
