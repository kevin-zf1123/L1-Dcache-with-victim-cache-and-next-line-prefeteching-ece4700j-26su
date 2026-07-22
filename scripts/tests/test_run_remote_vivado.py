from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "run_remote_vivado", ROOT / "scripts" / "run_remote_vivado.py"
)
assert SPEC is not None and SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class RunRemoteVivadoEvidenceTests(unittest.TestCase):
    def report_text(self, filename: str) -> str:
        if "utilization" in filename:
            return """\
| Slice LUTs*        | 100 | 0 | 0 | 1000 | 10.0 |
| LUT as Logic       | 80  | 0 | 0 | 1000 | 8.0  |
| LUT as Memory      | 20  | 0 | 0 | 1000 | 2.0  |
| Slice Registers    | 70  | 0 | 0 | 1000 | 7.0  |
| F7 Muxes           | 4   | 0 | 0 | 1000 | 0.4  |
| F8 Muxes           | 2   | 0 | 0 | 1000 | 0.2  |
| Unique Control Sets| 3   | 0 | 0 | 1000 | 0.3  |
| Block RAM Tile     | 0   | 0 | 0 | 50   | 0.0  |
"""
        if "timing_summary" in filename:
            checks = "\n".join(
                f"checking {name} (0)"
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
                )
            )
            return (
                f"check_timing report\n{checks}\n{checks}\n"
                "| Design Timing Summary\n"
                "    WNS(ns) TNS(ns) TNS Failing Endpoints TNS Total Endpoints "
                "WHS(ns) THS(ns) THS Failing Endpoints THS Total Endpoints\n"
                "      0.250 0.000 0 70 0.050 0.000 0 70\n"
            )
        if "power" in filename:
            activity = "fixture.saif" if "activity" in filename else "---"
            matched = "60%   (60/100)" if "activity" in filename else "NA"
            return f"""\
| Total On-Chip Power (W)  | 0.100 |
| Dynamic (W)              | 0.030 |
| Device Static (W)        | 0.070 |
| Confidence Level         | High  |
| Simulation Activity File | {activity} |
| Design Nets Matched      | {matched} |
"""
        return f"fixture {filename}\n"

    def workload_line(
        self,
        simulation_name: str,
        workload: str,
        **overrides: object,
    ) -> str:
        geometry = RUNNER.SIMULATION_CONFIGURATIONS[simulation_name]
        config_id = simulation_name
        if simulation_name.startswith("trace_replay_smoke_"):
            config_id = "2w_s4_vc4_pf0"
        elif simulation_name.startswith("trace_replay_generated_pointer_") or (
            simulation_name.startswith("2w_s4_vc4_pf1_")
        ):
            config_id = "2w_s4_vc4_pf1"
        l1_bytes = geometry["sets"] * geometry["ways"] * geometry["line_bytes"]
        victim_bytes = geometry["victim_entries"] * geometry["line_bytes"]
        fields: dict[str, object] = {
            "schema": 3,
            "name": workload,
            "config_id": config_id,
            "sets": geometry["sets"],
            "ways": geometry["ways"],
            "line_bytes": geometry["line_bytes"],
            "l1_bytes": l1_bytes,
            "victim_entries": geometry["victim_entries"],
            "victim_bytes": victim_bytes,
            "total_bytes": l1_bytes + victim_bytes,
            "mem_latency": geometry["mem_latency"],
            "mem_bp": geometry["mem_bp"],
            "cpu_bp": geometry["cpu_bp"],
            "status": "PASS",
            "watchdogs": 0,
            "protocol": 0,
            "duplicate_lines": 0,
            "pf_admitted": 0,
            "pf_issued": 0,
            "pf_returned": 0,
            "pf_installed": 0,
            "pf_merged": 0,
            "pf_discarded": 0,
            "pf_cancelled": 0,
            "timely_useful": 0,
            "pf_unused_evicted": 0,
            "pf_unused_resident": 0,
            "pf_caused_writebacks": 0,
            "pf_mshr_valid": 0,
        }
        fields.update(overrides)
        return "WORKLOAD_RESULT " + " ".join(
            f"{key}={value}" for key, value in fields.items()
        )

    def make_valid_tree(self, root: Path) -> None:
        report_root = root / "build" / "vivado" / "reports"
        report_root.mkdir(parents=True)
        for name, workloads in RUNNER.SIMULATION_WORKLOADS.items():
            lines = [self.workload_line(name, workload) for workload in workloads]
            lines.append("ALL OOP TESTS PASSED")
            (report_root / f"{name}_simulation.log").write_text(
                "\n".join(lines) + "\n", encoding="utf-8"
            )
        for name, marker in RUNNER.AUXILIARY_SIMULATIONS.items():
            (report_root / f"{name}_simulation.log").write_text(
                f"PASS: 1 {marker}\n", encoding="utf-8"
            )
        for name, marker in RUNNER.ACTIVITY_SIMULATIONS.items():
            (report_root / f"{name}_simulation.log").write_text(
                f"{marker} fixture\n", encoding="utf-8"
            )

        vivado_lines = ["Vivado v2024.2.1"]
        ooc_root = report_root / "ooc"
        ooc_root.mkdir()
        for name, geometry in RUNNER.SYNTHESIS_CONFIGURATIONS.items():
            vivado_lines.append(f"Running Vivado synthesis: {name}")
            for parameter, geometry_field in RUNNER.SYNTHESIS_PARAMETER_FIELDS.items():
                vivado_lines.append(
                    f"  Parameter {parameter} bound to: "
                    f"{geometry[geometry_field]} - type: integer"
                )
            report_dir = ooc_root / name
            report_dir.mkdir()
            for filename in RUNNER.OOC_REPORTS:
                (report_dir / filename).write_text(
                    self.report_text(filename), encoding="utf-8"
                )
        implementation_root = report_root / "implementation"
        implementation_root.mkdir()
        for name, geometry in RUNNER.IMPLEMENTATION_CONFIGURATIONS.items():
            vivado_lines.append(f"Running Vivado implementation: {name}")
            for parameter, geometry_field in RUNNER.SYNTHESIS_PARAMETER_FIELDS.items():
                vivado_lines.append(
                    f"  Parameter {parameter} bound to: "
                    f"{geometry[geometry_field]} - type: integer"
                )
            report_dir = implementation_root / name
            report_dir.mkdir()
            for filename in RUNNER.IMPLEMENTATION_REPORTS:
                (report_dir / filename).write_text(
                    self.report_text(filename), encoding="utf-8"
                )
        activity_root = report_root / "activity"
        activity_root.mkdir()
        for name in RUNNER.IMPLEMENTATION_CONFIGURATIONS:
            (activity_root / f"{name}.saif").write_text(
                f"(SAIFILE ({name}))\n", encoding="utf-8"
            )
        (root / "vivado.log").write_text(
            "\n".join(vivado_lines) + "\n", encoding="utf-8"
        )
        (root / "vivado.jou").write_text("journal\n", encoding="utf-8")
        (report_root / "2w_s4_vc4_pf1.vcd").write_text(
            "$comment fixture $end\n", encoding="utf-8"
        )

    def test_valid_exact_matrix_and_provenance_artifacts_pass(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_valid_tree(root)
            findings, evidence = RUNNER.validate_report_matrix(root)

        self.assertEqual([], findings)
        self.assertEqual(15, len(evidence["simulations"]))
        self.assertEqual(8, len(evidence["synthesis"]))
        self.assertEqual(4, len(evidence["implementation"]))
        self.assertEqual(7, len(evidence["artifacts"]))
        self.assertEqual(
            100, evidence["synthesis"][0]["metrics"]["utilization"]["slice_luts"]
        )
        self.assertEqual(
            0.25, evidence["implementation"][0]["metrics"]["timing"]["wns_ns"]
        )
        self.assertEqual(
            60,
            evidence["implementation"][0]["metrics"]["power_activity"][
                "matched_design_nets"
            ],
        )

    def test_numerical_report_parser_rejects_missing_fields(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report = Path(temporary) / "timing.rpt"
            report.write_text("Design Timing Summary without table\n", encoding="utf-8")
            with self.assertRaisesRegex(
                RUNNER.ReportParseError, "missing check_timing report"
            ):
                RUNNER.parse_timing_summary_report(report)

    def test_power_parser_accepts_legacy_matched_net_count_format(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            report = Path(temporary) / "power_activity.rpt"
            report.write_text(
                self.report_text(report.name).replace(
                    "60%   (60/100)", "60 of 100"
                ),
                encoding="utf-8",
            )

            metrics = RUNNER.parse_power_report(report)

        self.assertEqual(60, metrics["matched_design_nets"])
        self.assertEqual(100, metrics["total_design_nets"])

    def test_log_scan_accepts_oop_and_auxiliary_pass_markers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_valid_tree(root)
            status, findings = RUNNER.scan_logs(root, RUNNER.DEFAULT_DOWNLOADS)

        self.assertEqual(0, status)
        self.assertEqual([], findings)

    def test_log_scan_does_not_treat_report_fail_status_as_tool_crash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_valid_tree(root)
            report = (
                root
                / "build/vivado/reports/ooc/optimized_pf0_deploy/timing_summary.rpt"
            )
            report.write_text("Design Timing Summary: FAIL\n", encoding="utf-8")
            status, findings = RUNNER.scan_logs(root, RUNNER.DEFAULT_DOWNLOADS)

        self.assertEqual(0, status)
        self.assertEqual([], findings)

    def test_log_scan_treats_timing_gate_warning_as_nonfatal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_valid_tree(root)
            log = root / "vivado.log"
            with log.open("a", encoding="utf-8") as handle:
                handle.write(
                    "CRITICAL WARNING: [Timing 38-282] The design failed to "
                    "meet the timing requirements. Please see the timing "
                    "summary report for details on the timing violations.\n"
                )
            status, findings = RUNNER.scan_logs(root, RUNNER.DEFAULT_DOWNLOADS)

        self.assertEqual(0, status)
        self.assertEqual([], findings)

    def test_log_scan_still_rejects_other_critical_warnings(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_valid_tree(root)
            log = root / "vivado.log"
            with log.open("a", encoding="utf-8") as handle:
                handle.write(
                    "CRITICAL WARNING: [Timing 38-999] Unexpected timing "
                    "analysis failure.\n"
                )
            status, findings = RUNNER.scan_logs(root, RUNNER.DEFAULT_DOWNLOADS)

        self.assertEqual(1, status)
        self.assertTrue(
            any("Timing 38-999" in finding for finding in findings),
            findings,
        )

    def test_log_scan_rejects_missing_auxiliary_pass_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_valid_tree(root)
            log = root / "build/vivado/reports/p3_prefetch_mshr_simulation.log"
            log.write_text("PASS: unrelated checks\n", encoding="utf-8")
            status, findings = RUNNER.scan_logs(root, RUNNER.DEFAULT_DOWNLOADS)

        self.assertEqual(1, status)
        self.assertTrue(
            any(
                "missing PASS marker 'directed P3 PF-MSHR checks'" in finding
                for finding in findings
            ),
            findings,
        )

    def test_truncated_workload_log_fails_exact_matrix(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_valid_tree(root)
            log = root / "build/vivado/reports/dm_s8_vc4_pf0_simulation.log"
            log.write_text(
                self.workload_line("dm_s8_vc4_pf0", "directed_rv64") + "\n",
                encoding="utf-8",
            )
            findings, _ = RUNNER.validate_report_matrix(root)

        self.assertTrue(
            any("workload matrix mismatch" in finding for finding in findings),
            findings,
        )
        self.assertTrue(any("actual_count=1" in finding for finding in findings))

    def test_duplicate_workload_and_bad_derived_capacity_fail(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_valid_tree(root)
            name = "2w_s4_vc4_pf0"
            workloads = list(RUNNER.SIMULATION_WORKLOADS[name])
            workloads[-1] = workloads[0]
            lines = [
                self.workload_line(
                    name,
                    workload,
                    **({"l1_bytes": 999} if index == 0 else {}),
                )
                for index, workload in enumerate(workloads)
            ]
            log = root / f"build/vivado/reports/{name}_simulation.log"
            log.write_text("\n".join(lines) + "\n", encoding="utf-8")
            findings, _ = RUNNER.validate_report_matrix(root)

        self.assertTrue(any("duplicates=['directed_rv64']" in f for f in findings))
        self.assertTrue(any("l1_bytes='999', expected 128" in f for f in findings))

    def test_nonzero_drained_optimized_lifecycle_passes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_valid_tree(root)
            name = "2w_s4_vc4_pf1"
            log = root / f"build/vivado/reports/{name}_simulation.log"
            lines = log.read_text(encoding="utf-8").splitlines()
            lines[0] = self.workload_line(
                name,
                RUNNER.SIMULATION_WORKLOADS[name][0],
                pf_admitted=4,
                pf_issued=3,
                pf_cancelled=1,
                pf_returned=3,
                pf_installed=1,
                pf_merged=1,
                pf_discarded=1,
                timely_useful=0,
                pf_unused_evicted=1,
                pf_unused_resident=0,
            )
            log.write_text("\n".join(lines) + "\n", encoding="utf-8")
            findings, _ = RUNNER.validate_report_matrix(root)

        self.assertEqual([], findings)

    def test_invalid_optimized_lifecycle_relations_fail(self) -> None:
        cases = (
            (
                {"pf_admitted": 1},
                "pf_admitted must be <= pf_issued + pf_cancelled after drain",
            ),
            (
                {"pf_admitted": 1, "pf_issued": 1},
                "pf_issued == pf_returned",
            ),
            (
                {"pf_admitted": 1, "pf_issued": 1, "pf_returned": 1},
                "pf_returned == pf_installed + pf_merged + pf_discarded",
            ),
            (
                {
                    "pf_admitted": 1,
                    "pf_issued": 1,
                    "pf_returned": 1,
                    "pf_installed": 1,
                },
                "pf_installed == timely_useful + pf_unused_evicted + "
                "pf_unused_resident",
            ),
            ({"pf_caused_writebacks": 1}, "pf_caused_writebacks=1, expected 0"),
            ({"pf_mshr_valid": 1}, "pf_mshr_valid=1, expected 0"),
        )
        for overrides, expected in cases:
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.make_valid_tree(root)
                name = "2w_s4_vc4_pf1"
                log = root / f"build/vivado/reports/{name}_simulation.log"
                lines = log.read_text(encoding="utf-8").splitlines()
                lines[1] = self.workload_line(
                    name,
                    RUNNER.SIMULATION_WORKLOADS[name][1],
                    **overrides,
                )
                log.write_text("\n".join(lines) + "\n", encoding="utf-8")
                findings, _ = RUNNER.validate_report_matrix(root)

            self.assertTrue(
                any(expected in finding for finding in findings), findings
            )

    def test_missing_or_non_decimal_optimized_lifecycle_field_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_valid_tree(root)
            name = "2w_s4_vc4_pf1"
            log = root / f"build/vivado/reports/{name}_simulation.log"
            lines = log.read_text(encoding="utf-8").splitlines()
            lines[0] = lines[0].replace(" pf_cancelled=0", "")
            lines[1] = lines[1].replace(" pf_mshr_valid=0", " pf_mshr_valid=x")
            log.write_text("\n".join(lines) + "\n", encoding="utf-8")
            findings, _ = RUNNER.validate_report_matrix(root)

        self.assertTrue(
            any(
                "missing optimized lifecycle field pf_cancelled" in finding
                for finding in findings
            ),
            findings,
        )
        self.assertTrue(
            any(
                "pf_mshr_valid='x', expected non-negative decimal integer"
                in finding
                for finding in findings
            ),
            findings,
        )

    def test_synthesis_parameter_mismatch_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_valid_tree(root)
            log = root / "vivado.log"
            log.write_text(
                log.read_text(encoding="utf-8").replace(
                    "Parameter PF_USE_STREAM bound to: 0",
                    "Parameter PF_USE_STREAM bound to: 1",
                    1,
                ),
                encoding="utf-8",
            )
            findings, _ = RUNNER.validate_report_matrix(root)

        self.assertTrue(
            any(
                "optimized_pf0_deploy: PF_USE_STREAM bindings=[1], expected [0]"
                in finding
                for finding in findings
            ),
            findings,
        )

    def test_execution_failures_become_manifest_findings(self) -> None:
        execution, findings = RUNNER.execution_evidence(
            "vivado -mode batch",
            7,
            ["build/vivado/reports", "vivado.log"],
            log_scan_skipped=False,
        )
        self.assertEqual(7, execution["remote_exit_status"])
        self.assertIn("remote Vivado exited with status 7", findings)
        self.assertIn(
            "remote download failed: build/vivado/reports", findings
        )
        self.assertIn("remote download failed: vivado.log", findings)

    def test_failed_execution_writes_fail_manifest_with_runner_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "constraints").mkdir()
            (root / "constraints/l1d_baseline.xdc").write_text(
                "create_clock -name clk -period 10.000 [get_ports clk]\n",
                encoding="utf-8",
            )
            (root / "scripts").mkdir()
            (root / "scripts/run_remote_vivado.py").write_text(
                "# fixture runner\n", encoding="utf-8"
            )
            (root / "vivado.log").write_text(
                "Vivado v2024.2.1\n", encoding="utf-8"
            )
            args = argparse.Namespace(vivado="vivado.bat", part_env="")
            execution, findings = RUNNER.execution_evidence(
                "vivado -mode batch", 3, [], log_scan_skipped=False
            )
            completed = [
                subprocess.CompletedProcess([], 0, stdout="abc123\n"),
                subprocess.CompletedProcess([], 0, stdout=""),
            ]
            with mock.patch.object(RUNNER, "DEFAULT_UPLOADS", []), mock.patch.object(
                RUNNER.subprocess, "run", side_effect=completed
            ):
                manifest_path = RUNNER.write_evidence_manifest(
                    root,
                    args,
                    {"simulations": [], "synthesis": [], "artifacts": {}},
                    findings,
                    execution,
                )
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

        self.assertEqual("FAIL", manifest["status"])
        self.assertEqual(3, manifest["execution"]["remote_exit_status"])
        self.assertIn("scripts/run_remote_vivado.py", manifest["inputs"])


if __name__ == "__main__":
    unittest.main()
