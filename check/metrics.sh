#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/runfiles_env.sh"

exec "${PYTHON3}" "${WS_ROOT}/tools/inventory/check_metrics.py" \
  --packages "${WS_ROOT}/inventories/packages.yaml" \
  --metrics "${WS_ROOT}/inventories/metrics.yaml" \
  --api-dir "${WS_ROOT}/inventories/api" \
  --allowlists-dir "${WS_ROOT}/inventories/allowlists" \
  --goldens-dir "${WS_ROOT}/data/goldens" \
  --pin-md "${WS_ROOT}/GO_GIT_PIN.md" \
  --src-root "${WS_ROOT}/src" \
  "$@"
