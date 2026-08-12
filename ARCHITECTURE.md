# Architecture

gitz ports the behavior and package boundaries of go-git to Zig. It does not
define a separate Git model. [`GO_GIT_PIN.md`](GO_GIT_PIN.md) records the exact
go-git revision used as the reference.

## Design principles

- Keep Git wire formats and observable behavior compatible with go-git.
- Use explicit allocators and error sets.
- Keep storage, file-system, and transport boundaries explicit.
- Keep production libraries independent of test-only packages.
- Support native and WebAssembly builds without a required C or Go runtime.
- Treat untrusted repository data as hostile input. Validate sizes, paths,
  object identifiers, offsets, and protocol framing before use.

## Ownership

go-git is the feature and Git-behavior reference. Zig owns allocation and free
companions. Do not assume go-git GC lifetimes. The normative rules (R1–R9),
EncodedObject contract, walker free policy, and process lifecycle live in
[`docs/OWNERSHIP.md`](docs/OWNERSHIP.md).

## Dependency direction

```text
hash, object types, file modes, utilities
                 |
                 v
format codecs: config, objects, index, pack, pkt-line
                 |
                 v
storage contracts and memory/filesystem implementations
                 |
                 v
objects, revision walking, commit graph
                 |
                 v
protocol and transport
                 |
                 v
repository, remote, and worktree operations
```

Higher layers can depend on lower layers. Lower layers must not depend on
repository or worktree APIs.

## Major boundaries

| Area | Location | Responsibility |
|------|----------|----------------|
| Core library | `src/` | Git formats, storage, transport, repository, and worktree APIs |
| Acceptance checks | `check/` | Bazel targets for inventories, goldens, metrics, and regression checks |
| Compatibility inventory | `inventories/` | Mapping between the pinned go-git surface and gitz |
| Test data | `data/fixtures/`, `data/goldens/` | Committed, deterministic inputs and expected results |
| Maintenance tools | `tools/` | Inventory and golden maintenance utilities |

## Object formats

The library supports SHA-1 and SHA-256 repositories. A storage instance owns
its object format. Code that processes wire data activates the matching
thread-local format before it reads or writes object identifiers.
`plumbing.Hash` has enough capacity for either format; serialization uses the
active digest width. Use `plumbing.FormatScope` around direct codec calls.

## File systems and paths

Library code uses the project file-system abstraction where repository behavior
must work across memory, operating-system, and WebAssembly environments. Path
validation rejects Git metadata aliases and platform-specific unsafe forms.
Security-sensitive validation belongs in `src/internal/pathutil`; user path
expansion is isolated in `src/internal/pathutil/tilde.zig`.

## Verification

Bazel is the only supported build and test entry point. `//check:all` runs the
complete acceptance suite. See [`docs/TESTING.md`](docs/TESTING.md) for test
layout and [`docs/GATES.md`](docs/GATES.md) for inventory and golden maintenance.
