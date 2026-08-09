#!/usr/bin/env bash
# Negative test against *fixture* inventory + empty fixture src (not live src/).
# Expect failure because all four required fixture packages are missing.
set -euo pipefail
source "$(dirname "$0")/runfiles_env.sh"

FF="${WS_ROOT}/data/fail_forward"

set +e
out="$("${PYTHON3}" "${WS_ROOT}/tools/inventory/check_file_inventory.py" \
  --packages "${FF}/packages.yaml" \
  --src-root "${FF}/src" 2>&1)"
rc=$?
set -e

echo "${out}"

if [[ "${rc}" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for fixture with hollow src" >&2
  exit 1
fi

echo "${out}" | grep -q "metric packages.missing=4" || {
  echo "FAIL: expected packages.missing=4" >&2
  exit 1
}
echo "${out}" | grep -q "MISSING required package go='fixture/alpha'" || {
  echo "FAIL: expected MISSING fixture/alpha" >&2
  exit 1
}
echo "${out}" | grep -Eq "reason=(path missing|hollow)" || {
  echo "FAIL: expected hollow/missing reason in messages" >&2
  exit 1
}
echo "${out}" | grep -q "MISSING required package go='fixture/delta'" || {
  echo "FAIL: expected MISSING fixture/delta" >&2
  exit 1
}

echo "file_inventory_fail_forward OK (fixture, exit=${rc}, missing=4)"
