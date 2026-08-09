//! In-memory reference storage (go-git `storage/memory` ReferenceStorage).

const std = @import("std");
const plumbing = @import("plumbing");

const Allocator = std.mem.Allocator;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;

pub const ReferenceUpdate = struct {
    name: ReferenceName,
    new_reference: ?Reference,
    expected: ?Reference = null,
    require_absent: bool = false,
};

pub const ReferenceUpdateError = error{
    ReferenceHasChanged,
    DuplicateReference,
    ReferenceNameMismatch,
};

/// Map of owned reference name → owned `Reference` (name strings heap-owned).
pub const ReferenceStorage = struct {
    allocator: Allocator,
    refs: std.StringHashMapUnmanaged(Reference) = .empty,

    pub fn init(allocator: Allocator) ReferenceStorage {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ReferenceStorage) void {
        var it = self.refs.iterator();
        while (it.next()) |e| {
            freeOwned(self.allocator, e.key_ptr.*, e.value_ptr.*);
        }
        self.refs.deinit(self.allocator);
        self.* = undefined;
    }

    /// go-git `SetReference`. Duplicates the reference name (and symbolic target).
    ///
    /// On allocation failure the previous value (if any) is left intact.
    pub fn setReference(self: *ReferenceStorage, ref: Reference) Allocator.Error!void {
        if (ref.type == .invalid and ref.name.raw.len == 0) return;

        // Allocate the new entry first so a failure never drops an existing ref.
        const key = try self.allocator.dupe(u8, ref.name.raw);
        var key_needs_free = true;
        errdefer if (key_needs_free) self.allocator.free(key);

        var owned = try cloneOwned(self.allocator, ref, key);
        errdefer freeReferenceValue(self.allocator, owned);

        const gop = try self.refs.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            // Reuse the map's key; free the provisional key and old value payload.
            freeReferenceValue(self.allocator, gop.value_ptr.*);
            owned.name = ReferenceName.init(gop.key_ptr.*);
            self.allocator.free(key);
            key_needs_free = false;
            gop.value_ptr.* = owned;
        } else {
            // Map now owns `key`; `owned.name` already points at it.
            key_needs_free = false;
            gop.value_ptr.* = owned;
        }
    }

    /// go-git `CheckAndSetReference`.
    ///
    /// When `old` is non-null and a current ref exists with a different hash,
    /// returns `error.ReferenceHasChanged` (go-git `storage.ErrReferenceHasChanged`).
    pub fn checkAndSetReference(
        self: *ReferenceStorage,
        ref: ?Reference,
        old: ?Reference,
    ) (Allocator.Error || error{ReferenceHasChanged})!void {
        const new_ref = ref orelse return;

        if (old) |o| {
            if (self.refs.get(new_ref.name.raw)) |tmp| {
                if (!tmp.hash.eql(o.hash)) return error.ReferenceHasChanged;
            }
        }
        try self.setReference(new_ref);
    }

    /// go-git `Reference`.
    pub fn reference(self: *const ReferenceStorage, n: ReferenceName) plumbing.Error!Reference {
        return self.refs.get(n.raw) orelse error.ReferenceNotFound;
    }

    /// go-git `IterReferences`.
    pub fn iterReferences(self: *const ReferenceStorage) Allocator.Error!ReferenceSliceIter {
        return try ReferenceSliceIter.fromMap(self.allocator, &self.refs);
    }

    /// go-git `CountLooseRefs`.
    pub fn countLooseRefs(self: *const ReferenceStorage) usize {
        return self.refs.count();
    }

    /// go-git `PackRefs` — no-op for memory.
    pub fn packRefs(_: *ReferenceStorage) void {}

    /// go-git `RemoveReference`.
    pub fn removeReference(self: *ReferenceStorage, n: ReferenceName) void {
        if (self.refs.fetchRemove(n.raw)) |old| {
            freeOwned(self.allocator, old.key, old.value);
        }
    }

    /// Validate and allocate a complete replacement map without changing the
    /// visible refs. Publish it later with `commitPrepared`.
    pub fn prepareUpdates(
        self: *const ReferenceStorage,
        updates: []const ReferenceUpdate,
    ) (Allocator.Error || plumbing.Error || ReferenceUpdateError)!ReferenceStorage {
        var names: std.StringHashMapUnmanaged(void) = .empty;
        defer names.deinit(self.allocator);

        for (updates) |update| {
            try update.name.validate();
            if (names.contains(update.name.raw)) return error.DuplicateReference;
            try names.put(self.allocator, update.name.raw, {});

            if (update.new_reference) |new_ref| {
                if (!std.mem.eql(u8, new_ref.name.raw, update.name.raw)) {
                    return error.ReferenceNameMismatch;
                }
                try new_ref.name.validate();
                if (new_ref.type == .symbolic) try new_ref.target.validate();
            }

            const current = self.refs.get(update.name.raw);
            if (update.require_absent and current != null) return error.ReferenceHasChanged;
            if (update.expected) |expected| {
                if (current == null or !referencesEqual(current.?, expected)) {
                    return error.ReferenceHasChanged;
                }
            }
        }

        var prepared = ReferenceStorage.init(self.allocator);
        errdefer prepared.deinit();
        var current_it = self.refs.valueIterator();
        while (current_it.next()) |ref| try prepared.setReference(ref.*);
        for (updates) |update| {
            if (update.new_reference) |new_ref| {
                try prepared.setReference(new_ref);
            } else {
                prepared.removeReference(update.name);
            }
        }
        return prepared;
    }

    /// Publish a map returned by `prepareUpdates`. This cannot fail.
    pub fn commitPrepared(self: *ReferenceStorage, prepared: *ReferenceStorage) void {
        std.mem.swap(std.StringHashMapUnmanaged(Reference), &self.refs, &prepared.refs);
        prepared.deinit();
    }

    pub fn applyUpdates(
        self: *ReferenceStorage,
        updates: []const ReferenceUpdate,
    ) (Allocator.Error || ReferenceUpdateError)!void {
        var prepared = try self.prepareUpdates(updates);
        self.commitPrepared(&prepared);
    }
};

fn referencesEqual(a: Reference, b: Reference) bool {
    if (a.type != b.type or !std.mem.eql(u8, a.name.raw, b.name.raw)) return false;
    return switch (a.type) {
        .hash => a.hash.eql(b.hash),
        .symbolic => std.mem.eql(u8, a.target.raw, b.target.raw),
        .invalid => true,
    };
}

fn cloneOwned(allocator: Allocator, ref: Reference, name_owned: []u8) Allocator.Error!Reference {
    var out = ref;
    out.name = ReferenceName.init(name_owned);
    if (ref.type == .symbolic) {
        const t = try allocator.dupe(u8, ref.target.raw);
        out.target = ReferenceName.init(t);
    } else {
        out.target = ReferenceName.init("");
    }
    return out;
}

/// Free symbolic target only (name/key is separate).
fn freeReferenceValue(allocator: Allocator, ref: Reference) void {
    if (ref.type == .symbolic and ref.target.raw.len > 0) {
        allocator.free(ref.target.raw);
    }
}

fn freeOwned(allocator: Allocator, key: []const u8, ref: Reference) void {
    freeReferenceValue(allocator, ref);
    allocator.free(key);
}

/// Slice iterator over references (go-git `ReferenceSliceIter`).
pub const ReferenceSliceIter = struct {
    allocator: ?Allocator = null,
    owned: ?[]Reference = null,
    items: []Reference = &.{},
    pos: usize = 0,

    pub fn fromMap(allocator: Allocator, map: *const std.StringHashMapUnmanaged(Reference)) Allocator.Error!ReferenceSliceIter {
        var list: std.ArrayList(Reference) = .empty;
        errdefer list.deinit(allocator);
        var it = map.valueIterator();
        while (it.next()) |vp| {
            try list.append(allocator, vp.*);
        }
        const owned = try list.toOwnedSlice(allocator);
        return .{
            .allocator = allocator,
            .owned = owned,
            .items = owned,
        };
    }

    pub fn deinit(self: *ReferenceSliceIter) void {
        if (self.owned) |o| {
            if (self.allocator) |a| a.free(o);
        }
        self.* = .{};
    }

    pub fn next(self: *ReferenceSliceIter) error{EndOfStream}!Reference {
        if (self.pos >= self.items.len) return error.EndOfStream;
        const r = self.items[self.pos];
        self.pos += 1;
        return r;
    }

    pub fn forEach(self: *ReferenceSliceIter, cb: anytype) anyerror!void {
        defer self.close();
        while (true) {
            const r = self.next() catch |err| switch (err) {
                error.EndOfStream => return,
            };
            @call(.auto, cb, .{r}) catch |err| {
                const e: anyerror = err;
                if (e == error.Stop) return;
                return e;
            };
        }
    }

    pub fn close(self: *ReferenceSliceIter) void {
        self.pos = self.items.len;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ReferenceStorage set get remove not found" {
    const allocator = std.testing.allocator;
    var store = ReferenceStorage.init(allocator);
    defer store.deinit();

    try store.setReference(plumbing.Reference.fromStrings(
        "refs/heads/main",
        "c3f4688a08fd86f1bf8e055724c84b7a40a09733",
    ));
    const got = try store.reference(plumbing.ReferenceName.init("refs/heads/main"));
    var buf: [plumbing.MaxHexSize]u8 = undefined;
    try std.testing.expectEqualStrings(
        "c3f4688a08fd86f1bf8e055724c84b7a40a09733",
        got.hash.string(&buf),
    );

    store.removeReference(plumbing.ReferenceName.init("refs/heads/main"));
    try std.testing.expectError(
        error.ReferenceNotFound,
        store.reference(plumbing.ReferenceName.init("refs/heads/main")),
    );
}

test "ReferenceStorage checkAndSet success failure and nil old" {
    const allocator = std.testing.allocator;
    var store = ReferenceStorage.init(allocator);
    defer store.deinit();

    try store.setReference(plumbing.Reference.fromStrings(
        "refs/foo",
        "482e0eada5de4039e6f216b45b3c9b683b83bfa",
    ));

    // CAS success
    try store.checkAndSetReference(
        plumbing.Reference.fromStrings("refs/foo", "bc9968d75e48de59f0870ffb71f5e160bbbdcf52"),
        plumbing.Reference.fromStrings("refs/foo", "482e0eada5de4039e6f216b45b3c9b683b83bfa"),
    );

    // CAS failure → ReferenceHasChanged; value unchanged
    try std.testing.expectError(
        error.ReferenceHasChanged,
        store.checkAndSetReference(
            plumbing.Reference.fromStrings("refs/foo", "c3f4688a08fd86f1bf8e055724c84b7a40a09733"),
            plumbing.Reference.fromStrings("refs/foo", "482e0eada5de4039e6f216b45b3c9b683b83bfa"),
        ),
    );
    const still = try store.reference(plumbing.ReferenceName.init("refs/foo"));
    var buf: [plumbing.MaxHexSize]u8 = undefined;
    try std.testing.expectEqualStrings(
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
        still.hash.string(&buf),
    );

    // nil old → unconditional set
    try store.checkAndSetReference(
        plumbing.Reference.fromStrings("refs/foo", "c3f4688a08fd86f1bf8e055724c84b7a40a09733"),
        null,
    );

    // nil new → no-op
    try store.checkAndSetReference(null, null);
    const after = try store.reference(plumbing.ReferenceName.init("refs/foo"));
    try std.testing.expectEqualStrings(
        "c3f4688a08fd86f1bf8e055724c84b7a40a09733",
        after.hash.string(&buf),
    );
}

test "ReferenceStorage CAS when ref missing with old still sets" {
    const allocator = std.testing.allocator;
    var store = ReferenceStorage.init(allocator);
    defer store.deinit();

    // go-git: if current is nil, old check is skipped and set proceeds.
    try store.checkAndSetReference(
        plumbing.Reference.fromStrings("refs/new", "bc9968d75e48de59f0870ffb71f5e160bbbdcf52"),
        plumbing.Reference.fromStrings("refs/new", "482e0eada5de4039e6f216b45b3c9b683b83bfa"),
    );
    _ = try store.reference(plumbing.ReferenceName.init("refs/new"));
}

test "ReferenceStorage countLooseRefs packRefs symbolic and iter" {
    const allocator = std.testing.allocator;
    var store = ReferenceStorage.init(allocator);
    defer store.deinit();

    try store.setReference(plumbing.Reference.fromStrings(
        "refs/heads/a",
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
    ));
    try store.setReference(plumbing.Reference.fromStrings(
        "HEAD",
        "ref: refs/heads/a",
    ));
    try std.testing.expectEqual(@as(usize, 2), store.countLooseRefs());
    store.packRefs(); // no-op for memory

    var iter = try store.iterReferences();
    defer iter.deinit();
    var n: usize = 0;
    while (iter.next()) |_| {
        n += 1;
    } else |err| {
        try std.testing.expect(err == error.EndOfStream);
    }
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "ReferenceSliceIter forEach Stop" {
    const allocator = std.testing.allocator;
    var store = ReferenceStorage.init(allocator);
    defer store.deinit();

    try store.setReference(plumbing.Reference.fromStrings(
        "refs/a",
        "bc9968d75e48de59f0870ffb71f5e160bbbdcf52",
    ));
    try store.setReference(plumbing.Reference.fromStrings(
        "refs/b",
        "c3f4688a08fd86f1bf8e055724c84b7a40a09733",
    ));

    var iter = try store.iterReferences();
    defer iter.deinit();
    const S = struct {
        var n: usize = 0;
        fn cb(_: plumbing.Reference) anyerror!void {
            n += 1;
            if (n == 1) return error.Stop;
        }
    };
    S.n = 0;
    try iter.forEach(S.cb);
    try std.testing.expectEqual(@as(usize, 1), S.n);
}
