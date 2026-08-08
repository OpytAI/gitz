//! References and reference names (go-git plumbing/reference.go).

const std = @import("std");
const err = @import("error.zig");
const hash_mod = @import("hash.zig");

const Hash = hash_mod.Hash;

const ref_prefix = "refs/";
const ref_head_prefix = ref_prefix ++ "heads/";
const ref_tag_prefix = ref_prefix ++ "tags/";
const ref_remote_prefix = ref_prefix ++ "remotes/";
const ref_note_prefix = ref_prefix ++ "notes/";
const symref_prefix = "ref: ";

/// Rules used by git to expand/shorten refs (go-git RefRevParseRules).
pub const ref_rev_parse_rules = [_][]const u8{
    "%s",
    "refs/%s",
    "refs/tags/%s",
    "refs/heads/%s",
    "refs/remotes/%s",
    "refs/remotes/%s/HEAD",
};

/// Reference kind (go-git ReferenceType).
pub const ReferenceType = enum(i8) {
    invalid = 0,
    hash = 1,
    symbolic = 2,

    pub fn string(self: ReferenceType) []const u8 {
        return switch (self) {
            .invalid => "invalid-reference",
            .hash => "hash-reference",
            .symbolic => "symbolic-reference",
        };
    }
};

/// Reference name (go-git ReferenceName). Holds a borrowed slice; caller owns storage.
pub const ReferenceName = struct {
    raw: []const u8,

    pub fn init(name: []const u8) ReferenceName {
        return .{ .raw = name };
    }

    pub fn string(self: ReferenceName) []const u8 {
        return self.raw;
    }

    pub fn eql(self: ReferenceName, other: ReferenceName) bool {
        return std.mem.eql(u8, self.raw, other.raw);
    }

    pub fn isBranch(self: ReferenceName) bool {
        return std.mem.startsWith(u8, self.raw, ref_head_prefix);
    }

    pub fn isNote(self: ReferenceName) bool {
        return std.mem.startsWith(u8, self.raw, ref_note_prefix);
    }

    pub fn isRemote(self: ReferenceName) bool {
        return std.mem.startsWith(u8, self.raw, ref_remote_prefix);
    }

    pub fn isTag(self: ReferenceName) bool {
        return std.mem.startsWith(u8, self.raw, ref_tag_prefix);
    }

    /// Whether the name is safe under `.git` (go-git ReferenceName.IsSafe).
    pub fn isSafe(self: ReferenceName) bool {
        const s = self.raw;
        if (s.len == 0) return false;

        if (std.mem.startsWith(u8, s, ref_prefix)) {
            const rest = s[ref_prefix.len..];
            if (rest.len == 0 or std.mem.indexOfScalar(u8, rest, '\\') != null) return false;
            var it = std.mem.splitScalar(u8, rest, '/');
            while (it.next()) |part| {
                if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) {
                    return false;
                }
            }
            return true;
        }

        for (s) |c| {
            if (!((c >= 'A' and c <= 'Z') or c == '_')) return false;
        }
        return true;
    }

    /// Short name via reverse RefRevParseRules (best-effort; go-git Short).
    pub fn short(self: ReferenceName) []const u8 {
        const s = self.raw;
        // Prefer longest matching prefix among known ref namespaces.
        const prefixes = [_][]const u8{
            ref_remote_prefix,
            ref_head_prefix,
            ref_tag_prefix,
            ref_note_prefix,
            ref_prefix,
        };
        for (prefixes) |p| {
            if (std.mem.startsWith(u8, s, p) and s.len > p.len) {
                return s[p.len..];
            }
        }
        return s;
    }

    /// Validate against git-check-ref-format rules (subset of go-git Validate).
    pub fn validate(self: ReferenceName) err.Error!void {
        const s = self.raw;
        if (s.len == 0) return error.InvalidReferenceName;
        if (std.mem.eql(u8, s, "HEAD")) return;

        if (std.mem.endsWith(u8, s, ".")) return error.InvalidReferenceName;

        var parts_count: usize = 0;
        var it = std.mem.splitScalar(u8, s, '/');
        while (it.next()) |part| {
            parts_count += 1;
            if (part.len == 0) return error.InvalidReferenceName;
            if (part[0] == '.') return error.InvalidReferenceName;
            if (std.mem.endsWith(u8, part, ".lock")) return error.InvalidReferenceName;
            if (std.mem.indexOf(u8, part, "..") != null) return error.InvalidReferenceName;
            if (std.mem.indexOf(u8, part, "@{") != null) return error.InvalidReferenceName;
            if (std.mem.eql(u8, part, "@")) return error.InvalidReferenceName;
            if (std.mem.indexOfScalar(u8, part, '\\') != null) return error.InvalidReferenceName;
            for (part) |c| {
                if (c < 0o40 or c == 0x7f) return error.InvalidReferenceName;
                if (c == ' ' or c == '~' or c == '^' or c == ':' or
                    c == '?' or c == '*' or c == '[')
                    return error.InvalidReferenceName;
            }
        }
        if (parts_count < 2) return error.InvalidReferenceName;

        // Branches and tags: first name component after category cannot start with '-'.
        if (self.isBranch() or self.isTag()) {
            var it2 = std.mem.splitScalar(u8, s, '/');
            _ = it2.next(); // "refs"
            _ = it2.next(); // "heads" / "tags"
            if (it2.next()) |name_part| {
                if (name_part.len > 0 and name_part[0] == '-') return error.InvalidReferenceName;
            }
        }
    }
};

/// Well-known reference names.
pub const HEAD: ReferenceName = .{ .raw = "HEAD" };
pub const master: ReferenceName = .{ .raw = "refs/heads/master" };
pub const main: ReferenceName = .{ .raw = "refs/heads/main" };

pub fn newBranchReferenceName(name: []const u8, buf: []u8) !ReferenceName {
    const written = try std.fmt.bufPrint(buf, "{s}{s}", .{ ref_head_prefix, name });
    return ReferenceName.init(written);
}

pub fn newTagReferenceName(name: []const u8, buf: []u8) !ReferenceName {
    const written = try std.fmt.bufPrint(buf, "{s}{s}", .{ ref_tag_prefix, name });
    return ReferenceName.init(written);
}

pub fn newNoteReferenceName(name: []const u8, buf: []u8) !ReferenceName {
    const written = try std.fmt.bufPrint(buf, "{s}{s}", .{ ref_note_prefix, name });
    return ReferenceName.init(written);
}

pub fn newRemoteReferenceName(remote: []const u8, name: []const u8, buf: []u8) !ReferenceName {
    const written = try std.fmt.bufPrint(buf, "{s}{s}/{s}", .{ ref_remote_prefix, remote, name });
    return ReferenceName.init(written);
}

pub fn newRemoteHEADReferenceName(remote: []const u8, buf: []u8) !ReferenceName {
    const written = try std.fmt.bufPrint(buf, "{s}{s}/HEAD", .{ ref_remote_prefix, remote });
    return ReferenceName.init(written);
}

/// Git reference: hash ref or symbolic ref (go-git `Reference`).
/// Use fields `.type`, `.name`, `.hash`, `.target` directly.
pub const Reference = struct {
    type: ReferenceType = .invalid,
    name: ReferenceName = .{ .raw = "" },
    hash: Hash = hash_mod.ZeroHash,
    target: ReferenceName = .{ .raw = "" },

    pub fn newHashReference(n: ReferenceName, h: Hash) Reference {
        return .{ .type = .hash, .name = n, .hash = h };
    }

    pub fn newSymbolicReference(n: ReferenceName, target: ReferenceName) Reference {
        return .{ .type = .symbolic, .name = n, .target = target };
    }

    /// True when type, name, and hash/target match.
    pub fn eql(self: Reference, other: Reference) bool {
        if (self.type != other.type) return false;
        if (!self.name.eql(other.name)) return false;
        return switch (self.type) {
            .hash => self.hash.eql(other.hash),
            .symbolic => self.target.eql(other.target),
            .invalid => true,
        };
    }

    /// Create from name and target string (hash hex or `ref: …`).
    pub fn fromStrings(name: []const u8, target: []const u8) Reference {
        const n = ReferenceName.init(name);
        if (std.mem.startsWith(u8, target, symref_prefix)) {
            return newSymbolicReference(n, ReferenceName.init(target[symref_prefix.len..]));
        }
        return newHashReference(n, hash_mod.newHash(target));
    }

    /// Dump as [name, target] strings (go-git Strings). Target for symbolic includes prefix.
    pub fn strings(self: *const Reference, target_buf: []u8) error{NoSpaceLeft}![2][]const u8 {
        const name_s = self.name.string();
        switch (self.type) {
            .hash => {
                if (target_buf.len < hash_mod.HexSize) return error.NoSpaceLeft;
                var hex_buf: [hash_mod.MaxHexSize]u8 = undefined;
                const hex = self.hash.formatHex(&hex_buf);
                @memcpy(target_buf[0..hex.len], hex);
                return .{ name_s, target_buf[0..hex.len] };
            },
            .symbolic => {
                const t = self.target.string();
                const needed = symref_prefix.len + t.len;
                if (target_buf.len < needed) return error.NoSpaceLeft;
                @memcpy(target_buf[0..symref_prefix.len], symref_prefix);
                @memcpy(target_buf[symref_prefix.len..][0..t.len], t);
                return .{ name_s, target_buf[0..needed] };
            },
            .invalid => {
                return .{ name_s, "" };
            },
        }
    }
};
