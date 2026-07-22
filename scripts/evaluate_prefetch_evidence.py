#!/usr/bin/env python3
"""Evaluate the feedback's replay, PPA, timing, and power stop gates.

The script reports a FAIL decision without treating it as an execution error;
use ``--require-pass`` when a CI job should reject a failed deployment gate.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import importlib.util
import json
import math
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class EvidenceError(ValueError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_csv(path: Path) -> list[dict[str, str]]:
    if not path.is_file():
        raise EvidenceError(f"missing evidence CSV: {path}")
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        raise EvidenceError(f"empty evidence CSV: {path}")
    return rows


def integer(row: dict[str, str], field: str, context: str) -> int:
    raw = row.get(field)
    if raw is None or not raw.isdigit():
        raise EvidenceError(f"{context}: {field}={raw!r}, expected integer")
    return int(raw, 10)


def number(row: dict[str, str], field: str, context: str) -> float:
    raw = row.get(field)
    try:
        value = float(raw) if raw not in {None, "", "N/A"} else math.nan
    except ValueError as exc:
        raise EvidenceError(f"{context}: {field}={raw!r}, expected number") from exc
    if not math.isfinite(value):
        raise EvidenceError(f"{context}: {field}={raw!r}, expected finite number")
    return value


def load_replay(name: str, root: Path) -> dict[str, Any]:
    analysis = root / "analysis"
    aggregate_rows = read_csv(analysis / "aggregate.csv")
    pair_rows = read_csv(analysis / "pairs.csv")
    if len(aggregate_rows) != 1:
        raise EvidenceError(
            f"{name}: expected one aggregate row, found {len(aggregate_rows)}"
        )
    aggregate = aggregate_rows[0]
    context = f"{name} aggregate"
    pair_count = integer(aggregate, "pair_count", context)
    if pair_count != len(pair_rows):
        raise EvidenceError(
            f"{name}: pair_count={pair_count}, pairs.csv rows={len(pair_rows)}"
        )
    validation_path = analysis / "validation.json"
    validation = json.loads(validation_path.read_text(encoding="utf-8"))
    if validation.get("status") != "PASS":
        raise EvidenceError(f"{name}: replay validation is not PASS")

    off_cycles = integer(aggregate, "off_replay_service_cycles", context)
    on_cycles = integer(aggregate, "on_replay_service_cycles", context)
    off_bytes = integer(aggregate, "off_read_bytes", context) + integer(
        aggregate, "off_write_bytes", context
    )
    on_bytes = integer(aggregate, "on_read_bytes", context) + integer(
        aggregate, "on_write_bytes", context
    )
    if off_cycles <= 0 or off_bytes <= 0:
        raise EvidenceError(f"{name}: baseline cycles and bytes must be positive")
    cycle_improvement = (off_cycles - on_cycles) / off_cycles
    bandwidth_overhead = (on_bytes - off_bytes) / off_bytes
    slowdowns = [number(row, "cycle_delta_fraction", name) for row in pair_rows]
    non_slow = sum(value <= 0.0 for value in slowdowns)
    max_slowdown = max(slowdowns)
    caused_writebacks = integer(aggregate, "on_pf_caused_writebacks", context)
    checks = {
        "aggregate_cycle_improvement_ge_1pct": cycle_improvement >= 0.01,
        "bandwidth_overhead_le_10pct": bandwidth_overhead <= 0.10,
        "non_slow_windows_ge_20": non_slow >= 20,
        "max_window_slowdown_le_5pct": max_slowdown <= 0.05,
        "pf_caused_writebacks_zero": caused_writebacks == 0,
    }
    fields = (
        "on_pf_candidates",
        "on_pf_admitted",
        "on_pf_issued",
        "on_pf_returned",
        "on_pf_installed",
        "on_pf_merged",
        "on_pf_discarded",
        "on_pf_cancelled",
        "on_pf_unused_evicted",
        "on_pf_unused_resident",
        "on_pf_caused_writebacks",
        "on_pf_demand_block_cycles",
        "on_read_bytes",
        "on_write_bytes",
        "off_read_bytes",
        "off_write_bytes",
    )
    return {
        "name": name,
        "root": str(root.resolve()),
        "profile": {
            key: aggregate.get(key)
            for key in (
                "timing_profile",
                "producer_profile",
                "producer_gap",
                "prefetch_policy",
                "pf_opt_level",
            )
        },
        "pair_count": pair_count,
        "off_cycles": off_cycles,
        "on_cycles": on_cycles,
        "cycle_improvement_fraction": cycle_improvement,
        "off_total_bytes": off_bytes,
        "on_total_bytes": on_bytes,
        "bandwidth_overhead_fraction": bandwidth_overhead,
        "non_slow_windows": non_slow,
        "max_window_slowdown_fraction": max_slowdown,
        "checks": checks,
        "replay_gate_pass": all(checks.values()),
        "counters": {field: integer(aggregate, field, context) for field in fields},
        "artifacts": {
            "aggregate.csv": sha256(analysis / "aggregate.csv"),
            "pairs.csv": sha256(analysis / "pairs.csv"),
            "validation.json": sha256(validation_path),
            "campaign_manifest.json": sha256(root / "campaign_manifest.json"),
        },
    }


def _index(entries: list[dict[str, Any]], kind: str) -> dict[str, dict[str, Any]]:
    indexed: dict[str, dict[str, Any]] = {}
    for entry in entries:
        name = entry.get("config_id")
        if not isinstance(name, str) or name in indexed:
            raise EvidenceError(f"Vivado {kind} entries have invalid/duplicate config_id")
        indexed[name] = entry
    return indexed


def _fraction(on: float, off: float, context: str) -> float:
    if off <= 0:
        raise EvidenceError(f"{context}: baseline must be positive")
    return (on - off) / off


def _load_vivado_parser() -> Any:
    parser_path = Path(__file__).with_name("run_remote_vivado.py")
    spec = importlib.util.spec_from_file_location(
        "evaluate_prefetch_evidence_run_remote_vivado", parser_path
    )
    if spec is None or spec.loader is None:
        raise EvidenceError(f"cannot load Vivado report parser: {parser_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _verified_path(root: Path, rel_path: str, expected_sha256: str) -> Path:
    candidate = (root / rel_path).resolve()
    try:
        candidate.relative_to(root.resolve())
    except ValueError as exc:
        raise EvidenceError(f"evidence artifact escapes repository root: {rel_path}") from exc
    if not candidate.is_file():
        raise EvidenceError(f"missing hashed evidence artifact: {candidate}")
    actual = sha256(candidate)
    if actual != expected_sha256:
        raise EvidenceError(
            f"evidence hash mismatch for {rel_path}: {actual} != {expected_sha256}"
        )
    return candidate


def verify_vivado_manifest_artifacts(
    path: Path, manifest: dict[str, Any]
) -> tuple[Path, Any]:
    if len(path.parents) < 3:
        raise EvidenceError(f"cannot infer repository root from {path}")
    root = path.parents[2]
    inputs = manifest.get("inputs")
    if not isinstance(inputs, dict) or not inputs:
        raise EvidenceError("Vivado manifest has no bound input hashes")
    for rel_path, digest in inputs.items():
        if not isinstance(rel_path, str) or not isinstance(digest, str):
            raise EvidenceError("Vivado input hash table is malformed")
        _verified_path(root, rel_path, digest)

    for kind in ("synthesis", "implementation"):
        entries = manifest.get(kind)
        if not isinstance(entries, list):
            raise EvidenceError(f"Vivado manifest {kind} matrix is malformed")
        for entry in entries:
            reports = entry.get("reports")
            if not isinstance(reports, dict) or not reports:
                raise EvidenceError(
                    f"Vivado {kind} {entry.get('config_id')} has no report hashes"
                )
            for artifact in reports.values():
                if not isinstance(artifact, dict):
                    raise EvidenceError("Vivado report artifact is malformed")
                _verified_path(root, artifact["path"], artifact["sha256"])
    parser = _load_vivado_parser()
    return root, parser


def verify_embedded_metrics(
    root: Path,
    parser: Any,
    entry: dict[str, Any],
    specs: tuple[tuple[str, str, Any], ...],
) -> None:
    reports = entry["reports"]
    embedded = entry.get("metrics")
    if not isinstance(embedded, dict):
        raise EvidenceError(f"{entry.get('config_id')}: missing embedded metrics")
    for metric_name, filename, parse in specs:
        try:
            artifact = reports[filename]
            expected = embedded[metric_name]
        except KeyError as exc:
            raise EvidenceError(
                f"{entry.get('config_id')}: missing {metric_name} metric/report"
            ) from exc
        actual = parse((root / artifact["path"]).resolve())
        if actual != expected:
            raise EvidenceError(
                f"{entry.get('config_id')}: embedded {metric_name} metrics "
                "do not match the hashed report"
            )


def load_vivado(path: Path, replay: dict[str, Any]) -> dict[str, Any]:
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest.get("schema") != "l1d-vivado-evidence-v3":
        raise EvidenceError("Vivado manifest schema is not l1d-vivado-evidence-v3")
    if manifest.get("status") != "PASS":
        raise EvidenceError("Vivado evidence manifest is not PASS")
    root, parser = verify_vivado_manifest_artifacts(path, manifest)
    synthesis = _index(manifest.get("synthesis", []), "synthesis")
    implementation = _index(manifest.get("implementation", []), "implementation")
    for name in ("optimized_pf0_deploy", "p3_lite_mshr_fixed"):
        if name not in synthesis or name not in implementation:
            raise EvidenceError(f"Vivado manifest is missing required config {name}")
        verify_embedded_metrics(
            root,
            parser,
            synthesis[name],
            (
                ("utilization", "utilization.rpt", parser.parse_utilization_report),
                ("timing", "timing_summary.rpt", parser.parse_timing_summary_report),
                ("power_vectorless", "power_vectorless.rpt", parser.parse_power_report),
            ),
        )
        verify_embedded_metrics(
            root,
            parser,
            implementation[name],
            (
                (
                    "utilization",
                    "post_route_utilization.rpt",
                    parser.parse_utilization_report,
                ),
                (
                    "timing",
                    "post_route_timing_summary.rpt",
                    parser.parse_timing_summary_report,
                ),
                (
                    "power_activity",
                    "post_route_power_activity.rpt",
                    parser.parse_power_report,
                ),
            ),
        )
    try:
        synth_off = synthesis["optimized_pf0_deploy"]["metrics"]
        synth_on = synthesis["p3_lite_mshr_fixed"]["metrics"]
        impl_off = implementation["optimized_pf0_deploy"]["metrics"]
        impl_on = implementation["p3_lite_mshr_fixed"]["metrics"]
        off_luts = float(synth_off["utilization"]["slice_luts"])
        on_luts = float(synth_on["utilization"]["slice_luts"])
        off_ffs = float(synth_off["utilization"]["slice_registers"])
        on_ffs = float(synth_on["utilization"]["slice_registers"])
        ooc_on_wns = float(synth_on["timing"]["wns_ns"])
        post_timing = impl_on["timing"]
        off_fmax = float(impl_off["timing"]["slack_derived_fmax_mhz"])
        on_fmax = float(post_timing["slack_derived_fmax_mhz"])
        off_dynamic = float(impl_off["power_activity"]["dynamic_w"])
        on_dynamic = float(impl_on["power_activity"]["dynamic_w"])
    except (KeyError, TypeError, ValueError) as exc:
        raise EvidenceError(f"Vivado manifest is missing required numerical metrics: {exc}") from exc

    lut_overhead = _fraction(on_luts, off_luts, "LUT overhead")
    ff_overhead = _fraction(on_ffs, off_ffs, "FF overhead")
    power_overhead = _fraction(on_dynamic, off_dynamic, "dynamic power overhead")
    off_time = replay["off_cycles"] / off_fmax
    on_time = replay["on_cycles"] / on_fmax
    time_improvement = (off_time - on_time) / off_time
    check_names = (
        "check_no_clock",
        "check_constant_clock",
        "check_unconstrained_internal_endpoints",
        "check_no_input_delay",
        "check_no_output_delay",
        "check_multiple_clock",
        "check_loops",
        "check_partial_input_delay",
        "check_partial_output_delay",
        "check_latch_loops",
    )
    checks = {
        "ooc_p3_lite_wns_nonnegative": ooc_on_wns >= 0.0,
        "lut_overhead_le_15pct": lut_overhead <= 0.15,
        "ff_overhead_le_15pct": ff_overhead <= 0.15,
        "post_route_wns_nonnegative": float(post_timing["wns_ns"]) >= 0.0,
        "post_route_hold_clean": (
            float(post_timing["whs_ns"]) >= 0.0
            and float(post_timing["ths_ns"]) == 0.0
            and int(post_timing["hold_failing_endpoints"]) == 0
        ),
        "post_route_no_unconstrained_paths": all(
            int(post_timing[name]) == 0 for name in check_names
        ),
        "activity_dynamic_power_overhead_le_10pct": power_overhead <= 0.10,
        "achieved_frequency_time_improves": time_improvement > 0.0,
    }
    return {
        "manifest": str(path.resolve()),
        "manifest_sha256": sha256(path),
        "repository": manifest.get("repository"),
        "tool": manifest.get("tool"),
        "lut_overhead_fraction": lut_overhead,
        "ff_overhead_fraction": ff_overhead,
        "ooc_p3_lite_wns_ns": ooc_on_wns,
        "post_route_p3_lite_wns_ns": float(post_timing["wns_ns"]),
        "post_route_p3_lite_whs_ns": float(post_timing["whs_ns"]),
        "pf0_slack_derived_fmax_mhz": off_fmax,
        "p3_lite_slack_derived_fmax_mhz": on_fmax,
        "execution_time_proxy_improvement_fraction": time_improvement,
        "activity_dynamic_power_overhead_fraction": power_overhead,
        "checks": checks,
        "hardware_gate_pass": all(checks.values()),
    }


def write_markdown(result: dict[str, Any], path: Path) -> None:
    main = result["replays"][result["main_replay"]]
    lines = [
        "# Prefetch Deployment Gate",
        "",
        f"Decision: **{result['decision']}**",
        "",
        "## Main replay",
        "",
        "| metric | value | gate |",
        "| --- | ---: | --- |",
        f"| aggregate cycle improvement | {main['cycle_improvement_fraction']:.3%} | >= 1% |",
        f"| bandwidth overhead | {main['bandwidth_overhead_fraction']:.3%} | <= 10% |",
        f"| non-slow windows | {main['non_slow_windows']}/{main['pair_count']} | >= 20/25 |",
        f"| maximum window slowdown | {main['max_window_slowdown_fraction']:.3%} | <= 5% |",
        f"| PF-caused writebacks | {main['counters']['on_pf_caused_writebacks']} | = 0 |",
    ]
    hardware = result.get("vivado")
    if hardware is not None:
        lines.extend(
            [
                "",
                "## Hardware",
                "",
                "| metric | value | gate |",
                "| --- | ---: | --- |",
                f"| OOC LUT overhead | {hardware['lut_overhead_fraction']:.3%} | <= 15% |",
                f"| OOC FF overhead | {hardware['ff_overhead_fraction']:.3%} | <= 15% |",
                f"| OOC P3-lite WNS | {hardware['ooc_p3_lite_wns_ns']:.3f} ns | >= 0 ns |",
                f"| post-route P3-lite WNS | {hardware['post_route_p3_lite_wns_ns']:.3f} ns | >= 0 ns |",
                f"| post-route P3-lite WHS | {hardware['post_route_p3_lite_whs_ns']:.3f} ns | >= 0 ns |",
                f"| activity dynamic-power overhead | {hardware['activity_dynamic_power_overhead_fraction']:.3%} | <= 10% |",
                f"| achieved-Fmax time improvement | {hardware['execution_time_proxy_improvement_fraction']:.3%} | > 0% |",
            ]
        )
    lines.extend(
        [
            "",
            "A failed gate is an experimental result, not a validator crash. "
            "When the combined gate fails, deployment must default to prefetch disabled.",
            "",
        ]
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines), encoding="utf-8")


def parse_named_path(value: str) -> tuple[str, Path]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("expected NAME=PATH")
    name, raw_path = value.split("=", 1)
    if not name or not raw_path:
        raise argparse.ArgumentTypeError("expected non-empty NAME=PATH")
    return name, Path(raw_path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--replay", action="append", type=parse_named_path, required=True)
    parser.add_argument("--main-replay", required=True)
    parser.add_argument("--vivado-manifest", type=Path)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--require-pass", action="store_true")
    args = parser.parse_args()

    replay_args = dict(args.replay)
    if len(replay_args) != len(args.replay):
        raise SystemExit("duplicate --replay name")
    if args.main_replay not in replay_args:
        raise SystemExit("--main-replay must name one --replay entry")
    try:
        replays = {
            name: load_replay(name, root.resolve())
            for name, root in replay_args.items()
        }
        main_replay = replays[args.main_replay]
        vivado = (
            load_vivado(args.vivado_manifest.resolve(), main_replay)
            if args.vivado_manifest
            else None
        )
    except (EvidenceError, OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"evidence validation failed: {exc}") from exc

    combined_pass = main_replay["replay_gate_pass"] and (
        vivado is None or vivado["hardware_gate_pass"]
    )
    result = {
        "schema": "l1d-prefetch-gate-v1",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "status": "PASS",
        "main_replay": args.main_replay,
        "combined_gate_pass": combined_pass,
        "decision": (
            "ENABLE_DEPLOY_PREFETCH"
            if combined_pass
            else "DISABLE_DEPLOY_PREFETCH_STRUCTURAL_LIMIT"
        ),
        "replays": replays,
        "vivado": vivado,
    }
    args.out_dir.mkdir(parents=True, exist_ok=True)
    json_path = args.out_dir / "gate-result.json"
    json_path.write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    write_markdown(result, args.out_dir / "gate-result.md")
    print(f"{result['decision']} ({json_path})")
    return 1 if args.require_pass and not combined_pass else 0


if __name__ == "__main__":
    raise SystemExit(main())
