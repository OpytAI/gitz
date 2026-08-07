//! plumbing/cache — object and buffer LRU caches (go-git `plumbing/cache`).
//!
//! # Threading model
//!
//! go-git uses `sync.Mutex` on each LRU. This Zig port is **single-threaded**
//! (same model as `utils/sync` free lists). Concurrent access is not supported.
//!
//! # Surface
//!
//! | go-git | Zig |
//! |--------|-----|
//! | `FileSize`, `Byte`…`GiByte`, `DefaultMaxSize` | same names (`common.zig`) |
//! | `NewObjectLRU` / `NewObjectLRUDefault` | `ObjectLru.init` / `initDefault` |
//! | `ObjectLRU.Put` / `Get` / `Clear` | `ObjectLru.put` / `get` / `clear` |
//! | `NewBufferLRU` / `NewBufferLRUDefault` | `BufferLru.init` / `initDefault` |
//! | `BufferLRU.Put` / `Get` / `Clear` | `BufferLru.put` / `get` / `clear` |

const std = @import("std");

const common = @import("common.zig");
const object_lru = @import("object_lru.zig");
const buffer_lru = @import("buffer_lru.zig");

pub const FileSize = common.FileSize;
pub const Byte = common.Byte;
pub const KiByte = common.KiByte;
pub const MiByte = common.MiByte;
pub const GiByte = common.GiByte;
pub const DefaultMaxSize = common.DefaultMaxSize;

pub const ObjectLru = object_lru.ObjectLru;
pub const BufferLru = buffer_lru.BufferLru;

test {
    _ = @import("common.zig");
    _ = @import("object_lru.zig");
    _ = @import("buffer_lru.zig");
}
