#!/usr/bin/env bash
# Offline golden refresh stub — developer workflow only, not used by //check:*.
#
# Intended later: run a small Go helper against pinned ../go-git and write
# expected outputs under data/goldens/. Default Bazel tests must never
# invoke this script.
set -euo pipefail

echo "refresh_oracle_stub: not implemented yet." >&2
echo "Policy: offline only; pin go-git; commit golden diffs; do not wire into //check." >&2
exit 2
