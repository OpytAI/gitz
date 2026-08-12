//! gitz `utils/sync` — free lists for buffers and zlib writers.
//!
//! Port of go-git package `github.com/go-git/go-git/v5/utils/sync`.
//!
//! # Threading model
//!
//! Go uses `sync.Pool`. This Zig port uses **single-threaded free lists**.
//! Concurrent get/put from multiple threads is not supported. Documented
//! single-threaded free lists are OK for the current sequential port.
//!
//! # Zig module import
//!
//! Prefer `@import("utils/sync")` (Bazel `import_name`). Avoid bare `sync` as
//! an import name; it is easy to confuse with language-level synchronization.
//!
//! # Pools
//!
//! | Helper | Go analogue |
//! |--------|-------------|
//! | `getBytesBuffer` / `putBytesBuffer` | `GetBytesBuffer` / `PutBytesBuffer` |
//! | `getByteSlice` / `putByteSlice` | `GetByteSlice` / `PutByteSlice` |
//! | `getZlibWriter` / `putZlibWriter` | `GetZlibWriter` / `PutZlibWriter` |
//! | `getBufioReader` / `putBufioReader` | `GetBufioReader` / `PutBufioReader` |
//!
//! Zlib uses `std.compress.flate` with container `.zlib` (no `std.compress.zlib`
//! in Zig 0.16).
//!
//! # Process lifecycle (hosts)
//!
//! Free lists are **process-scoped**. `put*` returns nodes to package-level
//! lists; nodes stay allocated until `deinitPools`.
//!
//! - Call `deinitPools(allocator)` once at host/engine shutdown (or end of a
//!   leak-checked test), with the **same allocator** used for every get/put.
//! - Do **not** call `deinitPools` from `Repository.deinit` /
//!   `PlainRepository.deinit`: multi-repo hosts share one process pool, and
//!   draining on each repo close thrashes free lists and races other repos.
//! - After network use, also call transport `client.deinit()` (see
//!   `//src/plumbing/transport/client`) so the protocol registry and default
//!   clients are released. That is separate from pool drain.
//!
//! ## Allocator identity (native GPA vs freestanding wasm)
//!
//! | Host | Allocator | Leak checking |
//! |------|-----------|---------------|
//! | Native tests / tools | `std.testing.allocator` or a process GPA | `deinitPools` required for zero leaks |
//! | Freestanding wasm examples | `std.heap.wasm_allocator` | No GPA; still drain on engine close so free-list nodes are not retained across module lifetime |
//!
//! Mixing allocators between get/put and `deinitPools` is undefined (nodes
//! freed with the wrong allocator). Prefer one process allocator for all
//! pool traffic.

const std = @import("std");
const Allocator = std.mem.Allocator;

const bytes_mod = @import("bytes.zig");
const zlib_mod = @import("zlib.zig");
const bufio_mod = @import("bufio.zig");

// --- bytes ---
pub const byte_slice_len = bytes_mod.byte_slice_len;
pub const BytesBuffer = bytes_mod.BytesBuffer;
pub const getBytesBuffer = bytes_mod.getBytesBuffer;
pub const putBytesBuffer = bytes_mod.putBytesBuffer;
pub const getByteSlice = bytes_mod.getByteSlice;
pub const putByteSlice = bytes_mod.putByteSlice;

// --- zlib ---
pub const ZlibWriter = zlib_mod.ZlibWriter;
pub const ZlibReader = zlib_mod.ZlibReader;
pub const getZlibReader = zlib_mod.getZlibReader;
pub const putZlibReader = zlib_mod.putZlibReader;
pub const getZlibWriter = zlib_mod.getZlibWriter;
pub const putZlibWriter = zlib_mod.putZlibWriter;

// --- bufio ---
pub const bufio_buffer_len = bufio_mod.bufio_buffer_len;
pub const BufioReader = bufio_mod.BufioReader;
pub const getBufioReader = bufio_mod.getBufioReader;
pub const putBufioReader = bufio_mod.putBufioReader;

/// Release every free-list entry retained by this package.
///
/// Pass the same `allocator` used for get/put. Safe to call when pools are
/// empty. See package docs for host shutdown rules.
pub fn deinitPools(allocator: Allocator) void {
    bytes_mod.deinitBytesPools(allocator);
    zlib_mod.deinitZlibPools(allocator);
    bufio_mod.deinitBufioPools(allocator);
}

/// RAII helper for tests and short-lived hosts: `defer guard.deinit()`.
pub const PoolGuard = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) PoolGuard {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PoolGuard) void {
        deinitPools(self.allocator);
        self.* = undefined;
    }
};

test {
    _ = @import("free_list.zig");
    _ = bytes_mod;
    _ = zlib_mod;
    _ = bufio_mod;
}

test "smoke getBytesBuffer putBytesBuffer round trip" {
    const gpa = std.testing.allocator;
    defer deinitPools(gpa);

    const a = try getBytesBuffer(gpa);
    try a.appendSlice(gpa, "gitz");
    putBytesBuffer(a);
    const b = try getBytesBuffer(gpa);
    try std.testing.expect(a == b);
    try std.testing.expectEqual(@as(usize, 0), b.items.len);
    putBytesBuffer(b);
}

test "smoke getZlibWriter putZlibWriter round trip" {
    const gpa = std.testing.allocator;
    defer deinitPools(gpa);

    var out_buf: [2048]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const w = try getZlibWriter(gpa, &out);
    try w.writer().writeAll("x");
    try w.finish();
    putZlibWriter(w);

    var out2_buf: [2048]u8 = undefined;
    var out2: std.Io.Writer = .fixed(&out2_buf);
    const w2 = try getZlibWriter(gpa, &out2);
    try std.testing.expect(w == w2);
    putZlibWriter(w2);
}

test "PoolGuard drains free lists under testing allocator" {
    const gpa = std.testing.allocator;
    {
        var guard = PoolGuard.init(gpa);
        defer guard.deinit();
        const buf = try getBytesBuffer(gpa);
        try buf.appendSlice(gpa, "pool-guard");
        putBytesBuffer(buf);
    }
    // Second guard must see an empty free list after the first drained.
    {
        var guard = PoolGuard.init(gpa);
        defer guard.deinit();
        const a = try getBytesBuffer(gpa);
        const b = try getBytesBuffer(gpa);
        try std.testing.expect(a != b);
        putBytesBuffer(a);
        putBytesBuffer(b);
    }
}
