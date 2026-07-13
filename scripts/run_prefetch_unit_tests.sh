#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM_DIR="${ROOT_DIR}/sim"
OUTPUT="${SIM_DIR}/prefetch_units.vvp"
LOG="${SIM_DIR}/prefetch_units.log"

mkdir -p "${SIM_DIR}"

iverilog -g2012 -Wall \
    -s tb_l1d_prefetch_units \
    -o "${OUTPUT}" \
    "${ROOT_DIR}/src/l1d_stream_prefetch.sv" \
    "${ROOT_DIR}/src/l1d_prefetch_controller.sv" \
    "${ROOT_DIR}/src/l1d_shadow_cache.sv" \
    "${ROOT_DIR}/src/tb_l1d_prefetch_units.sv"

vvp "${OUTPUT}" | tee "${LOG}"
echo "Prefetch helper unit tests passed. Log: ${LOG}"
