#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/runfiles_env.sh"

exec "${PYTHON3}" "${WS_ROOT}/tools/inventory/check_api_inventory.py" \
  --packages "${WS_ROOT}/inventories/packages.yaml" \
  --api-dir "${WS_ROOT}/inventories/api" \
  --src-root "${WS_ROOT}/src" \
  "$@"
