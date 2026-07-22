#!/usr/bin/env bash
set -euo pipefail

# Run the 2026-07-22 feedback replay matrix strictly serially.  Each nested
# campaign also runs one simulator at a time, so this script never creates
# parallel vvp workers.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

CAPTURE_MANIFEST="${L1D_CAPTURE_MANIFEST:-build/spec2026/qemu-private/campaign_manifest.json}"
OUTPUT_ROOT="${L1D_FEEDBACK_OUTPUT_ROOT:-build/spec2026/current-2026-07-22}"
LIST_ONLY=0
SKIP_JOBS=()

usage() {
    echo "usage: $0 [--list] [--skip JOB]..." >&2
}

while (($#)); do
    case "$1" in
        --list)
            LIST_ONLY=1
            shift
            ;;
        --skip)
            if (($# < 2)); then
                usage
                exit 2
            fi
            SKIP_JOBS+=("$2")
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

should_skip() {
    local requested="$1"
    local candidate
    for candidate in "${SKIP_JOBS[@]}"; do
        if [[ "${candidate}" == "${requested}" ]]; then
            return 0
        fi
    done
    return 1
}

# id|variant|output|scope|producer|gap|latency|ready|guard|refill|epoch
JOBS=(
    "main-legacy|legacy|main/legacy|paired|zero-bubble|0|2|periodic|2|8|256"
    "main-p1|p1|main/p1|paired|zero-bubble|0|2|periodic|2|8|256"
    "main-p2|p2|main/p2|paired|zero-bubble|0|2|periodic|2|8|256"
    "main-p3|p3|main/p3|full|zero-bubble|0|2|periodic|2|8|256"
    "main-p3-lite|p3-lite|main/p3-lite|paired|zero-bubble|0|2|periodic|2|8|256"
    "sweep-guard1|p3-lite|sweep/guard1|paired|zero-bubble|0|2|periodic|1|8|256"
    "sweep-guard4|p3-lite|sweep/guard4|paired|zero-bubble|0|2|periodic|4|8|256"
    "sweep-on-refill16|p3-lite|sweep/on-refill16|paired|zero-bubble|0|2|periodic|2|16|256"
    "sweep-on-refill4|p3-lite|sweep/on-refill4|paired|zero-bubble|0|2|periodic|2|4|256"
    "sweep-epoch512|p3-lite|sweep/epoch512|paired|zero-bubble|0|2|periodic|2|8|512"
    "sensitivity-p3-lite-sequential|p3-lite|sensitivity/sequential/p3-lite|paired|sequential|0|2|periodic|2|8|256"
    "sensitivity-p3-lite-gap1|p3-lite|sensitivity/gap1/p3-lite|paired|fixed-gap|1|2|periodic|2|8|256"
    "sensitivity-p3-lite-gap2|p3-lite|sensitivity/gap2/p3-lite|paired|fixed-gap|2|2|periodic|2|8|256"
    "sensitivity-p3-lite-gap4|p3-lite|sensitivity/gap4/p3-lite|paired|fixed-gap|4|2|periodic|2|8|256"
    "sensitivity-p3-lite-gap8|p3-lite|sensitivity/gap8/p3-lite|paired|fixed-gap|8|2|periodic|2|8|256"
    "sensitivity-p3-lite-latency0-always|p3-lite|sensitivity/latency0-always/p3-lite|paired|zero-bubble|0|0|always-ready|2|8|256"
    "sensitivity-p3-lite-latency8-periodic|p3-lite|sensitivity/latency8-periodic/p3-lite|paired|zero-bubble|0|8|periodic|2|8|256"
    "sensitivity-p3-lite-latency8-random|p3-lite|sensitivity/latency8-random/p3-lite|paired|zero-bubble|0|8|deterministic-random|2|8|256"
    "sensitivity-legacy-sequential|legacy|sensitivity/sequential/legacy|paired|sequential|0|2|periodic|2|8|256"
    "sensitivity-legacy-gap1|legacy|sensitivity/gap1/legacy|paired|fixed-gap|1|2|periodic|2|8|256"
    "sensitivity-legacy-gap2|legacy|sensitivity/gap2/legacy|paired|fixed-gap|2|2|periodic|2|8|256"
    "sensitivity-legacy-gap4|legacy|sensitivity/gap4/legacy|paired|fixed-gap|4|2|periodic|2|8|256"
    "sensitivity-legacy-gap8|legacy|sensitivity/gap8/legacy|paired|fixed-gap|8|2|periodic|2|8|256"
    "sensitivity-legacy-latency0-always|legacy|sensitivity/latency0-always/legacy|paired|zero-bubble|0|0|always-ready|2|8|256"
    "sensitivity-legacy-latency8-periodic|legacy|sensitivity/latency8-periodic/legacy|paired|zero-bubble|0|8|periodic|2|8|256"
    "sensitivity-legacy-latency8-random|legacy|sensitivity/latency8-random/legacy|paired|zero-bubble|0|8|deterministic-random|2|8|256"
)

run_job() {
    local id="$1"
    local variant="$2"
    local output="$3"
    local scope="$4"
    local producer="$5"
    local gap="$6"
    local latency="$7"
    local ready="$8"
    local guard="$9"
    local refill="${10}"
    local epoch="${11}"
    local policy opt stream adaptive shadow mshr

    case "${variant}" in
        legacy)
            policy=0; opt=0; stream=0; adaptive=0; shadow=0; mshr=0 ;;
        p1)
            policy=1; opt=1; stream=0; adaptive=0; shadow=0; mshr=0 ;;
        p2)
            policy=1; opt=2; stream=1; adaptive=1; shadow=0; mshr=0 ;;
        p3)
            policy=1; opt=3; stream=1; adaptive=1; shadow=1; mshr=1 ;;
        p3-lite)
            policy=1; opt=3; stream=1; adaptive=0; shadow=0; mshr=1 ;;
        *)
            echo "unknown matrix variant: ${variant}" >&2
            return 2 ;;
    esac

    echo "MATRIX_JOB_START ${id}"
    env \
        L1D_PREFETCH_POLICY="${policy}" \
        L1D_PF_OPT_LEVEL="${opt}" \
        L1D_PF_USE_STREAM="${stream}" \
        L1D_PF_USE_ADAPTIVE="${adaptive}" \
        L1D_PF_USE_SHADOW="${shadow}" \
        L1D_PF_USE_MSHR="${mshr}" \
        L1D_PF_IDLE_GUARD="${guard}" \
        L1D_PF_ON_REFILL="${refill}" \
        L1D_PF_EPOCH_DEMANDS="${epoch}" \
        L1D_PRODUCER_PROFILE="${producer}" \
        L1D_PRODUCER_GAP="${gap}" \
        L1D_MEM_LATENCY="${latency}" \
        L1D_MEM_READY_MODE="${ready}" \
        L1D_REPLAY_SCOPE="${scope}" \
        ./scripts/run_spec_trace_replay.sh \
        "${CAPTURE_MANIFEST}" "${OUTPUT_ROOT}/${output}/logs"
    echo "MATRIX_JOB_PASS ${id}"
}

for job in "${JOBS[@]}"; do
    IFS='|' read -r id variant output scope producer gap latency ready guard refill epoch <<<"${job}"
    if ((LIST_ONLY)); then
        echo "${id}"
    elif should_skip "${id}"; then
        echo "MATRIX_JOB_SKIP ${id}"
    else
        run_job "${id}" "${variant}" "${output}" "${scope}" \
            "${producer}" "${gap}" "${latency}" "${ready}" \
            "${guard}" "${refill}" "${epoch}"
    fi
done

if ((!LIST_ONLY)); then
    echo "MATRIX_ALL_PASS"
fi
