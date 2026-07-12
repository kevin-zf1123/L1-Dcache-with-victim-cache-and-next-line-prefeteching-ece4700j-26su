#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-${SCRIPT_DIR}/../../build/trace-roi-guest}"
CC_BIN="${CC:-cc}"

mkdir -p "${OUT_DIR}"

target="$(${CC_BIN} -dumpmachine 2>/dev/null || true)"
case "${target}" in
  riscv64*-linux-gnu*) ;;
  *)
    echo "build_guest_tools: RV64 glibc compiler required, got '${target}'" >&2
    exit 2
    ;;
esac

"${CC_BIN}" -std=c11 -O2 -fPIC -fvisibility=hidden -Wall -Wextra -Werror \
  -shared "${SCRIPT_DIR}/libl1d_roi.c" -ldl \
  -Wl,-soname,libl1d_roi.so -o "${OUT_DIR}/libl1d_roi.so"

"${CC_BIN}" -std=c11 -O2 -Wall -Wextra -Werror \
  "${SCRIPT_DIR}/trace_exec.c" -o "${OUT_DIR}/trace_exec"

file "${OUT_DIR}/libl1d_roi.so" "${OUT_DIR}/trace_exec"
