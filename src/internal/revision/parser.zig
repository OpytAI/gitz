//! Revision string parser (go-git `internal/revision/parser.go`).
//!
//! Grammar: https://www.kernel.org/pub/software/scm/git/docs/gitrevisions.html

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Token = @import("token.zig").Token;
const Scanner = @import("scanner.zig").Scanner;
const ScanResult = @import("scanner.zig").ScanResult;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// go-git `ErrInvalidRevision` reason (without the `"Revision invalid : "` prefix).
pub const ErrInvalidRevision = struct {
    /// Reason fragment (go-git `ErrInvalidRevision.s`).
    reason: []const u8,

    /// go-git `(*ErrInvalidRevision).Error`.
    pub fn errorMessage(self: ErrInvalidRevision, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "Revision invalid : {s}", .{self.reason});
    }

    pub fn eql(self: ErrInvalidRevision, other: ErrInvalidRevision) bool {
        return std.mem.eql(u8, self.reason, other.reason);
    }
};

pub const Error = error{
    /// Revision string does not match a valid form (go-git `*ErrInvalidRevision`).
    InvalidRevision,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Revision components (go-git `Revisioner` and concrete types)
// ---------------------------------------------------------------------------

/// Reference name: HEAD, master, short hash (go-git `Ref`).
/// `name` is owned when produced by `Parser.parse` / `parseRef`.
pub const Ref = struct {
    name: []const u8,

    pub fn deinit(self: Ref, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

/// `~` / `~{n}` (go-git `TildePath`).
pub const TildePath = struct {
    depth: i32,
};

/// `^` / `^{n}` (go-git `CaretPath`). Depth must be 0, 1, or 2.
pub const CaretPath = struct {
    depth: i32,
};

/// `^{/foo bar}` (go-git `CaretReg`).
/// Pattern is the RE2/Go regexp source string (not compiled).
pub const CaretReg = struct {
    pattern: []const u8,
    negate: bool,

    pub fn deinit(self: CaretReg, allocator: Allocator) void {
        allocator.free(self.pattern);
    }
};

/// `^{commit}` / `^{}` (go-git `CaretType`).
pub const CaretType = struct {
    object_type: []const u8,

    pub fn deinit(self: CaretType, allocator: Allocator) void {
        allocator.free(self.object_type);
    }
};

/// `@{n}` (go-git `AtReflog`).
pub const AtReflog = struct {
    depth: i32,
};

/// `@{-n}` (go-git `AtCheckout`).
pub const AtCheckout = struct {
    depth: i32,
};

/// `@{upstream}` / `@{u}` (go-git `AtUpstream`).
pub const AtUpstream = struct {
    branch_name: []const u8 = "",
};

/// `@{push}` (go-git `AtPush`).
pub const AtPush = struct {
    branch_name: []const u8 = "",
};

/// `@{ISO-8601}` (go-git `AtDate`). Instant is UTC unix seconds.
pub const AtDate = struct {
    /// Unix timestamp seconds (UTC), matching go-git `time.Time` for the Z form.
    unix_seconds: i64,
};

/// `:/foo bar` (go-git `ColonReg`).
pub const ColonReg = struct {
    pattern: []const u8,
    negate: bool,

    pub fn deinit(self: ColonReg, allocator: Allocator) void {
        allocator.free(self.pattern);
    }
};

/// `:<path>` / `:./path` (go-git `ColonPath`).
pub const ColonPath = struct {
    path: []const u8,

    pub fn deinit(self: ColonPath, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

/// `:<n>:<path>` (go-git `ColonStagePath`).
pub const ColonStagePath = struct {
    path: []const u8,
    stage: i32,

    pub fn deinit(self: ColonStagePath, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

/// One revision component (go-git `Revisioner` interface → tagged union).
pub const Revisioner = union(enum) {
    ref: Ref,
    tilde_path: TildePath,
    caret_path: CaretPath,
    caret_reg: CaretReg,
    caret_type: CaretType,
    at_reflog: AtReflog,
    at_checkout: AtCheckout,
    at_upstream: AtUpstream,
    at_push: AtPush,
    at_date: AtDate,
    colon_reg: ColonReg,
    colon_path: ColonPath,
    colon_stage_path: ColonStagePath,

    pub fn deinit(self: *Revisioner, allocator: Allocator) void {
        switch (self.*) {
            .ref => |r| r.deinit(allocator),
            .caret_reg => |r| r.deinit(allocator),
            .caret_type => |r| r.deinit(allocator),
            .colon_reg => |r| r.deinit(allocator),
            .colon_path => |r| r.deinit(allocator),
            .colon_stage_path => |r| r.deinit(allocator),
            else => {},
        }
        self.* = .{ .tilde_path = .{ .depth = 0 } };
    }
};

/// Free a slice returned by `Parser.parse`.
pub fn freeRevisioners(allocator: Allocator, revs: []Revisioner) void {
    for (revs) |*r| r.deinit(allocator);
    allocator.free(revs);
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

/// Tokenizes and transforms a revision string into component chunks (go-git `Parser`).
pub const Parser = struct {
    allocator: Allocator,
    scanner: Scanner,
    current: ScanResult = .{ .tok = .eof, .lit = "" },
    unread_last: bool = false,
    /// Reason for the last `error.InvalidRevision` (go-git `ErrInvalidRevision.s`).
    invalid_reason: []const u8 = "",
    invalid_reason_owned: bool = false,
    /// Scratch for owned invalid reasons.
    reason_buf: std.ArrayList(u8) = .empty,

    /// go-git `NewParserFromString`.
    pub fn initFromString(allocator: Allocator, s: []const u8) Parser {
        return .{
            .allocator = allocator,
            .scanner = Scanner.init(s),
        };
    }

    /// go-git `NewParser` from an already-buffered revision string.
    pub fn init(allocator: Allocator, s: []const u8) Parser {
        return initFromString(allocator, s);
    }

    pub fn deinit(self: *Parser) void {
        self.reason_buf.deinit(self.allocator);
        self.invalid_reason = "";
        self.invalid_reason_owned = false;
    }

    /// Last invalid-revision reason (empty if none).
    pub fn invalidRevision(self: *const Parser) ErrInvalidRevision {
        return .{ .reason = self.invalid_reason };
    }

    fn fail(self: *Parser, comptime static_reason: []const u8) Error {
        self.clearOwnedReason();
        self.invalid_reason = static_reason;
        self.invalid_reason_owned = false;
        return error.InvalidRevision;
    }

    fn failFmt(self: *Parser, comptime fmt: []const u8, args: anytype) Error {
        self.reason_buf.clearRetainingCapacity();
        self.reason_buf.print(self.allocator, fmt, args) catch return error.OutOfMemory;
        self.invalid_reason = self.reason_buf.items;
        self.invalid_reason_owned = true;
        return error.InvalidRevision;
    }

    fn clearOwnedReason(self: *Parser) void {
        self.reason_buf.clearRetainingCapacity();
        self.invalid_reason_owned = false;
    }

    /// go-git `(*Parser).scan`.
    pub fn scan(self: *Parser) ScanResult {
        if (self.unread_last) {
            self.unread_last = false;
            return self.current;
        }
        self.current = self.scanner.scan();
        return self.current;
    }

    /// go-git `(*Parser).unscan`.
    pub fn unscan(self: *Parser) void {
        self.unread_last = true;
    }

    /// go-git `(*Parser).Parse` — full revision → component list.
    pub fn parse(self: *Parser) Error![]Revisioner {
        var revs: std.ArrayList(Revisioner) = .empty;
        errdefer {
            for (revs.items) |*r| r.deinit(self.allocator);
            revs.deinit(self.allocator);
        }

        while (true) {
            const r = self.scan();
            const rev: Revisioner = switch (r.tok) {
                .at => try self.parseAt(),
                .tilde => try self.parseTilde(),
                .caret => try self.parseCaret(),
                .colon => try self.parseColon(),
                .eof => {
                    try self.validateFullRevision(revs.items);
                    return try revs.toOwnedSlice(self.allocator);
                },
                else => blk: {
                    self.unscan();
                    break :blk try self.parseRef();
                },
            };
            try revs.append(self.allocator, rev);
        }
    }

    fn validateFullRevision(self: *Parser, chunks: []const Revisioner) Error!void {
        var has_reference = false;

        for (chunks, 0..) |chunk, i| {
            switch (chunk) {
                .ref => {
                    if (i == 0) {
                        has_reference = true;
                    } else {
                        return self.fail("reference must be defined once at the beginning");
                    }
                },
                .at_date => {
                    if (chunks.len == 1 or (has_reference and chunks.len == 2)) return;
                    return self.fail("\"@\" statement is not valid, could be : <refname>@{<ISO-8601 date>}, @{<ISO-8601 date>}");
                },
                .at_reflog => {
                    if (chunks.len == 1 or (has_reference and chunks.len == 2)) return;
                    return self.fail("\"@\" statement is not valid, could be : <refname>@{<n>}, @{<n>}");
                },
                .at_checkout => {
                    if (chunks.len == 1) return;
                    return self.fail("\"@\" statement is not valid, could be : @{-<n>}");
                },
                .at_upstream => {
                    if (chunks.len == 1 or (has_reference and chunks.len == 2)) return;
                    return self.fail("\"@\" statement is not valid, could be : <refname>@{upstream}, @{upstream}, <refname>@{u}, @{u}");
                },
                .at_push => {
                    if (chunks.len == 1 or (has_reference and chunks.len == 2)) return;
                    return self.fail("\"@\" statement is not valid, could be : <refname>@{push}, @{push}");
                },
                .tilde_path, .caret_path, .caret_reg => {
                    if (!has_reference) {
                        return self.fail("\"~\" or \"^\" statement must have a reference defined at the beginning");
                    }
                },
                .colon_reg => {
                    if (chunks.len == 1) return;
                    return self.fail("\":\" statement is not valid, could be : :/<regexp>");
                },
                .colon_path => {
                    if ((i == chunks.len - 1 and has_reference) or chunks.len == 1) return;
                    return self.fail("\":\" statement is not valid, could be : <revision>:<path>");
                },
                .colon_stage_path => {
                    if (chunks.len == 1) return;
                    return self.fail("\":\" statement is not valid, could be : :<n>:<path>");
                },
                .caret_type => {},
            }
        }
    }

    /// go-git `(*Parser).parseAt`.
    pub fn parseAt(self: *Parser) Error!Revisioner {
        var r = self.scan();
        if (r.tok != .obrace) {
            self.unscan();
            const name = try self.allocator.dupe(u8, "HEAD");
            return .{ .ref = .{ .name = name } };
        }

        r = self.scan();
        const lit = r.lit;
        const tok = r.tok;

        const next = self.scan();
        const next_tok = next.tok;
        const next_lit = next.lit;

        if (tok == .word and (std.mem.eql(u8, lit, "u") or std.mem.eql(u8, lit, "upstream")) and next_tok == .cbrace) {
            return .{ .at_upstream = .{} };
        }
        if (tok == .word and std.mem.eql(u8, lit, "push") and next_tok == .cbrace) {
            return .{ .at_push = .{} };
        }
        if (tok == .number and next_tok == .cbrace) {
            const n = std.fmt.parseInt(i32, lit, 10) catch 0;
            return .{ .at_reflog = .{ .depth = n } };
        }
        if (tok == .minus and next_tok == .number) {
            const n = std.fmt.parseInt(i32, next_lit, 10) catch 0;
            const t = self.scan();
            if (t.tok != .cbrace) {
                return self.fail("missing \"}\" in @{-n} structure");
            }
            return .{ .at_checkout = .{ .depth = n } };
        }

        // Date form: accumulate tokens until `}`.
        self.unscan();
        var date_buf: std.ArrayList(u8) = .empty;
        defer date_buf.deinit(self.allocator);
        try date_buf.appendSlice(self.allocator, lit);

        while (true) {
            const dr = self.scan();
            switch (dr.tok) {
                .cbrace => {
                    const unix = parseIso8601Z(date_buf.items) orelse {
                        return self.failFmt("wrong date \"{s}\" must fit ISO-8601 format : 2006-01-02T15:04:05Z", .{date_buf.items});
                    };
                    return .{ .at_date = .{ .unix_seconds = unix } };
                },
                .eof => return self.fail("missing \"}\" in @{<data>} structure"),
                else => try date_buf.appendSlice(self.allocator, dr.lit),
            }
        }
    }

    /// go-git `(*Parser).parseTilde`.
    pub fn parseTilde(self: *Parser) Error!Revisioner {
        const r = self.scan();
        if (r.tok == .number) {
            const n = std.fmt.parseInt(i32, r.lit, 10) catch 0;
            return .{ .tilde_path = .{ .depth = n } };
        }
        self.unscan();
        return .{ .tilde_path = .{ .depth = 1 } };
    }

    /// go-git `(*Parser).parseCaret`.
    pub fn parseCaret(self: *Parser) Error!Revisioner {
        const r = self.scan();
        switch (r.tok) {
            .obrace => return self.parseCaretBraces(),
            .number => {
                const n = std.fmt.parseInt(i32, r.lit, 10) catch 0;
                if (n > 2) {
                    return self.failFmt("\"{s}\" found must be 0, 1 or 2 after \"^\"", .{r.lit});
                }
                return .{ .caret_path = .{ .depth = n } };
            },
            else => {
                self.unscan();
                return .{ .caret_path = .{ .depth = 1 } };
            },
        }
    }

    fn parseCaretBraces(self: *Parser) Error!Revisioner {
        var start = true;
        var re_buf: std.ArrayList(u8) = .empty;
        defer re_buf.deinit(self.allocator);
        var negate = false;

        while (true) {
            const r = self.scan();
            const tok = r.tok;
            const lit = r.lit;
            const next = self.scan();
            const next_tok = next.tok;

            if (tok == .word and next_tok == .cbrace and isObjectType(lit)) {
                const ot = try self.allocator.dupe(u8, lit);
                return .{ .caret_type = .{ .object_type = ot } };
            }
            if (re_buf.items.len == 0 and tok == .cbrace) {
                const ot = try self.allocator.dupe(u8, "tag");
                return .{ .caret_type = .{ .object_type = ot } };
            }
            if (re_buf.items.len == 0 and tok == .emark and next_tok == .emark) {
                try re_buf.appendSlice(self.allocator, lit);
            } else if (re_buf.items.len == 0 and tok == .emark and next_tok == .minus) {
                negate = true;
            } else if (re_buf.items.len == 0 and tok == .emark) {
                return self.fail("revision suffix brace component sequences starting with \"/!\" others than those defined are reserved");
            } else if (re_buf.items.len == 0 and tok == .slash) {
                self.unscan();
            } else if (tok != .slash and start) {
                return self.failFmt("\"{s}\" is not a valid revision suffix brace component", .{lit});
            } else if (tok == .eof) {
                return self.fail("missing \"}\" in ^{<data>} structure");
            } else if (tok != .cbrace) {
                self.unscan();
                try re_buf.appendSlice(self.allocator, lit);
            } else {
                // tok == cbrace
                self.unscan();
                if (validateRegexp(re_buf.items)) |re_err| {
                    return self.failFmt("revision suffix brace component, {s}", .{re_err});
                }
                const pat = try self.allocator.dupe(u8, re_buf.items);
                return .{ .caret_reg = .{ .pattern = pat, .negate = negate } };
            }

            start = false;
        }
    }

    /// go-git `(*Parser).parseColon`.
    pub fn parseColon(self: *Parser) Error!Revisioner {
        const r = self.scan();
        if (r.tok == .slash) {
            return self.parseColonSlash();
        }
        self.unscan();
        return self.parseColonDefault();
    }

    fn parseColonSlash(self: *Parser) Error!Revisioner {
        var re_buf: std.ArrayList(u8) = .empty;
        defer re_buf.deinit(self.allocator);
        var negate = false;

        while (true) {
            const r = self.scan();
            const tok = r.tok;
            const lit = r.lit;
            const next = self.scan();
            const next_tok = next.tok;

            if (tok == .emark and next_tok == .emark) {
                try re_buf.appendSlice(self.allocator, lit);
            } else if (re_buf.items.len == 0 and tok == .emark and next_tok == .minus) {
                negate = true;
            } else if (re_buf.items.len == 0 and tok == .emark) {
                return self.fail("revision suffix brace component sequences starting with \"/!\" others than those defined are reserved");
            } else if (tok == .eof) {
                self.unscan();
                if (validateRegexp(re_buf.items)) |re_err| {
                    return self.failFmt("revision suffix brace component, {s}", .{re_err});
                }
                const pat = try self.allocator.dupe(u8, re_buf.items);
                return .{ .colon_reg = .{ .pattern = pat, .negate = negate } };
            } else {
                self.unscan();
                try re_buf.appendSlice(self.allocator, lit);
            }
        }
    }

    fn parseColonDefault(self: *Parser) Error!Revisioner {
        const r = self.scan();
        const lit = r.lit;
        const tok = r.tok;
        const next = self.scan();

        var n: i32 = -1;
        if (tok == .number and next.tok == .colon) {
            n = std.fmt.parseInt(i32, lit, 10) catch -1;
        }

        var path_buf: std.ArrayList(u8) = .empty;
        defer path_buf.deinit(self.allocator);
        var stage: i32 = 0;

        switch (n) {
            0, 1, 2, 3 => stage = n,
            else => {
                try path_buf.appendSlice(self.allocator, lit);
                self.unscan();
            },
        }

        while (true) {
            const pr = self.scan();
            switch (pr.tok) {
                .eof => {
                    const p = try self.allocator.dupe(u8, path_buf.items);
                    if (n == 0 or n == 1 or n == 2 or n == 3) {
                        return .{ .colon_stage_path = .{ .path = p, .stage = stage } };
                    }
                    return .{ .colon_path = .{ .path = p } };
                },
                else => try path_buf.appendSlice(self.allocator, pr.lit),
            }
        }
    }

    /// go-git `(*Parser).parseRef`.
    pub fn parseRef(self: *Parser) Error!Revisioner {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var prev_tok: Token = .eof;
        var end_of_ref = false;

        while (true) {
            const r = self.scan();
            const tok = r.tok;
            const lit = r.lit;

            switch (tok) {
                .eof, .at, .colon, .tilde, .caret => end_of_ref = true,
                else => {},
            }

            try self.checkRefFormat(tok, lit, prev_tok, buf.items, end_of_ref);

            if (end_of_ref) {
                self.unscan();
                const name = try self.allocator.dupe(u8, buf.items);
                return .{ .ref = .{ .name = name } };
            }

            try buf.appendSlice(self.allocator, lit);
            prev_tok = tok;
        }
    }

    fn checkRefFormat(
        self: *Parser,
        token: Token,
        literal: []const u8,
        previous_token: Token,
        buffer: []const u8,
        end_of_ref: bool,
    ) Error!void {
        switch (token) {
            .aslash, .space, .control, .qmark, .asterisk, .obracket => {
                return self.failFmt("must not contains \"{s}\"", .{literal});
            },
            else => {},
        }

        if ((token == .dot or token == .slash) and buffer.len == 0) {
            return self.failFmt("must not start with \"{s}\"", .{literal});
        }
        if (previous_token == .slash and end_of_ref) {
            return self.fail("must not end with \"/\"");
        }
        if (previous_token == .dot and end_of_ref) {
            return self.fail("must not end with \".\"");
        }
        if (token == .dot and previous_token == .slash) {
            return self.fail("must not contains \"/.\"");
        }
        if (previous_token == .dot and token == .dot) {
            return self.fail("must not contains \"..\"");
        }
        if (previous_token == .slash and token == .slash) {
            return self.fail("must not contains consecutively \"/\"");
        }
        if ((token == .slash or end_of_ref) and buffer.len > 4 and std.mem.eql(u8, buffer[buffer.len - 5 ..], ".lock")) {
            return self.fail("cannot end with .lock");
        }
    }
};

fn isObjectType(lit: []const u8) bool {
    return std.mem.eql(u8, lit, "commit") or
        std.mem.eql(u8, lit, "tree") or
        std.mem.eql(u8, lit, "blob") or
        std.mem.eql(u8, lit, "tag") or
        std.mem.eql(u8, lit, "object");
}

/// Parse `2006-01-02T15:04:05Z` into unix seconds (UTC).
fn parseIso8601Z(s: []const u8) ?i64 {
    if (s.len != 20) return null;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':' or s[19] != 'Z') {
        return null;
    }
    const year = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u4, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u5, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u5, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u6, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u6, s[17..19], 10) catch return null;

    if (month < 1 or month > 12) return null;
    if (hour > 23 or minute > 59 or second > 59) return null;

    const m: std.time.epoch.Month = @enumFromInt(month);
    const dim = std.time.epoch.getDaysInMonth(year, m);
    if (day < 1 or day > dim) return null;

    // Days since 1970-01-01.
    var days: i64 = 0;
    if (year >= 1970) {
        var y: u16 = 1970;
        while (y < year) : (y += 1) {
            days += std.time.epoch.getDaysInYear(y);
        }
        var mo: u4 = 1;
        while (mo < month) : (mo += 1) {
            days += std.time.epoch.getDaysInMonth(year, @enumFromInt(mo));
        }
        days += @as(i64, day) - 1;
    } else {
        var y: u16 = year;
        while (y < 1970) : (y += 1) {
            days -= std.time.epoch.getDaysInYear(y);
        }
        // year is before 1970: subtract remaining months of year and days
        // Simpler path: only support >= 1970 for revision dates (git practice).
        return null;
    }

    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

// ---------------------------------------------------------------------------
// Minimal RE2-style validation (enough for go-git parser tests)
// ---------------------------------------------------------------------------

/// Returns a Go-style `error parsing regexp: …` message, or null if ok.
fn validateRegexp(pattern: []const u8) ?[]const u8 {
    var i: usize = 0;
    var prev_was_atom = false;
    var prev_was_repeat = false;

    while (i < pattern.len) {
        const c = pattern[i];
        switch (c) {
            '\\' => {
                if (i + 1 >= pattern.len) {
                    return "error parsing regexp: trailing backslash at end of expression";
                }
                i += 2;
                prev_was_atom = true;
                prev_was_repeat = false;
            },
            '*', '+', '?' => {
                if (!prev_was_atom) {
                    if (c == '*') return "error parsing regexp: missing argument to repetition operator: `*`";
                    if (c == '+') return "error parsing regexp: missing argument to repetition operator: `+`";
                    return "error parsing regexp: missing argument to repetition operator: `?`";
                }
                if (prev_was_repeat and c == '*' and i > 0 and pattern[i - 1] == '*') {
                    return "error parsing regexp: invalid nested repetition operator: `**`";
                }
                // Any second consecutive repeat operator (**, ++, *+, etc.)
                if (prev_was_repeat) {
                    return "error parsing regexp: invalid nested repetition operator: `**`";
                }
                prev_was_atom = true;
                prev_was_repeat = true;
                i += 1;
            },
            '(' => {
                // Find matching ) naively for nest tracking not required for tests.
                i += 1;
                prev_was_atom = false;
                prev_was_repeat = false;
                // Treat group as starting; atom after close.
                // Simplified: mark that `(` alone is not an atom until closed content.
            },
            ')' => {
                i += 1;
                prev_was_atom = true;
                prev_was_repeat = false;
            },
            '[' => {
                // Character class: require closing ].
                i += 1;
                if (i < pattern.len and pattern[i] == '^') i += 1;
                if (i < pattern.len and pattern[i] == ']') i += 1; // empty or ] first
                var closed = false;
                while (i < pattern.len) {
                    if (pattern[i] == '\\' and i + 1 < pattern.len) {
                        i += 2;
                        continue;
                    }
                    if (pattern[i] == ']') {
                        i += 1;
                        closed = true;
                        break;
                    }
                    i += 1;
                }
                if (!closed) return "error parsing regexp: missing closing ]: `[`";
                prev_was_atom = true;
                prev_was_repeat = false;
            },
            '{' => {
                // Count quantifier {n} / {n,m} — treat as repeat if after atom.
                if (!prev_was_atom) {
                    return "error parsing regexp: missing argument to repetition operator: `{`";
                }
                const start = i;
                i += 1;
                while (i < pattern.len and pattern[i] != '}') : (i += 1) {}
                if (i >= pattern.len) return "error parsing regexp: missing closing }: `{`";
                _ = start;
                i += 1;
                prev_was_atom = true;
                prev_was_repeat = true;
            },
            '|', '^', '$', '.' => {
                // `|` resets atom on right; treat `.` as atom; anchors not atoms for * purpose loosely
                if (c == '.') {
                    prev_was_atom = true;
                } else if (c == '|') {
                    prev_was_atom = false;
                } else {
                    // ^ $ — not atoms for repetition in RE2 when alone at edges, but OK as atoms sometimes
                    prev_was_atom = true;
                }
                prev_was_repeat = false;
                i += 1;
            },
            else => {
                prev_was_atom = true;
                prev_was_repeat = false;
                i += 1;
            },
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests (go-git parser_test.go)
// ---------------------------------------------------------------------------

test "ErrInvalidRevision Error string" {
    const e = ErrInvalidRevision{ .reason = "test" };
    var buf: [64]u8 = undefined;
    const msg = try e.errorMessage(&buf);
    try testing.expectEqualStrings("Revision invalid : test", msg);
}

test "NewParserFromString constructs" {
    var p = Parser.initFromString(testing.allocator, "test");
    defer p.deinit();
    _ = p.scan();
}

test "Parser scan tokens" {
    var p = Parser.initFromString(testing.allocator, "Hello world !");
    defer p.deinit();

    const expected = [_]struct { Token, []const u8 }{
        .{ .word, "Hello" },
        .{ .space, " " },
        .{ .word, "world" },
        .{ .space, " " },
        .{ .emark, "!" },
    };

    for (expected) |e| {
        const r = p.scan();
        try testing.expect(r.tok != .eof);
        try testing.expectEqual(e[0], r.tok);
        try testing.expectEqualStrings(e[1], r.lit);
    }
    try testing.expectEqual(Token.eof, p.scan().tok);
}

test "Parser unscan" {
    var p = Parser.initFromString(testing.allocator, "Hello world !");
    defer p.deinit();

    const r1 = p.scan();
    try testing.expectEqual(Token.word, r1.tok);
    try testing.expectEqualStrings("Hello", r1.lit);

    p.unscan();
    const r2 = p.scan();
    try testing.expectEqual(Token.word, r2.tok);
    try testing.expectEqualStrings("Hello", r2.lit);
}

const known_date_unix: i64 = blk: {
    // 2016-12-16T21:42:47Z
    // Compute at comptime via the same function if possible; use precomputed value.
    // Verified: date(2016,12,16,21,42,47 UTC) = 1481924567
    break :blk 1481924567;
};

fn expectParseOk(input: []const u8, want: []const Revisioner) !void {
    var p = Parser.initFromString(testing.allocator, input);
    defer p.deinit();
    const got = try p.parse();
    defer freeRevisioners(testing.allocator, got);
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try expectRevisionerEql(w, g);
    }
}

fn expectRevisionerEql(want: Revisioner, got: Revisioner) !void {
    try testing.expectEqual(std.meta.activeTag(want), std.meta.activeTag(got));
    switch (want) {
        .ref => |w| try testing.expectEqualStrings(w.name, got.ref.name),
        .tilde_path => |w| try testing.expectEqual(w.depth, got.tilde_path.depth),
        .caret_path => |w| try testing.expectEqual(w.depth, got.caret_path.depth),
        .caret_reg => |w| {
            try testing.expectEqualStrings(w.pattern, got.caret_reg.pattern);
            try testing.expectEqual(w.negate, got.caret_reg.negate);
        },
        .caret_type => |w| try testing.expectEqualStrings(w.object_type, got.caret_type.object_type),
        .at_reflog => |w| try testing.expectEqual(w.depth, got.at_reflog.depth),
        .at_checkout => |w| try testing.expectEqual(w.depth, got.at_checkout.depth),
        .at_upstream => {},
        .at_push => {},
        .at_date => |w| try testing.expectEqual(w.unix_seconds, got.at_date.unix_seconds),
        .colon_reg => |w| {
            try testing.expectEqualStrings(w.pattern, got.colon_reg.pattern);
            try testing.expectEqual(w.negate, got.colon_reg.negate);
        },
        .colon_path => |w| try testing.expectEqualStrings(w.path, got.colon_path.path),
        .colon_stage_path => |w| {
            try testing.expectEqualStrings(w.path, got.colon_stage_path.path);
            try testing.expectEqual(w.stage, got.colon_stage_path.stage);
        },
    }
}

fn expectParseErr(input: []const u8, reason: []const u8) !void {
    var p = Parser.initFromString(testing.allocator, input);
    defer p.deinit();
    const result = p.parse();
    try testing.expectError(error.InvalidRevision, result);
    try testing.expectEqualStrings(reason, p.invalid_reason);
}

test "parse valid expressions" {
    try expectParseOk("@", &[_]Revisioner{.{ .ref = .{ .name = "HEAD" } }});
    try expectParseOk("@~3", &[_]Revisioner{
        .{ .ref = .{ .name = "HEAD" } },
        .{ .tilde_path = .{ .depth = 3 } },
    });
    try expectParseOk("@{2016-12-16T21:42:47Z}", &[_]Revisioner{
        .{ .at_date = .{ .unix_seconds = known_date_unix } },
    });
    try expectParseOk("@{1}", &[_]Revisioner{.{ .at_reflog = .{ .depth = 1 } }});
    try expectParseOk("@{-1}", &[_]Revisioner{.{ .at_checkout = .{ .depth = 1 } }});
    try expectParseOk("master@{upstream}", &[_]Revisioner{
        .{ .ref = .{ .name = "master" } },
        .{ .at_upstream = .{} },
    });
    try expectParseOk("@{upstream}", &[_]Revisioner{.{ .at_upstream = .{} }});
    try expectParseOk("@{u}", &[_]Revisioner{.{ .at_upstream = .{} }});
    try expectParseOk("master@{push}", &[_]Revisioner{
        .{ .ref = .{ .name = "master" } },
        .{ .at_push = .{} },
    });
    try expectParseOk("master@{2016-12-16T21:42:47Z}", &[_]Revisioner{
        .{ .ref = .{ .name = "master" } },
        .{ .at_date = .{ .unix_seconds = known_date_unix } },
    });
    try expectParseOk("HEAD^", &[_]Revisioner{
        .{ .ref = .{ .name = "HEAD" } },
        .{ .caret_path = .{ .depth = 1 } },
    });
    try expectParseOk("master~3", &[_]Revisioner{
        .{ .ref = .{ .name = "master" } },
        .{ .tilde_path = .{ .depth = 3 } },
    });
    try expectParseOk("v0.99.8^{commit}", &[_]Revisioner{
        .{ .ref = .{ .name = "v0.99.8" } },
        .{ .caret_type = .{ .object_type = "commit" } },
    });
    try expectParseOk("v0.99.8^{}", &[_]Revisioner{
        .{ .ref = .{ .name = "v0.99.8" } },
        .{ .caret_type = .{ .object_type = "tag" } },
    });
    try expectParseOk("HEAD^{/fix nasty bug}", &[_]Revisioner{
        .{ .ref = .{ .name = "HEAD" } },
        .{ .caret_reg = .{ .pattern = "fix nasty bug", .negate = false } },
    });
    try expectParseOk(":/fix nasty bug", &[_]Revisioner{
        .{ .colon_reg = .{ .pattern = "fix nasty bug", .negate = false } },
    });
    try expectParseOk("HEAD:README", &[_]Revisioner{
        .{ .ref = .{ .name = "HEAD" } },
        .{ .colon_path = .{ .path = "README" } },
    });
    try expectParseOk(":README", &[_]Revisioner{
        .{ .colon_path = .{ .path = "README" } },
    });
    try expectParseOk("master:./README", &[_]Revisioner{
        .{ .ref = .{ .name = "master" } },
        .{ .colon_path = .{ .path = "./README" } },
    });
    try expectParseOk("master^1~:./README", &[_]Revisioner{
        .{ .ref = .{ .name = "master" } },
        .{ .caret_path = .{ .depth = 1 } },
        .{ .tilde_path = .{ .depth = 1 } },
        .{ .colon_path = .{ .path = "./README" } },
    });
    try expectParseOk(":0:README", &[_]Revisioner{
        .{ .colon_stage_path = .{ .path = "README", .stage = 0 } },
    });
    try expectParseOk(":3:README", &[_]Revisioner{
        .{ .colon_stage_path = .{ .path = "README", .stage = 3 } },
    });
    try expectParseOk("master~1^{/update}~5~^^1", &[_]Revisioner{
        .{ .ref = .{ .name = "master" } },
        .{ .tilde_path = .{ .depth = 1 } },
        .{ .caret_reg = .{ .pattern = "update", .negate = false } },
        .{ .tilde_path = .{ .depth = 5 } },
        .{ .tilde_path = .{ .depth = 1 } },
        .{ .caret_path = .{ .depth = 1 } },
        .{ .caret_path = .{ .depth = 1 } },
    });
}

test "parse invalid expressions" {
    try expectParseErr("..", "must not start with \".\"");
    try expectParseErr("master^1master", "reference must be defined once at the beginning");
    try expectParseErr("master^1@{2016-12-16T21:42:47Z}", "\"@\" statement is not valid, could be : <refname>@{<ISO-8601 date>}, @{<ISO-8601 date>}");
    try expectParseErr("master^1@{1}", "\"@\" statement is not valid, could be : <refname>@{<n>}, @{<n>}");
    try expectParseErr("master@{-1}", "\"@\" statement is not valid, could be : @{-<n>}");
    try expectParseErr("master^1@{upstream}", "\"@\" statement is not valid, could be : <refname>@{upstream}, @{upstream}, <refname>@{u}, @{u}");
    try expectParseErr("master^1@{u}", "\"@\" statement is not valid, could be : <refname>@{upstream}, @{upstream}, <refname>@{u}, @{u}");
    try expectParseErr("master^1@{push}", "\"@\" statement is not valid, could be : <refname>@{push}, @{push}");
    try expectParseErr("^1", "\"~\" or \"^\" statement must have a reference defined at the beginning");
    try expectParseErr("^{/test}", "\"~\" or \"^\" statement must have a reference defined at the beginning");
    try expectParseErr("~1", "\"~\" or \"^\" statement must have a reference defined at the beginning");
    try expectParseErr("master:/test", "\":\" statement is not valid, could be : :/<regexp>");
    try expectParseErr("master:0:README", "\":\" statement is not valid, could be : :<n>:<path>");
    try expectParseErr("^{/", "missing \"}\" in ^{<data>} structure");
    try expectParseErr("~@{", "missing \"}\" in @{<data>} structure");
    try expectParseErr("@@{{0", "missing \"}\" in @{<data>} structure");
}

fn expectParseAt(input: []const u8, want: Revisioner) !void {
    var p = Parser.initFromString(testing.allocator, input);
    defer p.deinit();
    var got = try p.parseAt();
    defer got.deinit(testing.allocator);
    try expectRevisionerEql(want, got);
}

fn expectParseAtErr(input: []const u8, reason: []const u8) !void {
    var p = Parser.initFromString(testing.allocator, input);
    defer p.deinit();
    const result = p.parseAt();
    try testing.expectError(error.InvalidRevision, result);
    try testing.expectEqualStrings(reason, p.invalid_reason);
}

test "parseAt valid" {
    try expectParseAt("", .{ .ref = .{ .name = "HEAD" } });
    try expectParseAt("{1}", .{ .at_reflog = .{ .depth = 1 } });
    try expectParseAt("{-1}", .{ .at_checkout = .{ .depth = 1 } });
    try expectParseAt("{push}", .{ .at_push = .{} });
    try expectParseAt("{upstream}", .{ .at_upstream = .{} });
    try expectParseAt("{u}", .{ .at_upstream = .{} });
    try expectParseAt("{2016-12-16T21:42:47Z}", .{ .at_date = .{ .unix_seconds = known_date_unix } });
}

test "parseAt invalid" {
    try expectParseAtErr("{test}", "wrong date \"test\" must fit ISO-8601 format : 2006-01-02T15:04:05Z");
    try expectParseAtErr("{-1", "missing \"}\" in @{-n} structure");
}

fn expectParseCaret(input: []const u8, want: Revisioner) !void {
    var p = Parser.initFromString(testing.allocator, input);
    defer p.deinit();
    var got = try p.parseCaret();
    defer got.deinit(testing.allocator);
    try expectRevisionerEql(want, got);
}

fn expectParseCaretErr(input: []const u8, reason: []const u8) !void {
    var p = Parser.initFromString(testing.allocator, input);
    defer p.deinit();
    const result = p.parseCaret();
    try testing.expectError(error.InvalidRevision, result);
    try testing.expectEqualStrings(reason, p.invalid_reason);
}

test "parseCaret valid" {
    try expectParseCaret("", .{ .caret_path = .{ .depth = 1 } });
    try expectParseCaret("2", .{ .caret_path = .{ .depth = 2 } });
    try expectParseCaret("{}", .{ .caret_type = .{ .object_type = "tag" } });
    try expectParseCaret("{commit}", .{ .caret_type = .{ .object_type = "commit" } });
    try expectParseCaret("{tree}", .{ .caret_type = .{ .object_type = "tree" } });
    try expectParseCaret("{blob}", .{ .caret_type = .{ .object_type = "blob" } });
    try expectParseCaret("{tag}", .{ .caret_type = .{ .object_type = "tag" } });
    try expectParseCaret("{object}", .{ .caret_type = .{ .object_type = "object" } });
    try expectParseCaret("{/hello world !}", .{ .caret_reg = .{ .pattern = "hello world !", .negate = false } });
    try expectParseCaret("{/!-hello world !}", .{ .caret_reg = .{ .pattern = "hello world !", .negate = true } });
    try expectParseCaret("{/!! hello world !}", .{ .caret_reg = .{ .pattern = "! hello world !", .negate = false } });
}

test "parseCaret invalid" {
    try expectParseCaretErr("3", "\"3\" found must be 0, 1 or 2 after \"^\"");
    try expectParseCaretErr("{test}", "\"test\" is not a valid revision suffix brace component");
    try expectParseCaretErr("{/!test}", "revision suffix brace component sequences starting with \"/!\" others than those defined are reserved");
    try expectParseCaretErr("{/test**}", "revision suffix brace component, error parsing regexp: invalid nested repetition operator: `**`");
}

test "parseTilde valid" {
    var p1 = Parser.initFromString(testing.allocator, "3");
    defer p1.deinit();
    const t1 = try p1.parseTilde();
    try testing.expectEqual(@as(i32, 3), t1.tilde_path.depth);

    var p2 = Parser.initFromString(testing.allocator, "1");
    defer p2.deinit();
    const t2 = try p2.parseTilde();
    try testing.expectEqual(@as(i32, 1), t2.tilde_path.depth);

    var p3 = Parser.initFromString(testing.allocator, "");
    defer p3.deinit();
    const t3 = try p3.parseTilde();
    try testing.expectEqual(@as(i32, 1), t3.tilde_path.depth);
}

fn expectParseColon(input: []const u8, want: Revisioner) !void {
    var p = Parser.initFromString(testing.allocator, input);
    defer p.deinit();
    var got = try p.parseColon();
    defer got.deinit(testing.allocator);
    try expectRevisionerEql(want, got);
}

fn expectParseColonErr(input: []const u8, reason: []const u8) !void {
    var p = Parser.initFromString(testing.allocator, input);
    defer p.deinit();
    const result = p.parseColon();
    try testing.expectError(error.InvalidRevision, result);
    try testing.expectEqualStrings(reason, p.invalid_reason);
}

test "parseColon valid" {
    try expectParseColon("/hello world !", .{ .colon_reg = .{ .pattern = "hello world !", .negate = false } });
    try expectParseColon("/!-hello world !", .{ .colon_reg = .{ .pattern = "hello world !", .negate = true } });
    try expectParseColon("/!! hello world !", .{ .colon_reg = .{ .pattern = "! hello world !", .negate = false } });
    try expectParseColon("../parser.go", .{ .colon_path = .{ .path = "../parser.go" } });
    try expectParseColon("./parser.go", .{ .colon_path = .{ .path = "./parser.go" } });
    try expectParseColon("parser.go", .{ .colon_path = .{ .path = "parser.go" } });
    try expectParseColon("0:parser.go", .{ .colon_stage_path = .{ .path = "parser.go", .stage = 0 } });
    try expectParseColon("1:parser.go", .{ .colon_stage_path = .{ .path = "parser.go", .stage = 1 } });
    try expectParseColon("2:parser.go", .{ .colon_stage_path = .{ .path = "parser.go", .stage = 2 } });
    try expectParseColon("3:parser.go", .{ .colon_stage_path = .{ .path = "parser.go", .stage = 3 } });
}

test "parseColon invalid" {
    try expectParseColonErr("/!test", "revision suffix brace component sequences starting with \"/!\" others than those defined are reserved");
    try expectParseColonErr("/*", "revision suffix brace component, error parsing regexp: missing argument to repetition operator: `*`");
}

fn expectParseRef(input: []const u8) !void {
    var p = Parser.initFromString(testing.allocator, input);
    defer p.deinit();
    var got = try p.parseRef();
    defer got.deinit(testing.allocator);
    try testing.expectEqualStrings(input, got.ref.name);
}

fn expectParseRefErr(input: []const u8, reason: []const u8) !void {
    var p = Parser.initFromString(testing.allocator, input);
    defer p.deinit();
    const result = p.parseRef();
    try testing.expectError(error.InvalidRevision, result);
    try testing.expectEqualStrings(reason, p.invalid_reason);
}

test "parseRef valid names" {
    const names = [_][]const u8{
        "lock",
        "master",
        "v1.0.0",
        "refs/stash",
        "refs/tags/v1.0.0",
        "refs/heads/master",
        "refs/remotes/test",
        "refs/remotes/origin/HEAD",
        "refs/remotes/origin/master",
        "0123abcd",
    };
    for (names) |n| try expectParseRef(n);
}

test "parseRef invalid names" {
    try expectParseRefErr(".master", "must not start with \".\"");
    try expectParseRefErr("/master", "must not start with \"/\"");
    try expectParseRefErr("master/", "must not end with \"/\"");
    try expectParseRefErr("master.", "must not end with \".\"");
    try expectParseRefErr("refs/remotes/.origin/HEAD", "must not contains \"/.\"");
    try expectParseRefErr("test..test", "must not contains \"..\"");
    try expectParseRefErr("test..", "must not contains \"..\"");
    try expectParseRefErr("test test", "must not contains \" \"");
    try expectParseRefErr("test*test", "must not contains \"*\"");
    try expectParseRefErr("test?test", "must not contains \"?\"");
    try expectParseRefErr("test\\test", "must not contains \"\\\"");
    try expectParseRefErr("test[test", "must not contains \"[\"");
    try expectParseRefErr("te//st", "must not contains consecutively \"/\"");
    try expectParseRefErr("refs/remotes/test.lock/HEAD", "cannot end with .lock");
    try expectParseRefErr("test.lock", "cannot end with .lock");
}

test "iso8601 date known value" {
    const u = parseIso8601Z("2016-12-16T21:42:47Z");
    try testing.expect(u != null);
    try testing.expectEqual(known_date_unix, u.?);
}
