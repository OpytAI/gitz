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
    /// Unsupported shallow mode (e.g. deepen-since / deepen-not without full support).
    /// Depth-commits shallow fetch is implemented; go-git rejects all shallows.
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

    /// Expose the embedded server through the same transport interface as
    /// file/git/http/ssh clients.
    pub fn asTransport(self: *Server) transport.Transport {
        return .{ .ptr = self, .vtable = &server_transport_vtable };
    }
};

const OwnedUploadSession = struct {
    allocator: Allocator,
    session: UploadPackSession,
};

const OwnedReceiveSession = struct {
    allocator: Allocator,
    session: ReceivePackSession,
};

fn serverNewUpload(ptr: *anyopaque, ep: *const Endpoint, auth: ?transport.AuthMethod) anyerror!transport.UploadPackSession {
    const srv: *Server = @ptrCast(@alignCast(ptr));
    const owned = try srv.allocator.create(OwnedUploadSession);
    errdefer srv.allocator.destroy(owned);
    owned.* = .{ .allocator = srv.allocator, .session = try srv.newUploadPackSession(ep, auth) };
    return .{ .ptr = owned, .vtable = &owned_upload_vtable };
}

fn serverNewReceive(ptr: *anyopaque, ep: *const Endpoint, auth: ?transport.AuthMethod) anyerror!transport.ReceivePackSession {
    const srv: *Server = @ptrCast(@alignCast(ptr));
    const owned = try srv.allocator.create(OwnedReceiveSession);
    errdefer srv.allocator.destroy(owned);
    owned.* = .{ .allocator = srv.allocator, .session = try srv.newReceivePackSession(ep, auth) };
    return .{ .ptr = owned, .vtable = &owned_receive_vtable };
}

fn ownedUploadClose(ptr: *anyopaque) void {
    const owned: *OwnedUploadSession = @ptrCast(@alignCast(ptr));
    const allocator = owned.allocator;
    owned.session.close();
    allocator.destroy(owned);
}

fn ownedUploadAdvertised(ptr: *anyopaque, ctx: transport.OperationContext) anyerror!*packp.AdvRefs {
    const owned: *OwnedUploadSession = @ptrCast(@alignCast(ptr));
    try ctx.check();
    return owned.session.advertisedReferencesContext();
}

fn ownedUploadPack(ptr: *anyopaque, ctx: transport.OperationContext, req: *const packp.UploadPackRequest) anyerror!*packp.UploadPackResponse {
    const owned: *OwnedUploadSession = @ptrCast(@alignCast(ptr));
    try ctx.check();
    return owned.session.uploadPack(req);
}

fn ownedUploadSetAuth(ptr: *anyopaque, auth: ?transport.AuthMethod) anyerror!void {
    const owned: *OwnedUploadSession = @ptrCast(@alignCast(ptr));
    return owned.session.setAuth(auth);
}

fn ownedReceiveClose(ptr: *anyopaque) void {
    const owned: *OwnedReceiveSession = @ptrCast(@alignCast(ptr));
    const allocator = owned.allocator;
    owned.session.close();
    allocator.destroy(owned);
}

fn ownedReceiveAdvertised(ptr: *anyopaque, ctx: transport.OperationContext) anyerror!*packp.AdvRefs {
    const owned: *OwnedReceiveSession = @ptrCast(@alignCast(ptr));
    try ctx.check();
    return owned.session.advertisedReferencesContext();
}

fn ownedReceivePack(ptr: *anyopaque, ctx: transport.OperationContext, req: *const packp.ReferenceUpdateRequest) anyerror!transport.ReceivePackOutcome {
    const owned: *OwnedReceiveSession = @ptrCast(@alignCast(ptr));
    try ctx.check();
    const outcome = try owned.session.receivePackOutcome(req);
    return .{ .report = outcome.report, .err = outcome.err };
}

fn ownedReceiveSetAuth(ptr: *anyopaque, auth: ?transport.AuthMethod) anyerror!void {
    const owned: *OwnedReceiveSession = @ptrCast(@alignCast(ptr));
    return owned.session.setAuth(auth);
}

const owned_upload_vtable = transport.UploadPackSession.VTable{
    .close = ownedUploadClose,
    .advertised_references = ownedUploadAdvertised,
    .upload_pack = ownedUploadPack,
    .set_auth = ownedUploadSetAuth,
};

const owned_receive_vtable = transport.ReceivePackSession.VTable{
    .close = ownedReceiveClose,
    .advertised_references = ownedReceiveAdvertised,
    .receive_pack = ownedReceivePack,
    .set_auth = ownedReceiveSetAuth,
};

const server_transport_vtable = transport.Transport.VTable{
    .newUploadPackSession = serverNewUpload,
    .newReceivePackSession = serverNewReceive,
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
    ///
    /// Unlike go-git (which rejects client shallows), gitz supports `deepen`
    /// depth-limited packs and reports boundary commits via `shallow_update`.
    pub fn uploadPack(
        self: *UploadPackSession,
        req: *const packp.UploadPackRequest,
    ) !*packp.UploadPackResponse {
        if (req.isEmpty()) return transport.Error.EmptyUploadPackRequest;
        try req.validate();

        try self.base.ensureCaps(setSupportedCapabilitiesUpload);
        try self.base.checkSupportedCapabilities(&req.upload_request.capabilities);
        try self.base.adoptCaps(&req.upload_request.capabilities);

        const use_depth = !req.depth().isZero() or req.upload_request.shallows.items.len > 0;

        var objs: ?[]Hash = null;
        var shallow_tips: ?[]Hash = null;
        defer {
            if (objs) |o| self.base.allocator.free(o);
            if (shallow_tips) |s| self.base.allocator.free(s);
        }

        if (use_depth) {
            const depth_n = switch (req.depth()) {
                .commits => |n| n,
                // Deepen-since / deepen-not require caps we do not advertise;
                // validate() rejects them first. Keep a clear error if forced.
                else => return Error.ShallowNotSupported,
            };
            const got = try self.objectsToUploadDepth(req, depth_n);
            objs = got.objects;
            shallow_tips = got.shallows;
        } else {
            objs = try self.objectsToUpload(req);
        }

        const objs_slice = objs.?;

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
        _ = try enc.encode(objs_slice, 10);

        const pack_data = try aw.toOwnedSlice();
        // Response takes ownership of pack_data (no second copy).
        const resp = try packp.newUploadPackResponseWithPackfile(self.base.allocator, req, pack_data);
        errdefer packp.freeUploadPackResponse(self.base.allocator, resp);

        // Boundary commits past the depth limit → `shallow` lines on the response.
        // `is_shallow` is already true when request depth is non-zero (packp init).
        if (shallow_tips) |tips| {
            for (tips) |h| {
                try resp.shallow_update.shallows.append(self.base.allocator, h);
            }
        }

        return resp;
    }

    fn objectsToUpload(self: *UploadPackSession, req: *const packp.UploadPackRequest) ![]Hash {
        var adapter = StorerAdapter{ .inner = self.base.storer };
        const haves = try revlist.objects(self.base.allocator, &adapter, req.upload_haves.haves.items, &.{});
        defer self.base.allocator.free(haves);
        return revlist.objects(self.base.allocator, &adapter, req.upload_request.wants.items, haves);
    }

    /// Depth-limited object set for shallow fetch.
    ///
    /// Walks commit parents from each want up to `depth_n` commits (`0` = unlimited).
    /// Parents past the limit become **new** shallow tips (not already listed by the
    /// client). Client shallows are accepted so deepen/refetch does not error; they
    /// are not expanded as "haves" (the client often lacks those objects).
    ///
    /// Trees/blobs come from `revlist` over each included commit's **tree** (not the
    /// commit). That avoids walking parents through revlist and avoids expanding
    /// shallow boundary commits into the ignore set (which would drop shared blobs).
    fn objectsToUploadDepth(
        self: *UploadPackSession,
        req: *const packp.UploadPackRequest,
        depth_n: i32,
    ) !struct { objects: []Hash, shallows: []Hash } {
        const allocator = self.base.allocator;
        var adapter = StorerAdapter{ .inner = self.base.storer };

        var client_shallow: std.AutoHashMapUnmanaged(Hash, void) = .empty;
        defer client_shallow.deinit(allocator);
        for (req.upload_request.shallows.items) |h| {
            try client_shallow.put(allocator, h, {});
        }

        // BFS: (commit hash, depth from want; want itself is depth 1).
        // Head-index queue (not orderedRemove(0)) keeps this O(n).
        const QueueItem = struct { hash: Hash, depth: i32 };
        var queue: std.ArrayList(QueueItem) = .empty;
        defer queue.deinit(allocator);
        var qhead: usize = 0;

        var visited: std.AutoHashMapUnmanaged(Hash, void) = .empty;
        defer visited.deinit(allocator);

        var included: std.ArrayList(Hash) = .empty;
        defer included.deinit(allocator);

        var shallow_set: std.AutoHashMapUnmanaged(Hash, void) = .empty;
        defer shallow_set.deinit(allocator);

        for (req.upload_request.wants.items) |want| {
            try queue.append(allocator, .{ .hash = want, .depth = 1 });
        }

        while (qhead < queue.items.len) {
            const item = queue.items[qhead];
            qhead += 1;
            if (visited.contains(item.hash)) continue;
            try visited.put(allocator, item.hash, {});

            // Peel annotated tags to the underlying commit (or other tip).
            const tip = try peelWantToTip(self.base.storer, item.hash);

            const obj = self.base.storer.encodedObject(.any, tip) catch |err| {
                if (err == error.ObjectNotFound) return err;
                return err;
            };

            if (obj.object_type != .commit) {
                // Non-commit want tip: include as-is; no parent walk / no shallow.
                try included.append(allocator, tip);
                continue;
            }

            // Unlimited depth (0) always includes; finite depth stops after depth_n.
            if (depth_n > 0 and item.depth > depth_n) continue;

            try included.append(allocator, tip);

            var parents_buf: [16]Hash = undefined;
            const parents = try parseCommitParents(obj.readerBytes(), &parents_buf);

            const at_limit = depth_n > 0 and item.depth >= depth_n;
            for (parents) |p| {
                if (at_limit) {
                    // New shallow edge only when the client did not already list it.
                    if (!client_shallow.contains(p)) {
                        try shallow_set.put(allocator, p, {});
                    }
                } else {
                    try queue.append(allocator, .{ .hash = p, .depth = item.depth + 1 });
                }
            }
        }

        // Objects the client already has (negotiation haves only).
        // Client shallows and new shallow tips are **not** expanded here.
        const haves_exp = try revlist.objects(allocator, &adapter, req.upload_haves.haves.items, &.{});
        defer allocator.free(haves_exp);

        // Collect trees (and non-commit tips) for revlist; add commit OIDs by hand.
        var tree_tips: std.ArrayList(Hash) = .empty;
        defer tree_tips.deinit(allocator);
        var commit_oids: std.ArrayList(Hash) = .empty;
        defer commit_oids.deinit(allocator);

        var haves_set: std.AutoHashMapUnmanaged(Hash, void) = .empty;
        defer haves_set.deinit(allocator);
        for (haves_exp) |h| try haves_set.put(allocator, h, {});

        for (included.items) |h| {
            if (haves_set.contains(h)) continue;
            const obj = self.base.storer.encodedObject(.any, h) catch |err| {
                if (err == error.ObjectNotFound) return err;
                return err;
            };
            switch (obj.object_type) {
                .commit => {
                    try commit_oids.append(allocator, h);
                    const tree = try parseCommitTree(obj.readerBytes());
                    if (!haves_set.contains(tree)) try tree_tips.append(allocator, tree);
                },
                else => try tree_tips.append(allocator, h),
            }
        }

        const tree_objs = try revlist.objects(allocator, &adapter, tree_tips.items, haves_exp);
        defer allocator.free(tree_objs);

        var out: std.ArrayList(Hash) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, commit_oids.items);
        for (tree_objs) |h| {
            if (!haves_set.contains(h)) try out.append(allocator, h);
        }

        var shallows: std.ArrayList(Hash) = .empty;
        errdefer shallows.deinit(allocator);
        var sit = shallow_set.keyIterator();
        while (sit.next()) |k| {
            try shallows.append(allocator, k.*);
        }

        const objects = try out.toOwnedSlice(allocator);
        errdefer allocator.free(objects);
        const shallow_slice = try shallows.toOwnedSlice(allocator);
        return .{ .objects = objects, .shallows = shallow_slice };
    }
};

fn setSupportedCapabilitiesUpload(c: *capability.List) !void {
    const agent = try capability.defaultAgent(c.allocator, null);
    defer c.allocator.free(agent);
    try c.set(capability.Agent, &.{agent});
    try c.set(capability.OFSDelta, &.{});
    // gitz extends go-git here: advertise shallow so depth fetch can negotiate.
    try c.set(capability.Shallow, &.{});
}

/// Peel annotated-tag wants to their ultimate non-tag target (commit/tree/blob).
fn peelWantToTip(s: RepoStorer, start: Hash) !Hash {
    var current = start;
    var depth: usize = 0;
    const max_peel: usize = 16;
    while (depth < max_peel) : (depth += 1) {
        const obj = s.encodedObject(.any, current) catch |err| {
            if (err == error.ObjectNotFound) return start;
            return err;
        };
        if (obj.object_type != .tag) return current;
        current = parseTagTarget(obj.readerBytes()) orelse return current;
    }
    return current;
}

/// Parse `parent <hex>` lines from a commit body into `buf` (cap 16 parents).
/// Uses active wire `hexSize()` (SHA-1 / SHA-256 dual format).
fn parseCommitParents(body: []const u8, buf: *[16]Hash) ![]const Hash {
    const width = plumbing.hexSize();
    var n: usize = 0;
    var rest = body;
    while (rest.len > 0) {
        if (rest[0] == '\n') break;
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse break;
        const line = rest[0..nl];
        rest = rest[nl + 1 ..];
        if (!std.mem.startsWith(u8, line, "parent ")) continue;
        if (line.len < 7 + width) return plumbing.Error.InvalidType;
        if (n >= buf.len) break;
        buf[n] = plumbing.newHash(line[7 .. 7 + width]);
        n += 1;
    }
    return buf[0..n];
}

/// Parse the `tree <hex>` header from a commit body (active wire `hexSize()`).
fn parseCommitTree(body: []const u8) !Hash {
    const width = plumbing.hexSize();
    var rest = body;
    while (rest.len > 0) {
        if (rest[0] == '\n') break;
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse break;
        const line = rest[0..nl];
        rest = rest[nl + 1 ..];
        if (!std.mem.startsWith(u8, line, "tree ")) continue;
        if (line.len < 5 + width) return plumbing.Error.InvalidType;
        return plumbing.newHash(line[5 .. 5 + width]);
    }
    return plumbing.Error.InvalidType;
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
