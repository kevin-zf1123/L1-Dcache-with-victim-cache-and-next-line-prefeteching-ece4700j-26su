#!/usr/bin/env python3
"""Validate schema-2 WORKLOAD_RESULT logs and emit canonical CSV."""

from __future__ import annotations

import csv
import re
import shlex
import sys
from pathlib import Path
from typing import Mapping, Sequence, TextIO


RESULT_PREFIX = "WORKLOAD_RESULT "
FIELDS = (
    "schema",
    "name",
    "config_id",
    "trace_id",
    "sets",
    "ways",
    "line_bytes",
    "l1_bytes",
    "victim_entries",
    "victim_bytes",
    "total_bytes",
    "prefetch",
    "accesses",
    "hits",
    "misses",
    "victim_hits",
    "demand_mem_reads",
    "prefetch_mem_reads",
    "mem_reads",
    "mem_writes",
    "read_bytes",
    "write_bytes",
    "writebacks",
    "fills",
    "useful",
    "useless_evicted",
    "unused_resident",
    "pollution_proxy",
    "dropped",
    "timely_useful",
    "late_useful",
    "replay_service_cycles",
    "watchdogs",
    "protocol",
    "duplicate_lines",
    "status",
)
STRING_FIELDS = {"name", "config_id", "trace_id", "status"}
INTEGER_FIELDS = tuple(field for field in FIELDS if field not in STRING_FIELDS)
PREFETCH_FIELDS = (
    "prefetch_mem_reads",
    "fills",
    "useful",
    "useless_evicted",
    "unused_resident",
    "pollution_proxy",
    "dropped",
    "timely_useful",
    "late_useful",
)


class WorkloadValidationError(ValueError):
    """Raised when a workload row is incomplete or internally impossible."""


def _fail(context: str, message: str) -> None:
    raise WorkloadValidationError(f"{context}: {message}")


def parse_result(line: str, context: str) -> dict[str, str]:
    try:
        tokens = shlex.split(line[len(RESULT_PREFIX) :])
    except ValueError as exc:
        raise WorkloadValidationError(f"{context}: invalid quoting: {exc}") from exc
    row: dict[str, str] = {}
    for token in tokens:
        if "=" not in token:
            _fail(context, f"malformed token {token!r}")
        key, value = token.split("=", 1)
        if not key or not value:
            _fail(context, f"malformed token {token!r}")
        if key in row:
            _fail(context, f"duplicate field {key}")
        row[key] = value
    for field in FIELDS:
        if field not in row:
            _fail(context, f"missing required field {field}")
    return row


def _equal(context: str, expression: str, actual: int, expected: int) -> None:
    if actual != expected:
        _fail(
            context,
            f"conservation failure {expression}: got {actual}, expected {expected}",
        )


def validate_result(row: Mapping[str, str], context: str) -> None:
    values: dict[str, int] = {}
    for field in INTEGER_FIELDS:
        raw = row[field]
        if not re.fullmatch(r"[0-9]+", raw):
            _fail(context, f"non-integer field {field}: {raw!r}")
        values[field] = int(raw, 10)

    if values["schema"] != 2:
        _fail(context, f"schema must be 2, got {values['schema']}")
    if row["status"] != "PASS":
        _fail(context, f"status must be PASS, got {row['status']!r}")
    if values["prefetch"] not in (0, 1):
        _fail(context, f"prefetch must be 0 or 1, got {values['prefetch']}")

    _equal(
        context,
        "l1_bytes = sets * ways * line_bytes",
        values["l1_bytes"],
        values["sets"] * values["ways"] * values["line_bytes"],
    )
    _equal(
        context,
        "victim_bytes = victim_entries * line_bytes",
        values["victim_bytes"],
        values["victim_entries"] * values["line_bytes"],
    )
    _equal(
        context,
        "total_bytes = l1_bytes + victim_bytes",
        values["total_bytes"],
        values["l1_bytes"] + values["victim_bytes"],
    )
    _equal(
        context,
        "hits + misses = accesses",
        values["hits"] + values["misses"],
        values["accesses"],
    )
    if values["victim_hits"] > values["misses"]:
        _fail(context, "conservation failure victim_hits <= misses")
    _equal(
        context,
        "demand_mem_reads = misses - victim_hits",
        values["demand_mem_reads"],
        values["misses"] - values["victim_hits"],
    )
    _equal(
        context,
        "mem_reads = demand_mem_reads + prefetch_mem_reads",
        values["mem_reads"],
        values["demand_mem_reads"] + values["prefetch_mem_reads"],
    )
    _equal(
        context,
        "prefetch_mem_reads = fills",
        values["prefetch_mem_reads"],
        values["fills"],
    )
    _equal(
        context,
        "read_bytes = mem_reads * line_bytes",
        values["read_bytes"],
        values["mem_reads"] * values["line_bytes"],
    )
    _equal(
        context,
        "write_bytes = mem_writes * line_bytes",
        values["write_bytes"],
        values["mem_writes"] * values["line_bytes"],
    )
    _equal(
        context,
        "mem_writes = writebacks",
        values["mem_writes"],
        values["writebacks"],
    )
    _equal(
        context,
        "fills = useful + useless_evicted + unused_resident",
        values["fills"],
        values["useful"]
        + values["useless_evicted"]
        + values["unused_resident"],
    )
    _equal(
        context,
        "useful = timely_useful + late_useful",
        values["useful"],
        values["timely_useful"] + values["late_useful"],
    )
    if any(values[field] != 0 for field in ("watchdogs", "protocol", "duplicate_lines")):
        _fail(
            context,
            "conservation failure watchdogs/protocol/duplicate_lines = 0",
        )
    if values["prefetch"] == 0 and any(
        values[field] != 0 for field in PREFETCH_FIELDS
    ):
        _fail(context, "conservation failure prefetch-off counters = 0")


def load_results(paths: Sequence[Path]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    seen: set[tuple[str, str, str]] = set()
    for path in paths:
        try:
            lines = path.read_text(encoding="utf-8", errors="strict").splitlines()
        except (OSError, UnicodeError) as exc:
            raise WorkloadValidationError(f"{path}: {exc}") from exc
        file_rows = 0
        for line_number, line in enumerate(lines, 1):
            if not line.startswith(RESULT_PREFIX):
                continue
            context = f"{path}:{line_number}"
            row = parse_result(line, context)
            validate_result(row, context)
            key = (row["config_id"], row["trace_id"], row["name"])
            if key in seen:
                _fail(context, f"duplicate workload key {'/'.join(key)}")
            seen.add(key)
            rows.append(row)
            file_rows += 1
        if file_rows == 0:
            _fail(str(path), "no WORKLOAD_RESULT rows")
    if not rows:
        _fail("inputs", "no WORKLOAD_RESULT rows")
    return rows


def write_csv(rows: Sequence[Mapping[str, str]], output: TextIO) -> None:
    writer = csv.DictWriter(
        output,
        fieldnames=FIELDS,
        extrasaction="ignore",
        lineterminator="\n",
    )
    writer.writeheader()
    for row in rows:
        writer.writerow(row)


def main(argv: Sequence[str] | None = None) -> int:
    paths = [Path(value) for value in (sys.argv[1:] if argv is None else argv)]
    if not paths:
        print("workload validation failed: no input logs", file=sys.stderr)
        return 2
    try:
        rows = load_results(paths)
        write_csv(rows, sys.stdout)
    except (OSError, UnicodeError, WorkloadValidationError, ValueError) as exc:
        print(f"workload validation failed: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
