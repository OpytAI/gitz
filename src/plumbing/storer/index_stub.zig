//! IndexStorer method-set docs + lightweight test helper
//! (go-git `plumbing/storer/index.go`).
//!
//! Production backends (`storage/memory`) use `plumbing/format/index.Index`.
//! `IndexStub` remains only for storer package unit tests that need a tiny
//! stand-in without depending on the full codec.
//!
//! # IndexStorer method set
//!
//! | Method | go-git | Role |
//! |--------|--------|------|
//! | `setIndex(idx)` | `SetIndex(*index.Index) error` | Store index (ownership is backend-specific). |
//! | `index()` | `Index() (*index.Index, error)` | Current index; create empty default if missing. |
//!
//! No PackfileWriter (or other optional object traits) live here — see `root.zig`.

const std = @import("std");

/// Tiny stand-in for storer-package tests only (not a full dircache).
pub const IndexStub = struct {
    /// Index file version (go-git default is 2).
    version: u32 = 2,
    /// Last modification time, unix seconds.
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
