//! SHA-1 block compression with collision detection (portable path).
//!
//! Port of github.com/pjbgf/sha1cd `blockGeneric` / `checkCollision` / `hasCollided`.

const std = @import("std");
const ubc = @import("ubc.zig");

pub const rounds: usize = 80;
pub const pre_step_state: usize = 3;
pub const word_buffers: usize = 5;
pub const block_size: usize = 64;

const K0: u32 = 0x5A827999;
const K1: u32 = 0x6ED9EBA1;
const K2: u32 = 0x8F1BBCDC;
const K3: u32 = 0xCA62C1D6;

inline fn rotl(x: u32, n: u5) u32 {
    return std.math.rotl(u32, x, n);
}

inline fn rotr(x: u32, n: u5) u32 {
    return std.math.rotr(u32, x, n);
}

inline fn loadBeWord(p: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, p[i * 4 ..][0..4], .big);
}

/// Portable block compression with collision detection.
/// Updates chaining values `h` and sets `col` when a near-collision is mitigated.
pub fn blockGeneric(h: *[word_buffers]u32, col: *bool, p_in: []const u8) void {
    var p = p_in;
    var w: [16]u32 = undefined;
    var cs: [pre_step_state][word_buffers]u32 = undefined;

    var h0 = h[0];
    var h1 = h[1];
    var h2 = h[2];
    var h3 = h[3];
    var h4 = h[4];

    while (p.len >= block_size) {
        var m1: [rounds]u32 = undefined;
        var hi: u32 = 1;

        rehash: while (true) {
            var a = h0;
            var b = h1;
            var c = h2;
            var d = h3;
            var e = h4;

            var i: usize = 0;
            cs[0] = .{ a, b, c, d, e };

            while (i < 16) : (i += 1) {
                w[i] = loadBeWord(p, i);
                const f = (b & c) | ((~b) & d);
                const t = rotl(a, 5) +% f +% e +% w[i & 0xf] +% K0;
                e = d;
                d = c;
                c = rotl(b, 30);
                b = a;
                a = t;
                m1[i] = w[i & 0xf];
            }
            while (i < 20) : (i += 1) {
                const tmp = w[(i -% 3) & 0xf] ^ w[(i -% 8) & 0xf] ^ w[(i -% 14) & 0xf] ^ w[i & 0xf];
                w[i & 0xf] = rotl(tmp, 1);
                const f = (b & c) | ((~b) & d);
                const t = rotl(a, 5) +% f +% e +% w[i & 0xf] +% K0;
                e = d;
                d = c;
                c = rotl(b, 30);
                b = a;
                a = t;
                m1[i] = w[i & 0xf];
            }
            while (i < 40) : (i += 1) {
                const tmp = w[(i -% 3) & 0xf] ^ w[(i -% 8) & 0xf] ^ w[(i -% 14) & 0xf] ^ w[i & 0xf];
                w[i & 0xf] = rotl(tmp, 1);
                const f = b ^ c ^ d;
                const t = rotl(a, 5) +% f +% e +% w[i & 0xf] +% K1;
                e = d;
                d = c;
                c = rotl(b, 30);
                b = a;
                a = t;
                m1[i] = w[i & 0xf];
            }
            while (i < 60) : (i += 1) {
                if (i == 58) cs[1] = .{ a, b, c, d, e };
                const tmp = w[(i -% 3) & 0xf] ^ w[(i -% 8) & 0xf] ^ w[(i -% 14) & 0xf] ^ w[i & 0xf];
                w[i & 0xf] = rotl(tmp, 1);
                const f = ((b | c) & d) | (b & c);
                const t = rotl(a, 5) +% f +% e +% w[i & 0xf] +% K2;
                e = d;
                d = c;
                c = rotl(b, 30);
                b = a;
                a = t;
                m1[i] = w[i & 0xf];
            }
            while (i < 80) : (i += 1) {
                if (i == 65) cs[2] = .{ a, b, c, d, e };
                const tmp = w[(i -% 3) & 0xf] ^ w[(i -% 8) & 0xf] ^ w[(i -% 14) & 0xf] ^ w[i & 0xf];
                w[i & 0xf] = rotl(tmp, 1);
                const f = b ^ c ^ d;
                const t = rotl(a, 5) +% f +% e +% w[i & 0xf] +% K3;
                e = d;
                d = c;
                c = rotl(b, 30);
                b = a;
                a = t;
                m1[i] = w[i & 0xf];
            }

            h0 +%= a;
            h1 +%= b;
            h2 +%= c;
            h3 +%= d;
            h4 +%= e;

            // Near-collision mitigation: compress the same block three times.
            if (hi == 2) {
                hi += 1;
                continue :rehash;
            }
            if (hi == 1) {
                if (checkCollision(m1, cs, .{ h0, h1, h2, h3, h4 })) {
                    col.* = true;
                    hi += 1;
                    continue :rehash;
                }
            }
            break :rehash;
        }

        p = p[block_size..];
    }

    h.* = .{ h0, h1, h2, h3, h4 };
}

fn checkCollision(
    m1: [rounds]u32,
    cs: [pre_step_state][word_buffers]u32,
    state: [word_buffers]u32,
) bool {
    const mask = ubc.calculateDvMask(&m1);
    if (mask == 0) return false;

    for (ubc.sha1Dvs()) |dv| {
        if (dv.dv_type == 0) break;
        if ((mask & (@as(u32, 1) << @intCast(dv.mask_b))) == 0) continue;
        const cs_state: [word_buffers]u32 = switch (dv.test_t) {
            58 => cs[1],
            65 => cs[2],
            0 => cs[0],
            else => unreachable,
        };
        if (hasCollided(dv.test_t, m1, dv.dm, cs_state, state)) return true;
    }
    return false;
}

fn hasCollided(
    step: u32,
    m1: [rounds]u32,
    dm: [rounds]u32,
    state: [word_buffers]u32,
    h: [word_buffers]u32,
) bool {
    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];

    // Undo compression steps from the saved pre-step state back to round 0.
    undoRounds(&a, &b, &c, &d, &e, step, m1, dm, 64, 60, K3, .xor);
    undoRounds(&a, &b, &c, &d, &e, step, m1, dm, 59, 40, K2, .maj);
    undoRounds(&a, &b, &c, &d, &e, step, m1, dm, 39, 20, K1, .xor);
    {
        var i: u32 = 20;
        while (i > 0) {
            const j = i - 1;
            rotateUndo(&a, &b, &c, &d, &e);
            if (step > j) {
                b = rotr(b, 30);
                const f = (b & c) | ((~b) & d);
                e -%= rotl(a, 5) +% f +% K0 +% (m1[j] ^ dm[j]);
            }
            i = j;
        }
    }

    var ihv: [word_buffers]u32 = .{ a, b, c, d, e };
    a = state[0];
    b = state[1];
    c = state[2];
    d = state[3];
    e = state[4];

    // Recompress forward from the DV test step.
    recompress(&a, &b, &c, &d, &e, step, m1, dm, 40, 60, K2, .maj);
    recompress(&a, &b, &c, &d, &e, step, m1, dm, 60, 80, K3, .xor);

    ihv[0] +%= a;
    ihv[1] +%= b;
    ihv[2] +%= c;
    ihv[3] +%= d;
    ihv[4] +%= e;

    return ((ihv[0] ^ h[0]) | (ihv[1] ^ h[1]) | (ihv[2] ^ h[2]) | (ihv[3] ^ h[3]) | (ihv[4] ^ h[4])) == 0;
}

const FKind = enum { xor, maj };

inline fn rotateUndo(a: *u32, b: *u32, c: *u32, d: *u32, e: *u32) void {
    const ea = a.*;
    a.* = b.*;
    b.* = c.*;
    c.* = d.*;
    d.* = e.*;
    e.* = ea;
}

fn fOf(kind: FKind, b: u32, c: u32, d: u32) u32 {
    return switch (kind) {
        .xor => b ^ c ^ d,
        .maj => ((b | c) & d) | (b & c),
    };
}

fn undoRounds(
    a: *u32,
    b: *u32,
    c: *u32,
    d: *u32,
    e: *u32,
    step: u32,
    m1: [rounds]u32,
    dm: [rounds]u32,
    from: u32,
    to_inclusive: u32,
    k: u32,
    kind: FKind,
) void {
    var i = from;
    while (true) : (i -%= 1) {
        rotateUndo(a, b, c, d, e);
        if (step > i) {
            b.* = rotr(b.*, 30);
            const f = fOf(kind, b.*, c.*, d.*);
            e.* -%= rotl(a.*, 5) +% f +% k +% (m1[i] ^ dm[i]);
        }
        if (i == to_inclusive) break;
    }
}

fn recompress(
    a: *u32,
    b: *u32,
    c: *u32,
    d: *u32,
    e: *u32,
    step: u32,
    m1: [rounds]u32,
    dm: [rounds]u32,
    from: u32,
    to_exclusive: u32,
    k: u32,
    kind: FKind,
) void {
    var i = from;
    while (i < to_exclusive) : (i += 1) {
        if (step > i) continue;
        const f = fOf(kind, b.*, c.*, d.*);
        const t = rotl(a.*, 5) +% f +% e.* +% k +% (m1[i] ^ dm[i]);
        e.* = d.*;
        d.* = c.*;
        c.* = rotl(b.*, 30);
        b.* = a.*;
        a.* = t;
    }
}
