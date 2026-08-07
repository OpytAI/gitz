//! Frame: sorted siblings for trie iteration (go-git `internal/frame`).

const std = @import("std");
const noder = @import("noder");

const Allocator = std.mem.Allocator;
const Noder = noder.Noder;

/// Collection of siblings sorted reverse-alphabetically by name so that
/// `first` peeks the alphabetically smallest (go-git `Frame`).
pub const Frame = struct {
    /// Siblings in reverse alphabetical order by name (stack top = first).
    stack: std.ArrayList(Noder) = .empty,
    allocator: Allocator,

    /// New frame with children of `n`, sorted reverse by name (go-git `New`).
    pub fn init(allocator: Allocator, n: Noder) anyerror!Frame {
        const children = try n.children(allocator);
        // `no_children` is a static empty slice — only free heap results.
        defer if (children.len > 0) allocator.free(children);

        // Sort ascending, then reverse into stack (same as go-git sort.Reverse).
        if (children.len > 0) {
            std.mem.sort(Noder, children, {}, struct {
                fn less(_: void, a: Noder, b: Noder) bool {
                    return std.mem.order(u8, a.name(), b.name()) == .lt;
                }
            }.less);
            // Reverse in place so stack[len-1] is alphabetically first.
            std.mem.reverse(Noder, children);
        }

        var stack: std.ArrayList(Noder) = .empty;
        errdefer stack.deinit(allocator);
        try stack.appendSlice(allocator, children);

        return .{
            .stack = stack,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Frame) void {
        self.stack.deinit(self.allocator);
        self.* = undefined;
    }

    /// Quoted names in alphabetical order: `[]` or `["a", "b"]` (go-git `String`).
    /// Caller frees.
    pub fn string(self: *const Frame, allocator: Allocator) Allocator.Error![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        try list.append(allocator, '[');
        var i = self.stack.items.len;
        var is_first = true;
        while (i > 0) {
            i -= 1;
            if (!is_first) try list.appendSlice(allocator, ", ");
            is_first = false;
            try list.append(allocator, '"');
            try list.appendSlice(allocator, self.stack.items[i].name());
            try list.append(allocator, '"');
        }
        try list.append(allocator, ']');
        return try list.toOwnedSlice(allocator);
    }

    /// Peek the alphabetically smallest noder (go-git `First`).
    pub fn first(self: *const Frame) ?Noder {
        if (self.stack.items.len == 0) return null;
        return self.stack.items[self.stack.items.len - 1];
    }

    /// Drop the alphabetically smallest noder (go-git `Drop`).
    pub fn drop(self: *Frame) void {
        if (self.stack.items.len == 0) return;
        _ = self.stack.pop();
    }

    /// Number of noders (go-git `Len`).
    pub fn len(self: *const Frame) usize {
        return self.stack.items.len;
    }
};

// ---------------------------------------------------------------------------
// Tests (go-git frame_test.go) — use fsnoder
// ---------------------------------------------------------------------------

const fsnoder = @import("fsnoder");

test "Frame empty dir" {
    const a = std.testing.allocator;
    var root = try fsnoder.New(a, "A()");
    defer root.deinit(a);

    var frame = try Frame.init(a, root.noder());
    defer frame.deinit();

    const s = try frame.string(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("[]", s);
    try std.testing.expect(frame.first() == null);
    try std.testing.expectEqual(@as(usize, 0), frame.len());
}

test "Frame non-empty sorted" {
    const a = std.testing.allocator;
    // A(x<> y<> B() C(z<>)) → children B, C, x, y
    var root = try fsnoder.New(a, "A(x<> y<> B() C(z<>))");
    defer root.deinit(a);

    var frame = try Frame.init(a, root.noder());
    defer frame.deinit();

    const s = try frame.string(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("[\"B\", \"C\", \"x\", \"y\"]", s);
    try std.testing.expectEqual(@as(usize, 4), frame.len());

    try expectFirstAndDrop(&frame, "B");
    try expectFirstAndDrop(&frame, "C");
    try expectFirstAndDrop(&frame, "x");
    try expectFirstAndDrop(&frame, "y");
    try std.testing.expect(frame.first() == null);
    try std.testing.expectEqual(@as(usize, 0), frame.len());
}

fn expectFirstAndDrop(frame: *Frame, expected: []const u8) !void {
    const f = frame.first() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(expected, f.name());
    frame.drop();
}

test "Frame children error" {
    const a = std.testing.allocator;
    var err_n = ErrorNoder{};
    const n = noder.noderOf(ErrorNoder, &err_n);
    try std.testing.expectError(error.MockError, Frame.init(a, n));
}

const ErrorNoder = struct {
    pub fn hash(_: *ErrorNoder) []const u8 {
        return &.{};
    }
    pub fn name(_: *ErrorNoder) []const u8 {
        return "";
    }
    pub fn isDir(_: *ErrorNoder) bool {
        return true;
    }
    pub fn children(_: *ErrorNoder, _: Allocator) anyerror![]Noder {
        return error.MockError;
    }
    pub fn numChildren(_: *ErrorNoder) anyerror!usize {
        return error.MockError;
    }
    pub fn skip(_: *ErrorNoder) bool {
        return false;
    }
    pub fn string(_: *ErrorNoder, allocator: Allocator) anyerror![]u8 {
        return try allocator.dupe(u8, "");
    }
};
