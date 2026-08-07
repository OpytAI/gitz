//! Thin Remote handle (go-git `Remote` without fetch/push bodies).
//!
//! Phase 10: construction + config access only. Fetch/List/Push are phase 11.

const memory = @import("memory");

/// go-git `Remote` config-only shell (no transport).
pub const Remote = struct {
    /// Borrowed storage (not owned).
    storer: *memory.Storage,
    /// Borrowed remote config living in the repository Config map (not owned).
    config: *const memory.RemoteConfig,

    /// go-git `Remote.Config` — remote configuration.
    pub fn remoteConfig(self: *const Remote) *const memory.RemoteConfig {
        return self.config;
    }

    /// Convenience: remote name.
    pub fn name(self: *const Remote) []const u8 {
        return self.config.name;
    }
};

/// go-git `NewRemote`.
pub fn newRemote(s: *memory.Storage, c: *const memory.RemoteConfig) Remote {
    return .{ .storer = s, .config = c };
}
