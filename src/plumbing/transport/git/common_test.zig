//! Unit tests for git:// transport (hermetic — no network).
//!
//! Covers go-git `plumbing/transport/git` client wire behavior with BufferConn:
//! DefaultPort, auth rejection, GitProtoRequest host fields, Start encode,
//! session lifecycle. Full protocol e2e lives in `e2e_test.zig` (in-process
//! MapLoader server + live git-daemon).

const std = @import("std");
const testing = std.testing;
const transport = @import("transport");
const packp = @import("packp");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const Endpoint = transport.Endpoint;
const AuthMethod = transport.AuthMethod;

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn makeEp(allocator: Allocator, host: []const u8, port: i32, path: []const u8) !Endpoint {
    return .{
        .allocator = allocator,
        .protocol = try allocator.dupe(u8, "git"),
        .user = &.{},
        .password = &.{},
        .host = try allocator.dupe(u8, host),
        .port = port,
        .path = try allocator.dupe(u8, path),
    };
}

const DummyAuth = struct {
    fn nameFn(_: *anyopaque) []const u8 {
        return "dummy";
    }
    fn formatFn(_: *anyopaque, a: Allocator) Allocator.Error![]u8 {
        return try a.dupe(u8, "dummy");
    }
    const vtable = AuthMethod.VTable{
        .name = nameFn,
        .format = formatFn,
    };
    fn asAuth(self: *DummyAuth) AuthMethod {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

// ---------------------------------------------------------------------------
// DefaultPort
// ---------------------------------------------------------------------------

test "DefaultPort is 9418" {
    try testing.expectEqual(@as(i32, 9418), common.DefaultPort);
}

test "connectPort uses DefaultPort when endpoint port is zero" {
    var ep = try makeEp(testing.allocator, "example.com", 0, "/repo.git");
    defer ep.deinit();
    try testing.expectEqual(@as(u16, 9418), common.connectPort(&ep));
}

test "connectPort uses DefaultPort when endpoint port is negative" {
    var ep = try makeEp(testing.allocator, "example.com", -1, "/repo.git");
    defer ep.deinit();
    try testing.expectEqual(@as(u16, 9418), common.connectPort(&ep));
}

test "connectPort keeps explicit non-default port" {
    var ep = try makeEp(testing.allocator, "example.com", 1234, "/repo.git");
    defer ep.deinit();
    try testing.expectEqual(@as(u16, 1234), common.connectPort(&ep));
}

test "connectPort keeps DefaultPort when set explicitly" {
    var ep = try makeEp(testing.allocator, "example.com", common.DefaultPort, "/repo.git");
    defer ep.deinit();
    try testing.expectEqual(@as(u16, 9418), common.connectPort(&ep));
}

test "connectPort rejects out of range endpoint port" {
    var ep = try makeEp(testing.allocator, "example.com", 99_999, "/repo.git");
    defer ep.deinit();
    try testing.expectError(transport.Error.InvalidEndpoint, common.connectPort(&ep));
}

// ---------------------------------------------------------------------------
// Auth rejected
// ---------------------------------------------------------------------------

test "runner rejects injected service and NUL pathname" {
    var runner = common.Runner.init(testing.allocator, testing.io);
    defer runner.deinit();
    var buf = common.BufferConn.init(testing.allocator);
    defer buf.deinit();
    runner.setDial(&buf, common.BufferConn.dialFn);

    var ep = try makeEp(testing.allocator, "localhost", common.DefaultPort, "/repo.git");
    defer ep.deinit();
    try testing.expectError(
        transport.Error.InvalidEndpoint,
        runner.command("git-upload-pack\x00host=evil", &ep, null),
    );

    testing.allocator.free(ep.path);
    ep.path = try testing.allocator.dupe(u8, "/repo.git\x00host=evil");
    try testing.expectError(
        transport.Error.InvalidEndpoint,
        runner.command(transport.UploadPackServiceName, &ep, null),
    );
}

test "Command rejects auth (ErrInvalidAuthMethod)" {
    var runner = common.Runner.init(testing.allocator, testing.io);
    defer runner.deinit();
    var buf = common.BufferConn.init(testing.allocator);
    defer buf.deinit();
    runner.setDial(&buf, common.BufferConn.dialFn);

    var ep = try makeEp(testing.allocator, "localhost", common.DefaultPort, "/repo.git");
    defer ep.deinit();

    var dummy: DummyAuth = .{};
    try testing.expectError(
        error.InvalidAuthMethod,
        runner.command("git-upload-pack", &ep, dummy.asAuth()),
    );
}

test "Command accepts null auth" {
    var runner = common.Runner.init(testing.allocator, testing.io);
    defer runner.deinit();
    var buf = common.BufferConn.init(testing.allocator);
    defer buf.deinit();
    runner.setDial(&buf, common.BufferConn.dialFn);

    var ep = try makeEp(testing.allocator, "localhost", common.DefaultPort, "/repo.git");
    defer ep.deinit();

    const cmd = try runner.command("git-upload-pack", &ep, null);
    try cmd.close();
}

// ---------------------------------------------------------------------------
// GitProtoRequest host field rules
// ---------------------------------------------------------------------------

test "requestHost bare when port is DefaultPort" {
    var ep = try makeEp(testing.allocator, "git.example.com", common.DefaultPort, "/foo.git");
    defer ep.deinit();
    const host = try common.requestHost(testing.allocator, &ep);
    defer testing.allocator.free(host);
    try testing.expectEqualStrings("git.example.com", host);
}

test "requestHost joins host:port when port is non-default" {
    var ep = try makeEp(testing.allocator, "git.example.com", 1234, "/foo.git");
    defer ep.deinit();
    const host = try common.requestHost(testing.allocator, &ep);
    defer testing.allocator.free(host);
    try testing.expectEqualStrings("git.example.com:1234", host);
}

test "requestHost joins host:0 when port is zero" {
    // Matches go-git Start: Port 0 != DefaultPort → JoinHostPort(host, "0").
    var ep = try makeEp(testing.allocator, "git.example.com", 0, "/foo.git");
    defer ep.deinit();
    const host = try common.requestHost(testing.allocator, &ep);
    defer testing.allocator.free(host);
    try testing.expectEqualStrings("git.example.com:0", host);
}

test "joinHostPort brackets IPv6 host" {
    const s = try common.joinHostPort(testing.allocator, "::1", 9418);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("[::1]:9418", s);
}

test "joinHostPort does not double-bracket already-bracketed IPv6" {
    // gitz endpoints keep brackets; JoinHostPort must not produce [[::1]]:port.
    const s = try common.joinHostPort(testing.allocator, "[::1]", 1234);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("[::1]:1234", s);
}

test "bareHost strips brackets" {
    try testing.expectEqualStrings("::1", common.bareHost("[::1]"));
    try testing.expectEqualStrings("example.com", common.bareHost("example.com"));
}

test "requestHost IPv6 non-default port is single-bracketed" {
    var ep = try makeEp(testing.allocator, "[::1]", 1234, "/repo.git");
    defer ep.deinit();
    const host = try common.requestHost(testing.allocator, &ep);
    defer testing.allocator.free(host);
    try testing.expectEqualStrings("[::1]:1234", host);
}

// ---------------------------------------------------------------------------
// Command Start encodes GitProtoRequest on buffer connection
// ---------------------------------------------------------------------------

test "Command Start encodes GitProtoRequest default port" {
    var runner = common.Runner.init(testing.allocator, testing.io);
    defer runner.deinit();
    var buf = common.BufferConn.init(testing.allocator);
    defer buf.deinit();
    runner.setDial(&buf, common.BufferConn.dialFn);

    var ep = try makeEp(testing.allocator, "example.com", common.DefaultPort, "/repo.git");
    defer ep.deinit();

    const cmd = try runner.command("git-upload-pack", &ep, null);
    // Dial recorded host/port used for connect.
    try testing.expectEqualStrings("example.com", buf.dial_host);
    try testing.expectEqual(@as(u16, 9418), buf.dial_port);

    try cmd.start();

    // Decode what was written and check GitProtoRequest fields.
    var r: std.Io.Reader = .fixed(buf.written());
    var req = packp.GitProtoRequest.init(testing.allocator);
    defer req.deinit();
    try req.decode(&r);
    try testing.expectEqualStrings("git-upload-pack", req.request_command);
    try testing.expectEqualStrings("/repo.git", req.pathname);
    try testing.expectEqualStrings("example.com", req.host);

    try cmd.close();
    try testing.expect(buf.closed);
}

test "Command Start encodes GitProtoRequest non-default port" {
    var runner = common.Runner.init(testing.allocator, testing.io);
    defer runner.deinit();
    var buf = common.BufferConn.init(testing.allocator);
    defer buf.deinit();
    runner.setDial(&buf, common.BufferConn.dialFn);

    var ep = try makeEp(testing.allocator, "example.com", 1234, "/path/to/repo");
    defer ep.deinit();

    const cmd = try runner.command("git-receive-pack", &ep, null);
    try testing.expectEqual(@as(u16, 1234), buf.dial_port);

    try cmd.start();

    var r: std.Io.Reader = .fixed(buf.written());
    var req = packp.GitProtoRequest.init(testing.allocator);
    defer req.deinit();
    try req.decode(&r);
    try testing.expectEqualStrings("git-receive-pack", req.request_command);
    try testing.expectEqualStrings("/path/to/repo", req.pathname);
    try testing.expectEqualStrings("example.com:1234", req.host);

    try cmd.close();
}

test "Command Start encode matches known pkt-line bytes" {
    var runner = common.Runner.init(testing.allocator, testing.io);
    defer runner.deinit();
    var buf = common.BufferConn.init(testing.allocator);
    defer buf.deinit();
    runner.setDial(&buf, common.BufferConn.dialFn);

    var ep = try makeEp(testing.allocator, "host", common.DefaultPort, "pathname");
    defer ep.deinit();

    const cmd = try runner.command(transport.UploadPackServiceName, &ep, null);
    try cmd.start();

    // Independent encode of the same request for byte-level check.
    var expected_storage: [128]u8 = undefined;
    var ew: std.Io.Writer = .fixed(&expected_storage);
    var expected = packp.GitProtoRequest.init(testing.allocator);
    defer expected.deinit();
    expected.request_command = transport.UploadPackServiceName;
    expected.pathname = "pathname";
    expected.host = "host";
    try expected.encode(&ew);

    try testing.expectEqualStrings(ew.buffered(), buf.written());
    try cmd.close();
}

test "stdinPipe close does not close connection" {
    var runner = common.Runner.init(testing.allocator, testing.io);
    defer runner.deinit();
    var buf = common.BufferConn.init(testing.allocator);
    defer buf.deinit();
    runner.setDial(&buf, common.BufferConn.dialFn);

    var ep = try makeEp(testing.allocator, "localhost", common.DefaultPort, "/r");
    defer ep.deinit();

    const cmd = try runner.command("git-upload-pack", &ep, null);
    const stdin = try cmd.stdinPipe();
    try stdin.close();
    try testing.expect(!buf.closed);

    _ = try cmd.stdoutPipe();
    try testing.expectError(error.NoStderrChannel, cmd.stderrPipe());

    try cmd.close();
    try testing.expect(buf.closed);
}

test "defaultClient builds pack-protocol client over runner" {
    var runner = common.Runner.init(testing.allocator, testing.io);
    defer runner.deinit();
    var buf = common.BufferConn.init(testing.allocator);
    defer buf.deinit();
    runner.setDial(&buf, common.BufferConn.dialFn);

    var client = common.defaultClient(testing.allocator, &runner);
    var ep = try makeEp(testing.allocator, "localhost", common.DefaultPort, "/repo");
    defer ep.deinit();

    // Session starts command (encodes request). Empty mock stdout is fine.
    var sess = try client.newUploadPackSession(&ep, null);
    defer sess.close() catch {};

    // Start already encoded the proto request onto the buffer conn.
    try testing.expect(buf.written().len > 0);
    var r: std.Io.Reader = .fixed(buf.written());
    var req = packp.GitProtoRequest.init(testing.allocator);
    defer req.deinit();
    try req.decode(&r);
    try testing.expectEqualStrings("git-upload-pack", req.request_command);
    try testing.expectEqualStrings("/repo", req.pathname);
}

test "Command close is idempotent and drops connection" {
    var runner = common.Runner.init(testing.allocator, testing.io);
    defer runner.deinit();
    var buf = common.BufferConn.init(testing.allocator);
    defer buf.deinit();
    runner.setDial(&buf, common.BufferConn.dialFn);

    var ep = try makeEp(testing.allocator, "localhost", common.DefaultPort, "/r");
    defer ep.deinit();

    const cmd = try runner.command("git-upload-pack", &ep, null);
    try cmd.close();
    try testing.expect(buf.closed);
    try cmd.close();
    try cmd.kill();
    try testing.expect(buf.closed);
}

test "Command Start after close fails NotConnected" {
    var runner = common.Runner.init(testing.allocator, testing.io);
    defer runner.deinit();
    var buf = common.BufferConn.init(testing.allocator);
    defer buf.deinit();
    runner.setDial(&buf, common.BufferConn.dialFn);

    var ep = try makeEp(testing.allocator, "localhost", common.DefaultPort, "/r");
    defer ep.deinit();

    const cmd = try runner.command("git-upload-pack", &ep, null);
    try cmd.close();
    try testing.expectError(error.NotConnected, cmd.start());
    try testing.expectError(error.NotConnected, cmd.stdoutPipe());
}

test "dial failure is not retained on Runner" {
    const fail_dial = struct {
        fn dial(
            _: ?*anyopaque,
            _: Allocator,
            _: std.Io,
            _: []const u8,
            _: u16,
        ) anyerror!common.Conn {
            return error.ConnectionRefused;
        }
    }.dial;

    var runner = common.Runner.init(testing.allocator, testing.io);
    defer runner.deinit();
    runner.setDial(null, fail_dial);

    var ep = try makeEp(testing.allocator, "localhost", common.DefaultPort, "/r");
    defer ep.deinit();

    try testing.expectError(error.ConnectionRefused, runner.command("git-upload-pack", &ep, null));
    try testing.expectEqual(@as(usize, 0), runner.owned.items.len);
}

test "Command Start encodes GitProtoRequest for IPv6 host non-default port" {
    var runner = common.Runner.init(testing.allocator, testing.io);
    defer runner.deinit();
    var buf = common.BufferConn.init(testing.allocator);
    defer buf.deinit();
    runner.setDial(&buf, common.BufferConn.dialFn);

    var ep = try makeEp(testing.allocator, "[::1]", 1234, "/ipv6.git");
    defer ep.deinit();

    const cmd = try runner.command("git-upload-pack", &ep, null);
    try testing.expectEqualStrings("[::1]", buf.dial_host);
    try testing.expectEqual(@as(u16, 1234), buf.dial_port);

    try cmd.start();

    var r: std.Io.Reader = .fixed(buf.written());
    var req = packp.GitProtoRequest.init(testing.allocator);
    defer req.deinit();
    try req.decode(&r);
    try testing.expectEqualStrings("git-upload-pack", req.request_command);
    try testing.expectEqualStrings("/ipv6.git", req.pathname);
    try testing.expectEqualStrings("[::1]:1234", req.host);

    try cmd.close();
}

test "session over BufferConn decodes empty stdout as empty-class error" {
    // Hermetic stand-in for upload-pack suite: Start encodes, advertise is empty.
    var runner = common.Runner.init(testing.allocator, testing.io);
    defer runner.deinit();
    var buf = common.BufferConn.init(testing.allocator);
    defer buf.deinit();
    // Empty read_data → EmptyInput on advertise decode.
    buf.read_data = "";
    runner.setDial(&buf, common.BufferConn.dialFn);

    var client = common.defaultClient(testing.allocator, &runner);
    var ep = try makeEp(testing.allocator, "localhost", common.DefaultPort, "/empty");
    defer ep.deinit();

    var sess = try client.newUploadPackSession(&ep, null);
    defer sess.close() catch {};

    // Empty stream without stderr → UnexpectedEndOfStream (not soft multi-error).
    try testing.expectError(error.UnexpectedEndOfStream, sess.advertisedReferences());
    try testing.expect(buf.written().len > 0);
}
