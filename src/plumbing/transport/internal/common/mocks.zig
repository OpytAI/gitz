//! Test doubles for Commander / Command
//! (go-git `plumbing/transport/internal/common/mocks.go`).

const std = @import("std");
const transport = @import("transport");
const common = @import("common.zig");

const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Endpoint = transport.Endpoint;
const Command = common.Command;
const Commander = common.Commander;
const WriteCloser = common.WriteCloser;

/// In-memory command with stdin/stdout/stderr buffers (go-git `MockCommand`).
pub const MockCommand = struct {
    allocator: Allocator,
    stdin_buf: std.ArrayList(u8) = .empty,
    stdout_buf: std.ArrayList(u8) = .empty,
    stderr_data: []const u8 = "",
    stderr_owned: ?[]u8 = null,

    stdin_writer: Writer.Allocating = undefined,
    stdout_reader: Reader = undefined,
    stderr_reader: Reader = undefined,
    stdin_closed: bool = false,
    stdin_writer_live: bool = false,
    started: bool = false,

    pub fn init(allocator: Allocator) MockCommand {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MockCommand) void {
        if (self.stdin_writer_live and !self.stdin_closed) {
            self.stdin_writer.deinit();
            self.stdin_closed = true;
            self.stdin_writer_live = false;
        } else if (self.stdin_writer_live and self.stdin_closed) {
            // already moved into stdin_buf in closeFn
            self.stdin_writer_live = false;
        }
        self.stdin_buf.deinit(self.allocator);
        self.stdout_buf.deinit(self.allocator);
        if (self.stderr_owned) |o| self.allocator.free(o);
        self.* = undefined;
    }

    /// Preload stdout bytes the client will read (e.g. empty adv-refs / errors).
    pub fn setStdout(self: *MockCommand, data: []const u8) !void {
        self.stdout_buf.clearRetainingCapacity();
        try self.stdout_buf.appendSlice(self.allocator, data);
        self.stdout_reader = Reader.fixed(self.stdout_buf.items);
    }

    /// Preload stderr text (go-git MockCommander.stderr).
    pub fn setStderr(self: *MockCommand, data: []const u8) !void {
        if (self.stderr_owned) |o| self.allocator.free(o);
        self.stderr_owned = try self.allocator.dupe(u8, data);
        self.stderr_data = self.stderr_owned.?;
        self.stderr_reader = Reader.fixed(self.stderr_data);
    }

    pub fn stderrPipe(self: *MockCommand) anyerror!*Reader {
        if (self.stderr_data.len == 0 and self.stderr_owned == null) {
            // Empty fixed reader.
            self.stderr_reader = Reader.fixed(&.{});
        }
        return &self.stderr_reader;
    }

    pub fn stdinPipe(self: *MockCommand) anyerror!WriteCloser {
        self.stdin_writer = Writer.Allocating.init(self.allocator);
        self.stdin_writer_live = true;
        const gen = struct {
            fn closeFn(ptr: *anyopaque) anyerror!void {
                const s: *MockCommand = @ptrCast(@alignCast(ptr));
                if (s.stdin_closed) return;
                // Move written bytes into stdin_buf for inspection.
                const written = s.stdin_writer.written();
                try s.stdin_buf.appendSlice(s.allocator, written);
                s.stdin_writer.deinit();
                s.stdin_closed = true;
                s.stdin_writer_live = false;
            }
        };
        return .{
            .ptr = self,
            .writer = &self.stdin_writer.writer,
            .close_fn = gen.closeFn,
        };
    }

    pub fn stdoutPipe(self: *MockCommand) anyerror!*Reader {
        if (self.stdout_buf.items.len == 0) {
            self.stdout_reader = Reader.fixed(&.{});
        } else {
            self.stdout_reader = Reader.fixed(self.stdout_buf.items);
        }
        return &self.stdout_reader;
    }

    pub fn start(self: *MockCommand) anyerror!void {
        self.started = true;
    }

    pub fn close(self: *MockCommand) anyerror!void {
        _ = self;
        // no-op for mock
    }

    /// go-git CommandKiller — same as close for in-memory mock.
    pub fn kill(self: *MockCommand) anyerror!void {
        return self.close();
    }

    pub fn asCommand(self: *MockCommand) Command {
        return Command.from(MockCommand, self);
    }
};

/// Commander that always returns a MockCommand with fixed stderr/stdout
/// (go-git `MockCommander`).
pub const MockCommander = struct {
    allocator: Allocator,
    stderr: []const u8 = "",
    /// Preloaded stdout for the created command (e.g. encoded AdvRefs pkt-lines).
    /// Empty (default) → EmptyInput path on advertise decode.
    stdout: []const u8 = "",
    /// Last command created (test inspection); not owned beyond commander lifetime.
    last: ?*MockCommand = null,
    /// Owned commands for deinit.
    owned: std.ArrayListUnmanaged(*MockCommand) = .empty,

    pub fn init(allocator: Allocator) MockCommander {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MockCommander) void {
        for (self.owned.items) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
        self.owned.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn asCommander(self: *MockCommander) Commander {
        return Commander.from(MockCommander, self);
    }

    pub fn command(
        self: *MockCommander,
        cmd: []const u8,
        ep: *const Endpoint,
        auth: ?transport.AuthMethod,
    ) anyerror!Command {
        _ = cmd;
        _ = ep;
        _ = auth;
        const mc = try self.allocator.create(MockCommand);
        errdefer self.allocator.destroy(mc);
        mc.* = MockCommand.init(self.allocator);
        if (self.stderr.len > 0) {
            try mc.setStderr(self.stderr);
        }
        try mc.setStdout(self.stdout);
        try self.owned.append(self.allocator, mc);
        self.last = mc;
        return mc.asCommand();
    }
};
