# Fail-forward fixtures

Frozen inventories and an empty `src/` tree for negative Bazel tests:

- `//check:file_inventory_fail_forward`
- `//check:api_inventory_fail_forward`

These do **not** use live `inventories/packages.yaml` or production `src/`.
Phase 1+ package work must not change the expected missing counts here unless
you intentionally update the fixture and the sh_test assertions together.

| File | Role |
|------|------|
| `packages.yaml` | 3 required phase-1 packages + later/excluded rows |
| `api/*.yaml` | API seeds for two phase-1 fixtures |
| `src/` | Empty (hollow) fixture source root |
