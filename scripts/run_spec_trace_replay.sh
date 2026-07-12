#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
CAPTURE_CAMPAIGN="${1:-${ROOT_DIR}/build/spec2026/qemu-private/campaign_manifest.json}"
LOG_DIR="${2:-${ROOT_DIR}/build/spec2026/replay/logs}"
REPLAY_ROOT="$(cd "$(dirname "${LOG_DIR}")" && pwd 2>/dev/null || dirname "${LOG_DIR}")"
BIN_DIR="${REPLAY_ROOT}/bin"
DECOMPRESS_DIR="${REPLAY_ROOT}/decompressed"
SIDECAR_DIR="${REPLAY_ROOT}/sidecars"
CAPTURE_REPLAY_LIST="${REPLAY_ROOT}/capture_replay_list.json"
RUN_ROWS="${REPLAY_ROOT}/run_rows.tsv"
REPLAY_MANIFEST="${REPLAY_ROOT}/campaign_manifest.json"
ANALYSIS_DIR="${REPLAY_ROOT}/analysis"
readonly TRACE_LINE_BYTES=4096

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
        +TRACE_SKIP_LOAD_CHECKS | tee "${log}"
    if ! grep -q '^WORKLOAD_RESULT .* status=PASS$' "${log}"; then
        echo "replay did not emit a PASS schema=2 result: ${log}" >&2
        return 2
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(cd "$(dirname "${replay_trace}")" && pwd)/$(basename "${replay_trace}")" \
        "${config}" \
        "$(cd "$(dirname "${log}")" && pwd)/$(basename "${log}")" \
        "$(cd "$(dirname "${sidecar}")" && pwd)/$(basename "${sidecar}")" \
        "${sets}" "${ways}" "${line_bytes}" "${victim_entries}" "${prefetch}" \
        "${trace_arg}" "${sidecar_arg}" \
        >> "${RUN_ROWS}"
}

compile_case dm_s8_vc4_pf0 1 8 16 0 4
compile_case 2w_s4_vc4_pf0 2 4 16 0 4
compile_case 2w_s4_vc8_pf0 2 4 16 0 8
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
    run_replay dm_s8_vc4_pf0 "${trace}"
    run_replay 2w_s4_vc4_pf0 "${trace}"
    run_replay 2w_s4_vc8_pf0 "${trace}"
    run_replay 2w_s4_vc4_pf1 "${trace}"
done

actual_runs=$((4 * ${#traces[@]}))
actual_pairs=${#traces[@]}
expected_runs="${L1D_EXPECTED_RUNS:-${actual_runs}}"
expected_pairs="${L1D_EXPECTED_PAIRS:-${actual_pairs}}"

python3 - \
    "${CAPTURE_REPLAY_LIST}" "${RUN_ROWS}" "${REPLAY_MANIFEST}" \
    "${BIN_DIR}" "${expected_runs}" "${expected_pairs}" \
    "${actual_runs}" "${actual_pairs}" <<'PY'
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
    "trace_arg sidecar_arg"
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

expected_configs = {
    "dm_s8_vc4_pf0",
    "2w_s4_vc4_pf0",
    "2w_s4_vc8_pf0",
    "2w_s4_vc4_pf1",
}
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
        raise SystemExit(f"incomplete four-config matrix for {trace_path}: {sorted(configs)}")
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
        f"+ACCESS_SIDECAR={row['sidecar_arg']}", "+TRACE_SKIP_LOAD_CHECKS",
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
            "sets": int(row["sets"]),
            "ways": int(row["ways"]),
            "line_bytes": int(row["line_bytes"]),
            "victim_entries": int(row["victim_entries"]),
            "prefetch": int(row["prefetch"]),
            "timing_profile": "blocking-fixed-latency2-periodic-ready",
            "cold_warm_mode": cold_warm_mode,
        }
    )

manifest = {
    "schema": "l1d-replay-campaign-v2",
    "status": "PASS",
    "artifact_hashes": True,
    "require_sidecars": True,
    "require_capture_manifests": True,
    "expected_runs": expected_runs,
    "expected_pairs": expected_pairs,
    "actual_runs": len(runs),
    "actual_pairs": len(by_trace),
    "paired_config_ids": ["2w_s4_vc4_pf0", "2w_s4_vc4_pf1"],
    "standalone_config_ids": ["dm_s8_vc4_pf0", "2w_s4_vc8_pf0"],
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
