//! Optional debug tracing (port of go-git `utils/trace`).
//!
//! Thin bitflag targets with enable / printf-style helpers. Disabled by default.
//! Single-threaded; no mutex (phase-1 sequential port).

const std = @import("std");

/// Tracing target bitmask (go-git `trace.Target`).
pub const Target = i32;

/// General operations (go-git `trace.General`).
pub const general: Target = 1 << 0;

/// Git packet traffic (go-git `trace.Packet`).
pub const packet: Target = 1 << 1;

/// Performance of components (inventory `trace.performance`).
pub const performance: Target = 1 << 2;

/// Log sink: receives one message without trailing newline.
pub const LogFn = *const fn (msg: []const u8) void;

var current: std.atomic.Value(i32) = .init(0);
var log_fn: ?LogFn = null;

fn defaultLog(msg: []const u8) void {
    std.debug.print("{s}\n", .{msg});
}

/// Set the enabled tracing targets (bitmask). Pass `0` to disable all.
pub fn setTarget(target: Target) void {
    current.store(target, .release);
}

/// Return the currently enabled tracing targets.
pub fn getTarget() Target {
    return current.load(.acquire);
}

/// Replace the log sink. Pass `null` to restore the default (stderr via debug print).
pub fn setLogger(f: ?LogFn) void {
    log_fn = f;
}

/// Return true when any bit of `t` is currently enabled.
pub fn enabled(t: Target) bool {
    return (t & current.load(.acquire)) != 0;
}

fn emit(msg: []const u8) void {
    const f = log_fn orelse defaultLog;
    f(msg);
}

/// Print when `t` is enabled (go-git `Target.Print` / `Target.Printf` style).
pub fn print(t: Target, comptime fmt: []const u8, args: anytype) void {
    if (!enabled(t)) return;
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    emit(msg);
}

/// Alias of `print` (go-git `Target.Printf`).
pub fn printf(t: Target, comptime fmt: []const u8, args: anytype) void {
    print(t, fmt, args);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Capture = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    fn reset(self: *Capture) void {
        self.len = 0;
    }

    fn appendMsg(self: *Capture, msg: []const u8) void {
        const need = msg.len + 1;
        if (self.len + need > self.buf.len) return;
        @memcpy(self.buf[self.len..][0..msg.len], msg);
        self.len += msg.len;
        self.buf[self.len] = '\n';
        self.len += 1;
    }

    fn slice(self: *const Capture) []const u8 {
        return self.buf[0..self.len];
    }
};

var test_capture: Capture = .{};

fn testLog(msg: []const u8) void {
    test_capture.appendMsg(msg);
}

fn setUpTest(capturing: bool) void {
    test_capture.reset();
    setTarget(0);
    if (capturing) {
        setLogger(testLog);
    } else {
        setLogger(struct {
            fn discard(_: []const u8) void {}
        }.discard);
    }
}

fn tearDownTest() void {
    setTarget(0);
    setLogger(null);
    test_capture.reset();
}

test "empty: disabled target prints nothing" {
    setUpTest(true);
    defer tearDownTest();
    print(general, "test", .{});
    try std.testing.expectEqualStrings("", test_capture.slice());
}

test "one target" {
    setUpTest(true);
    defer tearDownTest();
    setTarget(general);
    print(general, "test", .{});
    try std.testing.expectEqualStrings("test\n", test_capture.slice());
}

test "multiple targets" {
    setUpTest(true);
    defer tearDownTest();
    setTarget(general | packet);
    print(general, "a", .{});
    print(packet, "b", .{});
    try std.testing.expectEqualStrings("a\nb\n", test_capture.slice());
}

test "printf" {
    setUpTest(true);
    defer tearDownTest();
    setTarget(general);
    printf(general, "a {d}", .{1});
    try std.testing.expectEqualStrings("a 1\n", test_capture.slice());
}

test "disabled among multiple targets" {
    setUpTest(true);
    defer tearDownTest();
    setTarget(general);
    print(general, "a", .{});
    print(packet, "b", .{});
    try std.testing.expectEqualStrings("a\n", test_capture.slice());
}

test "enabled and performance flag" {
    setUpTest(true);
    defer tearDownTest();
    try std.testing.expect(!enabled(performance));
    setTarget(performance);
    try std.testing.expect(enabled(performance));
    try std.testing.expect(!enabled(general));
    printf(performance, "t={d}", .{42});
    try std.testing.expectEqualStrings("t=42\n", test_capture.slice());
    try std.testing.expectEqual(@as(Target, performance), getTarget());
}

test "setLogger null restores default path without panic" {
    setUpTest(false);
    defer tearDownTest();
    setLogger(null);
    setTarget(0);
    print(general, "quiet", .{});
}
