from __future__ import annotations

import re
import sys
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / "scripts"))

from split_qemu_memtrace_windows import TraceFormatError, parse_capture  # noqa: E402


SATP = "0x8000000000012345"


def valid_identity_trace() -> str:
    return "".join(
        (
            "# L1D_QEMU_MEMTRACE schema=3\n",
            "# columns seq vcpu priv satp pc op size vaddr paddr paddr_end\n",
            "# data_policy addresses=licensed-private store_data=redacted\n",
            "# context target=riscv64 plugin_api=6 system_emulation=1 "
            "smp_vcpus=1 max_vcpus=1 mode=capture expected_nonce=0x55 "
            "command=3 expected_total=2\n",
            "# window_config index=0 start=0 count=2 warmup=1 measure=1 label=whole\n",
            "# registers status=PASS a0=a0 a1=a1 a2=a2 a3=a3 a4=a4 "
            "a5=a5 priv=priv satp=satp\n",
            f"# roi_start nonce=0x55 command=3 vcpu=0 priv=0 satp={SATP} "
            "pid=10 tid=11\n",
            "# window index=0 start=0 count=2 warmup=1 measure=1 label=whole\n",
            f"0\t0\t0\t{SATP}\t0x1000\tR\t8\t0x40001000\t0x81001000\t0x81001007\n",
            f"1\t0\t0\t{SATP}\t0x1004\tW\t4\t0x40001008\t0x81001008\t0x8100100b\n",
            f"# roi_stop nonce=0x55 command=3 vcpu=0 priv=0 satp={SATP} "
            "pid=10 tid=11 total_events=2\n",
            "# summary status=PASS reason=qemu_exit mode=capture total_events=2 "
            "captured_rows=2 expected_total=2 count_matches_capture=1 start_seen=1 "
            f"stop_seen=1 vcpu=0 priv=0 satp={SATP} pid=10 tid=11 command=3 "
            "nonce=0x55 filtered_non_u=0 filtered_foreign_satp=0 "
            "misaligned_events=0 cross_line_events=0 expanded_replay_accesses=0 "
            "canonical_replay_accesses=2 captured_canonical_replay_accesses=2 "
            "register_read_failures=0 violations=0 first_violation=none\n",
            "# window_summary index=0 start=0 count=2 warmup=1 measure=1 "
            "label=whole captured=2 misaligned=0 cross_line=0 "
            "canonical_accesses=2 status=PASS\n",
        )
    )


def replace_marker_field(text: str, marker: str, field: str, value: str) -> str:
    lines = text.splitlines(keepends=True)
    for index, line in enumerate(lines):
        if line.startswith(f"# {marker} "):
            changed, count = re.subn(
                rf"(?<!\S){re.escape(field)}=[^\s]+",
                f"{field}={value}",
                line,
                count=1,
            )
            if count != 1:
                raise AssertionError(f"fixture has no {marker}.{field}")
            lines[index] = changed
            return "".join(lines)
    raise AssertionError(f"fixture has no {marker} marker")


class SplitterIdentityTests(unittest.TestCase):
    def parse_text(self, text: str) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            raw = Path(temporary) / "capture.raw.tsv"
            raw.write_text(text, encoding="utf-8")
            parse_capture(raw)

    def test_valid_identity_chain_is_accepted(self) -> None:
        self.parse_text(valid_identity_trace())

    def test_payload_row_satp_must_match_roi_binding(self) -> None:
        text = valid_identity_trace().replace(
            f"0\t0\t0\t{SATP}\t",
            "0\t0\t0\t0x80000000000abcde\t",
            1,
        )
        with self.assertRaisesRegex(TraceFormatError, "satp does not match ROI binding"):
            self.parse_text(text)

    def test_payload_outside_window_cannot_bypass_identity_binding(self) -> None:
        text = valid_identity_trace().replace(
            "# window index=0",
            "2\t0\t0\t0x80000000000abcde\t0x1008\tR\t1\t"
            "0x4000100c\t0x8100100c\t0x8100100c\n# window index=0",
            1,
        )
        with self.assertRaisesRegex(TraceFormatError, "outside a capture window"):
            self.parse_text(text)

    def test_identity_chain_mismatches_fail_closed(self) -> None:
        mismatches = (
            ("context", "expected_nonce", "0x56"),
            ("context", "command", "4"),
            ("roi_start", "nonce", "0x56"),
            ("roi_start", "command", "4"),
            ("roi_start", "satp", "0x80000000000abcde"),
            ("roi_start", "pid", "12"),
            ("roi_start", "tid", "12"),
            ("roi_start", "vcpu", "1"),
            ("roi_start", "priv", "1"),
            ("roi_stop", "nonce", "0x56"),
            ("roi_stop", "command", "4"),
            ("roi_stop", "satp", "0x80000000000abcde"),
            ("roi_stop", "pid", "12"),
            ("roi_stop", "tid", "12"),
            ("roi_stop", "vcpu", "1"),
            ("roi_stop", "priv", "1"),
            ("summary", "nonce", "0x56"),
            ("summary", "command", "4"),
            ("summary", "satp", "0x80000000000abcde"),
            ("summary", "pid", "12"),
            ("summary", "tid", "12"),
            ("summary", "vcpu", "1"),
            ("summary", "priv", "1"),
        )
        for marker, field, value in mismatches:
            with self.subTest(marker=marker, field=field):
                text = replace_marker_field(
                    valid_identity_trace(), marker, field, value
                )
                with self.assertRaises(TraceFormatError):
                    self.parse_text(text)

    def test_missing_identity_fields_fail_closed(self) -> None:
        for marker, field in (
            ("context", "expected_nonce"),
            ("roi_start", "satp"),
            ("roi_stop", "pid"),
            ("summary", "tid"),
        ):
            with self.subTest(marker=marker, field=field):
                text = replace_marker_field(
                    valid_identity_trace(), marker, field, "removed"
                ).replace(f"{field}=removed ", "", 1)
                with self.assertRaises(TraceFormatError):
                    self.parse_text(text)


if __name__ == "__main__":
    unittest.main()
