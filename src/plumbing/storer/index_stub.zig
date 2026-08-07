//! Index storer contract + phase-4 stub (go-git `plumbing/storer/index.go`).
//!
//! Full `plumbing/format/index` codec is phase 5. Until then, storages hold a
//! minimal stub (version + mod time) so Reference/Object suites can compile.
//!
//! # IndexStorer method set
//!
//! | Method | go-git | Role |
//! |--------|--------|------|
//! | `setIndex(idx: *IndexStub) !void` | `SetIndex(*index.Index) error` | Store index (ownership policy is backend-specific). |
//! | `index() !*IndexStub` | `Index() (*index.Index, error)` | Current index; create empty default if missing. |
//!
//! go-git uses `plumbing/format/index.Index`. Phase 4 maps that to `IndexStub`.
//! Phase 5 replaces the stub with the real index type.
//!
//! No PackfileWriter (or other optional object traits) live here — see `root.zig`.

const std = @import("std");

/// Minimal index placeholder until phase 5 (full index codec).
pub const IndexStub = struct {
    /// Index file version (go-git default is 2).
    version: u32 = 2,
    /// Last modification time, unix seconds (optional metadata).
    mod_time_sec: i64 = 0,

    pub fn init() IndexStub {
        return .{};
    }
};

/// Documented method names for inventories / implementors (not callables).
pub const method_set = struct {
    pub const set_index = "setIndex";
    pub const index = "index";
};

/// In-memory IndexStorer helper for tests.
pub const IndexStubStore = struct {
    current: ?IndexStub = null,

    pub fn setIndex(self: *IndexStubStore, idx: IndexStub) void {
        self.current = idx;
    }

    pub fn index(self: *IndexStubStore) IndexStub {
        if (self.current) |c| return c;
        return IndexStub.init();
    }
};

test "IndexStubStore default and set" {
    var store: IndexStubStore = .{};
    const empty = store.index();
    try std.testing.expectEqual(@as(u32, 2), empty.version);

    store.setIndex(.{ .version = 3, .mod_time_sec = 42 });
    const got = store.index();
    try std.testing.expectEqual(@as(u32, 3), got.version);
    try std.testing.expectEqual(@as(i64, 42), got.mod_time_sec);
}
