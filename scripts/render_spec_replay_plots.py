#!/usr/bin/env python3
"""Classify paired replay windows and render deterministic cycle-delta SVG.

The input rows are the strict analyzer's ``pairs.csv`` records.  A positive
``cycles_on_minus_off`` value is harmful, zero is neutral, and a negative
value is helpful.  The module intentionally uses only the Python standard
library so validated evidence can be rendered in a minimal environment.
"""

from __future__ import annotations

import argparse
import csv
import html
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Any, Mapping, Sequence


CLASSIFICATION_FIELDS = (
    "benchmark",
    "command",
    "window",
    "sets",
    "ways",
    "line_bytes",
    "victim_entries",
    "timing_profile",
    "prefetch_policy",
    "pf_opt_level",
    "producer_profile",
    "producer_gap",
    "trace_id",
    "cycles_on_minus_off",
    "classification",
)
CLASSIFICATION_KEY_FIELDS = (
    "benchmark",
    "command",
    "window",
    "sets",
    "ways",
    "line_bytes",
    "victim_entries",
    "timing_profile",
    "prefetch_policy",
    "pf_opt_level",
    "producer_profile",
    "producer_gap",
)
LEGACY_CLASSIFICATION_DEFAULTS = {
    "prefetch_policy": "0",
    "pf_opt_level": "0",
    "producer_profile": "sequential",
    "producer_gap": "0",
}
CLASSIFICATION_COLORS = {
    "harmful": "#c0392b",
    "neutral": "#7f8c8d",
    "helpful": "#2e8b57",
}


class PlotError(ValueError):
    """Raised when paired analyzer output cannot be classified or plotted."""


def _required(row: Mapping[str, Any], field: str, context: str) -> Any:
    if field not in row:
        raise PlotError(f"{context}: missing required field {field!r}")
    value = row[field]
    if value is None or str(value) == "":
        raise PlotError(f"{context}: field {field!r} must not be empty")
    return value


def _cycle_delta(value: Any, context: str) -> int:
    if isinstance(value, bool):
        raise PlotError(f"{context}: cycles_on_minus_off must be an integer")
    if isinstance(value, int):
        return value
    text = str(value)
    if not re.fullmatch(r"[+-]?\d+", text):
        raise PlotError(
            f"{context}: cycles_on_minus_off must be an integer, got {value!r}"
        )
    return int(text, 10)


def classify_cycle_delta(delta: int) -> str:
    """Return the normative classification for one signed cycle delta."""

    return "harmful" if delta > 0 else "helpful" if delta < 0 else "neutral"


def classification_rows(
    pairs: Sequence[Mapping[str, Any]],
) -> list[dict[str, Any]]:
    """Validate and deterministically classify strict analyzer pair rows."""

    if not pairs:
        raise PlotError("pairs: at least one validated pair is required")
    rows: list[dict[str, Any]] = []
    identities: set[tuple[str, ...]] = set()
    for index, pair in enumerate(pairs):
        context = f"pairs[{index}]"
        identity_values = {}
        for field in CLASSIFICATION_KEY_FIELDS:
            if field in LEGACY_CLASSIFICATION_DEFAULTS and pair.get(field) in (None, ""):
                identity_values[field] = LEGACY_CLASSIFICATION_DEFAULTS[field]
            else:
                identity_values[field] = str(_required(pair, field, context))
        identity = tuple(
            identity_values[field] for field in CLASSIFICATION_KEY_FIELDS
        )
        if identity in identities:
            raise PlotError(
                f"{context}: duplicate pair identity {identity!r}"
            )
        identities.add(identity)
        delta = _cycle_delta(_required(pair, "cycles_on_minus_off", context), context)
        classification = classify_cycle_delta(delta)
        declared = pair.get("cycle_class")
        if declared not in (None, "") and str(declared) != classification:
            raise PlotError(
                f"{context}: cycle_class={declared!r} disagrees with "
                f"cycles_on_minus_off={delta} ({classification})"
            )
        rows.append(
            {
                **identity_values,
                "trace_id": str(pair.get("trace_id", "")),
                "cycles_on_minus_off": delta,
                "classification": classification,
            }
        )
    return sorted(
        rows,
        key=lambda row: tuple(row[field] for field in CLASSIFICATION_KEY_FIELDS),
    )


def _atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, raw_temp = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    temp = Path(raw_temp)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        temp.replace(path)
    except BaseException:
        temp.unlink(missing_ok=True)
        raise


def write_classification_csv(rows: Sequence[Mapping[str, Any]], path: Path) -> None:
    """Atomically publish the canonical per-window classification table."""

    if not rows:
        raise PlotError("classification: cannot write an empty table")
    # csv.writer handles embedded commas, quotes, and newlines deterministically.
    from io import StringIO

    buffer = StringIO(newline="")
    writer = csv.DictWriter(buffer, fieldnames=CLASSIFICATION_FIELDS)
    writer.writeheader()
    for row in rows:
        writer.writerow({field: row.get(field, "") for field in CLASSIFICATION_FIELDS})
    _atomic_write_text(path, buffer.getvalue())


def cycle_delta_svg(rows: Sequence[Mapping[str, Any]]) -> str:
    """Return a deterministic, self-contained horizontal bar chart SVG."""

    if not rows:
        raise PlotError("plot: cannot render an empty classification table")
    width = 1280
    top = 104
    row_height = 48
    bottom = 66
    height = top + len(rows) * row_height + bottom
    label_right = 540
    plot_left = 575
    plot_right = 1240
    axis_x = (plot_left + plot_right) / 2
    half_width = (plot_right - plot_left) / 2 - 12
    deltas = [_cycle_delta(row.get("cycles_on_minus_off"), "plot row") for row in rows]
    max_abs = max(1, *(abs(delta) for delta in deltas))

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" '
        'aria-labelledby="title description">',
        '  <title id="title">Prefetch cycle delta by validated replay window</title>',
        '  <desc id="description">Cycles with prefetch on minus cycles with prefetch off; '
        'negative is helpful, zero neutral, and positive harmful.</desc>',
        '  <rect width="100%" height="100%" fill="#ffffff"/>',
        '  <text x="24" y="32" font-family="sans-serif" font-size="20" '
        'font-weight="bold" fill="#17202a">Prefetch cycle delta by window</text>',
        '  <text x="24" y="56" font-family="sans-serif" font-size="12" '
        'fill="#566573">cycles_on_minus_off (negative is helpful)</text>',
        f'  <rect x="850" y="21" width="12" height="12" fill="{CLASSIFICATION_COLORS["helpful"]}"/>',
        '  <text x="868" y="32" font-family="sans-serif" font-size="12">helpful</text>',
        f'  <rect x="940" y="21" width="12" height="12" fill="{CLASSIFICATION_COLORS["neutral"]}"/>',
        '  <text x="958" y="32" font-family="sans-serif" font-size="12">neutral</text>',
        f'  <rect x="1024" y="21" width="12" height="12" fill="{CLASSIFICATION_COLORS["harmful"]}"/>',
        '  <text x="1042" y="32" font-family="sans-serif" font-size="12">harmful</text>',
        f'  <line x1="{axis_x:.1f}" y1="78" x2="{axis_x:.1f}" '
        f'y2="{top + len(rows) * row_height}" stroke="#34495e" stroke-width="1"/>',
        f'  <text x="{plot_left}" y="91" font-family="sans-serif" font-size="11" '
        f'text-anchor="start" fill="#566573">-{max_abs}</text>',
        f'  <text x="{axis_x:.1f}" y="91" font-family="sans-serif" font-size="11" '
        'text-anchor="middle" fill="#566573">0</text>',
        f'  <text x="{plot_right}" y="91" font-family="sans-serif" font-size="11" '
        f'text-anchor="end" fill="#566573">+{max_abs}</text>',
    ]
    for index, (row, delta) in enumerate(zip(rows, deltas)):
        classification = str(_required(row, "classification", f"plot rows[{index}]"))
        if classification != classify_cycle_delta(delta):
            raise PlotError(
                f"plot rows[{index}]: classification {classification!r} "
                f"does not match delta {delta}"
            )
        color = CLASSIFICATION_COLORS[classification]
        y = top + index * row_height
        bar_y = y + 16
        bar_width = abs(delta) / max_abs * half_width
        bar_x = axis_x - bar_width if delta < 0 else axis_x
        if delta == 0:
            bar_x = axis_x - 2
            bar_width = 4
        identity_label = (
            f"{row['benchmark']} / cmd {row['command']} / window {row['window']}"
        )
        geometry_label = (
            f"sets {row['sets']} / ways {row['ways']} / line {row['line_bytes']} / "
            f"VC {row['victim_entries']} / PF {row['prefetch_policy']}:{row['pf_opt_level']} / "
            f"producer {row['producer_profile']}:{row['producer_gap']} / "
            f"timing {row['timing_profile']}"
        )
        safe_identity = html.escape(identity_label, quote=True)
        safe_geometry = html.escape(geometry_label, quote=True)
        safe_class = html.escape(classification, quote=True)
        safe_delta = html.escape(str(delta), quote=True)
        lines.extend(
            [
                f'  <g data-classification="{safe_class}" data-delta="{safe_delta}">',
                f'    <title>{safe_identity} / {safe_geometry}: {safe_delta} cycles ({safe_class})</title>',
                f'    <text class="pair-identity" x="{label_right}" y="{y + 17}" '
                f'font-family="sans-serif" font-size="12" text-anchor="end" '
                f'fill="#17202a">{safe_identity}</text>',
                f'    <text class="pair-geometry" x="{label_right}" y="{y + 34}" '
                f'font-family="sans-serif" font-size="11" text-anchor="end" '
                f'fill="#566573">{safe_geometry}</text>',
                f'    <rect x="{bar_x:.2f}" y="{bar_y}" width="{bar_width:.2f}" '
                f'height="16" rx="2" fill="{color}"/>',
                f'    <text x="{bar_x + bar_width + (7 if delta >= 0 else -7):.2f}" '
                f'y="{y + 29}" font-family="sans-serif" font-size="11" '
                f'text-anchor="{"start" if delta >= 0 else "end"}" fill="#17202a">{safe_delta}</text>',
                "  </g>",
            ]
        )
    lines.extend(
        [
            f'  <text x="{width / 2:.1f}" y="{height - 22}" '
            'font-family="sans-serif" font-size="11" text-anchor="middle" '
            'fill="#566573">Validated paired windows; bar scale uses maximum absolute delta.</text>',
            "</svg>",
            "",
        ]
    )
    return "\n".join(lines)


def write_cycle_delta_svg(rows: Sequence[Mapping[str, Any]], path: Path) -> None:
    """Atomically publish a deterministic cycle-delta SVG."""

    _atomic_write_text(path, cycle_delta_svg(rows))


def _remove_plot_targets(targets: Sequence[Path]) -> list[str]:
    findings: list[str] = []
    for target in targets:
        try:
            target.unlink(missing_ok=True)
        except OSError as exc:
            findings.append(f"could not remove plot output {target}: {exc}")
    return findings


def write_plot_outputs(
    pairs: Sequence[Mapping[str, Any]],
    classification_path: Path,
    cycles_svg_path: Path,
) -> list[dict[str, Any]]:
    """Atomically publish both outputs, removing the set on any failure."""

    targets = (classification_path, cycles_svg_path)
    preflight: list[str] = []
    try:
        if classification_path.resolve() == cycles_svg_path.resolve():
            preflight.append(
                "plot output paths alias after resolve: "
                f"{classification_path.resolve()}"
            )
    except (OSError, RuntimeError) as exc:
        preflight.append(f"could not resolve plot output paths: {exc}")
    preflight.extend(_remove_plot_targets(targets))
    if preflight:
        raise PlotError("; ".join(preflight))
    try:
        rows = classification_rows(pairs)
        write_classification_csv(rows, classification_path)
        write_cycle_delta_svg(rows, cycles_svg_path)
    except BaseException:
        _remove_plot_targets(targets)
        raise
    return rows


def read_pairs_csv(path: Path) -> list[dict[str, str]]:
    try:
        with path.open(newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
    except (OSError, UnicodeError, csv.Error) as exc:
        raise PlotError(f"pairs CSV {path}: {exc}") from exc
    if not rows:
        raise PlotError(f"pairs CSV {path}: contains no data rows")
    return rows


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pairs-csv", type=Path, required=True)
    parser.add_argument("--classification-csv", type=Path, required=True)
    parser.add_argument("--cycles-svg", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        write_plot_outputs(
            read_pairs_csv(args.pairs_csv),
            args.classification_csv,
            args.cycles_svg,
        )
    except (OSError, UnicodeError, PlotError, ValueError) as exc:
        _remove_plot_targets((args.classification_csv, args.cycles_svg))
        print(f"plot generation failed: {exc}", file=sys.stderr)
        return 2
    print(f"wrote {args.classification_csv} and {args.cycles_svg}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
