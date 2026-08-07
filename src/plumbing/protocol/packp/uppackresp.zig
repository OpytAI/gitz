//! Upload-pack response (go-git `plumbing/protocol/packp/uppackresp.go`).
//!
//! Shallow update + server ACK/NAK + packfile stream.
//! multi_ack negotiation matches go-git: capability may be set, but
//! multi-ACK response encoding is unsupported (`error.MultiAckNotSupported`).
//! Pin: go-git v5.19.2.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const plumbing = @import("plumbing");
const capability = @import("capability");
const ioutil = @import("ioutil");
const shallowupd = @import("shallowupd.zig");
const srvresp = @import("srvresp.zig");

const uppackreq = @import("uppackreq.zig");
const ulreq = @import("ulreq.zig");
const UploadPackRequest = uppackreq.UploadPackRequest;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// go-git `ErrUploadPackResponseNotDecoded`.
pub const Error = error{
    UploadPackResponseNotDecoded,
};

// ---------------------------------------------------------------------------
// UploadPackResponse
// ---------------------------------------------------------------------------

/// Response from upload-pack: shallow update, ACKs/NAK, then packfile bytes.
///
/// After a successful `decode`, `read` yields packfile content. Implements the
/// go-git `io.ReadCloser` role via `read` / `close`.
pub const UploadPackResponse = struct {
    shallow_update: shallowupd.ShallowUpdate,
    server_response: srvresp.ServerResponse,

    /// Packfile reader (set by `decode` or `initWithPackfile`).
    r: ?ioutil.ReadCloser = null,
    is_shallow: bool = false,
    is_multi_ack: bool = false,
    allocator: Allocator,

    /// go-git `NewUploadPackResponse`.
    pub fn init(allocator: Allocator, req: *const UploadPackRequest) UploadPackResponse {
        const is_shallow = !req.depth().isZero();
        const is_multi_ack = req.upload_request.capabilities.supports(capability.MultiACK) or
            req.upload_request.capabilities.supports(capability.MultiACKDetailed);
        return .{
            .allocator = allocator,
            .is_shallow = is_shallow,
            .is_multi_ack = is_multi_ack,
            .shallow_update = shallowupd.ShallowUpdate.init(allocator),
            .server_response = srvresp.ServerResponse.init(allocator),
        };
    }

    /// go-git `NewUploadPackResponseWithPackfile`.
    pub fn initWithPackfile(
        allocator: Allocator,
        req: *const UploadPackRequest,
        pf: ioutil.ReadCloser,
    ) UploadPackResponse {
        var resp = init(allocator, req);
        resp.r = pf;
        return resp;
    }

    pub fn deinit(self: *UploadPackResponse) void {
        self.close() catch {};
        self.shallow_update.deinit();
        self.server_response.deinit();
    }

    /// go-git `(*UploadPackResponse).Decode`.
    ///
    /// Reads optional shallow-update, then server-response (ACK/NAK). Remaining
    /// bytes on `reader` are the packfile (via `ioutil.ReadCloser`).
    pub fn decode(self: *UploadPackResponse, reader: *Reader, closer: anytype) !void {
        if (self.is_shallow) {
            try self.shallow_update.decode(reader);
        }
        try self.server_response.decode(reader, self.is_multi_ack);

        // Remaining stream is packfile content. Pair reader with the caller's closer.
        self.r = ioutil.newReadCloser(reader, closer);
    }

    /// Decode when the outer stream has no separate closer (tests / fixed buffers).
    pub fn decodeNopClose(self: *UploadPackResponse, reader: *Reader) !void {
        var nop = ioutil.NopCloser{};
        try self.decode(reader, &nop);
    }

    /// go-git `(*UploadPackResponse).Encode`.
    pub fn encode(self: *UploadPackResponse, w: *Writer) !void {
        if (self.is_shallow) {
            try self.shallow_update.encode(w);
        }
        try self.server_response.encode(w, self.is_multi_ack);

        var err: ?anyerror = null;
        defer {
            if (self.r) |*rc| {
                ioutil.checkClose(rc, &err);
                self.r = null;
            }
        }

        if (self.r) |rc| {
            // Copy packfile bytes. `readSliceShort` returns 0 at EOF (not EndOfStream).
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = rc.reader.readSliceShort(&buf) catch |e| {
                    err = e;
                    break;
                };
                if (n == 0) break;
                w.writeAll(buf[0..n]) catch |e| {
                    err = e;
                    break;
                };
            }
        }

        if (err) |e| return e;
    }

    /// go-git `(*UploadPackResponse).Read`.
    ///
    /// Returns 0 at end of packfile (Zig short-read EOF).
    pub fn read(self: *UploadPackResponse, p: []u8) (Error || Reader.Error)!usize {
        const rc = self.r orelse return error.UploadPackResponseNotDecoded;
        if (p.len == 0) return 0;
        return rc.reader.readSliceShort(p);
    }

    /// Read all remaining packfile bytes (test helper; go-git `io.ReadAll`).
    pub fn readAll(self: *UploadPackResponse, allocator: Allocator) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);
        var buf: [1024]u8 = undefined;
        while (true) {
            const n = try self.read(&buf);
            if (n == 0) break;
            try list.appendSlice(allocator, buf[0..n]);
        }
        return try list.toOwnedSlice(allocator);
    }

    /// go-git `(*UploadPackResponse).Close`.
    pub fn close(self: *UploadPackResponse) anyerror!void {
        if (self.r) |rc| {
            self.r = null;
            return rc.close();
        }
    }
};

// ---------------------------------------------------------------------------
// Tests — port of uppackresp_test.go
// ---------------------------------------------------------------------------

test "Decode NAK then pack" {
    const gpa = testing.allocator;
    const raw = "0008NAK\nPACK";
    var req = UploadPackRequest.init(gpa);
    defer req.deinit();
    var res = UploadPackResponse.init(gpa, &req);
    defer res.deinit();

    var r: Reader = .fixed(raw);
    try res.decodeNopClose(&r);

    const pack = try res.readAll(gpa);
    defer gpa.free(pack);
    try testing.expectEqualStrings("PACK", pack);
}

test "Decode with depth (shallow flush + NAK)" {
    const gpa = testing.allocator;
    // shallow-update empty flush "0000" then NAK then PACK
    const raw = "00000008NAK\nPACK";
    var req = UploadPackRequest.init(gpa);
    defer req.deinit();
    req.upload_request.depth = .{ .commits = 1 };

    var res = UploadPackResponse.init(gpa, &req);
    defer res.deinit();

    var r: Reader = .fixed(raw);
    try res.decodeNopClose(&r);

    const pack = try res.readAll(gpa);
    defer gpa.free(pack);
    try testing.expectEqualStrings("PACK", pack);
}

test "Decode malformed ACK after shallow" {
    const gpa = testing.allocator;
    const raw = "00000008ACK\nPACK";
    var req = UploadPackRequest.init(gpa);
    defer req.deinit();
    req.upload_request.depth = .{ .commits = 1 };

    var res = UploadPackResponse.init(gpa, &req);
    defer res.deinit();

    var r: Reader = .fixed(raw);
    const result = res.decodeNopClose(&r);
    try testing.expect(std.meta.isError(result));
}

test "Decode multi_ack empty stream OK" {
    // go-git: multi_ack isn't fully implemented; empty stream still succeeds.
    const gpa = testing.allocator;
    var req = UploadPackRequest.init(gpa);
    defer req.deinit();
    try req.upload_request.capabilities.set(capability.MultiACK, &.{});

    var res = UploadPackResponse.init(gpa, &req);
    defer res.deinit();
    try testing.expect(res.is_multi_ack);

    var r: Reader = .fixed(&.{});
    try res.decodeNopClose(&r);
}

test "Read without decode fails" {
    const gpa = testing.allocator;
    var req = UploadPackRequest.init(gpa);
    defer req.deinit();
    try req.upload_request.capabilities.set(capability.MultiACK, &.{});

    var res = UploadPackResponse.init(gpa, &req);
    defer res.deinit();

    var buf: [1]u8 = undefined;
    try testing.expectError(error.UploadPackResponseNotDecoded, res.read(&buf));
}

test "Encode NAK with packfile" {
    const gpa = testing.allocator;
    var pack_storage = "[PACK]".*;
    var pack_reader: Reader = .fixed(&pack_storage);
    var nop = ioutil.NopCloser{};
    const pf = ioutil.newReadCloser(&pack_reader, &nop);

    var req = UploadPackRequest.init(gpa);
    defer req.deinit();
    var res = UploadPackResponse.initWithPackfile(gpa, &req, pf);
    defer res.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try res.encode(&aw.writer);
    try testing.expectEqualStrings("0008NAK\n[PACK]", aw.written());
}

test "Encode with depth prepends empty shallow flush" {
    const gpa = testing.allocator;
    var pack_storage = "PACK".*;
    var pack_reader: Reader = .fixed(&pack_storage);
    var nop = ioutil.NopCloser{};
    const pf = ioutil.newReadCloser(&pack_reader, &nop);

    var req = UploadPackRequest.init(gpa);
    defer req.deinit();
    req.upload_request.depth = .{ .commits = 1 };

    var res = UploadPackResponse.initWithPackfile(gpa, &req, pf);
    defer res.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try res.encode(&aw.writer);
    try testing.expectEqualStrings("00000008NAK\nPACK", aw.written());
}

test "Encode multi ACK without multi_ack capability fails" {
    const gpa = testing.allocator;
    var pack_storage = "[PACK]".*;
    var pack_reader: Reader = .fixed(&pack_storage);
    var nop = ioutil.NopCloser{};
    const pf = ioutil.newReadCloser(&pack_reader, &nop);

    var req = UploadPackRequest.init(gpa);
    defer req.deinit();
    var res = UploadPackResponse.initWithPackfile(gpa, &req, pf);
    defer res.deinit();

    // Two ACKs requires multi_ack — go-git returns error.MultiAckNotSupported.
    try res.server_response.acks.append(gpa, plumbing.newHash("5dc01c595e6c6ec9ccda4f6f69c131c0dd945f81"));
    try res.server_response.acks.append(gpa, plumbing.newHash("5dc01c595e6c6ec9ccda4f6f69c131c0dd945f82"));

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try testing.expectError(error.MultiAckNotSupported, res.encode(&aw.writer));
}

test "is_shallow and is_multi_ack flags from request" {
    const gpa = testing.allocator;
    {
        var req = UploadPackRequest.init(gpa);
        defer req.deinit();
        var res = UploadPackResponse.init(gpa, &req);
        defer res.deinit();
        try testing.expect(!res.is_shallow);
        try testing.expect(!res.is_multi_ack);
    }
    {
        var req = UploadPackRequest.init(gpa);
        defer req.deinit();
        req.upload_request.depth = .{ .commits = 3 };
        try req.upload_request.capabilities.set(capability.MultiACKDetailed, &.{});
        var res = UploadPackResponse.init(gpa, &req);
        defer res.deinit();
        try testing.expect(res.is_shallow);
        try testing.expect(res.is_multi_ack);
    }
}
