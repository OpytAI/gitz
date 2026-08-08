//! High-level git repository configuration — port of go-git `config` package.
//!
//! Import this package as **`gitconfig`** (`import_name = "gitconfig"`).
//! The format codec remains `@import("config")` (`//src/plumbing/format/config`).
//!
//! Reference: go-git v5.19.2 `config/*.go`.

const config_mod = @import("config.zig");
const optbool_mod = @import("optbool.zig");
const refspec_mod = @import("refspec.zig");
const branch_mod = @import("branch.zig");
const url_mod = @import("url.zig");
const modules_mod = @import("modules.zig");
const storer_mod = @import("storer.zig");

// --- config.go ---
pub const Config = config_mod.Config;
pub const RemoteConfig = config_mod.RemoteConfig;
pub const Core = config_mod.Core;
pub const Identity = config_mod.Identity;
pub const Pack = config_mod.Pack;
pub const Init = config_mod.Init;
pub const Extensions = config_mod.Extensions;
pub const Scope = config_mod.Scope;
pub const Error = config_mod.Error;
pub const ConfigError = config_mod.ConfigError;

pub const default_fetch_ref_spec = config_mod.default_fetch_ref_spec;
pub const default_push_ref_spec = config_mod.default_push_ref_spec;
pub const default_pack_window = config_mod.default_pack_window;

pub const newConfig = config_mod.newConfig;
pub const readConfig = config_mod.readConfig;
pub const loadConfig = config_mod.loadConfig;
pub const paths = config_mod.paths;
pub const ConfigStorer = storer_mod.ConfigStorer;

// --- optbool.go ---
pub const OptBool = optbool_mod.OptBool;
pub const parseConfigBool = optbool_mod.parseConfigBool;

// --- refspec.go ---
pub const RefSpec = refspec_mod.RefSpec;
pub const matchAny = refspec_mod.matchAny;

// --- branch.go ---
pub const Branch = branch_mod.Branch;

// --- url.go ---
pub const URL = url_mod.URL;
pub const findLongestInsteadOfMatch = url_mod.findLongestInsteadOfMatch;

// --- modules.go ---
pub const Modules = modules_mod.Modules;
pub const Submodule = modules_mod.Submodule;
pub const unmarshalSubmodules = modules_mod.unmarshalSubmodules;

test {
    _ = @import("optbool.zig");
    _ = @import("refspec.zig");
    _ = @import("branch.zig");
    _ = @import("url.zig");
    _ = @import("modules.zig");
    _ = @import("config.zig");
    _ = @import("owned.zig");
    _ = @import("storer.zig");
}
