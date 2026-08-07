//! Color configuration for unified diffs — port of go-git
//! `plumbing/format/diff/colorconfig.go`.

const color = @import("color");

/// A ColorKey is a key into a ColorConfig map and also equal to the key in the
/// diff.color subsection of the config. See
/// https://github.com/git/git/blob/v2.26.2/diff.c#L83-L106.
pub const ColorKey = enum(u8) {
    context = 0,
    meta = 1,
    frag = 2,
    old = 3,
    new = 4,
    commit = 5,
    whitespace = 6,
    func = 7,
    old_moved = 8,
    old_moved_alternative = 9,
    old_moved_dimmed = 10,
    old_moved_alternative_dimmed = 11,
    new_moved = 12,
    new_moved_alternative = 13,
    new_moved_dimmed = 14,
    new_moved_alternative_dimmed = 15,
    context_dimmed = 16,
    old_dimmed = 17,
    new_dimmed = 18,
    context_bold = 19,
    old_bold = 20,
    new_bold = 21,

    pub const count: usize = 22;

    /// Config / go-git string name for this key.
    pub fn name(self: ColorKey) []const u8 {
        return switch (self) {
            .context => "context",
            .meta => "meta",
            .frag => "frag",
            .old => "old",
            .new => "new",
            .commit => "commit",
            .whitespace => "whitespace",
            .func => "func",
            .old_moved => "oldMoved",
            .old_moved_alternative => "oldMovedAlternative",
            .old_moved_dimmed => "oldMovedDimmed",
            .old_moved_alternative_dimmed => "oldMovedAlternativeDimmed",
            .new_moved => "newMoved",
            .new_moved_alternative => "newMovedAlternative",
            .new_moved_dimmed => "newMovedDimmed",
            .new_moved_alternative_dimmed => "newMovedAlternativeDimmed",
            .context_dimmed => "contextDimmed",
            .old_dimmed => "oldDimmed",
            .new_dimmed => "newDimmed",
            .context_bold => "contextBold",
            .old_bold => "oldBold",
            .new_bold => "newBold",
        };
    }
};

// go-git ColorKey constants (exported aliases).
pub const Context = ColorKey.context;
pub const Meta = ColorKey.meta;
pub const Frag = ColorKey.frag;
pub const Old = ColorKey.old;
pub const New = ColorKey.new;
pub const Commit = ColorKey.commit;
pub const Whitespace = ColorKey.whitespace;
pub const Func = ColorKey.func;
pub const OldMoved = ColorKey.old_moved;
pub const OldMovedAlternative = ColorKey.old_moved_alternative;
pub const OldMovedDimmed = ColorKey.old_moved_dimmed;
pub const OldMovedAlternativeDimmed = ColorKey.old_moved_alternative_dimmed;
pub const NewMoved = ColorKey.new_moved;
pub const NewMovedAlternative = ColorKey.new_moved_alternative;
pub const NewMovedDimmed = ColorKey.new_moved_dimmed;
pub const NewMovedAlternativeDimmed = ColorKey.new_moved_alternative_dimmed;
pub const ContextDimmed = ColorKey.context_dimmed;
pub const OldDimmed = ColorKey.old_dimmed;
pub const NewDimmed = ColorKey.new_dimmed;
pub const ContextBold = ColorKey.context_bold;
pub const OldBold = ColorKey.old_bold;
pub const NewBold = ColorKey.new_bold;

/// A ColorConfig is a color configuration. An empty ColorConfig corresponds to
/// no color (go-git nil/empty map).
pub const ColorConfig = struct {
    entries: [ColorKey.count][]const u8 = .{""} ** ColorKey.count,

    /// Look up the ANSI sequence for `key` (empty when unset).
    pub fn get(self: ColorConfig, key: ColorKey) []const u8 {
        return self.entries[@intFromEnum(key)];
    }

    /// Set the ANSI sequence for `key`.
    pub fn put(self: *ColorConfig, key: ColorKey, value: []const u8) void {
        self.entries[@intFromEnum(key)] = value;
    }

    /// Return the ANSI escape sequence to reset the color with key set from
    /// this config. If no color was set then no reset is needed so it returns
    /// the empty string (go-git `ColorConfig.Reset`).
    pub fn reset(self: ColorConfig, key: ColorKey) []const u8 {
        if (self.get(key).len == 0) return "";
        return color.Reset;
    }
};

/// A ColorConfigOption sets an option on a ColorConfig (go-git `ColorConfigOption`).
pub const ColorConfigOption = struct {
    key: ColorKey,
    value: []const u8,
};

/// WithColor sets the color for key (go-git `WithColor`).
pub fn withColor(key: ColorKey, value: []const u8) ColorConfigOption {
    return .{ .key = key, .value = value };
}

/// defaultColorConfig is the default color configuration. See
/// https://github.com/git/git/blob/v2.26.2/diff.c#L57-L81.
fn defaultColorConfig() ColorConfig {
    var cc: ColorConfig = .{};
    cc.put(.context, color.Normal);
    cc.put(.meta, color.Bold);
    cc.put(.frag, color.Cyan);
    cc.put(.old, color.Red);
    cc.put(.new, color.Green);
    cc.put(.commit, color.Yellow);
    cc.put(.whitespace, color.BgRed);
    cc.put(.func, color.Normal);
    cc.put(.old_moved, color.BoldMagenta);
    cc.put(.old_moved_alternative, color.BoldBlue);
    cc.put(.old_moved_dimmed, color.Faint);
    cc.put(.old_moved_alternative_dimmed, color.FaintItalic);
    cc.put(.new_moved, color.BoldCyan);
    cc.put(.new_moved_alternative, color.BoldYellow);
    cc.put(.new_moved_dimmed, color.Faint);
    cc.put(.new_moved_alternative_dimmed, color.FaintItalic);
    cc.put(.context_dimmed, color.Faint);
    cc.put(.old_dimmed, color.FaintRed);
    cc.put(.new_dimmed, color.FaintGreen);
    cc.put(.context_bold, color.Bold);
    cc.put(.old_bold, color.BoldRed);
    cc.put(.new_bold, color.BoldGreen);
    return cc;
}

/// NewColorConfig returns a new ColorConfig with defaults, then applies options
/// (go-git `NewColorConfig`).
pub fn newColorConfig(options: []const ColorConfigOption) ColorConfig {
    var cc = defaultColorConfig();
    for (options) |opt| {
        cc.put(opt.key, opt.value);
    }
    return cc;
}
