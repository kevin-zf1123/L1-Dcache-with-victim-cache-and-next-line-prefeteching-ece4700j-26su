from __future__ import annotations

import csv
import json
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

from scripts.render_spec_replay_plots import PlotError, write_plot_outputs
from scripts.summarize_spec_replay import main as summarize_main
from scripts.tests.test_summarize_spec_replay import CampaignFixture


class ReplayPlotTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.classification = self.root / "classification.csv"
        self.svg = self.root / "cycles-on-minus-off.svg"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_negative_zero_and_positive_deltas_are_classified_and_rendered(self) -> None:
        pairs = [
            {
                "benchmark": "harmful",
                "command": "2",
                "window": "1",
                "trace_id": "harmful-c2-w1",
                "cycles_on_minus_off": 7,
                "cycle_class": "harmful",
            },
            {
                "benchmark": '<helpful & "escaped">',
                "command": "0",
                "window": "3",
                "trace_id": "helpful-c0-w3",
                "cycles_on_minus_off": -5,
                "cycle_class": "helpful",
            },
            {
                "benchmark": "neutral",
                "command": "1",
                "window": "0",
                "trace_id": "neutral-c1-w0",
                "cycles_on_minus_off": 0,
                "cycle_class": "neutral",
            },
        ]
        for pair in pairs:
            pair.update(
                {
                    "sets": 4,
                    "ways": 2,
                    "line_bytes": 16,
                    "victim_entries": 4,
                    "timing_profile": "blocking-fixed",
                }
            )

        rows = write_plot_outputs(pairs, self.classification, self.svg)
        self.assertEqual(
            {row["cycles_on_minus_off"]: row["classification"] for row in rows},
            {-5: "helpful", 0: "neutral", 7: "harmful"},
        )
        with self.classification.open(newline="", encoding="utf-8") as handle:
            classified = list(csv.DictReader(handle))
        self.assertEqual(
            {int(row["cycles_on_minus_off"]): row["classification"] for row in classified},
            {-5: "helpful", 0: "neutral", 7: "harmful"},
        )

        first_svg = self.svg.read_text(encoding="utf-8")
        self.assertIn('data-classification="helpful" data-delta="-5"', first_svg)
        self.assertIn('data-classification="neutral" data-delta="0"', first_svg)
        self.assertIn('data-classification="harmful" data-delta="7"', first_svg)
        self.assertIn("#2e8b57", first_svg)
        self.assertIn("#7f8c8d", first_svg)
        self.assertIn("#c0392b", first_svg)
        self.assertIn("&lt;helpful &amp; &quot;escaped&quot;&gt;", first_svg)
        self.assertNotIn('<helpful & "escaped">', first_svg)

        # Publishing the same evidence again must be byte-for-byte stable.
        write_plot_outputs(pairs, self.classification, self.svg)
        self.assertEqual(self.svg.read_text(encoding="utf-8"), first_svg)

    def test_invalid_pair_set_removes_all_previous_plot_outputs(self) -> None:
        self.classification.write_text("stale classification\n", encoding="utf-8")
        self.svg.write_text("stale plot\n", encoding="utf-8")
        duplicate = {
            "benchmark": "same",
            "command": "0",
            "window": "0",
            "sets": 4,
            "ways": 2,
            "line_bytes": 16,
            "victim_entries": 4,
            "timing_profile": "blocking-fixed",
            "cycles_on_minus_off": 1,
            "cycle_class": "harmful",
        }
        with self.assertRaisesRegex(PlotError, "duplicate"):
            write_plot_outputs([duplicate, duplicate], self.classification, self.svg)
        self.assertFalse(self.classification.exists())
        self.assertFalse(self.svg.exists())

    def test_plot_cleanup_attempts_every_target_after_one_error(self) -> None:
        self.classification.mkdir()
        self.svg.write_text("stale plot\n", encoding="utf-8")
        with self.assertRaisesRegex(PlotError, "could not remove plot output"):
            write_plot_outputs([], self.classification, self.svg)
        self.assertFalse(self.svg.exists())

    def test_same_window_with_different_geometry_is_classified_separately(self) -> None:
        common = {
            "benchmark": "708.sqlite_r",
            "command": "0",
            "window": "0",
            "line_bytes": 16,
            "victim_entries": 4,
            "timing_profile": "blocking-fixed",
        }
        pairs = [
            {
                **common,
                "sets": 4,
                "ways": 2,
                "cycles_on_minus_off": -3,
                "cycle_class": "helpful",
            },
            {
                **common,
                "sets": 8,
                "ways": 1,
                "cycles_on_minus_off": 4,
                "cycle_class": "harmful",
            },
        ]
        rows = write_plot_outputs(pairs, self.classification, self.svg)
        self.assertEqual(len(rows), 2)
        self.assertEqual(
            {(row["sets"], row["ways"]) for row in rows},
            {("4", "2"), ("8", "1")},
        )
        with self.classification.open(newline="", encoding="utf-8") as handle:
            classified = list(csv.DictReader(handle))
        self.assertEqual(
            {(row["sets"], row["ways"]) for row in classified},
            {("4", "2"), ("8", "1")},
        )
        svg = self.svg.read_text(encoding="utf-8")
        self.assertIn("sets 4 / ways 2 / line 16 / VC 4", svg)
        self.assertIn("sets 8 / ways 1 / line 16 / VC 4", svg)
        document = ET.fromstring(svg)
        self.assertGreaterEqual(int(document.attrib["width"]), 1200)
        geometry_labels = document.findall(
            ".//{http://www.w3.org/2000/svg}text[@class='pair-geometry']"
        )
        self.assertEqual(len(geometry_labels), 2)

    def test_same_window_with_different_prefetch_or_producer_is_not_duplicate(self) -> None:
        common = {
            "benchmark": "708.sqlite_r",
            "command": "0",
            "window": "0",
            "sets": 4,
            "ways": 2,
            "line_bytes": 16,
            "victim_entries": 4,
            "timing_profile": "fixed-latency2-periodic-ready",
            "prefetch_policy": 1,
            "pf_opt_level": 3,
            "producer_gap": 0,
            "cycles_on_minus_off": -1,
            "cycle_class": "helpful",
        }
        rows = write_plot_outputs(
            [
                {**common, "producer_profile": "sequential"},
                {**common, "producer_profile": "zero-bubble"},
            ],
            self.classification,
            self.svg,
        )
        self.assertEqual(len(rows), 2)
        self.assertEqual(
            {row["producer_profile"] for row in rows},
            {"sequential", "zero-bubble"},
        )

    def test_analyzer_registers_outputs_and_removes_them_after_failure(self) -> None:
        fixture = CampaignFixture(self.root)
        out_dir = self.root / "analysis"
        self.assertEqual(
            summarize_main(
                ["--manifest", str(fixture.manifest), "--out-dir", str(out_dir)]
            ),
            0,
        )
        classification = out_dir / "classification.csv"
        svg = out_dir / "cycles-on-minus-off.svg"
        self.assertTrue(classification.is_file())
        self.assertTrue(svg.is_file())
        validation = json.loads(
            (out_dir / "validation.json").read_text(encoding="utf-8")
        )
        self.assertEqual(
            Path(validation["outputs"]["classification"]),
            classification.resolve(),
        )
        self.assertEqual(Path(validation["outputs"]["cycles_svg"]), svg.resolve())

        fixture.data["runs"][0]["trace"]["sha256"] = "0" * 64
        fixture.write_manifest()
        self.assertEqual(
            summarize_main(
                ["--manifest", str(fixture.manifest), "--out-dir", str(out_dir)]
            ),
            2,
        )
        self.assertFalse(classification.exists())
        self.assertFalse(svg.exists())

    def test_analyzer_rejects_output_paths_that_resolve_to_same_file(self) -> None:
        fixture = CampaignFixture(self.root)
        out_dir = self.root / "analysis"
        shared = self.root / "shared-output"
        alias = self.root / "uncreated" / ".." / shared.name
        self.assertEqual(
            summarize_main(
                [
                    "--manifest",
                    str(fixture.manifest),
                    "--out-dir",
                    str(out_dir),
                    "--classification-csv",
                    str(shared),
                    "--cycles-svg",
                    str(alias),
                ]
            ),
            2,
        )
        self.assertFalse(shared.exists())
        failure = json.loads(
            (out_dir / "validation.json").read_text(encoding="utf-8")
        )
        self.assertEqual(failure["status"], "FAIL")
        self.assertIn("output paths alias", failure["error"])

    def test_cleanup_error_cannot_leave_stale_pass_validation(self) -> None:
        fixture = CampaignFixture(self.root)
        out_dir = self.root / "analysis"
        out_dir.mkdir()
        (out_dir / "runs.csv").mkdir()
        (out_dir / "pairs.csv").write_text("stale pairs\n", encoding="utf-8")
        (out_dir / "validation.json").write_text(
            '{"status":"PASS"}\n', encoding="utf-8"
        )

        self.assertEqual(
            summarize_main(
                ["--manifest", str(fixture.manifest), "--out-dir", str(out_dir)]
            ),
            2,
        )
        self.assertFalse((out_dir / "pairs.csv").exists())
        failure = json.loads(
            (out_dir / "validation.json").read_text(encoding="utf-8")
        )
        self.assertEqual(failure["status"], "FAIL")
        self.assertIn("could not remove output", failure["error"])


if __name__ == "__main__":
    unittest.main()
