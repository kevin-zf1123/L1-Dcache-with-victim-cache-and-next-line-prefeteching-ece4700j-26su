#!/usr/bin/env python3
import csv
import sys
from pathlib import Path
import re


def load_rows(path: Path):
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


def key_for(row):
    return (
        row["name"],
        row["ways"],
        row["victim_entries"],
        row["pb_entries"],
    )


def to_int(row, field):
    value = row.get(field, "")
    return int(value) if value not in ("", None) else 0


ACCESS_RE = re.compile(r"^ACCESS_RESULT (.+)$")
PREFETCH_RE = re.compile(r"^PREFETCH_EVENT (.+)$")
WORKLOAD_BEGIN_RE = re.compile(r"^WORKLOAD_BEGIN (.+)$")


def parse_kv_blob(blob: str):
    result = {}
    for token in blob.strip().split():
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        result[key] = value
    return result


def parse_prefetch_log(path: Path):
    workloads = {}
    current_workload = None

    with path.open() as f:
        for raw_line in f:
            line = raw_line.strip()
            workload_match = WORKLOAD_BEGIN_RE.match(line)
            if workload_match:
                entry = parse_kv_blob(workload_match.group(1))
                current_workload = entry.get("name")
                workloads[current_workload] = {
                    "accesses": [],
                    "issues": {},
                    "fills": {},
                }
                continue
            access_match = ACCESS_RE.match(line)
            if access_match:
                if current_workload is None:
                    continue
                entry = parse_kv_blob(access_match.group(1))
                workloads[current_workload]["accesses"].append(entry)
                continue
            prefetch_match = PREFETCH_RE.match(line)
            if prefetch_match:
                if current_workload is None:
                    continue
                entry = parse_kv_blob(prefetch_match.group(1))
                kind = entry.get("kind")
                line_addr = entry.get("line")
                cycle = int(entry.get("cycle", "0"))
                if kind == "issue" and line_addr is not None and \
                        line_addr not in workloads[current_workload]["issues"]:
                    workloads[current_workload]["issues"][line_addr] = cycle
                elif kind == "fill" and line_addr is not None and \
                        line_addr not in workloads[current_workload]["fills"]:
                    workloads[current_workload]["fills"][line_addr] = cycle

    results = {}
    for workload_name, workload in workloads.items():
        late_prefetch_misses = 0
        prefetched_miss_candidates = 0
        filled_before_miss = 0
        on_time_uses = 0
        for entry in workload["accesses"]:
            line_addr = entry.get("line")
            cycle = int(entry.get("cycle", "0"))
            is_miss = int(entry.get("miss", "0")) != 0
            used_prefetch = int(entry.get("used_prefetch", "0")) != 0
            issue_cycle = workload["issues"].get(line_addr)
            fill_cycle = workload["fills"].get(line_addr)

            if used_prefetch:
                on_time_uses += 1

            if is_miss and issue_cycle is not None and issue_cycle <= cycle:
                prefetched_miss_candidates += 1
                if fill_cycle is None or fill_cycle > cycle:
                    late_prefetch_misses += 1
                else:
                    filled_before_miss += 1

        results[workload_name] = {
            "late_prefetch_misses": late_prefetch_misses,
            "prefetched_miss_candidates": prefetched_miss_candidates,
            "filled_before_miss": filled_before_miss,
            "on_time_uses": on_time_uses,
        }
    return results


def main():
    csv_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("sim/workload_results.csv")
    rows = load_rows(csv_path)
    baseline = {}
    enabled = {}

    for row in rows:
        key = key_for(row)
        if row["prefetch"] == "0":
            baseline[key] = row
        elif row["prefetch"] == "1":
            enabled[key] = row

    fieldnames = [
        "name",
        "ways",
        "victim_entries",
        "pb_entries",
        "baseline_misses",
        "prefetch_misses",
        "true_pollution",
        "miss_reduction",
        "baseline_mem_total_bytes",
        "prefetch_mem_total_bytes",
        "bandwidth_overhead_bytes",
        "baseline_cycles",
        "prefetch_cycles",
        "cycle_delta",
        "prefetch_issued",
        "prefetch_fills",
        "prefetch_useful",
        "avg_issue_to_fill",
        "avg_fill_to_use",
        "late_prefetch_misses",
        "prefetched_miss_candidates",
        "filled_before_miss",
        "on_time_uses",
        "prefetch_accuracy",
        "bytes_per_useful",
    ]

    writer = csv.DictWriter(sys.stdout, fieldnames=fieldnames)
    writer.writeheader()

    for key in sorted(enabled):
        if key not in baseline:
            continue
        base = baseline[key]
        pref = enabled[key]

        baseline_misses = to_int(base, "misses")
        prefetch_misses = to_int(pref, "misses")
        true_pollution = max(prefetch_misses - baseline_misses, 0)
        miss_reduction = max(baseline_misses - prefetch_misses, 0)
        prefetch_fills = to_int(pref, "prefetch_fills")
        prefetch_useful = to_int(pref, "useful")
        prefetch_accuracy = (
            float(prefetch_useful) / float(prefetch_fills)
            if prefetch_fills > 0 else 0.0
        )
        log_metrics = {
            "late_prefetch_misses": 0,
            "prefetched_miss_candidates": 0,
            "filled_before_miss": 0,
            "on_time_uses": 0,
        }
        prefetch_log = csv_path.parent / f'workload_next_line_prefetch_pb{pref["pb_entries"]}_vc{pref["victim_entries"]}.log'
        if prefetch_log.exists():
            log_metrics = parse_prefetch_log(prefetch_log).get(pref["name"], log_metrics)

        writer.writerow({
            "name": pref["name"],
            "ways": pref["ways"],
            "victim_entries": pref["victim_entries"],
            "pb_entries": pref["pb_entries"],
            "baseline_misses": baseline_misses,
            "prefetch_misses": prefetch_misses,
            "true_pollution": true_pollution,
            "miss_reduction": miss_reduction,
            "baseline_mem_total_bytes": to_int(base, "mem_total_bytes"),
            "prefetch_mem_total_bytes": to_int(pref, "mem_total_bytes"),
            "bandwidth_overhead_bytes":
                to_int(pref, "mem_total_bytes") - to_int(base, "mem_total_bytes"),
            "baseline_cycles": to_int(base, "cycles"),
            "prefetch_cycles": to_int(pref, "cycles"),
            "cycle_delta": to_int(pref, "cycles") - to_int(base, "cycles"),
            "prefetch_issued": to_int(pref, "prefetch_issued"),
            "prefetch_fills": prefetch_fills,
            "prefetch_useful": prefetch_useful,
            "avg_issue_to_fill": to_int(pref, "avg_issue_to_fill"),
            "avg_fill_to_use": to_int(pref, "avg_fill_to_use"),
            "late_prefetch_misses": log_metrics["late_prefetch_misses"],
            "prefetched_miss_candidates": log_metrics["prefetched_miss_candidates"],
            "filled_before_miss": log_metrics["filled_before_miss"],
            "on_time_uses": log_metrics["on_time_uses"],
            "prefetch_accuracy": f"{prefetch_accuracy:.4f}",
            "bytes_per_useful": to_int(pref, "bytes_per_useful"),
        })


if __name__ == "__main__":
    main()
