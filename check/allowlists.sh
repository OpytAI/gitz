#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/runfiles_env.sh"

exec "${PYTHON3}" "${WS_ROOT}/tools/inventory/check_allowlists.py" \
  --packages "${WS_ROOT}/inventories/packages.yaml" \
  --allowlists-dir "${WS_ROOT}/inventories/allowlists" \
  "$@"
