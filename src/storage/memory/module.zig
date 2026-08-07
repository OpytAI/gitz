//! Module storage re-export (implementation lives in `storage.zig` to avoid cycles).

const storage_mod = @import("storage.zig");

pub const ModuleStorage = storage_mod.ModuleStorage;
