//! gitz — Git in Zig (full port of go-git v5.19.2).
//!
//! # Layout
//! Package paths under `src/` mirror go-git. Prefer importing leaf packages
//! (`plumbing`, `hash`, `filemode`, …) over this root for library use.
//! `//src:gitz` re-exports foundation modules for convenience and smoke tests.

const std = @import("std");

pub const name = "gitz";
pub const version = "0.0.0";
pub const go_git_pin = "v5.19.2";

pub const plumbing = @import("plumbing");
pub const hash = @import("hash");
pub const filemode = @import("filemode");
pub const color = @import("color");
pub const binary = @import("binary");
/// Free lists (go-git `utils/sync`). Imported as `utils/sync` in leaf code.
pub const sync = @import("utils/sync");
pub const ioutil = @import("ioutil");
pub const trace = @import("trace");

// Git format codecs.
pub const pktline = @import("pktline");
pub const objfile = @import("objfile");
pub const config_format = @import("config");
pub const idxfile = @import("idxfile");

// Packfiles and the Git index.
pub const packfile = @import("packfile");
/// Git index (dircache) codec (go-git plumbing/format/index).
pub const index_format = @import("index");

// Storage contracts and implementations.
pub const storer = @import("storer");
pub const cache = @import("cache");
pub const storage = @import("storage");
/// In-memory storage backend (go-git `storage/memory`). Import name from package.
pub const memory_storage = @import("memory");

// Protocol and transport core.
pub const capability = @import("capability");
pub const sideband = @import("sideband");
pub const packp = @import("packp");
pub const transport = @import("transport");
pub const transport_client = @import("client");
pub const transport_server = @import("server");
pub const transport_common = @import("transport_common");

// Diff, attributes, revision, and tree utilities.
pub const pathutil = @import("pathutil");
pub const internal_url = @import("url");
pub const internal_reference = @import("internal_reference");
pub const revision = @import("revision");
pub const utils_diff = @import("diff");
pub const format_diff = @import("format_diff");
pub const gitignore = @import("gitignore");
pub const gitattributes = @import("gitattributes");
pub const merkletrie = @import("merkletrie");
pub const noder = @import("noder");
pub const merkletrie_index = @import("merkletrie_index");
pub const merkletrie_filesystem = @import("merkletrie_filesystem");

// Typed configuration and repository APIs.
/// High-level repository config (go-git `config`). Import name `gitconfig`.
pub const gitconfig = @import("gitconfig");
pub const repo = @import("repo");

// Remote fetch, list, and push.
pub const remote = @import("remote");

// Worktree and porcelain operations.
pub const worktree = @import("worktree");
pub const porcelain = @import("porcelain");

// Concrete transports and higher-level Git operations.
pub const transport_file = @import("transport_file");
pub const transport_git = @import("transport_git");
pub const transport_http = @import("transport_http");
pub const transport_ssh = @import("transport_ssh");
pub const serverinfo = @import("serverinfo");
pub const submodule = @import("submodule");
pub const blame = @import("blame");
pub const prune = @import("prune");

test "identity" {
    try std.testing.expectEqualStrings("gitz", name);
    try std.testing.expectEqualStrings("v5.19.2", go_git_pin);
}

test "foundation surface" {
    try std.testing.expect(plumbing.ZeroHash.isZero());
    try std.testing.expectEqual(@as(usize, 20), hash.Size);
    try std.testing.expectEqual(@as(filemode.FileMode, 0o100644), filemode.Regular);
    try std.testing.expect(std.mem.startsWith(u8, color.Reset, "\x1b"));
    try std.testing.expect(binary.ErrIntegerOverflow == binary.Error.IntegerOverflow);
    try std.testing.expectEqual(@as(usize, 16 * 1024), sync.byte_slice_len);
    var empty = ioutil.newReaderFromBuf(&.{});
    try std.testing.expectError(error.EmptyReader, ioutil.nonEmptyReader(&empty));
    try std.testing.expect(!trace.enabled(trace.general));
}

test "leaf codec surface" {
    try std.testing.expectEqual(@as(usize, 65516), pktline.MaxPayloadSize);
    try std.testing.expectEqual(@as(u32, 2), idxfile.VersionSupported);
    _ = objfile.Reader.open;
    _ = objfile.Writer.open;
    _ = config_format.Config.init;
}

test "packfile read surface" {
    try std.testing.expectEqual(@as(u32, 2), packfile.VersionSupported);
    try std.testing.expectEqualSlices(u8, "PACK", &packfile.signature);
    _ = packfile.Scanner.init;
    _ = packfile.Parser.init;
    _ = packfile.Packfile.init;
    _ = packfile.patchDelta;
    _ = packfile.applyDelta;
}

test "index and pack encoder surface" {
    try std.testing.expectEqual(@as(u32, 4), index_format.EncodeVersionSupported);
    try std.testing.expectEqualSlices(u8, "DIRC", &index_format.index_signature);
    _ = index_format.Index.init;
    _ = index_format.Decoder.init;
    _ = index_format.Encoder.init;
    _ = packfile.Encoder.init;
    _ = packfile.diffDelta;
    _ = packfile.getDelta;
    _ = packfile.ObjectToPack;
}

test "storer memory cache surface" {
    try std.testing.expectEqual(@as(usize, 1024), storer.MaxResolveRecursion);
    try std.testing.expect(storer.Error.Stop == storer.Error.Stop);
    try std.testing.expect(storage.Error.ReferenceHasChanged == storage.Error.ReferenceHasChanged);
    try std.testing.expectEqual(cache.DefaultMaxSize, @as(cache.FileSize, 96 * cache.MiByte));
    _ = cache.ObjectLru.initDefault;
    _ = cache.BufferLru.initDefault;
    _ = memory_storage.Storage.init;
    _ = storer.resolveReference;
    _ = storer.newEncodedObjectSliceIter;
    _ = storer.newReferenceSliceIter;
}

test "protocol transport surface" {
    try std.testing.expectEqualStrings("multi_ack", capability.MultiACK);
    try std.testing.expectEqual(@as(usize, 1000), sideband.MaxPackedSize);
    try std.testing.expectEqualStrings("git-upload-pack", transport.UploadPackServiceName);
    _ = packp.AdvRefs;
    _ = packp.AdvRefs.init;
    _ = transport.newEndpoint;
    _ = transport.filterUnsupportedCapabilities;
    _ = transport_client.installProtocol;
    _ = transport_client.newClient;
    _ = transport_server.newServer;
    _ = transport_server.MapLoader;
    _ = transport_common.newClient;
}

test "config and repository facade surface" {
    _ = gitconfig.Config;
    _ = gitconfig.RemoteConfig;
    _ = gitconfig.Branch;
    _ = gitconfig.RefSpec;
    _ = gitconfig.OptBool;
    _ = gitconfig.newConfig;
    _ = gitconfig.readConfig;
    _ = gitconfig.loadConfig;
    _ = gitconfig.paths;
    try std.testing.expectEqual(@as(u32, 10), gitconfig.default_pack_window);

    _ = repo.Repository;
    _ = repo.newRepository;
    _ = repo.init;
    _ = repo.open;
    _ = repo.LogOptions;
    _ = repo.LogOrder;
    _ = repo.Remote;
    _ = repo.CreateTagOptions;
    _ = repo.CreateTagOptions.validate;
    _ = repo.plainInit;
    _ = repo.plainOpen;
    _ = repo.PlainInitOptions;
    _ = repo.PlainOpenOptions;
    _ = repo.configScopedFromLocal;
    _ = repo.Repository.commitObject;
    _ = repo.Repository.blobObject;
    _ = repo.Repository.treeObject;
    _ = repo.Repository.tagObject;
    _ = repo.Repository.object;
    _ = repo.Repository.log;
    _ = repo.Repository.resolveRevision;
    _ = repo.Repository.branches;
    _ = repo.Repository.tags;
    _ = repo.Repository.notes;
    _ = repo.Repository.createRemote;
    _ = repo.Repository.createBranch;
    _ = repo.Repository.createTag;
    _ = repo.Repository.configScoped;
    _ = repo.Repository.worktreeFs;
}

test "remote surface" {
    _ = remote.Remote;
    _ = remote.newRemote;
    _ = remote.newRemoteEmbedded;
    _ = remote.freeReferences;
    _ = remote.FetchOptions;
    _ = remote.PushOptions;
    _ = remote.ListOptions;
    _ = remote.TagMode;
    _ = remote.PeelingOption;
    _ = remote.ForceWithLease;
    _ = remote.PushOption;
    _ = remote.SessionOpts;
    _ = remote.openUploadPack;
    _ = remote.openReceivePack;
    try std.testing.expectEqualStrings("origin", remote.default_remote_name);
    const e: remote.Error = error.AlreadyUpToDate;
    try std.testing.expect(e == error.AlreadyUpToDate);
    _ = remote.Remote.list;
    _ = remote.Remote.fetch;
    _ = remote.Remote.push;
    _ = remote.Remote.string;
    _ = repo.Repository.fetch;
    _ = repo.Repository.push;
    _ = repo.FetchOptions;
    _ = repo.PushOptions;
}

test "worktree porcelain surface" {
    _ = worktree.Worktree;
    _ = worktree.newWorktree;
    _ = worktree.CloneOptions;
    _ = worktree.CheckoutOptions;
    _ = worktree.ResetOptions;
    _ = porcelain.clone;
    _ = porcelain.cloneEmbedded;
    _ = porcelain.plainClone;
    _ = porcelain.plainCloneEmbedded;
    _ = porcelain.cloneInto;
    _ = porcelain.OwnedRepository;
    _ = porcelain.CloneOptions;
    _ = repo.Repository.worktreeFs;
    _ = repo.Repository.worktree;
    _ = repo.Repository.worktreeEmbedded;
    _ = repo.worktreeOf;
    _ = repo.worktreeEmbedded;
}

test "transport and extra package surface" {
    _ = transport_file.defaultClient;
    _ = transport_git.DefaultPort;
    _ = transport_http.BasicAuth;
    _ = transport_ssh.DefaultPort;
    _ = serverinfo.updateServerInfo;
    _ = submodule.Submodule;
    _ = blame.blame;
    _ = prune.prune;
}
