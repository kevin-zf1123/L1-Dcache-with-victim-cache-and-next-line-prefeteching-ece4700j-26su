from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts"))

from capture_spec_qemu_windows import (  # noqa: E402
    HOST_INPUT_PATHS,
    command_sha,
    parse_compare_cmd,
    parse_speccmds,
    write_benchmark_plan,
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fake_toolchain() -> dict[str, object]:
    digest = "a" * 64
    identity = {"path": "/fixture/input", "bytes": 1, "sha256": digest}
    files = {relative: dict(identity, path=f"/fixture/{relative}") for relative in HOST_INPUT_PATHS}
    aggregate = hashlib.sha256()
    for relative in HOST_INPUT_PATHS:
        aggregate.update(relative.encode() + b"\0")
        aggregate.update(digest.encode() + b"\0")
    return {
        "qemu_executable": identity,
        "immutable_vm_inputs": {
            name: dict(identity, path=f"/fixture/{name}")
            for name in ("uefi_code_pflash", "uefi_vars", "base_qcow2", "seed_iso")
        },
        "host_inputs": {"sha256": aggregate.hexdigest(), "files": files},
    }


class ReplayRunnerTests(unittest.TestCase):
    def test_invalid_replay_matrix_is_rejected_before_replay(self) -> None:
        cases = (
            ({"L1D_PREFETCH_POLICY": "0", "L1D_PF_OPT_LEVEL": "3"}, "requires"),
            ({"L1D_PRODUCER_PROFILE": "fixed-gap", "L1D_PRODUCER_GAP": "3"}, "1, 2, 4, or 8"),
            ({"L1D_MEM_LATENCY": "-1"}, "non-negative integer"),
            ({"L1D_MEM_LATENCY": "fast"}, "non-negative integer"),
            (
                {"L1D_MEM_READY_MODE": "random"},
                "always-ready, periodic, or deterministic-random",
            ),
            ({"L1D_REPLAY_SCOPE": "pair"}, "full or paired"),
        )
        for overrides, expected in cases:
            with self.subTest(overrides=overrides):
                environment = os.environ.copy()
                environment.update(overrides)
                completed = subprocess.run(
                    [str(REPO / "scripts" / "run_spec_trace_replay.sh")],
                    check=False,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    env=environment,
                )
                self.assertEqual(completed.returncode, 2, completed.stdout)
                self.assertIn(expected, completed.stdout)

    def test_failed_capture_validation_removes_stale_pass_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            capture = root / "capture" / "campaign_manifest.json"
            capture.parent.mkdir(parents=True)
            capture.write_text(
                json.dumps(
                    {
                        "schema": "l1d-qemu-capture-campaign-v2",
                        "status": "INVALID",
                        "valid": False,
                        "requested_benchmarks": ["fixture"],
                        "expected_capture_units": 0,
                        "captures": [],
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            replay_root = root / "replay"
            logs = replay_root / "logs"
            logs.mkdir(parents=True)
            stale_manifest = replay_root / "campaign_manifest.json"
            stale_manifest.write_text('{"status":"PASS"}\n', encoding="utf-8")
            stale_sha = replay_root / "campaign_manifest.json.sha256"
            stale_sha.write_text("stale\n", encoding="utf-8")
            stale_analysis = replay_root / "analysis"
            stale_analysis.mkdir()
            (stale_analysis / "validation.json").write_text(
                '{"status":"PASS"}\n', encoding="utf-8"
            )

            completed = subprocess.run(
                [
                    str(REPO / "scripts" / "run_spec_trace_replay.sh"),
                    str(capture),
                    str(logs),
                ],
                cwd=root,
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )

            self.assertNotEqual(0, completed.returncode)
            self.assertFalse(stale_manifest.exists())
            self.assertFalse(stale_sha.exists())
            self.assertFalse(stale_analysis.exists())

    def test_manifest_driven_four_config_smoke_from_arbitrary_cwd(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            capture_root = root / "capture"
            bench_dir = capture_root / "708_sqlite_r"
            unit = bench_dir / "cmd000"
            replay_dir = unit / "replay"
            replay_dir.mkdir(parents=True)
            speccmds = bench_dir / "speccmds.original.cmd"
            speccmds.write_text(
                "-C /spec/run\n-o out -e err ../fixture > out 2>> err\n",
                encoding="utf-8",
            )
            parsed_commands = parse_speccmds(speccmds.read_text(encoding="utf-8"))
            replay = replay_dir / "spec2026_708_sqlite_r_cmd000_w00_whole_n12.trace"
            long_summary = (
                "# summary status=PASS "
                + " ".join(f"counter_{index}=123456789" for index in range(32))
                + "\n"
            )
            self.assertGreater(len(long_summary.encode("utf-8")), 256)
            replay.write_text(
                "# PHASE warmup\n"
                "# PHASE measure\n"
                + (REPO / "traces" / "smoke.trace").read_text(encoding="utf-8")
                + long_summary,
                encoding="utf-8",
            )
            raw = unit / "capture.raw.tsv"
            raw.write_text("fixture raw evidence\n", encoding="utf-8")
            compare_text = "-C /spec/run\n-k -o out.cmp specdiff /ref/out out > out.cmp\n"
            compare_plan = parse_compare_cmd(compare_text, run_dir="/spec/run")
            comparison = compare_plan.evidence({"/spec/run/out"})
            comparison.update(
                {"count_pass_status": "PASS", "capture_pass_status": "PASS"}
            )
            comparison_artifacts: dict[str, dict[str, str]] = {}
            for name, content in (
                ("count.compare.cmd", compare_text),
                ("count.compare.full.cmd", compare_text),
                ("count.compare.log", "count compare PASS\n"),
                ("capture.compare.cmd", compare_text),
                ("capture.compare.full.cmd", compare_text),
                ("capture.compare.log", "capture compare PASS\n"),
            ):
                path = unit / name
                path.write_text(content, encoding="utf-8")
                comparison_artifacts[name.replace(".", "_")] = {
                    "path": name,
                    "sha256": sha256(path),
                }
            unit_manifest = unit / "manifest.json"
            unit_data = {
                "schema": "l1d-qemu-capture-manifest-v2",
                "status": "PASS",
                "valid": True,
                "benchmark": "708.sqlite_r",
                "command_index": 0,
                "comparison": comparison,
                "toolchain": {
                    **fake_toolchain(),
                    "qemu_version": "QEMU emulator version 11.0.1",
                    "plugin_api": 6,
                    "target": "riscv64",
                    "system_emulation": True,
                    "smp_vcpus": 1,
                    "plugin_sha256": "1" * 64,
                },
                "command": {
                    "text": "fixture",
                    "sha256": command_sha(parsed_commands[0]),
                    "executable": "fixture.elf",
                    "path": "/guest/fixture.elf",
                    "elf_sha256": "3" * 64,
                },
                "guest_tools": {
                    "schema": "l1d-trace-roi-guest-tools-v1",
                    "source_sha256": "4" * 64,
                    "execution_policy": {
                        "address_space_randomization": "disabled-fail-closed"
                    },
                    "binaries": {
                        "libl1d_roi.so": "5" * 64,
                        "trace_exec": "6" * 64,
                    },
                },
                "roi": {
                    "count_matches_capture": True,
                    "violations": [],
                    "start_seen": True,
                    "stop_seen": True,
                    "vcpu": 0,
                    "priv": 0,
                    "marker_version": 2,
                    "satp": "0x8000000000012345",
                    "total_events": 12,
                    "count_pass_events": 12,
                    "capture_pass_events": 12,
                    "deterministic_counts": {
                        "total_events": 12,
                        "misaligned_events": 0,
                        "cross_line_events": 0,
                        "expanded_replay_accesses": 0,
                        "canonical_replay_accesses": 12,
                    },
                    "misaligned_source_events_count_pass": 0,
                    "misaligned_source_events_capture_pass": 0,
                    "cross_line_source_events_count_pass": 0,
                    "cross_line_source_events_capture_pass": 0,
                    "expanded_replay_accesses_count_pass": 0,
                    "expanded_replay_accesses_capture_pass": 0,
                    "canonical_replay_accesses_count_pass": 12,
                    "canonical_replay_accesses_capture_pass": 12,
                },
                "guest": {"kernel": "Linux-6.x-riscv64"},
                "artifacts": {
                    "raw": {"path": raw.name, "sha256": sha256(raw)},
                    **comparison_artifacts,
                },
                "windows": [
                    {
                        "index": 0,
                        "kind": "whole",
                        "warmup_events": 0,
                        "measure_events": 12,
                        "total_events": 12,
                        "replay": {
                            "path": f"replay/{replay.name}",
                            "sha256": sha256(replay),
                            "payload_lines": 12,
                        },
                    }
                ],
            }
            unit_manifest.write_text(
                json.dumps(unit_data, indent=2) + "\n", encoding="utf-8"
            )
            benchmark_plan = write_benchmark_plan(
                bench_dir, "708.sqlite_r", parsed_commands, [unit_manifest]
            )
            campaign = capture_root / "campaign_manifest.json"
            campaign.write_text(
                json.dumps(
                    {
                        "schema": "l1d-qemu-capture-campaign-v2",
                        "status": "PASS",
                        "valid": True,
                        "requested_benchmarks": ["708.sqlite_r"],
                        "expected_capture_units": 1,
                        "toolchain": unit_data["toolchain"],
                        "benchmark_plans": [
                            {
                                "benchmark": "708.sqlite_r",
                                "command_count": 1,
                                "path": str(benchmark_plan.relative_to(capture_root)),
                                "sha256": sha256(benchmark_plan),
                            }
                        ],
                        "captures": [
                            {
                                "benchmark": "708.sqlite_r",
                                "command_index": 0,
                                "manifest": str(unit_manifest.relative_to(capture_root)),
                                "sha256": sha256(unit_manifest),
                                "status": "PASS",
                            }
                        ],
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
            replay_root = root / "replay"
            (replay_root / "logs").mkdir(parents=True)
            completed = subprocess.run(
                [
                    str(REPO / "scripts" / "run_spec_trace_replay.sh"),
                    str(campaign),
                    str(replay_root / "logs"),
                ],
                cwd=root,
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            self.assertEqual(completed.returncode, 0, completed.stdout)
            generated = json.loads(
                (replay_root / "campaign_manifest.json").read_text(encoding="utf-8")
            )
            self.assertEqual(generated["schema"], "l1d-replay-campaign-v3")
            self.assertEqual(generated["replay_scope"], "full")
            self.assertEqual(generated["expected_runs"], 4)
            self.assertEqual(generated["expected_pairs"], 1)
            self.assertEqual(
                generated["standalone_config_ids"],
                ["dm_s8_vc4_pf0", "2w_s4_vc8_pf0"],
            )
            self.assertEqual(
                {path.stem for path in (replay_root / "bin").glob("*.vvp")},
                {
                    "dm_s8_vc4_pf0",
                    "2w_s4_vc4_pf0",
                    "2w_s4_vc8_pf0",
                    "2w_s4_vc4_pf1",
                },
            )
            self.assertEqual(len(generated["runs"]), 4)
            for run in generated["runs"]:
                self.assertEqual(run["prefetch_policy"], 1)
                self.assertEqual(run["pf_opt_level"], 3)
                self.assertEqual(run["producer_profile"], "zero-bubble")
                self.assertEqual(run["producer_gap"], 0)
                self.assertEqual(run["mem_latency"], 2)
                self.assertEqual(run["mem_ready_mode"], "periodic")
                self.assertEqual(run["mem_ready_mode_code"], 1)
                self.assertEqual(
                    run["timing_profile"],
                    "blocking-fixed-latency2-periodic-ready",
                )
                self.assertIn("+SIDECAR_SCHEMA=3", run["simulation_command"])
                self.assertIn("+PRODUCER_PROFILE=1", run["simulation_command"])
                self.assertIn("+MEM_LATENCY=2", run["simulation_command"])
                self.assertIn("+MEM_READY_MODE=1", run["simulation_command"])
            validation = json.loads(
                (replay_root / "analysis" / "validation.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(validation["status"], "PASS")
            self.assertEqual(validation["validated_runs"], 4)
            self.assertEqual(validation["validated_pairs"], 1)

            paired_root = root / "replay-paired"
            paired_logs = paired_root / "logs"
            paired_logs.mkdir(parents=True)
            paired_environment = os.environ.copy()
            paired_environment["L1D_REPLAY_SCOPE"] = "paired"
            paired_run = subprocess.run(
                [
                    str(REPO / "scripts" / "run_spec_trace_replay.sh"),
                    str(campaign),
                    str(paired_logs),
                ],
                cwd=root,
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                env=paired_environment,
            )
            self.assertEqual(paired_run.returncode, 0, paired_run.stdout)
            paired_manifest = json.loads(
                (paired_root / "campaign_manifest.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(paired_manifest["replay_scope"], "paired")
            self.assertEqual(paired_manifest["expected_runs"], 2)
            self.assertEqual(paired_manifest["actual_runs"], 2)
            self.assertEqual(paired_manifest["expected_pairs"], 1)
            self.assertEqual(
                paired_manifest["paired_config_ids"],
                ["2w_s4_vc4_pf0", "2w_s4_vc4_pf1"],
            )
            self.assertEqual(paired_manifest["standalone_config_ids"], [])
            self.assertEqual(
                {path.stem for path in (paired_root / "bin").glob("*.vvp")},
                {"2w_s4_vc4_pf0", "2w_s4_vc4_pf1"},
            )
            self.assertEqual(
                {run["config_id"] for run in paired_manifest["runs"]},
                {"2w_s4_vc4_pf0", "2w_s4_vc4_pf1"},
            )
            paired_validation = json.loads(
                (paired_root / "analysis" / "validation.json").read_text(
                    encoding="utf-8"
                )
            )
            self.assertEqual(paired_validation["status"], "PASS")
            self.assertEqual(paired_validation["validated_runs"], 2)
            self.assertEqual(paired_validation["validated_pairs"], 1)

            sensitivity_cases = (
                (0, "always-ready", 0, "blocking-fixed-latency0-always-ready"),
                (
                    8,
                    "deterministic-random",
                    2,
                    "blocking-fixed-latency8-deterministic-random-ready",
                ),
            )
            for latency, ready_mode, ready_mode_code, timing_profile in sensitivity_cases:
                with self.subTest(latency=latency, ready_mode=ready_mode):
                    sensitivity_root = root / f"replay-latency-{latency}"
                    sensitivity_logs = sensitivity_root / "logs"
                    sensitivity_logs.mkdir(parents=True)
                    environment = os.environ.copy()
                    environment.update(
                        {
                            "L1D_MEM_LATENCY": str(latency),
                            "L1D_MEM_READY_MODE": ready_mode,
                        }
                    )
                    sensitivity_run = subprocess.run(
                        [
                            str(REPO / "scripts" / "run_spec_trace_replay.sh"),
                            str(campaign),
                            str(sensitivity_logs),
                        ],
                        cwd=root,
                        check=False,
                        text=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                        env=environment,
                    )
                    self.assertEqual(
                        sensitivity_run.returncode, 0, sensitivity_run.stdout
                    )
                    sensitivity_manifest = json.loads(
                        (sensitivity_root / "campaign_manifest.json").read_text(
                            encoding="utf-8"
                        )
                    )
                    self.assertEqual(len(sensitivity_manifest["runs"]), 4)
                    for run in sensitivity_manifest["runs"]:
                        self.assertEqual(run["mem_latency"], latency)
                        self.assertEqual(run["mem_ready_mode"], ready_mode)
                        self.assertEqual(
                            run["mem_ready_mode_code"], ready_mode_code
                        )
                        self.assertEqual(run["timing_profile"], timing_profile)
                        self.assertIn(
                            f"+MEM_LATENCY={latency}", run["simulation_command"]
                        )
                        self.assertIn(
                            f"+MEM_READY_MODE={ready_mode_code}",
                            run["simulation_command"],
                        )

            wrapper_dir = root / "python-wrapper"
            wrapper_dir.mkdir()
            python_wrapper = wrapper_dir / "python3"
            python_wrapper.write_text(
                f"#!{sys.executable}\n"
                "import os\n"
                "import sys\n"
                "if any(arg.endswith('scripts/summarize_spec_replay.py') "
                "for arg in sys.argv[1:]):\n"
                "    raise SystemExit(77)\n"
                f"os.execv({sys.executable!r}, [{sys.executable!r}, *sys.argv[1:]])\n",
                encoding="utf-8",
            )
            python_wrapper.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = f"{wrapper_dir}{os.pathsep}{environment['PATH']}"
            failed = subprocess.run(
                [
                    str(REPO / "scripts" / "run_spec_trace_replay.sh"),
                    str(campaign),
                    str(replay_root / "logs"),
                ],
                cwd=root,
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                env=environment,
            )
            self.assertEqual(failed.returncode, 77, failed.stdout)
            self.assertFalse((replay_root / "campaign_manifest.json").exists())
            self.assertFalse((replay_root / "campaign_manifest.json.sha256").exists())
            self.assertFalse((replay_root / "analysis").exists())


if __name__ == "__main__":
    unittest.main()
