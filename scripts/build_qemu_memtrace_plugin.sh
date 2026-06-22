#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/build/qemu-memtrace"
OUT="${OUT_DIR}/qemu_memtrace.dylib"

mkdir -p "${OUT_DIR}"

clang -fPIC -dynamiclib -undefined dynamic_lookup \
  -I/opt/homebrew/include \
  $(pkg-config --cflags glib-2.0) \
  "${ROOT_DIR}/scripts/qemu_memtrace.c" \
  -o "${OUT}"

echo "${OUT}"
