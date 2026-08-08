# gitz

**Git for Zig — and for places Go and C cannot go lightly.**

A pure-Zig Git library: a deliberate, full-surface port of [go-git](https://github.com/go-git/go-git) **v5.19.2**, built to run as a normal native library and as a first-class **WebAssembly** citizen.

[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)
[![Zig 0.16](https://img.shields.io/badge/Zig-0.16-f7a41d)](https://ziglang.org/)

[Why gitz](#why-gitz) · [What you get](#what-you-get) · [Status](#status) · [Build](#build) · [For contributors](#for-contributors) · [License](#license)

---

## Why gitz

We needed **Git inside WebAssembly**.

The usual answers do not fit that goal well:

| Option | Problem for us |
|--------|----------------|
| **[libgit2](https://libgit2.org/)** | Capable, but its license is not permissive enough for every product we care about. |
| **[go-git](https://github.com/go-git/go-git)** | Feature-rich and approachable, yet a Go binary drags a large runtime. In our measurements the Go path sat around **~20 MiB**, versus roughly **0.635 MiB** for a libgit2 wasm build — a non-starter for lean Wasm embeds. |
| **[gitoxide](https://github.com/GitoxideLabs/gitoxide)** | Excellent Rust engineering, but heavy and awkward to get into a clean Wasm target for our stack. |

Separately, we rewrote a POSIX-shaped image from Rust to Zig and watched footprint collapse from **~20 MiB to ~2 MiB**. That made the question hard to ignore: **what if Git itself were Zig?**

There are incomplete, often AI-scaffolded Zig Git experiments. We wanted something we could treat as a **standard**: same behaviors as a mature library, not a greenfield partial clone of Git.

**go-git** is that standard for us. Despite Go’s runtime weight, its model is complete enough to port against (plumbing and porcelain, storers, transports, worktree). Go is a small language, so Go→Zig translation stays mechanical: packages map cleanly, tests map cleanly, and we can keep **behavioral fidelity** without inventing a different Git.

**gitz** is that port — pure Zig, Bazel-hermetic Zig **0.16**, Apache-2.0, aimed at **native and Wasm** without a GC runtime tax.

---

## What you get

- **Library, not a CLI** — embed Git operations in your process (or Wasm module).
- **go-git-shaped surface** — repository, remote fetch/push, worktree checkout/status/commit, pack protocol, file/git/http/ssh transports, submodules, blame, prune, and the format stack (pack, index, commit-graph, …).
- **Extensible storage** — memory and filesystem backends; in-process server for tests and hermetic remotes.
- **No C dependency wall** — collision-detecting SHA-1 and crypto paths in pure Zig where the port requires it.

Pin and policy: **[`GO_GIT_PIN.md`](GO_GIT_PIN.md)** (go-git **v5.19.2**).

---

## Status

gitz is under active development. The `develop` branch tracks a phase-gated port of go-git **v5.19.2**. Automated gates (`//check:…`) enforce package inventories and goldens as surface lands.

For architecture and phase detail (contributor-oriented):

| Doc | Role |
|-----|------|
| [`PORT_STRATEGY.md`](PORT_STRATEGY.md) | How we port (Zig seams, layers, non-goals) |
| [`PHASE_PLAN.md`](PHASE_PLAN.md) | Phases, packages, Bazel gates |
| [`docs/GATES.md`](docs/GATES.md) | Adding packages/goldens and running gates |

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

If your environment uses a custom Bazel output root, see workspace `.bazelrc` and contributor notes in [`AGENTS.md`](AGENTS.md).

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

