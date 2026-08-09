//! In-memory index storage (go-git `storage/memory` `IndexStorage`).
//!
//! Holds a heap `*index_format.Index` (full dircache model from
//! `plumbing/format/index`). `setIndex` takes ownership of the pointer and
//! stamps `mod_time` (go-git sets `ModTime = time.Now()` for racy-git checks).

const std = @import("std");
const builtin = @import("builtin");
const index_format = @import("index");

const Allocator = std.mem.Allocator;

/// Full index type (go-git `plumbing/format/index.Index`).
pub const Index = index_format.Index;
pub const Entry = index_format.Entry;
pub const Time = index_format.Time;

/// Repository clock used for index timestamps and implicit Git identities.
/// Freestanding callers must provide a fixed or callback-backed clock instead
/// of acquiring ambient wall-clock authority.
pub const Clock = union(enum) {
    system,
    fixed: Time,

    pub fn systemClock() Clock {
        if (comptime builtin.os.tag == .freestanding) {
            @compileError("freestanding storage requires an explicit Clock");
        }
        return .system;
    }

    pub fn fixedClock(time: Time) Clock {
        return .{ .fixed = time };
    }

    pub fn now(self: Clock) Time {
        return switch (self) {
            .system => systemTimeNow(),
            .fixed => |time| time,
        };
    }
};

/// go-git `IndexStorage`.
pub const IndexStorage = struct {
    allocator: Allocator,
    clock: Clock,
    /// Owned index pointer (field name avoids clash with method `index`).
    stored: ?*Index = null,

    pub fn init(allocator: Allocator) IndexStorage {
        return initWithClock(allocator, Clock.systemClock());
    }

    pub fn initWithClock(allocator: Allocator, clock: Clock) IndexStorage {
        return .{ .allocator = allocator, .clock = clock };
    }

    pub fn deinit(self: *IndexStorage) void {
        if (self.stored) |idx| {
            idx.deinit();
            self.allocator.destroy(idx);
            self.stored = null;
        }
        self.* = undefined;
    }

    /// go-git `SetIndex` — takes ownership of `idx` and stamps `mod_time`.
    /// Previous stored index (if any) is freed.
    pub fn setIndex(self: *IndexStorage, idx: *Index) void {
        idx.mod_time = self.clock.now();
        if (self.stored) |old| {
            if (old != idx) {
                old.deinit();
                self.allocator.destroy(old);
            }
        }
        self.stored = idx;
    }

    /// go-git `Index` — returns stored index or a default empty v2 index.
    pub fn index(self: *IndexStorage) Allocator.Error!*Index {
        if (self.stored) |idx| return idx;
        const idx = try self.allocator.create(Index);
        idx.* = Index.init(self.allocator);
        idx.version = 2;
        self.stored = idx;
        return idx;
    }
};

fn systemTimeNow() Time {
    if (comptime builtin.os.tag == .freestanding) unreachable;
    // Prefer std.time when present; Zig 0.16 removed milliTimestamp.
    if (@hasDecl(std.time, "nanoTimestamp")) {
        const ns = std.time.nanoTimestamp();
        if (ns > 0) {
            const sec: i64 = @intCast(@divTrunc(ns, 1_000_000_000));
            const nsec: i32 = @intCast(@rem(ns, 1_000_000_000));
            return Time.unix(sec, nsec);
        }
    }
    var ts: std.posix.timespec = undefined;
    const rc = std.posix.system.clock_gettime(.REALTIME, &ts);
    if (rc != 0) return Time.unix(1, 0);
    return Time.unix(@intCast(ts.sec), @intCast(ts.nsec));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "IndexStorage default version 2 zero mod time" {
    const allocator = std.testing.allocator;
    var store = IndexStorage.init(allocator);
    defer store.deinit();

    const idx = try store.index();
    try std.testing.expectEqual(@as(u32, 2), idx.version);
    try std.testing.expect(idx.mod_time.isZero());
}

test "IndexStorage setIndex stamps mod_time and takes ownership" {
    const allocator = std.testing.allocator;
    var store = IndexStorage.init(allocator);
    defer store.deinit();

    const idx = try allocator.create(Index);
    idx.* = Index.init(allocator);
    idx.version = 2;
    store.setIndex(idx);

    const got = try store.index();
    try std.testing.expect(got == idx);
    try std.testing.expectEqual(@as(u32, 2), got.version);
    try std.testing.expect(!got.mod_time.isZero());
}

test "IndexStorage setIndex overwrites previous" {
    const allocator = std.testing.allocator;
    var store = IndexStorage.init(allocator);
    defer store.deinit();

    const a = try allocator.create(Index);
    a.* = Index.init(allocator);
    a.version = 2;
    store.setIndex(a);

    const b = try allocator.create(Index);
    b.* = Index.init(allocator);
    b.version = 3;
    store.setIndex(b);

    const got = try store.index();
    try std.testing.expect(got == b);
    try std.testing.expectEqual(@as(u32, 3), got.version);
    try std.testing.expect(!got.mod_time.isZero());
}

test "IndexStorage holds entries from format/index" {
    const allocator = std.testing.allocator;
    var store = IndexStorage.init(allocator);
    defer store.deinit();

    const idx = try allocator.create(Index);
    idx.* = Index.init(allocator);
    idx.version = 2;
    _ = try idx.add("foo.txt");
    store.setIndex(idx);

    const got = try store.index();
    try std.testing.expectEqual(@as(usize, 1), got.entries.items.len);
    try std.testing.expectEqualStrings("foo.txt", got.entries.items[0].name);
}
