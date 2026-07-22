from __future__ import annotations

import csv
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "evaluate_prefetch_evidence", ROOT / "scripts/evaluate_prefetch_evidence.py"
)
assert SPEC is not None and SPEC.loader is not None
EVALUATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVALUATOR)


class EvaluatePrefetchEvidenceTests(unittest.TestCase):
    def make_replay(self, root: Path, *, on_cycles: int = 98_000) -> None:
        analysis = root / "analysis"
        analysis.mkdir(parents=True)
        aggregate = {
            "pair_count": 25,
            "timing_profile": "blocking-fixed-latency2-periodic-ready",
            "producer_profile": "zero-bubble",
            "producer_gap": 0,
            "prefetch_policy": 1,
            "pf_opt_level": 3,
            "off_replay_service_cycles": 100_000,
            "on_replay_service_cycles": on_cycles,
            "off_read_bytes": 80_000,
            "off_write_bytes": 20_000,
            "on_read_bytes": 80_000,
            "on_write_bytes": 20_000,
            "on_pf_candidates": 100,
            "on_pf_admitted": 20,
            "on_pf_issued": 20,
            "on_pf_returned": 20,
            "on_pf_installed": 10,
            "on_pf_merged": 10,
            "on_pf_discarded": 0,
            "on_pf_cancelled": 0,
            "on_pf_unused_evicted": 5,
            "on_pf_unused_resident": 5,
            "on_pf_caused_writebacks": 0,
            "on_pf_demand_block_cycles": 0,
        }
        with (analysis / "aggregate.csv").open(
            "w", newline="", encoding="utf-8"
        ) as handle:
            writer = csv.DictWriter(handle, fieldnames=list(aggregate))
            writer.writeheader()
            writer.writerow(aggregate)
        with (analysis / "pairs.csv").open(
            "w", newline="", encoding="utf-8"
        ) as handle:
            writer = csv.DictWriter(handle, fieldnames=["cycle_delta_fraction"])
            writer.writeheader()
            for _ in range(25):
                writer.writerow({"cycle_delta_fraction": "-0.020"})
        (analysis / "validation.json").write_text(
            json.dumps({"status": "PASS"}) + "\n", encoding="utf-8"
        )
        (root / "campaign_manifest.json").write_text(
            json.dumps({"status": "PASS"}) + "\n", encoding="utf-8"
        )

    def timing(self, fmax: float = 1000.0 / 9.9) -> dict[str, float | int]:
        result: dict[str, float | int] = {
            "wns_ns": 0.1,
            "tns_ns": 0.0,
            "setup_failing_endpoints": 0,
            "whs_ns": 0.05,
            "ths_ns": 0.0,
            "hold_failing_endpoints": 0,
            "clock_period_ns": 10.0,
            "slack_derived_fmax_mhz": fmax,
        }
        for name in (
            "no_clock",
            "constant_clock",
            "unconstrained_internal_endpoints",
            "no_input_delay",
            "no_output_delay",
            "multiple_clock",
            "loops",
            "partial_input_delay",
            "partial_output_delay",
            "latch_loops",
        ):
            result[f"check_{name}"] = 0
        return result

    def utilization(self, *, luts: int, ffs: int) -> dict[str, int]:
        return {
            "slice_luts": luts,
            "lut_as_logic": luts - 20,
            "lut_as_memory": 20,
            "slice_registers": ffs,
            "f7_muxes": 4,
            "f8_muxes": 2,
            "block_ram_tiles": 0,
            "unique_control_sets": 3,
        }

    def utilization_report(self, metrics: dict[str, int]) -> str:
        return f"""\
| Slice LUTs*         | {metrics['slice_luts']} | 0 | 0 | 1000 | 10.0 |
| LUT as Logic        | {metrics['lut_as_logic']} | 0 | 0 | 1000 | 8.0 |
| LUT as Memory       | {metrics['lut_as_memory']} | 0 | 0 | 1000 | 2.0 |
| Slice Registers     | {metrics['slice_registers']} | 0 | 0 | 1000 | 7.0 |
| F7 Muxes            | {metrics['f7_muxes']} | 0 | 0 | 1000 | 0.4 |
| F8 Muxes            | {metrics['f8_muxes']} | 0 | 0 | 1000 | 0.2 |
| Unique Control Sets | {metrics['unique_control_sets']} | 0 | 0 | 1000 | 0.3 |
| Block RAM Tile      | {metrics['block_ram_tiles']} | 0 | 0 | 50 | 0.0 |
"""

    def timing_report(self, metrics: dict[str, float | int]) -> str:
        names = (
            "no_clock",
            "constant_clock",
            "unconstrained_internal_endpoints",
            "no_input_delay",
            "no_output_delay",
            "multiple_clock",
            "loops",
            "partial_input_delay",
            "partial_output_delay",
            "latch_loops",
        )
        checks = "\n".join(
            f"checking {name} ({metrics[f'check_{name}']})" for name in names
        )
        return (
            f"check_timing report\n{checks}\n{checks}\n"
            "| Design Timing Summary\n"
            f" {metrics['wns_ns']} {metrics['tns_ns']} "
            f"{metrics['setup_failing_endpoints']} 70 "
            f"{metrics['whs_ns']} {metrics['ths_ns']} "
            f"{metrics['hold_failing_endpoints']} 70\n"
        )

    def power(self, *, dynamic: float, activity: bool) -> dict[str, object]:
        return {
            "total_on_chip_w": dynamic + 0.07,
            "dynamic_w": dynamic,
            "device_static_w": 0.07,
            "confidence": "High",
            "simulation_activity_file": "fixture.saif" if activity else None,
            "matched_design_nets": 60 if activity else None,
            "total_design_nets": 100 if activity else None,
        }

    def power_report(self, metrics: dict[str, object]) -> str:
        activity = metrics["simulation_activity_file"] or "---"
        matched = (
            f"{metrics['matched_design_nets']} of {metrics['total_design_nets']}"
            if metrics["matched_design_nets"] is not None
            else "NA"
        )
        return f"""\
| Total On-Chip Power (W)  | {metrics['total_on_chip_w']} |
| Dynamic (W)              | {metrics['dynamic_w']} |
| Device Static (W)        | {metrics['device_static_w']} |
| Confidence Level         | {metrics['confidence']} |
| Simulation Activity File | {activity} |
| Design Nets Matched      | {matched} |
"""

    def make_vivado(self, path: Path) -> None:
        root = path.parents[2]
        path.parent.mkdir(parents=True)
        input_path = root / "fixture.input"
        input_path.write_text("bound input\n", encoding="utf-8")

        def artifact(rel_path: str, text: str) -> dict[str, str]:
            report = root / rel_path
            report.parent.mkdir(parents=True, exist_ok=True)
            report.write_text(text, encoding="utf-8")
            return {"path": rel_path, "sha256": EVALUATOR.sha256(report)}

        synthesis = []
        implementation = []
        for name, luts, ffs, dynamic in (
            ("optimized_pf0_deploy", 100, 100, 0.100),
            ("p3_lite_mshr_fixed", 110, 112, 0.105),
        ):
            util = self.utilization(luts=luts, ffs=ffs)
            timing = self.timing()
            vectorless = self.power(dynamic=dynamic, activity=False)
            activity_power = self.power(dynamic=dynamic, activity=True)
            ooc_prefix = f"build/vivado/reports/ooc/{name}"
            impl_prefix = f"build/vivado/reports/implementation/{name}"
            synthesis.append(
                {
                    "config_id": name,
                    "metrics": {
                        "utilization": util,
                        "timing": timing,
                        "power_vectorless": vectorless,
                    },
                    "reports": {
                        "utilization.rpt": artifact(
                            f"{ooc_prefix}/utilization.rpt",
                            self.utilization_report(util),
                        ),
                        "timing_summary.rpt": artifact(
                            f"{ooc_prefix}/timing_summary.rpt",
                            self.timing_report(timing),
                        ),
                        "power_vectorless.rpt": artifact(
                            f"{ooc_prefix}/power_vectorless.rpt",
                            self.power_report(vectorless),
                        ),
                    },
                }
            )
            implementation.append(
                {
                    "config_id": name,
                    "metrics": {
                        "utilization": util,
                        "timing": timing,
                        "power_activity": activity_power,
                    },
                    "reports": {
                        "post_route_utilization.rpt": artifact(
                            f"{impl_prefix}/post_route_utilization.rpt",
                            self.utilization_report(util),
                        ),
                        "post_route_timing_summary.rpt": artifact(
                            f"{impl_prefix}/post_route_timing_summary.rpt",
                            self.timing_report(timing),
                        ),
                        "post_route_power_activity.rpt": artifact(
                            f"{impl_prefix}/post_route_power_activity.rpt",
                            self.power_report(activity_power),
                        ),
                    },
                }
            )
        path.write_text(
            json.dumps(
                {
                    "schema": "l1d-vivado-evidence-v3",
                    "status": "PASS",
                    "repository": {"commit": "fixture", "dirty": False},
                    "tool": {"vivado_version": "2024.2.1"},
                    "inputs": {"fixture.input": EVALUATOR.sha256(input_path)},
                    "synthesis": synthesis,
                    "implementation": implementation,
                }
            )
            + "\n",
            encoding="utf-8",
        )

    def test_passing_replay_and_hardware_gates(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            replay_root = root / "replay"
            self.make_replay(replay_root)
            vivado_path = root / "build/vivado/evidence_manifest.json"
            self.make_vivado(vivado_path)
            replay = EVALUATOR.load_replay("p3-lite", replay_root)
            vivado = EVALUATOR.load_vivado(vivado_path, replay)
            markdown = root / "gate.md"
            EVALUATOR.write_markdown(
                {
                    "decision": "ENABLE_DEPLOY_PREFETCH",
                    "main_replay": "p3-lite",
                    "replays": {"p3-lite": replay},
                    "vivado": vivado,
                },
                markdown,
            )
            markdown_text = markdown.read_text(encoding="utf-8")

        self.assertTrue(replay["replay_gate_pass"])
        self.assertEqual(25, replay["non_slow_windows"])
        self.assertAlmostEqual(0.02, replay["cycle_improvement_fraction"])
        self.assertTrue(vivado["hardware_gate_pass"])
        self.assertAlmostEqual(0.10, vivado["lut_overhead_fraction"])
        self.assertIn("PF-caused writebacks", markdown_text)

    def test_sub_one_percent_improvement_is_a_gate_result_not_parse_error(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            replay_root = Path(temporary) / "replay"
            self.make_replay(replay_root, on_cycles=99_500)
            replay = EVALUATOR.load_replay("p3-lite", replay_root)

        self.assertFalse(replay["replay_gate_pass"])
        self.assertFalse(replay["checks"]["aggregate_cycle_improvement_ge_1pct"])

    def test_missing_validation_artifact_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            replay_root = Path(temporary) / "replay"
            self.make_replay(replay_root)
            (replay_root / "analysis/validation.json").unlink()
            with self.assertRaises(OSError):
                EVALUATOR.load_replay("p3-lite", replay_root)


if __name__ == "__main__":
    unittest.main()
