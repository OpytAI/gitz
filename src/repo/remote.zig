//! Config-only Remote handle (go-git `Remote` without transport).
//!
//! Fetch/List/Push live in phase 11. Fields are public; use `.config` / `.name()`.

const memory = @import("memory");

/// go-git `Remote` shell: storer + borrowed config pointer.
pub const Remote = struct {
    /// Borrowed storage (not owned).
    storer: *memory.Storage,
    /// Borrowed remote config (in repository Config map, or AnonymousRemote heap).
    config: *const memory.RemoteConfig,

    /// Remote name (`config.name`).
    pub fn name(self: *const Remote) []const u8 {
        return self.config.name;
    }
};

/// go-git `NewRemote`.
pub fn newRemote(s: *memory.Storage, c: *const memory.RemoteConfig) Remote {
    return .{ .storer = s, .config = c };
}
