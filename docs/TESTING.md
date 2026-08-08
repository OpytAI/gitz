# Testing conventions

gitz tests are Bazel `zig_test` targets. Prefer hermetic, deterministic tests
(no network, no host FS except when the package under test is the Os backend).

## Layout

| Kind | Where | Bazel |
|------|--------|--------|
| **Unit** | Co-located `*_test.zig` next to production sources | Same package `zig_test` (often same `main = root.zig` + `_SRCS`) |
| **Shared suite / fixtures** | `src/<area>/test/` as a **test-only library** | e.g. `//src/storage:storage_suite`, `//src/plumbing/transport/test:fixtures` |
| **Cross-package e2e / integration** | `src/<go-git-area>/test/` matching go-git’s `…/test` packages | Dedicated `zig_test` in that package; **never** a dep of production libraries |

### Rules

1. **Production `zig_library` targets must not depend on test packages.**  
   Prefer a separate test main (e.g. `server_test_root.zig`) that imports
   `*_test.zig` + fixtures, so production `root.zig` never pulls test-only
   imports into dependents.

2. **Fixtures live under `…/test/`**, not copied into every `*_test.zig`.  
   Import a fixtures library (e.g. `transport_test_fixtures` from
   `//src/plumbing/transport/test:fixtures`).

3. **Name test files**  
   - Unit: `<module>_test.zig` or tests inside the module when tiny.  
   - E2e: descriptive (`serve_e2e.zig`).  
   - Test entry: `<package>_test_root.zig` when the package root must stay clean.

4. **go-git parity**  
   Prefer the same relative package as go-git when it has a `test` subtree  
   (`plumbing/transport/test` → `src/plumbing/transport/test`).

5. **Gates**  
   Phase suites under `//check:phase_N` list every package `zig_test` that must
   stay green for that phase, including e2e packages.

### Transport example (phase 8)

```
src/plumbing/transport/server/
  root.zig              # production only
  loader.zig / server.zig
  server_test.zig       # unit tests
  server_test_root.zig  # zig_test main → root + server_test

src/plumbing/transport/test/
  fixtures.zig          # shared memory-repo helpers
  serve_e2e.zig         # server + common cross-package e2e
  BUILD.bazel           # :fixtures (lib) + :transport_test
```

## Ownership in tests

When using type-erased APIs (`RepoStorer`, etc.), follow the production ownership
contract (see package docs). Prefer DebugAllocator / `std.testing.allocator` so
leaks fail the test.

## Goldens (Class A)

Static fixtures under `data/goldens/<name>/` with `meta.yaml`.

Class A files: `type: file_equals` with committed `actual.txt` / `expected.txt`
(inventory + byte equality via `//check:goldens_smoke`).

**Executable recomputation:** `//tools/golden:recompute_test` loads each suite’s
`expected.txt` from runfiles and rebuilds the non-comment payload from library
APIs (`utils/diff`, pathutil, revision, gitignore, gitattributes, format/diff,
merkletrie). A regression fails the recompute test even if someone edits
`actual.txt` and `expected.txt` in lockstep.

---

## Phase 9 — Diff / status shell

**Gate:** `//check:phase_9`  
**Purpose:** Merkle tree diffs, ignore/attributes, unified diffs, path security,
revision strings, and endpoint URL helpers that later worktree/status code needs.

### Packages (go-git → gitz)

| go-git | gitz | Role |
|--------|------|------|
| `utils/merkletrie` | `src/utils/merkletrie` | DiffTree, Change, Iter |
| `utils/merkletrie/noder` | `src/utils/merkletrie/noder` | Noder + Path |
| `utils/merkletrie/index` | `src/utils/merkletrie/index` | Index-backed noder |
| `utils/merkletrie/filesystem` | `src/utils/merkletrie/filesystem` | FS-backed noder |
| `utils/merkletrie/internal/frame` | `src/utils/merkletrie/internal/frame` | Sorted children frame |
| `utils/merkletrie/internal/fsnoder` | `src/utils/merkletrie/internal/fsnoder` | Test-only tree notation (`test_only`) |
| `plumbing/format/gitignore` | `src/plumbing/format/gitignore` | Pattern, Matcher, dir loaders |
| `plumbing/format/gitattributes` | `src/plumbing/format/gitattributes` | Pattern, Matcher, dir loaders |
| `plumbing/format/diff` | `src/plumbing/format/diff` | UnifiedEncoder, ColorConfig, Patch types |
| `utils/diff` | `src/utils/diff` | Line-oriented Myers (`Do` / `DoWithTimeout`) |
| `internal/pathutil` | `src/internal/pathutil` | NTFS/HFS/dotgit + ValidTreePath security |
| `internal/path_util` | `src/internal/path_util` | Tilde / home expansion |
| `internal/revision` | `src/internal/revision` | gitrevisions parser |
| `internal/url` | `src/internal/url` | Scheme / SCP-like / local endpoint |
| `internal/reference` | `src/internal/reference` | Stable reference name sort |

Package unit tests register under `//check:phase_9_packages` in
`check/BUILD.bazel` (transitive via `//check:phase_9` → phase_8 → … → phase_g).

### Class A goldens (phase 9)

All under `data/goldens/`; each has `meta.yaml` + matching `actual.txt` /
`expected.txt`.

| Suite | Locks |
|-------|--------|
| `pathutil_ntfs_dotgit` | `IsNTFSDotGit` + `WindowsValidPath` tables (go-git `ntfs_test.go`) |
| `pathutil_tree_reject` | `ValidTreePath` reject/accept paths including NTFS disguise and HFS+ ZWNJ (go-git `tree_test.go`) |
| `gitignore_simple` | `ParsePattern` + `Match` (classic `*.o`, `!` inclusion, wildcards, `**`) |
| `gitattributes_simple` | gitattributes `ParsePattern.Match` (domain, simple, glob) |
| `revision_parse` | `Parser.Parse` valid component dumps + invalid reason strings (go-git `parser_test.go`) |
| `diff_do_equal` | `utils/diff` Myers ops for equal / insert / delete / mixed |
| `unified_diff_one_line` | `UnifiedEncoder` classic hello/world → hello/bug wire |
| `merkletrie_empty` | DiffTree empty / empty-dir pairs → 0 changes |
| `merkletrie_insert` | DiffTree inserts + `NewInsert` string form |
| `merkletrie_modify_delete` | DiffTree modify/delete/mix + `NewDelete` / `NewModify` strings |

**Not Class A (covered by unit tests only):**

- gitignore / gitattributes **dir loaders** (`ReadPatterns`, `LoadGlobalPatterns`,
  `LoadSystemPatterns`) — need an in-memory FS layout; co-located in
  `dir.zig` tests.
- pathutil **HFS full tables** (`IsHFSDotGit`, `IsHFSDot`, `IsHFSDotGitmodules`) —
  full tables in `hfs.zig` unit tests; `pathutil_tree_reject` already locks the
  HFS ZWNJ tree-path rejects that matter for security.
- `internal/url`, `internal/path_util`, `internal/reference` — pure tables in
  package unit tests (no separate golden dirs).

Phase 9 adds **10** Class A dirs (see `inventories/metrics.yaml` `goldens.min_count`,
total suite **47** including earlier phases).

### Key unit suites

| Area | Target | What to look for |
|------|--------|------------------|
| format/diff (one-chunk + more) | `//src/plumbing/format/diff:diff_test` | UnifiedEncoder fixtures: empty, binary, rename, one-line change, color, context 0–6, custom prefixes |
| utils/diff Myers | `//src/utils/diff:diff_test` | `Do` round-trip, exact hunks, `DoWithTimeout` unlimited vs short deadline |
| pathutil security | `//src/internal/pathutil:pathutil_test` | NTFS/HFS/dotgit tables; `ValidTreePath` full table |
| path_util | `//src/internal/path_util:path_util_test` | `~/` expansion vs bare `~` / `~user` |
| gitignore | `//src/plumbing/format/gitignore:gitignore_test` | Pattern match matrix; Matcher; Dir loaders |
| gitattributes | `//src/plumbing/format/gitattributes:gitattributes_test` | Pattern match; attributes parse; Dir loaders |
| merkletrie | `//src/utils/merkletrie:merkletrie_test` | DiffTree empty/basic/insert/crazy/cancel; Change strings; Iter |
| merkletrie adapters | `//src/.../noder|index|filesystem|frame|fsnoder` tests | Path compare, index/fs Diff, frame sort, fsnoder notation |
| revision | `//src/internal/revision:revision_test` | Scanner tokens; Parse valid/invalid; parseAt/Caret/Tilde/Colon/Ref |
| url | `//src/internal/url:url_test` | Scheme, SCP-like (incl. reject local paths / Windows drive), components, local endpoint |
| reference | `//src/internal/reference:reference_test` | Name sort / sortPtrs |

### How to run

Shared Bazel cache (see `AGENTS.md`):

```bash
cd /mnt/workspace/gitz/gitz-phase-9   # or develop after merge

bazel --output_user_root=/mnt/workspace/gitz/bazel-cache test //check:phase_9

# Package slice only (no prior-phase suite):
bazel --output_user_root=/mnt/workspace/gitz/bazel-cache test //check:phase_9_packages

# Class A goldens alone:
bazel --output_user_root=/mnt/workspace/gitz/bazel-cache test //check:goldens_smoke
```

Merge-complete on `develop` also requires `current_phase: 9` in
`inventories/packages.yaml` so file/API inventory enforce phase ≤ 9 packages
(already set on this phase branch).

---

## Phase 10 — Typed config + repository core

**Gate:** `//check:phase_10`  
**Purpose:** go-git `config` package (typed remotes/branches/URLs/modules) and
root repository Init/Open (memory + PlainInit/PlainOpen on `fs.Mem`), object/ref
facades, Log, CreateTag, and configScoped. No full Worktree engine, PlainClone,
or Remote fetch/push (phases 11–12).

### SHA-256 object format (runtime dual)

gitz supports **both** SHA-1 and SHA-256 object formats in one binary (go-git uses
compile tags). Process-wide format lives in `//src/plumbing/hash`:

| API | Role |
|-----|------|
| `setObjectFormat(.sha1 \| .sha256)` | Activate format for digests / `Hash` wire length |
| `objectFormat()` / `digestSize()` / `hexSize()` | Query active format |
| `supportsObjectFormat` | Always true for both algorithms in gitz |
| `Size` / `HexSize` | Default-tag docs constants (20 / 40) |
| `MaxSize` / `MaxHexSize` | Storage capacity (32 / 64) |

`plumbing.Hash` stores `[MaxSize]u8` **zero-padded**. Equality / map keys use the
full 32-byte buffer (format-independent). `slice` / hex formatting use process
`digestSize()` (active wire width).

**Per-repo format:** `memory.Storage` / `filesystem.Storage` own `hash_algo`.
`newEncodedObject` stamps `MemoryObject.hash_algo`; `hash()` uses
`computeHashAlgo` so two storages can compute SHA-1 and SHA-256 OIDs without
clobbering each other. `setHashAlgo` / `activateFormat` also publish the format
for process-wide wire codecs (pack/index/tree read width). Call
`storage.activateFormat()` when switching repos on a thread before wire I/O.
Tests that flip process format must `defer setObjectFormat(.sha1)`.

**Wire formats that follow active OID width:** trees, loose objects, pack trailers
+ pack scanner hasher, idx OID names, dircache index, commit-graph (hash version
1/2 + trailer), packp framing (`hashSize()`), merkletrie composites.

**PlainInit:** validates `object_format` ∈ {`""`, `sha1`, `sha256`}; sha256 sets
version 1 + extensions and activates SHA-256. Unknown values → `InvalidObjectFormat`.
If dual support is compiled out → `SHA256NotSupported` (go-git parity).
**PlainOpen** re-applies format from config onto storage.

**FormatScope:** `plumbing.FormatScope.enter(algo)` RAII restores the previous
process format on `deinit` (tests / temporary codec work).

### Packages (go-git → gitz)

| go-git | gitz | Role |
|--------|------|------|
| `config` | `src/config` (`import_name = gitconfig`) | Typed Config, RemoteConfig, Branch, RefSpec, URL, Modules, OptBool |
| root repository (partial) | `src/repo` | Full phase-10 repository surface (see below) |

`//src/plumbing/format/config` remains `@import("config")` (format codec).  
High-level config is `@import("gitconfig")`.

### Repository surface (`src/repo`)

| Area | API | Notes |
|------|-----|--------|
| Lifecycle (memory) | `newRepository`, `init`, `initWithOptions`, `open` | `*memory.Storage`; bare when worktree is null |
| Lifecycle (plain) | `plainInit`, `plainInitWithOptions`, `plainOpen`, `plainOpenWithOptions` | `fs.Mem` + filesystem storage; owns `PlainRepository` |
| Config | `config`, `setConfig`, `configScoped` | Storer `memory.Config`; scoped merge via `gitconfig.loadConfig` |
| Refs | `head`, `reference`, `references`, `branches`, `tags`, `notes` | Filtered ref iters |
| Worktree probe | `isBare`, `setIsBare`, `worktreeFs` | Optional `?*fs.Mem` only (no Worktree engine) |
| Remotes (config) | `remote`, `remotes`, `createRemote`, `createRemoteFull`, `createRemoteAnonymous`, `deleteRemote` | Fetch/Push added in phase 11 |
| Branches (config) | `branch`, `createBranch`, `deleteBranch` | Tracking config, not ref creation |
| Tags | `tag`, `createTag`, `deleteTag` | Lightweight or annotated |
| CreateTagOptions | `tagger`, `message`, `sign_key`, `pgp_signature`, `validate` | Empty tagger loads author then user from storer config (`loadConfigTagger`); `sign_key` = Entity ArmoredDetachSign |
| OpenPGP | `Entity` + subkeys, `readArmoredKeyRing`, `decrypt`, `armoredDetachSign`, `encodeArmor` | S2K simple/salted/iterated; AES-128/192/256; SHA-1/256/512; signing prefers flagged subkeys |
| Objects | `commitObject`, `blobObject`, `treeObject`, `tagObject`, `object` | Plus store iters (`commitObjects`, …) |
| Log | `log` + `LogOptions` / `LogOrder` / `LogResult` | All orders; `all`; `file_name`; `path_filter` / `path_filter_ctx_fn`; `since`/`until` |
| Revision | `resolveRevision` | Refs, hash, `~`/`^`, `^{/pattern}` (literal/simple) |

### Class A goldens (phase 10)

Static `file_equals` plus **executable** recompute in `//tools/golden:recompute_test`
(rebuilds the same non-comment payload from library APIs).

| Suite | Locks |
|-------|--------|
| `gitconfig_new_defaults` | `Config.create` pack window + empty maps + not bare |
| `gitconfig_marshal_core` | Empty `Marshal` → `[core]` + tab-indented `bare = false` |
| `repo_init_bare` | bare `init`: `is_bare`, symbolic HEAD → `refs/heads/master` |
| `repo_init_nonbare` | non-bare `init` with worktree: not bare, symbolic HEAD → `refs/heads/master` |
| `repo_open_head` | bare `init` then `open`: exists, symbolic HEAD → `refs/heads/master` |
| `repo_object_getters` | bare `init`, empty blob store + `blobObject` → fixed SHA-1 OID |

### How to run

```bash
cd /mnt/workspace/gitz/gitz-phase-10   # or develop after merge

bazel --output_user_root=/mnt/workspace/gitz/bazel-cache test //check:phase_10

# Package slice only:
bazel --output_user_root=/mnt/workspace/gitz/bazel-cache test //check:phase_10_packages
```

Merge-complete on `develop` also requires `current_phase: 10` in
`inventories/packages.yaml` (set on this phase branch).

---

## Phase 11 — Remote engine

**Gate:** `//check:phase_11`  
**Purpose:** go-git root `remote.go` + remote-related `options.go` types —
`Remote` List / Fetch / Push over transport sessions. Integration uses an
in-process `server` + `MapLoader` (no real internet). `Repository.fetch` /
`Repository.push` resolve the named remote and delegate.

### Packages (go-git → gitz)

| go-git | gitz | Role |
|--------|------|------|
| root `remote.go` (+ remote options) | `src/remote` (`import_name = remote`) | List / Fetch / Push, options, ref match, session open |

### Remote surface (`src/remote`)

| Area | API | Notes |
|------|-----|--------|
| Handle | `Remote`, `newRemote`, `newRemoteEmbedded` | Public fields; `embedded` binds in-process `server.Server` |
| Display | `Remote.string`, `Remote.name` | go-git `String`; config via public `.config` |
| List | `Remote.list` + `ListOptions` / `PeelingOption` | Owned `[]Reference`; free with `freeReferences` |
| Fetch | `Remote.fetch` + `FetchOptions` / `TagMode` | Pack ingest, tracking refs, `updateShallow`, prune |
| Push | `Remote.push` + `PushOptions` / `ForceWithLease` / `PushOption` | Commands + pack; follow-tags via `isAncestor` |
| Session | `openUploadPack`, `openReceivePack`, `SessionOpts` | TLS/proxy applied to `Endpoint`; embedded or registry |
| Refs | `calculateRefs`, `getWants`, `getHaves`, `isFastForward` | Refspec expand + commit-walk FF |
| Repo glue | `Repository.fetch`, `Repository.push` | Validate options → lookup remote → delegate |

### Class A goldens (phase 11)

Static `file_equals` plus **executable** recompute in `//tools/golden:recompute_test`.

| Suite | Locks |
|-------|--------|
| `remote_string` | `Remote.string` for single URL (fetch + push lines) |
| `remote_fetch_options_defaults` | `FetchOptions.validate` → `origin` + `following` |
| `remote_default_fetch_refspec` | `default_fetch_ref_spec` formatted for `origin` |

Integration unit tests (not Class A dumps) cover List/Fetch/Push and
ForceWithLease reject over MapLoader in `//src/remote:remote_test`.

### How to run

```bash
cd /mnt/workspace/gitz/gitz-phase-11   # or develop after merge

bazel --output_user_root=/mnt/workspace/gitz/bazel-cache test //check:phase_11

# Package slice only:
bazel --output_user_root=/mnt/workspace/gitz/bazel-cache test //check:phase_11_packages
bazel --output_user_root=/mnt/workspace/gitz/bazel-cache test //src/remote:remote_test
```

Merge-complete on `develop` also requires `current_phase: 11` in
`inventories/packages.yaml` (set on this phase branch).
