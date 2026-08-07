#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/runfiles_env.sh"

# simple_yaml is imported from tools/inventory
export PYTHONPATH="${WS_ROOT}/tools/inventory${PYTHONPATH:+:$PYTHONPATH}"

exec "${PYTHON3}" "${WS_ROOT}/tools/golden/run_goldens.py" \
  --goldens-dir "${WS_ROOT}/data/goldens" \
  "$@"
