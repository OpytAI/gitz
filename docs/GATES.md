# Gates — Bazel acceptance (after Phase G)

**Policy:** After Phase G merges, all acceptance for inventories, goldens, metrics, and phase gates runs **only** through Bazel. Do not treat hand-run scripts as “done.”

Shared invocation (see `AGENTS.md`):

```bash
cd /mnt/workspace/gitz/gitz-develop   # or the phase worktree
bazel test //check:phase_g
```

`startup --output_user_root=/mnt/workspace/gitz/bazel-cache` is already in `.bazelrc`.

---

## Targets

| Target | Role |
|--------|------|
| `//check:file_inventory` | `inventories/packages.yaml` vs `src/**` for packages with `phase ≤ current_phase` (non-hollow: ≥1 `*.zig`) |
| `//check:api_inventory` | Schema + due-package symbol checks for `inventories/api/*.yaml` |
| `//check:goldens_smoke` | Class A golden runner over `data/goldens/` |
| `//check:metrics` | Counts, pin match, thresholds in `inventories/metrics.yaml` |
| `//check:allowlists` | Fail overdue `remove_by_phase` entries; strict YAML shape |
| `//check:checker_self_tests` | Unit self-tests for Python checkers |
| `//check:file_inventory_fail_forward` | Fixture inventory (`data/fail_forward/`) + hollow fixture src must fail at `current_phase=1` |
| `//check:api_inventory_fail_forward` | Fixture API seeds + hollow fixture src must fail at `current_phase=1` |
| `//check:phase_g` | Bundle of the above + `//src:gitz_test` |
| `//check:phase_1` … `//check:phase_13` | Phase gates (stubs chain through `phase_g` until each phase expands them) |
| `//check:all` | All completed phases so far |

Merge rule: phase N work merges to `develop` only when `//check:phase_N` is green **and** `current_phase` is bumped to N so inventories enforce due packages. A green stub suite alone is not merge-complete.

### API symbol matching (best-effort)

`//check:api_inventory` checks that the last path component of each semantic / `zig_map` id appears as a **substring** in package `.zig` sources. Comments or partial names can satisfy this. Stronger decl matching may land in later phases; do not rely on substring checks alone for hollow-proofing (file inventory already requires non-empty `.zig` trees).

---

## `current_phase`

Source of truth: key `current_phase` in `inventories/packages.yaml` (also `pin: v5.19.2`).

| Value | Meaning |
|-------|---------|
| `g` | Guardrails only; no production packages required under `src/` |
| `1` … `13` | Required packages with `phase ≤ N` must exist |

**Bump procedure (on `develop` after a phase merges):**

1. Confirm `bazel test //check:phase_N` is green on the phase branch.
2. Merge into `develop` from the develop worktree.
3. Edit `inventories/packages.yaml`: set `current_phase: N` (e.g. `1`).
4. Run `bazel test //check:phase_N` and `//check:phase_g` on develop.
5. Commit the phase bump with the merge or immediately after.

While `current_phase` is `g`, listing phase-1+ packages in the inventory does **not** fail file inventory (they are not yet due).

---

## Add a package

1. Add a row to `inventories/packages.yaml`:

   ```yaml
   - go: plumbing/format/pktline
     zig: src/plumbing/format/pktline
     phase: 2
     status: required
   ```

2. If the package is due (`phase ≤ current_phase`), create the Zig package root under `src/` with **at least one `*.zig` file directly in that directory** (empty dirs fail; child-package sources do **not** satisfy a parent inventory row). Example: `src/plumbing/hash/hash.zig` does not make `src/plumbing` present — add `src/plumbing/root.zig` (or similar) for the parent.

3. For due required packages, add `inventories/api/<name>.yaml` with semantic IDs and optional `zig_map` (all phase-1 foundation packages are seeded). API symbol scans also use **package-root** `.zig` files only.

4. Run:

   ```bash
   bazel test //check:file_inventory //check:api_inventory //check:phase_g
   ```

Statuses (lowercase only): `required` | `deferred` (same enforcement as required) | `excluded` | `test_only`.

---

## Add a golden

1. Create a directory under `data/goldens/<suite>/`.
2. Add `meta.yaml`:

   ```yaml
   name: my_case
   type: file_equals
   actual: input.txt
   expected: expected.txt
   ```

3. Add the `actual` / `expected` files (or other type-specific inputs).
4. Golden runner is already wired to walk `data/goldens/**/meta.yaml`.
5. Run:

   ```bash
   bazel test //check:goldens_smoke
   ```

Types: `file_equals`, `text_equals`, `static_contains` (see `tools/golden/run_goldens.py`).

Refresh helpers may live under `tools/golden/` for offline oracle use. **Do not** make default tests depend on host `go` or network.

---

## Allowlists

Temporary gaps only. File under `inventories/allowlists/*.yaml`:

```yaml
entries:
  - id: packfile.Encoder.window
    reason: read path first
    remove_by_phase: 5
```

If `remove_by_phase ≤ current_phase`, `//check:allowlists` and `//check:metrics` fail. No silent `# bazel: disable`.

---

## Metrics

Defined in `inventories/metrics.yaml`. `//check:metrics` emits `metric key=value` lines and fails on threshold violations (package counts, API file count, goldens count, pin match with `GO_GIT_PIN.md`, overdue allowlists).

---

## Phase gate growth

When implementing phase N:

1. Implement packages marked `phase: N`.
2. Extend `inventories/api/` and `data/goldens/` for that phase.
3. Optionally add dedicated tests under `//src/...` and register them in `//check:phase_N`.
4. On merge to develop, set `current_phase: N`.

`//check:phase_N` currently chains to prior phases and `phase_g`. Expand `check/BUILD.bazel` as suites grow.

---

## What not to do

- Accept “I ran a local script” as phase completion after G.
- Skip or weaken `//check:*` without an allowlist entry + user approval.
- Depend on network or floating go-git tip in default tests.
- Invent packages outside `packages.yaml` at the top level of `src/` (file inventory flags unexpected top-level dirs).
