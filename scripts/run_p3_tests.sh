#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
SIM_DIR="${ROOT_DIR}/sim"
OUTPUT="${SIM_DIR}/l1d_cache_p3.vvp"
LOG="${SIM_DIR}/l1d_cache_p3.log"
ZERO_BUBBLE_OUTPUT="${SIM_DIR}/l1d_cache_zero_bubble_p3.vvp"
ZERO_BUBBLE_LOG="${SIM_DIR}/l1d_cache_zero_bubble_p3.log"
ZERO_BUBBLE_SIDECAR="sim/l1d_cache_zero_bubble_p3.sidecar"
ZERO_BUBBLE_TRACE="traces/zero_bubble_p3.trace"
WALL_TIMEOUT_SECONDS="${P3_WALL_TIMEOUT_SECONDS:-10}"

mkdir -p "${SIM_DIR}"

iverilog -g2012 -Wall \
    -s tb_l1d_cache_p3 \
    -o "${OUTPUT}" \
    "${ROOT_DIR}/src/l1d_sram.sv" \
    "${ROOT_DIR}/src/l1d_stream_prefetch.sv" \
    "${ROOT_DIR}/src/l1d_prefetch_controller.sv" \
    "${ROOT_DIR}/src/l1d_shadow_cache.sv" \
    "${ROOT_DIR}/src/l1d_cache_optimized.sv" \
    "${ROOT_DIR}/src/tb_l1d_cache_p3.sv"

set +e
perl -e 'alarm shift; exec @ARGV' \
    "${WALL_TIMEOUT_SECONDS}" vvp "${OUTPUT}" | tee "${LOG}"
sim_status=${PIPESTATUS[0]}
set -e

if [[ ${sim_status} -ne 0 ]]; then
    if [[ ${sim_status} -eq 142 ]]; then
        echo "P3 wall-clock watchdog expired; possible zero-time simulation spin." >&2
    fi
    exit "${sim_status}"
fi

iverilog -g2012 -Wall \
    -s tb_l1d_cache \
    -P tb_l1d_cache.NUM_WAYS=2 \
    -P tb_l1d_cache.NUM_SETS=4 \
    -P tb_l1d_cache.LINE_BYTES=16 \
    -P tb_l1d_cache.ENABLE_PREFETCH=1 \
    -P tb_l1d_cache.VICTIM_ENTRIES=4 \
    -P tb_l1d_cache.PREFETCH_POLICY=1 \
    -P tb_l1d_cache.PF_OPT_LEVEL=3 \
    -P tb_l1d_cache.PRODUCER_PROFILE=1 \
    -P tb_l1d_cache.PRODUCER_GAP=0 \
    -o "${ZERO_BUBBLE_OUTPUT}" \
    "${ROOT_DIR}/src/l1d_sram.sv" \
    "${ROOT_DIR}/src/l1d_next_line_prefetch.sv" \
    "${ROOT_DIR}/src/l1d_stream_prefetch.sv" \
    "${ROOT_DIR}/src/l1d_prefetch_controller.sv" \
    "${ROOT_DIR}/src/l1d_shadow_cache.sv" \
    "${ROOT_DIR}/src/l1d_cache_legacy.sv" \
    "${ROOT_DIR}/src/l1d_cache_optimized.sv" \
    "${ROOT_DIR}/src/l1d_cache.sv" \
    "${ROOT_DIR}/src/tb_l1d_cache.sv"

set +e
perl -e 'alarm shift; exec @ARGV' \
    "${WALL_TIMEOUT_SECONDS}" vvp "${ZERO_BUBBLE_OUTPUT}" \
    "+TRACE=${ZERO_BUBBLE_TRACE}" \
    +TRACE_ID=zero-bubble-p3 \
    +CONFIG_ID=2w_s4_vc4_pf1 \
    +SIDECAR_SCHEMA=3 \
    +PRODUCER_PROFILE=1 \
    +PRODUCER_GAP=0 \
    "+ACCESS_SIDECAR=${ZERO_BUBBLE_SIDECAR}" | \
    tee "${ZERO_BUBBLE_LOG}"
zero_bubble_status=${PIPESTATUS[0]}
set -e

if [[ ${zero_bubble_status} -ne 0 ]]; then
    if [[ ${zero_bubble_status} -eq 142 ]]; then
        echo "Zero-bubble P3 wall-clock watchdog expired." >&2
    fi
    exit "${zero_bubble_status}"
fi

grep -q 'ZERO_BUBBLE_RESULT overlaps=3' "${ZERO_BUBBLE_LOG}"
grep -Eq 'pf_issued=1 .*pf_merged=1 .*pf_same_line_coalesced=1' \
    "${ZERO_BUBBLE_LOG}"

echo "P3 PF-MSHR regression passed. Log: ${LOG}"

OPT_OUTPUT="${SIM_DIR}/l1d_cache_optimized_p3.vvp"
OPT_LOG="${SIM_DIR}/l1d_cache_optimized_p3.log"
iverilog -g2012 -Wall \
    -s tb_l1d_cache_optimized_p3 \
    -o "${OPT_OUTPUT}" \
    "${ROOT_DIR}/src/l1d_sram.sv" \
    "${ROOT_DIR}/src/l1d_stream_prefetch.sv" \
    "${ROOT_DIR}/src/l1d_prefetch_controller.sv" \
    "${ROOT_DIR}/src/l1d_shadow_cache.sv" \
    "${ROOT_DIR}/src/l1d_cache_optimized.sv" \
    "${ROOT_DIR}/src/tb_l1d_cache_optimized_p3.sv"

set +e
perl -e 'alarm shift; exec @ARGV' \
    "${WALL_TIMEOUT_SECONDS}" vvp "${OPT_OUTPUT}" | tee "${OPT_LOG}"
opt_status=${PIPESTATUS[0]}
set -e
if [[ ${opt_status} -ne 0 ]]; then
    if [[ ${opt_status} -eq 142 ]]; then
        echo "Optimized P3 wall-clock watchdog expired." >&2
    fi
    exit "${opt_status}"
fi
echo "Optimized P3 edge-case regression passed. Log: ${OPT_LOG}"
echo "Zero-bubble trace/P3 merge regression passed. Log: ${ZERO_BUBBLE_LOG}"
