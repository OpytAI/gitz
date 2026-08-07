//! Advertised-refs message value (go-git `plumbing/protocol/packp/advrefs.go`).
//!
//! Values are not zero-value safe — use `AdvRefs.init`.

const std = @import("std");
const plumbing = @import("plumbing");
const capability = @import("capability");
const memory = @import("memory");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const testing = std.testing;

/// Advertised-refs message (go-git `AdvRefs`).
pub const AdvRefs = struct {
    allocator: Allocator,
    /// Prefix payloads (HTTP smart service line, optional flush).
    /// Empty slice entries represent a flush-pkt (go-git `pktline.Flush`).
    prefix: std.ArrayListUnmanaged([]const u8) = .empty,
    /// Resolved HEAD hash when present (upload-pack).
    head: ?Hash = null,
    /// Protocol capabilities.
    capabilities: capability.List,
    /// Hash references by name (keys owned).
    references: std.StringHashMapUnmanaged(Hash) = .empty,
    /// Peeled hash references by name (keys owned).
    peeled: std.StringHashMapUnmanaged(Hash) = .empty,
    /// Shallow object ids.
    shallows: std.ArrayListUnmanaged(Hash) = .empty,

    /// go-git `NewAdvRefs`.
    pub fn init(allocator: Allocator) AdvRefs {
        return .{
            .allocator = allocator,
            .capabilities = capability.List.init(allocator),
        };
    }

    pub fn deinit(self: *AdvRefs) void {
        for (self.prefix.items) |p| {
            if (p.len > 0) self.allocator.free(p);
        }
        self.prefix.deinit(self.allocator);

        self.capabilities.deinit();

        var rit = self.references.iterator();
        while (rit.next()) |e| self.allocator.free(e.key_ptr.*);
        self.references.deinit(self.allocator);

        var pit = self.peeled.iterator();
        while (pit.next()) |e| self.allocator.free(e.key_ptr.*);
        self.peeled.deinit(self.allocator);

        self.shallows.deinit(self.allocator);
        self.* = undefined;
    }

    /// go-git `AddReference`.
    pub fn addReference(self: *AdvRefs, r: Reference) !void {
        switch (r.type) {
            .symbolic => {
                var buf: [512]u8 = undefined;
                const v = try std.fmt.bufPrint(&buf, "{s}:{s}", .{ r.name.raw, r.target.raw });
                try self.capabilities.add(capability.SymRef, &.{v});
            },
            .hash => {
                const key = try self.allocator.dupe(u8, r.name.raw);
                errdefer self.allocator.free(key);
                const gop = try self.references.getOrPut(self.allocator, key);
                if (gop.found_existing) {
                    self.allocator.free(key);
                }
                gop.value_ptr.* = r.hash;
            },
            .invalid => return error.InvalidType,
        }
    }

    /// go-git `AllReferences` — build in-memory reference storage from this message.
    pub fn allReferences(self: *const AdvRefs) !memory.ReferenceStorage {
        var s = memory.ReferenceStorage.init(self.allocator);
        errdefer s.deinit();
        try self.addRefs(&s);
        return s;
    }

    fn addRefs(self: *const AdvRefs, s: *memory.ReferenceStorage) !void {
        var it = self.references.iterator();
        while (it.next()) |e| {
            var hex_buf: [plumbing.HexSize]u8 = undefined;
            const hex = e.value_ptr.string(&hex_buf);
            const ref = Reference.fromStrings(e.key_ptr.*, hex);
            try s.setReference(ref);
        }

        if (self.supportSymrefs()) {
            try self.addSymbolicRefs(s);
            return;
        }
        try self.resolveHead(s);
    }

    /// Guess HEAD target when the server does not advertise `symref` (go-git).
    fn resolveHead(self: *const AdvRefs, s: *memory.ReferenceStorage) !void {
        const head_hash = self.head orelse return;

        // Prefer master when it matches HEAD.
        if (s.reference(plumbing.master)) |ref| {
            if (try self.createHeadIfCorrectReference(ref, s, head_hash)) return;
        } else |err| {
            if (err != error.ReferenceNotFound) return err;
        }

        var iter = try s.iterReferences();
        defer iter.deinit();

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(self.allocator);

        while (true) {
            const r = iter.next() catch |err| switch (err) {
                error.EndOfStream => break,
            };
            try names.append(self.allocator, r.name.raw);
        }

        std.mem.sort([]const u8, names.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);

        var head_set = false;
        for (names.items) |ref_name| {
            const ref = try s.reference(ReferenceName.init(ref_name));
            if (try self.createHeadIfCorrectReference(ref, s, head_hash)) {
                head_set = true;
                break;
            }
        }

        if (!head_set) return error.ReferenceNotFound;
    }

    fn createHeadIfCorrectReference(
        self: *const AdvRefs,
        reference: Reference,
        s: *memory.ReferenceStorage,
        head_hash: Hash,
    ) !bool {
        _ = self;
        if (!reference.hash.eql(head_hash)) return false;
        const head_ref = Reference.newSymbolicReference(plumbing.HEAD, reference.name);
        try s.setReference(head_ref);
        return true;
    }

    fn addSymbolicRefs(self: *const AdvRefs, s: *memory.ReferenceStorage) !void {
        const values = self.capabilities.get(capability.SymRef);
        for (values) |symref| {
            var it = std.mem.splitScalar(u8, symref, ':');
            const name_s = it.next() orelse {
                return error.UnexpectedData;
            };
            const target_s = it.next() orelse {
                return error.UnexpectedData;
            };
            if (it.next() != null) return error.UnexpectedData;

            const ref = Reference.newSymbolicReference(
                ReferenceName.init(name_s),
                ReferenceName.init(target_s),
            );
            try s.setReference(ref);
        }
    }

    fn supportSymrefs(self: *const AdvRefs) bool {
        return self.capabilities.supports(capability.SymRef);
    }

    /// go-git `IsEmpty` — true when there is no head, refs, peeled, or shallows.
    pub fn isEmpty(self: *const AdvRefs) bool {
        return self.head == null and
            self.references.count() == 0 and
            self.peeled.count() == 0 and
            self.shallows.items.len == 0;
    }

    /// Encode this message (go-git `Encode`). Implementation in `advrefs_encode.zig`.
    pub fn encode(self: *const AdvRefs, w: *std.Io.Writer) !void {
        return @import("advrefs_encode.zig").encode(self, w);
    }

    /// Decode into this message (go-git `Decode`). Implementation in `advrefs_decode.zig`.
    pub fn decode(self: *AdvRefs, r: *std.Io.Reader) !void {
        return @import("advrefs_decode.zig").decode(self, r);
    }

    // --- helpers used by encode/decode siblings ---

    /// Insert or replace a reference hash (owns a copy of `name`).
    pub fn putReference(self: *AdvRefs, name: []const u8, hash: Hash) Allocator.Error!void {
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        const gop = try self.references.getOrPut(self.allocator, key);
        if (gop.found_existing) self.allocator.free(key);
        gop.value_ptr.* = hash;
    }

    /// Insert or replace a peeled hash (owns a copy of `name`).
    pub fn putPeeled(self: *AdvRefs, name: []const u8, hash: Hash) Allocator.Error!void {
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        const gop = try self.peeled.getOrPut(self.allocator, key);
        if (gop.found_existing) self.allocator.free(key);
        gop.value_ptr.* = hash;
    }

    /// Append an owned prefix payload (or flush via empty slice).
    pub fn appendPrefix(self: *AdvRefs, payload: []const u8) Allocator.Error!void {
        if (payload.len == 0) {
            try self.prefix.append(self.allocator, &.{});
            return;
        }
        const owned = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(owned);
        try self.prefix.append(self.allocator, owned);
    }

    pub fn appendShallow(self: *AdvRefs, hash: Hash) Allocator.Error!void {
        try self.shallows.append(self.allocator, hash);
    }
};



// ---------------------------------------------------------------------------
// Tests — go-git advrefs_test.go
// ---------------------------------------------------------------------------

test "advrefs.TestAddReferenceSymbolic" {
    const allocator = testing.allocator;
    var a = AdvRefs.init(allocator);
    defer a.deinit();

    const ref = Reference.newSymbolicReference(
        ReferenceName.init("foo"),
        ReferenceName.init("bar"),
    );
    try a.addReference(ref);

    const values = a.capabilities.get(capability.SymRef);
    try testing.expectEqual(@as(usize, 1), values.len);
    try testing.expectEqualStrings("foo:bar", values[0]);
}

test "advrefs.TestAddReferenceHash" {
    const allocator = testing.allocator;
    var a = AdvRefs.init(allocator);
    defer a.deinit();

    const h = plumbing.newHash("5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c");
    const ref = Reference.newHashReference(ReferenceName.init("foo"), h);
    try a.addReference(ref);

    try testing.expectEqual(@as(usize, 1), a.references.count());
    const got = a.references.get("foo").?;
    var buf: [plumbing.HexSize]u8 = undefined;
    try testing.expectEqualStrings("5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c", got.string(&buf));
}

test "advrefs.TestAllReferences" {
    const allocator = testing.allocator;
    var a = AdvRefs.init(allocator);
    defer a.deinit();

    const hash = plumbing.newHash("5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c");
    try a.addReference(Reference.newSymbolicReference(
        ReferenceName.init("foo"),
        ReferenceName.init("bar"),
    ));
    try a.addReference(Reference.newHashReference(ReferenceName.init("bar"), hash));

    var refs = try a.allReferences();
    defer refs.deinit();

    var iter = try refs.iterReferences();
    defer iter.deinit();

    var count: usize = 0;
    while (true) {
        const ref = iter.next() catch |err| switch (err) {
            error.EndOfStream => break,
        };
        count += 1;
        if (std.mem.eql(u8, ref.name.raw, "bar")) {
            try testing.expect(ref.hash.eql(hash));
        } else if (std.mem.eql(u8, ref.name.raw, "foo")) {
            try testing.expectEqualStrings("bar", ref.target.raw);
        }
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "advrefs.TestAllReferencesBadSymref" {
    const allocator = testing.allocator;
    var a = AdvRefs.init(allocator);
    defer a.deinit();

    try a.capabilities.set(capability.SymRef, &.{"foo"});
    try testing.expectError(error.UnexpectedData, a.allReferences());
}

test "advrefs.TestIsEmpty" {
    const allocator = testing.allocator;
    var a = AdvRefs.init(allocator);
    defer a.deinit();
    try testing.expect(a.isEmpty());
}

test "advrefs.TestNoSymRefCapabilityHeadToMaster" {
    const allocator = testing.allocator;
    var a = AdvRefs.init(allocator);
    defer a.deinit();

    const head_hash = plumbing.newHash("5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c");
    a.head = head_hash;
    const ref = Reference.newHashReference(plumbing.master, head_hash);
    try a.addReference(ref);

    var storage = try a.allReferences();
    defer storage.deinit();

    const head = try storage.reference(plumbing.HEAD);
    try testing.expectEqualStrings(ref.name.raw, head.target.raw);
}

test "advrefs.TestNoSymRefCapabilityHeadToOtherThanMaster" {
    const allocator = testing.allocator;
    var a = AdvRefs.init(allocator);
    defer a.deinit();

    const head_hash = plumbing.ZeroHash;
    a.head = head_hash;
    try a.addReference(Reference.newHashReference(
        plumbing.master,
        plumbing.newHash("5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c"),
    ));
    const ref2 = Reference.newHashReference(
        ReferenceName.init("other/ref"),
        plumbing.ZeroHash,
    );
    try a.addReference(ref2);

    var storage = try a.allReferences();
    defer storage.deinit();

    const head = try storage.reference(plumbing.HEAD);
    // Symbolic HEAD has zero hash (same as go-git assertion on Hash()).
    try testing.expect(head.hash.eql(ref2.hash));
    try testing.expectEqualStrings("other/ref", head.target.raw);
}

test "advrefs.TestNoSymRefCapabilityHeadToNoRef" {
    const allocator = testing.allocator;
    var a = AdvRefs.init(allocator);
    defer a.deinit();

    a.head = plumbing.ZeroHash;
    try a.addReference(Reference.newHashReference(
        plumbing.master,
        plumbing.newHash("5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c"),
    ));

    try testing.expectError(error.ReferenceNotFound, a.allReferences());
}

test "advrefs.TestNoSymRefCapabilityHeadToNoMasterAlphabeticallyOrdered" {
    const allocator = testing.allocator;
    var a = AdvRefs.init(allocator);
    defer a.deinit();

    const head_hash = plumbing.newHash("5dc01c595e6c6ec9ccda4f6f69c131c0dd945f8c");
    a.head = head_hash;
    try a.addReference(Reference.newHashReference(plumbing.master, plumbing.ZeroHash));
    const ref2 = Reference.newHashReference(
        ReferenceName.init("aaaaaaaaaaaaaaa"),
        head_hash,
    );
    try a.addReference(Reference.newHashReference(
        ReferenceName.init("bbbbbbbbbbbbbbb"),
        head_hash,
    ));
    try a.addReference(ref2);

    var storage = try a.allReferences();
    defer storage.deinit();

    const head = try storage.reference(plumbing.HEAD);
    try testing.expectEqualStrings(ref2.name.raw, head.target.raw);
}
