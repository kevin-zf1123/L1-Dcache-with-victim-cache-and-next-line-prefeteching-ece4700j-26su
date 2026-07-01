#!/usr/bin/env python3
"""Summarize SPEC trace replay WORKLOAD_RESULT logs.

Input logs are expected to contain one or more lines of the form emitted by
the SystemVerilog testbenches:

    WORKLOAD_RESULT name=trace_replay ways=2 vc=4 ...

The script writes a CSV with all parsed fields and a compact Markdown summary
that compares hit rate, victim-hit rate, memory traffic, and prefetch accuracy.
"""

from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path


RESULT_PREFIX = "WORKLOAD_RESULT "


def parse_workload_result(line: str) -> dict[str, str]:
    row: dict[str, str] = {}
    for field in line.strip().split()[1:]:
        if "=" in field:
            key, value = field.split("=", 1)
            row[key] = value
    return row


def infer_metadata(path: Path) -> dict[str, str]:
    stem = path.stem
    metadata = {"log": path.name}
    bench = re.search(r"spec2026_(708|721|723|767|777)_(.+?)_test_", stem)
    if bench:
        metadata["benchmark"] = f"{bench.group(1)}.{bench.group(2)}"
    window = re.search(r"_w(\d+)_", stem)
    if window:
        metadata["sample"] = f"w{int(window.group(1)):02d}"
    config = re.search(r"(direct_mapped_vc4|two_way_vc4|two_way_vc8|next_line_prefetch_vc4)", stem)
    if config:
        metadata["config"] = config.group(1)
    return metadata


def numeric(row: dict[str, str], key: str) -> float:
    try:
        return float(row.get(key, "0"))
    except ValueError:
        return 0.0


def enrich(row: dict[str, str]) -> dict[str, str]:
    accesses = numeric(row, "accesses")
    hits = numeric(row, "hits")
    victim_hits = numeric(row, "victim_hits")
    mem_reads = numeric(row, "mem_reads")
    mem_writes = numeric(row, "mem_writes")
    useful = numeric(row, "useful")
    useless = numeric(row, "useless")
    fills = useful + useless

    row["fills"] = str(int(fills))
    row["hit_rate"] = f"{(hits / accesses):.6f}" if accesses else "0"
    row["victim_hit_rate"] = f"{(victim_hits / accesses):.6f}" if accesses else "0"
    row["mem_accesses"] = str(int(mem_reads + mem_writes))
    row["mem_accesses_per_demand"] = f"{((mem_reads + mem_writes) / accesses):.6f}" if accesses else "0"
    row["prefetch_accuracy"] = f"{(useful / fills):.6f}" if fills else "0"
    return row


def collect(log_dir: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for path in sorted(log_dir.rglob("*.log")):
        metadata = infer_metadata(path)
        text = path.read_text(encoding="utf-8", errors="replace")
        inferred_status = ""
        if "ALL TESTS PASSED" in text:
            inferred_status = "PASS"
        elif any(marker in text for marker in ("FATAL", "ERROR", "FAILED")):
            inferred_status = "FAIL"
        for line in text.splitlines():
            if line.startswith(RESULT_PREFIX):
                row = metadata | parse_workload_result(line)
                if not row.get("status") and inferred_status:
                    row["status"] = inferred_status
                rows.append(enrich(row))
    return rows


def write_csv(rows: list[dict[str, str]], path: Path) -> None:
    field_order = [
        "benchmark",
        "sample",
        "config",
        "log",
        "name",
        "ways",
        "vc",
        "prefetch",
        "accesses",
        "hits",
        "misses",
        "victim_hits",
        "hit_rate",
        "victim_hit_rate",
        "mem_reads",
        "mem_writes",
        "mem_accesses",
        "mem_accesses_per_demand",
        "useful",
        "useless",
        "pollution",
        "dropped",
        "fills",
        "prefetch_accuracy",
        "cycles",
        "status",
    ]
    extra = sorted({key for row in rows for key in row} - set(field_order))
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=field_order + extra)
        writer.writeheader()
        writer.writerows(rows)


def write_markdown(rows: list[dict[str, str]], path: Path) -> None:
    lines = [
        "# SPEC Trace Replay Summary",
        "",
        "| benchmark | sample | config | accesses | hit rate | victim hit rate | mem/access | prefetch accuracy | cycles | status |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for row in rows:
        lines.append(
            f"| {row.get('benchmark', '')} | {row.get('sample', '')} | "
            f"{row.get('config', '')} | {row.get('accesses', '')} | "
            f"{row.get('hit_rate', '')} | {row.get('victim_hit_rate', '')} | "
            f"{row.get('mem_accesses_per_demand', '')} | "
            f"{row.get('prefetch_accuracy', '')} | {row.get('cycles', '')} | "
            f"{row.get('status', '')} |"
        )
    lines.append("")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("log_dir", type=Path)
    parser.add_argument("--csv", type=Path, required=True)
    parser.add_argument("--markdown", type=Path, required=True)
    args = parser.parse_args()

    rows = collect(args.log_dir)
    if not rows:
        raise SystemExit(f"no WORKLOAD_RESULT rows found under {args.log_dir}")
    write_csv(rows, args.csv)
    write_markdown(rows, args.markdown)
    print(f"wrote {len(rows)} rows to {args.csv} and {args.markdown}")


if __name__ == "__main__":
    main()
