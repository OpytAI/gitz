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
  packs/          # .pack / .idx samples (Phase 3+)
  repos/          # small on-disk git repos (Phase 6+)
  indexes/        # .git/index samples (Phase 5+)
  README.md       # this file
```

## Rules

- Do not download fixtures in CI. Commit selected files under this tree.
- Prefer small fixtures harvested from go-git tests or go-git-fixtures.
- Reference pin: see `GO_GIT_PIN.md`. Do not edit `../go-git` to create fixtures.
- Large packs: document source and trim when possible.

Phase 2 adds `idxfile/basic.idx` (go-git basic pack index). Full packs land when pack-read (Phase 3) needs them.
