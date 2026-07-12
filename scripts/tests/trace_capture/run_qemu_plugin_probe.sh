#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT_DIR="${ROOT_DIR}/build/tests/trace-capture-probe"
LLVM_PREFIX="${LLVM_PREFIX:-/opt/homebrew/opt/llvm}"
OBJCOPY="${OBJCOPY:-${LLVM_PREFIX}/bin/llvm-objcopy}"
CLANG_BIN="${CLANG_BIN:-${LLVM_PREFIX}/bin/clang}"
QEMU_BIN="${L1D_QEMU_BIN:-$(command -v qemu-system-riscv64)}"

mkdir -p "${OUT_DIR}"
plugin="$(${ROOT_DIR}/scripts/build_qemu_memtrace_plugin.sh)"

clang -std=c11 -Wall -Wextra -Werror \
  "${ROOT_DIR}/scripts/tests/trace_capture/test_qemu_memtrace_policy.c" \
  -o "${OUT_DIR}/test_qemu_memtrace_policy"
"${OUT_DIR}/test_qemu_memtrace_policy"

"${CLANG_BIN}" --target=riscv64-unknown-elf -march=rv64gc -mabi=lp64d \
  -c "${ROOT_DIR}/scripts/tests/trace_capture/bare_marker.S" \
  -o "${OUT_DIR}/bare_marker.o"
"${OBJCOPY}" -O binary --only-section=.text \
  "${OUT_DIR}/bare_marker.o" "${OUT_DIR}/bare_marker.bin"

"${QEMU_BIN}" \
  -machine virt -cpu rv64 -accel tcg,thread=single \
  -smp 1,maxcpus=1 -m 128 -nographic -bios none \
  -kernel "${OUT_DIR}/bare_marker.bin" \
  -plugin "${plugin},out=${OUT_DIR}/probe.raw.tsv,mode=count,nonce=0x55,command=7"

grep -q '^# registers status=PASS .* priv=priv satp=satp$' \
  "${OUT_DIR}/probe.raw.tsv"
grep -q '^# summary status=INVALID .*first_violation=start_not_user_mode$' \
  "${OUT_DIR}/probe.raw.tsv"

set +e
"${QEMU_BIN}" -machine virt -smp 2,maxcpus=2 -display none -S \
  -plugin "${plugin},out=${OUT_DIR}/must-not-exist.tsv,mode=count,nonce=0x55,command=7" \
  >"${OUT_DIR}/smp-reject.log" 2>&1
smp_rc=$?
set -e
if [[ ${smp_rc} -eq 0 ]]; then
  echo "QEMU plugin unexpectedly accepted two vCPUs" >&2
  exit 1
fi
grep -q 'requires -smp 1,maxcpus=1' "${OUT_DIR}/smp-reject.log"
echo "QEMU register/ABI probe PASS (expected fail-closed M-mode ROI)"
