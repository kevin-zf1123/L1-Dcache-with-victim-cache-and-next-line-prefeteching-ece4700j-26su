#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QEMU_BIN="${L1D_QEMU_BIN:-$(command -v qemu-system-riscv64)}"
CC_BIN="${CC:-clang}"

case "$(uname -s)" in
  Darwin) extension=dylib ;;
  *) extension=so ;;
esac

OUT="${L1D_QEMU_PLUGIN_OUT:-${ROOT_DIR}/build/qemu-memtrace/qemu_memtrace.${extension}}"
QEMU_REAL="$(realpath "${QEMU_BIN}")"
QEMU_PREFIX="$(cd "$(dirname "${QEMU_REAL}")/.." && pwd)"
QEMU_INCLUDE="${L1D_QEMU_INCLUDE:-${QEMU_PREFIX}/include}"

version_line="$(${QEMU_BIN} --version | head -1)"
if [[ "${version_line}" != "QEMU emulator version 11.0.1"* ]]; then
  echo "build_qemu_memtrace_plugin: QEMU 11.0.1 required; got ${version_line}" >&2
  exit 2
fi
if ! grep -Eq '^#define QEMU_PLUGIN_VERSION[[:space:]]+6$' \
  "${QEMU_INCLUDE}/qemu-plugin.h"; then
  echo "build_qemu_memtrace_plugin: Plugin API 6 header required" >&2
  exit 2
fi

mkdir -p "$(dirname "${OUT}")"

common_flags=(
  -std=c11 -O2 -fPIC -fvisibility=hidden
  -Wall -Wextra -Werror
  -I"${QEMU_INCLUDE}"
)
while IFS= read -r flag; do
  [[ -n "${flag}" ]] && common_flags+=("${flag}")
done < <(pkg-config --cflags-only-I glib-2.0 | tr ' ' '\n')

if [[ "$(uname -s)" == "Darwin" ]]; then
  "${CC_BIN}" "${common_flags[@]}" -dynamiclib -undefined dynamic_lookup \
    "${ROOT_DIR}/scripts/qemu_memtrace.c" -o "${OUT}"
else
  "${CC_BIN}" "${common_flags[@]}" -shared \
    "${ROOT_DIR}/scripts/qemu_memtrace.c" -o "${OUT}"
fi

echo "${OUT}"
