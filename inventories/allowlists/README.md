# Allowlists

Temporary exceptions for inventories and goldens.

## Rules

- Every entry needs `id` and `reason`.
- The repository limit is `max_active: 0`. The checker rejects active entries.
- No silent Bazel disable comments. Put gaps here.

## Schema

```yaml
# inventories/allowlists/<name>.yaml
entries:
  - id: packfile.Encoder.window
    reason: encoder is not implemented
    owner: optional-maintainer
```

## Files

Files can be empty (`entries: []`). Add one file per concern when needed.
