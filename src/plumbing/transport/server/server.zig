//! In-process git server protocol (go-git `plumbing/transport/server/server.go`).
//!
//! Implements upload-pack and receive-pack sessions over a loaded storer.
//! Pack encode uses an in-memory buffer (Zig has no goroutine `io.Pipe`).

const std = @import("std");
const plumbing = @import("plumbing");
const transport = @import("transport");
const packp = @import("packp");
const capability = @import("capability");
const revlist = @import("revlist");
const packfile = @import("packfile");
const sync = @import("utils/sync");

const loader_mod = @import("loader.zig");

const Allocator = std.mem.Allocator;
const Hash = plumbing.Hash;
const Reference = plumbing.Reference;
const ReferenceName = plumbing.ReferenceName;
const Endpoint = transport.Endpoint;
const Loader = loader_mod.Loader;
const RepoStorer = loader_mod.RepoStorer;
const IoWriter = std.Io.Writer;

/// go-git `server.ErrUpdateReference` and session-local errors.
pub const Error = error{
    /// go-git `ErrUpdateReference`.
    UpdateReference,
    /// Requested capability is not supported by this server.
    UnsupportedCapability,
    /// Shallow upload-pack is not implemented (go-git server message).
    ShallowNotSupported,
};

// ---------------------------------------------------------------------------
// Transport shell
// ---------------------------------------------------------------------------

/// In-process server / embedded-client transport (go-git `*server`).
pub const Server = struct {
    loader: Loader,
    as_client: bool,
    allocator: Allocator,

    /// go-git `NewServer`.
    pub fn init(allocator: Allocator, loader: Loader) Server {
        return .{ .loader = loader, .as_client = false, .allocator = allocator };
    }

    /// go-git `NewClient` — server used as an embedded client transport.
    pub fn initClient(allocator: Allocator, loader: Loader) Server {
        return .{ .loader = loader, .as_client = true, .allocator = allocator };
    }

    pub fn newUploadPackSession(
        self: *Server,
        ep: *const Endpoint,
        auth: ?transport.AuthMethod,
    ) !UploadPackSession {
        _ = auth;
        const sto = try self.loader.load(ep);
        return UploadPackSession.init(self.allocator, sto, self.as_client);
    }

    pub fn newReceivePackSession(
        self: *Server,
        ep: *const Endpoint,
        auth: ?transport.AuthMethod,
    ) !ReceivePackSession {
        _ = auth;
        const sto = try self.loader.load(ep);
        return ReceivePackSession.init(self.allocator, sto, self.as_client);
    }
};

/// go-git `NewServer`.
pub fn newServer(allocator: Allocator, loader: Loader) Server {
    return Server.init(allocator, loader);
}

/// go-git `NewClient`.
pub fn newClient(allocator: Allocator, loader: Loader) Server {
    return Server.initClient(allocator, loader);
}

// ---------------------------------------------------------------------------
// Shared session state
// ---------------------------------------------------------------------------

const SessionBase = struct {
    allocator: Allocator,
    storer: RepoStorer,
    /// Negotiated / advertised capability list (inline value; null until first use).
    caps: ?capability.List = null,
    as_client: bool,

    fn deinitCaps(self: *SessionBase) void {
        if (self.caps) |*c| {
            c.deinit();
            self.caps = null;
        }
    }

    fn close(self: *SessionBase) void {
        self.deinitCaps();
    }

    /// go-git `SetAuth` — no-op; auth is applied when creating the session.
    fn setAuth(_: *SessionBase, _: ?transport.AuthMethod) !void {}

    fn checkSupportedCapabilities(self: *const SessionBase, cl: *const capability.List) !void {
        const mine = self.caps orelse return;
        for (cl.all()) |c| {
            if (!mine.supports(c)) return Error.UnsupportedCapability;
        }
    }

    fn adoptCaps(self: *SessionBase, src: *const capability.List) !void {
        self.deinitCaps();
        self.caps = try src.clone(self.allocator);
    }

    fn ensureCaps(self: *SessionBase, set_fn: *const fn (*capability.List) anyerror!void) !void {
        if (self.caps != null) return;
        var list = capability.List.init(self.allocator);
        errdefer list.deinit();
        try set_fn(&list);
        self.caps = list;
    }
};

// ---------------------------------------------------------------------------
// Upload-pack session
// ---------------------------------------------------------------------------

/// go-git `upSession`.
pub const UploadPackSession = struct {
    base: SessionBase,

    pub fn init(allocator: Allocator, sto: RepoStorer, as_client: bool) UploadPackSession {
        return .{ .base = .{ .allocator = allocator, .storer = sto, .as_client = as_client } };
    }

    pub fn close(self: *UploadPackSession) void {
        self.base.close();
    }

    pub fn setAuth(self: *UploadPackSession, auth: ?transport.AuthMethod) !void {
        return self.base.setAuth(auth);
    }

    /// go-git `AdvertisedReferences`.
    /// Caller owns the returned pointer: free with `packp.freeAdvRefs(allocator, ar)`.
    pub fn advertisedReferences(self: *UploadPackSession) !*packp.AdvRefs {
        return self.advertisedReferencesContext();
    }

    /// go-git `AdvertisedReferencesContext` (no cancel plumbing yet).
    /// Caller owns the returned pointer: free with `packp.freeAdvRefs(allocator, ar)`.
    pub fn advertisedReferencesContext(self: *UploadPackSession) !*packp.AdvRefs {
        const ar = try packp.allocAdvRefs(self.base.allocator);
        errdefer {
            ar.deinit();
            self.base.allocator.destroy(ar);
        }

        try setSupportedCapabilitiesUpload(&ar.capabilities);
        try self.base.adoptCaps(&ar.capabilities);

        try setReferences(self.base.storer, ar);
        try setHEAD(self.base.storer, ar);

        if (self.base.as_client and ar.isEmpty()) {
            return transport.Error.EmptyRemoteRepository;
        }

        return ar;
    }

    /// go-git `UploadPack` — encode reachable objects into an in-memory pack.
    pub fn uploadPack(
        self: *UploadPackSession,
        req: *const packp.UploadPackRequest,
    ) !*packp.UploadPackResponse {
        if (req.isEmpty()) return transport.Error.EmptyUploadPackRequest;
        try req.validate();

        try self.base.ensureCaps(setSupportedCapabilitiesUpload);
        try self.base.checkSupportedCapabilities(&req.upload_request.capabilities);
        try self.base.adoptCaps(&req.upload_request.capabilities);

        if (req.upload_request.shallows.items.len > 0) return Error.ShallowNotSupported;

        const objs = try self.objectsToUpload(req);
        defer self.base.allocator.free(objs);

        var aw: IoWriter.Allocating = .init(self.base.allocator);
        errdefer aw.deinit();

        var adapter = StorerAdapter{ .inner = self.base.storer };
        var enc = packfile.Encoder.initFrom(
            self.base.allocator,
            &aw.writer,
            StorerAdapter,
            &adapter,
            false,
        );
        // go-git pack window 10. Delta selection uses `utils/sync` free lists;
        // drain them after encode so GPA-based tests stay leak-clean.
        defer sync.deinitPools(self.base.allocator);
        _ = try enc.encode(objs, 10);

        const pack_data = try aw.toOwnedSlice();
        // Response takes ownership of pack_data (no second copy).
        return try packp.newUploadPackResponseWithPackfile(self.base.allocator, req, pack_data);
    }

    fn objectsToUpload(self: *UploadPackSession, req: *const packp.UploadPackRequest) ![]Hash {
        var adapter = StorerAdapter{ .inner = self.base.storer };
        const haves = try revlist.objects(self.base.allocator, &adapter, req.upload_haves.haves.items, &.{});
        defer self.base.allocator.free(haves);
        return revlist.objects(self.base.allocator, &adapter, req.upload_request.wants.items, haves);
    }
};

fn setSupportedCapabilitiesUpload(c: *capability.List) !void {
    const agent = try capability.defaultAgent(c.allocator, null);
    defer c.allocator.free(agent);
    try c.set(capability.Agent, &.{agent});
    try c.set(capability.OFSDelta, &.{});
}

// ---------------------------------------------------------------------------
// Receive-pack session
// ---------------------------------------------------------------------------

/// Outcome of `ReceivePack` (go-git returns `(report, err)` pair).
pub const ReceivePackOutcome = struct {
    report: ?*packp.ReportStatus = null,
    err: ?anyerror = null,
};

/// go-git `rpSession`.
pub const ReceivePackSession = struct {
    base: SessionBase,
    /// Per-ref status: name → null means ok, else error.
    cmd_status: std.StringHashMapUnmanaged(?anyerror) = .empty,
    first_err: ?anyerror = null,
    unpack_err: ?anyerror = null,

    pub fn init(allocator: Allocator, sto: RepoStorer, as_client: bool) ReceivePackSession {
        return .{ .base = .{ .allocator = allocator, .storer = sto, .as_client = as_client } };
    }

    pub fn close(self: *ReceivePackSession) void {
        var it = self.cmd_status.keyIterator();
        while (it.next()) |k| {
            self.base.allocator.free(k.*);
        }
        self.cmd_status.deinit(self.base.allocator);
        self.base.close();
    }

    pub fn setAuth(self: *ReceivePackSession, auth: ?transport.AuthMethod) !void {
        return self.base.setAuth(auth);
    }

    /// Caller owns the returned pointer: free with `packp.freeAdvRefs(allocator, ar)`.
    pub fn advertisedReferences(self: *ReceivePackSession) !*packp.AdvRefs {
        return self.advertisedReferencesContext();
    }

    /// Caller owns the returned pointer: free with `packp.freeAdvRefs(allocator, ar)`.
    pub fn advertisedReferencesContext(self: *ReceivePackSession) !*packp.AdvRefs {
        const ar = try packp.allocAdvRefs(self.base.allocator);
        errdefer {
            ar.deinit();
            self.base.allocator.destroy(ar);
        }

        try setSupportedCapabilitiesReceive(&ar.capabilities);
        try self.base.adoptCaps(&ar.capabilities);

        try setReferences(self.base.storer, ar);
        try setHEAD(self.base.storer, ar);

        return ar;
    }

    /// go-git `ReceivePack`. Prefer `receivePackOutcome` for the full `(report, err)` pair.
    pub fn receivePack(
        self: *ReceivePackSession,
        req: *const packp.ReferenceUpdateRequest,
    ) !?*packp.ReportStatus {
        const out = try self.receivePackOutcome(req);
        if (out.err) |e| return e;
        return out.report;
    }

    /// Full go-git return pair: report-status (maybe null) and first error.
    pub fn receivePackOutcome(
        self: *ReceivePackSession,
        req: *const packp.ReferenceUpdateRequest,
    ) !ReceivePackOutcome {
        try self.base.ensureCaps(setSupportedCapabilitiesReceive);
        try self.base.checkSupportedCapabilities(&req.capabilities);
        try self.base.adoptCaps(&req.capabilities);

        const atomic = req.capabilities.supports(capability.Atomic);

        if (try collectPackBytes(self.base.allocator, req)) |owned| {
            defer self.base.allocator.free(owned);
            if (owned.len > 0) {
                self.writePackfile(owned) catch |err| {
                    self.unpack_err = err;
                    self.first_err = err;
                    // Atomic: refuse all ref updates when pack unpack fails.
                    if (atomic) {
                        try self.failAllCommands(req, err);
                    }
                    return .{
                        .report = try self.buildReportStatus(),
                        .err = err,
                    };
                };
            }
        }

        if (atomic) {
            try self.updateReferencesAtomic(req);
        } else {
            try self.updateReferences(req);
        }
        return .{
            .report = try self.buildReportStatus(),
            .err = self.first_err,
        };
    }

    /// Non-atomic: apply each command independently (go-git default path).
    fn updateReferences(self: *ReceivePackSession, req: *const packp.ReferenceUpdateRequest) !void {
        for (req.commands.items) |cmd| {
            try self.applyOneCommand(cmd);
        }
    }

    /// Atomic: validate every command first; apply all only if every one is legal.
    /// On any validation failure, mark every command failed and apply none.
    fn updateReferencesAtomic(self: *ReceivePackSession, req: *const packp.ReferenceUpdateRequest) !void {
        var first_fail: ?anyerror = null;
        for (req.commands.items) |cmd| {
            if (try self.validateCommand(cmd)) |err| {
                if (first_fail == null) first_fail = err;
            }
        }
        if (first_fail) |err| {
            try self.failAllCommands(req, err);
            return;
        }
        for (req.commands.items) |cmd| {
            try self.applyOneCommand(cmd);
        }
    }

    fn failAllCommands(self: *ReceivePackSession, req: *const packp.ReferenceUpdateRequest, err: anyerror) !void {
        for (req.commands.items) |cmd| {
            try self.setStatus(cmd.name, err);
        }
    }

    /// Returns null when the command is valid to apply; otherwise the failure.
    /// Storage lookup errors are returned as the error union (not optional payload).
    fn validateCommand(self: *ReceivePackSession, cmd: packp.Command) !?anyerror {
        if (cmd.action() == .invalid) return @as(?anyerror, Error.UpdateReference);
        const exists = try referenceExists(self.base.storer, cmd.name);
        return switch (cmd.action()) {
            .create => if (exists) @as(?anyerror, Error.UpdateReference) else null,
            .delete, .update => if (!exists) @as(?anyerror, Error.UpdateReference) else null,
            .invalid => @as(?anyerror, Error.UpdateReference),
        };
    }

    fn applyOneCommand(self: *ReceivePackSession, cmd: packp.Command) !void {
        const name = cmd.name;
        const exists = referenceExists(self.base.storer, name) catch |err| {
            try self.setStatus(name, err);
            return;
        };

        switch (cmd.action()) {
            .create => {
                if (exists) {
                    try self.setStatus(name, Error.UpdateReference);
                    return;
                }
                const ref = Reference.newHashReference(name, cmd.new);
                self.base.storer.setReference(ref) catch |err| {
                    try self.setStatus(name, err);
                    return;
                };
                try self.setStatus(name, null);
            },
            .delete => {
                if (!exists) {
                    try self.setStatus(name, Error.UpdateReference);
                    return;
                }
                self.base.storer.removeReference(name) catch |err| {
                    try self.setStatus(name, err);
                    return;
                };
                try self.setStatus(name, null);
            },
            .update => {
                if (!exists) {
                    try self.setStatus(name, Error.UpdateReference);
                    return;
                }
                const ref = Reference.newHashReference(name, cmd.new);
                self.base.storer.setReference(ref) catch |err| {
                    try self.setStatus(name, err);
                    return;
                };
                try self.setStatus(name, null);
            },
            .invalid => {
                try self.setStatus(name, Error.UpdateReference);
            },
        }
    }

    fn writePackfile(self: *ReceivePackSession, pack_bytes: []const u8) !void {
        // go-git `packfile.UpdateObjectStorage` then objects land in the session storer.
        var obj_store = packfile.ObjectStore.init(self.base.allocator);
        defer obj_store.deinit();

        _ = try packfile.updateObjectStorage(self.base.allocator, &obj_store, pack_bytes);

        var it = obj_store.map.iterator();
        while (it.next()) |e| {
            const src = e.value_ptr.*;
            const dst = try self.base.storer.newEncodedObject();
            errdefer {
                dst.deinit();
                dst.allocator.destroy(dst);
            }
            dst.setType(src.object_type);
            try dst.setContent(src.readerBytes());
            _ = try self.base.storer.setEncodedObject(dst);
        }
    }

    fn setStatus(self: *ReceivePackSession, ref: ReferenceName, status: ?anyerror) !void {
        const key = try self.base.allocator.dupe(u8, ref.raw);
        errdefer self.base.allocator.free(key);
        const gop = try self.cmd_status.getOrPut(self.base.allocator, key);
        if (gop.found_existing) {
            self.base.allocator.free(key);
            gop.value_ptr.* = status;
        } else {
            gop.value_ptr.* = status;
        }
        if (self.first_err == null) {
            if (status) |e| self.first_err = e;
        }
    }

    fn buildReportStatus(self: *ReceivePackSession) !?*packp.ReportStatus {
        const caps_val = self.base.caps orelse return null;
        if (!caps_val.supports(capability.ReportStatus)) return null;

        const rs = try packp.newReportStatus(self.base.allocator);
        errdefer packp.freeReportStatus(self.base.allocator, rs);

        if (self.unpack_err) |e| {
            try rs.setUnpackStatus(@errorName(e));
        } else {
            try rs.setUnpackStatus("ok");
        }

        var it = self.cmd_status.iterator();
        while (it.next()) |e| {
            const msg: []const u8 = if (e.value_ptr.*) |err| @errorName(err) else "ok";
            try rs.addCommandStatus(e.key_ptr.*, msg);
        }
        return rs;
    }
};

fn setSupportedCapabilitiesReceive(c: *capability.List) !void {
    const agent = try capability.defaultAgent(c.allocator, null);
    defer c.allocator.free(agent);
    try c.set(capability.Agent, &.{agent});
    try c.set(capability.OFSDelta, &.{});
    try c.set(capability.DeleteRefs, &.{});
    try c.set(capability.ReportStatus, &.{});
    try c.set(capability.Atomic, &.{});
}

/// Prefer `packfile_bytes`; else drain `packfile` reader into an owned buffer.
fn collectPackBytes(allocator: Allocator, req: *const packp.ReferenceUpdateRequest) !?[]u8 {
    if (req.packfile_bytes) |b| {
        if (b.len == 0) return try allocator.alloc(u8, 0);
        return try allocator.dupe(u8, b);
    }
    const r = req.packfile orelse return null;
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try r.readSliceShort(&buf);
        if (n == 0) break;
        try list.appendSlice(allocator, buf[0..n]);
    }
    return try list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Advertise helpers
// ---------------------------------------------------------------------------

fn setHEAD(s: RepoStorer, ar: *packp.AdvRefs) !void {
    const ref = s.reference(plumbing.HEAD) catch |err| {
        if (err == error.ReferenceNotFound) return;
        return err;
    };
    defer s.freeReference(ref);

    if (ref.type == .symbolic) {
        // go-git ignores AddReference error for symrefs (copies name/target into caps).
        ar.addReference(ref) catch {};
        const resolved = s.resolveReference(ref.target) catch |err| {
            if (err == error.ReferenceNotFound) return;
            return err;
        };
        defer s.freeReference(resolved);
        if (resolved.type != .hash) return plumbing.Error.InvalidType;
        ar.head = resolved.hash;
        return;
    }

    if (ref.type != .hash) return plumbing.Error.InvalidType;
    ar.head = ref.hash;
}

fn setReferences(s: RepoStorer, ar: *packp.AdvRefs) !void {
    const Ctx = struct {
        ar: *packp.AdvRefs,
        storer: RepoStorer,
        fn cb(ctx: *anyopaque, name: []const u8, hash: Hash) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.ar.putReference(name, hash);
            // Pack-protocol peel for annotated tags (go-git server still TODOs this).
            if (!ReferenceName.init(name).isTag()) return;
            if (try peelToNonTag(self.storer, hash)) |peeled| {
                // Lightweight tags (ref → commit) yield null; only real peels differ.
                if (!peeled.eql(hash)) try self.ar.putPeeled(name, peeled);
            }
        }
    };
    var ctx = Ctx{ .ar = ar, .storer = s };
    try s.forEachHashRef(@ptrCast(&ctx), Ctx.cb);
}

/// Follow annotated-tag object chains to the first non-tag target.
///
/// Returns `null` when `start` is not an annotated tag (lightweight tags, missing
/// objects, non-tag types). Returned objects from `encodedObject` are store-owned —
/// do not free them.
fn peelToNonTag(s: RepoStorer, start: Hash) !?Hash {
    var current = start;
    var walked = false;
    var depth: usize = 0;
    const max_peel: usize = 16;

    while (depth < max_peel) : (depth += 1) {
        const obj = s.encodedObject(.any, current) catch |err| {
            if (err == error.ObjectNotFound) break;
            return err;
        };
        if (obj.object_type != .tag) break;
        current = parseTagTarget(obj.readerBytes()) orelse break;
        walked = true;
    }

    return if (walked) current else null;
}

/// Parse the first `object <40-hex>` header from an annotated tag body.
/// Mirrors the lightweight path in `revlist.parseTag` without allocating a Tag.
fn parseTagTarget(body: []const u8) ?Hash {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) return null; // end of headers
        if (!std.mem.startsWith(u8, line, "object ")) continue;
        const hex = std.mem.trim(u8, line["object ".len..], " \t\r");
        return plumbing.parseHash(hex) catch null;
    }
    return null;
}

fn referenceExists(s: RepoStorer, n: ReferenceName) !bool {
    return s.hasReference(n);
}

// ---------------------------------------------------------------------------
// StorerAdapter — presents RepoStorer to revlist / packfile.Encoder
// ---------------------------------------------------------------------------

const StorerAdapter = struct {
    inner: RepoStorer,

    pub fn encodedObject(self: *StorerAdapter, t: plumbing.ObjectType, h: Hash) anyerror!*plumbing.MemoryObject {
        return self.inner.encodedObject(t, h);
    }
};
