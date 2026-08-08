//! Blame — last author of each line of a file at a commit.
//!
//! Port of go-git v5.19.2 `blame.go` (package `git`). Walks parents with
//! line-oriented diffs (`//src/utils/diff`) and assigns each final-file line
//! to the commit that last introduced or changed it.
//!
//! Pin: go-git v5.19.2.

const std = @import("std");
const plumbing = @import("plumbing");
const object = @import("object");
const diff = @import("diff");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Commit = object.Commit;

/// Public errors from the blame walk (beyond object/diff store errors).
pub const Error = error{
    /// Queue emptied before all lines were resolved (go-git invalid state).
    InvalidBlameState,
};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// One blamed line (go-git `Line`).
///
/// `author`, `author_name`, and `text` are owned by the containing
/// `BlameResult` and freed by `BlameResult.deinit`.
pub const Line = struct {
    /// Email of the last author that modified the line (go-git `Author`).
    author: []const u8 = "",
    /// Name of the last author that modified the line (go-git `AuthorName`).
    author_name: []const u8 = "",
    /// Original text of the line without trailing newline (go-git `Text`).
    text: []const u8 = "",
    /// Author date: unix seconds (go-git `Date.Unix()`).
    date: i64 = 0,
    /// Author timezone offset east of UTC in minutes.
    tz_offset_minutes: i16 = 0,
    /// Commit hash that introduced the line (go-git `Hash`).
    hash: Hash = plumbing.ZeroHash,

    fn deinit(self: *Line, allocator: Allocator) void {
        freeOwned(allocator, self.author);
        freeOwned(allocator, self.author_name);
        freeOwned(allocator, self.text);
        self.* = .{};
    }
};

/// Result of a Blame operation (go-git `BlameResult`).
pub const BlameResult = struct {
    allocator: Allocator,
    /// Path of the blamed file (owned).
    path: []const u8 = "",
    /// Hash of the commit used to generate this result (go-git `Rev`).
    rev: Hash = plumbing.ZeroHash,
    /// Every line with its authorship (owned lines + slice).
    lines: []Line = &.{},

    pub fn deinit(self: *BlameResult) void {
        freeOwned(self.allocator, self.path);
        for (self.lines) |*l| l.deinit(self.allocator);
        if (self.lines.len > 0) self.allocator.free(self.lines);
        self.* = .{ .allocator = self.allocator };
    }

    /// go-git `BlameResult.String` — git-blame style pretty-print.
    /// Caller frees the returned slice with `self.allocator`.
    pub fn string(self: *const BlameResult) Allocator.Error![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        const mlnl = digitCount(self.lines.len);
        const mal = self.maxAuthorLength();

        for (self.lines, 0..) |line, ln| {
            var hex_buf: [plumbing.MaxHexSize]u8 = undefined;
            const full_hex = line.hash.formatHex(&hex_buf);
            const short = if (full_hex.len >= 8) full_hex[0..8] else full_hex;

            var date_buf: [40]u8 = undefined;
            const date_s = formatBlameDate(line.date, line.tz_offset_minutes, &date_buf) catch "0000-00-00 00:00:00 +0000";

            // "%s (%-*s %s %*d) %s\n"
            var line_buf: [512]u8 = undefined;
            const prefix = std.fmt.bufPrint(&line_buf, "{s} (", .{short}) catch unreachable;
            try buf.appendSlice(self.allocator, prefix);
            try padAuthor(&buf, self.allocator, line.author_name, mal);
            const mid = std.fmt.bufPrint(&line_buf, " {s} ", .{date_s}) catch unreachable;
            try buf.appendSlice(self.allocator, mid);
            try padUint(&buf, self.allocator, ln + 1, mlnl);
            const suffix = std.fmt.bufPrint(&line_buf, ") {s}\n", .{line.text}) catch unreachable;
            try buf.appendSlice(self.allocator, suffix);
        }
        return try buf.toOwnedSlice(self.allocator);
    }

    fn maxAuthorLength(self: *const BlameResult) usize {
        var m: usize = 0;
        for (self.lines) |line| {
            m = @max(m, utf8RuneCount(line.author_name));
        }
        return m;
    }
};

/// Blame returns a `BlameResult` with the last author of each line of file
/// `path` at commit `c`.
///
/// go-git: `func Blame(c *object.Commit, path string) (*BlameResult, error)`
///
/// Caller owns the result and must call `deinit`. `c` must remain valid for
/// the duration of the call (not retained afterward).
pub fn blame(allocator: Allocator, c: *const Commit, path: []const u8) anyerror!BlameResult {
    var b = try BlameState.init(allocator, c, path);
    defer b.deinit();
    return try b.run();
}

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------

const LineMap = struct {
    orig: i32 = 0,
    cur: i32 = 0,
    commit: ?*Commit = null,
    from_parent_no: i32 = -1,
};

const ChildToNeedsMap = struct {
    child: *QueueItem,
    needs_map: []LineMap,
    identical_to_child: bool,
    parent_no: i32,
};

const QueueItem = struct {
    child: ?*QueueItem = null,
    merged_children: []ChildToNeedsMap = &.{},
    commit: *Commit,
    path: []const u8 = "",
    contents: []const u8 = "",
    needs_map: []LineMap = &.{},
    num_parents_need_resolving: i32 = 0,
    identical_to_child: bool = false,
    parent_no: i32 = 0,
    /// True when this item was created for the root and must not free commit.
    is_root: bool = false,
};

const ParentCommit = struct {
    commit: *Commit,
    path: []const u8,
};

fn queueCompare(_: void, a: *QueueItem, b: *QueueItem) std.math.Order {
    // go-git priorityQueue: Less(i,j) = !a.Commit.Less(b.Commit) → newer first.
    if (a.commit.less(b.commit)) return .gt;
    if (b.commit.less(a.commit)) return .lt;
    return .eq;
}

const Queue = std.PriorityQueue(*QueueItem, void, queueCompare);

const BlameState = struct {
    allocator: Allocator,
    /// Arena for temporary queue state (paths, contents, needs maps, items).
    arena: std.heap.ArenaAllocator,
    f_rev: *const Commit,
    path: []const u8,
    q: Queue,
    /// Commits loaded during the walk (not including f_rev). Freed on deinit.
    owned_commits: std.ArrayList(*Commit),
    /// Root needs map (lives in arena; result reads it before arena deinit).
    root_needs: []LineMap = &.{},
    final_lines: []const []const u8 = &.{},
    /// Whether final_lines strings are owned (always true after load).
    final_lines_owned: bool = false,

    fn init(allocator: Allocator, c: *const Commit, path: []const u8) Allocator.Error!BlameState {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .f_rev = c,
            // const cast: walk only uses f_rev as *Commit for API parity with parents.
            // Safety: f_rev is never mutated or freed by BlameState.
            .path = path,
            .q = Queue.initContext({}),
            .owned_commits = .empty,
        };
    }

    fn deinit(self: *BlameState) void {
        while (self.q.pop()) |_| {}
        self.q.deinit(self.allocator);
        for (self.owned_commits.items) |c| {
            c.deinit();
            self.allocator.destroy(c);
        }
        self.owned_commits.deinit(self.allocator);
        if (self.final_lines_owned) {
            for (self.final_lines) |line| self.allocator.free(line);
            self.allocator.free(self.final_lines);
        }
        self.arena.deinit();
        self.* = undefined;
    }

    fn aa(self: *BlameState) Allocator {
        return self.arena.allocator();
    }

    fn trackCommit(self: *BlameState, c: *Commit) Allocator.Error!void {
        try self.owned_commits.append(self.allocator, c);
    }

    fn run(self: *BlameState) anyerror!BlameResult {
        // f_rev is const to callers; queue items need *Commit. Safe: we never
        // mutate or free f_rev.
        const root_commit: *Commit = @constCast(self.f_rev);

        const file = try root_commit.file(self.path);
        self.final_lines = try file.lines(self.allocator);
        self.final_lines_owned = true;
        const final_length = self.final_lines.len;

        const needs_map = try self.aa().alloc(LineMap, final_length);
        for (needs_map, 0..) |*nm, i| {
            nm.* = .{
                .orig = @intCast(i),
                .cur = @intCast(i),
                .commit = null,
                .from_parent_no = -1,
            };
        }
        self.root_needs = needs_map;

        const contents = try file.contents(self.aa());
        const path_owned = try self.aa().dupe(u8, self.path);

        const root_item = try self.aa().create(QueueItem);
        root_item.* = .{
            .child = null,
            .merged_children = &.{},
            .commit = root_commit,
            .path = path_owned,
            .contents = contents,
            .needs_map = needs_map,
            .num_parents_need_resolving = 0,
            .identical_to_child = false,
            .parent_no = 0,
            .is_root = true,
        };
        try self.q.push(self.allocator, root_item);

        var items: std.ArrayList(*QueueItem) = .empty;
        defer items.deinit(self.allocator);

        while (true) {
            items.clearRetainingCapacity();
            while (true) {
                if (self.q.count() == 0) return error.InvalidBlameState;
                const item = self.q.pop().?;
                try items.append(self.allocator, item);
                const next = self.q.peek();
                if (next == null or !next.?.commit.hash.eql(item.commit.hash)) break;
            }
            const finished = try self.addBlames(items.items);
            if (finished) break;
        }

        return try self.buildResult();
    }

    fn buildResult(self: *BlameState) anyerror!BlameResult {
        const lines = try self.allocator.alloc(Line, self.final_lines.len);
        errdefer {
            for (lines) |*l| l.deinit(self.allocator);
            self.allocator.free(lines);
        }
        @memset(lines, .{});

        for (self.final_lines, self.root_needs, 0..) |text, nm, i| {
            const c = nm.commit orelse return error.InvalidBlameState;
            // Block-scoped errdefer: released on successful break, not after.
            lines[i] = blk: {
                const author = try self.allocator.dupe(u8, c.author.email);
                errdefer freeOwned(self.allocator, author);
                const author_name = try self.allocator.dupe(u8, c.author.name);
                errdefer freeOwned(self.allocator, author_name);
                const text_owned = try self.allocator.dupe(u8, text);
                errdefer freeOwned(self.allocator, text_owned);
                break :blk .{
                    .author = author,
                    .author_name = author_name,
                    .text = text_owned,
                    .date = c.author.when,
                    .tz_offset_minutes = c.author.tz_offset_minutes,
                    .hash = c.hash,
                };
            };
        }

        const path_owned = try self.allocator.dupe(u8, self.path);
        return .{
            .allocator = self.allocator,
            .path = path_owned,
            .rev = self.f_rev.hash,
            .lines = lines,
        };
    }

    fn addBlames(self: *BlameState, cur_items_in: []*QueueItem) anyerror!bool {
        var cur_items = cur_items_in;
        var cur_item = cur_items[0];

        // Merge paths optimisation when all items are identical-to-same-child.
        if (cur_items.len == 1) {
            cur_items = cur_items[0..0];
        } else if (cur_item.identical_to_child) {
            var all_same = true;
            var lowest_parent_no = cur_item.parent_no;
            var i: usize = 1;
            while (i < cur_items.len) : (i += 1) {
                if (!cur_items[i].identical_to_child or cur_item.child != cur_items[i].child) {
                    all_same = false;
                    break;
                }
                lowest_parent_no = @min(lowest_parent_no, cur_items[i].parent_no);
            }
            if (all_same) {
                if (cur_item.child) |ch| {
                    ch.num_parents_need_resolving = ch.num_parents_need_resolving - @as(i32, @intCast(cur_items.len)) + 1;
                }
                cur_items = cur_items[0..0];
                cur_item.parent_no = lowest_parent_no;

                while (cur_item.child != null and
                    cur_item.child.?.identical_to_child and
                    cur_item.child.?.merged_children.len == 0 and
                    cur_item.child.?.num_parents_need_resolving == 1)
                {
                    const old_child = cur_item.child.?;
                    cur_item.child = old_child.child;
                    cur_item.parent_no = old_child.parent_no;
                }
            }
        }

        // Merge multiple needs maps for the same commit.
        if (cur_items.len > 1) {
            const merged = try self.aa().alloc(ChildToNeedsMap, cur_items.len);
            for (cur_items, 0..) |ci, i| {
                merged[i] = .{
                    .child = ci.child.?,
                    .needs_map = ci.needs_map,
                    .identical_to_child = ci.identical_to_child,
                    .parent_no = ci.parent_no,
                };
            }
            cur_item.merged_children = merged;

            var new_needs: std.ArrayList(LineMap) = .empty;
            // Use arena for merged map.
            try new_needs.appendSlice(self.aa(), cur_items[0].needs_map);

            var i: usize = 1;
            while (i < cur_items.len) : (i += 1) {
                const cur = cur_items[i].needs_map;
                var n: usize = 0;
                var cpos: usize = 0;
                while (cpos < cur.len) {
                    if (n == new_needs.items.len) {
                        try new_needs.appendSlice(self.aa(), cur[cpos..]);
                        break;
                    } else if (new_needs.items[n].cur == cur[cpos].cur) {
                        n += 1;
                        cpos += 1;
                    } else if (new_needs.items[n].cur < cur[cpos].cur) {
                        n += 1;
                    } else {
                        try new_needs.insert(self.aa(), n, cur[cpos]);
                        // insert already placed at n; no bubble needed.
                        cpos += 1;
                        n += 1;
                    }
                }
            }
            cur_item.needs_map = try new_needs.toOwnedSlice(self.aa());
            cur_item.identical_to_child = false;
            cur_item.child = null;
            cur_items = cur_items[0..0];
        }

        const parents = try self.parentsContainingPath(cur_item.path, cur_item.commit);
        defer self.aa().free(parents); // only the slice; commits are tracked

        var any_pushed = false;
        for (parents, 0..) |prev, parent_no| {
            const current_hash = try blobHash(cur_item.path, cur_item.commit);
            const prev_hash = try blobHash(prev.path, prev.commit);
            if (current_hash.eql(prev_hash)) {
                if (parents.len == 1 and cur_item.merged_children.len == 0 and cur_item.identical_to_child) {
                    // Bypass completely: single parent, identical, one child.
                    const qi = try self.aa().create(QueueItem);
                    qi.* = .{
                        .child = cur_item.child,
                        .commit = prev.commit,
                        .path = try self.aa().dupe(u8, prev.path),
                        .contents = cur_item.contents,
                        .needs_map = cur_item.needs_map,
                        .identical_to_child = true,
                        .parent_no = cur_item.parent_no,
                    };
                    try self.q.push(self.allocator, qi);
                } else {
                    const needs_copy = try self.aa().dupe(LineMap, cur_item.needs_map);
                    const qi = try self.aa().create(QueueItem);
                    qi.* = .{
                        .child = cur_item,
                        .commit = prev.commit,
                        .path = try self.aa().dupe(u8, prev.path),
                        .contents = cur_item.contents,
                        .needs_map = needs_copy,
                        .identical_to_child = true,
                        .parent_no = @intCast(parent_no),
                    };
                    try self.q.push(self.allocator, qi);
                    cur_item.num_parents_need_resolving += 1;
                }
                any_pushed = true;
                continue;
            }

            const prev_file = try prev.commit.file(prev.path);
            const prev_contents = try prev_file.contents(self.aa());

            const hunks = try diff.do(self.allocator, prev_contents, cur_item.contents);
            defer diff.freeDiffs(self.allocator, hunks);

            var prevl: i32 = -1;
            var curl: i32 = -1;
            var need: usize = 0;
            var get_from_parent: std.ArrayList(LineMap) = .empty;
            defer get_from_parent.deinit(self.aa());

            outer: for (hunks) |h| {
                const h_lines = countLines(h.text);
                var hl: i32 = 0;
                while (hl < h_lines) : (hl += 1) {
                    switch (h.operation) {
                        .equal => {
                            prevl += 1;
                            curl += 1;
                            if (need < cur_item.needs_map.len and curl == cur_item.needs_map[need].cur) {
                                try get_from_parent.append(self.aa(), .{
                                    .orig = curl,
                                    .cur = prevl,
                                    .commit = null,
                                    .from_parent_no = -1,
                                });
                                need += 1;
                                if (need >= cur_item.needs_map.len) break :outer;
                            }
                        },
                        .insert => {
                            curl += 1;
                            if (need < cur_item.needs_map.len and curl == cur_item.needs_map[need].cur) {
                                need += 1;
                                if (need >= cur_item.needs_map.len) break :outer;
                            }
                        },
                        .delete => {
                            prevl += h_lines;
                            continue :outer;
                        },
                    }
                }
            }

            if (get_from_parent.items.len > 0) {
                const qi = try self.aa().create(QueueItem);
                qi.* = .{
                    .child = cur_item,
                    .commit = prev.commit,
                    .path = try self.aa().dupe(u8, prev.path),
                    .contents = prev_contents,
                    .needs_map = try get_from_parent.toOwnedSlice(self.aa()),
                    .identical_to_child = false,
                    .parent_no = @intCast(parent_no),
                };
                try self.q.push(self.allocator, qi);
                cur_item.num_parents_need_resolving += 1;
                any_pushed = true;
            }
        }

        // Contents no longer needed on this item (arena will free).
        cur_item.contents = "";

        if (!any_pushed) {
            return try self.finishNeeds(cur_item);
        }
        return false;
    }

    fn finishNeeds(self: *BlameState, cur_item: *QueueItem) anyerror!bool {
        for (cur_item.needs_map) |*nm| {
            if (nm.commit == null) {
                nm.commit = cur_item.commit;
                nm.from_parent_no = -1;
            }
        }

        if (cur_item.child == null and cur_item.merged_children.len == 0) {
            return true;
        }

        if (cur_item.merged_children.len == 0) {
            return try self.applyNeeds(
                cur_item.child.?,
                cur_item.needs_map,
                cur_item.identical_to_child,
                cur_item.parent_no,
            );
        }

        for (cur_item.merged_children) |ctn| {
            var m: usize = 0;
            var p: usize = 0;
            while (p < ctn.needs_map.len) {
                if (m >= cur_item.needs_map.len) break;
                if (ctn.needs_map[p].cur == cur_item.needs_map[m].cur) {
                    ctn.needs_map[p].commit = cur_item.needs_map[m].commit;
                    m += 1;
                    p += 1;
                } else if (ctn.needs_map[p].cur < cur_item.needs_map[m].cur) {
                    p += 1;
                } else {
                    m += 1;
                }
            }
            const finished = try self.applyNeeds(
                ctn.child,
                ctn.needs_map,
                ctn.identical_to_child,
                ctn.parent_no,
            );
            if (finished) return true;
        }
        return false;
    }

    fn applyNeeds(
        self: *BlameState,
        child: *QueueItem,
        needs_map: []LineMap,
        identical_to_child: bool,
        parent_no: i32,
    ) anyerror!bool {
        if (identical_to_child) {
            if (child.needs_map.len != needs_map.len) return error.InvalidBlameState;
            for (child.needs_map, needs_map) |*l, nm| {
                if (l.cur != nm.cur or l.orig != nm.orig) return error.InvalidBlameState;
                if (l.commit == null or parent_no < l.from_parent_no) {
                    l.commit = nm.commit;
                    l.from_parent_no = parent_no;
                }
            }
        } else {
            var i: usize = 0;
            outer: for (child.needs_map) |*l| {
                while (i < needs_map.len and needs_map[i].orig < l.cur) : (i += 1) {}
                if (i == needs_map.len) break :outer;
                if (l.cur == needs_map[i].orig) {
                    if (l.commit == null or parent_no < l.from_parent_no) {
                        l.commit = needs_map[i].commit;
                        l.from_parent_no = parent_no;
                    }
                }
            }
        }
        child.num_parents_need_resolving -= 1;
        if (child.num_parents_need_resolving == 0) {
            return try self.finishNeeds(child);
        }
        return false;
    }

    fn parentsContainingPath(self: *BlameState, path: []const u8, c: *Commit) anyerror![]ParentCommit {
        var result: std.ArrayList(ParentCommit) = .empty;
        errdefer result.deinit(self.aa());

        var iter = c.parents();
        while (true) {
            const parent = iter.next() catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };
            try self.trackCommit(parent);

            if (parent.file(path)) |_| {
                try result.append(self.aa(), .{
                    .commit = parent,
                    .path = try self.aa().dupe(u8, path),
                });
            } else |_| {
                // Look for renames: parent.Patch(c).
                var patch = try parent.patch(self.allocator, c);
                defer patch.deinit();
                for (patch.filePatches()) |fp| {
                    if (!fp.from.empty() and !fp.to.empty() and std.mem.eql(u8, fp.to.path, path)) {
                        try result.append(self.aa(), .{
                            .commit = parent,
                            .path = try self.aa().dupe(u8, fp.from.path),
                        });
                        break;
                    }
                }
            }
        }
        return try result.toOwnedSlice(self.aa());
    }
};

fn blobHash(path: []const u8, commit: *const Commit) anyerror!Hash {
    const file = try commit.file(path);
    return file.blob.hash;
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

fn freeOwned(allocator: Allocator, s: []const u8) void {
    if (s.len > 0) allocator.free(s);
}

/// go-git `countLines` — empty string is 0 lines; trailing non-newline still counts.
fn countLines(s: []const u8) i32 {
    if (s.len == 0) return 0;
    var n_eol: i32 = 0;
    for (s) |ch| {
        if (ch == '\n') n_eol += 1;
    }
    if (s[s.len - 1] == '\n') return n_eol;
    return n_eol + 1;
}

fn utf8RuneCount(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn digitCount(n: usize) usize {
    if (n == 0) return 1;
    var x = n;
    var d: usize = 0;
    while (x > 0) : (x /= 10) d += 1;
    return d;
}

fn padAuthor(buf: *std.ArrayList(u8), allocator: Allocator, name: []const u8, width: usize) Allocator.Error!void {
    try buf.appendSlice(allocator, name);
    const runes = utf8RuneCount(name);
    if (runes < width) {
        var i: usize = 0;
        while (i < width - runes) : (i += 1) {
            try buf.append(allocator, ' ');
        }
    }
}

fn padUint(buf: *std.ArrayList(u8), allocator: Allocator, value: usize, width: usize) Allocator.Error!void {
    var tmp: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch unreachable;
    if (s.len < width) {
        var i: usize = 0;
        while (i < width - s.len) : (i += 1) {
            try buf.append(allocator, ' ');
        }
    }
    try buf.appendSlice(allocator, s);
}

/// Format like go-git blame String: `2006-01-02 15:04:05 -0700`.
fn formatBlameDate(when: i64, tz_offset_minutes: i16, buf: []u8) error{NoSpaceLeft}![]const u8 {
    const offset_secs: i64 = @as(i64, tz_offset_minutes) * 60;
    const local = when + offset_secs;
    var tz_buf: [5]u8 = undefined;
    const tz = formatTzOffset(tz_offset_minutes, &tz_buf);

    if (local < 0) {
        return std.fmt.bufPrint(buf, "1970-01-01 00:00:00 {s}", .{tz});
    }

    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(local) };
    const day_secs = es.getDaySeconds();
    const epoch_day = es.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const month_num: u8 = @intFromEnum(month_day.month);

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {s}", .{
        year_day.year,
        month_num,
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
        tz,
    });
}

fn formatTzOffset(offset_minutes: i16, buf: *[5]u8) []const u8 {
    const off: i32 = offset_minutes;
    const negative = off < 0;
    const abs: u32 = @intCast(if (negative) -off else off);
    const hours = abs / 60;
    const mins = abs % 60;
    buf[0] = if (negative) '-' else '+';
    buf[1] = '0' + @as(u8, @intCast((hours / 10) % 10));
    buf[2] = '0' + @as(u8, @intCast(hours % 10));
    buf[3] = '0' + @as(u8, @intCast((mins / 10) % 10));
    buf[4] = '0' + @as(u8, @intCast(mins % 10));
    return buf[0..5];
}

// ---------------------------------------------------------------------------
// Tests — hermetic multi-commit history with memory storage
// ---------------------------------------------------------------------------

const memory = @import("memory");
const filemode = @import("filemode");
const Writer = std.Io.Writer;

test "countLines matches go-git" {
    try std.testing.expectEqual(@as(i32, 0), countLines(""));
    try std.testing.expectEqual(@as(i32, 1), countLines("a"));
    try std.testing.expectEqual(@as(i32, 1), countLines("a\n"));
    try std.testing.expectEqual(@as(i32, 2), countLines("a\nb"));
    try std.testing.expectEqual(@as(i32, 2), countLines("a\nb\n"));
    try std.testing.expectEqual(@as(i32, 3), countLines("a\nb\nc"));
}

test "newLines single line author fields" {
    const gpa = std.testing.allocator;
    var store = memory.Storage.init(gpa);
    defer store.deinit();

    const h = try storeCommitWithFile(&store, gpa, "file.txt", "foo\n", "Alice", "alice@example.com", 1000, null, "c1");
    const c = try object.getCommit(gpa, &store, h);
    defer {
        c.deinit();
        gpa.destroy(c);
    }

    var result = try blame(gpa, c, "file.txt");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.lines.len);
    try std.testing.expectEqualStrings("foo", result.lines[0].text);
    try std.testing.expectEqualStrings("alice@example.com", result.lines[0].author);
    try std.testing.expectEqualStrings("Alice", result.lines[0].author_name);
    try std.testing.expect(result.lines[0].hash.eql(h));
    try std.testing.expectEqual(@as(i64, 1000), result.lines[0].date);
    try std.testing.expect(result.rev.eql(h));
    try std.testing.expectEqualStrings("file.txt", result.path);
}

test "blame empty file yields zero lines" {
    const gpa = std.testing.allocator;
    var store = memory.Storage.init(gpa);
    defer store.deinit();

    const h = try storeCommitWithFile(&store, gpa, "empty.txt", "", "A", "a@e", 1, null, "empty");
    const c = try object.getCommit(gpa, &store, h);
    defer {
        c.deinit();
        gpa.destroy(c);
    }

    var result = try blame(gpa, c, "empty.txt");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.lines.len);
}

test "blame multi-commit assigns lines to introducing commits" {
    // History:
    //   c1: create file with "line1\nline2\n"          author Alice
    //   c2: change to "line1\nline2-mod\nline3\n"     author Bob
    //   c3: change to "line1\nline2-mod\nline3\nline4\n" author Carol
    //
    // Expected blame at c3:
    //   line1     → c1 (Alice)
    //   line2-mod → c2 (Bob)
    //   line3     → c2 (Bob)
    //   line4     → c3 (Carol)

    const gpa = std.testing.allocator;
    var store = memory.Storage.init(gpa);
    defer store.deinit();

    const c1 = try storeCommitWithFile(&store, gpa, "doc.txt", "line1\nline2\n", "Alice", "alice@ex.com", 1000, null, "init");
    const c2 = try storeCommitWithFile(&store, gpa, "doc.txt", "line1\nline2-mod\nline3\n", "Bob", "bob@ex.com", 2000, c1, "modify");
    const c3 = try storeCommitWithFile(&store, gpa, "doc.txt", "line1\nline2-mod\nline3\nline4\n", "Carol", "carol@ex.com", 3000, c2, "append");

    const tip = try object.getCommit(gpa, &store, c3);
    defer {
        tip.deinit();
        gpa.destroy(tip);
    }

    var result = try blame(gpa, tip, "doc.txt");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 4), result.lines.len);

    try std.testing.expectEqualStrings("line1", result.lines[0].text);
    try std.testing.expect(result.lines[0].hash.eql(c1));
    try std.testing.expectEqualStrings("alice@ex.com", result.lines[0].author);
    try std.testing.expectEqualStrings("Alice", result.lines[0].author_name);

    try std.testing.expectEqualStrings("line2-mod", result.lines[1].text);
    try std.testing.expect(result.lines[1].hash.eql(c2));
    try std.testing.expectEqualStrings("bob@ex.com", result.lines[1].author);

    try std.testing.expectEqualStrings("line3", result.lines[2].text);
    try std.testing.expect(result.lines[2].hash.eql(c2));
    try std.testing.expectEqualStrings("bob@ex.com", result.lines[2].author);

    try std.testing.expectEqualStrings("line4", result.lines[3].text);
    try std.testing.expect(result.lines[3].hash.eql(c3));
    try std.testing.expectEqualStrings("carol@ex.com", result.lines[3].author);
    try std.testing.expectEqualStrings("Carol", result.lines[3].author_name);
}

test "blame root commit all lines same author" {
    const gpa = std.testing.allocator;
    var store = memory.Storage.init(gpa);
    defer store.deinit();

    const content = "a\nb\nc\n";
    const h = try storeCommitWithFile(&store, gpa, "f.txt", content, "Solo", "solo@ex.com", 50, null, "root");
    const c = try object.getCommit(gpa, &store, h);
    defer {
        c.deinit();
        gpa.destroy(c);
    }

    var result = try blame(gpa, c, "f.txt");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.lines.len);
    for (result.lines) |line| {
        try std.testing.expect(line.hash.eql(h));
        try std.testing.expectEqualStrings("Solo", line.author_name);
    }
}

test "blame missing file returns error" {
    const gpa = std.testing.allocator;
    var store = memory.Storage.init(gpa);
    defer store.deinit();

    const h = try storeCommitWithFile(&store, gpa, "exists.txt", "x\n", "A", "a@e", 1, null, "m");
    const c = try object.getCommit(gpa, &store, h);
    defer {
        c.deinit();
        gpa.destroy(c);
    }

    try std.testing.expectError(error.FileNotFound, blame(gpa, c, "missing.txt"));
}

test "blame line deletion keeps surviving line authorship" {
    // c1: "keep\ngone\n"
    // c2: "keep\n"  (deleted "gone")
    const gpa = std.testing.allocator;
    var store = memory.Storage.init(gpa);
    defer store.deinit();

    const c1 = try storeCommitWithFile(&store, gpa, "t.txt", "keep\ngone\n", "A", "a@e", 10, null, "add");
    const c2 = try storeCommitWithFile(&store, gpa, "t.txt", "keep\n", "B", "b@e", 20, c1, "del");

    const tip = try object.getCommit(gpa, &store, c2);
    defer {
        tip.deinit();
        gpa.destroy(tip);
    }

    var result = try blame(gpa, tip, "t.txt");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.lines.len);
    try std.testing.expectEqualStrings("keep", result.lines[0].text);
    try std.testing.expect(result.lines[0].hash.eql(c1));
    try std.testing.expectEqualStrings("a@e", result.lines[0].author);
}

test "blame insert in middle" {
    // c1: "top\nbottom\n"
    // c2: "top\nmiddle\nbottom\n"
    const gpa = std.testing.allocator;
    var store = memory.Storage.init(gpa);
    defer store.deinit();

    const c1 = try storeCommitWithFile(&store, gpa, "m.txt", "top\nbottom\n", "A", "a@e", 10, null, "base");
    const c2 = try storeCommitWithFile(&store, gpa, "m.txt", "top\nmiddle\nbottom\n", "B", "b@e", 20, c1, "mid");

    const tip = try object.getCommit(gpa, &store, c2);
    defer {
        tip.deinit();
        gpa.destroy(tip);
    }

    var result = try blame(gpa, tip, "m.txt");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.lines.len);
    try std.testing.expect(result.lines[0].hash.eql(c1));
    try std.testing.expectEqualStrings("top", result.lines[0].text);
    try std.testing.expect(result.lines[1].hash.eql(c2));
    try std.testing.expectEqualStrings("middle", result.lines[1].text);
    try std.testing.expect(result.lines[2].hash.eql(c1));
    try std.testing.expectEqualStrings("bottom", result.lines[2].text);
}

test "blame string includes hash prefix and author" {
    const gpa = std.testing.allocator;
    var store = memory.Storage.init(gpa);
    defer store.deinit();

    const h = try storeCommitWithFile(&store, gpa, "s.txt", "hello\n", "Name", "n@e", 1136239445, null, "msg");
    const c = try object.getCommit(gpa, &store, h);
    defer {
        c.deinit();
        gpa.destroy(c);
    }

    var result = try blame(gpa, c, "s.txt");
    defer result.deinit();

    const s = try result.string();
    defer gpa.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "hello") != null);
    var hex: [plumbing.MaxHexSize]u8 = undefined;
    const full = h.formatHex(&hex);
    try std.testing.expect(std.mem.indexOf(u8, s, full[0..8]) != null);
}

test "blame replaces entire file" {
    // c1: "old\n"
    // c2: "new\n"
    const gpa = std.testing.allocator;
    var store = memory.Storage.init(gpa);
    defer store.deinit();

    const c1 = try storeCommitWithFile(&store, gpa, "r.txt", "old\n", "A", "a@e", 10, null, "old");
    const c2 = try storeCommitWithFile(&store, gpa, "r.txt", "new\n", "B", "b@e", 20, c1, "new");

    const tip = try object.getCommit(gpa, &store, c2);
    defer {
        tip.deinit();
        gpa.destroy(tip);
    }

    var result = try blame(gpa, tip, "r.txt");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.lines.len);
    try std.testing.expectEqualStrings("new", result.lines[0].text);
    try std.testing.expect(result.lines[0].hash.eql(c2));
}

test "blame four-commit chain progressive edits" {
    // c1: "L1\n"
    // c2: "L1\nL2\n"
    // c3: "L1x\nL2\n"
    // c4: "L1x\nL2\nL3\n"
    const gpa = std.testing.allocator;
    var store = memory.Storage.init(gpa);
    defer store.deinit();

    const h1 = try storeCommitWithFile(&store, gpa, "chain.txt", "L1\n", "A1", "a1@e", 100, null, "1");
    const h2 = try storeCommitWithFile(&store, gpa, "chain.txt", "L1\nL2\n", "A2", "a2@e", 200, h1, "2");
    const h3 = try storeCommitWithFile(&store, gpa, "chain.txt", "L1x\nL2\n", "A3", "a3@e", 300, h2, "3");
    const h4 = try storeCommitWithFile(&store, gpa, "chain.txt", "L1x\nL2\nL3\n", "A4", "a4@e", 400, h3, "4");

    const tip = try object.getCommit(gpa, &store, h4);
    defer {
        tip.deinit();
        gpa.destroy(tip);
    }

    var result = try blame(gpa, tip, "chain.txt");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.lines.len);
    try std.testing.expectEqualStrings("L1x", result.lines[0].text);
    try std.testing.expect(result.lines[0].hash.eql(h3));
    try std.testing.expectEqualStrings("L2", result.lines[1].text);
    try std.testing.expect(result.lines[1].hash.eql(h2));
    try std.testing.expectEqualStrings("L3", result.lines[2].text);
    try std.testing.expect(result.lines[2].hash.eql(h4));
}

// ---------------------------------------------------------------------------
// Test helpers — build blob/tree/commit chains in memory storage
// ---------------------------------------------------------------------------

fn storeCommitWithFile(
    store: *memory.Storage,
    gpa: Allocator,
    path: []const u8,
    content: []const u8,
    author_name: []const u8,
    author_email: []const u8,
    when: i64,
    parent: ?Hash,
    message: []const u8,
) !Hash {
    const storer = @import("storer");
    const storer_getter = storer.ObjectGetter.from(@TypeOf(store.*), store);

    const blob_obj = try store.newEncodedObject();
    blob_obj.setType(.blob);
    try blob_obj.setContent(content);
    const blob_h = try store.setEncodedObject(blob_obj);

    var tree = object.Tree.init(gpa, storer_getter);
    defer tree.deinit();

    // Support simple nested paths like "dir/file.txt" with one directory level.
    if (std.mem.indexOfScalar(u8, path, '/')) |slash| {
        const dir_name = path[0..slash];
        const base = path[slash + 1 ..];
        var sub = object.Tree.init(gpa, storer_getter);
        defer sub.deinit();
        try sub.appendEntry(base, filemode.Regular, blob_h);
        sub.sortEntries();
        const sub_obj = try store.newEncodedObject();
        try sub.encode(sub_obj);
        const sub_h = try store.setEncodedObject(sub_obj);
        try tree.appendEntry(dir_name, filemode.Dir, sub_h);
    } else {
        try tree.appendEntry(path, filemode.Regular, blob_h);
    }
    tree.sortEntries();
    const tree_obj = try store.newEncodedObject();
    try tree.encode(tree_obj);
    const tree_h = try store.setEncodedObject(tree_obj);

    var hex: [plumbing.MaxHexSize]u8 = undefined;
    var body: Writer.Allocating = .init(gpa);
    defer body.deinit();
    try body.writer.print("tree {s}\n", .{tree_h.string(&hex)});
    if (parent) |p| {
        var phex: [plumbing.MaxHexSize]u8 = undefined;
        try body.writer.print("parent {s}\n", .{p.string(&phex)});
    }
    try body.writer.print(
        \\author {s} <{s}> {d} +0000
        \\committer {s} <{s}> {d} +0000
        \\
        \\{s}
    , .{ author_name, author_email, when, author_name, author_email, when, message });

    var commit_obj = try store.newEncodedObject();
    commit_obj.setType(.commit);
    try commit_obj.setContent(body.written());
    return try store.setEncodedObject(commit_obj);
}
