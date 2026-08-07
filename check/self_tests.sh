#!/usr/bin/env bash
# Unit self-tests for inventory/golden Python helpers (stdlib only).
set -euo pipefail
source "$(dirname "$0")/runfiles_env.sh"

export PYTHONPATH="${WS_ROOT}/tools/inventory${PYTHONPATH:+:$PYTHONPATH}"

"${PYTHON3}" "${WS_ROOT}/tools/inventory/simple_yaml.py"
"${PYTHON3}" "${WS_ROOT}/tools/inventory/phase_util.py"
"${PYTHON3}" "${WS_ROOT}/tools/inventory/check_file_inventory.py" --self-test
"${PYTHON3}" "${WS_ROOT}/tools/inventory/check_api_inventory.py" --self-test
"${PYTHON3}" "${WS_ROOT}/tools/inventory/check_metrics.py" --self-test
"${PYTHON3}" "${WS_ROOT}/tools/inventory/check_allowlists.py" --self-test
"${PYTHON3}" "${WS_ROOT}/tools/golden/run_goldens.py" --self-test

echo "all checker self-tests OK"
