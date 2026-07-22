from __future__ import annotations

import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts.summarize_spec_replay import (
    INT_RESULT_FIELDS,
    V3_LIFECYCLE_COUNTER_FIELDS,
    ValidationError,
    aggregate_pairs,
    analyze_campaign,
    analyze_trace,
    load_campaign,
    main as summarize_main,
    parse_sidecar,
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class SidecarPrefetchIdentityTests(unittest.TestCase):
    def _rows(self) -> list[str]:
        demand = [
            "schema=3 event=demand_present seq=0 cycle=0 addr=0x0 op=load size=3 outcome=pending latency=-1 details=-",
            "schema=3 event=demand_accept seq=0 cycle=1 addr=0x0 op=load size=3 outcome=pending latency=0 details=-",
            "schema=3 event=demand_response seq=0 cycle=4 addr=0x0 op=load size=3 outcome=lower_memory latency=3 details=-",
        ]
        details = "source:0,stream_id:2,generation:1,confidence:3"
        prefetch = [
            f"schema=3 event=prefetch_candidate seq=7 cycle=0 addr=0x1000 op=prefetch size=16 outcome=queued latency=-1 details={details}",
            f"schema=3 event=prefetch_admit seq=7 cycle=1 addr=0x1000 op=prefetch size=16 outcome=admitted latency=1 details={details}",
            f"schema=3 event=prefetch_issue seq=7 cycle=2 addr=0x1000 op=prefetch size=16 outcome=lower_memory latency=2 details={details}",
            f"schema=3 event=prefetch_return seq=7 cycle=5 addr=0x1000 op=prefetch size=16 outcome=returned latency=3 details={details}",
            f"schema=3 event=prefetch_install seq=7 cycle=6 addr=0x1000 op=prefetch size=16 outcome=l1_hit latency=4 details={details}",
            f"schema=3 event=prefetch_use seq=7 cycle=9 addr=0x1000 op=prefetch size=16 outcome=timely_use latency=3 details={details}",
        ]
        return demand + prefetch

    def test_identified_prefetch_lifecycle_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "sidecar.tsv"
            path.write_text("\n".join(self._rows()) + "\n", encoding="utf-8")
            accesses, counts = parse_sidecar(path, line_bytes=16)
            self.assertEqual(len(accesses), 1)
            self.assertEqual(counts["prefetch_issue"], 1)

    def test_identified_prefetch_address_change_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "sidecar.tsv"
            rows = self._rows()
            rows[6] = rows[6].replace("addr=0x1000", "addr=0x1010")
            path.write_text("\n".join(rows) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(ValidationError, "lifecycle addresses differ"):
                parse_sidecar(path, line_bytes=16)

    def test_identified_prefetch_return_requires_terminal_outcome(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "sidecar.tsv"
            rows = self._rows()[:-2]
            path.write_text("\n".join(rows) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(ValidationError, "lacks one install/merge/discard"):
                parse_sidecar(path, line_bytes=16)


class CampaignFixture:
    def __init__(self, root: Path, *, all_hits: bool = False) -> None:
        self.root = root
        self.trace = root / "window.trace"
        self.trace.write_text(
            "# PHASE warmup\n"
            "0 3 0 0000000000000100\n"
            "# PHASE measure\n"
            "0 3 0 0000000000000000\n"
            "0 3 0 0000000000000010\n"
            "0 3 0 0000000000000020\n"
            "0 3 0 0000000000000030\n",
            encoding="utf-8",
        )
        self.off_log = root / "off.log"
        self.on_log = root / "on.log"
        self.off_sidecar = root / "off.tsv"
        self.on_sidecar = root / "on.tsv"
        self.manifest = root / "campaign.json"
        self.capture_campaign = root / "capture-campaign.json"
        self.capture_replay_list = root / "capture-replay-list.json"
        self.simulator = root / "vvp"
        self.sim_binary = root / "cache.vvp"
        self.capture_campaign.write_text("{}\n", encoding="utf-8")
        self.capture_replay_list.write_text("{}\n", encoding="utf-8")
        self.simulator.write_bytes(b"fixture simulator\n")
        self.sim_binary.write_bytes(b"fixture compiled simulation\n")

        if all_hits:
            self.off = self._counters(
                accesses=4,
                hits=4,
                misses=0,
                victim_hits=0,
                demand_mem_reads=0,
                mem_reads=0,
                read_bytes=0,
                replay_service_cycles=8,
            )
            self.on = self._counters(
                accesses=4,
                hits=4,
                misses=0,
                victim_hits=0,
                demand_mem_reads=0,
                mem_reads=0,
                read_bytes=0,
                replay_service_cycles=8,
                prefetch=1,
            )
            off_outcomes = ["l1_hit"] * 4
            on_outcomes = ["l1_hit"] * 4
        else:
            self.off = self._counters(
                accesses=4,
                hits=1,
                misses=3,
                victim_hits=1,
                demand_mem_reads=2,
                mem_reads=2,
                read_bytes=32,
                replay_service_cycles=40,
            )
            self.on = self._counters(
                accesses=4,
                hits=2,
                misses=2,
                victim_hits=1,
                demand_mem_reads=1,
                prefetch_mem_reads=3,
                mem_reads=4,
                read_bytes=64,
                fills=3,
                useful=2,
                unused_resident=1,
                timely_useful=1,
                late_useful=1,
                replay_service_cycles=35,
                prefetch=1,
            )
            # L1: 2 help, 1 pollution => miss delta -1.
            # Lower: 2 help, 1 pollution => demand-read delta -1.
            off_outcomes = ["l1_hit", "lower_memory", "victim_hit", "lower_memory"]
            on_outcomes = ["lower_memory", "l1_hit", "l1_hit", "victim_hit"]

        self._write_log(self.off_log, "pf0", self.off)
        self._write_log(self.on_log, "pf1", self.on)
        self._write_sidecar(self.off_sidecar, off_outcomes)
        self._write_sidecar(
            self.on_sidecar,
            on_outcomes,
            prefetch_issues=self.on["prefetch_mem_reads"],
            prefetch_fills=self.on["fills"],
        )
        self.data = {
            "schema": "l1d-replay-campaign-v2",
            "expected_runs": 2,
            "expected_pairs": 1,
            "actual_runs": 2,
            "actual_pairs": 1,
            "require_sidecars": True,
            "require_capture_manifests": False,
            "paired_config_ids": ["pf0", "pf1"],
            "standalone_config_ids": [],
            "status": "PASS",
            "artifact_hashes": True,
            "capture_campaign": {
                "path": self.capture_campaign.name,
                "sha256": sha256(self.capture_campaign),
            },
            "capture_replay_list": {
                "path": self.capture_replay_list.name,
                "sha256": sha256(self.capture_replay_list),
            },
            "runs": [self._run(0), self._run(1)],
        }
        self.write_manifest()
        self.attach_capture_manifest()

    @staticmethod
    def _counters(**overrides: int) -> dict[str, int]:
        values = {field: 0 for field in INT_RESULT_FIELDS}
        values.update(
            {
                "schema": 2,
                "sets": 4,
                "ways": 2,
                "line_bytes": 16,
                "l1_bytes": 128,
                "victim_entries": 4,
                "victim_bytes": 64,
                "total_bytes": 192,
            }
        )
        values.update(overrides)
        return values

    @staticmethod
    def _write_log(path: Path, config_id: str, counters: dict[str, int]) -> None:
        fields = ["schema=2", f"config_id={config_id}", "trace_id=trace-c0-w0"]
        fields.extend(f"{field}={counters[field]}" for field in INT_RESULT_FIELDS if field != "schema")
        fields.append("status=PASS")
        path.write_text("WORKLOAD_RESULT " + " ".join(fields) + "\n", encoding="utf-8")

    @staticmethod
    def _write_sidecar(
        path: Path,
        outcomes: list[str],
        *,
        prefetch_issues: int = 0,
        prefetch_fills: int = 0,
    ) -> None:
        addresses = (0x0, 0x10, 0x20, 0x30)
        rows = []
        for seq, (addr, outcome) in enumerate(zip(addresses, outcomes)):
            rows.append(
                f"schema=2 event=demand seq={seq} cycle={seq * 4} "
                f"addr=0x{addr:x} op=load size=3 outcome={outcome} details=-"
            )
        for index in range(prefetch_issues):
            rows.append(
                "schema=2 event=prefetch_issue seq=-1 "
                f"cycle={100 + index} addr=0x{0x1000 + index * 16:x} "
                "op=prefetch size=16 outcome=lower_memory details=-"
            )
        for index in range(prefetch_fills):
            rows.append(
                "schema=2 event=prefetch_fill seq=-1 "
                f"cycle={200 + index} addr=0x{0x1000 + index * 16:x} "
                "op=prefetch size=16 outcome=l1_hit details=-"
            )
        path.write_text("\n".join(rows) + "\n", encoding="utf-8")

    @staticmethod
    def _write_v3_sidecar(
        path: Path,
        outcomes: list[str],
        *,
        prefetch_issues: int = 0,
        prefetch_fills: int = 0,
    ) -> None:
        addresses = (0x0, 0x10, 0x20, 0x30)
        rows = []
        for seq, (addr, outcome) in enumerate(zip(addresses, outcomes)):
            present = seq * 10
            accept = present + 1
            response = accept + 3
            common = f"seq={seq} addr=0x{addr:x} op=load size=3"
            rows.extend(
                [
                    f"schema=3 event=demand_present {common} cycle={present} "
                    "outcome=pending latency=-1 details=-",
                    f"schema=3 event=demand_accept {common} cycle={accept} "
                    "outcome=pending latency=0 details=-",
                    f"schema=3 event=demand_response {common} cycle={response} "
                    f"outcome={outcome} latency=3 details=-",
                ]
            )
        for index in range(prefetch_issues):
            rows.append(
                "schema=3 event=prefetch_issue seq=-1 "
                f"cycle={100 + index} addr=0x{0x1000 + index * 16:x} "
                "op=prefetch size=16 outcome=lower_memory latency=-1 details=-"
            )
        for index in range(prefetch_fills):
            rows.append(
                "schema=3 event=prefetch_fill seq=-1 "
                f"cycle={200 + index} addr=0x{0x1000 + index * 16:x} "
                "op=prefetch size=16 outcome=l1_hit latency=-1 details=-"
            )
        path.write_text("\n".join(rows) + "\n", encoding="utf-8")

    def _run(self, prefetch: int) -> dict[str, object]:
        sidecar = self.off_sidecar if prefetch == 0 else self.on_sidecar
        command = [
            str(self.simulator.resolve()),
            str(self.sim_binary.resolve()),
            f"+CONFIG_ID=pf{prefetch}",
            "+TRACE_ID=trace-c0-w0",
            "+TRACE_SKIP_LOAD_CHECKS",
            f"+TRACE={self.trace.name}",
            f"+ACCESS_SIDECAR={sidecar.name}",
        ]
        return {
            "benchmark": "708.sqlite_r",
            "command": 0,
            "window": 0,
            "config_id": f"pf{prefetch}",
            "trace_id": "trace-c0-w0",
            "trace": {"path": self.trace.name, "sha256": sha256(self.trace)},
            "log": {
                "path": (self.off_log if prefetch == 0 else self.on_log).name,
                "sha256": sha256(self.off_log if prefetch == 0 else self.on_log),
            },
            "sidecar": {
                "path": sidecar.name,
                "sha256": sha256(sidecar),
            },
            "simulation_binary": {
                "path": self.sim_binary.name,
                "sha256": sha256(self.sim_binary),
            },
            "simulator": {
                "path": self.simulator.name,
                "sha256": sha256(self.simulator),
            },
            "simulation_command": command,
            "simulation_command_sha256": hashlib.sha256(
                json.dumps(
                    command, separators=(",", ":"), ensure_ascii=False
                ).encode("utf-8")
            ).hexdigest(),
            "simulation_cwd": str(self.root.resolve()),
            "sets": 4,
            "ways": 2,
            "line_bytes": 16,
            "victim_entries": 4,
            "prefetch": prefetch,
            "timing_profile": "fixed-10",
            "cold_warm_mode": "demand-warm-measure",
        }

    @staticmethod
    def refresh_command_hash(run: dict[str, object]) -> None:
        command = run["simulation_command"]
        assert isinstance(command, list)
        run["simulation_command_sha256"] = hashlib.sha256(
            json.dumps(
                command, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
        ).hexdigest()

    def write_manifest(self) -> None:
        self.manifest.write_text(json.dumps(self.data), encoding="utf-8")

    def refresh_artifact_hashes(self) -> None:
        for run in self.data["runs"]:
            for field in ("trace", "log", "sidecar", "capture_manifest"):
                artifact = run.get(field)
                if isinstance(artifact, dict):
                    artifact["sha256"] = sha256(self.root / str(artifact["path"]))
        capture_campaign = json.loads(
            self.capture_campaign.read_text(encoding="utf-8")
        )
        if capture_campaign.get("captures"):
            for capture in capture_campaign["captures"]:
                capture["sha256"] = sha256(self.root / capture["manifest"])
            self.capture_campaign.write_text(
                json.dumps(capture_campaign), encoding="utf-8"
            )
        replay_list = json.loads(self.capture_replay_list.read_text(encoding="utf-8"))
        if replay_list.get("schema") == "l1d-qemu-replay-list-v2":
            replay_list["campaign_sha256"] = sha256(self.capture_campaign)
            self.capture_replay_list.write_text(
                json.dumps(replay_list), encoding="utf-8"
            )
        self.data["capture_campaign"]["sha256"] = sha256(self.capture_campaign)
        self.data["capture_replay_list"]["sha256"] = sha256(
            self.capture_replay_list
        )

    def attach_capture_manifest(self) -> Path:
        evidence = self.root / "capture.raw.tsv"
        evidence.write_text("fixture capture evidence\n", encoding="utf-8")
        capture = self.root / "capture-manifest.json"
        data = {
            "schema": "l1d-qemu-capture-manifest-v2",
            "status": "PASS",
            "valid": True,
            "benchmark": "708.sqlite_r",
            "command_index": 0,
            "toolchain": {
                "qemu_version": "QEMU emulator version 11.0.1",
                "plugin_api": 6,
                "target": "riscv64",
                "system_emulation": True,
                "smp_vcpus": 1,
                "plugin_sha256": "1" * 64,
            },
            "command": {
                "text": "fixture",
                "sha256": "2" * 64,
                "executable": "fixture.elf",
                "path": "/guest/fixture.elf",
                "elf_sha256": "3" * 64,
            },
            "guest_tools": {
                "schema": "l1d-trace-roi-guest-tools-v1",
                "source_sha256": "4" * 64,
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
                "total_events": 5,
                "count_pass_events": 5,
                "capture_pass_events": 5,
            },
            "guest": {"kernel": "Linux-6.x-riscv64"},
            "artifacts": {
                "raw": {"path": evidence.name, "sha256": sha256(evidence)}
            },
            "windows": [
                {
                    "index": 0,
                    "kind": "sampled",
                    "warmup_events": 1,
                    "measure_events": 4,
                    "total_events": 5,
                    "replay": {
                        "path": self.trace.name,
                        "sha256": sha256(self.trace),
                        "payload_lines": 5,
                    },
                }
            ],
        }
        capture.write_text(json.dumps(data), encoding="utf-8")
        self.capture_campaign.write_text(
            json.dumps(
                {
                    "schema": "l1d-qemu-capture-campaign-v2",
                    "status": "PASS",
                    "valid": True,
                    "requested_benchmarks": ["708.sqlite_r"],
                    "expected_capture_units": 1,
                    "captures": [
                        {
                            "benchmark": "708.sqlite_r",
                            "command_index": 0,
                            "manifest": capture.name,
                            "sha256": sha256(capture),
                            "status": "PASS",
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        self.capture_replay_list.write_text(
            json.dumps(
                {
                    "schema": "l1d-qemu-replay-list-v2",
                    "status": "PASS",
                    "campaign_manifest": str(self.capture_campaign.resolve()),
                    "campaign_sha256": sha256(self.capture_campaign),
                    "capture_units": 1,
                    "replay_count": 1,
                    "replays": [
                        {
                            "capture_manifest": capture.name,
                            "benchmark": "708.sqlite_r",
                            "command_index": 0,
                            "window_index": 0,
                            "kind": "sampled",
                            "warmup_events": 1,
                            "measure_events": 4,
                            "total_events": 5,
                            "path": self.trace.name,
                            "sha256": sha256(self.trace),
                            "payload_lines": 5,
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )
        self.data["capture_campaign"]["sha256"] = sha256(self.capture_campaign)
        self.data["capture_replay_list"]["sha256"] = sha256(
            self.capture_replay_list
        )
        for run in self.data["runs"]:
            run["capture_manifest"] = {
                "path": capture.name,
                "sha256": sha256(capture),
            }
            run["capture_window_index"] = 0
            run["capture_window_kind"] = "sampled"
            run["warmup_events"] = 1
            run["measure_events"] = 4
            run["total_events"] = 5
        self.write_manifest()
        return capture


class StrictCampaignTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_resident_unused_is_in_accuracy_denominator_and_coverage_is_paired(self) -> None:
        fixture = CampaignFixture(self.root)
        runs, pairs, aggregate, validation = analyze_campaign(fixture.manifest)
        self.assertEqual(len(runs), 2)
        self.assertEqual(validation["status"], "PASS")
        pair = pairs[0]
        self.assertAlmostEqual(pair["accuracy"], 2 / 3)
        self.assertNotAlmostEqual(pair["accuracy"], 1.0)
        self.assertAlmostEqual(pair["l1_coverage"], 1 / 3)
        self.assertNotAlmostEqual(pair["l1_coverage"], 2 / 4)  # old useful/accesses formula
        self.assertAlmostEqual(pair["lower_coverage"], 1 / 2)
        self.assertEqual(pair["true_l1_help"], 2)
        self.assertEqual(pair["true_l1_pollution"], 1)
        self.assertEqual(pair["true_lower_help"], 2)
        self.assertEqual(pair["true_lower_pollution"], 1)
        self.assertEqual(pair["cycles_on_minus_off"], -5)
        self.assertEqual(pair["cycle_class"], "helpful")
        self.assertAlmostEqual(aggregate[0]["accuracy"], 2 / 3)

    def test_schema3_lifecycle_allows_merge_without_install(self) -> None:
        fixture = CampaignFixture(self.root)
        fixture.on.update(
            {
                "schema": 3,
                "demand_mem_reads": 0,
                "prefetch_mem_reads": 4,
                "mem_reads": 4,
                "read_bytes": 64,
                "useless_evicted": 1,
                "pf_candidates": 5,
                "pf_admitted": 4,
                "pf_issued": 4,
                "pf_returned": 4,
                "pf_installed": 3,
                "pf_merged": 1,
                "pf_discarded": 0,
                "pf_cancelled": 1,
                "pf_unused_evicted": 1,
                "pf_unused_resident": 1,
            }
        )
        for field in V3_LIFECYCLE_COUNTER_FIELDS:
            fixture.on.setdefault(field, 0)
        fields = ["schema=3", "config_id=pf1", "trace_id=trace-c0-w0"]
        fields.extend(
            f"{field}={fixture.on[field]}"
            for field in INT_RESULT_FIELDS
            if field != "schema"
        )
        fields.extend(
            f"{field}={fixture.on[field]}"
            for field in V3_LIFECYCLE_COUNTER_FIELDS
        )
        fields.append("status=PASS")
        fixture.on_log.write_text(
            "WORKLOAD_RESULT " + " ".join(fields) + "\n", encoding="utf-8"
        )
        fixture._write_sidecar(
            fixture.on_sidecar,
            ["lower_memory", "l1_hit", "l1_hit", "victim_hit"],
            prefetch_issues=4,
            prefetch_fills=3,
        )
        fixture.refresh_artifact_hashes()
        fixture.write_manifest()

        runs, pairs, _, _ = analyze_campaign(fixture.manifest)
        on = next(run for run in runs if run["prefetch"] == 1)
        self.assertEqual(on["pf_issued"], 4)
        self.assertEqual(on["pf_installed"], 3)
        self.assertEqual(on["pf_merged"], 1)
        self.assertEqual(pairs[0]["on_pf_returned"], 4)

        fixture.on["pf_admitted"] = 5
        fixture.on["pf_cancelled"] = 0
        fields = ["schema=3", "config_id=pf1", "trace_id=trace-c0-w0"]
        fields.extend(
            f"{field}={fixture.on[field]}"
            for field in INT_RESULT_FIELDS
            if field != "schema"
        )
        fields.extend(
            f"{field}={fixture.on[field]}"
            for field in V3_LIFECYCLE_COUNTER_FIELDS
        )
        fields.append("status=PASS")
        fixture.on_log.write_text(
            "WORKLOAD_RESULT " + " ".join(fields) + "\n", encoding="utf-8"
        )
        fixture.refresh_artifact_hashes()
        fixture.write_manifest()
        with self.assertRaisesRegex(
            ValidationError,
            r"pf_admitted must be <= pf_issued \+ pf_cancelled after drain",
        ):
            analyze_campaign(fixture.manifest)

    def test_campaign_and_sidecar_schema3_bind_producer_and_policy(self) -> None:
        fixture = CampaignFixture(self.root)
        fixture.data["schema"] = "l1d-replay-campaign-v3"
        fixture._write_v3_sidecar(
            fixture.off_sidecar,
            ["l1_hit", "lower_memory", "victim_hit", "lower_memory"],
        )
        fixture._write_v3_sidecar(
            fixture.on_sidecar,
            ["lower_memory", "l1_hit", "l1_hit", "victim_hit"],
            prefetch_issues=3,
            prefetch_fills=3,
        )
        for run in fixture.data["runs"]:
            run.update(
                {
                    "prefetch_policy": 1,
                    "pf_opt_level": 3,
                    "producer_profile": "zero-bubble",
                    "producer_gap": 0,
                }
            )
            command = run["simulation_command"]
            command.extend(["+PRODUCER_PROFILE=1", "+PRODUCER_GAP=0"])
            fixture.refresh_command_hash(run)
        fixture.refresh_artifact_hashes()
        fixture.write_manifest()

        runs, pairs, aggregate, _ = analyze_campaign(fixture.manifest)
        self.assertEqual({run["producer_profile"] for run in runs}, {"zero-bubble"})
        self.assertEqual(pairs[0]["prefetch_policy"], 1)
        self.assertEqual(pairs[0]["pf_opt_level"], 3)
        self.assertEqual(aggregate[0]["producer_gap"], 0)

    def test_zero_denominators_are_na_not_silent_zero(self) -> None:
        fixture = CampaignFixture(self.root, all_hits=True)
        _, pairs, aggregate, _ = analyze_campaign(fixture.manifest)
        pair = pairs[0]
        self.assertIsNone(pair["accuracy"])
        self.assertIsNone(pair["l1_coverage"])
        self.assertIsNone(pair["lower_coverage"])
        self.assertIsNone(pair["bandwidth_overhead"])
        self.assertIsNone(pair["timeliness"])
        self.assertIsNone(aggregate[0]["accuracy"])

    def test_duplicate_expected_run_is_rejected(self) -> None:
        fixture = CampaignFixture(self.root)
        fixture.data["runs"].append(copy.deepcopy(fixture.data["runs"][0]))
        fixture.data["expected_runs"] = 3
        fixture.data["actual_runs"] = 3
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, "duplicate expected run"):
            load_campaign(fixture.manifest)

    def test_missing_pair_member_is_rejected(self) -> None:
        fixture = CampaignFixture(self.root)
        fixture.data["runs"] = fixture.data["runs"][:1]
        fixture.data["expected_runs"] = 1
        fixture.data["actual_runs"] = 1
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, "config policy does not match"):
            load_campaign(fixture.manifest)

    def test_baseline_only_geometry_is_valid_but_not_a_pair(self) -> None:
        fixture = CampaignFixture(self.root)
        standalone_log = self.root / "dm.log"
        standalone_sidecar = self.root / "dm.tsv"
        standalone_sidecar.write_bytes(fixture.off_sidecar.read_bytes())
        counters = copy.deepcopy(fixture.off)
        counters.update({"sets": 8, "ways": 1})
        fixture._write_log(standalone_log, "dm_s8_vc4_pf0", counters)
        standalone = copy.deepcopy(fixture.data["runs"][0])
        standalone.update(
            {
                "config_id": "dm_s8_vc4_pf0",
                "sets": 8,
                "ways": 1,
                "log": {"path": standalone_log.name, "sha256": sha256(standalone_log)},
                "sidecar": {
                    "path": standalone_sidecar.name,
                    "sha256": sha256(standalone_sidecar),
                },
            }
        )
        standalone["simulation_command"][2] = "+CONFIG_ID=dm_s8_vc4_pf0"
        standalone["simulation_command"][-1] = (
            f"+ACCESS_SIDECAR={standalone_sidecar.name}"
        )
        fixture.refresh_command_hash(standalone)
        fixture.data["runs"].append(standalone)
        fixture.data["standalone_config_ids"] = ["dm_s8_vc4_pf0"]
        fixture.data["expected_runs"] = 3
        fixture.data["actual_runs"] = 3
        fixture.write_manifest()
        runs, pairs, _, validation = analyze_campaign(fixture.manifest)
        self.assertEqual(len(runs), 3)
        self.assertEqual(len(pairs), 1)
        self.assertEqual(validation["expected_pairs"], 1)

    def test_declared_run_and_pair_counts_are_enforced(self) -> None:
        fixture = CampaignFixture(self.root)
        fixture.data["expected_runs"] = 3
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, "expected_runs=3"):
            analyze_campaign(fixture.manifest)

        fixture.data["expected_runs"] = 2
        fixture.data["expected_pairs"] = 2
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, "expected_pairs=2"):
            analyze_campaign(fixture.manifest)

    def test_capture_backed_campaign_requires_canonical_four_config_policy(self) -> None:
        fixture = CampaignFixture(self.root)
        fixture.data["require_capture_manifests"] = True
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, "canonical four-config matrix"):
            analyze_campaign(fixture.manifest)

    def test_log_and_sidecar_hashes_are_required_and_verified(self) -> None:
        fixture = CampaignFixture(self.root)
        fixture.data["runs"][0]["log"].pop("sha256")
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, "log SHA-256 is required"):
            analyze_campaign(fixture.manifest)

        fixture = CampaignFixture(self.root)
        fixture.off_log.write_text("tampered\n", encoding="utf-8")
        with self.assertRaisesRegex(ValidationError, "SHA-256 mismatch"):
            analyze_campaign(fixture.manifest)

        fixture = CampaignFixture(self.root)
        fixture.data["runs"][0]["sidecar"].pop("sha256")
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, "sidecar SHA-256 is required"):
            analyze_campaign(fixture.manifest)

        fixture = CampaignFixture(self.root)
        fixture.off_sidecar.write_text("tampered\n", encoding="utf-8")
        with self.assertRaisesRegex(ValidationError, "SHA-256 mismatch"):
            analyze_campaign(fixture.manifest)

    def test_capture_manifest_hash_and_provenance_are_enforced(self) -> None:
        fixture = CampaignFixture(self.root)
        capture = fixture.attach_capture_manifest()
        analyze_campaign(fixture.manifest)

        fixture.data["runs"][0]["capture_manifest"].pop("sha256")
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, "capture-manifest SHA-256 is required"):
            analyze_campaign(fixture.manifest)

        fixture = CampaignFixture(self.root)
        capture = fixture.attach_capture_manifest()
        capture_data = json.loads(capture.read_text(encoding="utf-8"))
        capture_data["toolchain"]["qemu_version"] = "QEMU emulator version 10.0.0"
        capture.write_text(json.dumps(capture_data), encoding="utf-8")
        fixture.refresh_artifact_hashes()
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, "requires QEMU 11.0.1"):
            analyze_campaign(fixture.manifest)

    def test_simulation_binary_and_command_hashes_are_enforced(self) -> None:
        fixture = CampaignFixture(self.root)
        fixture.sim_binary.write_bytes(b"tampered simulation\n")
        with self.assertRaisesRegex(ValidationError, "SHA-256 mismatch"):
            analyze_campaign(fixture.manifest)

        fixture = CampaignFixture(self.root)
        fixture.data["runs"][0]["simulation_command"].append("+UNDECLARED_TIMING=1")
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, "simulation command SHA-256 mismatch"):
            analyze_campaign(fixture.manifest)

    def test_simulation_command_binds_trace_and_sidecar_artifacts(self) -> None:
        fixture = CampaignFixture(self.root)
        run = fixture.data["runs"][0]
        run["simulation_command"][-2] = f"+TRACE={fixture.on_sidecar.name}"
        fixture.refresh_command_hash(run)
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, r"\+TRACE path .* does not match"):
            analyze_campaign(fixture.manifest)

        fixture = CampaignFixture(self.root)
        run = fixture.data["runs"][0]
        run["simulation_command"][-1] = (
            f"+ACCESS_SIDECAR={fixture.on_sidecar.name}"
        )
        fixture.refresh_command_hash(run)
        fixture.write_manifest()
        with self.assertRaisesRegex(
            ValidationError,
            r"\+ACCESS_SIDECAR path .* does not match",
        ):
            analyze_campaign(fixture.manifest)

    def test_failed_validation_removes_previous_pass_outputs(self) -> None:
        fixture = CampaignFixture(self.root)
        out_dir = self.root / "analysis"
        self.assertEqual(
            summarize_main(
                ["--manifest", str(fixture.manifest), "--out-dir", str(out_dir)]
            ),
            0,
        )
        self.assertTrue((out_dir / "runs.csv").is_file())
        fixture.data["runs"][0]["trace"]["sha256"] = "0" * 64
        fixture.write_manifest()
        self.assertEqual(
            summarize_main(
                ["--manifest", str(fixture.manifest), "--out-dir", str(out_dir)]
            ),
            2,
        )
        self.assertFalse((out_dir / "runs.csv").exists())
        failure = json.loads((out_dir / "validation.json").read_text(encoding="utf-8"))
        self.assertEqual(failure["status"], "FAIL")

    def test_geometry_mismatch_is_rejected(self) -> None:
        fixture = CampaignFixture(self.root)
        fixture.on["sets"] = 8
        fixture._write_log(fixture.on_log, "pf1", fixture.on)
        fixture.refresh_artifact_hashes()
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, "sets mismatch"):
            analyze_campaign(fixture.manifest)

    def test_trace_hash_mismatch_is_rejected(self) -> None:
        fixture = CampaignFixture(self.root)
        fixture.data["runs"][1]["trace"]["sha256"] = "0" * 64
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, "SHA-256 mismatch"):
            analyze_campaign(fixture.manifest)

    def test_cold_warm_mode_mismatch_is_rejected(self) -> None:
        fixture = CampaignFixture(self.root)
        fixture.data["runs"][1]["cold_warm_mode"] = "cold-measure"
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, "sampled ROI must use"):
            analyze_campaign(fixture.manifest)

    def test_sidecar_demand_identity_must_match_canonical_trace(self) -> None:
        fixture = CampaignFixture(self.root)
        for sidecar in (fixture.off_sidecar, fixture.on_sidecar):
            text = sidecar.read_text(encoding="utf-8")
            sidecar.write_text(
                text.replace("addr=0x10", "addr=0x18"),
                encoding="utf-8",
            )
        fixture.refresh_artifact_hashes()
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, "demand identity mismatch"):
            analyze_campaign(fixture.manifest)

    def test_sidecar_missing_prefetch_fill_is_rejected(self) -> None:
        fixture = CampaignFixture(self.root)
        lines = fixture.on_sidecar.read_text(encoding="utf-8").splitlines()
        removed = False
        retained = []
        for line in lines:
            if not removed and "event=prefetch_fill" in line:
                removed = True
                continue
            retained.append(line)
        self.assertTrue(removed)
        fixture.on_sidecar.write_text("\n".join(retained) + "\n", encoding="utf-8")
        fixture.refresh_artifact_hashes()
        fixture.write_manifest()
        with self.assertRaisesRegex(
            ValidationError,
            "prefetch_fill rows = fills",
        ):
            analyze_campaign(fixture.manifest)

    def test_sidecar_extra_prefetch_issue_in_off_run_is_rejected(self) -> None:
        fixture = CampaignFixture(self.root)
        with fixture.off_sidecar.open("a", encoding="utf-8") as handle:
            handle.write(
                "schema=2 event=prefetch_issue seq=-1 cycle=100 "
                "addr=0x1000 op=prefetch size=16 "
                "outcome=lower_memory details=-\n"
            )
        fixture.refresh_artifact_hashes()
        fixture.write_manifest()
        with self.assertRaisesRegex(
            ValidationError,
            "prefetch_issue rows = prefetch_mem_reads",
        ):
            analyze_campaign(fixture.manifest)

    def test_sidecar_unknown_event_is_rejected(self) -> None:
        fixture = CampaignFixture(self.root)
        with fixture.off_sidecar.open("a", encoding="utf-8") as handle:
            handle.write(
                "schema=2 event=unknown seq=-1 cycle=100 addr=0x1000 "
                "op=prefetch size=16 outcome=lower_memory details=-\n"
            )
        fixture.refresh_artifact_hashes()
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, "unsupported sidecar event"):
            analyze_campaign(fixture.manifest)

    def test_sidecars_may_be_omitted_only_as_a_pair(self) -> None:
        fixture = CampaignFixture(self.root)
        fixture.data["require_sidecars"] = False
        fixture.data["runs"][0].pop("sidecar")
        fixture.data["runs"][1].pop("sidecar")
        for run in fixture.data["runs"]:
            run["simulation_command"] = [
                argument
                for argument in run["simulation_command"]
                if not argument.startswith("+ACCESS_SIDECAR=")
            ]
            fixture.refresh_command_hash(run)
        fixture.write_manifest()
        _, pairs, aggregate, validation = analyze_campaign(fixture.manifest)
        self.assertIsNone(pairs[0]["true_l1_help"])
        self.assertFalse(aggregate[0]["true_pollution_available"])
        self.assertEqual(validation["pairs_without_sidecars"], 1)

        fixture.data["runs"][0]["sidecar"] = {
            "path": fixture.off_sidecar.name,
            "sha256": sha256(fixture.off_sidecar),
        }
        fixture.data["runs"][0]["simulation_command"].append(
            f"+ACCESS_SIDECAR={fixture.off_sidecar.name}"
        )
        fixture.refresh_command_hash(fixture.data["runs"][0])
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, "both runs or neither"):
            analyze_campaign(fixture.manifest)

    def test_non_pass_status_and_counter_conservation_are_rejected(self) -> None:
        fixture = CampaignFixture(self.root)
        fixture.off_log.write_text(
            fixture.off_log.read_text(encoding="utf-8").replace("status=PASS", "status=FAIL"),
            encoding="utf-8",
        )
        fixture.refresh_artifact_hashes()
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, "status must be PASS"):
            analyze_campaign(fixture.manifest)

        fixture._write_log(fixture.off_log, "pf0", fixture.off)
        fixture.off["demand_mem_reads"] = 1
        fixture._write_log(fixture.off_log, "pf0", fixture.off)
        fixture.refresh_artifact_hashes()
        fixture.write_manifest()
        with self.assertRaisesRegex(ValidationError, "misses - victim_hits"):
            analyze_campaign(fixture.manifest)

    def test_prefetch_reads_must_equal_fills_after_draining(self) -> None:
        fixture = CampaignFixture(self.root)
        fixture.on["prefetch_mem_reads"] += 1
        fixture.on["mem_reads"] += 1
        fixture.on["read_bytes"] += fixture.on["line_bytes"]
        fixture._write_log(fixture.on_log, "pf1", fixture.on)
        with fixture.on_sidecar.open("a", encoding="utf-8") as handle:
            handle.write(
                "schema=2 event=prefetch_issue seq=-1 cycle=999 "
                "addr=0x2000 op=prefetch size=16 "
                "outcome=lower_memory details=-\n"
            )
        fixture.refresh_artifact_hashes()
        fixture.write_manifest()
        with self.assertRaisesRegex(
            ValidationError,
            "prefetch_mem_reads = fills",
        ):
            analyze_campaign(fixture.manifest)

    def test_aggregate_recomputes_ratio_from_summed_raw_counters(self) -> None:
        fixture = CampaignFixture(self.root)
        _, pairs, _, _ = analyze_campaign(fixture.manifest)
        second = copy.deepcopy(pairs[0])
        second["on_useful"] = 0
        second["on_fills"] = 1
        second["true_l1_help"] = None
        second["true_l1_pollution"] = None
        second["true_lower_help"] = None
        second["true_lower_pollution"] = None
        pairs[0]["true_l1_help"] = None
        pairs[0]["true_l1_pollution"] = None
        pairs[0]["true_lower_help"] = None
        pairs[0]["true_lower_pollution"] = None
        aggregate = aggregate_pairs([pairs[0], second])[0]
        self.assertAlmostEqual(aggregate["accuracy"], 2 / 4)


class TraceFeatureTests(unittest.TestCase):
    def test_trace_locality_stride_reuse_and_set_pressure(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "features.trace"
            path.write_text(
                "0 3 0 0000000000000000\n"
                "1 3 0 0000000000000010 0\n"
                "0 3 0 0000000000000000\n"
                "0 3 0 0000000000000040\n",
                encoding="utf-8",
            )
            features = analyze_trace(path, line_bytes=16, sets=2, ways=1)
            self.assertEqual(features["trace_accesses"], 4)
            self.assertEqual(features["trace_loads"], 3)
            self.assertEqual(features["trace_stores"], 1)
            self.assertEqual(features["trace_load_store_ratio"], 3.0)
            self.assertEqual(features["trace_unique_lines"], 3)
            self.assertEqual(features["trace_reuse_count"], 1)
            self.assertEqual(features["trace_reuse_distance_mean"], 1.0)
            self.assertEqual(features["trace_sets_over_way_capacity"], 1)
            self.assertEqual(features["trace_max_unique_lines_over_ways"], 1)


if __name__ == "__main__":
    unittest.main()
