from __future__ import annotations

import csv
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


def valid_result() -> dict[str, str]:
    return {
        "schema": "2",
        "name": "fixture",
        "config_id": "2w_s4_vc4_pf1",
        "trace_id": "fixture-c0-w0",
        "sets": "4",
        "ways": "2",
        "line_bytes": "16",
        "l1_bytes": "128",
        "victim_entries": "4",
        "victim_bytes": "64",
        "total_bytes": "192",
        "prefetch": "1",
        "accesses": "4",
        "hits": "2",
        "misses": "2",
        "victim_hits": "1",
        "demand_mem_reads": "1",
        "prefetch_mem_reads": "3",
        "mem_reads": "4",
        "mem_writes": "0",
        "read_bytes": "64",
        "write_bytes": "0",
        "writebacks": "0",
        "fills": "3",
        "useful": "2",
        "useless_evicted": "0",
        "unused_resident": "1",
        "pollution_proxy": "0",
        "dropped": "0",
        "timely_useful": "2",
        "late_useful": "0",
        "replay_service_cycles": "35",
        "watchdogs": "0",
        "protocol": "0",
        "duplicate_lines": "0",
        "status": "PASS",
    }


def valid_schema3_result() -> dict[str, str]:
    fields = valid_result()
    fields.update(
        {
            "schema": "3",
            # One lower-level miss is satisfied by the in-flight PF MSHR, so
            # it is a late useful prefetch rather than a demand-issued read.
            "demand_mem_reads": "0",
            "prefetch_mem_reads": "4",
            "mem_reads": "4",
            "read_bytes": "64",
            "useless_evicted": "1",
            "timely_useful": "1",
            "late_useful": "1",
            "pf_candidates": "5",
            "pf_admitted": "4",
            "pf_issued": "4",
            "pf_returned": "4",
            "pf_installed": "3",
            "pf_merged": "1",
            "pf_discarded": "0",
            "pf_cancelled": "1",
            "pf_unused_evicted": "1",
            "pf_unused_resident": "1",
            "pf_vc_bypass": "1",
            "pf_caused_writebacks": "0",
            "pf_demand_block_cycles": "2",
            "pf_true_help": "1",
            "pf_true_pollution": "0",
            "pf_suppressed_quota": "2",
            "pf_suppressed_unsafe": "1",
            "pf_same_line_coalesced": "1",
            "pf_controller_state": "2",
            "pf_mshr_valid": "0",
            "pf_mshr_addr": "00000000deadbeef",
            "pf_mshr_confidence": "3",
        }
    )
    return fields


def result_line(fields: dict[str, str]) -> str:
    return "WORKLOAD_RESULT " + " ".join(
        f"{key}={value}" for key, value in fields.items()
    ) + "\n"


class SummarizeWorkloadsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        self.script = scripts / "summarize_workloads.sh"
        self.script.write_bytes(
            (REPO / "scripts" / "summarize_workloads.sh").read_bytes()
        )
        self.script.chmod(0o755)
        validator = scripts / "validate_workload_results.py"
        validator.write_bytes(
            (REPO / "scripts" / "validate_workload_results.py").read_bytes()
        )
        self.sim = self.root / "sim"
        self.sim.mkdir()
        self.output = self.sim / "workload_results.csv"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_script(self, fields: dict[str, str]) -> subprocess.CompletedProcess[str]:
        log = self.root / "fixture.log"
        log.write_text(result_line(fields), encoding="utf-8")
        return self.run_logs(log)

    def run_logs(self, *logs: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(self.script), *(str(log) for log in logs)],
            cwd=self.root,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )

    def test_missing_required_field_removes_stale_csv(self) -> None:
        self.output.write_text("stale PASS evidence\n", encoding="utf-8")
        fields = valid_result()
        fields.pop("fills")
        completed = self.run_script(fields)
        self.assertNotEqual(completed.returncode, 0, completed.stdout)
        self.assertIn("missing required field fills", completed.stdout)
        self.assertFalse(self.output.exists())

    def test_counter_conservation_failure_removes_stale_csv(self) -> None:
        self.output.write_text("stale PASS evidence\n", encoding="utf-8")
        fields = valid_result()
        fields.update(
            {
                "prefetch_mem_reads": "4",
                "mem_reads": "5",
                "read_bytes": "80",
            }
        )
        completed = self.run_script(fields)
        self.assertNotEqual(completed.returncode, 0, completed.stdout)
        self.assertIn("prefetch_mem_reads = fills", completed.stdout)
        self.assertFalse(self.output.exists())

    def test_hit_miss_conservation_is_required(self) -> None:
        fields = valid_result()
        fields["accesses"] = "5"
        completed = self.run_script(fields)
        self.assertNotEqual(completed.returncode, 0, completed.stdout)
        self.assertIn("hits + misses = accesses", completed.stdout)
        self.assertFalse(self.output.exists())

    def test_schema2_derived_invariants_are_enforced(self) -> None:
        cases = (
            ({"sets": "four"}, "non-integer field sets"),
            ({"l1_bytes": "127"}, "l1_bytes = sets * ways * line_bytes"),
            ({"victim_bytes": "63"}, "victim_bytes = victim_entries * line_bytes"),
            ({"total_bytes": "191"}, "total_bytes = l1_bytes + victim_bytes"),
            ({"victim_hits": "3"}, "victim_hits <= misses"),
            ({"demand_mem_reads": "2"}, "demand_mem_reads = misses - victim_hits"),
            (
                {"mem_reads": "5", "read_bytes": "80"},
                "mem_reads = demand_mem_reads + prefetch_mem_reads",
            ),
            ({"read_bytes": "63"}, "read_bytes = mem_reads * line_bytes"),
            ({"write_bytes": "16"}, "write_bytes = mem_writes * line_bytes"),
            (
                {"mem_writes": "1", "write_bytes": "16"},
                "mem_writes = writebacks",
            ),
            (
                {
                    "fills": "4",
                    "prefetch_mem_reads": "4",
                    "mem_reads": "5",
                    "read_bytes": "80",
                },
                "fills = useful + useless_evicted + unused_resident",
            ),
            ({"timely_useful": "1"}, "useful = timely_useful + late_useful"),
            ({"protocol": "1"}, "watchdogs/protocol/duplicate_lines = 0"),
            ({"prefetch": "0"}, "prefetch-off counters = 0"),
        )
        for updates, expected in cases:
            with self.subTest(expected=expected):
                fields = valid_result()
                fields.update(updates)
                completed = self.run_script(fields)
                self.assertNotEqual(completed.returncode, 0, completed.stdout)
                self.assertIn(expected, completed.stdout)
                self.assertFalse(self.output.exists())

    def test_valid_schema2_row_is_published(self) -> None:
        completed = self.run_script(valid_result())
        self.assertEqual(completed.returncode, 0, completed.stdout)
        lines = self.output.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 2)
        self.assertIn("schema,name,config_id,trace_id", lines[0])
        self.assertTrue(lines[1].startswith("2,fixture,2w_s4_vc4_pf1,"))

    def test_schema3_requires_lifecycle_and_diagnostic_fields(self) -> None:
        for required in (
            "pf_candidates",
            "pf_returned",
            "pf_unused_resident",
            "pf_true_help",
            "pf_mshr_addr",
        ):
            with self.subTest(required=required):
                fields = valid_schema3_result()
                fields.pop(required)
                completed = self.run_script(fields)
                self.assertNotEqual(completed.returncode, 0, completed.stdout)
                self.assertIn(f"missing required field {required}", completed.stdout)
                self.assertFalse(self.output.exists())

    def test_schema3_lifecycle_conservation_is_enforced(self) -> None:
        cases = (
            (
                {"pf_admitted": "5", "pf_cancelled": "0"},
                "pf_admitted must be <= pf_issued + pf_cancelled after drain",
            ),
            ({"pf_returned": "3"}, "pf_issued = pf_returned after drain"),
            (
                {"pf_discarded": "1"},
                "pf_returned = pf_installed + pf_merged + pf_discarded",
            ),
            (
                {"pf_unused_resident": "0"},
                "pf_installed = timely_useful + pf_unused_evicted + pf_unused_resident",
            ),
            ({"late_useful": "0"}, "late_useful = pf_merged"),
        )
        for updates, expected in cases:
            with self.subTest(expected=expected):
                fields = valid_schema3_result()
                fields.update(updates)
                completed = self.run_script(fields)
                self.assertNotEqual(completed.returncode, 0, completed.stdout)
                self.assertIn(expected, completed.stdout)
                self.assertFalse(self.output.exists())

    def test_schema2_and_schema3_logs_share_one_csv(self) -> None:
        schema2 = valid_result()
        schema2["name"] = "legacy_fixture"
        schema2_log = self.root / "schema2.log"
        schema2_log.write_text(result_line(schema2), encoding="utf-8")

        schema3 = valid_schema3_result()
        schema3["name"] = "optimized_fixture"
        schema3["config_id"] = "2w_s4_vc4_opt_pf1"
        schema3_log = self.root / "schema3.log"
        schema3_log.write_text(result_line(schema3), encoding="utf-8")

        completed = self.run_logs(schema2_log, schema3_log)
        self.assertEqual(completed.returncode, 0, completed.stdout)
        with self.output.open(encoding="utf-8", newline="") as csv_file:
            rows = list(csv.DictReader(csv_file))
        self.assertEqual([row["schema"] for row in rows], ["2", "3"])
        self.assertIn("pf_candidates", rows[0])
        self.assertEqual(rows[0]["pf_candidates"], "")
        self.assertEqual(rows[1]["pf_candidates"], "5")
        self.assertEqual(rows[1]["pf_mshr_addr"], "00000000deadbeef")


if __name__ == "__main__":
    unittest.main()
