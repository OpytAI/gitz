//! Minimal pure-Zig regular expression engine for Worktree.Grep.
//!
//! Covers go-git `regexp.MatchString` usage in Grep tests without C/RE2
//! (wasm-safe). Unanchored match (Go `MatchString` semantics).
//!
//! Supported: literals, escapes, `(?i)`/`(?m)` leading flags, `.`, `*`/`+`/`?`
//! (greedy with backtracking), `^`/`$`, `[…]`/`[^…]`, `|`, `(…)`.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidRegex,
    OutOfMemory,
};

pub const Flags = struct {
    case_insensitive: bool = false,
    multiline: bool = false,
};

pub const Regex = struct {
    allocator: Allocator,
    flags: Flags,
    root: *Node,

    pub fn deinit(self: *Regex) void {
        freeNode(self.allocator, self.root);
        self.* = undefined;
    }

    /// Go `Regexp.MatchString`.
    pub fn matchString(self: *const Regex, text: []const u8) bool {
        var i: usize = 0;
        while (i <= text.len) : (i += 1) {
            if (matchHere(self.root, text, i, self.flags) != null) return true;
        }
        return false;
    }
};

pub fn compile(allocator: Allocator, pattern: []const u8) Error!Regex {
    var flags: Flags = .{};
    var body = pattern;
    if (std.mem.startsWith(u8, body, "(?")) {
        var j: usize = 2;
        while (j < body.len and body[j] != ')') : (j += 1) {
            switch (body[j]) {
                'i' => flags.case_insensitive = true,
                'm' => flags.multiline = true,
                else => return Error.InvalidRegex,
            }
        }
        if (j >= body.len or body[j] != ')') return Error.InvalidRegex;
        body = body[j + 1 ..];
    }
    var p: Parser = .{ .s = body, .i = 0, .allocator = allocator };
    const root = try p.parseAlt();
    errdefer freeNode(allocator, root);
    if (p.i != p.s.len) return Error.InvalidRegex;
    return .{ .allocator = allocator, .flags = flags, .root = root };
}

pub fn matchString(allocator: Allocator, pattern: []const u8, text: []const u8) Error!bool {
    var re = try compile(allocator, pattern);
    defer re.deinit();
    return re.matchString(text);
}

// ---------------------------------------------------------------------------
// AST
// ---------------------------------------------------------------------------

const NodeKind = enum {
    lit,
    any,
    class,
    concat,
    alt,
    star,
    plus,
    opt,
    anchor_start,
    anchor_end,
};

const Node = struct {
    kind: NodeKind,
    bytes: []u8 = &.{},
    negated: bool = false,
    kids: []const *Node = &.{},
};

fn freeNode(allocator: Allocator, n: *Node) void {
    for (n.kids) |k| freeNode(allocator, k);
    if (n.kids.len > 0) allocator.free(@constCast(n.kids));
    if (n.bytes.len > 0) allocator.free(n.bytes);
    allocator.destroy(n);
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

const Parser = struct {
    s: []const u8,
    i: usize,
    allocator: Allocator,

    fn peek(self: *const Parser) ?u8 {
        if (self.i >= self.s.len) return null;
        return self.s[self.i];
    }
    fn bump(self: *Parser) ?u8 {
        const c = self.peek() orelse return null;
        self.i += 1;
        return c;
    }

    fn parseAlt(self: *Parser) Error!*Node {
        var parts: std.ArrayList(*Node) = .empty;
        errdefer {
            for (parts.items) |n| freeNode(self.allocator, n);
            parts.deinit(self.allocator);
        }
        try parts.append(self.allocator, try self.parseConcat());
        while (self.peek() == '|') {
            _ = self.bump();
            try parts.append(self.allocator, try self.parseConcat());
        }
        if (parts.items.len == 1) {
            const only = parts.items[0];
            parts.deinit(self.allocator);
            return only;
        }
        const node = try self.allocator.create(Node);
        errdefer self.allocator.destroy(node);
        node.* = .{ .kind = .alt, .kids = try parts.toOwnedSlice(self.allocator) };
        return node;
    }

    fn parseConcat(self: *Parser) Error!*Node {
        var parts: std.ArrayList(*Node) = .empty;
        errdefer {
            for (parts.items) |n| freeNode(self.allocator, n);
            parts.deinit(self.allocator);
        }
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            try parts.append(self.allocator, try self.parseQuant());
        }
        if (parts.items.len == 0) {
            const node = try self.allocator.create(Node);
            node.* = .{ .kind = .concat, .kids = &.{} };
            return node;
        }
        if (parts.items.len == 1) {
            const only = parts.items[0];
            parts.deinit(self.allocator);
            return only;
        }
        const node = try self.allocator.create(Node);
        errdefer self.allocator.destroy(node);
        node.* = .{ .kind = .concat, .kids = try parts.toOwnedSlice(self.allocator) };
        return node;
    }

    fn parseQuant(self: *Parser) Error!*Node {
        const atom = try self.parseAtom();
        errdefer freeNode(self.allocator, atom);
        const q = self.peek() orelse return atom;
        const kind: NodeKind = switch (q) {
            '*' => .star,
            '+' => .plus,
            '?' => .opt,
            else => return atom,
        };
        _ = self.bump();
        const node = try self.allocator.create(Node);
        errdefer self.allocator.destroy(node);
        const kids = try self.allocator.alloc(*Node, 1);
        kids[0] = atom;
        node.* = .{ .kind = kind, .kids = kids };
        return node;
    }

    fn parseAtom(self: *Parser) Error!*Node {
        const c = self.bump() orelse return Error.InvalidRegex;
        switch (c) {
            '.' => {
                const node = try self.allocator.create(Node);
                node.* = .{ .kind = .any };
                return node;
            },
            '^' => {
                const node = try self.allocator.create(Node);
                node.* = .{ .kind = .anchor_start };
                return node;
            },
            '$' => {
                const node = try self.allocator.create(Node);
                node.* = .{ .kind = .anchor_end };
                return node;
            },
            '(' => {
                const inner = try self.parseAlt();
                if (self.bump() != ')') {
                    freeNode(self.allocator, inner);
                    return Error.InvalidRegex;
                }
                return inner;
            },
            '[' => return try self.parseClass(),
            '\\' => {
                const e = self.bump() orelse return Error.InvalidRegex;
                return try self.litNode(&[_]u8{escapeByte(e)});
            },
            '*', '+', '?', ')', '|' => return Error.InvalidRegex,
            else => {
                const start = self.i - 1;
                while (self.peek()) |n| {
                    if (isMeta(n)) break;
                    _ = self.bump();
                }
                return try self.litNode(self.s[start..self.i]);
            },
        }
    }

    fn litNode(self: *Parser, bytes: []const u8) Error!*Node {
        const node = try self.allocator.create(Node);
        errdefer self.allocator.destroy(node);
        node.* = .{ .kind = .lit, .bytes = try self.allocator.dupe(u8, bytes) };
        return node;
    }

    fn parseClass(self: *Parser) Error!*Node {
        var negated = false;
        if (self.peek() == '^') {
            _ = self.bump();
            negated = true;
        }
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        if (self.peek() == ']') try buf.append(self.allocator, self.bump().?);
        while (self.peek()) |c| {
            if (c == ']') {
                _ = self.bump();
                const node = try self.allocator.create(Node);
                errdefer self.allocator.destroy(node);
                node.* = .{
                    .kind = .class,
                    .bytes = try buf.toOwnedSlice(self.allocator),
                    .negated = negated,
                };
                return node;
            }
            if (c == '\\') {
                _ = self.bump();
                const e = self.bump() orelse return Error.InvalidRegex;
                try buf.append(self.allocator, escapeByte(e));
                continue;
            }
            if (self.i + 2 < self.s.len and self.s[self.i + 1] == '-' and self.s[self.i + 2] != ']') {
                const lo = self.bump().?;
                _ = self.bump();
                const hi = self.bump().?;
                var b: u16 = lo;
                while (b <= hi) : (b += 1) {
                    try buf.append(self.allocator, @intCast(b));
                }
                continue;
            }
            try buf.append(self.allocator, self.bump().?);
        }
        return Error.InvalidRegex;
    }
};

fn isMeta(c: u8) bool {
    return switch (c) {
        '.', '*', '+', '?', '(', ')', '[', ']', '|', '^', '$', '\\' => true,
        else => false,
    };
}

fn escapeByte(e: u8) u8 {
    return switch (e) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        else => e,
    };
}

// ---------------------------------------------------------------------------
// Matcher with greedy backtracking
// ---------------------------------------------------------------------------

/// Match `n` at `pos`; return end index or null.
fn matchHere(n: *const Node, text: []const u8, pos: usize, flags: Flags) ?usize {
    return switch (n.kind) {
        .lit => matchLit(n.bytes, text, pos, flags),
        .any => if (pos < text.len and text[pos] != '\n') pos + 1 else null,
        .class => matchClass(n, text, pos, flags),
        .concat => matchConcat(n.kids, 0, text, pos, flags),
        .alt => blk: {
            for (n.kids) |k| {
                if (matchHere(k, text, pos, flags)) |end| break :blk end;
            }
            break :blk null;
        },
        .star => matchRepeat(n.kids[0], text, pos, flags, 0, null),
        .plus => matchRepeat(n.kids[0], text, pos, flags, 1, null),
        .opt => matchRepeat(n.kids[0], text, pos, flags, 0, 1),
        .anchor_start => blk: {
            if (pos == 0) break :blk pos;
            if (flags.multiline and pos > 0 and text[pos - 1] == '\n') break :blk pos;
            break :blk null;
        },
        .anchor_end => blk: {
            if (pos == text.len) break :blk pos;
            if (flags.multiline and pos < text.len and text[pos] == '\n') break :blk pos;
            break :blk null;
        },
    };
}

fn matchLit(bytes: []const u8, text: []const u8, pos: usize, flags: Flags) ?usize {
    if (pos + bytes.len > text.len) return null;
    if (flags.case_insensitive) {
        for (bytes, 0..) |b, i| {
            if (std.ascii.toLower(b) != std.ascii.toLower(text[pos + i])) return null;
        }
    } else if (!std.mem.eql(u8, text[pos .. pos + bytes.len], bytes)) {
        return null;
    }
    return pos + bytes.len;
}

fn matchClass(n: *const Node, text: []const u8, pos: usize, flags: Flags) ?usize {
    if (pos >= text.len) return null;
    const c = text[pos];
    var found = false;
    for (n.bytes) |b| {
        const eq = if (flags.case_insensitive)
            std.ascii.toLower(b) == std.ascii.toLower(c)
        else
            b == c;
        if (eq) {
            found = true;
            break;
        }
    }
    if (found == n.negated) return null;
    return pos + 1;
}

fn matchConcat(kids: []const *Node, ki: usize, text: []const u8, pos: usize, flags: Flags) ?usize {
    if (ki >= kids.len) return pos;
    const k = kids[ki];
    switch (k.kind) {
        .star => return matchRepeatThen(k.kids[0], text, pos, flags, 0, null, kids, ki + 1),
        .plus => return matchRepeatThen(k.kids[0], text, pos, flags, 1, null, kids, ki + 1),
        .opt => return matchRepeatThen(k.kids[0], text, pos, flags, 0, 1, kids, ki + 1),
        else => {
            const after = matchHere(k, text, pos, flags) orelse return null;
            return matchConcat(kids, ki + 1, text, after, flags);
        },
    }
}

/// Greedy quantifier then continue concat at `rest_ki`.
fn matchRepeatThen(
    inner: *const Node,
    text: []const u8,
    pos: usize,
    flags: Flags,
    min: usize,
    max: ?usize,
    rest: []const *Node,
    rest_ki: usize,
) ?usize {
    var ends: [128]usize = undefined;
    ends[0] = pos;
    var n: usize = 1;
    var p = pos;
    const limit = max orelse ends.len - 1;
    while (n <= limit and n < ends.len) {
        const next = matchHere(inner, text, p, flags) orelse break;
        if (next == p) break;
        ends[n] = next;
        n += 1;
        p = next;
    }
    // Greedy: try longest first.
    var i = n;
    while (i > 0) {
        i -= 1;
        if (i < min) break;
        if (matchConcat(rest, rest_ki, text, ends[i], flags)) |end| return end;
    }
    return null;
}

/// Quantifier as whole pattern (no following concat).
fn matchRepeat(inner: *const Node, text: []const u8, pos: usize, flags: Flags, min: usize, max: ?usize) ?usize {
    var ends: [128]usize = undefined;
    ends[0] = pos;
    var n: usize = 1;
    var p = pos;
    const limit = max orelse ends.len - 1;
    while (n <= limit and n < ends.len) {
        const next = matchHere(inner, text, p, flags) orelse break;
        if (next == p) break;
        ends[n] = next;
        n += 1;
        p = next;
    }
    if (n - 1 < min) return null;
    // Greedy: longest.
    return ends[n - 1];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "literal and unanchored" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try matchString(gpa, "import", "package\nimport \"fmt\"\n"));
    try std.testing.expect(!try matchString(gpa, "import", "package main"));
}

test "case insensitive flag" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try matchString(gpa, "(?i)IMport", "import \"os\""));
    try std.testing.expect(try matchString(gpa, "(?i)IMport", "IMPORT"));
    try std.testing.expect(!try matchString(gpa, "IMport", "import"));
}

test "dot star pathspec" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try matchString(gpa, "go/", "vendor/go/foo"));
    try std.testing.expect(try matchString(gpa, ".*\\.go", "src/main.go"));
    try std.testing.expect(!try matchString(gpa, ".*\\.go", "src/main.c"));
}

test "greedy backtrack" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try matchString(gpa, "a*ab", "aaab"));
    try std.testing.expect(try matchString(gpa, ".*x", "abcx"));
}

test "anchors quantifiers class alt" {
    const gpa = std.testing.allocator;
    try std.testing.expect(try matchString(gpa, "^import", "import x"));
    try std.testing.expect(!try matchString(gpa, "^import", "x import"));
    try std.testing.expect(try matchString(gpa, "colou?r", "color"));
    try std.testing.expect(try matchString(gpa, "[Ii]mport", "Import"));
    try std.testing.expect(try matchString(gpa, "foo|bar", "xxbar"));
}

test "invalid" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(Error.InvalidRegex, matchString(gpa, "[abc", "a"));
    try std.testing.expectError(Error.InvalidRegex, matchString(gpa, "*", "a"));
}
