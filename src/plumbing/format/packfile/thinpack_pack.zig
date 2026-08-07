//! thinpack ee4fef0e…
//! Size: 2461 bytes. Decoded from standard base64 at first access.
const std = @import("std");

const b64 =
    "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"
    ++ "MiHZS5XeH1176A==";

var decoded: [2461]u8 = undefined;
var ready: bool = false;

/// Full pack bytes (lazy base64 decode into static storage).
pub fn data() []const u8 {
    if (!ready) {
        const n = std.base64.standard.Decoder.calcSizeForSlice(b64) catch unreachable;
        _ = std.base64.standard.Decoder.decode(decoded[0..n], b64) catch unreachable;
        ready = true;
    }
    return decoded[0..];
}
