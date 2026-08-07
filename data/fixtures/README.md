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
                  # see table below; also embedded as *.zig under
                  # src/plumbing/format/packfile/ for package unit tests
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

All hashes below are go-git-fixtures `PackfileHash` (pack trailer SHA-1 = last 20
bytes of the pack image), unless noted.

| File | Size | PackfileHash (trailer) | Role |
|------|------|------------------------|------|
| `packfile/basic.pack` | 84794 bytes | `a3fed42da1e8189a077c0e6846c040dcf73fc9dd` | go-git-fixtures **basic** OFS-delta pack (31 objects) |
| `packfile/basic.idx` | (matches phase-2 idx) | index for `basic.pack` | same bytes as `idxfile/basic.idx` |
| `packfile/ref_delta.pack` | 85585 bytes | `c544593473465e6315ad4182d04d366c4592b829` | basic.git **ref-delta** pack (31 objects) |
| `packfile/ref_delta.idx` | (idx for ref-delta) | index for `ref_delta.pack` | pack-c5445934… idx |
| `packfile/thinpack.pack` | 2461 bytes | `ee4fef0ef8be5053ebae4ce75acf062ddf3031fb` | thin pack (adds commit on spinnaker base) |
| `packfile/codecommit.pack` | 42029 bytes | `9733763ae7ee6efcf452d373d6fff77424fb1dcc` | codecommit external-refs pack |
| `packfile/delta_before_base.pack` | 6680 bytes | `90fedc00729b64ea0d0406db861be081cda25bbf` | delta object before base in stream |

**Source:** go-git-fixtures (v4/v6) pack images used by go-git `plumbing/format/packfile` tests (`fixtures.Basic()`, `ByTag("ref-delta"|"thinpack"|"codecommit"|"delta-before-base")`).

**Embedded Zig mirrors** (for `//src/plumbing/format/packfile:packfile_test`; regenerate from the binaries above if fixtures change):

| Fixture | Zig module |
|---------|------------|
| `basic.pack` | `basic_pack.zig` |
| `ref_delta.pack` | `ref_delta_pack.zig` |
| `ref_delta.idx` | `ref_delta_idx.zig` |
| `thinpack.pack` | `thinpack_pack.zig` |
| `codecommit.pack` | `codecommit_pack.zig` |
| `delta_before_base.pack` | `delta_before_base_pack.zig` |

**Proven bytes (Class A goldens):**

| Field | Value | Golden |
|-------|-------|--------|
| Signature | `PACK` (bytes 0–3) | `data/goldens/packfile_header/` |
| Version | 2 (big-endian u32 at offset 4) | `data/goldens/packfile_header/` |
| Object count | 31 (big-endian u32 at offset 8) | `data/goldens/packfile_header/` |
| Pack trailer SHA-1 | `a3fed42da1e8189a077c0e6846c040dcf73fc9dd` (last 20 bytes) | `data/goldens/packfile_checksum/` |
| Ref-delta object count | 31 | `data/goldens/packfile_ref_delta_count/` |
| Ref-delta pack trailer | `c544593473465e6315ad4182d04d366c4592b829` | `data/goldens/packfile_ref_delta_count/` |

The basic trailer hash is also recorded as `packfile_hash` in `data/goldens/idxfile_basic_count/` (Phase 2).

Phase 2 added `idxfile/basic.idx`. Phase 3 vendors the matching full packs under `packfile/`.
