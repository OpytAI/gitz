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

Static fixtures under `data/goldens/<name>/` with `meta.yaml`. Wire bytes should
also be locked by unit encode tests when practical; `meta.yaml` may carry a
`note:` pointing at the encoder test name.
