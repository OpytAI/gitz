# Acceptance checks

Run acceptance checks through Bazel. Default tests must not use the network,
the host Go toolchain, or the system Zig installation.

```bash
bazel test //check:all
```

The workspace `.bazelrc` configures the shared output root.

## Targets

| Target | Purpose |
|--------|---------|
| `//check:file_inventory` | Compare required package paths with `src/` |
| `//check:api_inventory` | Validate API inventory files and mapped symbols |
| `//check:goldens_smoke` | Compare committed golden inputs and expected results |
| `//check:metrics` | Validate inventory counts, thresholds, and the go-git pin |
| `//check:allowlists` | Reject expired compatibility exceptions |
| `//check:checker_self_tests` | Test the inventory checkers |
| `//check:all` | Run the complete acceptance suite |
| `//examples/wasm:all` | Build and run the five import-free freestanding WebAssembly artifacts |

## Add or update an inventory entry

1. Update `inventories/packages.yaml`.
2. Add or update the corresponding file in `inventories/api/`.
3. Ensure the package directory contains a production `.zig` file directly in
   that directory. A child package does not satisfy its parent entry.
4. Run:

   ```bash
   bazel test //check:file_inventory //check:api_inventory
   ```

Valid package statuses are `required`, `deferred`, `excluded`, and `test_only`.
Inventories are **navigation and package-surface hygiene**: they map the pinned
go-git tree to gitz paths and exports so hollow or missing packages fail CI.
Numeric API-name mapping fields (`zig_map` coverage, `min_mapped_ratio`) are
legacy compatibility data used by existing checkers; they are **not** a project
success metric or roadmap driver. Prefer behavioral goldens, Bazel gate health,
allowlists, and ownership GPA suites (see [`docs/OWNERSHIP.md`](OWNERSHIP.md)).

## Add a golden

1. Create `data/goldens/<suite>/meta.yaml`.
2. Commit the input and expected result files named by `meta.yaml`.
3. Run `bazel test //check:goldens_smoke`.

Example:

```yaml
name: my_case
type: file_equals
actual: input.txt
expected: expected.txt
```

Supported types are `file_equals`, `text_equals`, and `static_contains`.
Golden refresh tools can use the pinned go-git checkout offline, but default
tests must never refresh expected results automatically.

## Compatibility exceptions

Store temporary inventory exceptions in `inventories/allowlists/*.yaml`. Each
entry must have an identifier, a reason, and the expiry field required by the
checker. Keep exceptions narrow and remove them when the implementation lands.
Do not disable Bazel checks in comments or weaken a check to hide a gap.

## Review expectations

- Review changes to expected results as carefully as source changes.
- Keep fixtures small and record their origin.
- Do not fetch fixtures during a build or test.
- Run `//check:all` before merging changes that affect public behavior,
  inventories, fixtures, or acceptance tooling.
