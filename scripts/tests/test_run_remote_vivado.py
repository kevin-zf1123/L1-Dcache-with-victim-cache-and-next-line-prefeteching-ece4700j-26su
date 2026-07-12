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
            "schema": 2,
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

        vivado_lines = ["Vivado v2024.2.1"]
        for name, geometry in RUNNER.SYNTHESIS_CONFIGURATIONS.items():
            vivado_lines.append(f"Running Vivado synthesis: {name}")
            for parameter, geometry_field in RUNNER.SYNTHESIS_PARAMETER_FIELDS.items():
                vivado_lines.append(
                    f"  Parameter {parameter} bound to: "
                    f"{geometry[geometry_field]} - type: integer"
                )
            report_dir = report_root / name
            report_dir.mkdir()
            for filename in ("utilization.rpt", "timing_summary.rpt", "power.rpt"):
                (report_dir / filename).write_text(
                    f"{name} {filename}\n", encoding="utf-8"
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
        self.assertEqual(8, len(evidence["simulations"]))
        self.assertEqual(4, len(evidence["synthesis"]))
        self.assertEqual(3, len(evidence["artifacts"]))

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

    def test_synthesis_parameter_mismatch_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_valid_tree(root)
            log = root / "vivado.log"
            log.write_text(
                log.read_text(encoding="utf-8").replace(
                    "Parameter NUM_SETS bound to: 8",
                    "Parameter NUM_SETS bound to: 4",
                    1,
                ),
                encoding="utf-8",
            )
            findings, _ = RUNNER.validate_report_matrix(root)

        self.assertTrue(
            any(
                "dm_s8_vc4_pf0: NUM_SETS bindings=[4], expected [8]" in finding
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
