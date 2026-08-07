//! Packfile constants (go-git `plumbing/format/packfile/common.go`).
//!
//! Wire-format masks stay package-private (scanner only). Root re-exports
//! the few constants external callers need.

/// Pack signature bytes: `PACK`.
pub const signature = [_]u8{ 'P', 'A', 'C', 'K' };

/// Only pack version supported (go-git `VersionSupported`).
pub const VersionSupported: u32 = 2;

// Object header bit layout (go-git firstLengthBits / mask*).
pub const first_length_bits: u3 = 4;
pub const length_bits: u3 = 7;
pub const mask_first_length: u8 = 15;
pub const mask_continue: u8 = 0x80;
pub const mask_length: u8 = 127;
pub const mask_type: u8 = 112;

/// Parser prealloc hint cap (go-git `maxObjectsPrealloc`).
pub const max_objects_prealloc: usize = 1 << 16;
/// Content prealloc hint cap (go-git `maxObjectPreallocBytes`).
pub const max_object_prealloc_bytes: usize = 1 << 30;
/// Max OFS/REF delta chain depth (go-git `maxDeltaChainDepth` = 4095).
pub const max_delta_chain_depth: usize = 4095;
