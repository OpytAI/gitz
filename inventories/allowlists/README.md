# Allowlists

Temporary gaps from inventories and goldens.

## Rules

- Every entry needs `id`, `reason`, and `remove_by_phase`.
- The metrics / allowlist checker fails if `remove_by_phase` is less than or equal to `current_phase` and the entry is still listed.
- No silent Bazel disable comments. Put gaps here.

## Schema

```yaml
# inventories/allowlists/<name>.yaml
entries:
  - id: packfile.Encoder.window
    reason: read path first; encoder lands in phase 5
    remove_by_phase: 5
    owner: optional-agent-or-human
```

Phase ids match `packages.yaml` (`g`, `1` … `13`). Rank: g=0, numeric phases as integers.

## Files

Seed files may be empty (`entries: []`). Add a file per concern or per phase as needed.
