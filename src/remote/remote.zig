//! Remote handle — go-git `Remote`, `NewRemote`, and method wrappers.
//!
//! List / Fetch / Push bodies live in `list.zig` / `fetch.zig` / `push.zig`.

const std = @import("std");
const plumbing = @import("plumbing");
const memory = @import("memory");
const server = @import("server");

const options_mod = @import("options.zig");
const list_mod = @import("list.zig");
const fetch_mod = @import("fetch.zig");
const push_mod = @import("push.zig");

const Allocator = std.mem.Allocator;
const Reference = plumbing.Reference;
const ListOptions = options_mod.ListOptions;
const FetchOptions = options_mod.FetchOptions;
const PushOptions = options_mod.PushOptions;

/// go-git `Remote` — local storer + remote config + optional embedded server.
///
/// Fields are public (borrowed; this type does not own them). A config view
/// from storage remains valid only until that storage's next config read or
/// write. When `embedded` is non-null, list/fetch/push use that in-process
/// server; otherwise the transport client registry is used (`session.zig`).
/// Config, name, string, and list are backend-generic. The current fetch and
/// push transport bodies require `memory.Storage`; host-mediated callers use
/// the pack import and build APIs with any supported repository backend.
pub fn RemoteFor(comptime Storage: type) type {
    return struct {
        const Self = @This();

        /// Allocator for list results, `string`, and delegated operations.
        /// Usually `storer.allocator` (not owned).
        allocator: Allocator,
        /// Local object/ref storage (borrowed).
        storer: *Storage,
        /// Borrowed remote config (go-git private field `c`).
        config: *const memory.RemoteConfig,
        /// In-process server used as client. Null → client registry.
        embedded: ?*server.Server = null,

        /// Remote name (`config.name`).
        pub fn name(self: *const Self) []const u8 {
            return self.config.name;
        }

        /// go-git `Remote.String` — `name\turl (fetch)\nname\turl (push)`.
        pub fn string(self: *const Self, allocator: Allocator) Allocator.Error![]u8 {
            const fetch_url: []const u8 = if (self.config.urls.len > 0) self.config.urls[0] else "";
            const push_url: []const u8 = if (self.config.urls.len > 0)
                self.config.urls[self.config.urls.len - 1]
            else
                "";
            return std.fmt.allocPrint(allocator, "{s}\t{s} (fetch)\n{s}\t{s} (push)", .{
                self.config.name,
                fetch_url,
                self.config.name,
                push_url,
            });
        }

        /// go-git `Remote.List`. Caller frees with `freeReferences`.
        pub fn list(self: *const Self, opts: ListOptions) ![]Reference {
            return list_mod.list(self.allocator, self.config, self.embedded, opts);
        }

        /// go-git `Remote.Fetch`. Memory-storage transport implementation.
        /// Returns `error.AlreadyUpToDate` when noop.
        pub fn fetch(self: *Self, opts: *FetchOptions) !void {
            return fetch_mod.fetch(self.allocator, self.storer, self.config, self.embedded, opts);
        }

        /// go-git `Remote.Push`. Memory-storage transport implementation.
        /// Returns `error.AlreadyUpToDate` when noop.
        pub fn push(self: *Self, opts: *PushOptions) !void {
            return push_mod.push(self.allocator, self.storer, self.config, self.embedded, opts);
        }
    };
}

pub const Remote = RemoteFor(memory.Storage);

/// go-git `NewRemote`.
pub fn newRemote(s: anytype, c: *const memory.RemoteConfig) RemoteFor(@TypeOf(s.*)) {
    return .{
        .allocator = s.allocator,
        .storer = s,
        .config = c,
        .embedded = null,
    };
}

/// Like `newRemote`, but bind an in-process server as the client transport.
pub fn newRemoteEmbedded(
    s: anytype,
    c: *const memory.RemoteConfig,
    srv: *server.Server,
) RemoteFor(@TypeOf(s.*)) {
    return .{
        .allocator = s.allocator,
        .storer = s,
        .config = c,
        .embedded = srv,
    };
}

/// Free a reference slice returned by `Remote.list` (owned names + slice).
pub fn freeReferences(allocator: Allocator, refs: []Reference) void {
    list_mod.freeReferences(allocator, refs);
}

test "newRemote fields" {
    const allocator = std.testing.allocator;
    const sto = try memory.newStorage(allocator);
    defer {
        sto.deinit();
        allocator.destroy(sto);
    }
    const name_buf = try allocator.dupe(u8, "origin");
    defer allocator.free(name_buf);
    const url_owned = try allocator.dupe(u8, "file://repo");
    defer allocator.free(url_owned);
    var urls = [_][]u8{url_owned};
    const cfg = memory.RemoteConfig{
        .name = name_buf,
        .urls = urls[0..],
    };
    const r = newRemote(sto, &cfg);
    try std.testing.expectEqualStrings("origin", r.name());
    try std.testing.expect(r.storer == sto);
    try std.testing.expect(r.embedded == null);
    try std.testing.expect(r.config == &cfg);

    const s = try r.string(allocator);
    defer allocator.free(s);
    try std.testing.expectEqualStrings("origin\tfile://repo (fetch)\norigin\tfile://repo (push)", s);
}

test "freeReferences empty" {
    const empty = try std.testing.allocator.alloc(Reference, 0);
    freeReferences(std.testing.allocator, empty);
}
