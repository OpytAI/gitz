//! storage — repository storage façade (go-git `storage` package).
//!
//! Holds cross-backend errors and re-exports the memory backend. Filesystem
//! and transactional storers are provided by their respective packages.
//!
//! # go-git interfaces (method sets in Zig)
//!
//! - **Storer** — EncodedObject + Reference + Shallow + Index + Config + Module
//! - **ModuleStorer** — `module(name) → Storer` for submodule storage

const std = @import("std");

/// go-git `storage.ErrReferenceHasChanged`.
pub const Error = error{
    /// Concurrent reference update lost the race (check-and-set failed).
    ReferenceHasChanged,
};

/// Memory storage backend (go-git `storage/memory`).
pub const memory = @import("memory");

/// Concrete repository storage (implements go-git `Storer` method set).
pub const Storage = memory.Storage;
pub const newStorage = memory.newStorage;

/// Alias for go-git `storage.Storer` (concrete backends; no Go interface).
pub const Storer = Storage;

/// go-git `ModuleStorer` method set: backends that expose nested storages via `module`.
/// Concrete form is `Storage.module` on the memory (and later filesystem) backends.
pub const ModuleStorer = struct {
    /// Method name documentation (go-git `Module(name string) (Storer, error)`).
    pub const method_module = "module";
};

test "ReferenceHasChanged error name" {
    const e: Error = error.ReferenceHasChanged;
    try std.testing.expect(e == error.ReferenceHasChanged);
}

test "memory surface" {
    try std.testing.expect(@TypeOf(memory.newStorage) != void);
    try std.testing.expect(@TypeOf(Storer.init) != void);
    try std.testing.expectEqualStrings("module", ModuleStorer.method_module);
}
