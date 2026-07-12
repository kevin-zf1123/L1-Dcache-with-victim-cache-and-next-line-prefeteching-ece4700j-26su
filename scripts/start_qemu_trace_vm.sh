#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_DIR="${L1D_QEMU_VM_DIR:-${ROOT_DIR}/debian-rv64}"
QEMU_BIN="${L1D_QEMU_BIN:-$(command -v qemu-system-riscv64)}"
CODE_PFLASH="${L1D_QEMU_CODE_PFLASH:-/opt/homebrew/share/qemu/edk2-riscv-code.fd}"
case "$(uname -s)" in
  Darwin) plugin_extension=dylib ;;
  *) plugin_extension=so ;;
esac
PLUGIN="${L1D_QEMU_PLUGIN:-${ROOT_DIR}/build/qemu-memtrace/qemu_memtrace.${plugin_extension}}"
PLUGIN_ARGS="${L1D_QEMU_PLUGIN_ARGS:-}"
SSH_PORT="${L1D_QEMU_SSH_PORT:-2222}"

version_line="$(${QEMU_BIN} --version | head -1)"
if [[ "${version_line}" != "QEMU emulator version 11.0.1"* ]]; then
  echo "start_qemu_trace_vm: QEMU 11.0.1 required; got ${version_line}" >&2
  exit 2
fi
if [[ ! -f "${PLUGIN}" ]]; then
  echo "start_qemu_trace_vm: plugin not found: ${PLUGIN}" >&2
  exit 2
fi
if [[ -z "${PLUGIN_ARGS}" ]]; then
  echo "start_qemu_trace_vm: L1D_QEMU_PLUGIN_ARGS is required" >&2
  exit 2
fi
for immutable_input in \
  "${CODE_PFLASH}" \
  "${VM_DIR}/edk2-riscv-vars.fd" \
  "${VM_DIR}/debian-rv64.qcow2" \
  "${VM_DIR}/seed.iso"; do
  if [[ ! -f "${immutable_input}" ]]; then
    echo "start_qemu_trace_vm: immutable VM input not found: ${immutable_input}" >&2
    exit 2
  fi
done

plugin_option="${PLUGIN},${PLUGIN_ARGS}"

# -snapshot plus explicit snapshot=on keeps the licensed VM, UEFI variables,
# and root disk byte-for-byte unchanged across both count and capture passes.
exec "${QEMU_BIN}" \
  -machine virt \
  -cpu rv64 \
  -accel tcg,thread=single \
  -smp 1,maxcpus=1 \
  -m 4096 \
  -snapshot \
  -nographic \
  -serial mon:stdio \
  -plugin "${plugin_option}" \
  -drive if=pflash,format=raw,readonly=on,file="${CODE_PFLASH}" \
  -drive if=pflash,format=raw,snapshot=on,file="${VM_DIR}/edk2-riscv-vars.fd" \
  -device virtio-blk-device,drive=hd0 \
  -drive if=none,id=hd0,format=qcow2,snapshot=on,file="${VM_DIR}/debian-rv64.qcow2" \
  -device virtio-blk-device,drive=cidata \
  -drive if=none,id=cidata,format=raw,media=cdrom,readonly=on,file="${VM_DIR}/seed.iso" \
  -device virtio-net-device,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"${SSH_PORT}"-:22 \
  -device virtio-rng-device
