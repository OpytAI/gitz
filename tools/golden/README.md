# Golden tools

## Runner (CI / acceptance)

`run_goldens.py` is the Class A golden runner. Bazel invokes it via `//check:goldens_smoke`.

Default tests **must not** depend on host `go` or network.

```bash
# Prefer Bazel:
bazel test //check:goldens_smoke

# Local debug only (not acceptance):
python3 tools/golden/run_goldens.py --goldens-dir data/goldens
```

## Refresh / oracle (developer workflow only)

When a golden needs regeneration from go-git behavior:

1. Prefer extracting vectors from pinned go-git tests by hand.
2. Optional offline oracle: a small Go program under `tools/golden/` that imports the **pinned** sibling `../go-git` and writes expected bytes/JSON under `data/goldens/`.
3. Commit the refreshed golden files. Review the diff.
4. Never wire the oracle into default `//check:*` tests.

### Scaffold policy

| Allowed | Forbidden in default CI |
|---------|-------------------------|
| Offline Go helper run by a developer | Network download of fixtures |
| Commit refreshed `expected` files | Host `go test` as phase gate |
| Document vectors in commit message | Auto-refresh without review |

Stub: `refresh_oracle_stub.sh` documents the interface; implement when Phase 2+ goldens need bulk refresh.
