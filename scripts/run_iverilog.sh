#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM_DIR="${ROOT_DIR}/sim"
mkdir -p "${SIM_DIR}"

run_case() {
    local name="$1"
    local ways="$2"
    local sets="$3"
    local line_bytes="$4"
    local prefetch="$5"
    local victim_entries="$6"
    local prefetch_policy="${7:-1}"
    local pf_opt_level="${8:-3}"
    local output="${SIM_DIR}/${name}.vvp"
    local log="${SIM_DIR}/${name}.log"

    iverilog -g2012 -Wall \
        -s tb_l1d_cache \
        -P "tb_l1d_cache.NUM_WAYS=${ways}" \
        -P "tb_l1d_cache.NUM_SETS=${sets}" \
        -P "tb_l1d_cache.LINE_BYTES=${line_bytes}" \
        -P "tb_l1d_cache.ENABLE_PREFETCH=${prefetch}" \
        -P "tb_l1d_cache.PREFETCH_POLICY=${prefetch_policy}" \
        -P "tb_l1d_cache.PF_OPT_LEVEL=${pf_opt_level}" \
        -P "tb_l1d_cache.VICTIM_ENTRIES=${victim_entries}" \
        -o "${output}" \
        "${ROOT_DIR}/src/l1d_sram.sv" \
        "${ROOT_DIR}/src/l1d_next_line_prefetch.sv" \
        "${ROOT_DIR}/src/l1d_stream_prefetch.sv" \
        "${ROOT_DIR}/src/l1d_prefetch_controller.sv" \
        "${ROOT_DIR}/src/l1d_shadow_cache.sv" \
        "${ROOT_DIR}/src/l1d_cache_legacy.sv" \
        "${ROOT_DIR}/src/l1d_cache_optimized.sv" \
        "${ROOT_DIR}/src/l1d_cache.sv" \
        "${ROOT_DIR}/src/tb_l1d_cache.sv"
    vvp "${output}" "+CONFIG_ID=${name}" | tee "${log}"
}

run_workload_case() {
    local name="$1"
    local ways="$2"
    local sets="$3"
    local line_bytes="$4"
    local prefetch="$5"
    local victim_entries="$6"
    local config_id="${name#workload_}"
    local output="${SIM_DIR}/${name}.vvp"
    local log="${SIM_DIR}/${name}.log"

    iverilog -g2012 -Wall \
        -s tb_l1d_cache \
        -P "tb_l1d_cache.NUM_WAYS=${ways}" \
        -P "tb_l1d_cache.NUM_SETS=${sets}" \
        -P "tb_l1d_cache.LINE_BYTES=${line_bytes}" \
        -P "tb_l1d_cache.ENABLE_PREFETCH=${prefetch}" \
        -P "tb_l1d_cache.VICTIM_ENTRIES=${victim_entries}" \
        -o "${output}" \
        "${ROOT_DIR}/src/l1d_sram.sv" \
        "${ROOT_DIR}/src/l1d_next_line_prefetch.sv" \
        "${ROOT_DIR}/src/l1d_stream_prefetch.sv" \
        "${ROOT_DIR}/src/l1d_prefetch_controller.sv" \
        "${ROOT_DIR}/src/l1d_shadow_cache.sv" \
        "${ROOT_DIR}/src/l1d_cache_legacy.sv" \
        "${ROOT_DIR}/src/l1d_cache_optimized.sv" \
        "${ROOT_DIR}/src/l1d_cache.sv" \
        "${ROOT_DIR}/src/tb_l1d_cache.sv"
    vvp "${output}" +WORKLOADS_ONLY "+CONFIG_ID=${config_id}" | tee "${log}"
}

run_case dm_s8_vc4_pf0 1 8 16 0 4
run_case 2w_s4_vc4_pf0 2 4 16 0 4
run_case 2w_s4_vc8_pf0 2 4 16 0 8
run_case 2w_s4_vc4_pf1 2 4 16 1 4
run_case legacy_2w_s4_vc4_pf1 2 4 16 1 4 0 0
run_workload_case workload_dm_s8_vc4_pf0 1 8 16 0 4
run_workload_case workload_2w_s4_vc4_pf0 2 4 16 0 4
run_workload_case workload_2w_s4_vc8_pf0 2 4 16 0 8
run_workload_case workload_2w_s4_vc4_pf1 2 4 16 1 4

"${ROOT_DIR}/scripts/run_prefetch_unit_tests.sh"

vvp "${SIM_DIR}/2w_s4_vc4_pf0.vvp" \
    "+TRACE=traces/smoke.trace" \
    +TRACE_ID=smoke +CONFIG_ID=2w_s4_vc4_pf0 | \
    tee "${SIM_DIR}/trace_replay_smoke.log"

"${ROOT_DIR}/scripts/summarize_workloads.sh"
echo "Icarus regression passed. Logs are in ${SIM_DIR}."
