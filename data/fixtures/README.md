# Fixtures

Vendored binary and repository fixtures for Class A–C goldens.

## Layout

```text
data/fixtures/
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

Phase G only seeds this layout. Real packs land when pack-read (Phase 3) needs them.
