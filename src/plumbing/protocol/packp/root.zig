//! Pack protocol message types — port of go-git `plumbing/protocol/packp` (v5.19.2).
//!
//! # Construction convention
//! - Value types: `Type.init(allocator)` (preferred) or go-git inventory `new*` aliases.
//! - Heap pointers (go-git returns `*T`): `allocAdvRefs`, `newReportStatus`,
//!   `newUploadPackResponse*`. Free with `free*` helpers or
//!   `t.deinit(); allocator.destroy(t)`.

const std = @import("std");
const ioutil = @import("ioutil");

const common = @import("common.zig");
const filter_mod = @import("filter.zig");
const gitproto_mod = @import("gitproto.zig");
const shallowupd_mod = @import("shallowupd.zig");
const srvresp_mod = @import("srvresp.zig");
const report_status_mod = @import("report_status.zig");
const advrefs_mod = @import("advrefs.zig");
const ulreq_mod = @import("ulreq.zig");
const uppackreq_mod = @import("uppackreq.zig");
const uppackresp_mod = @import("uppackresp.zig");
const updreq_mod = @import("updreq.zig");

// --- common ---
pub const hashSize = common.hashSize;
pub const head = common.head;
pub const no_head = common.no_head;
pub const sp = common.sp;
pub const eol = common.eol;
pub const null_byte = common.null_byte;
pub const peeled = common.peeled;
pub const no_head_mark = common.no_head_mark;
pub const want = common.want;
pub const shallow = common.shallow;
pub const deepen = common.deepen;
pub const deepen_commits = common.deepen_commits;
pub const deepen_since = common.deepen_since;
pub const deepen_reference = common.deepen_reference;
pub const unshallow = common.unshallow;
pub const ack = common.ack;
pub const nak = common.nak;
pub const shallow_no_sp = common.shallow_no_sp;
pub const Error = common.Error;
pub const UnexpectedData = common.UnexpectedData;
pub const newErrUnexpectedData = common.newErrUnexpectedData;
pub const isFlush = common.isFlush;

// --- filter ---
pub const Filter = filter_mod.Filter;
pub const BlobLimitPrefix = filter_mod.BlobLimitPrefix;
pub const filterBlobNone = filter_mod.filterBlobNone;
pub const filterBlobLimit = filter_mod.filterBlobLimit;
pub const filterTreeDepth = filter_mod.filterTreeDepth;
pub const filterObjectType = filter_mod.filterObjectType;
pub const filterCombine = filter_mod.filterCombine;

// --- gitproto ---
pub const GitProtoRequest = gitproto_mod.GitProtoRequest;

// --- shallow / server response / report ---
pub const ShallowUpdate = shallowupd_mod.ShallowUpdate;
pub const ServerResponse = srvresp_mod.ServerResponse;
pub const ReportStatus = report_status_mod.ReportStatus;
pub const CommandStatus = report_status_mod.CommandStatus;

// --- request / response types ---
pub const AdvRefs = advrefs_mod.AdvRefs;
pub const Depth = ulreq_mod.Depth;
pub const UploadRequest = ulreq_mod.UploadRequest;
pub const UploadHaves = uppackreq_mod.UploadHaves;
pub const UploadPackRequest = uppackreq_mod.UploadPackRequest;
pub const UploadPackResponse = uppackresp_mod.UploadPackResponse;
pub const ReferenceUpdateRequest = updreq_mod.ReferenceUpdateRequest;
pub const Command = updreq_mod.Command;
pub const Action = updreq_mod.Action;
pub const Option = updreq_mod.Option;
pub const newReferenceUpdateRequest = updreq_mod.newReferenceUpdateRequest;
pub const newReferenceUpdateRequestFromCapabilities = updreq_mod.newReferenceUpdateRequestFromCapabilities;

// ---------------------------------------------------------------------------
// Heap helpers (go-git returns pointers)
// ---------------------------------------------------------------------------

/// AdvRefs ownership (dual rule):
///
/// | How obtained | Owner | Free with |
/// |--------------|-------|-----------|
/// | Stack `AdvRefs.init` | Caller | `deinit` only (no destroy) |
/// | `allocAdvRefs` | Caller | `freeAdvRefs` |
/// | Server / remote session `advertisedReferences` that **transfer** | Caller | `freeAdvRefs` |
/// | HTTP `Session.advertisedReferences` (cached on session) | Session | `Session.close` only — **do not** `freeAdvRefs` |
///
/// Never free a session-cached pointer; never leave a transferred heap pointer
/// unfreed. Call-site docs state which rule applies.

/// Heap-allocate AdvRefs. Free with `freeAdvRefs`.
pub fn allocAdvRefs(allocator: std.mem.Allocator) std.mem.Allocator.Error!*AdvRefs {
    const ar = try allocator.create(AdvRefs);
    ar.* = AdvRefs.init(allocator);
    return ar;
}

/// Free a heap `*AdvRefs` from `allocAdvRefs` or a transferring session.
/// Do not use for HTTP session-cached returns (session owns those).
pub fn freeAdvRefs(allocator: std.mem.Allocator, ar: *AdvRefs) void {
    ar.deinit();
    allocator.destroy(ar);
}

/// Heap-allocate ReportStatus. Free with `freeReportStatus`.
pub fn newReportStatus(allocator: std.mem.Allocator) std.mem.Allocator.Error!*ReportStatus {
    const rs = try allocator.create(ReportStatus);
    rs.* = ReportStatus.init(allocator);
    return rs;
}

pub fn freeReportStatus(allocator: std.mem.Allocator, rs: *ReportStatus) void {
    rs.deinit();
    allocator.destroy(rs);
}

/// Heap-allocate UploadPackResponse. Free with `freeUploadPackResponse`.
pub fn newUploadPackResponse(
    allocator: std.mem.Allocator,
    req: *const UploadPackRequest,
) std.mem.Allocator.Error!*UploadPackResponse {
    const res = try allocator.create(UploadPackResponse);
    res.* = UploadPackResponse.init(allocator, req);
    return res;
}

/// Heap UploadPackResponse that **takes ownership** of `owned_pack` (no extra copy).
/// Free with `freeUploadPackResponse` (closes and frees pack bytes).
pub fn newUploadPackResponseWithPackfile(
    allocator: std.mem.Allocator,
    req: *const UploadPackRequest,
    owned_pack: []u8,
) std.mem.Allocator.Error!*UploadPackResponse {
    const Ctx = struct {
        allocator: std.mem.Allocator,
        bytes: []u8,
        reader: std.Io.Reader = undefined,

        fn closeFn(ctx: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.allocator.free(self.bytes);
            self.allocator.destroy(self);
        }
    };
    const ctx = try allocator.create(Ctx);
    errdefer {
        allocator.free(owned_pack);
        allocator.destroy(ctx);
    }
    ctx.* = .{ .allocator = allocator, .bytes = owned_pack };
    ctx.reader = std.Io.Reader.fixed(ctx.bytes);
    const rc = ioutil.ReadCloser{
        .reader = &ctx.reader,
        .close_fn = Ctx.closeFn,
        .ctx = ctx,
    };

    const res = try allocator.create(UploadPackResponse);
    res.* = UploadPackResponse.initWithPackfile(allocator, req, rc);
    return res;
}

pub fn freeUploadPackResponse(allocator: std.mem.Allocator, res: *UploadPackResponse) void {
    res.deinit();
    allocator.destroy(res);
}

/// Construct UploadPackRequest (value; go-git returns pointer).
pub fn newUploadPackRequest(allocator: std.mem.Allocator) UploadPackRequest {
    return UploadPackRequest.init(allocator);
}

/// Construct UploadPackRequest from advertised capabilities.
pub fn newUploadPackRequestFromCapabilities(
    allocator: std.mem.Allocator,
    adv: *const @import("capability").List,
) !UploadPackRequest {
    return UploadPackRequest.initFromCapabilities(allocator, adv);
}

test {
    _ = @import("common.zig");
    _ = @import("filter.zig");
    _ = @import("gitproto.zig");
    _ = @import("shallowupd.zig");
    _ = @import("srvresp.zig");
    _ = @import("report_status.zig");
    _ = @import("advrefs.zig");
    _ = @import("advrefs_encode.zig");
    _ = @import("advrefs_decode.zig");
    _ = @import("ulreq.zig");
    _ = @import("ulreq_encode.zig");
    _ = @import("ulreq_decode.zig");
    _ = @import("uppackreq.zig");
    _ = @import("uppackresp.zig");
    _ = @import("updreq.zig");
    _ = @import("updreq_encode.zig");
    _ = @import("updreq_decode.zig");
}
