//! File transport server helpers
//! (go-git `plumbing/transport/file/server.go`).
//!
//! Serve upload-pack / receive-pack for a local path over caller-provided
//! stdio (`transport_common.ServerCommand`). Hermetic: uses
//! `server.newDefaultLoader` (host FS) or a caller-supplied loader.

const std = @import("std");
const transport = @import("transport");
const common = @import("transport_common");
const server = @import("server");
const fs = @import("fs");

const Allocator = std.mem.Allocator;

/// go-git `ServeUploadPack` for `path`, writing through `cmd` stdio.
///
/// Uses host filesystem loader rooted at `/` (go-git `DefaultServer`).
pub fn serveUploadPack(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    cmd: common.ServerCommand,
) !void {
    var base: fs.Os = undefined;
    var loader = try server.newDefaultLoader(allocator, io, &base);
    defer base.deinit();

    var ep = try transport.newEndpoint(allocator, io, path);
    defer ep.deinit();

    var srv = server.newServer(allocator, loader.asLoader());
    var sess = try srv.newUploadPackSession(&ep, null);
    defer sess.close();

    try common.serveUploadPack(allocator, cmd, &sess);
}

/// go-git `ServeReceivePack` for `path`.
pub fn serveReceivePack(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    cmd: common.ServerCommand,
) !void {
    var base: fs.Os = undefined;
    var loader = try server.newDefaultLoader(allocator, io, &base);
    defer base.deinit();

    var ep = try transport.newEndpoint(allocator, io, path);
    defer ep.deinit();

    var srv = server.newServer(allocator, loader.asLoader());
    var sess = try srv.newReceivePackSession(&ep, null);
    defer sess.close();

    try common.serveReceivePack(allocator, cmd, &sess);
}

/// Serve upload-pack with an explicit loader (hermetic MapLoader tests).
pub fn serveUploadPackWithLoader(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    loader: server.Loader,
    cmd: common.ServerCommand,
) !void {
    var ep = try transport.newEndpoint(allocator, io, path);
    defer ep.deinit();

    var srv = server.newServer(allocator, loader);
    var sess = try srv.newUploadPackSession(&ep, null);
    defer sess.close();

    try common.serveUploadPack(allocator, cmd, &sess);
}

/// Serve receive-pack with an explicit loader (hermetic MapLoader tests).
pub fn serveReceivePackWithLoader(
    allocator: Allocator,
    io: std.Io,
    path: []const u8,
    loader: server.Loader,
    cmd: common.ServerCommand,
) !void {
    var ep = try transport.newEndpoint(allocator, io, path);
    defer ep.deinit();

    var srv = server.newServer(allocator, loader);
    var sess = try srv.newReceivePackSession(&ep, null);
    defer sess.close();

    try common.serveReceivePack(allocator, cmd, &sess);
}
