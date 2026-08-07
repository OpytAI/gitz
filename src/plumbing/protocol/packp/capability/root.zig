//! Pack protocol capabilities — port of go-git
//! `plumbing/protocol/packp/capability` (v5.19.2).
//!
//! Defines known capability names, validation maps, `DefaultAgent`, and an
//! ordered capability `List` (decode / encode / mutate).

const capability_mod = @import("capability.zig");
const list_mod = @import("list.zig");

// --- capability.go ---
pub const Capability = capability_mod.Capability;

pub const MultiACK = capability_mod.MultiACK;
pub const MultiACKDetailed = capability_mod.MultiACKDetailed;
pub const NoDone = capability_mod.NoDone;
pub const ThinPack = capability_mod.ThinPack;
pub const Sideband = capability_mod.Sideband;
pub const Sideband64k = capability_mod.Sideband64k;
pub const OFSDelta = capability_mod.OFSDelta;
pub const Agent = capability_mod.Agent;
pub const Shallow = capability_mod.Shallow;
pub const DeepenSince = capability_mod.DeepenSince;
pub const DeepenNot = capability_mod.DeepenNot;
pub const DeepenRelative = capability_mod.DeepenRelative;
pub const NoProgress = capability_mod.NoProgress;
pub const IncludeTag = capability_mod.IncludeTag;
pub const ReportStatus = capability_mod.ReportStatus;
pub const DeleteRefs = capability_mod.DeleteRefs;
pub const Quiet = capability_mod.Quiet;
pub const Atomic = capability_mod.Atomic;
pub const PushOptions = capability_mod.PushOptions;
pub const AllowTipSHA1InWant = capability_mod.AllowTipSHA1InWant;
pub const AllowReachableSHA1InWant = capability_mod.AllowReachableSHA1InWant;
pub const PushCert = capability_mod.PushCert;
pub const SymRef = capability_mod.SymRef;
pub const ObjectFormat = capability_mod.ObjectFormat;
pub const Filter = capability_mod.Filter;

pub const user_agent = capability_mod.user_agent;
pub const env_user_agent_extra = capability_mod.env_user_agent_extra;

pub const isKnown = capability_mod.isKnown;
pub const requiresArgument = capability_mod.requiresArgument;
pub const multipleArgument = capability_mod.multipleArgument;
pub const defaultAgent = capability_mod.defaultAgent;
pub const defaultAgentFromEnviron = capability_mod.defaultAgentFromEnviron;

// --- list.go ---
pub const List = list_mod.List;
pub const Error = list_mod.Error;
// Prefer `List.init(allocator)` / `List.init(allocator)` for construction.

test {
    _ = @import("capability.zig");
    _ = @import("list.zig");
}
