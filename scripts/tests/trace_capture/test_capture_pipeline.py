from __future__ import annotations

import json
import hashlib
import sys
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "scripts"))

from capture_spec_qemu_windows import (  # noqa: E402
    CaptureError,
    HOST_INPUT_PATHS,
    _valid_guest_tool_cache,
    command_sha,
    compare_cmd_sha,
    compute_windows,
    parse_compare_cmd,
    parse_trace_metadata,
    parse_speccmds,
    retain_failed_unit,
    validate_campaign_manifest,
    validate_comparison_evidence,
    write_benchmark_plan,
    write_campaign_manifest,
    write_invalid_manifest,
    wrap_speccmd,
)
from split_qemu_memtrace_windows import (  # noqa: E402
    TraceFormatError,
    parse_capture,
    raw_to_replay,
    sha256,
    split_v2_trace,
)


def valid_raw_trace() -> str:
    rows = [
        "10\t0\t0\t0x8000000000012345\t0x0000000000010000\tR\t8\t0x0000000040001000\t0x0000000081001000\t0x0000000081001007\n",
        "11\t0\t0\t0x8000000000012345\t0x0000000000010004\tW\t4\t0x0000000040001008\t0x0000000081001008\t0x000000008100100b\n",
        "20\t0\t0\t0x8000000000012345\t0x0000000000010008\tR\t1\t0x0000000040001010\t0x0000000081001010\t0x0000000081001010\n",
        "21\t0\t0\t0x8000000000012345\t0x000000000001000c\tW\t2\t0x0000000040001012\t0x0000000081001012\t0x0000000081001013\n",
    ]
    return "".join(
        [
            "# L1D_QEMU_MEMTRACE schema=3\n",
            "# columns seq vcpu priv satp pc op size vaddr paddr paddr_end\n",
            "# data_policy addresses=licensed-private store_data=redacted\n",
            "# context target=riscv64 plugin_api=6 system_emulation=1 smp_vcpus=1 max_vcpus=1 mode=capture expected_nonce=0x55 command=0 expected_total=30\n",
            "# window_config index=0 start=10 count=2 warmup=1 measure=1 label=q10\n",
            "# window_config index=1 start=20 count=2 warmup=0 measure=2 label=q30\n",
            "# registers status=PASS a0=a0 a1=a1 a2=a2 a3=a3 a4=a4 a5=a5 priv=priv satp=satp\n",
            "# roi_start nonce=0x55 command=0 vcpu=0 priv=0 satp=0x8000000000012345 pid=10 tid=10\n",
            "# window index=0 start=10 count=2 warmup=1 measure=1 label=q10\n",
            rows[0],
            rows[1],
            "# window index=1 start=20 count=2 warmup=0 measure=2 label=q30\n",
            rows[2],
            rows[3],
            "# roi_stop nonce=0x55 command=0 vcpu=0 priv=0 satp=0x8000000000012345 pid=10 tid=10 total_events=30\n",
            "# summary status=PASS reason=qemu_exit mode=capture total_events=30 captured_rows=4 expected_total=30 count_matches_capture=1 start_seen=1 stop_seen=1 vcpu=0 priv=0 satp=0x8000000000012345 pid=10 tid=10 command=0 nonce=0x55 filtered_non_u=12 filtered_foreign_satp=3 misaligned_events=0 cross_line_events=0 expanded_replay_accesses=0 canonical_replay_accesses=30 captured_canonical_replay_accesses=4 register_read_failures=0 violations=0 first_violation=none\n",
            "# window_summary index=0 start=10 count=2 warmup=1 measure=1 label=q10 captured=2 misaligned=0 cross_line=0 canonical_accesses=2 status=PASS\n",
            "# window_summary index=1 start=20 count=2 warmup=0 measure=2 label=q30 captured=2 misaligned=0 cross_line=0 canonical_accesses=2 status=PASS\n",
        ]
    )


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


def make_benchmark_plan_fixture(
    root: Path, selections: list[set[str]]
) -> tuple[Path, list[object], list[Path]]:
    bench_dir = root / "fixture_bench"
    bench_dir.mkdir(parents=True)
    speccmds = bench_dir / "speccmds.original.cmd"
    speccmds.write_text(
        "-C /spec/run\n"
        "-o out0 -e err0 ../fixture0 > out0 2>> err0\n"
        "-o out1 -e err1 ../fixture1 > out1 2>> err1\n",
        encoding="utf-8",
    )
    commands = parse_speccmds(speccmds.read_text(encoding="utf-8"))
    full_text = (
        "-C /spec/run\n"
        "-k -o out0.cmp specdiff /ref/out0 out0 > out0.cmp\n"
        "-k -o out1.cmp specdiff /ref/out1 out1 > out1.cmp\n"
        "-k -o side.cmp specdiff /ref/side side > side.cmp\n"
    )
    compare_plan = parse_compare_cmd(full_text, run_dir="/spec/run")
    manifests: list[Path] = []
    for index, selection in enumerate(selections):
        unit_dir = bench_dir / f"cmd{index:03d}"
        unit_dir.mkdir()
        comparison = compare_plan.evidence(selection)
        comparison.update(
            {"count_pass_status": "PASS", "capture_pass_status": "PASS"}
        )
        artifacts: dict[str, dict[str, str]] = {}
        for name, content in (
            ("count.compare.cmd", comparison["text"]),
            ("count.compare.full.cmd", full_text),
            ("count.compare.log", "PASS\n"),
            ("capture.compare.cmd", comparison["text"]),
            ("capture.compare.full.cmd", full_text),
            ("capture.compare.log", "PASS\n"),
        ):
            artifact_path = unit_dir / name
            artifact_path.write_text(content, encoding="utf-8")
            artifacts[name.replace(".", "_")] = {
                "path": name,
                "sha256": sha256(artifact_path),
            }
        manifest_path = unit_dir / "manifest.json"
        manifest_path.write_text(
            json.dumps(
                {
                    "schema": "l1d-qemu-capture-manifest-v2",
                    "status": "PASS",
                    "valid": True,
                    "benchmark": "fixture",
                    "command_index": index,
                    "command": {"sha256": command_sha(commands[index])},
                    "comparison": comparison,
                    "artifacts": artifacts,
                }
            ),
            encoding="utf-8",
        )
        manifests.append(manifest_path)
    return bench_dir, commands, manifests


class SpeccmdTests(unittest.TestCase):
    def test_parse_and_wrap_one_command(self) -> None:
        commands = parse_speccmds(
            "# generated\n-E LANG C\n-r\n-N C\n-C run\n"
            "-i in.txt -o out.txt -e err.txt ../bench --flag value > out.txt 2>> err.txt\n"
        )
        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0].working_directory, "run")
        self.assertEqual(commands[0].executable, "../bench")
        wrapped = wrap_speccmd(
            commands[0], nonce=0x55, shim="/tmp/shim.so", trace_exec="/tmp/trace_exec"
        )
        self.assertIn("/tmp/trace_exec --shim /tmp/shim.so --nonce 0x0000000000000055", wrapped)
        self.assertIn("-E LANG C\n-r\n-N C\n-C run\n", wrapped)
        self.assertTrue(
            wrapped.rstrip().endswith("-- ../bench --flag value > out.txt 2>> err.txt")
        )

    def test_unknown_specinvoke_option_is_rejected(self) -> None:
        with self.assertRaises(CaptureError):
            parse_speccmds("-Z mystery ../bench\n")

    def test_compare_subset_tracks_all_outputs_produced_by_one_command(self) -> None:
        text = (
            "-E LANG C\n"
            "-r\n"
            "-N C\n"
            "-C /spec/run\n"
            "-k -o first.cmp specdiff /ref/first.out first.out > first.cmp\n"
            "-k -o second.cmp specdiff /ref/second.out second.out > second.cmp\n"
            "-k -o side.cmp specdiff /ref/side.dat side.dat > side.cmp\n"
        )
        plan = parse_compare_cmd(text, run_dir="/spec/run")
        selected = plan.select({"/spec/run/first.out", "/spec/run/side.dat"})
        self.assertIn("first.out > first.cmp", selected)
        self.assertNotIn("second.out > second.cmp", selected)
        self.assertIn("side.dat > side.cmp", selected)
        self.assertTrue(selected.startswith("-E LANG C\n-r\n-N C\n-C /spec/run\n"))

    def test_compare_output_escape_is_rejected(self) -> None:
        with self.assertRaises(CaptureError):
            parse_compare_cmd(
                "-C /spec/run\n-k -o bad.cmp specdiff /ref/out ../out > bad.cmp\n",
                run_dir="/spec/run",
            )


class WindowTests(unittest.TestCase):
    def test_short_roi_is_whole_measurement(self) -> None:
        windows = compute_windows(12_345)
        self.assertEqual(
            (windows[0].start, windows[0].warmup, windows[0].measure, windows[0].label),
            (0, 0, 12_345, "whole"),
        )

    def test_minimum_sampled_roi_has_five_ten_k_windows(self) -> None:
        windows = compute_windows(50_000)
        self.assertEqual([window.start for window in windows], [0, 10_000, 20_000, 30_000, 40_000])
        self.assertTrue(all(window.warmup == 5_000 and window.measure == 5_000 for window in windows))

    def test_zero_event_roi_is_invalid(self) -> None:
        with self.assertRaises(CaptureError):
            compute_windows(0)


class SplitterTests(unittest.TestCase):
    def test_split_preserves_header_and_marks_phases(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = root / "capture.raw.tsv"
            raw.write_text(valid_raw_trace(), encoding="utf-8")
            windows = split_v2_trace(raw, root / "replay", "fixture")
            self.assertEqual(len(windows), 2)
            first = Path(windows[0]["replay"]["path"])
            text = first.read_text(encoding="utf-8")
            self.assertIn("# L1D_QEMU_MEMTRACE schema=3", text)
            self.assertIn("# roi_start nonce=0x55", text)
            self.assertIn("# PHASE warmup\n0 3 1 0000000081001000", text)
            self.assertIn("# PHASE measure\n1 2 0 0000000081001008 00000000", text)
            self.assertEqual(windows[0]["replay"]["payload_lines"], 2)

    def test_same_line_misaligned_becomes_one_byte_line_touch(self) -> None:
        row = (
            "7\t0\t0\t0x8001\t0x100\tR\t4\t0x1003\t0x8003\t0x8006\n"
        )
        self.assertEqual(
            raw_to_replay(row, expected_seq=7),
            ["0 0 1 0000000000008000\n"],
        )

    def test_cross_line_misaligned_becomes_two_real_pa_touches(self) -> None:
        row = (
            "8\t0\t0\t0x8001\t0x104\tR\t2\t0x100f\t0x900f\t0xa000\n"
        )
        self.assertEqual(
            raw_to_replay(row, expected_seq=8),
            [
                "0 0 1 0000000000009000\n",
                "0 0 1 000000000000a000\n",
            ],
        )

    def test_bad_sequence_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            raw = Path(temporary) / "bad.raw.tsv"
            raw.write_text(valid_raw_trace().replace("10\t0\t0", "9\t0\t0", 1), encoding="utf-8")
            with self.assertRaises(TraceFormatError):
                parse_capture(raw)


class EvidenceTests(unittest.TestCase):
    def test_benchmark_plan_rejects_missing_compare_command(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bench_dir, commands, manifests = make_benchmark_plan_fixture(
                root, [{"/spec/run/out0"}, {"/spec/run/out1"}]
            )
            with self.assertRaises(CaptureError):
                write_benchmark_plan(bench_dir, "fixture", commands, manifests)

    def test_benchmark_plan_rejects_overlapping_compare_command(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bench_dir, commands, manifests = make_benchmark_plan_fixture(
                root,
                [
                    {"/spec/run/out0", "/spec/run/side"},
                    {"/spec/run/out1", "/spec/run/side"},
                ],
            )
            with self.assertRaises(CaptureError):
                write_benchmark_plan(bench_dir, "fixture", commands, manifests)

    def test_benchmark_plan_rejects_non_dense_command_units(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bench_dir, commands, manifests = make_benchmark_plan_fixture(
                root,
                [
                    {"/spec/run/out0", "/spec/run/side"},
                    {"/spec/run/out1"},
                ],
            )
            second = json.loads(manifests[1].read_text(encoding="utf-8"))
            second["command_index"] = 2
            manifests[1].write_text(json.dumps(second), encoding="utf-8")
            with self.assertRaises(CaptureError):
                write_benchmark_plan(bench_dir, "fixture", commands, manifests)

    def test_invalid_campaign_graph_never_publishes_pass_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bench_dir, commands, manifests = make_benchmark_plan_fixture(
                root,
                [
                    {"/spec/run/out0", "/spec/run/side"},
                    {"/spec/run/out1"},
                ],
            )
            benchmark_plan = write_benchmark_plan(
                bench_dir, "fixture", commands, manifests
            )
            with self.assertRaises(CaptureError):
                write_campaign_manifest(
                    root,
                    manifests,
                    [benchmark_plan],
                    ["fixture"],
                    fake_toolchain(),
                )
            published = json.loads(
                (root / "campaign_manifest.json").read_text(encoding="utf-8")
            )
            self.assertEqual(published["status"], "INVALID")
            self.assertFalse(published["valid"])
            self.assertFalse((root / "campaign_manifest.json.tmp").exists())
            self.assertFalse((root / "campaign_manifest.md").exists())

    def test_failed_unit_retains_hashed_diagnostics_but_removes_replays(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            staging = root / ".cmd000.tmp"
            final = root / "cmd000"
            (staging / "replay").mkdir(parents=True)
            (staging / "capture.raw.tsv").write_text("invalid raw\n", encoding="utf-8")
            (staging / "capture.qemu.log").write_text("diagnostic\n", encoding="utf-8")
            (staging / "replay" / "stale.trace").write_text("stale\n", encoding="utf-8")
            retain_failed_unit(staging, final)
            write_invalid_manifest(
                final / "manifest.json",
                bench="fixture",
                command_index=0,
                error=CaptureError("count mismatch"),
            )
            manifest = json.loads((final / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["status"], "INVALID")
            self.assertFalse(list(final.rglob("*.trace")))
            self.assertEqual(
                {item["path"] for item in manifest["failure_artifacts"]},
                {"capture.qemu.log", "capture.raw.tsv"},
            )

    def test_comparison_evidence_requires_two_passes_and_matching_content(self) -> None:
        text = "-E LANG C\n-C /spec/run\n-k -o out.cmp specdiff /ref/out out > out.cmp\n"
        plan = parse_compare_cmd(text, run_dir="/spec/run")
        comparison = plan.evidence({"/spec/run/out"})
        comparison.update(
            {"count_pass_status": "PASS", "capture_pass_status": "PASS"}
        )
        digest = comparison["sha256"]
        full_digest = comparison["full_plan"]["sha256"]
        artifacts = {
            "count_compare_cmd": {"sha256": digest},
            "count_compare_full_cmd": {"sha256": full_digest},
            "count_compare_log": {"sha256": "1" * 64},
            "capture_compare_cmd": {"sha256": digest},
            "capture_compare_full_cmd": {"sha256": full_digest},
            "capture_compare_log": {"sha256": "2" * 64},
        }
        validate_comparison_evidence(comparison, artifacts)

        bad = dict(comparison, capture_pass_status="INVALID")
        with self.assertRaises(CaptureError):
            validate_comparison_evidence(bad, artifacts)
        bad = dict(comparison, text=text + "# changed\n")
        with self.assertRaises(CaptureError):
            validate_comparison_evidence(bad, artifacts)

        two_command_text = text + "-k -o side.cmp specdiff /ref/side side > side.cmp\n"
        two_command_plan = parse_compare_cmd(two_command_text, run_dir="/spec/run")
        tampered = two_command_plan.evidence({"/spec/run/out"})
        tampered["full_plan"]["commands"] = tampered["full_plan"]["commands"][:1]
        tampered.update(
            {"count_pass_status": "PASS", "capture_pass_status": "PASS"}
        )
        tampered_artifacts = dict(artifacts)
        tampered_artifacts["count_compare_full_cmd"] = {
            "sha256": tampered["full_plan"]["sha256"]
        }
        tampered_artifacts["capture_compare_full_cmd"] = {
            "sha256": tampered["full_plan"]["sha256"]
        }
        with self.assertRaises(CaptureError):
            validate_comparison_evidence(tampered, tampered_artifacts)

    def test_guest_tool_cache_hash_rejects_stale_binary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            cache = Path(temporary)
            (cache / "libl1d_roi.so").write_bytes(b"shim")
            (cache / "trace_exec").write_bytes(b"exec")
            source_hash = "a" * 64
            manifest = {
                "source_sha256": source_hash,
                "execution_policy": {
                    "address_space_randomization": "disabled-fail-closed"
                },
                "binaries": {
                    "libl1d_roi.so": sha256(cache / "libl1d_roi.so"),
                    "trace_exec": sha256(cache / "trace_exec"),
                },
            }
            (cache / "cache_manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            self.assertTrue(_valid_guest_tool_cache(cache, source_hash))
            (cache / "trace_exec").write_bytes(b"stale")
            self.assertFalse(_valid_guest_tool_cache(cache, source_hash))

    def test_campaign_validator_rejects_extra_stale_replay(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bench_dir = root / "bench"
            unit_dir = bench_dir / "cmd000"
            unit_dir.mkdir(parents=True)
            speccmds_path = bench_dir / "speccmds.original.cmd"
            speccmds_path.write_text(
                "-C /spec/run\n-o out -e err ../fixture > out 2>> err\n",
                encoding="utf-8",
            )
            commands = parse_speccmds(speccmds_path.read_text(encoding="utf-8"))
            raw = unit_dir / "capture.raw.tsv"
            raw.write_text(valid_raw_trace(), encoding="utf-8")
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
                ("count.compare.log", "compare count PASS\n"),
                ("capture.compare.cmd", compare_text),
                ("capture.compare.full.cmd", compare_text),
                ("capture.compare.log", "compare capture PASS\n"),
            ):
                path = unit_dir / name
                path.write_text(content, encoding="utf-8")
                comparison_artifacts[name.replace(".", "_")] = {
                    "path": name,
                    "sha256": sha256(path),
                }
            windows = split_v2_trace(raw, unit_dir / "replay", "fixture")
            for window in windows:
                replay_path = Path(window["replay"]["path"])
                window["replay"]["path"] = str(replay_path.relative_to(unit_dir))
            unit = {
                "schema": "l1d-qemu-capture-manifest-v2",
                "status": "PASS",
                "valid": True,
                "benchmark": "fixture",
                "command_index": 0,
                "command": {"sha256": command_sha(commands[0])},
                "comparison": comparison,
                "toolchain": fake_toolchain(),
                "roi": {
                    "count_matches_capture": True,
                    "total_events": 30,
                    "count_pass_events": 30,
                    "capture_pass_events": 30,
                    "deterministic_counts": {
                        "total_events": 30,
                        "misaligned_events": 0,
                        "cross_line_events": 0,
                        "expanded_replay_accesses": 0,
                        "canonical_replay_accesses": 30,
                    },
                    "misaligned_source_events_count_pass": 0,
                    "misaligned_source_events_capture_pass": 0,
                    "cross_line_source_events_count_pass": 0,
                    "cross_line_source_events_capture_pass": 0,
                    "expanded_replay_accesses_count_pass": 0,
                    "expanded_replay_accesses_capture_pass": 0,
                    "canonical_replay_accesses_count_pass": 30,
                    "canonical_replay_accesses_capture_pass": 30,
                    "filtered_foreign_satp_count_pass": 7,
                    "filtered_foreign_satp_capture_pass": 9,
                    "violations": [],
                },
                "guest_tools": {
                    "execution_policy": {
                        "address_space_randomization": "disabled-fail-closed"
                    }
                },
                "artifacts": {
                    "raw": {
                        "path": str(raw.relative_to(unit_dir)),
                        "sha256": sha256(raw),
                    },
                    **comparison_artifacts,
                },
                "windows": windows,
            }
            unit_manifest = unit_dir / "manifest.json"
            unit_manifest.write_text(json.dumps(unit), encoding="utf-8")
            benchmark_plan = write_benchmark_plan(
                bench_dir, "fixture", commands, [unit_manifest]
            )
            campaign = {
                "schema": "l1d-qemu-capture-campaign-v2",
                "status": "PASS",
                "valid": True,
                "requested_benchmarks": ["fixture"],
                "expected_capture_units": 1,
                "toolchain": unit["toolchain"],
                "benchmark_plans": [
                    {
                        "benchmark": "fixture",
                        "command_count": 1,
                        "path": str(benchmark_plan.relative_to(root)),
                        "sha256": sha256(benchmark_plan),
                    }
                ],
                "captures": [
                    {
                        "benchmark": "fixture",
                        "command_index": 0,
                        "manifest": str(unit_manifest.relative_to(root)),
                        "sha256": sha256(unit_manifest),
                        "status": "PASS",
                    }
                ],
            }
            campaign_path = root / "campaign_manifest.json"
            campaign_path.write_text(json.dumps(campaign), encoding="utf-8")
            replay_list = validate_campaign_manifest(campaign_path)
            self.assertEqual(replay_list["replay_count"], 2)
            self.assertEqual(replay_list["replays"][0]["warmup_events"], 1)
            self.assertEqual(replay_list["replays"][0]["measure_events"], 1)

            saved_comparison = unit.pop("comparison")
            unit_manifest.write_text(json.dumps(unit), encoding="utf-8")
            campaign["captures"][0]["sha256"] = sha256(unit_manifest)
            campaign_path.write_text(json.dumps(campaign), encoding="utf-8")
            with self.assertRaises(CaptureError):
                validate_campaign_manifest(campaign_path)
            unit["comparison"] = saved_comparison
            unit_manifest.write_text(json.dumps(unit), encoding="utf-8")
            benchmark_plan = write_benchmark_plan(
                bench_dir, "fixture", commands, [unit_manifest]
            )
            campaign["captures"][0]["sha256"] = sha256(unit_manifest)
            campaign["benchmark_plans"][0]["sha256"] = sha256(benchmark_plan)
            campaign_path.write_text(json.dumps(campaign), encoding="utf-8")

            (root / "stale.trace").write_text("# stale\n", encoding="utf-8")
            with self.assertRaises(CaptureError):
                validate_campaign_manifest(campaign_path)

    def test_invalid_summary_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            raw = Path(temporary) / "bad.raw.tsv"
            raw.write_text(valid_raw_trace().replace("status=PASS reason", "status=INVALID reason"), encoding="utf-8")
            with self.assertRaises(TraceFormatError):
                parse_capture(raw)

    def test_capture_metadata_rejects_context_roi_identity_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            raw = Path(temporary) / "bad-identity.raw.tsv"
            raw.write_text(
                valid_raw_trace().replace("command=0 expected_total", "command=1 expected_total"),
                encoding="utf-8",
            )
            with self.assertRaises(CaptureError):
                parse_trace_metadata(raw, expected_mode="capture")


if __name__ == "__main__":
    unittest.main()
