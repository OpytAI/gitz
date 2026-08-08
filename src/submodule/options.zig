//! Submodule update options (go-git `options.go` SubmoduleUpdateOptions).

const transport = @import("transport");
const server = @import("server");

/// go-git `SubmoduleRescursivity` — recursion depth for nested submodule ops.
pub const SubmoduleRecursivity = u32;

/// go-git `NoRecurseSubmodules` — disable recursion.
pub const no_recurse_submodules: SubmoduleRecursivity = 0;

/// go-git `DefaultSubmoduleRecursionDepth`.
pub const default_submodule_recursion_depth: SubmoduleRecursivity = 10;

/// go-git `SubmoduleUpdateOptions`.
///
/// # Fetch path
///
/// When `no_fetch` is false, `Update` opens a remote via `//src/remote` and
/// fetches into the module object store. Auth and depth are forwarded fully
/// into `remote.FetchOptions.transport.auth` and `remote.FetchOptions.depth`.
///
/// | Field | Role |
/// |-------|------|
/// | `auth` | Optional transport auth (go-git `Auth`). |
/// | `depth` | Shallow fetch depth (go-git `Depth`; 0 = full). |
/// | `embedded` | In-process `server.Server` (MapLoader tests). Null → registry. |
/// | `remote_url` | Borrowed URL override. Empty → submodule config URL. |
///
/// `remote_url` and config URL strings are **borrowed**: `putRemoteFull` copies
/// them into module config ownership. Callers keep their own slices valid only
/// for the duration of `Update` (then the config owns its copy).
///
/// # Recursion
///
/// When `recurse_submodules > 0`, Update discovers nested modules from the
/// `.gitmodules` blob at the checked-out commit in module storage (object
/// graph; no nested worktree FS required). Each nested gitlink is updated
/// with depth − 1. Zero means no recursion (go-git `NoRecurseSubmodules`).
pub const SubmoduleUpdateOptions = struct {
    /// When true, call Init if the submodule is not yet initialized.
    init: bool = false,
    /// Skip fetch from the remote (go-git `NoFetch`).
    no_fetch: bool = false,
    /// Nested submodule recursion depth (go-git `RecurseSubmodules`).
    recurse_submodules: SubmoduleRecursivity = no_recurse_submodules,
    /// Auth for remote fetch (go-git `Auth`) → `FetchOptions.transport.auth`.
    auth: ?transport.AuthMethod = null,
    /// Fetch depth limit (go-git `Depth`) → `FetchOptions.depth`.
    depth: i32 = 0,
    /// In-process server for hermetic fetch (tests / MapLoader). When null,
    /// fetch uses registered transport clients / URL schemes via remote.
    /// Not owned by this options struct.
    embedded: ?*server.Server = null,
    /// Override remote URL (else submodule config URL). Borrowed, not owned.
    remote_url: []const u8 = "",
};
