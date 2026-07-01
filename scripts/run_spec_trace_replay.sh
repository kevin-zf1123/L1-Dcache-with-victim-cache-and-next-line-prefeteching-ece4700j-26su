#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SAMPLE_DIR="${1:-traces/spec2026}"
LOG_DIR="${2:-${ROOT_DIR}/build/spec2026/replay/logs}"
BIN_DIR="${ROOT_DIR}/build/spec2026/replay/bin"
DECOMPRESS_DIR="${ROOT_DIR}/build/spec2026/replay/decompressed"

mkdir -p "${BIN_DIR}" "${LOG_DIR}" "${DECOMPRESS_DIR}"

compile_case() {
    local name="$1"
    local ways="$2"
    local prefetch="$3"
    local victim_entries="$4"

    iverilog -g2012 -Wall \
        -s tb_l1d_cache \
        -P "tb_l1d_cache.NUM_WAYS=${ways}" \
        -P "tb_l1d_cache.ENABLE_PREFETCH=${prefetch}" \
        -P "tb_l1d_cache.VICTIM_ENTRIES=${victim_entries}" \
        -o "${BIN_DIR}/${name}.vvp" \
        "${ROOT_DIR}/src/l1d_sram.sv" \
        "${ROOT_DIR}/src/l1d_next_line_prefetch.sv" \
        "${ROOT_DIR}/src/l1d_cache.sv" \
        "${ROOT_DIR}/src/tb_l1d_cache.sv"
}

run_replay() {
    local config="$1"
    local trace="$2"
    local stem
    local log
    local trace_arg
    local replay_trace

    if [[ "${trace}" == *.trace.zst ]]; then
        stem="$(basename "${trace}" .trace.zst)"
        replay_trace="${DECOMPRESS_DIR}/${stem}.trace"
        zstd -q -dc "${trace}" > "${replay_trace}"
    else
        stem="$(basename "${trace}" .trace)"
        replay_trace="${trace}"
    fi
    log="${LOG_DIR}/${stem}_${config}.log"
    trace_arg="${replay_trace}"
    if [[ "${trace_arg}" == "${ROOT_DIR}/"* ]]; then
        trace_arg="${trace_arg#${ROOT_DIR}/}"
    fi
    vvp "${BIN_DIR}/${config}.vvp" \
        "+TRACE=${trace_arg}" \
        +TRACE_SKIP_LOAD_CHECKS | tee "${log}"
}

compile_case direct_mapped_vc4 1 0 4
compile_case two_way_vc4 2 0 4
compile_case two_way_vc8 2 0 8
compile_case next_line_prefetch_vc4 2 1 4

shopt -s nullglob
traces=("${SAMPLE_DIR}"/*.trace "${SAMPLE_DIR}"/*.trace.zst)
if [[ "${#traces[@]}" -eq 0 ]]; then
    echo "no trace samples found under ${SAMPLE_DIR}" >&2
    exit 1
fi

for trace in "${traces[@]}"; do
    run_replay direct_mapped_vc4 "${trace}"
    run_replay two_way_vc4 "${trace}"
    run_replay two_way_vc8 "${trace}"
    run_replay next_line_prefetch_vc4 "${trace}"
done
