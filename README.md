# gitz

Git in Zig. A full port of [go-git](https://github.com/go-git/go-git) (Apache 2.0).

## Layout

This workspace uses a bare repository and worktrees. See `AGENTS.md` at the workspace root and in this tree.

| Path | Role |
|------|------|
| `gitz.git/` | Bare repository |
| `gitz-master/` | `master` worktree |
| `gitz-develop/` | `develop` worktree |
| `go-git/` | Pinned go-git reference clone (sibling; not part of this repo) |

## Build

Bazel + rules_zig (Zig 0.16). Use the shared output root:

```bash
bazel --output_user_root=/mnt/workspace/gitz/bazel-cache build //...
```

## Reference pin

See `GO_GIT_PIN.md`.
