#!/usr/bin/env python3
"""Publish a compact, address-free prefetch evidence package.

Private traces, sidecars, logs, absolute paths, and remote execution details stay
under ``build/``.  This publisher selects only aggregate/lifecycle measurements,
binds them to the private manifests by SHA-256, and emits a redacted gate result.
"""

from __future__ import annotations

import argparse
import copy
import csv
import hashlib
import json
import re
from datetime import date
from pathlib import Path
from typing import Any, Iterable


MAIN_VARIANTS = ("legacy", "p1", "p2", "p3", "p3-lite")
SENSITIVITY_PROFILES = (
    "sequential",
    "gap1",
    "gap2",
    "gap4",
    "gap8",
    "latency0-always",
    "latency8-periodic",
    "latency8-random",
)
SENSITIVITY_VARIANTS = ("legacy", "p3-lite")
PRIVATE_PATTERN = re.compile(
    r"(?:/Users/|/home/|[A-Za-z]:[/\\]Users[/\\]|/cygdrive/|192\.168\.)"
)


class PublishError(ValueError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def gate_provenance_hashes(source: Path, public: Path) -> dict[str, str]:
    """Distinguish the private evaluator input from its public redacted copy."""
    return {
        "source_gate_result_sha256": sha256(source),
        "gate_result_sha256": sha256(public),
    }


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise PublishError(f"cannot read JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise PublishError(f"expected JSON object: {path}")
    return value


def read_csv(path: Path) -> list[dict[str, str]]:
    try:
        with path.open(newline="", encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
    except OSError as exc:
        raise PublishError(f"cannot read CSV {path}: {exc}") from exc
    if not rows:
        raise PublishError(f"empty CSV: {path}")
    return rows


def one_row(path: Path) -> dict[str, str]:
    rows = read_csv(path)
    if len(rows) != 1:
        raise PublishError(f"expected one aggregate row in {path}, got {len(rows)}")
    return rows[0]


def require_pass(root: Path) -> None:
    validation = read_json(root / "analysis" / "validation.json")
    manifest = read_json(root / "campaign_manifest.json")
    if validation.get("status") != "PASS" or manifest.get("status") != "PASS":
        raise PublishError(f"campaign is not validated PASS: {root}")


def integer(row: dict[str, str], field: str) -> int:
    try:
        return int(row[field], 10)
    except (KeyError, ValueError) as exc:
        raise PublishError(f"invalid integer field {field}={row.get(field)!r}") from exc


def decimal(row: dict[str, str], field: str) -> str:
    try:
        float(row[field])
    except (KeyError, ValueError) as exc:
        raise PublishError(f"invalid numeric field {field}={row.get(field)!r}") from exc
    return row[field]


def aggregate_row(label: str, row: dict[str, str]) -> dict[str, Any]:
    off_bytes = integer(row, "off_read_bytes") + integer(row, "off_write_bytes")
    on_bytes = integer(row, "on_read_bytes") + integer(row, "on_write_bytes")
    return {
        "variant": label,
        "prefetch_policy": integer(row, "prefetch_policy"),
        "pf_opt_level": integer(row, "pf_opt_level"),
        "producer_profile": row["producer_profile"],
        "producer_gap": integer(row, "producer_gap"),
        "timing_profile": row["timing_profile"],
        "pairs": integer(row, "pair_count"),
        "accesses": integer(row, "on_accesses"),
        "off_cycles": integer(row, "off_replay_service_cycles"),
        "on_cycles": integer(row, "on_replay_service_cycles"),
        "cycle_delta": integer(row, "cycles_on_minus_off"),
        "cycle_delta_fraction": decimal(row, "cycle_delta_fraction"),
        "off_total_bytes": off_bytes,
        "on_total_bytes": on_bytes,
        "byte_delta": on_bytes - off_bytes,
        "bandwidth_overhead": decimal(row, "bandwidth_overhead"),
        "harmful": integer(row, "harmful_pairs"),
        "neutral": integer(row, "neutral_pairs"),
        "helpful": integer(row, "helpful_pairs"),
        "pf_candidates": integer(row, "on_pf_candidates"),
        "pf_admitted": integer(row, "on_pf_admitted"),
        "pf_issued": integer(row, "on_pf_issued"),
        "pf_returned": integer(row, "on_pf_returned"),
        "pf_installed": integer(row, "on_pf_installed"),
        "pf_merged": integer(row, "on_pf_merged"),
        "pf_discarded": integer(row, "on_pf_discarded"),
        "pf_cancelled": integer(row, "on_pf_cancelled"),
        "pf_unused_evicted": integer(row, "on_pf_unused_evicted"),
        "pf_unused_resident": integer(row, "on_pf_unused_resident"),
        "pf_caused_writebacks": integer(row, "on_pf_caused_writebacks"),
        "pf_demand_block_cycles": integer(row, "on_pf_demand_block_cycles"),
    }


def pair_row(row: dict[str, str]) -> dict[str, Any]:
    off_bytes = integer(row, "off_read_bytes") + integer(row, "off_write_bytes")
    on_bytes = integer(row, "on_read_bytes") + integer(row, "on_write_bytes")
    return {
        "benchmark": row["benchmark"],
        "command": integer(row, "command"),
        "window": integer(row, "window"),
        "trace_id": row["trace_id"],
        "producer_profile": row["producer_profile"],
        "producer_gap": integer(row, "producer_gap"),
        "timing_profile": row["timing_profile"],
        "off_cycles": integer(row, "off_replay_service_cycles"),
        "on_cycles": integer(row, "on_replay_service_cycles"),
        "cycle_delta": integer(row, "cycles_on_minus_off"),
        "cycle_delta_fraction": decimal(row, "cycle_delta_fraction"),
        "classification": row["cycle_class"],
        "off_total_bytes": off_bytes,
        "on_total_bytes": on_bytes,
        "byte_delta": on_bytes - off_bytes,
        "pf_candidates": integer(row, "on_pf_candidates"),
        "pf_admitted": integer(row, "on_pf_admitted"),
        "pf_issued": integer(row, "on_pf_issued"),
        "pf_returned": integer(row, "on_pf_returned"),
        "pf_installed": integer(row, "on_pf_installed"),
        "pf_merged": integer(row, "on_pf_merged"),
        "pf_discarded": integer(row, "on_pf_discarded"),
        "pf_unused_evicted": integer(row, "on_pf_unused_evicted"),
        "pf_unused_resident": integer(row, "on_pf_unused_resident"),
        "pf_caused_writebacks": integer(row, "on_pf_caused_writebacks"),
        "pf_demand_block_cycles": integer(row, "on_pf_demand_block_cycles"),
    }


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    if not rows:
        raise PublishError(f"refusing to write empty CSV: {path}")
    fields = list(rows[0])
    if any(list(row) != fields for row in rows):
        raise PublishError(f"inconsistent CSV fields for {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def _campaign_source_hashes(root: Path) -> dict[str, str]:
    files = (
        root / "campaign_manifest.json",
        root / "analysis" / "aggregate.csv",
        root / "analysis" / "pairs.csv",
        root / "analysis" / "classification.csv",
        root / "analysis" / "validation.json",
    )
    return {path.name: sha256(path) for path in files}


def _sweep_values(root: Path) -> tuple[int, int, int]:
    manifest = read_json(root / "campaign_manifest.json")
    runs = manifest.get("runs")
    if not isinstance(runs, list) or not runs:
        raise PublishError(f"campaign has no runs: {root}")
    values = {
        (
            int(run["pf_idle_guard"]),
            int(run["pf_on_refill"]),
            int(run["pf_epoch_demands"]),
        )
        for run in runs
    }
    if len(values) != 1:
        raise PublishError(f"inconsistent sweep knobs: {root}")
    return next(iter(values))


def _metric(metrics: dict[str, Any], group: str, field: str) -> Any:
    value = metrics.get(group, {}).get(field)
    return "" if value is None else value


def vivado_rows(manifest: dict[str, Any]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for stage in ("synthesis", "implementation"):
        entries = manifest.get(stage)
        if not isinstance(entries, list):
            raise PublishError(f"Vivado manifest has no {stage} matrix")
        for entry in entries:
            metrics = entry.get("metrics", {})
            geometry = entry.get("geometry", {})
            timing = metrics.get("timing", {})
            rows.append(
                {
                    "stage": stage,
                    "config_id": entry["config_id"],
                    "sets": geometry.get("sets", ""),
                    "ways": geometry.get("ways", ""),
                    "line_bytes": geometry.get("line_bytes", ""),
                    "victim_entries": geometry.get("victim_entries", ""),
                    "enable_prefetch": geometry.get("prefetch", ""),
                    "pf_opt_level": geometry.get("pf_opt_level", ""),
                    "pf_use_stream": geometry.get("pf_use_stream", ""),
                    "pf_use_adaptive": geometry.get("pf_use_adaptive", ""),
                    "pf_use_shadow": geometry.get("pf_use_shadow", ""),
                    "pf_use_mshr": geometry.get("pf_use_mshr", ""),
                    "luts": _metric(metrics, "utilization", "slice_luts"),
                    "lut_as_memory": _metric(metrics, "utilization", "lut_as_memory"),
                    "registers": _metric(metrics, "utilization", "slice_registers"),
                    "bram_tiles": _metric(metrics, "utilization", "block_ram_tiles"),
                    "wns_ns": timing.get("wns_ns", ""),
                    "tns_ns": timing.get("tns_ns", ""),
                    "whs_ns": timing.get("whs_ns", ""),
                    "ths_ns": timing.get("ths_ns", ""),
                    "fmax_mhz": timing.get("slack_derived_fmax_mhz", ""),
                    "vectorless_total_w": _metric(metrics, "power_vectorless", "total_on_chip_w"),
                    "vectorless_dynamic_w": _metric(metrics, "power_vectorless", "dynamic_w"),
                    "vectorless_static_w": _metric(metrics, "power_vectorless", "device_static_w"),
                    "vectorless_confidence": _metric(metrics, "power_vectorless", "confidence"),
                    "activity_total_w": _metric(metrics, "power_activity", "total_on_chip_w"),
                    "activity_dynamic_w": _metric(metrics, "power_activity", "dynamic_w"),
                    "activity_static_w": _metric(metrics, "power_activity", "device_static_w"),
                    "activity_confidence": _metric(metrics, "power_activity", "confidence"),
                    "activity_matched_nets": _metric(metrics, "power_activity", "matched_design_nets"),
                    "activity_total_nets": _metric(metrics, "power_activity", "total_design_nets"),
                    "activity_source": entry.get("activity_source", ""),
                }
            )
    return rows


def sanitize_gate_result(gate: dict[str, Any]) -> dict[str, Any]:
    public = copy.deepcopy(gate)
    replays = public.get("replays", {})
    if isinstance(replays, dict):
        for name, replay in replays.items():
            if isinstance(replay, dict) and "root" in replay:
                replay["root"] = f"private-build/replay/{name}"
    vivado = public.get("vivado")
    if isinstance(vivado, dict):
        vivado["manifest"] = "private-build/vivado/evidence_manifest.json"
        tool = vivado.get("tool")
        if isinstance(tool, dict) and "launcher" in tool:
            tool["launcher"] = "redacted"
    return public


def write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def ensure_public(files: Iterable[Path]) -> None:
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        match = PRIVATE_PATTERN.search(text)
        if match:
            raise PublishError(
                f"private absolute path/host marker {match.group(0)!r} in {path}"
            )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--campaign-root", type=Path, required=True)
    parser.add_argument("--vivado-manifest", type=Path, required=True)
    parser.add_argument("--gate-result", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--date", default=date.today().isoformat())
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    campaign_root = args.campaign_root.resolve()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)

    provenance_sources: dict[str, Any] = {}
    main_rows: list[dict[str, Any]] = []
    for variant in MAIN_VARIANTS:
        root = campaign_root / "main" / variant
        require_pass(root)
        main_rows.append(
            aggregate_row(variant, one_row(root / "analysis" / "aggregate.csv"))
        )
        provenance_sources[f"main/{variant}"] = _campaign_source_hashes(root)
    write_csv(output / "aggregate.csv", main_rows)

    p3_lite = campaign_root / "main" / "p3-lite"
    pairs = [pair_row(row) for row in read_csv(p3_lite / "analysis" / "pairs.csv")]
    write_csv(output / "pairs.csv", pairs)
    write_csv(
        output / "classification.csv",
        [
            {
                "benchmark": row["benchmark"],
                "command": integer(row, "command"),
                "window": integer(row, "window"),
                "trace_id": row["trace_id"],
                "cycles_on_minus_off": integer(row, "cycles_on_minus_off"),
                "classification": row["classification"],
            }
            for row in read_csv(p3_lite / "analysis" / "classification.csv")
        ],
    )

    sweep_rows: list[dict[str, Any]] = []
    default_row = aggregate_row(
        "default", one_row(p3_lite / "analysis" / "aggregate.csv")
    )
    sweep_rows.append(
        {
            "point": "default",
            "idle_guard": 2,
            "on_refill": 8,
            "epoch_demands": 256,
            **{key: default_row[key] for key in default_row if key not in {
                "variant", "prefetch_policy", "pf_opt_level", "producer_profile",
                "producer_gap", "timing_profile",
            }},
        }
    )
    for root in sorted((campaign_root / "sweep").iterdir()):
        if not root.is_dir():
            continue
        require_pass(root)
        idle_guard, on_refill, epoch_demands = _sweep_values(root)
        row = aggregate_row(root.name, one_row(root / "analysis" / "aggregate.csv"))
        sweep_rows.append(
            {
                "point": root.name,
                "idle_guard": idle_guard,
                "on_refill": on_refill,
                "epoch_demands": epoch_demands,
                **{key: row[key] for key in row if key not in {
                    "variant", "prefetch_policy", "pf_opt_level", "producer_profile",
                    "producer_gap", "timing_profile",
                }},
            }
        )
        provenance_sources[f"sweep/{root.name}"] = _campaign_source_hashes(root)
    if len(sweep_rows) != 6:
        raise PublishError(f"expected six sweep points including default, got {len(sweep_rows)}")
    write_csv(output / "sweep.csv", sweep_rows)

    sensitivity_rows: list[dict[str, Any]] = []
    for profile in SENSITIVITY_PROFILES:
        for variant in SENSITIVITY_VARIANTS:
            root = campaign_root / "sensitivity" / profile / variant
            require_pass(root)
            row = aggregate_row(variant, one_row(root / "analysis" / "aggregate.csv"))
            sensitivity_rows.append({"profile": profile, **row})
            provenance_sources[f"sensitivity/{profile}/{variant}"] = (
                _campaign_source_hashes(root)
            )
    write_csv(output / "sensitivity.csv", sensitivity_rows)

    vivado_manifest = read_json(args.vivado_manifest.resolve())
    if vivado_manifest.get("schema") != "l1d-vivado-evidence-v3" or (
        vivado_manifest.get("status") != "PASS"
    ):
        raise PublishError("Vivado manifest is not validated schema-v3 PASS")
    write_csv(output / "vivado-ppa.csv", vivado_rows(vivado_manifest))

    gate = read_json(args.gate_result.resolve())
    if gate.get("status") != "PASS":
        raise PublishError("gate evaluator did not complete successfully")
    write_json(output / "gate-result.json", sanitize_gate_result(gate))

    provenance = {
        "schema": "l1d-prefetch-public-evidence-v1",
        "date": args.date,
        "status": "PASS",
        "decision": gate.get("decision"),
        "private_artifacts_excluded": True,
        "repository": vivado_manifest.get("repository"),
        "tool": {
            key: value
            for key, value in vivado_manifest.get("tool", {}).items()
            if key != "launcher"
        },
        "vivado_manifest_sha256": sha256(args.vivado_manifest.resolve()),
        **gate_provenance_hashes(
            args.gate_result.resolve(), output / "gate-result.json"
        ),
        "vivado_input_hashes": vivado_manifest.get("inputs"),
        "campaign_sources": provenance_sources,
    }
    public_files = sorted(
        path for path in output.rglob("*")
        if path.is_file() and path.name != "provenance.json"
    )
    ensure_public(public_files)
    provenance["public_artifacts"] = {
        str(path.relative_to(output)): sha256(path) for path in public_files
    }
    write_json(output / "provenance.json", provenance)
    ensure_public([output / "provenance.json"])
    print(f"published address-free evidence: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
