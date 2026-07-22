import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "publish_prefetch_evidence.py"
SPEC = importlib.util.spec_from_file_location("publish_prefetch_evidence", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PublishPrefetchEvidenceTests(unittest.TestCase):
    def test_gate_provenance_distinguishes_source_and_public_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.json"
            public = root / "public.json"
            source.write_text('{"root":"/private/path"}\n', encoding="utf-8")
            public.write_text('{"root":"private-build"}\n', encoding="utf-8")

            hashes = MODULE.gate_provenance_hashes(source, public)

            self.assertEqual(
                hashes["source_gate_result_sha256"], MODULE.sha256(source)
            )
            self.assertEqual(hashes["gate_result_sha256"], MODULE.sha256(public))
            self.assertNotEqual(
                hashes["source_gate_result_sha256"],
                hashes["gate_result_sha256"],
            )

    def test_gate_paths_and_launcher_are_redacted(self) -> None:
        public = MODULE.sanitize_gate_result(
            {
                "replays": {"p3-lite": {"root": "/Users/private/build/replay"}},
                "vivado": {
                    "manifest": "/Users/private/build/vivado/evidence_manifest.json",
                    "tool": {"launcher": "C:/Users/private/vivado.bat", "part": "x"},
                },
            }
        )
        self.assertEqual(
            public["replays"]["p3-lite"]["root"],
            "private-build/replay/p3-lite",
        )
        self.assertEqual(
            public["vivado"]["manifest"],
            "private-build/vivado/evidence_manifest.json",
        )
        self.assertEqual(public["vivado"]["tool"]["launcher"], "redacted")

    def test_public_scan_rejects_absolute_private_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "artifact.json"
            path.write_text('{"root":"/Users/private/project"}\n', encoding="utf-8")
            with self.assertRaisesRegex(MODULE.PublishError, "private absolute path"):
                MODULE.ensure_public([path])

    def test_public_scan_accepts_relative_artifact_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "artifact.json"
            path.write_text(
                '{"manifest":"private-build/vivado/evidence_manifest.json"}\n',
                encoding="utf-8",
            )
            MODULE.ensure_public([path])


if __name__ == "__main__":
    unittest.main()
