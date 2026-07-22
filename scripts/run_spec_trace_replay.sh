#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
CAPTURE_CAMPAIGN="${1:-${ROOT_DIR}/build/spec2026/qemu-private/campaign_manifest.json}"
LOG_DIR="${2:-${ROOT_DIR}/build/spec2026/replay/logs}"
mkdir -p "$(dirname "${LOG_DIR}")"
REPLAY_ROOT="$(cd "$(dirname "${LOG_DIR}")" && pwd)"
BIN_DIR="${REPLAY_ROOT}/bin"
DECOMPRESS_DIR="${REPLAY_ROOT}/decompressed"
SIDECAR_DIR="${REPLAY_ROOT}/sidecars"
CAPTURE_REPLAY_LIST="${REPLAY_ROOT}/capture_replay_list.json"
RUN_ROWS="${REPLAY_ROOT}/run_rows.tsv"
REPLAY_MANIFEST="${REPLAY_ROOT}/campaign_manifest.json"
ANALYSIS_DIR="${REPLAY_ROOT}/analysis"
readonly TRACE_LINE_BYTES=4096

PREFETCH_POLICY="${L1D_PREFETCH_POLICY:-1}"
PF_OPT_LEVEL="${L1D_PF_OPT_LEVEL:-3}"
if (( PF_OPT_LEVEL >= 2 )); then
    DEFAULT_PF_USE_STREAM=1
    DEFAULT_PF_USE_ADAPTIVE=1
else
    DEFAULT_PF_USE_STREAM=0
    DEFAULT_PF_USE_ADAPTIVE=0
fi
if (( PF_OPT_LEVEL >= 3 )); then
    DEFAULT_PF_USE_SHADOW=1
    DEFAULT_PF_USE_MSHR=1
else
    DEFAULT_PF_USE_SHADOW=0
    DEFAULT_PF_USE_MSHR=0
fi
PF_USE_STREAM="${L1D_PF_USE_STREAM:-${DEFAULT_PF_USE_STREAM}}"
PF_USE_ADAPTIVE="${L1D_PF_USE_ADAPTIVE:-${DEFAULT_PF_USE_ADAPTIVE}}"
PF_USE_SHADOW="${L1D_PF_USE_SHADOW:-${DEFAULT_PF_USE_SHADOW}}"
PF_USE_MSHR="${L1D_PF_USE_MSHR:-${DEFAULT_PF_USE_MSHR}}"
PF_IDLE_GUARD="${L1D_PF_IDLE_GUARD:-2}"
PF_EPOCH_DEMANDS="${L1D_PF_EPOCH_DEMANDS:-256}"
PF_OFF_DEMANDS="${L1D_PF_OFF_DEMANDS:-512}"
PF_PROBE_BUDGET="${L1D_PF_PROBE_BUDGET:-8}"
PF_PROBE_REFILL="${L1D_PF_PROBE_REFILL:-16}"
PF_ON_REFILL="${L1D_PF_ON_REFILL:-8}"
VC_FORMAT_IN_SWAP="${L1D_VC_FORMAT_IN_SWAP:-1}"
PRODUCER_PROFILE="${L1D_PRODUCER_PROFILE:-zero-bubble}"
PRODUCER_GAP="${L1D_PRODUCER_GAP:-0}"
SIDECAR_SCHEMA="${L1D_SIDECAR_SCHEMA:-3}"
MEM_LATENCY="${L1D_MEM_LATENCY:-2}"
MEM_READY_MODE="${L1D_MEM_READY_MODE:-periodic}"
REPLAY_SCOPE="${L1D_REPLAY_SCOPE:-full}"

case "${PREFETCH_POLICY}" in 0|1) ;; *)
    echo "L1D_PREFETCH_POLICY must be 0 or 1" >&2; exit 2 ;; esac
case "${PF_OPT_LEVEL}" in 0|1|2|3) ;; *)
    echo "L1D_PF_OPT_LEVEL must be in 0..3" >&2; exit 2 ;; esac
if [[ "${PREFETCH_POLICY}" == 0 && "${PF_OPT_LEVEL}" != 0 ]]; then
    echo "legacy L1D_PREFETCH_POLICY=0 requires L1D_PF_OPT_LEVEL=0" >&2
    exit 2
fi
if [[ "${PREFETCH_POLICY}" == 1 && "${PF_OPT_LEVEL}" == 0 ]]; then
    echo "optimized L1D_PREFETCH_POLICY=1 requires L1D_PF_OPT_LEVEL in 1..3" >&2
    exit 2
fi
for feature_name in PF_USE_STREAM PF_USE_ADAPTIVE PF_USE_SHADOW PF_USE_MSHR \
                    VC_FORMAT_IN_SWAP; do
    feature_value="${!feature_name}"
    if [[ "${feature_value}" != 0 && "${feature_value}" != 1 ]]; then
        echo "${feature_name} must be 0 or 1" >&2
        exit 2
    fi
done
for tuning_name in PF_IDLE_GUARD PF_EPOCH_DEMANDS PF_OFF_DEMANDS \
                   PF_PROBE_BUDGET PF_PROBE_REFILL PF_ON_REFILL; do
    tuning_value="${!tuning_name}"
    if [[ ! "${tuning_value}" =~ ^[0-9]+$ ]]; then
        echo "${tuning_name} must be a non-negative integer" >&2
        exit 2
    fi
done
if (( PF_IDLE_GUARD > 7 || PF_EPOCH_DEMANDS < 1 || PF_OFF_DEMANDS < 1 ||
      PF_PROBE_BUDGET < 1 || PF_PROBE_REFILL < 1 || PF_ON_REFILL < 1 )); then
    echo "prefetch tuning values are outside supported ranges" >&2
    exit 2
fi
case "${PRODUCER_PROFILE}" in
    sequential) PRODUCER_PROFILE_CODE=0 ;;
    zero-bubble) PRODUCER_PROFILE_CODE=1 ;;
    fixed-gap) PRODUCER_PROFILE_CODE=2 ;;
    *) echo "L1D_PRODUCER_PROFILE must be sequential, zero-bubble, or fixed-gap" >&2; exit 2 ;;
esac
if [[ ! "${PRODUCER_GAP}" =~ ^[0-9]+$ ]]; then
    echo "L1D_PRODUCER_GAP must be a non-negative integer" >&2
    exit 2
fi
if [[ "${PRODUCER_PROFILE}" == fixed-gap ]]; then
    case "${PRODUCER_GAP}" in 1|2|4|8) ;; *)
        echo "fixed-gap L1D_PRODUCER_GAP must be 1, 2, 4, or 8" >&2; exit 2 ;; esac
elif [[ "${PRODUCER_GAP}" != 0 ]]; then
    echo "${PRODUCER_PROFILE} requires L1D_PRODUCER_GAP=0" >&2
    exit 2
fi
case "${SIDECAR_SCHEMA}" in 2|3) ;; *)
    echo "L1D_SIDECAR_SCHEMA must be 2 or 3" >&2; exit 2 ;; esac
if [[ ! "${MEM_LATENCY}" =~ ^[0-9]+$ ]]; then
    echo "L1D_MEM_LATENCY must be a non-negative integer" >&2
    exit 2
fi
case "${MEM_READY_MODE}" in
    always-ready) MEM_READY_MODE_CODE=0 ;;
    periodic) MEM_READY_MODE_CODE=1 ;;
    deterministic-random) MEM_READY_MODE_CODE=2 ;;
    *)
        echo "L1D_MEM_READY_MODE must be always-ready, periodic, or deterministic-random" >&2
        exit 2 ;;
esac
case "${REPLAY_SCOPE}" in full|paired) ;; *)
    echo "L1D_REPLAY_SCOPE must be full or paired" >&2; exit 2 ;; esac

mkdir -p "${BIN_DIR}" "${LOG_DIR}" "${DECOMPRESS_DIR}" "${SIDECAR_DIR}"

# A failed new campaign must never leave an older PASS manifest or analysis
# looking current.  Per-run logs may remain for diagnosis, but without these
# authoritative outputs they cannot be consumed as a valid campaign.
cleanup_authoritative_outputs() {
    rm -f "${CAPTURE_REPLAY_LIST}" "${RUN_ROWS}" \
        "${REPLAY_MANIFEST}" "${REPLAY_MANIFEST}.sha256"
    rm -rf "${ANALYSIS_DIR}"
}

cleanup_on_failure() {
    local status=$?
    if [[ ${status} -ne 0 ]]; then
        set +e
        cleanup_authoritative_outputs
    fi
}

trap cleanup_on_failure EXIT
cleanup_authoritative_outputs
VVP_BIN="$(command -v vvp)"

if [[ ! -f "${CAPTURE_CAMPAIGN}" ]]; then
    echo "capture campaign manifest not found: ${CAPTURE_CAMPAIGN}" >&2
    exit 1
fi
python3 "${ROOT_DIR}/scripts/capture_spec_qemu_windows.py" \
    --repo "${ROOT_DIR}" \
    --validate-campaign "${CAPTURE_CAMPAIGN}" \
    --replay-list "${CAPTURE_REPLAY_LIST}"
: > "${RUN_ROWS}"

compile_case() {
    local name="$1"
    local ways="$2"
    local sets="$3"
    local line_bytes="$4"
    local prefetch="$5"
    local victim_entries="$6"

    iverilog -g2012 -Wall \
        -s tb_l1d_cache \
        -P "tb_l1d_cache.NUM_WAYS=${ways}" \
        -P "tb_l1d_cache.NUM_SETS=${sets}" \
        -P "tb_l1d_cache.LINE_BYTES=${line_bytes}" \
        -P "tb_l1d_cache.ENABLE_PREFETCH=${prefetch}" \
        -P "tb_l1d_cache.PREFETCH_POLICY=${PREFETCH_POLICY}" \
        -P "tb_l1d_cache.PF_OPT_LEVEL=${PF_OPT_LEVEL}" \
        -P "tb_l1d_cache.PF_USE_STREAM=${PF_USE_STREAM}" \
        -P "tb_l1d_cache.PF_USE_ADAPTIVE=${PF_USE_ADAPTIVE}" \
        -P "tb_l1d_cache.PF_USE_SHADOW=${PF_USE_SHADOW}" \
        -P "tb_l1d_cache.PF_USE_MSHR=${PF_USE_MSHR}" \
        -P "tb_l1d_cache.PF_IDLE_GUARD=${PF_IDLE_GUARD}" \
        -P "tb_l1d_cache.PF_EPOCH_DEMANDS=${PF_EPOCH_DEMANDS}" \
        -P "tb_l1d_cache.PF_OFF_DEMANDS=${PF_OFF_DEMANDS}" \
        -P "tb_l1d_cache.PF_PROBE_BUDGET=${PF_PROBE_BUDGET}" \
        -P "tb_l1d_cache.PF_PROBE_REFILL=${PF_PROBE_REFILL}" \
        -P "tb_l1d_cache.PF_ON_REFILL=${PF_ON_REFILL}" \
        -P "tb_l1d_cache.VC_FORMAT_IN_SWAP=${VC_FORMAT_IN_SWAP}" \
        -P "tb_l1d_cache.MEM_LATENCY=${MEM_LATENCY}" \
        -P "tb_l1d_cache.MEM_READY_MODE=${MEM_READY_MODE_CODE}" \
        -P "tb_l1d_cache.VICTIM_ENTRIES=${victim_entries}" \
        -o "${BIN_DIR}/${name}.vvp" \
        "${ROOT_DIR}/src/l1d_sram.sv" \
        "${ROOT_DIR}/src/l1d_next_line_prefetch.sv" \
        "${ROOT_DIR}/src/l1d_stream_prefetch.sv" \
        "${ROOT_DIR}/src/l1d_prefetch_controller.sv" \
        "${ROOT_DIR}/src/l1d_shadow_cache.sv" \
        "${ROOT_DIR}/src/l1d_cache_legacy.sv" \
        "${ROOT_DIR}/src/l1d_cache_optimized.sv" \
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
    local sidecar
    local sidecar_arg
    local sets
    local ways
    local line_bytes=16
    local victim_entries
    local prefetch

    case "${config}" in
        dm_s8_vc4_pf0)
            ways=1; sets=8; victim_entries=4; prefetch=0 ;;
        2w_s4_vc4_pf0)
            ways=2; sets=4; victim_entries=4; prefetch=0 ;;
        2w_s4_vc8_pf0)
            ways=2; sets=4; victim_entries=8; prefetch=0 ;;
        2w_s4_vc4_pf1)
            ways=2; sets=4; victim_entries=4; prefetch=1 ;;
        *)
            echo "unknown replay config: ${config}" >&2
            return 2 ;;
    esac

    if [[ "${trace}" == *.trace.zst ]]; then
        stem="$(basename "${trace}" .trace.zst)"
        replay_trace="${DECOMPRESS_DIR}/${stem}.trace"
        zstd -q -dc "${trace}" > "${replay_trace}"
    else
        stem="$(basename "${trace}" .trace)"
        replay_trace="${trace}"
    fi
    python3 - "${replay_trace}" "${TRACE_LINE_BYTES}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
capacity = int(sys.argv[2])
with path.open("rb") as handle:
    for line_number, line in enumerate(handle, 1):
        if len(line) >= capacity:
            raise SystemExit(
                f"{path}:{line_number}: trace line is {len(line)} bytes; "
                f"testbench capacity is {capacity - 1} bytes"
            )
PY
    log="${LOG_DIR}/${stem}_${config}.log"
    sidecar="${SIDECAR_DIR}/${stem}_${config}.tsv"
    trace_arg="${replay_trace}"
    sidecar_arg="${sidecar}"
    if [[ "${trace_arg}" == "${ROOT_DIR}/"* ]]; then
        trace_arg="${trace_arg#${ROOT_DIR}/}"
    fi
    if [[ "${sidecar_arg}" == "${ROOT_DIR}/"* ]]; then
        sidecar_arg="${sidecar_arg#${ROOT_DIR}/}"
    fi
    "${VVP_BIN}" "${BIN_DIR}/${config}.vvp" \
        "+TRACE=${trace_arg}" \
        "+TRACE_ID=${stem}" \
        "+CONFIG_ID=${config}" \
        "+ACCESS_SIDECAR=${sidecar_arg}" \
        "+SIDECAR_SCHEMA=${SIDECAR_SCHEMA}" \
        "+PRODUCER_PROFILE=${PRODUCER_PROFILE_CODE}" \
        "+PRODUCER_GAP=${PRODUCER_GAP}" \
        "+MEM_LATENCY=${MEM_LATENCY}" \
        "+MEM_READY_MODE=${MEM_READY_MODE_CODE}" \
        +TRACE_SKIP_LOAD_CHECKS | tee "${log}"
    if ! grep -Eq '^WORKLOAD_RESULT .* status=PASS( |$)' "${log}"; then
        echo "replay did not emit a PASS WORKLOAD_RESULT: ${log}" >&2
        return 2
    fi
    local row=(
        "$(cd "$(dirname "${replay_trace}")" && pwd)/$(basename "${replay_trace}")"
        "${config}"
        "$(cd "$(dirname "${log}")" && pwd)/$(basename "${log}")"
        "$(cd "$(dirname "${sidecar}")" && pwd)/$(basename "${sidecar}")"
        "${sets}" "${ways}" "${line_bytes}" "${victim_entries}" "${prefetch}"
        "${trace_arg}" "${sidecar_arg}"
        "${PREFETCH_POLICY}" "${PF_OPT_LEVEL}" "${PRODUCER_PROFILE}"
        "${PRODUCER_PROFILE_CODE}" "${PRODUCER_GAP}" "${SIDECAR_SCHEMA}"
        "${MEM_LATENCY}" "${MEM_READY_MODE}" "${MEM_READY_MODE_CODE}"
        "${PF_USE_STREAM}" "${PF_USE_ADAPTIVE}" "${PF_USE_SHADOW}"
        "${PF_USE_MSHR}" "${PF_IDLE_GUARD}" "${PF_EPOCH_DEMANDS}"
        "${PF_OFF_DEMANDS}" "${PF_PROBE_BUDGET}" "${PF_PROBE_REFILL}"
        "${PF_ON_REFILL}" "${VC_FORMAT_IN_SWAP}"
    )
    (IFS=$'\t'; printf '%s\n' "${row[*]}") >> "${RUN_ROWS}"
}

if [[ "${REPLAY_SCOPE}" == full ]]; then
    compile_case dm_s8_vc4_pf0 1 8 16 0 4
fi
compile_case 2w_s4_vc4_pf0 2 4 16 0 4
if [[ "${REPLAY_SCOPE}" == full ]]; then
    compile_case 2w_s4_vc8_pf0 2 4 16 0 8
fi
compile_case 2w_s4_vc4_pf1 2 4 16 1 4

traces=()
while IFS= read -r -d '' trace; do
    traces+=("${trace}")
done < <(python3 - "${CAPTURE_REPLAY_LIST}" <<'PY'
import json
import os
import sys
from pathlib import Path

replay_list_path = Path(sys.argv[1]).resolve()
data = json.loads(replay_list_path.read_text(encoding="utf-8"))
root = Path(data["campaign_manifest"]).resolve().parent
for replay in data["replays"]:
    path = (root / replay["path"]).resolve()
    sys.stdout.buffer.write(os.fsencode(path) + b"\0")
PY
)
if [[ "${#traces[@]}" -eq 0 ]]; then
    echo "capture campaign contains no replay traces: ${CAPTURE_CAMPAIGN}" >&2
    exit 1
fi

for trace in "${traces[@]}"; do
    if [[ "${REPLAY_SCOPE}" == full ]]; then
        run_replay dm_s8_vc4_pf0 "${trace}"
    fi
    run_replay 2w_s4_vc4_pf0 "${trace}"
    if [[ "${REPLAY_SCOPE}" == full ]]; then
        run_replay 2w_s4_vc8_pf0 "${trace}"
    fi
    run_replay 2w_s4_vc4_pf1 "${trace}"
done

if [[ "${REPLAY_SCOPE}" == full ]]; then
    configs_per_trace=4
else
    configs_per_trace=2
fi
actual_runs=$((configs_per_trace * ${#traces[@]}))
actual_pairs=${#traces[@]}
expected_runs="${L1D_EXPECTED_RUNS:-${actual_runs}}"
expected_pairs="${L1D_EXPECTED_PAIRS:-${actual_pairs}}"

python3 - \
    "${CAPTURE_REPLAY_LIST}" "${RUN_ROWS}" "${REPLAY_MANIFEST}" \
    "${BIN_DIR}" "${expected_runs}" "${expected_pairs}" \
    "${actual_runs}" "${actual_pairs}" "${REPLAY_SCOPE}" <<'PY'
import hashlib
import json
import os
import shutil
import subprocess
import sys
from collections import defaultdict
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact(path: Path) -> dict[str, str]:
    resolved = path.resolve()
    if not resolved.is_file():
        raise SystemExit(f"missing replay evidence artifact: {resolved}")
    return {"path": str(resolved), "sha256": sha256(resolved)}


replay_list_path = Path(sys.argv[1]).resolve()
rows_path = Path(sys.argv[2]).resolve()
output_path = Path(sys.argv[3]).resolve()
bin_dir = Path(sys.argv[4]).resolve()
expected_runs = int(sys.argv[5])
expected_pairs = int(sys.argv[6])
declared_actual_runs = int(sys.argv[7])
declared_actual_pairs = int(sys.argv[8])
replay_scope = sys.argv[9]
if replay_scope not in {"full", "paired"}:
    raise SystemExit(f"invalid replay scope passed to manifest builder: {replay_scope}")

replay_list = json.loads(replay_list_path.read_text(encoding="utf-8"))
if replay_list.get("schema") != "l1d-qemu-replay-list-v2" or replay_list.get("status") != "PASS":
    raise SystemExit("capture replay list is not a PASS schema-v2 artifact")
capture_campaign = Path(replay_list["campaign_manifest"]).resolve()
capture_root = capture_campaign.parent
if sha256(capture_campaign) != replay_list.get("campaign_sha256"):
    raise SystemExit("capture campaign changed after replay-list validation")

authoritative = {}
for replay in replay_list["replays"]:
    trace_path = (capture_root / replay["path"]).resolve()
    if sha256(trace_path) != replay["sha256"]:
        raise SystemExit(f"trace changed after capture validation: {trace_path}")
    authoritative[trace_path] = replay

columns = (
    "trace config log sidecar sets ways line_bytes victim_entries prefetch "
    "trace_arg sidecar_arg prefetch_policy pf_opt_level producer_profile "
    "producer_profile_code producer_gap sidecar_schema mem_latency "
    "mem_ready_mode mem_ready_mode_code pf_use_stream pf_use_adaptive "
    "pf_use_shadow pf_use_mshr pf_idle_guard pf_epoch_demands pf_off_demands "
    "pf_probe_budget pf_probe_refill pf_on_refill vc_format_in_swap"
).split()
rows = []
for line_number, line in enumerate(rows_path.read_text(encoding="utf-8").splitlines(), 1):
    values = line.split("\t")
    if len(values) != len(columns):
        raise SystemExit(f"{rows_path}:{line_number}: malformed run row")
    rows.append(dict(zip(columns, values)))
if len(rows) != declared_actual_runs or len(rows) != expected_runs:
    raise SystemExit(
        f"run matrix mismatch: rows={len(rows)} actual_runs={declared_actual_runs} "
        f"expected_runs={expected_runs}"
    )

paired_config_ids = ["2w_s4_vc4_pf0", "2w_s4_vc4_pf1"]
standalone_config_ids = (
    ["dm_s8_vc4_pf0", "2w_s4_vc8_pf0"]
    if replay_scope == "full"
    else []
)
expected_configs = set(paired_config_ids + standalone_config_ids)
by_trace = defaultdict(set)
for row in rows:
    trace_path = Path(row["trace"]).resolve()
    if trace_path not in authoritative:
        raise SystemExit(f"run references a non-authoritative replay: {trace_path}")
    config = row["config"]
    if config in by_trace[trace_path]:
        raise SystemExit(f"duplicate config {config} for {trace_path}")
    by_trace[trace_path].add(config)
if set(by_trace) != set(authoritative):
    raise SystemExit("replay run set differs from authoritative capture replay set")
for trace_path, configs in by_trace.items():
    if configs != expected_configs:
        raise SystemExit(
            f"incomplete {replay_scope} config matrix for {trace_path}: "
            f"{sorted(configs)}"
        )
if len(by_trace) != declared_actual_pairs or len(by_trace) != expected_pairs:
    raise SystemExit(
        f"pair matrix mismatch: traces={len(by_trace)} actual_pairs={declared_actual_pairs} "
        f"expected_pairs={expected_pairs}"
    )

vvp = Path(shutil.which("vvp") or "").resolve()
if not vvp.is_file():
    raise SystemExit("vvp executable is unavailable")
git_commit = subprocess.run(
    ["git", "rev-parse", "HEAD"], check=True, text=True,
    stdout=subprocess.PIPE, cwd=Path.cwd()
).stdout.strip()
git_dirty = bool(subprocess.run(
    ["git", "status", "--porcelain"], check=True, text=True,
    stdout=subprocess.PIPE, cwd=Path.cwd()
).stdout.strip())

runs = []
for row in rows:
    trace_path = Path(row["trace"]).resolve()
    replay = authoritative[trace_path]
    config = row["config"]
    binary = (bin_dir / f"{config}.vvp").resolve()
    log = Path(row["log"]).resolve()
    sidecar = Path(row["sidecar"]).resolve()
    trace_id = trace_path.stem
    command = [
        str(vvp), str(binary), f"+TRACE={row['trace_arg']}",
        f"+TRACE_ID={trace_id}", f"+CONFIG_ID={config}",
        f"+ACCESS_SIDECAR={row['sidecar_arg']}",
        f"+SIDECAR_SCHEMA={row['sidecar_schema']}",
        f"+PRODUCER_PROFILE={row['producer_profile_code']}",
        f"+PRODUCER_GAP={row['producer_gap']}",
        f"+MEM_LATENCY={row['mem_latency']}",
        f"+MEM_READY_MODE={row['mem_ready_mode_code']}",
        "+TRACE_SKIP_LOAD_CHECKS",
    ]
    command_sha256 = hashlib.sha256(
        json.dumps(command, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    ).hexdigest()
    capture_manifest = (capture_root / replay["capture_manifest"]).resolve()
    if replay["kind"] == "whole":
        if replay["warmup_events"] != 0:
            raise SystemExit("whole-ROI replay unexpectedly has warmup events")
        cold_warm_mode = "whole-roi-short"
    else:
        if replay["warmup_events"] <= 0:
            raise SystemExit("sampled replay lacks demand warmup events")
        cold_warm_mode = "demand-warm-measure"
    ready_mode_codes = {
        "always-ready": 0,
        "periodic": 1,
        "deterministic-random": 2,
    }
    mem_latency = int(row["mem_latency"])
    mem_ready_mode = row["mem_ready_mode"]
    mem_ready_mode_code = int(row["mem_ready_mode_code"])
    if mem_latency < 0:
        raise SystemExit(f"negative memory latency in run row: {mem_latency}")
    if ready_mode_codes.get(mem_ready_mode) != mem_ready_mode_code:
        raise SystemExit(
            "memory ready mode/code mismatch in run row: "
            f"{mem_ready_mode}/{mem_ready_mode_code}"
        )
    ready_profile = {
        "always-ready": "always-ready",
        "periodic": "periodic-ready",
        "deterministic-random": "deterministic-random-ready",
    }[mem_ready_mode]
    timing_profile = (
        f"blocking-fixed-latency{mem_latency}-{ready_profile}"
    )
    compile_parameters = {
        "NUM_WAYS": int(row["ways"]),
        "NUM_SETS": int(row["sets"]),
        "LINE_BYTES": int(row["line_bytes"]),
        "VICTIM_ENTRIES": int(row["victim_entries"]),
        "ENABLE_PREFETCH": int(row["prefetch"]),
        "PREFETCH_POLICY": int(row["prefetch_policy"]),
        "PF_OPT_LEVEL": int(row["pf_opt_level"]),
        "PF_USE_STREAM": int(row["pf_use_stream"]),
        "PF_USE_ADAPTIVE": int(row["pf_use_adaptive"]),
        "PF_USE_SHADOW": int(row["pf_use_shadow"]),
        "PF_USE_MSHR": int(row["pf_use_mshr"]),
        "PF_IDLE_GUARD": int(row["pf_idle_guard"]),
        "PF_EPOCH_DEMANDS": int(row["pf_epoch_demands"]),
        "PF_OFF_DEMANDS": int(row["pf_off_demands"]),
        "PF_PROBE_BUDGET": int(row["pf_probe_budget"]),
        "PF_PROBE_REFILL": int(row["pf_probe_refill"]),
        "PF_ON_REFILL": int(row["pf_on_refill"]),
        "VC_FORMAT_IN_SWAP": int(row["vc_format_in_swap"]),
        "MEM_LATENCY": mem_latency,
        "MEM_READY_MODE": mem_ready_mode_code,
    }
    for parameter in (
        "ENABLE_PREFETCH", "PREFETCH_POLICY", "PF_USE_STREAM",
        "PF_USE_ADAPTIVE", "PF_USE_SHADOW", "PF_USE_MSHR",
        "VC_FORMAT_IN_SWAP",
    ):
        if compile_parameters[parameter] not in (0, 1):
            raise SystemExit(
                f"invalid binary compile parameter {parameter}="
                f"{compile_parameters[parameter]}"
            )
    compile_parameters_sha256 = hashlib.sha256(
        json.dumps(
            compile_parameters, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
    ).hexdigest()
    runs.append(
        {
            "benchmark": replay["benchmark"],
            "command": replay["command_index"],
            "window": replay["window_index"],
            "config_id": config,
            "trace_id": trace_id,
            "trace": artifact(trace_path),
            "log": artifact(log),
            "sidecar": artifact(sidecar),
            "capture_manifest": artifact(capture_manifest),
            "capture_window_index": replay["window_index"],
            "capture_window_kind": replay["kind"],
            "warmup_events": replay["warmup_events"],
            "measure_events": replay["measure_events"],
            "total_events": replay["total_events"],
            "simulation_binary": artifact(binary),
            "simulator": artifact(vvp),
            "simulation_cwd": str(Path.cwd().resolve()),
            "simulation_command": command,
            "simulation_command_sha256": command_sha256,
            "simulation_compile_parameters": compile_parameters,
            "simulation_compile_parameters_sha256": compile_parameters_sha256,
            "sets": int(row["sets"]),
            "ways": int(row["ways"]),
            "line_bytes": int(row["line_bytes"]),
            "victim_entries": int(row["victim_entries"]),
            "prefetch": int(row["prefetch"]),
            "prefetch_policy": int(row["prefetch_policy"]),
            "pf_opt_level": int(row["pf_opt_level"]),
            "pf_use_stream": int(row["pf_use_stream"]),
            "pf_use_adaptive": int(row["pf_use_adaptive"]),
            "pf_use_shadow": int(row["pf_use_shadow"]),
            "pf_use_mshr": int(row["pf_use_mshr"]),
            "pf_idle_guard": int(row["pf_idle_guard"]),
            "pf_epoch_demands": int(row["pf_epoch_demands"]),
            "pf_off_demands": int(row["pf_off_demands"]),
            "pf_probe_budget": int(row["pf_probe_budget"]),
            "pf_probe_refill": int(row["pf_probe_refill"]),
            "pf_on_refill": int(row["pf_on_refill"]),
            "vc_format_in_swap": int(row["vc_format_in_swap"]),
            "producer_profile": row["producer_profile"],
            "producer_profile_code": int(row["producer_profile_code"]),
            "producer_gap": int(row["producer_gap"]),
            "sidecar_schema": int(row["sidecar_schema"]),
            "mem_latency": mem_latency,
            "mem_ready_mode": mem_ready_mode,
            "mem_ready_mode_code": mem_ready_mode_code,
            "timing_profile": timing_profile,
            "cold_warm_mode": cold_warm_mode,
        }
    )

manifest = {
    "schema": "l1d-replay-campaign-v3",
    "status": "PASS",
    "artifact_hashes": True,
    "require_sidecars": True,
    "require_capture_manifests": True,
    "expected_runs": expected_runs,
    "expected_pairs": expected_pairs,
    "actual_runs": len(runs),
    "actual_pairs": len(by_trace),
    "replay_scope": replay_scope,
    "paired_config_ids": paired_config_ids,
    "standalone_config_ids": standalone_config_ids,
    "capture_campaign": artifact(capture_campaign),
    "capture_replay_list": artifact(replay_list_path),
    "rtl": {"commit": git_commit, "dirty": git_dirty},
    "runs": runs,
}
output_path.parent.mkdir(parents=True, exist_ok=True)
temporary = output_path.with_suffix(output_path.suffix + ".tmp")
temporary.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
os.replace(temporary, output_path)
PY

shasum -a 256 "${REPLAY_MANIFEST}" > "${REPLAY_MANIFEST}.sha256"
python3 "${ROOT_DIR}/scripts/summarize_spec_replay.py" \
    --manifest "${REPLAY_MANIFEST}" \
    --out-dir "${ANALYSIS_DIR}"

trap - EXIT
echo "Replay campaign manifest: ${REPLAY_MANIFEST}"
echo "Replay analysis: ${ANALYSIS_DIR}"
