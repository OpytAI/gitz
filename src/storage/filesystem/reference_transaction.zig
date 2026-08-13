//! Crash-recoverable multi-reference updates for filesystem storage.
//!
//! The immutable journal records both the old and new state. Absence of the
//! durable commit marker means recovery rolls back; presence means recovery
//! rolls forward. Both paths are idempotent, including a crash during recovery.

const std = @import("std");
const fs_pkg = @import("fs");
const plumbing = @import("plumbing");
const memory = @import("memory");

const reference_mod = @import("reference.zig");

const Allocator = std.mem.Allocator;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const ReferenceUpdate = memory.ReferenceUpdate;

const transaction_dir = "transactions";
const journal_path = transaction_dir ++ "/reference-v1.journal";
const commit_path = transaction_dir ++ "/reference-v1.committed";
const lock_path = transaction_dir ++ "/reference.lock";
const journal_header = "gitz-reference-transaction-v1\n";
const max_journal_bytes = 1024 * 1024;
const max_updates = 4096;

pub const Error = error{
    InvalidTransactionJournal,
    TransactionTooLarge,
    InjectedCrash,
} || Allocator.Error || fs_pkg.Error || plumbing.Error || memory.ReferenceUpdateError || reference_mod.Error;

pub const Boundary = union(enum) {
    journal_durable,
    reference_durable: usize,
    commit_durable,
    journal_removed,
    cleanup_durable,
};

/// Tests and embedding applications may request a simulated process death at
/// a durability boundary. Returning true leaves the journal exactly as a real
/// abrupt exit would; the next `recover` resolves it.
pub const FailureInjector = struct {
    context: ?*anyopaque = null,
    should_crash: *const fn (?*anyopaque, Boundary) bool,
};

pub fn ReferenceTransaction(comptime Fs: type) type {
    const ReferenceStorage = reference_mod.ReferenceStorage(Fs);

    return struct {
        const Self = @This();

        allocator: Allocator,
        storage: *ReferenceStorage,
        fs: *Fs,

        pub fn init(storage: *ReferenceStorage) Self {
            return .{
                .allocator = storage.allocator,
                .storage = storage,
                .fs = storage.dir.fsPtr(),
            };
        }

        /// Resolve any transaction left by a killed process. Call this before
        /// exposing repository state to readers.
        pub fn recover(self: *Self) Error!void {
            try self.fs.mkdirAll(transaction_dir, fs_pkg.Mode.dir);
            var lock = try self.fs.openFile(lock_path, fs_pkg.O.RDWR | fs_pkg.O.CREATE, 0o600);
            defer lock.close() catch {};
            try lock.lock();
            try self.recoverLocked();
        }

        /// Validate, journal, durably publish, and clean up one multi-ref set.
        pub fn apply(self: *Self, updates: []const ReferenceUpdate, injector: ?FailureInjector) Error!void {
            if (updates.len > max_updates) return error.TransactionTooLarge;
            try self.fs.mkdirAll(transaction_dir, fs_pkg.Mode.dir);
            var lock = try self.fs.openFile(lock_path, fs_pkg.O.RDWR | fs_pkg.O.CREATE, 0o600);
            defer lock.close() catch {};
            try lock.lock();

            try self.recoverLocked();
            var prepared = try self.storage.prepareUpdates(updates);
            defer prepared.deinit();

            const journal = try encodeJournal(self.allocator, updates, prepared.previous);
            defer self.allocator.free(journal);
            if (journal.len > max_journal_bytes) return error.TransactionTooLarge;
            try self.writeAtomic(journal_path, journal);
            if (shouldCrash(injector, .journal_durable)) return error.InjectedCrash;

            for (updates, 0..) |update, i| {
                self.applyReference(update.name, update.new_reference) catch |original| {
                    self.recoverLocked() catch |recovery_error| return recovery_error;
                    return original;
                };
                self.syncReferenceParent(update.name) catch |original| {
                    self.recoverLocked() catch |recovery_error| return recovery_error;
                    return original;
                };
                if (shouldCrash(injector, .{ .reference_durable = i })) return error.InjectedCrash;
            }

            self.writeAtomic(commit_path, "committed\n") catch |original| {
                self.recoverLocked() catch |recovery_error| return recovery_error;
                return original;
            };
            if (shouldCrash(injector, .commit_durable)) return error.InjectedCrash;
            try self.cleanup(injector);
        }

        fn recoverLocked(self: *Self) Error!void {
            if (!try self.exists(journal_path)) {
                if (try self.exists(commit_path)) {
                    try self.removeIfPresent(commit_path);
                    try self.fs.syncDir(transaction_dir);
                }
                return;
            }

            const stat = try self.fs.stat(journal_path);
            if (stat.size < 0 or stat.size > max_journal_bytes) return error.InvalidTransactionJournal;
            var file = try self.fs.open(journal_path);
            defer file.close() catch {};
            const body = try @import("dotgit").readFileAll(self.allocator, &file);
            defer self.allocator.free(body);
            const entries = try parseJournal(self.allocator, body);
            defer self.allocator.free(entries);

            const roll_forward = try self.exists(commit_path);
            for (entries) |entry| {
                try self.applyReference(entry.name, if (roll_forward) entry.new else entry.old);
                try self.syncReferenceParent(entry.name);
            }
            try self.cleanup(null);
        }

        fn applyReference(self: *Self, name: ReferenceName, value: ?Reference) Error!void {
            if (value) |ref| {
                try self.storage.setReference(ref);
            } else {
                try self.storage.removeReference(name);
            }
        }

        fn writeAtomic(self: *Self, destination: []const u8, body: []const u8) Error!void {
            var temp = try self.fs.tempFile(transaction_dir, "reference-tmp");
            const temp_name = try self.allocator.dupe(u8, temp.fileName());
            defer self.allocator.free(temp_name);
            var open = true;
            defer if (open) temp.close() catch {};
            errdefer self.fs.remove(temp_name) catch {};

            var offset: usize = 0;
            while (offset < body.len) offset += try temp.write(body[offset..]);
            try temp.sync();
            try temp.close();
            open = false;
            try self.fs.rename(temp_name, destination);
            try self.fs.syncDir(transaction_dir);
        }

        fn cleanup(self: *Self, injector: ?FailureInjector) Error!void {
            // Remove the journal first. If the process dies before the marker
            // is removed, recovery observes no work and preserves committed
            // refs. Removing the marker first could incorrectly roll back.
            try self.removeIfPresent(journal_path);
            try self.fs.syncDir(transaction_dir);
            if (shouldCrash(injector, .journal_removed)) return error.InjectedCrash;
            try self.removeIfPresent(commit_path);
            try self.fs.syncDir(transaction_dir);
            if (shouldCrash(injector, .cleanup_durable)) return error.InjectedCrash;
        }

        fn removeIfPresent(self: *Self, path: []const u8) Error!void {
            self.fs.remove(path) catch |err| switch (err) {
                error.NotExist => {},
                else => |e| return e,
            };
        }

        fn exists(self: *Self, path: []const u8) Error!bool {
            _ = self.fs.lstat(path) catch |err| switch (err) {
                error.NotExist => return false,
                else => |e| return e,
            };
            return true;
        }

        fn syncReferenceParent(self: *Self, name: ReferenceName) Error!void {
            const parent = fs_pkg.path.parentRel(name.raw) orelse ".";
            try self.fs.syncDir(parent);
            // Removal may also rewrite packed-refs at the storage root.
            try self.fs.syncRoot();
        }
    };
}

const JournalEntry = struct {
    name: ReferenceName,
    old: ?Reference,
    new: ?Reference,
};

fn shouldCrash(injector: ?FailureInjector, boundary: Boundary) bool {
    const value = injector orelse return false;
    return value.should_crash(value.context, boundary);
}

fn encodeJournal(allocator: Allocator, updates: []const ReferenceUpdate, previous: []const ?Reference) Error![]u8 {
    if (updates.len != previous.len) return error.InvalidTransactionJournal;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, journal_header);
    for (updates, previous) |update, old| {
        try out.appendSlice(allocator, update.name.raw);
        try appendReference(allocator, &out, old);
        try appendReference(allocator, &out, update.new_reference);
        try out.append(allocator, '\n');
    }
    return try out.toOwnedSlice(allocator);
}

fn appendReference(allocator: Allocator, out: *std.ArrayList(u8), value: ?Reference) Error!void {
    try out.append(allocator, '\t');
    const ref = value orelse {
        try out.appendSlice(allocator, "-\t");
        return;
    };
    switch (ref.type) {
        .hash => {
            var hex_buf: [plumbing.MaxHexSize]u8 = undefined;
            try out.appendSlice(allocator, "H\t");
            try out.appendSlice(allocator, ref.hash.string(&hex_buf));
        },
        .symbolic => {
            try out.appendSlice(allocator, "S\t");
            try out.appendSlice(allocator, ref.target.raw);
        },
        .invalid => return error.InvalidTransactionJournal,
    }
}

fn parseJournal(allocator: Allocator, body: []const u8) Error![]JournalEntry {
    if (!std.mem.startsWith(u8, body, journal_header)) return error.InvalidTransactionJournal;
    var entries: std.ArrayList(JournalEntry) = .empty;
    errdefer entries.deinit(allocator);
    var lines = std.mem.splitScalar(u8, body[journal_header.len..], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (entries.items.len >= max_updates) return error.TransactionTooLarge;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name_text = fields.next() orelse return error.InvalidTransactionJournal;
        const old_kind = fields.next() orelse return error.InvalidTransactionJournal;
        const old_value = fields.next() orelse return error.InvalidTransactionJournal;
        const new_kind = fields.next() orelse return error.InvalidTransactionJournal;
        const new_value = fields.next() orelse return error.InvalidTransactionJournal;
        if (fields.next() != null) return error.InvalidTransactionJournal;
        const name = ReferenceName.init(name_text);
        try name.validate();
        try entries.append(allocator, .{
            .name = name,
            .old = try parseReference(name, old_kind, old_value),
            .new = try parseReference(name, new_kind, new_value),
        });
    }
    return try entries.toOwnedSlice(allocator);
}

fn parseReference(name: ReferenceName, kind: []const u8, value: []const u8) Error!?Reference {
    if (std.mem.eql(u8, kind, "-")) {
        if (value.len != 0) return error.InvalidTransactionJournal;
        return null;
    }
    if (std.mem.eql(u8, kind, "H")) {
        return Reference.newHashReference(name, plumbing.parseHashAny(value) catch return error.InvalidTransactionJournal);
    }
    if (std.mem.eql(u8, kind, "S")) {
        const target = ReferenceName.init(value);
        try target.validate();
        return Reference.newSymbolicReference(name, target);
    }
    return error.InvalidTransactionJournal;
}

pub const ReferenceTransactionMem = ReferenceTransaction(fs_pkg.Mem);
pub const ReferenceTransactionOs = ReferenceTransaction(fs_pkg.Os);

const CrashPlan = struct {
    at: enum { journal, first_reference, commit, journal_removed, cleanup },

    fn shouldCrash(context: ?*anyopaque, boundary: Boundary) bool {
        const self: *CrashPlan = @ptrCast(@alignCast(context.?));
        return switch (boundary) {
            .journal_durable => self.at == .journal,
            .reference_durable => |index| self.at == .first_reference and index == 0,
            .commit_durable => self.at == .commit,
            .journal_removed => self.at == .journal_removed,
            .cleanup_durable => self.at == .cleanup,
        };
    }

    fn injector(self: *CrashPlan) FailureInjector {
        return .{ .context = self, .should_crash = CrashPlan.shouldCrash };
    }
};

test "reference transaction rolls back every pre-commit crash boundary" {
    const allocator = std.testing.allocator;
    var backend = try fs_pkg.Mem.init(allocator);
    defer backend.deinit();
    var dir = @import("dotgit").DotGitMem.new(&backend);
    defer dir.deinit();
    try dir.initialize();
    var storage = reference_mod.ReferenceStorageMem.init(allocator, &dir);
    defer storage.deinit();
    var transaction = ReferenceTransactionMem.init(&storage);

    const a = ReferenceName.init("refs/heads/a");
    const b = ReferenceName.init("refs/heads/b");
    const old_a = Reference.newHashReference(a, try plumbing.parseHashAny("1111111111111111111111111111111111111111"));
    const old_b = Reference.newHashReference(b, try plumbing.parseHashAny("2222222222222222222222222222222222222222"));
    const new_a = Reference.newHashReference(a, try plumbing.parseHashAny("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    const new_b = Reference.newHashReference(b, try plumbing.parseHashAny("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"));
    try storage.setReference(old_a);
    try storage.setReference(old_b);
    const updates = [_]ReferenceUpdate{
        .{ .name = a, .new_reference = new_a, .expected = old_a },
        .{ .name = b, .new_reference = new_b, .expected = old_b },
    };

    for ([_]CrashPlan{ .{ .at = .journal }, .{ .at = .first_reference } }) |initial_plan| {
        var plan = initial_plan;
        try std.testing.expectError(error.InjectedCrash, transaction.apply(&updates, plan.injector()));
        try transaction.recover();
        const got_a = try storage.reference(a);
        defer @import("dotgit").freeRef(allocator, got_a);
        const got_b = try storage.reference(b);
        defer @import("dotgit").freeRef(allocator, got_b);
        try std.testing.expect(got_a.eql(old_a));
        try std.testing.expect(got_b.eql(old_b));
    }
}

test "reference transaction rolls forward after durable commit marker" {
    const allocator = std.testing.allocator;
    var backend = try fs_pkg.Mem.init(allocator);
    defer backend.deinit();
    var dir = @import("dotgit").DotGitMem.new(&backend);
    defer dir.deinit();
    try dir.initialize();
    var storage = reference_mod.ReferenceStorageMem.init(allocator, &dir);
    defer storage.deinit();
    var transaction = ReferenceTransactionMem.init(&storage);

    const name = ReferenceName.init("refs/heads/main");
    const old = Reference.newHashReference(name, try plumbing.parseHashAny("1111111111111111111111111111111111111111"));
    const new = Reference.newHashReference(name, try plumbing.parseHashAny("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try storage.setReference(old);
    const updates = [_]ReferenceUpdate{.{ .name = name, .new_reference = new, .expected = old }};

    var plan = CrashPlan{ .at = .commit };
    try std.testing.expectError(error.InjectedCrash, transaction.apply(&updates, plan.injector()));
    try transaction.recover();
    {
        const got = try storage.reference(name);
        defer @import("dotgit").freeRef(allocator, got);
        try std.testing.expect(got.eql(new));
    }
    try std.testing.expectError(error.NotExist, backend.stat(journal_path));
    try std.testing.expectError(error.NotExist, backend.stat(commit_path));

    // A kill after removing the journal but before removing the marker must
    // also preserve the committed state; cleanup order is part of the proof.
    try storage.setReference(old);
    plan.at = .journal_removed;
    try std.testing.expectError(error.InjectedCrash, transaction.apply(&updates, plan.injector()));
    try transaction.recover();
    const got_after_cleanup_kill = try storage.reference(name);
    defer @import("dotgit").freeRef(allocator, got_after_cleanup_kill);
    try std.testing.expect(got_after_cleanup_kill.eql(new));
}

test "reference transaction recovery runs on secure Os storage" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var backend = try fs_pkg.Os.initFromDirWithOptions(allocator, io, tmp.dir, "tmp", false, .{ .secure_beneath = true });
    defer backend.deinit();
    var dir = @import("dotgit").DotGitOs.new(&backend);
    defer dir.deinit();
    try dir.initialize();
    var storage = reference_mod.ReferenceStorageOs.init(allocator, &dir);
    defer storage.deinit();
    var transaction = ReferenceTransactionOs.init(&storage);

    const name = ReferenceName.init("refs/heads/main");
    const old = Reference.newHashReference(name, try plumbing.parseHashAny("1111111111111111111111111111111111111111"));
    const new = Reference.newHashReference(name, try plumbing.parseHashAny("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
    try storage.setReference(old);
    const updates = [_]ReferenceUpdate{.{ .name = name, .new_reference = new, .expected = old }};
    var plan = CrashPlan{ .at = .first_reference };
    try std.testing.expectError(error.InjectedCrash, transaction.apply(&updates, plan.injector()));
    try transaction.recover();
    const got = try storage.reference(name);
    defer @import("dotgit").freeRef(allocator, got);
    try std.testing.expect(got.eql(old));
}
