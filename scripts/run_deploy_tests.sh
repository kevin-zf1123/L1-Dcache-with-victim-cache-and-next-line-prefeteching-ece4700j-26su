#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM_DIR="${ROOT_DIR}/sim/deploy"
mkdir -p "${SIM_DIR}"

SOURCES=(
    "${ROOT_DIR}/src/l1d_sram.sv"
    "${ROOT_DIR}/src/l1d_next_line_prefetch.sv"
    "${ROOT_DIR}/src/l1d_stream_prefetch.sv"
    "${ROOT_DIR}/src/l1d_prefetch_controller.sv"
    "${ROOT_DIR}/src/l1d_shadow_cache.sv"
    "${ROOT_DIR}/src/l1d_cache_legacy.sv"
    "${ROOT_DIR}/src/l1d_cache_optimized.sv"
    "${ROOT_DIR}/src/l1d_cache.sv"
    "${ROOT_DIR}/src/l1d_cache_deploy.sv"
    "${ROOT_DIR}/src/l1d_fpga_harness.sv"
    "${ROOT_DIR}/src/tb_l1d_fpga_harness.sv"
)

run_case() {
    local name="$1"
    local enable_prefetch="$2"
    local policy="$3"
    local level="$4"
    local stream="$5"
    local adaptive="$6"
    local shadow="$7"
    local mshr="$8"
    local output="${SIM_DIR}/${name}.vvp"
    local log="${SIM_DIR}/${name}.log"

    iverilog -g2012 -Wall -s tb_l1d_fpga_harness \
        -P "tb_l1d_fpga_harness.ENABLE_PREFETCH=${enable_prefetch}" \
        -P "tb_l1d_fpga_harness.PREFETCH_POLICY=${policy}" \
        -P "tb_l1d_fpga_harness.PF_OPT_LEVEL=${level}" \
        -P "tb_l1d_fpga_harness.PF_USE_STREAM=${stream}" \
        -P "tb_l1d_fpga_harness.PF_USE_ADAPTIVE=${adaptive}" \
        -P "tb_l1d_fpga_harness.PF_USE_SHADOW=${shadow}" \
        -P "tb_l1d_fpga_harness.PF_USE_MSHR=${mshr}" \
        -o "${output}" "${SOURCES[@]}"
    vvp "${output}" | tee "${log}"
}

run_case optimized_pf0 0 1 1 0 0 0 0
run_case p3_deploy 1 1 3 1 1 1 1
run_case p3_no_shadow 1 1 3 1 1 0 1
run_case p3_mshr_fixed 1 1 3 1 0 0 1
run_case p3_stream_only 1 1 3 1 0 0 0
run_case legacy_matched 1 0 0 0 0 0 0

echo "Deploy-wrapper and feature-ablation regressions passed."
