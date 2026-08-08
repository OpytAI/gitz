//! OpenSSH known_hosts path discovery + pure-Zig line matching
//! (go-git `NewKnownHostsCallback` / knownhosts helpers).
//!
//! # Scope
//!
//! - Path discovery (`SSH_KNOWN_HOSTS`, `~/.ssh/known_hosts`, system file)
//! - Line parse: hosts, key algorithm, base64 key blob, `@cert-authority` / `@revoked`
//! - Host match: comma-separated patterns, `[host]:port`, trailing `.`, simple trailing `*`
//! - Hashed hosts: OpenSSH `|1|<b64 salt>|<b64 hmac>` via HMAC-SHA1
//! - Key check: host + algorithm + blob → ok / mismatch / unknown
//!
//! # Hashed hosts
//!
//! OpenSSH `|1|salt|hash` host fields are fully supported. Match computes
//! `HMAC-SHA1(key=decoded_salt, data=hostname_bytes)` and constant-time
//! compares to the decoded hash. The hostname is hashed as given (plain host
//! or `[host]:port` as stored by OpenSSH after normalization).

const std = @import("std");
const auth_mod = @import("auth_method.zig");

const Allocator = std.mem.Allocator;
const testing = std.testing;
const HmacSha1 = std.crypto.auth.hmac.HmacSha1;

const Error = auth_mod.Error;
const HostKeyCallback = auth_mod.HostKeyCallback;
const HostKeyCheckError = auth_mod.HostKeyCheckError;

// ---------------------------------------------------------------------------
// Path discovery
// ---------------------------------------------------------------------------

/// go-git default known_hosts paths when `SSH_KNOWN_HOSTS` is unset.
pub fn defaultKnownHostsFiles(allocator: Allocator, environ: std.process.Environ) Allocator.Error![]const []const u8 {
    if (std.process.Environ.getPosix(environ, "SSH_KNOWN_HOSTS")) |raw| {
        if (raw.len > 0) {
            var list: std.ArrayList([]const u8) = .empty;
            errdefer {
                for (list.items) |p| allocator.free(p);
                list.deinit(allocator);
            }
            var it = std.mem.splitScalar(u8, raw, ':');
            while (it.next()) |part| {
                if (part.len == 0) continue;
                try list.append(allocator, try allocator.dupe(u8, part));
            }
            if (list.items.len > 0) return try list.toOwnedSlice(allocator);
            list.deinit(allocator);
        }
    }

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }
    if (std.process.Environ.getPosix(environ, "HOME")) |home| {
        if (home.len > 0) {
            try list.append(allocator, try std.fs.path.join(allocator, &.{ home, ".ssh", "known_hosts" }));
        }
    }
    try list.append(allocator, try allocator.dupe(u8, "/etc/ssh/ssh_known_hosts"));
    return try list.toOwnedSlice(allocator);
}

/// Free a slice from `defaultKnownHostsFiles` or `filterKnownHostsFiles`.
pub fn freeKnownHostsFiles(allocator: Allocator, files: []const []const u8) void {
    for (files) |f| allocator.free(f);
    allocator.free(files);
}

/// Filter to existing files (go-git `filterKnownHostsFiles`). Uses `std.Io`.
pub fn filterKnownHostsFiles(
    allocator: Allocator,
    io: std.Io,
    files: []const []const u8,
) (Allocator.Error || Error)![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }
    for (files) |file| {
        if (fileExists(io, file)) {
            try out.append(allocator, try allocator.dupe(u8, file));
        }
    }
    if (out.items.len == 0) return error.KnownHostsNotFound;
    return try out.toOwnedSlice(allocator);
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const file = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.openFileAbsolute(io, path, .{}) catch return false
    else
        std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

fn readFileBytes(allocator: Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    return try file_reader.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024));
}

// ---------------------------------------------------------------------------
// Line parsing + matching
// ---------------------------------------------------------------------------

/// One parsed OpenSSH known_hosts entry.
///
/// Hashed host fields (`|1|…`) set `hashed=true` and store decoded salt/MAC
/// for matching via HMAC-SHA1 (see module docs).
pub const KnownHostEntry = struct {
    /// Comma-separated host patterns as stored (owned when from parse helpers).
    /// For hashed entries this is the full `|1|salt|hash` field.
    hosts: []u8 = &.{},
    key_algo: []u8 = &.{},
    /// Raw key blob (base64-decoded).
    key_blob: []u8 = &.{},
    /// True when line starts with `@cert-authority`.
    cert_authority: bool = false,
    /// True when line starts with `@revoked`.
    revoked: bool = false,
    /// True when host field is hashed (`|1|…`).
    hashed: bool = false,
    /// Decoded HMAC salt (owned when `hashed`; empty otherwise).
    hash_salt: []u8 = &.{},
    /// Decoded HMAC-SHA1 digest (owned when `hashed`; empty otherwise).
    hash_mac: []u8 = &.{},

    pub fn deinit(self: *KnownHostEntry, allocator: Allocator) void {
        if (self.hosts.len > 0) allocator.free(self.hosts);
        if (self.key_algo.len > 0) allocator.free(self.key_algo);
        if (self.key_blob.len > 0) allocator.free(self.key_blob);
        if (self.hash_salt.len > 0) allocator.free(self.hash_salt);
        if (self.hash_mac.len > 0) allocator.free(self.hash_mac);
        self.* = .{};
    }
};

pub fn freeKnownHostEntries(allocator: Allocator, entries: []KnownHostEntry) void {
    for (entries) |*e| e.deinit(allocator);
    allocator.free(entries);
}

/// Parse a single known_hosts line. Returns null for comments / empty / unusable lines.
pub fn parseKnownHostsLine(allocator: Allocator, line_in: []const u8) Allocator.Error!?KnownHostEntry {
    var line = std.mem.trim(u8, line_in, " \t\r\n");
    if (line.len == 0 or line[0] == '#') return null;

    var cert_authority = false;
    var revoked = false;
    if (std.mem.startsWith(u8, line, "@cert-authority")) {
        cert_authority = true;
        line = std.mem.trimStart(u8, line["@cert-authority".len..], " \t");
    } else if (std.mem.startsWith(u8, line, "@revoked")) {
        revoked = true;
        line = std.mem.trimStart(u8, line["@revoked".len..], " \t");
    }

    // fields: hosts keytype base64 [comment...]
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const hosts_field = it.next() orelse return null;
    const algo_field = it.next() orelse return null;
    const b64_field = it.next() orelse return null;
    if (hosts_field.len == 0 or algo_field.len == 0 or b64_field.len == 0) return null;

    const hashed = std.mem.startsWith(u8, hosts_field, "|1|");

    // Build entry and free on any early-null / error path via deinit.
    var entry: KnownHostEntry = .{
        .cert_authority = cert_authority,
        .revoked = revoked,
        .hashed = hashed,
    };
    var committed = false;
    defer if (!committed) entry.deinit(allocator);

    if (hashed) {
        var salt_buf: [64]u8 = undefined;
        var mac_buf: [HmacSha1.mac_length]u8 = undefined;
        const parts = decodeHashedHostField(hosts_field, &salt_buf, &mac_buf) orelse return null;
        entry.hash_salt = try allocator.dupe(u8, parts.salt);
        entry.hash_mac = try allocator.dupe(u8, parts.hash);
    }

    const dec_len = std.base64.standard.Decoder.calcSizeForSlice(b64_field) catch return null;
    entry.key_blob = try allocator.alloc(u8, dec_len);
    std.base64.standard.Decoder.decode(entry.key_blob, b64_field) catch return null;

    entry.hosts = try allocator.dupe(u8, hosts_field);
    entry.key_algo = try allocator.dupe(u8, algo_field);
    committed = true;
    return entry;
}

/// Parse full known_hosts file contents into entries.
pub fn parseKnownHostsFile(allocator: Allocator, content: []const u8) Allocator.Error![]KnownHostEntry {
    var list: std.ArrayList(KnownHostEntry) = .empty;
    errdefer {
        for (list.items) |*e| e.deinit(allocator);
        list.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        if (try parseKnownHostsLine(allocator, raw)) |entry| {
            try list.append(allocator, entry);
        }
    }
    return try list.toOwnedSlice(allocator);
}

/// True when `hostname` matches a known_hosts host field.
/// Supports comma-separated hosts, optional `[host]:port`, trailing `.` strip,
/// and OpenSSH hashed `|1|salt|hash` entries (HMAC-SHA1).
pub fn hostFieldMatches(hosts_field: []const u8, hostname: []const u8) bool {
    if (std.mem.startsWith(u8, hosts_field, "|1|")) {
        return hashedHostFieldMatches(hosts_field, hostname);
    }
    var it = std.mem.splitScalar(u8, hosts_field, ',');
    while (it.next()) |pat| {
        if (hostPatternMatches(pat, hostname)) return true;
    }
    return false;
}

/// Match `hostname` against a parsed hashed entry (uses stored salt/MAC when present).
pub fn entryHostMatches(entry: KnownHostEntry, hostname: []const u8) bool {
    if (entry.hashed) {
        if (entry.hash_salt.len > 0 and entry.hash_mac.len == HmacSha1.mac_length) {
            return hmacHostMatches(hostname, entry.hash_salt, entry.hash_mac);
        }
        return hashedHostFieldMatches(entry.hosts, hostname);
    }
    return hostFieldMatches(entry.hosts, hostname);
}

/// Decode `|1|salt|hash` into caller-provided buffers. Returns null on malformed input.
/// `salt_out` / `hash_out` slices point into `salt_buf` / `hash_buf`.
fn decodeHashedHostField(
    hosts_field: []const u8,
    salt_buf: *[64]u8,
    hash_buf: *[HmacSha1.mac_length]u8,
) ?struct { salt: []const u8, hash: []const u8 } {
    // Format: |1|<base64 salt>|<base64 hmac>  → split yields ["", "1", salt, hash]
    if (!std.mem.startsWith(u8, hosts_field, "|1|")) return null;
    var it = std.mem.splitScalar(u8, hosts_field, '|');
    _ = it.next(); // leading empty before first '|'
    const typ = it.next() orelse return null;
    if (!std.mem.eql(u8, typ, "1")) return null;
    const salt_b64 = it.next() orelse return null;
    const hash_b64 = it.next() orelse return null;
    if (it.next() != null) return null; // extra components
    if (salt_b64.len == 0 or hash_b64.len == 0) return null;

    const salt_len = std.base64.standard.Decoder.calcSizeForSlice(salt_b64) catch return null;
    if (salt_len == 0 or salt_len > salt_buf.len) return null;
    std.base64.standard.Decoder.decode(salt_buf[0..salt_len], salt_b64) catch return null;

    const hash_len = std.base64.standard.Decoder.calcSizeForSlice(hash_b64) catch return null;
    if (hash_len != HmacSha1.mac_length) return null;
    std.base64.standard.Decoder.decode(hash_buf[0..hash_len], hash_b64) catch return null;

    return .{
        .salt = salt_buf[0..salt_len],
        .hash = hash_buf[0..hash_len],
    };
}

fn hashedHostFieldMatches(hosts_field: []const u8, hostname: []const u8) bool {
    var salt_buf: [64]u8 = undefined;
    var mac_buf: [HmacSha1.mac_length]u8 = undefined;
    const parts = decodeHashedHostField(hosts_field, &salt_buf, &mac_buf) orelse return false;
    return hmacHostMatches(hostname, parts.salt, parts.hash);
}

/// HMAC-SHA1(key=salt, data=hostname) constant-time equals expected MAC.
fn hmacHostMatches(hostname: []const u8, salt: []const u8, expected_mac: []const u8) bool {
    if (expected_mac.len != HmacSha1.mac_length) return false;
    var mac: [HmacSha1.mac_length]u8 = undefined;
    HmacSha1.create(&mac, hostname, salt);
    var expected: [HmacSha1.mac_length]u8 = undefined;
    @memcpy(&expected, expected_mac[0..HmacSha1.mac_length]);
    return std.crypto.timing_safe.eql([HmacSha1.mac_length]u8, mac, expected);
}

fn hostPatternMatches(pattern: []const u8, hostname: []const u8) bool {
    var pat = pattern;
    // Optional leading '!' (negation) — not treated as a positive match.
    if (pat.len > 0 and pat[0] == '!') return false;

    // [host]:port form
    if (pat.len >= 2 and pat[0] == '[') {
        if (std.mem.lastIndexOfScalar(u8, pat, ']')) |rb| {
            const inner = pat[1..rb];
            if (hostnameEquals(inner, hostname)) return true;
            if (std.mem.eql(u8, pat, hostname)) return true;
            pat = inner;
        }
    }

    // Simple glob: trailing `*` only (prefix match).
    if (std.mem.indexOfScalar(u8, pat, '*')) |star| {
        if (star == pat.len - 1) {
            const prefix = pat[0..star];
            return std.mem.startsWith(u8, hostname, prefix);
        }
    }
    return hostnameEquals(pat, hostname);
}

fn hostnameEquals(a: []const u8, b: []const u8) bool {
    var aa = a;
    var bb = b;
    if (aa.len > 0 and aa[aa.len - 1] == '.') aa = aa[0 .. aa.len - 1];
    if (bb.len > 0 and bb[bb.len - 1] == '.') bb = bb[0 .. bb.len - 1];
    return std.ascii.eqlIgnoreCase(aa, bb);
}

/// Check host key against loaded entries.
/// - Matching host + algo + blob → ok
/// - Matching host + different blob for same algo → HostKeyMismatch
/// - No entry for host → HostKeyUnknown
/// - Hashed hosts match via HMAC-SHA1(salt, hostname)
pub fn checkKnownHosts(
    entries: []const KnownHostEntry,
    hostname: []const u8,
    key_algo: []const u8,
    key_blob: []const u8,
) HostKeyCheckError!void {
    var saw_host = false;
    for (entries) |e| {
        if (e.revoked) continue;
        if (!entryHostMatches(e, hostname)) continue;
        saw_host = true;
        if (!std.mem.eql(u8, e.key_algo, key_algo)) continue;
        if (std.mem.eql(u8, e.key_blob, key_blob)) return;
        return error.HostKeyMismatch;
    }
    if (saw_host) {
        // Host known under other algorithms only — unknown for this algo.
        return error.HostKeyUnknown;
    }
    return error.HostKeyUnknown;
}

// ---------------------------------------------------------------------------
// In-memory DB + callback factory
// ---------------------------------------------------------------------------

/// In-memory known_hosts DB used as HostKeyCallback.
pub const KnownHostsDb = struct {
    allocator: Allocator,
    entries: []KnownHostEntry = &.{},

    pub fn deinit(self: *KnownHostsDb) void {
        freeKnownHostEntries(self.allocator, self.entries);
        self.entries = &.{};
    }

    pub fn check(
        self: *KnownHostsDb,
        hostname: []const u8,
        remote_addr: []const u8,
        key_algo: []const u8,
        key_blob: []const u8,
    ) HostKeyCheckError!void {
        _ = remote_addr;
        return checkKnownHosts(self.entries, hostname, key_algo, key_blob);
    }

    pub fn asHostKeyCallback(self: *KnownHostsDb) HostKeyCallback {
        const gen = struct {
            fn checkFn(
                ptr: *anyopaque,
                hostname: []const u8,
                remote_addr: []const u8,
                key_algo: []const u8,
                key_blob: []const u8,
            ) HostKeyCheckError!void {
                const db: *KnownHostsDb = @ptrCast(@alignCast(ptr));
                return db.check(hostname, remote_addr, key_algo, key_blob);
            }
        };
        return .{
            .ptr = self,
            .check_fn = gen.checkFn,
        };
    }
};

/// Load known_hosts files into a DB (caller owns / deinit).
pub fn loadKnownHostsDb(
    allocator: Allocator,
    io: std.Io,
    files: []const []const u8,
) anyerror!KnownHostsDb {
    var all: std.ArrayList(KnownHostEntry) = .empty;
    errdefer {
        for (all.items) |*e| e.deinit(allocator);
        all.deinit(allocator);
    }

    for (files) |path| {
        const content = readFileBytes(allocator, io, path) catch continue;
        defer allocator.free(content);
        var parsed = try parseKnownHostsFile(allocator, content);
        var i: usize = 0;
        errdefer {
            while (i < parsed.len) : (i += 1) parsed[i].deinit(allocator);
            allocator.free(parsed);
        }
        while (i < parsed.len) : (i += 1) {
            try all.append(allocator, parsed[i]);
        }
        allocator.free(parsed);
    }
    return .{
        .allocator = allocator,
        .entries = try all.toOwnedSlice(allocator),
    };
}

/// go-git `NewKnownHostsCallback`.
///
/// Loads existing known_hosts files and returns a callback that matches
/// host / algorithm / key blob. When no files exist → `KnownHostsNotFound`.
///
/// When `out_db` is non-null, the heap `KnownHostsDb` is returned for the caller
/// to free with `freeKnownHostsDb`. When null, the DB is intentionally long-lived
/// for the lifetime of the process/session (same model as long-lived callbacks).
pub fn newKnownHostsCallback(
    allocator: Allocator,
    io: std.Io,
    environ: std.process.Environ,
    files: []const []const u8,
) (Allocator.Error || Error)!HostKeyCallback {
    return newKnownHostsCallbackOwned(allocator, io, environ, files, null);
}

/// Like `newKnownHostsCallback` but optionally returns the owned DB for deinit.
pub fn newKnownHostsCallbackOwned(
    allocator: Allocator,
    io: std.Io,
    environ: std.process.Environ,
    files: []const []const u8,
    out_db: ?**KnownHostsDb,
) (Allocator.Error || Error)!HostKeyCallback {
    const use_files: []const []const u8 = if (files.len == 0)
        try defaultKnownHostsFiles(allocator, environ)
    else
        files;
    defer if (files.len == 0) freeKnownHostsFiles(allocator, use_files);

    const filtered = try filterKnownHostsFiles(allocator, io, use_files);
    defer freeKnownHostsFiles(allocator, filtered);

    const db = try allocator.create(KnownHostsDb);
    errdefer allocator.destroy(db);
    db.* = try loadKnownHostsDb(allocator, io, filtered);

    if (out_db) |p| p.* = db;
    return db.asHostKeyCallback();
}

/// Free a DB allocated by `newKnownHostsCallbackOwned` when `out_db` was set.
pub fn freeKnownHostsDb(allocator: Allocator, db: *KnownHostsDb) void {
    db.deinit();
    allocator.destroy(db);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "known_hosts parse and match" {
    const line =
        \\github.com ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEAq2A7hRGmdnm9tUDbO9IDSwBK6TbQa+PXYPCPy6rbTrTtw7PHkccKrpp0yVhp5HdEIcKr6pLlVDBfOLX9QUsyCOV0wzfjIJNlGEYsdlLJizHhbn2mUjvSAHQqZETYP81eFzLQNnPHt4EVVUh7VfDESU84KezmD5QlWpXLmvU31/yMf+Se8xhHTvKSCZIFImWwoG6mbUoWf9nzpIoaSjB+weqqUUmpaaasXVal72J+UX2B+2RPW3RcT0eOzQgqlJL3RKrTJvdsjE3JEAvGq3lGHSZXy28G3skua2SmVi/w4yCE6gbODqnTWlg7+wC604ydGXA8VJiS5ap43JXiUFFAaQ==
    ;
    var entry = (try parseKnownHostsLine(testing.allocator, line)).?;
    defer entry.deinit(testing.allocator);
    try testing.expectEqualStrings("github.com", entry.hosts);
    try testing.expectEqualStrings("ssh-rsa", entry.key_algo);
    try testing.expect(entry.key_blob.len > 0);
    try testing.expect(!entry.hashed);

    const entries = [_]KnownHostEntry{entry};
    try checkKnownHosts(&entries, "github.com", "ssh-rsa", entry.key_blob);
    try testing.expectError(error.HostKeyUnknown, checkKnownHosts(&entries, "other.com", "ssh-rsa", entry.key_blob));
    try testing.expectError(error.HostKeyMismatch, checkKnownHosts(&entries, "github.com", "ssh-rsa", "wrong"));
}

test "known_hosts hashed host matches HMAC-SHA1 vector" {
    // salt = b'0123456789abcdef' (16 bytes), host = b'example.com'
    // entry = |1| + b64(salt) + | + b64(HMAC-SHA1(salt, host))
    // Python verified: |1|MDEyMzQ1Njc4OWFiY2RlZg==|SRLY8gP13Q2WpJBR1mnYWd8QETQ=
    const hosts_field = "|1|MDEyMzQ1Njc4OWFiY2RlZg==|SRLY8gP13Q2WpJBR1mnYWd8QETQ=";
    const line = hosts_field ++ " ssh-ed25519 AAECAwQFBgcICQoLDA0ODw==";

    const parsed = try parseKnownHostsLine(testing.allocator, line);
    try testing.expect(parsed != null);
    var entry = parsed.?;
    defer entry.deinit(testing.allocator);

    try testing.expect(entry.hashed);
    try testing.expectEqual(@as(usize, 16), entry.hash_salt.len);
    try testing.expectEqual(@as(usize, HmacSha1.mac_length), entry.hash_mac.len);
    try testing.expectEqualStrings("0123456789abcdef", entry.hash_salt);

    try testing.expect(hostFieldMatches(hosts_field, "example.com"));
    try testing.expect(entryHostMatches(entry, "example.com"));
    try testing.expect(!hostFieldMatches(hosts_field, "other.example.com"));
    try testing.expect(!entryHostMatches(entry, "other.example.com"));

    try checkKnownHosts(&[_]KnownHostEntry{entry}, "example.com", "ssh-ed25519", entry.key_blob);
    try testing.expectError(
        error.HostKeyUnknown,
        checkKnownHosts(&[_]KnownHostEntry{entry}, "other.example.com", "ssh-ed25519", entry.key_blob),
    );
    try testing.expectError(
        error.HostKeyMismatch,
        checkKnownHosts(&[_]KnownHostEntry{entry}, "example.com", "ssh-ed25519", "wrong"),
    );
}

test "known_hosts hashed host matches bracket port form" {
    // Hash of "[git.example.com]:2222" with same salt as the plain-host vector.
    const salt = "0123456789abcdef";
    const host_port = "[git.example.com]:2222";
    var mac: [HmacSha1.mac_length]u8 = undefined;
    HmacSha1.create(&mac, host_port, salt);

    var salt_b64: [32]u8 = undefined;
    const salt_b64_len = std.base64.standard.Encoder.calcSize(salt.len);
    _ = std.base64.standard.Encoder.encode(salt_b64[0..salt_b64_len], salt);

    var mac_b64: [32]u8 = undefined;
    const mac_b64_len = std.base64.standard.Encoder.calcSize(mac.len);
    _ = std.base64.standard.Encoder.encode(mac_b64[0..mac_b64_len], &mac);

    var field_buf: [128]u8 = undefined;
    const field = try std.fmt.bufPrint(&field_buf, "|1|{s}|{s}", .{
        salt_b64[0..salt_b64_len],
        mac_b64[0..mac_b64_len],
    });

    try testing.expect(hostFieldMatches(field, host_port));
    try testing.expect(!hostFieldMatches(field, "git.example.com"));
    try testing.expect(!hostFieldMatches(field, "example.com"));
}

test "known_hosts bracket host and wildcard" {
    try testing.expect(hostFieldMatches("[git.example.com]:2222", "git.example.com"));
    try testing.expect(hostFieldMatches("*.example.com", "git.example.com") == false); // only trailing *
    try testing.expect(hostFieldMatches("git.*", "git.example.com"));
    try testing.expect(hostFieldMatches("GitHub.COM", "github.com"));
    try testing.expect(hostFieldMatches("a.com,b.com", "b.com"));
    try testing.expect(!hostFieldMatches("!evil.com", "evil.com"));
}

test "known_hosts comment and empty lines" {
    try testing.expect(try parseKnownHostsLine(testing.allocator, "# comment") == null);
    try testing.expect(try parseKnownHostsLine(testing.allocator, "   ") == null);
}

test "defaultKnownHostsFiles from SSH_KNOWN_HOSTS" {
    const gpa = testing.allocator;
    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();
    try map.put("SSH_KNOWN_HOSTS", "/a/kh:/b/kh");
    const environ: std.process.Environ = .{ .block = try map.createPosixBlock(gpa, .{}) };
    defer environ.block.deinit(gpa);

    const files = try defaultKnownHostsFiles(gpa, environ);
    defer freeKnownHostsFiles(gpa, files);
    try testing.expectEqual(@as(usize, 2), files.len);
    try testing.expectEqualStrings("/a/kh", files[0]);
    try testing.expectEqualStrings("/b/kh", files[1]);
}
