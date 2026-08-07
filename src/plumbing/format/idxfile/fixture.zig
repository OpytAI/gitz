//! Large idx fixture and load helpers (go-git fixtureLarge4GB).
//! Kept out of root.zig so the package root stays API + light tests.

const std = @import("std");
const idxfile_mod = @import("idxfile.zig");
const decoder_mod = @import("decoder.zig");

const MemoryIndex = idxfile_mod.MemoryIndex;
const Decoder = decoder_mod.Decoder;

// ---------------------------------------------------------------------------
// Fixture: 4 GiB-scale idx with 64-bit offsets (go-git fixtureLarge4GB).
// ---------------------------------------------------------------------------

// Exact copy of go-git v5.19.2 fixtureLarge4GB (newlines stripped at decode).
const fixture_large_4gb_b64 =
    \\/3RPYwAAAAIAAAAAAAAAAAAAAAAAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEA
    \\AAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAA
    \\AAEAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAA
    \\AgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAADAAAAAwAAAAMAAAADAAAAAwAAAAQAAAAE
    \\AAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQA
    \\AAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABAAAAAQAAAAEAAAABQAA
    \\AAUAAAAFAAAABQAAAAUAAAAFAAAABQAAAAUAAAAFAAAABQAAAAUAAAAFAAAABQAAAAUAAAAFAAAA
    \\BQAAAAUAAAAFAAAABQAAAAUAAAAFAAAABQAAAAUAAAAFAAAABQAAAAUAAAAFAAAABQAAAAUAAAAF
    \\AAAABQAAAAUAAAAFAAAABQAAAAUAAAAFAAAABQAAAAUAAAAFAAAABQAAAAUAAAAFAAAABQAAAAUA
    \\AAAFAAAABQAAAAUAAAAFAAAABQAAAAUAAAAFAAAABQAAAAUAAAAFAAAABQAAAAUAAAAFAAAABQAA
    \\AAUAAAAFAAAABQAAAAYAAAAHAAAABwAAAAcAAAAHAAAABwAAAAcAAAAHAAAABwAAAAcAAAAHAAAA
    \\BwAAAAcAAAAHAAAABwAAAAcAAAAHAAAABwAAAAcAAAAHAAAABwAAAAcAAAAHAAAABwAAAAcAAAAH
    \\AAAABwAAAAcAAAAHAAAABwAAAAcAAAAHAAAABwAAAAcAAAAHAAAABwAAAAcAAAAHAAAABwAAAAcA
    \\AAAHAAAABwAAAAcAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAA
    \\AAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAA
    \\CAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAgAAAAIAAAACAAAAAkAAAAJ
    \\AAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkA
    \\AAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAAAAkAAAAJAAAACQAA
    \\AAkAAAAJA/yNWNRCZydO3vRYXq7rRFh50z8biZX1GYfYpEnKXqQ1ZZUQLcL71DA5U+WqRhwgOjJI
    \\IbwXF/m0//iVNYWL6cb1kUy+Z2hInEHraAmivOtSlnaOPZ9mE4fMv/GMTepsmX/XjI88606ky55K
    \\D3UXletByaTwe+dykOujJs3E0dYcWtJSJMy/CHMd0EG6tTBVrde8NYgnWKkixUqHTWsScuDR1iUB
    \\AIf3nJ4BrZ2PleFijdoCkp36qiGHwFa8NHxMnInZ0s3CKEKmHe+KcZPzuqwmm44GvqGAX3I/VYAA
    \\AAAAAAAMgAAAAQAAAI6AAAACgAAAA4AAAASAAAAFAAAAAV9Qam8AAAABYR1ShwAAAACdxfYxAAAA
    \\ANz1Di4AAAABPUnxJAAAAADNxzlGr6vCJpIFz4XaG/fi/f9C9zgQ8ptKSQpfQ1NMJBGTDTxxYGGp
    \\ch2xUA==
;

pub fn decodeFixtureLarge4gb(allocator: std.mem.Allocator) ![]u8 {
    // Strip newlines from multiline base64.
    var clean: std.ArrayListUnmanaged(u8) = .empty;
    defer clean.deinit(allocator);
    for (fixture_large_4gb_b64) |c| {
        if (c != '\n' and c != '\r' and c != ' ') try clean.append(allocator, c);
    }
    const dec = std.base64.standard.Decoder;
    const out_len = try dec.calcSizeForSlice(clean.items);
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);
    try dec.decode(out, clean.items);
    return out;
}

pub fn fixtureIndex(allocator: std.mem.Allocator) !MemoryIndex {
    const raw = try decodeFixtureLarge4gb(allocator);
    defer allocator.free(raw);
    var idx = MemoryIndex.init(allocator);
    errdefer idx.deinit();
    var r = std.Io.Reader.fixed(raw);
    var d = Decoder.init(&r);
    try d.decode(&idx);
    return idx;
}

pub const fixture_hashes = [_][]const u8{
    "303953e5aa461c203a324821bc1717f9b4fff895",
    "5296768e3d9f661387ccbff18c4dea6c997fd78c",
    "03fc8d58d44267274edef4585eaeeb445879d33f",
    "8f3ceb4ea4cb9e4a0f751795eb41c9a4f07be772",
    "e0d1d625010087f79c9e01ad9d8f95e1628dda02",
    "90eba326cdc4d1d61c5ad25224ccbf08731dd041",
    "bab53055add7bc35882758a922c54a874d6b1272",
    "1b8995f51987d8a449ca5ea4356595102dc2fbd4",
    "35858be9c6f5914cbe6768489c41eb6809a2bceb",
};

pub const fixture_offsets = [_]i64{
    12,
    142,
    1601322837,
    2646996529,
    3452385606,
    3707047470,
    5323223332,
    5894072943,
    5924278919,
};

