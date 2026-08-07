# gitz

Git in Zig. A full port of [go-git](https://github.com/go-git/go-git).

**License:** Apache License 2.0 — see [`LICENSE`](LICENSE).

## Layout

This workspace uses a bare repository and worktrees. See `AGENTS.md` at the workspace root and in this tree.

| Path | Role |
|------|------|
| `gitz.git/` | Bare repository |
| `gitz-master/` | `master` worktree |
| `gitz-develop/` | `develop` worktree |
| `go-git/` | Pinned go-git reference clone (sibling; not part of this repo) |

## Build

Bazel + **rules_zig 0.16** with hermetic **Zig 0.16.0** (not system `zig`).

From this worktree (`gitz-develop` or `gitz-master`):

```bash
bazel build //...
bazel test //...
```

`.bazelrc` already sets:

- `startup --output_user_root=/mnt/workspace/gitz/bazel-cache` (Bazel disk cache)
- Zig compiler cache under `/tmp/gitz-zig-cache` (writable in linux-sandbox via `/tmp` mount)

If you invoke Bazel without this workspace’s `.bazelrc`, pass the output root explicitly (see `AGENTS.md`).

Smoke targets:

| Target | Role |
|--------|------|
| `//src:gitz` | Core library root |
| `//src:gitz_test` | Root unit tests |
| `//:gitz` | Alias to `//src:gitz` |

## Reference pin

See `GO_GIT_PIN.md` (go-git **v5.19.2**).
