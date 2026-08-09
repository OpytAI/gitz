#!/usr/bin/env bash
# Negative test against *fixture* API seeds + empty fixture src (not live src/).
set -euo pipefail
source "$(dirname "$0")/runfiles_env.sh"

FF="${WS_ROOT}/data/fail_forward"

set +e
out="$("${PYTHON3}" "${WS_ROOT}/tools/inventory/check_api_inventory.py" \
  --packages "${FF}/packages.yaml" \
  --api-dir "${FF}/api" \
  --src-root "${FF}/src" 2>&1)"
rc=$?
set -e

echo "${out}"

if [[ "${rc}" -eq 0 ]]; then
  echo "FAIL: expected non-zero exit for fixture API inventory" >&2
  exit 1
fi

echo "${out}" | grep -q "API package missing or hollow" || {
  echo "FAIL: expected missing API package messages" >&2
  exit 1
}
echo "${out}" | grep -q "fixture/alpha" || {
  echo "FAIL: expected fixture/alpha in messages" >&2
  exit 1
}
# A required package without an API seed must be reported.
echo "${out}" | grep -q "API inventory missing for required package go='fixture/gamma'" || {
  echo "FAIL: expected missing API inventory for fixture/gamma" >&2
  exit 1
}
echo "${out}" | grep -Eq "metric api\.(mapped_fail|packages|missing_for_required)=" || {
  echo "FAIL: expected api fail metrics" >&2
  exit 1
}

echo "api_inventory_fail_forward OK (fixture, exit=${rc})"
