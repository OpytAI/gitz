//! Module storage re-export (implementation in `storage.zig` to avoid cycles).

const storage_mod = @import("storage.zig");

/// Generic factory: `ModuleStorageFor(fs.Mem)` / `ModuleStorageFor(fs.Os)`.
pub const ModuleStorageFor = storage_mod.ModuleStorageFor;
/// Mem specialisation (default).
pub const ModuleStorageMem = storage_mod.ModuleStorageMem;
/// Os specialisation.
pub const ModuleStorageOs = storage_mod.ModuleStorageOs;
/// Default export — Mem specialisation (backward compatible).
pub const ModuleStorage = ModuleStorageMem;
