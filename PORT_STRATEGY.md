# gitz port strategy

**Status:** analysis complete (go-git `v5.19.2`). Phase plan is separate and comes next.  
**Pin:** see `GO_GIT_PIN.md`.  
**Goal:** full behavioral port of go-git into Zig, under Bazel + rules_zig (Zig 0.16), with strict automated guardrails.

This document is the strategy. It does not list every phase deliverable. Phases will reference this document.

---

## 1. What we are porting

| Fact | Value |
|------|--------|
| Source | go-git v5.19.2 (`3eeb238d…`) |
| Size | ~248 production `.go` files, ~192 tests, ~60 packages |
| License | Apache 2.0 (acceptable; libgit2 is not the target) |
| Model | Pure library: plumbing + porcelain; extensible storer / FS / transport |
| Incomplete by design | FF-only merge; no pack protocol v2; no multi_ack client; no LFS; `file://` may shell out to `git` |

**Rule:** match go-git behavior and incompleteness unless a later phase deliberately expands beyond go-git. Do not invent a different Git model.

### Architecture (dependency layers)

```
L0  hash, Hash/OID, ObjectType, filemode, utils/binary, zlib pools
L1  format codecs: pktline, objfile, idxfile, index, config, packfile (read→write)
L2  storer contracts + storage/memory + cache
L3  object decode/encode + revlist + commitgraph v2
L4  filesystem storage (dotgit) + FS abstraction (billy equivalent)
L5  packp + sideband + transport interfaces (+ in-memory server)
L6  merkletrie + gitignore/gitattributes + pathutil (security)
L7  config/ typed model + repository open/init
L8  remote (fetch/list → push)
L9  worktree (status/add/commit → checkout/reset → clone/pull)
L10 submodules, prune/repack, blame, network transports (http/ssh)
```

Parallel agents work **within one layer/phase**, never across unfinished lower layers for merge-ready code.

---

## 2. Zig way vs Go way

We port **behavior and package seams**, not Go’s method soup.

| Go pattern | Zig approach |
|------------|--------------|
| Large `Repository` method sets | Thin `Repository` holding storer + optional worktree; free functions in modules (`repo`, `remote`, `worktree`) |
| Interfaces (`Storer`, billy, `Noder`) | Small explicit traits: `anytype` + comptime checks for monomorphized call sites; vtables only where runtime plug-in is required |
| Closed set of backends | Prefer `union(enum) { memory, filesystem, transactional }` early; open vtables later if needed |
| `io.Reader` chains | `std.Io` / reader-writer anytype; explicit buffer ownership |
| `sync.Pool` | Free lists / arena recycle (`utils/sync` equivalent) |
| Dual `Foo` / `FooContext` | One API with cancel token only on network boundaries |
| OpenPGP in options | `Signer` interface; crypto adapters optional |
| Build-tag SHA-256 OID size | Start SHA-1 (`[20]u8`); plan runtime or comptime object-format without freezing the wrong API |

**Zig-native defaults (allowed):**

- `defer` and explicit allocators (`std.mem.Allocator` on APIs that allocate).
- Error sets / error unions instead of `error` interfaces.
- Packed structs and `@bitCast` for binary formats where safe.
- Table-driven tests and `std.testing`.
- No goroutines unless a later phase needs concurrent pack write; sequential first is fine.

**Not allowed as “Zig style” excuses:**

- Skipping path safety (`pathutil` / protectNTFS / HFS).
- Plain SHA-1 without documenting a temporary downgrade from sha1cd.
- Hardcoding only `std.fs` with no FS trait (blocks memfs tests and extension model).
- Redesigning pack/index/ref semantics for “simplicity.”

---

## 3. Guardrail philosophy

Human process is weak at scale. **Bazel is the process.**

| Principle | Meaning |
|-----------|---------|
| Inventories are build targets | Missing surface fails `bazel test`, not a spreadsheet |
| Goldens beat vibes | Bytes in → structure/bytes out must match fixtures |
| Phase gates | Phase N merge requires `//check:phase_N` (or equivalent package) green |
| No silent skip | Disabling a check needs an explicit `TODO` allowlist entry with owner and phase |
| Reference is pinned | Inventories and fixtures resolve against `go-git/` at the pin in `GO_GIT_PIN.md` |
| Optional capability flags | Like go-git type-asserts: skip only when the backend declares “no PackfileWriter” |

Three permanent check classes (from `AGENTS.md`):

1. **File inventory** — package/module surface vs go-git  
2. **Function / API inventory** — exported symbols and storer methods  
3. **Behavioral goldens** — codecs, suites, end-to-end scenarios  

---

## 4. Bazel enforcement design

### 4.1 Workspace layout (target)

```
gitz-develop/                 # worktree (example)
  MODULE.bazel                # rules_zig, Zig 0.16 toolchain
  .bazelrc                    # common flags; always document output_user_root
  AGENTS.md
  GO_GIT_PIN.md
  PORT_STRATEGY.md
  inventories/                # machine-readable manifests (source of truth)
    packages.yaml             # go package → zig package → phase id
    api/                      # per-package expected exports
    allowlists/               # intentional gaps (phase-scoped)
  tools/
    inventory/                # small generators/checkers (Go or Zig or Python)
    golden/                   # helpers to refresh goldens (never auto in CI)
  src/                        # Zig library (mirrors go-git paths)
    plumbing/...
    storage/...
    utils/...
    config/
    git/                      # porcelain (or repo/ remote/ worktree/)
  testdata/
    goldens/                  # committed expected outputs
    fixtures/                 # vendored or generated from go-git-fixtures
  check/                      # Bazel packages that ONLY run guardrails
```

Sibling (outside git tree of gitz):

```
../go-git/                    # pinned reference clone (read-only for port)
```

Bazel may read `../go-git` via a repository rule or `local_repository` / filegroup that pins the path. Prefer a **workspace-relative** data path declared in MODULE/WORKSPACE so checks fail if the pin checkout moves.

### 4.2 Shared Bazel invocation

Every command:

```bash
bazel --output_user_root=/mnt/workspace/gitz/bazel-cache <cmd>
```

Use rules_zig’s Zig 0.16 toolchain only. Forbid system `zig` in genrules and tests.

### 4.3 File inventory (`//check:file_inventory`)

**Input:**

- `inventories/packages.yaml` — one row per go-git production package in scope  
- Tree of `src/**`  
- Phase id (e.g. `--phase=3` or select via Bazel target `//check:file_inventory_phase_3`)

**Logic (genrule or `py_test` / `sh_test`):**

1. Load packages required for phases `≤ current`.  
2. For each required package, assert expected Zig package dir and/or marker file exists.  
3. Fail on **missing** required packages.  
4. Fail on **unexpected** top-level packages not in the inventory (drift control).  
5. Packages marked `status: deferred` must not appear until their phase (or must live under `src/…` only when phase allows).

**Not a substitute for goldens.** Empty `root.zig` can satisfy file inventory; goldens and API inventory catch hollow packages.

### 4.4 Function / API inventory (`//check:api_inventory`)

**Input:**

- `inventories/api/<package>.yaml` listing required exports, e.g.:

```yaml
package: plumbing/format/pktline
phase: 1
require:
  types: [Encoder, Scanner, ErrorLine]
  functions: [NewEncoder, NewScanner]
  constants: [MaxPayloadSize, FlushPkt]
  # Zig may rename constructors; map explicitly:
  zig_map:
    NewEncoder: pktline.Encoder.init
    NewScanner: pktline.Scanner.init
```

**Logic:**

1. Parse Zig AST or a generated `exports.json` from each package (prefer a small checker that reads `exports.json` produced by a Zig build step or grep conventions).  
2. Assert every `require` entry maps to a real export via `zig_map` or same name.  
3. Phase-scoped: only packages with `phase ≤ N` are mandatory.  
4. Storer interfaces get a **method matrix** inventory (EncodedObjectStorer, ReferenceStorer, …) shared by memory and filesystem backends.

**Zig naming freedom:** inventories use **semantic IDs** (`storer.encoded_object.set`) plus optional Zig path. Ports may use free functions; they must still satisfy the semantic ID.

### 4.5 Behavioral goldens (`//check/goldens/...`)

#### Class A — pure codec goldens (highest ROI, earliest)

| Area | Input | Assert |
|------|--------|--------|
| pktline | byte streams | scan/encode round-trip |
| binary / VLQ | integers | exact bytes |
| objfile | loose object files | type, size, hash, payload |
| idxfile | `.idx` from fixtures | offsets, CRCs, fanout |
| index | `.git/index` fixtures | entries, extensions subset |
| packfile | pack bytes | scan headers, delta apply, object payloads |
| config format | gitconfig text | section tree |
| object text | commit/tree/tag blobs | field equality |
| packp | pkt-line message corpora | struct equality + re-encode |
| pathutil | path strings | accept/reject tables (security) |
| revision | rev strings | AST / resolve against fixture repo |

**Sources of truth (in order):**

1. Existing go-git unit test vectors (extract to `testdata/goldens`).  
2. `go-git-fixtures` packs and repos (vendor selected fixtures under `testdata/fixtures`, do not depend on network).  
3. Optional **oracle mode**: genrule runs a tiny Go helper in `tools/` against pinned go-git and writes expected JSON; committed goldens must match. Oracle is for **refresh**, not a runtime dependency of default tests (keeps gitz tests pure Zig).

#### Class B — suite goldens (storage / protocol without network)

- Port `storage/test` BaseStorageSuite as parameterized Zig tests over memory (then filesystem).  
- Packp session over in-memory pipes + `transport/server` once storer + pack exist.  
- merkletrie: known tree pairs → change lists.

#### Class C — scenario goldens (porcelain)

- Init/open, status/add/commit loop, fetch/list, checkout matrix, submodule status strings.  
- Assert **Git-visible state**: refs, object IDs, index, worktree files, config text — not internal Go field layout.

### 4.6 Phase gate targets

```text
//check:phase_0   # foundation inventories + hash/oid goldens
//check:phase_1   # includes phase_0 + codec goldens…
…
//check:all       # full inventories + all goldens for completed phases
```

**Merge rule:** a phase worktree merges to `develop` only when its phase gate is green under:

```bash
bazel --output_user_root=/mnt/workspace/gitz/bazel-cache test //check:phase_N
```

### 4.7 Allowlists (escape hatches that stay honest)

`inventories/allowlists/phase_N.yaml`:

```yaml
# Temporary only. Each entry needs reason + remove_by_phase.
- id: packfile.Encoder.window
  reason: read path first
  remove_by_phase: 4
```

Checker fails if `remove_by_phase ≤ current_phase` still present. No silent `# bazel: disable`.

### 4.8 What not to put only in markdown

- Manual “we should test X” lists without a target  
- Inventory tables that are not machine-read  
- “Remember to use sha1cd” without a test that collision-detection hooks exist or a documented allowlist  

---

## 5. Package mapping (skeleton)

Mirror go-git paths under `src/` so file inventory is mechanical:

| go-git | gitz Zig | Early phase |
|--------|----------|-------------|
| `plumbing`, `plumbing/hash`, `filemode` | `src/plumbing/...` | yes |
| `utils/binary`, `utils/sync` | `src/utils/...` | yes |
| `plumbing/format/*` | `src/plumbing/format/*` | yes (codec order) |
| `plumbing/storer`, `storage/*` | `src/plumbing/storer`, `src/storage/*` | after formats |
| `plumbing/object` | `src/plumbing/object` | after pack read + storer |
| `plumbing/protocol/packp` | `src/plumbing/protocol/packp` | after pktline |
| `plumbing/transport/*` | `src/plumbing/transport/*` | after packp; network last |
| `utils/merkletrie` | `src/utils/merkletrie` | before status |
| `internal/pathutil`, `revision`, `url` | `src/internal/...` | with worktree / remote |
| `config` | `src/config` | after format/config |
| root `package git` | `src/repo`, `src/remote`, `src/worktree` (Zig split) | last |

**Exclude from default inventories:** `_examples/`, `cli/`, `internal/test`, transport test helper packages (or mark `test_only`).

**Prefer commitgraph v2 only** (v1 deprecated in go-git).

---

## 6. Critical design seams (implement early)

### 6.1 Hash / OID

- Default: collision-detecting SHA-1 (sha1cd semantics).  
- `RegisterHash` equivalent for tests and future SHA-256.  
- Golden: known object header+body → OID; optional collision fixture if portable.

### 6.2 Filesystem trait (billy equivalent)

```text
Filesystem: open, create, read, write, stat, readDir, mkdir, remove, rename,
            symlink/readLink, join, chroot/root, temp
Backends: os (std.fs), mem (tests)
```

Storage and worktree depend on this trait. No pure `std.fs` leakage into library core.

### 6.3 Storer composition

Implement semantic contracts first (memory backend + suite). Filesystem storage is formats + `dotgit` layout + thin façades. Optional capabilities: `PackfileWriter`, loose/packed GC, transactional demux — inventory-flagged.

### 6.4 Security shell

Port `internal/pathutil` before checkout/status materializes trees. Goldens for `.git` disguise, NTFS/HFS cases, `ValidTreePath`. This is not optional polish.

### 6.5 Protocol policy

Match go-git client filters: no multi_ack, no thin-pack by default. Packp goldens must not require full multi-round negotiation.

---

## 7. Dependency policy

| Class | Action |
|-------|--------|
| In-tree algorithms (merkletrie, pack delta, pathutil, revision) | Port to Zig |
| zlib, SHA-256, big-endian I/O | Zig std |
| sha1cd | Port or vendor CD implementation; do not silently use weak SHA-1 |
| sergi/go-diff | Port Myers or proven Zig diff; goldens for patch/blame |
| billy | Reimplement trait + os/mem |
| go-git-fixtures | Vendored data for tests only |
| SSH / OpenPGP / HTTP stack | Defer; keep transport interface |
| CLI (`cli/go-git`) | Out of library scope |

---

## 8. Parallelism model (agents)

| Mode | Rule |
|------|------|
| Across phases | **Sequential.** Phase N+1 code does not merge before phase N gate. |
| Inside a phase | **Parallel agents** own disjoint packages/files (e.g. pktline ∥ config ∥ filemode). |
| Shared files | Single owner per file per phase (storer interfaces, Hash type). |
| Inventories | One agent or human updates `inventories/` when adding surface; same PR as code. |
| Reference tree | Read-only. Never “fix” go-git to make a test pass. |

Suggested parallel splits by phase type:

- **Codec phase:** one agent per format package + one agent on goldens/testdata.  
- **Storage phase:** memory storer ∥ API inventory ∥ filesystem/dotgit after codecs land.  
- **Porcelain phase:** remote ∥ worktree only after shared repo type is stable.

---

## 9. Definition of done (per package)

A package is done for its phase when:

1. File inventory lists it and the Zig tree exists.  
2. API inventory IDs for that phase are mapped and present.  
3. Required goldens for that package are green.  
4. No allowlist entry is overdue.  
5. Public behavior matches go-git tests extracted for that package (not merely “compiles”).

A **phase** is done when `//check:phase_N` is green and the phase branch is merged to `develop` per `AGENTS.md`.

---

## 10. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Hollow packages pass file inventory | API inventory + goldens required same phase |
| Zig renames break tracking | Semantic IDs + `zig_map` in inventories |
| Fixture drift / network fetch | Vendor fixtures; pin go-git; no CI download |
| Packfile complexity explosion | Slice: scanner → delta → parse-to-memory → idx random access → encoder |
| Interface over-abstraction | Closed unions first; vtables only for true plug-ins |
| SHA-1 mismatch with Git | sha1cd (or documented allowlist + remove_by_phase) |
| Porcelain too early | Phase gates block `src/worktree` until merkletrie + index + object green |
| Oracle Go helper becomes runtime dep | Oracle only for golden refresh; default tests pure Zig |
| Dual hash / SHA-256 | Defer; COMPATIBILITY shows limited SHA-256 in go-git network paths |

---

## 11. Immediate next steps (after this strategy)

1. Write the **phase plan** (ordered phases, package sets, gate targets, parallel work slices).  
2. Bootstrap Bazel (`MODULE.bazel`, rules_zig 0.16, `//:gitz` skeleton).  
3. Add `inventories/packages.yaml` for L0–L1 packages and empty `//check:file_inventory` that fails until packages exist.  
4. Implement L0 + first goldens (hash, filemode, binary, pktline).  
5. Grow inventories and goldens with every phase — never as a cleanup at the end.

---

## 12. Analysis sources (agent reports)

This strategy synthesizes deep reads of go-git v5.19.2:

- Plumbing + format packages (layering, packfile/index criticality)  
- Storage + storer interfaces (memory-first, billy, no mmap)  
- packp + transport (pure protocol vs network; multi_ack unsupported)  
- Root porcelain + config (engines in remote/worktree; Zig module split)  
- utils/internal/deps (merkletrie, pathutil, sha1cd, billy centrality)  
- Quantitative inventory (~248 prod files, golden-friendly package ranking)

Detailed package notes remain in agent transcripts; this file is the durable strategy for humans and agents.
