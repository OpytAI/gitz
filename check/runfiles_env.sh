#!/usr/bin/env bash
# Resolve Bazel runfiles root into RUNFILES_ROOT and WS_ROOT.
# Source this from sh_test entrypoints.

set -euo pipefail

# Prefer RUNFILES_DIR (Bazel 6+ test env). Fall back to TEST_SRCDIR or $0.runfiles.
if [[ -n "${RUNFILES_DIR:-}" && -d "${RUNFILES_DIR}" ]]; then
  RUNFILES_ROOT="${RUNFILES_DIR}"
elif [[ -n "${TEST_SRCDIR:-}" && -d "${TEST_SRCDIR}" ]]; then
  RUNFILES_ROOT="${TEST_SRCDIR}"
else
  _self="${BASH_SOURCE[0]}"
  if [[ -d "${_self}.runfiles" ]]; then
    RUNFILES_ROOT="${_self}.runfiles"
  else
    echo "error: cannot locate runfiles (RUNFILES_DIR/TEST_SRCDIR unset)" >&2
    exit 2
  fi
fi

# Main repo workspace name under bzlmod is typically _main.
WS_NAME="${TEST_WORKSPACE:-_main}"
if [[ -d "${RUNFILES_ROOT}/${WS_NAME}" ]]; then
  WS_ROOT="${RUNFILES_ROOT}/${WS_NAME}"
elif [[ -d "${RUNFILES_ROOT}" ]]; then
  # Some layouts flatten or use the module name.
  if [[ -d "${RUNFILES_ROOT}/gitz" ]]; then
    WS_ROOT="${RUNFILES_ROOT}/gitz"
  else
    WS_ROOT="${RUNFILES_ROOT}"
  fi
else
  echo "error: runfiles root missing: ${RUNFILES_ROOT}" >&2
  exit 2
fi

export RUNFILES_ROOT WS_ROOT WS_NAME

# Prefer hermetic absolute python3 (strict action env PATH is minimal).
if [[ -x /usr/bin/python3 ]]; then
  PYTHON3=/usr/bin/python3
elif command -v python3 >/dev/null 2>&1; then
  PYTHON3="$(command -v python3)"
else
  echo "error: python3 not found" >&2
  exit 2
fi
export PYTHON3
