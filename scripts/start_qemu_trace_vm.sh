#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_DIR="${ROOT_DIR}/debian-rv64"

PLUGIN="${L1D_QEMU_PLUGIN:-${ROOT_DIR}/build/qemu-memtrace/qemu_memtrace.dylib}"
PLUGIN_ARGS="${L1D_QEMU_PLUGIN_ARGS:-out=${ROOT_DIR}/traces/qemu-memtrace.trace,start=off,aligned=on,noio=on}"

plugin_option="${PLUGIN}"
if [[ -n "${PLUGIN_ARGS}" ]]; then
  plugin_option="${PLUGIN},${PLUGIN_ARGS}"
fi

exec qemu-system-riscv64 \
  -machine virt \
  -cpu rv64 \
  -smp 4 \
  -m 4096 \
  -nographic \
  -serial mon:stdio \
  -plugin "${plugin_option}" \
  -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-riscv-code.fd \
  -drive if=pflash,format=raw,file="${VM_DIR}/edk2-riscv-vars.fd" \
  -device virtio-blk-device,drive=hd0 \
  -drive if=none,id=hd0,format=qcow2,file="${VM_DIR}/debian-rv64.qcow2" \
  -device virtio-blk-device,drive=cidata \
  -drive if=none,id=cidata,format=raw,media=cdrom,readonly=on,file="${VM_DIR}/seed.iso" \
  -device virtio-net-device,netdev=net0 \
  -netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
  -device virtio-rng-device
