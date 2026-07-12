#!/usr/bin/env python3
"""Analyze replay-trace locality, reuse, stride, and set pressure.

Input files may be legacy 4/5-column replay traces, schema-v2 key/value rows,
or canonical TSV containing ``op``, ``size``, and ``paddr``/``addr`` columns.
When ``# PHASE warmup`` and ``# PHASE measure`` markers are present, the
measurement phase is analyzed by default.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Sequence

try:
    from summarize_spec_replay import analyze_trace
except ImportError:  # Supports importing as scripts.analyze_trace_windows.
    from scripts.summarize_spec_replay import analyze_trace


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("traces", type=Path, nargs="+")
    parser.add_argument("--line-bytes", type=int, required=True)
    parser.add_argument("--sets", type=int, required=True)
    parser.add_argument("--ways", type=int, required=True)
    parser.add_argument("--phase", choices=("measure", "warmup", "all"), default="measure")
    parser.add_argument("--json", type=Path, required=True)
    args = parser.parse_args(argv)

    rows = []
    for trace in args.traces:
        row = {
            "trace": str(trace.resolve()),
            "line_bytes": args.line_bytes,
            "sets": args.sets,
            "ways": args.ways,
        }
        row.update(
            analyze_trace(
                trace.resolve(),
                line_bytes=args.line_bytes,
                sets=args.sets,
                ways=args.ways,
                phase=args.phase,
            )
        )
        rows.append(row)

    output = {"schema": 2, "status": "PASS", "windows": rows}
    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(output, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"analyzed {len(rows)} trace window(s); wrote {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
