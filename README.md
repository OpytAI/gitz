<div align="center">
  <h1>gitz</h1>

  <p><strong>Git, written for Zig.</strong></p>

  <p>
    A pure-Zig Git library for native and WebAssembly applications.<br>
    Clone, fetch, push, inspect, and rewrite repositories without a C or Go runtime.
  </p>

  <p>
    <img alt="Zig 0.16" src="https://img.shields.io/badge/Zig-0.16-f7a41d">
    <img alt="go-git v5.19.2" src="https://img.shields.io/badge/go--git-v5.19.2-00add8">
    <img alt="Native and WebAssembly" src="https://img.shields.io/badge/targets-Native%20%7C%20Wasm-654ff0">
    <img alt="Built with Bazel" src="https://img.shields.io/badge/build-Bazel-43a047">
  </p>

  <p>
    <a href="#why-gitz">Why gitz</a> ·
    <a href="#capabilities">Capabilities</a> ·
    <a href="#build">Build</a> ·
    <a href="#project-status">Status</a> ·
    <a href="./ARCHITECTURE.md">Architecture</a>
  </p>
</div>

---

## Why gitz

Git is useful far beyond the command line. Applications use repositories as
content stores, synchronization protocols, audit trails, and collaboration
layers. gitz brings those capabilities into Zig without crossing a C ABI or
shipping a second language runtime.

The library ports the behavior of
[go-git](https://github.com/go-git/go-git), a mature Git implementation with a
broad, well-tested surface. The current reference is pinned to
[`v5.19.2`](GO_GIT_PIN.md), so compatibility has a concrete target.

## Capabilities

- **Repositories and worktrees** — initialize, clone, open, inspect, commit,
  checkout, reset, merge, blame, prune, and manage submodules.
- **Remote operations** — fetch, pull, push, list references, and serve
  repositories through file, Git, HTTP, SSH, or in-process transports.
- **Git formats** — read and write objects, references, indexes, packfiles,
  pkt-lines, commit graphs, configuration, attributes, and ignore rules.
- **Pluggable storage** — use memory or filesystem storage with SHA-1 and
  SHA-256 object formats.
- **Portable runtime** — build for native targets and WebAssembly with pure-Zig
  cryptography and no required C or Go runtime.

## Build

gitz uses Bazel, rules_zig, and a hermetic Zig 0.16.0 toolchain.

```sh
bazel build //...
bazel test //check:all
```

Useful targets:

| Target | Purpose |
| --- | --- |
| `//:gitz` | Public library |
| `//src:gitz_test` | Root API tests |
| `//check:all` | Complete compatibility and regression suite |

The repository `.bazelrc` selects the shared output cache and hermetic build
settings.

## Project status

gitz is under active development. The package and API inventories cover the
full pinned go-git surface. Behavioral goldens and package tests protect Git
compatibility as the implementation evolves.

Start with the documents that match your task:

| Document | What it covers |
| --- | --- |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | System boundaries and dependency direction |
| [`docs/TESTING.md`](docs/TESTING.md) | Test layout and local verification |
| [`docs/GATES.md`](docs/GATES.md) | Inventories, goldens, and acceptance checks |
| [`GO_GIT_PIN.md`](GO_GIT_PIN.md) | Upstream reference and pin policy |
