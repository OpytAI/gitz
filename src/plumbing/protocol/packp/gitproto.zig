//! Git transport protocol request (command + pathname + host + extras).
//! Port of go-git `plumbing/protocol/packp/gitproto.go` (v5.19.2).

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const pktline = @import("pktline");
const common = @import("common.zig");

/// Command request for the git protocol (go-git `GitProtoRequest`).
///
/// See https://git-scm.com/docs/pack-protocol#_git_transport
pub const GitProtoRequest = struct {
    allocator: Allocator,
    /// Service/command name (e.g. `git-upload-pack`).
    request_command: []const u8 = "",
    /// Repository path on the remote.
    pathname: []const u8 = "",
    /// Optional `host=` value (without the `host=` prefix).
    host: []const u8 = "",
    /// Optional extra parameters (protocol v2).
    extra_params: std.ArrayListUnmanaged([]const u8) = .empty,
    /// When true, string fields and extra_params entries are owned by `allocator`.
    owns_strings: bool = false,

    /// Create an empty request.
    pub fn init(allocator: Allocator) GitProtoRequest {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *GitProtoRequest) void {
        if (self.owns_strings) {
            self.allocator.free(self.request_command);
            self.allocator.free(self.pathname);
            self.allocator.free(self.host);
            for (self.extra_params.items) |p| self.allocator.free(p);
        }
        self.extra_params.deinit(self.allocator);
        self.* = undefined;
    }

    /// go-git `(*GitProtoRequest).validate`.
    pub fn validate(self: *const GitProtoRequest) common.Error!void {
        if (self.request_command.len == 0) return error.InvalidGitProtoRequest;
        if (self.pathname.len == 0) return error.InvalidGitProtoRequest;
    }

    /// Encodes the request as one pkt-line (go-git `Encode`).
    pub fn encode(self: *const GitProtoRequest, w: *Writer) (common.Error || pktline.Error || Writer.Error || Allocator.Error)!void {
        try self.validate();

        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(self.allocator);

        try list.appendSlice(self.allocator, self.request_command);
        try list.append(self.allocator, ' ');
        try list.appendSlice(self.allocator, self.pathname);
        try list.append(self.allocator, 0);

        if (self.host.len > 0) {
            try list.appendSlice(self.allocator, "host=");
            try list.appendSlice(self.allocator, self.host);
            try list.append(self.allocator, 0);
        }

        if (self.extra_params.items.len > 0) {
            try list.append(self.allocator, 0);
            for (self.extra_params.items) |param| {
                try list.appendSlice(self.allocator, param);
                try list.append(self.allocator, 0);
            }
        }

        var enc = pktline.Encoder.init(w);
        try enc.encodeLine(list.items);
    }

    /// Decodes one pkt-line request (go-git `Decode`).
    /// Owns decoded strings; call `deinit` after use.
    pub fn decode(self: *GitProtoRequest, r: *Reader) (common.Error || pktline.Error || Reader.Error || Allocator.Error)!void {
        self.clearOwned();

        var sc = pktline.Scanner.init(r);
        if (!sc.scan()) {
            if (sc.err()) |e| return e;
            return error.InvalidGitProtoRequest;
        }

        const line = sc.bytes();
        if (line.len == 0) return error.UnexpectedEof;

        if (line[line.len - 1] != 0) return error.InvalidGitProtoRequest;

        const sp_idx = std.mem.indexOfScalar(u8, line, ' ') orelse return error.InvalidGitProtoRequest;
        const cmd = line[0..sp_idx];
        const rest = line[sp_idx + 1 ..];

        // Split on NUL; trailing empty segments from NULs are skipped for extras.
        var params: std.ArrayListUnmanaged([]const u8) = .empty;
        defer params.deinit(self.allocator);
        var it = std.mem.splitScalar(u8, rest, 0);
        while (it.next()) |p| {
            try params.append(self.allocator, p);
        }
        if (params.items.len < 1) return error.InvalidGitProtoRequest;

        // Allocate all owned pieces first; transfer to `self` only on full success.
        const cmd_owned = try self.allocator.dupe(u8, cmd);
        errdefer self.allocator.free(cmd_owned);
        const path_owned = try self.allocator.dupe(u8, params.items[0]);
        errdefer self.allocator.free(path_owned);
        const host_owned = blk: {
            if (params.items.len > 1) {
                const host_raw = params.items[1];
                const host_val = if (std.mem.startsWith(u8, host_raw, "host="))
                    host_raw["host=".len..]
                else
                    host_raw;
                break :blk try self.allocator.dupe(u8, host_val);
            }
            break :blk try self.allocator.dupe(u8, "");
        };
        errdefer self.allocator.free(host_owned);

        var extras: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (extras.items) |p| self.allocator.free(p);
            extras.deinit(self.allocator);
        }
        if (params.items.len > 2) {
            for (params.items[2..]) |param| {
                if (param.len == 0) continue;
                const owned = try self.allocator.dupe(u8, param);
                errdefer self.allocator.free(owned);
                try extras.append(self.allocator, owned);
            }
        }

        self.request_command = cmd_owned;
        self.pathname = path_owned;
        self.host = host_owned;
        self.extra_params = extras;
        self.owns_strings = true;
    }

    fn clearOwned(self: *GitProtoRequest) void {
        if (self.owns_strings) {
            self.allocator.free(self.request_command);
            self.allocator.free(self.pathname);
            self.allocator.free(self.host);
            for (self.extra_params.items) |p| self.allocator.free(p);
        }
        self.extra_params.clearRetainingCapacity();
        self.request_command = "";
        self.pathname = "";
        self.host = "";
        self.owns_strings = false;
    }
};

// ---------------------------------------------------------------------------
// Tests — gitproto_test.go
// ---------------------------------------------------------------------------

test "encode empty GitProtoRequest" {
    var storage: [64]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var p = GitProtoRequest.init(testing.allocator);
    defer p.deinit();
    try testing.expectError(error.InvalidGitProtoRequest, p.encode(&w));
}

test "encode GitProtoRequest" {
    var storage: [128]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var p = GitProtoRequest.init(testing.allocator);
    defer p.deinit();
    p.request_command = "command";
    p.pathname = "pathname";
    p.host = "host";
    try p.extra_params.append(testing.allocator, "param1");
    try p.extra_params.append(testing.allocator, "param2");
    try p.encode(&w);
    try testing.expectEqualStrings(
        "002ecommand pathname\x00host=host\x00\x00param1\x00param2\x00",
        w.buffered(),
    );
}

test "encode invalid GitProtoRequest missing pathname" {
    var storage: [64]u8 = undefined;
    var w: Writer = .fixed(&storage);
    var p = GitProtoRequest.init(testing.allocator);
    defer p.deinit();
    p.request_command = "command";
    try testing.expectError(error.InvalidGitProtoRequest, p.encode(&w));
}

test "decode empty GitProtoRequest" {
    var r: Reader = .fixed(&.{});
    var p = GitProtoRequest.init(testing.allocator);
    defer p.deinit();
    try testing.expectError(error.InvalidGitProtoRequest, p.decode(&r));
}

test "decode GitProtoRequest" {
    const raw = "002ecommand pathname\x00host=host\x00\x00param1\x00param2\x00";
    var r: Reader = .fixed(raw);
    var p = GitProtoRequest.init(testing.allocator);
    defer p.deinit();
    try p.decode(&r);
    try testing.expectEqualStrings("command", p.request_command);
    try testing.expectEqualStrings("pathname", p.pathname);
    try testing.expectEqualStrings("host", p.host);
    try testing.expectEqual(@as(usize, 2), p.extra_params.items.len);
    try testing.expectEqualStrings("param1", p.extra_params.items[0]);
    try testing.expectEqualStrings("param2", p.extra_params.items[1]);
}

test "decode invalid GitProtoRequest missing null terminator" {
    // Correct pkt-len (4 + 20) for payload without a trailing NUL.
    const raw = "0018git-upload-pack /foo";
    var r: Reader = .fixed(raw);
    var p = GitProtoRequest.init(testing.allocator);
    defer p.deinit();
    try testing.expectError(error.InvalidGitProtoRequest, p.decode(&r));
}

test "validate empty GitProtoRequest" {
    var p = GitProtoRequest.init(testing.allocator);
    defer p.deinit();
    try testing.expectError(error.InvalidGitProtoRequest, p.validate());
}
