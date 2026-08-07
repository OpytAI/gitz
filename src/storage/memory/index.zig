//! Minimal index storage (go-git `IndexStorage`).
//!
//! Full `plumbing/format/index` codec is phase 5. Phase 4 holds version +
//! mod_time (same surface as `plumbing/storer.IndexStub`) so BaseStorageSuite
//! SetIndex/Index checks pass.

const std = @import("std");

/// Minimal index stub (go-git `index.Index` subset: Version + ModTime).
/// Phase 5 replaces this with the full index format type.
pub const Index = struct {
    version: u32 = 2,
    /// Set when stored via `setIndex` (go-git sets `ModTime = time.Now()`).
    /// `null` means zero / unset (go-git `time.Time{}.IsZero()`).
    mod_time: ?i64 = null,

    pub fn modTimeIsZero(self: *const Index) bool {
        return self.mod_time == null;
    }
};

/// go-git `IndexStorage`.
pub const IndexStorage = struct {
    /// Stored index (field name avoids clash with method `index`).
    stored: ?Index = null,

    pub fn init() IndexStorage {
        return .{};
    }

    pub fn deinit(self: *IndexStorage) void {
        self.* = .{};
    }

    /// go-git `SetIndex` — stores a copy and stamps `mod_time` (simulates fs mtime).
    pub fn setIndex(self: *IndexStorage, idx: Index) void {
        var copy = idx;
        copy.mod_time = milliNow();
        self.stored = copy;
    }

    /// Milliseconds since Unix epoch. Falls back to `1` if the clock is unavailable
    /// (keeps mod-time non-zero so racy-git style checks still see a stamp).
    fn milliNow() i64 {
        // Prefer std.time when present; Zig 0.16 removed milliTimestamp.
        if (@hasDecl(std.time, "nanoTimestamp")) {
            const ns = std.time.nanoTimestamp();
            if (ns > 0) return @intCast(@divTrunc(ns, 1_000_000));
        }
        var ts: std.posix.timespec = undefined;
        const rc = std.posix.system.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 1;
        const sec_ms = @as(i64, @intCast(ts.sec)) * 1000;
        const nsec_ms = @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
        return sec_ms + nsec_ms;
    }

    /// go-git `Index` — returns default empty index (version 2) when unset.
    pub fn index(self: *IndexStorage) *Index {
        if (self.stored == null) {
            self.stored = .{ .version = 2 };
        }
        return &self.stored.?;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "IndexStorage default version 2 zero mod time" {
    var store = IndexStorage.init();
    defer store.deinit();

    const idx = store.index();
    try std.testing.expectEqual(@as(u32, 2), idx.version);
    try std.testing.expect(idx.modTimeIsZero());
}

test "IndexStorage setIndex stamps mod_time" {
    var store = IndexStorage.init();
    defer store.deinit();

    store.setIndex(.{ .version = 2 });
    const idx = store.index();
    try std.testing.expectEqual(@as(u32, 2), idx.version);
    try std.testing.expect(!idx.modTimeIsZero());
}

test "IndexStorage setIndex overwrites previous" {
    var store = IndexStorage.init();
    defer store.deinit();

    store.setIndex(.{ .version = 2 });
    store.setIndex(.{ .version = 3 });
    const idx = store.index();
    try std.testing.expectEqual(@as(u32, 3), idx.version);
    try std.testing.expect(!idx.modTimeIsZero());
}
