# Index fixtures

Git index (DIRC) images for decoder coverage without the go-git-fixtures network.

## Synthetic fixtures

Pad model (go-git encodeEntryName + padEntry for V2/V3):

- Write path bytes **without** an extra mandatory NUL after the name.
- Pad with `8 - wrote % 8` zero bytes (always 1–8).
- V4: VLQ(strip) + suffix + NUL; no 8-byte padding.

| File | Version | Size | Notes |
|------|---------|------|-------|
| `v2_simple` | 2 | 256 B | `.gitignore`, `CHANGELOG`, `README.md` |
| `v3_intent` | 3 | 328 B | plain + intent-to-add + skip-worktree + both |
| `v4_prefix` | 4 | 541 B | `src/` / `vendor/` paths for V4 prefix compression |
| `*.hex` | — | — | Continuous lowercase hex of the binaries above |

## Unit-test embed

rules_zig package `srcs` are `.zig`-only. Unit tests use embedded arrays in:

```text
src/plumbing/format/index/fixtures.zig
```

`TestDecodeAllIndexFixtures` is the go-git analogue (want versions {2, 3, 4}).

## Regenerate / verify — Bazel only

```bash
# Rewrite committed binaries + hex (worktree root as --outdir)
bazel run //tools:gen_index_fixtures -- --outdir "$PWD/data/fixtures/index"

# Also refresh fixtures.zig embeds
bazel run //tools:gen_index_fixtures -- \
  --outdir "$PWD/data/fixtures/index" \
  --embed "$PWD/src/plumbing/format/index/fixtures.zig"

# Verify generated fixtures
bazel test //tools:gen_index_fixtures_test

# bazel-out materialisation for other rules
bazel build //tools:index_fixture_images
```

There is no host-`python3` path. `//tools:gen_index_fixtures_test` fails the
graph if `data/fixtures/index/*` or `fixtures.zig` drift from the generator.
