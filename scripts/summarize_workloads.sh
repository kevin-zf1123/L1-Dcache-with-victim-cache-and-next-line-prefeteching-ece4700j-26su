#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM_DIR="${ROOT_DIR}/sim"
OUTPUT="${SIM_DIR}/workload_results.csv"

mkdir -p "${SIM_DIR}"
tmp_output="${OUTPUT}.tmp"
rm -f "${OUTPUT}" "${tmp_output}"
trap 'rm -f "${tmp_output}"' EXIT

if (( $# > 0 )); then
    INPUTS=("$@")
else
    INPUTS=(
        "${SIM_DIR}/workload_dm_s8_vc4_pf0.log"
        "${SIM_DIR}/workload_2w_s4_vc4_pf0.log"
        "${SIM_DIR}/workload_2w_s4_vc8_pf0.log"
        "${SIM_DIR}/workload_2w_s4_vc4_pf1.log"
        "${SIM_DIR}/trace_replay_smoke.log"
    )
fi

for input in "${INPUTS[@]}"; do
    if [[ ! -f "${input}" ]]; then
        echo "summarize_workloads: missing input: ${input}" >&2
        exit 2
    fi
done

python3 "${ROOT_DIR}/scripts/validate_workload_results.py" \
    "${INPUTS[@]}" > "${tmp_output}"

mv "${tmp_output}" "${OUTPUT}"
trap - EXIT

echo "Workload CSV written to ${OUTPUT}."
