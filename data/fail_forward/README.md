# Fail-forward fixtures

Frozen inventories and an empty `src/` tree for negative Bazel tests:

- `//check:file_inventory_fail_forward`
- `//check:api_inventory_fail_forward`

These do **not** use live `inventories/packages.yaml` or production `src/`.
Production package work must not change the expected missing counts here unless
you intentionally update the fixture and its test assertions together.

| File | Role |
|------|------|
| `packages.yaml` | Frozen required and excluded package rows |
| `api/*.yaml` | API seeds for two fixture packages |
| `src/` | Empty (hollow) fixture source root |
