#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=runfiles_env.sh
source "$(dirname "$0")/runfiles_env.sh"

exec "${PYTHON3}" "${WS_ROOT}/tools/inventory/check_file_inventory.py" \
  --packages "${WS_ROOT}/inventories/packages.yaml" \
  --src-root "${WS_ROOT}/src" \
  "$@"
