#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM_DIR="${ROOT_DIR}/sim"
mkdir -p "${SIM_DIR}"
rm -f "${SIM_DIR}"/*.log "${SIM_DIR}"/*.vvp "${SIM_DIR}"/workload_results.csv

run_case() {
    local name="$1"
    local ways="$2"
    local prefetch="$3"
    local victim_entries="$4"
    local pb_size="${5:-4}"
    local output="${SIM_DIR}/${name}.vvp"
    local log="${SIM_DIR}/${name}.log"

    iverilog -g2012 -Wall \
        -s tb_l1d_cache \
        -P "tb_l1d_cache.NUM_WAYS=${ways}" \
        -P "tb_l1d_cache.ENABLE_PREFETCH=${prefetch}" \
        -P "tb_l1d_cache.VICTIM_ENTRIES=${victim_entries}" \
        -P "tb_l1d_cache.PREFETCH_BUFFER_SIZE=${pb_size}" \
        -o "${output}" \
        "${ROOT_DIR}/src/l1d_sram.sv" \
        "${ROOT_DIR}/src/l1d_prefetch_buffer.sv" \
        "${ROOT_DIR}/src/l1d_next_line_prefetch.sv" \
        "${ROOT_DIR}/src/l1d_cache.sv" \
        "${ROOT_DIR}/src/tb_l1d_cache.sv"
    vvp "${output}" | tee "${log}"
}

run_workload_case() {
    local name="$1"
    local ways="$2"
    local prefetch="$3"
    local victim_entries="$4"
    local pb_size="${5:-4}"
    local output="${SIM_DIR}/${name}.vvp"
    local log="${SIM_DIR}/${name}.log"

    iverilog -g2012 -Wall \
        -s tb_l1d_cache \
        -P "tb_l1d_cache.NUM_WAYS=${ways}" \
        -P "tb_l1d_cache.ENABLE_PREFETCH=${prefetch}" \
        -P "tb_l1d_cache.VICTIM_ENTRIES=${victim_entries}" \
        -P "tb_l1d_cache.PREFETCH_BUFFER_SIZE=${pb_size}" \
        -o "${output}" \
        "${ROOT_DIR}/src/l1d_sram.sv" \
        "${ROOT_DIR}/src/l1d_next_line_prefetch.sv" \
        "${ROOT_DIR}/src/l1d_prefetch_buffer.sv" \
        "${ROOT_DIR}/src/l1d_cache.sv" \
        "${ROOT_DIR}/src/tb_l1d_cache.sv"
    vvp "${output}" +WORKLOADS_ONLY | tee "${log}"
}

run_case direct_mapped_vc4 1 0 4
run_case two_way_vc4 2 0 4
run_case two_way_vc8 2 0 8
run_case two_way_vc0 2 0 0
run_case next_line_prefetch_vc4 2 1 4
run_case next_line_prefetch_vc0 2 1 0
run_case next_line_prefetch_pb0_vc4 2 1 4 0
run_case next_line_prefetch_pb0_vc0 2 1 0 0
run_workload_case workload_two_way_vc0 2 0 0
run_workload_case workload_direct_mapped_vc4 1 0 4
run_workload_case workload_two_way_vc4 2 0 4
run_workload_case workload_next_line_prefetch_pb0_vc0 2 1 0 0
run_workload_case workload_next_line_prefetch_pb4_vc0 2 1 0 4
run_workload_case workload_next_line_prefetch_pb0_vc4 2 1 4 0
run_workload_case workload_next_line_prefetch_pb4_vc4 2 1 4 4

vvp "${SIM_DIR}/two_way_vc4.vvp" \
    "+TRACE=traces/smoke.trace" | \
    tee "${SIM_DIR}/trace_replay_smoke.log"

vvp "${SIM_DIR}/two_way_vc8.vvp" \
    "+TRACE=traces/test.trace" "+VCD" | \
    tee "${SIM_DIR}/spec2026_test_trace.log"

# vvp "${SIM_DIR}/two_way_vc8.vvp" \
#     "+TRACE=traces/spec2026_782_lbm_r_test_1m.trace" | \
#     tee "${SIM_DIR}/spec2026_trace.log"


"${ROOT_DIR}/scripts/summarize_workloads.sh"
echo "Icarus regression passed. Logs are in ${SIM_DIR}."
