# gitz

**A Git library for Zig.**

A pure-Zig port of [go-git](https://github.com/go-git/go-git) **v5.19.2**
for native and WebAssembly applications.

[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![Zig 0.16](https://img.shields.io/badge/Zig-0.16-f7a41d)](https://ziglang.org/)

[Why gitz](#why-gitz) · [What you get](#what-you-get) · [Status](#status) · [Build](#build) · [For contributors](#for-contributors) · [License](#license)

---

## Why gitz

gitz provides Git behavior to Zig programs without requiring a C or Go runtime.
It uses go-git as its behavioral reference so package boundaries and Git
semantics follow a mature implementation instead of a new, partial model.

The project uses a hermetic Zig **0.16** toolchain through Bazel and is licensed
under Apache-2.0.

---

## What you get

- **Library, not a CLI** — embed Git operations in your process (or Wasm module).
- **go-git-shaped surface** — repository, remote fetch/push, worktree checkout/status/commit, pack protocol, file/git/http/ssh transports, submodules, blame, prune, and the format stack (pack, index, commit-graph, …).
- **Extensible storage** — memory and filesystem backends; in-process server for tests and hermetic remotes.
- **No C dependency wall** — collision-detecting SHA-1 and crypto paths in pure Zig where the port requires it.

Pin and policy: **[`GO_GIT_PIN.md`](GO_GIT_PIN.md)** (go-git **v5.19.2**).

---

## Status

gitz is under active development. The `develop` branch is the integration
branch. Automated checks enforce the package inventory, behavioral fixtures,
and compatibility with the pinned go-git reference.

Contributor documentation:

| Doc | Role |
|-----|------|
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | Design principles, boundaries, and dependency direction |
| [`docs/TESTING.md`](docs/TESTING.md) | Test layout and conventions |
| [`docs/GATES.md`](docs/GATES.md) | Inventories, goldens, and acceptance checks |

---

## Build

**Bazel** + **rules_zig** with hermetic **Zig 0.16.0** (not a system `zig` install).

From a checkout of this repository:

```bash
bazel build //...
bazel test //...
```

Useful targets:

| Target | Role |
|--------|------|
| `//src:gitz` | Core library |
| `//src:gitz_test` | Root unit tests |
| `//:gitz` | Alias to `//src:gitz` |
| `//check:all` | Full inventory / golden / package gate suite |

The workspace `.bazelrc` configures the repository's shared Bazel output root.

---

## For contributors

We port **behavior and package seams**, not Go’s method soup. Prefer explicit allocators, error sets, and small traits; match go-git incompleteness unless a change deliberately expands past the pin.

```bash
# Full gate (preferred acceptance signal)
bazel test //check:all

# Package-focused work
bazel test //src/worktree:worktree_test
bazel test //src/remote:remote_test
```
