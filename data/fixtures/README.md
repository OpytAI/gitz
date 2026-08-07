# Fixtures

Vendored binary and repository fixtures for Class A–C goldens.

## Layout

```text
data/fixtures/
  sha1cd/         # SHA-1 collision vectors (sha-mbles; Phase 1)
                  # mirrored in src/crypto/sha1cd/collision_vectors.zig for tests
  idxfile/        # pack idx samples (Phase 2)
                  # basic.idx — go-git-fixtures basic pack (a3fed42d…), 31 objects
                  # also embedded as src/plumbing/format/idxfile/basic_idx.zig for tests
  packfile/       # .pack / .idx samples (Phase 3)
                  # basic.pack + basic.idx — same go-git-fixtures basic pack
  repos/          # small on-disk git repos (Phase 6+)
  indexes/        # .git/index samples (Phase 5+)
  README.md       # this file
```

## Rules

- Do not download fixtures in CI. Commit selected files under this tree.
- Prefer small fixtures harvested from go-git tests or go-git-fixtures.
- Reference pin: see `GO_GIT_PIN.md`. Do not edit `../go-git` to create fixtures.
- Large packs: document source and trim when possible.

## packfile/

| File | Size | Role |
|------|------|------|
| `packfile/basic.pack` | 84794 bytes | go-git-fixtures **basic** packfile |
| `packfile/basic.idx` | (matches phase-2 idx) | index for `basic.pack` (same bytes as `idxfile/basic.idx`) |

**Source:** go-git-fixtures basic fixture (the pack used by `fixtures.Basic()` in go-git tests).

**Proven bytes (Class A goldens):**

| Field | Value | Golden |
|-------|-------|--------|
| Signature | `PACK` (bytes 0–3) | `data/goldens/packfile_header/` |
| Version | 2 (big-endian u32 at offset 4) | `data/goldens/packfile_header/` |
| Object count | 31 (big-endian u32 at offset 8) | `data/goldens/packfile_header/` |
| Pack trailer SHA-1 | `a3fed42da1e8189a077c0e6846c040dcf73fc9dd` (last 20 bytes) | `data/goldens/packfile_checksum/` |

The trailer hash is also recorded as `packfile_hash` in `data/goldens/idxfile_basic_count/` (Phase 2).

Phase 2 added `idxfile/basic.idx`. Phase 3 vendors the matching full pack under `packfile/`.
