# Testing conventions

gitz tests are Bazel `zig_test` targets. Keep tests hermetic and deterministic.
Do not use the network or host file system unless the package under test is the
operating-system backend.

## Layout

| Test type | Location | Bazel shape |
|-----------|----------|-------------|
| Unit | Co-located `*_test.zig` beside production sources | A `zig_test` in the same Bazel package |
| Shared fixtures | `src/<area>/test/` | A test-only library |
| Cross-package integration | The matching `src/<area>/test/` package | A dedicated `zig_test` |
| Behavioral fixtures | `data/fixtures/` and `data/goldens/` | Invoked by `//check:*` targets |

Production `zig_library` targets must not depend on test packages. When a
package needs shared test helpers, import them from a test-only target through a
separate test entry point.

Prefer one shared fixture implementation over copied setup helpers.

### Ownership and allocators

Apply R1–R9 and free companions in [`docs/OWNERSHIP.md`](OWNERSHIP.md)
(EncodedObject, walkers, and related surfaces). Use `std.testing.allocator`
(GPA) or a debug allocator so leaks and double-frees fail tests. Ownership and
free-companion tests must exercise **production loaders** (`heap_owned=true`)
and both storage backends where the contract applies. Stack/map-only tips alone
are not enough for walker or merge-base paths.

## Naming

- Name a unit test `<module>_test.zig`.
- Use a descriptive name such as `serve_e2e.zig` for an integration scenario.
- Use `<package>_test_root.zig` when the production root must remain free of
  test-only imports.
- Match the relative go-git test package when it provides a useful behavioral
  reference.

## Behavioral goldens

Each directory under `data/goldens/` contains `meta.yaml` and committed inputs
and expected results. `//check:goldens_smoke` verifies file-level equality.
Executable recomputation tests rebuild selected results through library APIs so
editing both sides of a static fixture cannot conceal a regression.

Do not download fixtures or invoke an external oracle in default tests. Use the
pinned go-git checkout only during an explicit, offline refresh. Commit and
review refreshed results.

## Running tests

```bash
# Complete repository suite
bazel test //...

# Acceptance checks
bazel test //check:all

# Freestanding WebAssembly acceptance gate
bazel test //examples/wasm:all

# Release-small WebAssembly acceptance gate
bazel test //examples/wasm:release

# Safety-enabled WebAssembly acceptance gate
bazel test //examples/wasm:debug

# One package
bazel test //src/plumbing/format/packfile:packfile_test
```

Use Bazel with the repository's rules_zig toolchain. Do not use the system Zig
compiler as a substitute for these tests.
