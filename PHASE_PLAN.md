# gitz phase plan

**Status:** active — Phase 11 (`remote`) on feature branch; develop through Phase 10.  
**Pin:** go-git **v5.19.2** (`GO_GIT_PIN.md`)  
**Strategy:** `PORT_STRATEGY.md` (how). **This file:** what lands when.  
**Process:** `AGENTS.md` (worktrees, merge, sequential phases).  
**Gates:** `docs/GATES.md` (add package / golden / bump `current_phase`).

Full systematic port of go-git v5.19.2. Not a subset. Match go-git incompleteness unless a later phase explicitly expands scope.

---

## 0. Rules that apply to every phase

| Rule | Detail |
|------|--------|
| Sequential phases | Phase N+1 does not merge before phase N gate is green on `develop`. |
| Parallel only inside a phase | Disjoint packages/files; one owner for shared types (`Hash`, storer contracts, FS trait). |
| Worktree | `feature/phase-<id>-<slug>` → worktree `gitz-phase-<id>-<slug>` from `develop`. |
| Gate | `bazel test //check:phase_<id>` (and `//...` if that phase added library targets). |
| After **Phase G** | **All** acceptance, inventories, goldens, and metrics run **only** through Bazel. No hand-run scripts for “done.” |
| Reference | Read-only `../go-git` at pin. Never edit go-git to pass a test. |
| Inventories | Update `inventories/` in the **same** change set as new surface. |
| Allowlists | `inventories/allowlists/*.yaml` only; each entry has `remove_by_phase`. |
| Definition of done | `PORT_STRATEGY.md` §9 + this file’s per-phase exit criteria. |

### Branch naming

```text
feature/phase-g-guardrails
feature/phase-1-foundation
feature/phase-2-leaf-codecs
…
```

### Out of inventory scope (all phases)

| Path | Status |
|------|--------|
| `_examples/` | excluded |
| `cli/` | excluded (optional later tool) |
| `internal/test` | test-only; use Zig `std.testing` |
| `plumbing/transport/*/internal/test`, `plumbing/transport/test` | test helpers; mark `test_only` if listed |
| `storage/test` | port as **gitz test suite**, not production package |

### Prefer

- `format/commitgraph/v2` API only (fold into `src/plumbing/format/commitgraph/`; skip deprecated v1 types).  
- SHA-1 first (`[20]u8`); sha1cd semantics (allowlist only with `remove_by_phase`).  
- FS trait early (no pure `std.fs` in library core).

---

## Phase map (overview)

| Phase | Id | Slug | Goal |
|------:|----|------|------|
| **G** | `g` | `guardrails` | Bazel acceptance system: inventories, goldens harness, metrics, phase gates |
| **1** | `1` | `foundation` | Hash, plumbing root, filemode, utils/binary, utils/sync, color |
| **2** | `2` | `leaf-codecs` | pktline, objfile, config format, idxfile (no pack yet) |
| **3** | `3` | `pack-read` | packfile **read** path (scanner → delta → parse → Packfile+idx) |
| **4** | `4` | `storer-memory` | storer contracts, cache, storage/memory, storage root types |
| **5** | `5` | `index-pack-write` | format/index, packfile **encoder**, pack write helpers |
| **6** | `6` | `fs-storage` | FS trait, dotgit, filesystem storage, transactional |
| **7** | `7` | `objects` | plumbing/object (+ commitgraph), revlist |
| **8** | `8` | `protocol` | packp, capability, sideband, transport interfaces + client registry + server (memory) |
| **9** | `9` | `diff-status-shell` | merkletrie, gitignore, gitattributes, format/diff, pathutil, revision, url |
| **10** | `10` | `config-repo` | config/, repository open/init/facades (no full worktree/remote engines) |
| **11** | `11` | `remote` | remote fetch/list/push orchestration |
| **12** | `12` | `worktree` | worktree status/add/commit/checkout/reset/clean + clone/pull glue |
| **13** | `13` | `transports-extras` | http, ssh, git, file transports; submodule; blame; prune/repack; serverinfo |

Phases **G → 13** are sequential. After G, every phase’s merge gate is Bazel-only.

---

## Phase G — Guardrails (Bazel acceptance system)

**Branch:** `feature/phase-g-guardrails`  
**Depends on:** current `develop` (Bazel + `//src:gitz` smoke already present).  
**Purpose:** build the **process as code**. Until G merges, one-off scripts are allowed **only** to *develop* the checkers. After G merges, acceptance is **only** `bazel test //check:...`.

### Deliverables

| Path | Role |
|------|------|
| `inventories/packages.yaml` | Every in-scope go-git package → zig path → `phase` id → status |
| `inventories/api/` | Per-package semantic export lists (start with foundation packages; stubs OK for later phases) |
| `inventories/allowlists/` | Schema + empty or seed allowlists |
| `inventories/metrics.yaml` | What we measure (counts, coverage of inventory, golden suite sizes) |
| `tools/inventory/` | Generators/checkers **invoked by Bazel** (Python or Zig); no required host Go for default tests |
| `tools/golden/` | Helpers to *refresh* goldens (may use Go oracle offline); refresh is developer workflow, not CI default |
| `check/` | Bazel packages: `file_inventory`, `api_inventory`, `goldens`, `metrics`, `phase_*` |
| `data/goldens/` | Seed fixtures (even tiny) proving golden runner works |
| `data/fixtures/` | Layout + README; vendor real packs when Phase 3+ needs them |
| `docs/GATES.md` | How to add a package to inventory, add a golden, bump phase |

### Gate targets (must exist after G)

```text
//check:file_inventory          # packages.yaml vs src/** for phases ≤ declared "current"
//check:api_inventory           # semantic IDs for packages with phase ≤ current
//check:goldens_smoke           # at least one trivial golden passes
//check:metrics                 # emit/check metrics (e.g. package counts, allowlist age)
//check:phase_g                 # bundle: all of the above + //src:gitz_test
//check:phase_1 … //check:phase_13   # may be stubs that fail or select empty until that phase
//check:all                     # all phases completed so far (grows as phases land)
```

**Phase id “current”** for inventory checkers: a single source in `inventories/current_phase` or `inventories/packages.yaml` key `current_phase: g` updated **only** when a phase merges to develop (or via a version file committed on merge).

### Metrics (examples)

| Metric | Meaning |
|--------|---------|
| `packages.required` | Count with `phase ≤ current` |
| `packages.present` | Count with zig path existing |
| `packages.missing` | required − present (must be 0 for gate) |
| `api.required` / `api.mapped` | Semantic IDs vs implemented |
| `goldens.count` / `goldens.pass` | Suite size |
| `allowlist.active` | Entries not yet expired |
| `go_git.pin` | Must equal `GO_GIT_PIN.md` |

Metrics are produced by a Bazel test/genrule (JSON or textproto artifact); failing thresholds fail the test.

### Scripts policy (Phase G only)

| Allowed during G development | Forbidden after G merges |
|------------------------------|---------------------------|
| Local scripts to prototype checkers | “I ran `scripts/check.sh` so we’re done” |
| One-shot Go oracle to seed a golden | Network fetch of fixtures in CI |
| Manual `go test` in go-git to harvest vectors | System `zig` for acceptance |

**Exit criterion for G:**

1. `bazel test //check:phase_g` green.  
2. Documented workflow: add package → update yaml → gate fails until code exists.  
3. Documented workflow: add golden under `data/goldens` → registered in BUILD → runs in `//check:goldens_*`.  
4. `current_phase` mechanism works.  
5. No acceptance path outside Bazel remains in docs.

### Parallelism inside G

| Agent slice | Owns |
|-------------|------|
| A | `packages.yaml` schema + file inventory checker + `//check:file_inventory` |
| B | API inventory schema + checker + seed `api/plumbing*.yaml` |
| C | Golden runner + smoke golden + `//check:goldens_smoke` |
| D | Metrics + phase_g / phase stub targets + `docs/GATES.md` |

Shared: `check/BUILD.bazel` conventions (one owner or sequential commits).

---

## Phase 1 — Foundation

**Depends on:** G  
**Gate:** `//check:phase_1`

### Packages (go-git → gitz)

| go-git | gitz | Notes |
|--------|------|--------|
| `plumbing/hash` | `src/plumbing/hash` | sha1cd path or allowlist |
| `plumbing` (root) | `src/plumbing` | Hash, ObjectType, MemoryObject, Reference, errors |
| `plumbing/filemode` | `src/plumbing/filemode` | |
| `plumbing/color` | `src/plumbing/color` | leaf constants |
| `utils/binary` | `src/utils/binary` | VLQ + endian |
| `utils/sync` | `src/utils/sync` | buffer/zlib pools |
| `utils/ioutil` | `src/utils/ioutil` | minimal helpers needed by later codecs |
| `utils/trace` | `src/utils/trace` | thin optional |

### Goldens

- Hash: known `"blob 0\0"` / small payloads → OID.  
- filemode tables.  
- binary VLQ round-trip.  

### Parallel slices

| Slice | Packages |
|-------|----------|
| A | hash + plumbing root (single owner for `Hash`) |
| B | filemode + color |
| C | utils/binary + utils/sync + ioutil/trace |
| D | inventories/api for these packages + goldens registration |

### Exit

- File + API inventory for phase ≤ 1 green.  
- Foundation goldens green.  
- `//src:gitz` re-exports or depends on plumbing as needed.

---

## Phase 2 — Leaf codecs (no pack)

**Depends on:** 1  
**Gate:** `//check:phase_2`

| go-git | gitz |
|--------|------|
| `plumbing/format/pktline` | `src/plumbing/format/pktline` |
| `plumbing/format/objfile` | `src/plumbing/format/objfile` |
| `plumbing/format/config` | `src/plumbing/format/config` |
| `plumbing/format/idxfile` | `src/plumbing/format/idxfile` |

### Goldens

pktline encode/decode; objfile round-trip; config fixtures; idxfile decode from small fixture (vendor when needed).

### Parallel

pktline ∥ config ∥ objfile ∥ idxfile (shared: hash/OID only from phase 1).

### Exit

Class A goldens for all four packages green; inventories updated.

---

## Phase 3 — Packfile read path

**Depends on:** 2  
**Gate:** `//check:phase_3`

| go-git | gitz | Scope this phase |
|--------|------|------------------|
| `plumbing/format/packfile` | `src/plumbing/format/packfile` | **Read only:** scanner, headers, inflate, delta apply, parser-to-memory, Packfile+idx Get |

**Defer to Phase 5:** Encoder, delta window selection, WritePackfile.

### Goldens

- Scanner over `data/fixtures` packs (from go-git-fixtures or harvested).  
- PatchDelta known vectors.  
- Security bounds tests (oversize inflate) as goldens/unit tests.

### Parallel

| Slice | Owns |
|-------|------|
| A | Scanner + headers |
| B | Delta apply |
| C | Parser + memory objects |
| D | Packfile+idx random access + fixtures vendor |

### Exit

Can load objects from a real pack+idx without network; inventories list packfile read symbols; encoder symbols allowlisted until phase 5.

---

## Phase 4 — Storer + memory storage

**Depends on:** 3 (objects live in packs; storer can still start earlier if needed, but gate after pack-read so suite can use packs)  
**Gate:** `//check:phase_4`

| go-git | gitz |
|--------|------|
| `plumbing/storer` | `src/plumbing/storer` |
| `plumbing/cache` | `src/plumbing/cache` |
| `storage` | `src/storage` |
| `storage/memory` | `src/storage/memory` |

### Goldens / suites

Port `storage/test` BaseStorageSuite over **memory** (parameterized). Skip optional caps (PackfileWriter) via capability flags.

### Parallel

storer interfaces ∥ cache ∥ memory backend ∥ suite.

### Exit

Memory storer passes suite; API inventory for EncodedObjectStorer + ReferenceStorer methods.

---

## Phase 5 — Index format + pack write

**Depends on:** 4  
**Gate:** `//check:phase_5`

| go-git | gitz |
|--------|------|
| `plumbing/format/index` | `src/plumbing/format/index` |
| `plumbing/format/packfile` (encoder) | complete write path; remove encoder allowlist |

### Goldens

Index multi-version fixtures; pack encode → read back round-trip.

### Parallel

index codec ∥ pack encoder ∥ golden registration.

### Exit

Round-trip pack and index; phase 3 allowlists for encoder closed.

---

## Phase 6 — Filesystem storage

**Depends on:** 5  
**Gate:** `//check:phase_6`

| go-git | gitz |
|--------|------|
| (billy equivalent) | `src/fs` (trait + mem + os) |
| `storage/filesystem/dotgit` | `src/storage/filesystem/dotgit` |
| `storage/filesystem` | `src/storage/filesystem` |
| `storage/transactional` | `src/storage/transactional` |

### Goldens

BaseStorageSuite on filesystem backend; init layout; loose + pack read/write; refs loose + packed-refs.

### Parallel

| Slice | Owns |
|-------|------|
| A | FS trait + mem + os |
| B | dotgit layout |
| C | FS object/ref/index façades |
| D | transactional + suite wiring |

### Exit

Can open a real on-disk `.git` produced by system git or go-git fixtures; inventories complete for storage/*.

---

## Phase 7 — Logical objects + revlist

**Depends on:** 6  
**Gate:** `//check:phase_7`

| go-git | gitz |
|--------|------|
| `plumbing/object` | `src/plumbing/object` |
| `plumbing/format/commitgraph` (+v2) | `src/plumbing/format/commitgraph` |
| `plumbing/object/commitgraph` | `src/plumbing/object/commitgraph` |
| `plumbing/revlist` | `src/plumbing/revlist` |

### Goldens

Decode commit/tree/tag/blob; tree walk; revlist object sets against fixtures.

### Parallel

blob/tree ∥ commit/tag ∥ walkers ∥ commitgraph ∥ revlist (shared object types owned by one agent).

### Exit

Object API inventory; revlist goldens; rename detection can be allowlisted to phase 9/12 if tightly coupled to merkletrie.

---

## Phase 8 — Protocol (pure + transport core)

**Depends on:** 7 (server needs objects/revlist for real packs; pure packp can start after 2 but gate after 7 for integration)  
**Gate:** `//check:phase_8`

| go-git | gitz |
|--------|------|
| `plumbing/protocol/packp` | `src/plumbing/protocol/packp` |
| `plumbing/protocol/packp/capability` | `src/plumbing/protocol/packp/capability` |
| `plumbing/protocol/packp/sideband` | `src/plumbing/protocol/packp/sideband` |
| `plumbing/transport` | `src/plumbing/transport` |
| `plumbing/transport/client` | `src/plumbing/transport/client` |
| `plumbing/transport/internal/common` | `src/plumbing/transport/internal/common` |
| `plumbing/transport/server` | `src/plumbing/transport/server` |

**Policy:** match go-git — no multi_ack, no thin-pack client filter list.

### Goldens

packp encode/decode vectors; sideband; session over pipes + memory server.

### Parallel

capability+sideband ∥ packp messages ∥ transport interfaces+client ∥ server+pipe tests.

### Exit

Network-free protocol suite green; HTTP/SSH **not** required.

---

## Phase 9 — Diff / status dependencies

**Depends on:** 7 (and FS from 6)  
**Gate:** `//check:phase_9`

| go-git | gitz |
|--------|------|
| `utils/merkletrie` (+ noder, index, filesystem, frame) | `src/utils/merkletrie/...` |
| `utils/merkletrie/internal/fsnoder` | test-only helpers |
| `plumbing/format/gitignore` | `src/plumbing/format/gitignore` |
| `plumbing/format/gitattributes` | `src/plumbing/format/gitattributes` |
| `plumbing/format/diff` | `src/plumbing/format/diff` |
| `utils/diff` | `src/utils/diff` |
| `internal/pathutil` | `src/internal/pathutil` |
| `internal/path_util` | `src/internal/path_util` |
| `internal/revision` | `src/internal/revision` |
| `internal/url` | `src/internal/url` |
| `internal/reference` | `src/internal/reference` |

### Goldens

merkletrie change lists; pathutil reject tables (security); gitignore match; revision parse; unified diff strings.

### Parallel

merkletrie core ∥ adapters ∥ gitignore/gitattributes ∥ pathutil ∥ revision/url ∥ format/diff+utils/diff.

### Exit

Status/diff prerequisites complete; pathutil goldens mandatory (no allowlist for security tests).

---

## Phase 10 — Typed config + repository core

**Depends on:** 6, 8 (config format from 2; remotes types need config)  
**Gate:** `//check:phase_10`

| go-git | gitz |
|--------|------|
| `config` | `src/config` |
| root package (partial) | `src/repo` — Init, Open, Config, refs/object facades, ResolveRevision, Log (thin) |

**Not in this phase:** full Worktree engine, Remote fetch/push bodies, PlainClone end-to-end.

### Goldens

Config round-trip; init bare/non-bare; open + HEAD; object getters.

### Parallel

config package ∥ repo lifecycle ∥ facades ∥ inventories.

### Exit

Repository holds storer + optional worktree FS; no network.

---

## Phase 11 — Remote engine

**Depends on:** 8, 10  
**Gate:** `//check:phase_11`

| go-git | gitz |
|--------|------|
| root `remote.go` (+ related) | `src/remote` |

### Goldens

Fetch/list against memory server or file protocol; refspec; force-with-lease reject cases; shallow as go-git supports.

### Parallel

fetch/list ∥ push ∥ refspec/options validation ∥ goldens (single owner for Remote type).

### Exit

Remote API inventory; integration goldens without real internet (local server / fixtures).

---

## Phase 12 — Worktree + clone/pull

**Depends on:** 9, 10, 11  
**Gate:** `//check:phase_12`

| go-git | gitz |
|--------|------|
| root worktree*, status, commit | `src/worktree` |
| clone/pull/plain helpers | `src/repo` / `src/porcelain` as needed |

### Goldens

status → add → commit; checkout/reset matrix; pull FF; PlainClone against local remote; sparse as go-git.

### Parallel

status/add ∥ commit ∥ checkout/reset ∥ plain/clone glue (after Worktree type stable).

### Exit

Class C scenario goldens green; platform index stat files (linux/windows stubs) present.

---

## Phase 13 — Transports + extras

**Depends on:** 11, 12  
**Gate:** `//check:phase_13` and `//check:all`

| go-git | gitz |
|--------|------|
| `plumbing/transport/http` | `src/plumbing/transport/http` |
| `plumbing/transport/ssh` | `src/plumbing/transport/ssh` |
| `plumbing/transport/git` | `src/plumbing/transport/git` |
| `plumbing/transport/file` | `src/plumbing/transport/file` |
| root submodule, blame, prune, object_walker | `src/submodule`, `src/blame`, … |
| `plumbing/serverinfo` | `src/plumbing/serverinfo` |

### Goldens

Per-transport unit tests with mocks/fixtures; blame vectors; submodule status; prune/repack as go-git implements (COMPAT may lag code—match **code**).

### Parallel

http ∥ ssh ∥ git+file ∥ submodule ∥ blame ∥ prune/serverinfo.

### Exit

Full file inventory: every in-scope package present.  
`//check:all` green.  
No overdue allowlists.  
Document residual COMPAT gaps that match go-git (not gitz bugs).

---

## Gate matrix (what each `//check:phase_N` includes)

| Gate | Must include |
|------|----------------|
| `phase_g` | file_inventory, api_inventory, goldens_smoke, metrics, allowlists, checker_self_tests, file/api fail-forward negatives, `//src:gitz_test` |
| `phase_1` | phase_g + inventories phase≤1 + foundation goldens + unit tests for new pkgs |
| `phase_k` | phase_{k-1} (transitive) + new inventories + new goldens + `//src/...` tests for packages added in k |
| `all` | phase_13 complete |

Authoritative post-G gate list: `docs/GATES.md` and `check/BUILD.bazel`.

Implementation tip: `phase_k` is a `test_suite` or multirun that depends on prior phase suites + new targets—not a rewrite of checkers each time.

---

## Inventory seed structure (`packages.yaml`)

```yaml
# Illustrative — Phase G writes the real file.
pin: v5.19.2
current_phase: g   # updated on each phase merge to develop

packages:
  - go: plumbing/hash
    zig: src/plumbing/hash
    phase: 1
    status: required
  - go: plumbing/format/packfile
    zig: src/plumbing/format/packfile
    phase: 3
    status: required
    notes: "encoder symbols phase 5; allowlist until then"
  - go: _examples
    status: excluded
```

---

## Risk controls (plan-level)

| Risk | Phase control |
|------|----------------|
| Packfile blow-up | Split read (3) / write (5) |
| Hollow packages | API + goldens same phase as files |
| Security skip | pathutil goldens in 9; no allowlist |
| Network flakes | Fixtures + memory server only through 12; real hosts optional in 13 |
| Scope creep to v6 | Pin file; plan is v5.19.2 only |
| Scripts after G | AGENTS + GATES.md: acceptance = Bazel only |

---

## Already done (not a phase)

| Item | Status |
|------|--------|
| Bare repo + worktrees | done |
| go-git pin v5.19.2 | done |
| `PORT_STRATEGY.md` | done |
| Bazel + rules_zig 0.16 + `//src:gitz` smoke | done |
| Apache-2.0 `LICENSE` | done |

**Phase G (guardrails):** implemented — use `bazel test //check:phase_g`.  
**Next phase to execute:** **Phase 1 (foundation).**

---

## How to run a phase (operators)

```bash
cd /mnt/workspace/gitz/gitz.git
git worktree add ../gitz-phase-g-guardrails -b feature/phase-g-guardrails develop
cd ../gitz-phase-g-guardrails
# ... implement ...
bazel test //check:phase_g
# merge to develop from gitz-develop, then:
# git worktree remove ../gitz-phase-g-guardrails && git branch -d feature/phase-g-guardrails
# set inventories current_phase to next id on develop
```

Inside a phase, split agents only along the **Parallel** table for that phase.

---

## Document control

| Version | Date | Note |
|---------|------|------|
| 1 | 2026-08 | Initial plan; Phase G + 1–13; full v5.19.2 |

When the pin changes, revise package lists and re-baseline inventories in a dedicated chore phase or extend phase 13.
