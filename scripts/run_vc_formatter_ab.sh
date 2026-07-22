#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM_DIR="${ROOT_DIR}/sim/vc-formatter-ab"
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
    "${ROOT_DIR}/src/tb_l1d_cache.sv"
)

for formatter_stage in 0 1; do
    output="${SIM_DIR}/vc_formatter_${formatter_stage}.vvp"
    log="${SIM_DIR}/vc_formatter_${formatter_stage}.log"
    iverilog -g2012 -Wall -s tb_l1d_cache \
        -P tb_l1d_cache.NUM_WAYS=2 \
        -P tb_l1d_cache.NUM_SETS=4 \
        -P tb_l1d_cache.LINE_BYTES=16 \
        -P tb_l1d_cache.VICTIM_ENTRIES=4 \
        -P tb_l1d_cache.ENABLE_PREFETCH=0 \
        -P tb_l1d_cache.PREFETCH_POLICY=1 \
        -P "tb_l1d_cache.VC_FORMAT_IN_SWAP=${formatter_stage}" \
        -o "${output}" "${SOURCES[@]}"
    vvp "${output}" "+CONFIG_ID=vc_formatter_${formatter_stage}" | tee "${log}"
    grep -q 'ALL TESTS PASSED' "${log}"
    grep -q 'PASS victim store merge readback' "${log}"
done

echo "VC lookup-versus-swap formatter A/B regressions passed."
