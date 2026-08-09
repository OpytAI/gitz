const sha1cd = @import("sha1cd");

var input: [64]u8 = .{0} ** 64;
var digest: [sha1cd.Size]u8 = undefined;

export fn probe_input() [*]u8 {
    return &input;
}

export fn probe_sha1(len: u32) u32 {
    if (len > input.len) return 0;
    const result = sha1cd.sum(input[0..len]);
    digest = result[0];
    return 1;
}

export fn probe_digest() [*]const u8 {
    return &digest;
}
