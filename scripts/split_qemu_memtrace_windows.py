#!/usr/bin/env python3
"""Validate a schema-v3 QEMU capture and derive phase-tagged replay traces.

Raw trace addresses and every derived replay remain private under ``build/``.
The splitter is deliberately strict: malformed rows, incomplete windows, an
INVALID plugin summary, or non-contiguous sequence numbers abort the split.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SCHEMA_LINE = "# L1D_QEMU_MEMTRACE schema=3"
CONTEXT_RE = re.compile(r"^# context (?P<fields>.+)$")
ROI_START_RE = re.compile(r"^# roi_start (?P<fields>.+)$")
ROI_STOP_RE = re.compile(r"^# roi_stop (?P<fields>.+)$")
WINDOW_RE = re.compile(r"^# window (?P<fields>.+)$")
WINDOW_CONFIG_RE = re.compile(r"^# window_config (?P<fields>.+)$")
WINDOW_SUMMARY_RE = re.compile(r"^# window_summary (?P<fields>.+)$")
SUMMARY_RE = re.compile(r"^# summary (?P<fields>.+)$")
RAW_COLUMNS = (
    "seq", "vcpu", "priv", "satp", "pc", "op", "size", "vaddr", "paddr",
    "paddr_end",
)


class TraceFormatError(ValueError):
    """The input is not a complete, valid schema-v3 capture."""


@dataclass(frozen=True)
class Window:
    index: int
    start: int
    count: int
    warmup: int
    measure: int
    label: str
    marker_line: str
    rows: tuple[str, ...]


@dataclass(frozen=True)
class RawEvent:
    seq: int
    vcpu: int
    priv: int
    satp: int
    pc: int
    op: str
    size: int
    vaddr: int
    paddr: int
    paddr_end: int

    @property
    def misaligned(self) -> bool:
        return (self.vaddr & (self.size - 1)) != 0

    @property
    def vaddr_end(self) -> int:
        return self.vaddr + self.size - 1

    @property
    def cross_line(self) -> bool:
        return self.vaddr // 16 != self.vaddr_end // 16

    @property
    def canonical_accesses(self) -> int:
        return 2 if self.cross_line else 1


@dataclass(frozen=True)
class TraceIdentity:
    nonce: int
    command: int
    satp: int
    pid: int
    tid: int
    vcpu: int
    priv: int


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def payload_lines(path: Path) -> int:
    with path.open("r", encoding="utf-8") as handle:
        return sum(
            1
            for line in handle
            if line.strip() and not line.lstrip().startswith("#")
        )


def parse_key_values(fields: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for field in fields.strip().split():
        if "=" not in field:
            raise TraceFormatError(f"malformed key/value field: {field!r}")
        key, value = field.split("=", 1)
        if not key or not value or key in values:
            raise TraceFormatError(f"invalid or duplicate field: {field!r}")
        values[key] = value
    return values


def require_int(values: dict[str, str], key: str) -> int:
    if key not in values:
        raise TraceFormatError(f"missing {key}")
    try:
        return int(values[key], 0)
    except ValueError as error:
        raise TraceFormatError(f"{key} is not an integer: {values[key]!r}") from error


def require_uint64(values: dict[str, str], key: str, *, record: str) -> int:
    value = require_int(values, key)
    if not 0 <= value <= (1 << 64) - 1:
        raise TraceFormatError(f"{record} {key} is outside uint64 range")
    return value


def _identity_from_roi_start(values: dict[str, str]) -> TraceIdentity:
    identity = TraceIdentity(
        **{
            key: require_uint64(values, key, record="roi_start")
            for key in TraceIdentity.__dataclass_fields__
        }
    )
    if identity.vcpu != 0 or identity.priv != 0:
        raise TraceFormatError("roi_start is not bound to vCPU-0 U-mode")
    if identity.pid == 0 or identity.tid == 0:
        raise TraceFormatError("roi_start PID/TID must be nonzero")
    return identity


def _require_identity_match(
    values: dict[str, str],
    *,
    record: str,
    identity: TraceIdentity,
    nonce_key: str = "nonce",
    required_fields: tuple[str, ...] = (
        "nonce", "command", "satp", "pid", "tid", "vcpu", "priv",
    ),
) -> None:
    for identity_field in required_fields:
        record_field = nonce_key if identity_field == "nonce" else identity_field
        actual = require_uint64(values, record_field, record=record)
        expected = getattr(identity, identity_field)
        if actual != expected:
            raise TraceFormatError(
                f"{record} {record_field} identity mismatch: "
                f"expected {expected:#x}, got {actual:#x}"
            )


def _validate_identity_chain(
    context: dict[str, str],
    roi_start: dict[str, str],
    roi_stop: dict[str, str],
    summary: dict[str, str],
) -> TraceIdentity:
    identity = _identity_from_roi_start(roi_start)
    if context.get("mode") != "capture":
        raise TraceFormatError(f"context mode is not capture: {context.get('mode')!r}")
    _require_identity_match(
        context,
        record="context",
        identity=identity,
        nonce_key="expected_nonce",
        required_fields=("nonce", "command"),
    )
    _require_identity_match(roi_stop, record="roi_stop", identity=identity)
    _require_identity_match(summary, record="summary", identity=identity)

    # Fail closed if a future producer adds more identity fields to context:
    # once present, they must agree with the ROI binding as well.
    for identity_field in ("satp", "pid", "tid", "vcpu", "priv"):
        if identity_field in context:
            actual = require_uint64(context, identity_field, record="context")
            expected = getattr(identity, identity_field)
            if actual != expected:
                raise TraceFormatError(
                    f"context {identity_field} identity mismatch: "
                    f"expected {expected:#x}, got {actual:#x}"
                )
    return identity


def _window_from_marker(line: str, rows: list[str]) -> Window:
    match = WINDOW_RE.match(line)
    if match is None:
        raise TraceFormatError(f"invalid window marker: {line.rstrip()}")
    values = parse_key_values(match.group("fields"))
    index = require_int(values, "index")
    start = require_int(values, "start")
    count = require_int(values, "count")
    warmup = require_int(values, "warmup")
    measure = require_int(values, "measure")
    label = values.get("label", "")
    if min(index, start, warmup, measure) < 0 or count <= 0:
        raise TraceFormatError(f"negative/empty window {index}")
    if warmup + measure != count:
        raise TraceFormatError(f"window {index}: warmup + measure != count")
    return Window(index, start, count, warmup, measure, label, line, tuple(rows))


def _parse_raw_row(
    line: str,
    *,
    expected_seq: int,
    expected_identity: TraceIdentity | None = None,
) -> RawEvent:
    fields = tuple(line.rstrip("\n").split("\t"))
    if len(fields) != len(RAW_COLUMNS):
        raise TraceFormatError(
            f"raw row has {len(fields)} columns, expected {len(RAW_COLUMNS)}: {line.rstrip()}"
        )
    try:
        seq = int(fields[0], 0)
        vcpu = int(fields[1], 0)
        priv = int(fields[2], 0)
        satp = int(fields[3], 0)
        pc = int(fields[4], 0)
        size = int(fields[6], 0)
        vaddr = int(fields[7], 0)
        paddr = int(fields[8], 0)
        paddr_end = int(fields[9], 0)
    except ValueError as error:
        raise TraceFormatError(f"non-integer raw field: {line.rstrip()}") from error
    if seq != expected_seq:
        raise TraceFormatError(f"expected seq {expected_seq}, got {seq}")
    if vcpu != 0 or priv != 0:
        raise TraceFormatError(f"row {seq} is not vCPU-0 U-mode")
    if fields[5] not in {"R", "W"}:
        raise TraceFormatError(f"row {seq} has invalid op {fields[5]!r}")
    if size not in {1, 2, 4, 8}:
        raise TraceFormatError(f"row {seq} has unsupported size {size}")
    if vaddr > (1 << 64) - size:
        raise TraceFormatError(f"row {seq} virtual address overflows")
    event = RawEvent(
        seq, vcpu, priv, satp, pc, fields[5], size, vaddr, paddr, paddr_end
    )
    if expected_identity is not None:
        for field in ("vcpu", "priv", "satp"):
            actual = getattr(event, field)
            expected = getattr(expected_identity, field)
            if actual != expected:
                raise TraceFormatError(
                    f"row {seq} {field} does not match ROI binding: "
                    f"expected {expected:#x}, got {actual:#x}"
                )
    if not event.cross_line and paddr_end != paddr + size - 1:
        raise TraceFormatError(f"row {seq} has inconsistent same-line paddr_end")
    return event


def _replay_line(op: str, size_bytes: int, paddr: int) -> str:
    size_shift = int(math.log2(size_bytes))
    if op == "R":
        return f"0 {size_shift} 1 {paddr:016x}\n"
    return f"1 {size_shift} 0 {paddr:016x} {'0' * (size_bytes * 2)}\n"


def raw_to_replay(line: str, *, expected_seq: int) -> list[str]:
    event = _parse_raw_row(line, expected_seq=expected_seq)
    if not event.misaligned:
        return [_replay_line(event.op, event.size, event.paddr)]
    touches = [_replay_line(event.op, 1, event.paddr & ~0xF)]
    if event.cross_line:
        touches.append(_replay_line(event.op, 1, event.paddr_end & ~0xF))
    return touches


def parse_capture(input_path: Path) -> tuple[list[str], list[str], list[Window], dict[str, str]]:
    header: list[str] = []
    trailer: list[str] = []
    windows: list[Window] = []
    configs: dict[int, dict[str, str]] = {}
    summaries: dict[int, dict[str, str]] = {}
    contexts: list[dict[str, str]] = []
    roi_starts: list[dict[str, str]] = []
    roi_stops: list[dict[str, str]] = []
    summary: dict[str, str] | None = None
    current_marker: str | None = None
    current_rows: list[str] = []

    with input_path.open("r", encoding="utf-8") as handle:
        for line in handle:
            for pattern, records in (
                (CONTEXT_RE, contexts),
                (ROI_START_RE, roi_starts),
                (ROI_STOP_RE, roi_stops),
            ):
                match = pattern.match(line)
                if match is not None:
                    records.append(parse_key_values(match.group("fields")))

            if WINDOW_CONFIG_RE.match(line):
                values = parse_key_values(WINDOW_CONFIG_RE.match(line).group("fields"))  # type: ignore[union-attr]
                index = require_int(values, "index")
                if index in configs:
                    raise TraceFormatError(f"duplicate window_config {index}")
                configs[index] = values

            marker_match = WINDOW_RE.match(line)
            if marker_match is not None and not line.startswith("# window_config") and not line.startswith("# window_summary"):
                if current_marker is not None:
                    windows.append(_window_from_marker(current_marker, current_rows))
                current_marker = line
                current_rows = []
                continue

            if line.startswith("# violation"):
                trailer.append(line)
                continue
            summary_match = SUMMARY_RE.match(line)
            if summary_match is not None:
                if summary is not None:
                    raise TraceFormatError("duplicate summary")
                summary = parse_key_values(summary_match.group("fields"))
                trailer.append(line)
                continue
            window_summary_match = WINDOW_SUMMARY_RE.match(line)
            if window_summary_match is not None:
                values = parse_key_values(window_summary_match.group("fields"))
                index = require_int(values, "index")
                if index in summaries:
                    raise TraceFormatError(f"duplicate window_summary {index}")
                summaries[index] = values
                trailer.append(line)
                continue

            if current_marker is None:
                if line.strip() and not line.lstrip().startswith("#"):
                    raise TraceFormatError("raw payload appears outside a capture window")
                header.append(line)
            elif line.lstrip().startswith("#"):
                trailer.append(line)
            elif line.strip():
                current_rows.append(line)

    if current_marker is not None:
        windows.append(_window_from_marker(current_marker, current_rows))
    if not header or header[0].rstrip("\n") != SCHEMA_LINE:
        raise TraceFormatError("missing schema-v3 header")
    if summary is None:
        raise TraceFormatError("missing summary")
    for name, records in (
        ("context", contexts),
        ("roi_start", roi_starts),
        ("roi_stop", roi_stops),
    ):
        if len(records) != 1:
            raise TraceFormatError(f"expected exactly one {name}, got {len(records)}")
    identity = _validate_identity_chain(
        contexts[0], roi_starts[0], roi_stops[0], summary
    )
    if summary.get("status") != "PASS" or summary.get("mode") != "capture":
        raise TraceFormatError(
            f"capture summary is not PASS/capture: {summary.get('status')}/{summary.get('mode')}"
        )
    if require_int(summary, "start_seen") != 1 or require_int(summary, "stop_seen") != 1:
        raise TraceFormatError("ROI marker pair is incomplete")
    if require_int(summary, "count_matches_capture") != 1:
        raise TraceFormatError("count/capture totals differ")
    if require_int(summary, "violations") != 0:
        raise TraceFormatError("capture contains a violation")
    total_source_events = require_int(summary, "total_events")
    total_misaligned = require_int(summary, "misaligned_events")
    total_cross_line = require_int(summary, "cross_line_events")
    total_expanded = require_int(summary, "expanded_replay_accesses")
    total_canonical = require_int(summary, "canonical_replay_accesses")
    if (
        total_cross_line > total_misaligned
        or total_expanded != total_cross_line
        or total_canonical != total_source_events + total_expanded
    ):
        raise TraceFormatError("global canonicalization conservation failed")
    if not windows:
        raise TraceFormatError("capture contains no windows")

    for expected_index, window in enumerate(windows):
        if window.index != expected_index:
            raise TraceFormatError(
                f"window indices must be dense; expected {expected_index}, got {window.index}"
            )
        if len(window.rows) != window.count:
            raise TraceFormatError(
                f"window {window.index}: expected {window.count} rows, got {len(window.rows)}"
            )
        config = configs.get(window.index)
        window_summary = summaries.get(window.index)
        if config is None or window_summary is None:
            raise TraceFormatError(f"window {window.index}: missing config or summary")
        for key, expected in {
            "start": window.start,
            "count": window.count,
            "warmup": window.warmup,
            "measure": window.measure,
        }.items():
            if require_int(config, key) != expected or require_int(window_summary, key) != expected:
                raise TraceFormatError(f"window {window.index}: {key} metadata mismatch")
        if config.get("label") != window.label or window_summary.get("label") != window.label:
            raise TraceFormatError(f"window {window.index}: label metadata mismatch")
        if require_int(window_summary, "captured") != window.count or window_summary.get("status") != "PASS":
            raise TraceFormatError(f"window {window.index}: incomplete plugin summary")
        events = [
            _parse_raw_row(
                row,
                expected_seq=window.start + offset,
                expected_identity=identity,
            )
            for offset, row in enumerate(window.rows)
        ]
        window_misaligned = sum(event.misaligned for event in events)
        window_cross_line = sum(event.cross_line for event in events)
        window_canonical = sum(event.canonical_accesses for event in events)
        if (
            require_int(window_summary, "misaligned") != window_misaligned
            or require_int(window_summary, "cross_line") != window_cross_line
            or require_int(window_summary, "canonical_accesses") != window_canonical
            or window_canonical != window.count + window_cross_line
        ):
            raise TraceFormatError(
                f"window {window.index}: canonicalization metadata mismatch"
            )

    if require_int(summary, "captured_rows") != sum(window.count for window in windows):
        raise TraceFormatError("captured_rows does not equal the sum of window counts")
    if require_int(summary, "captured_canonical_replay_accesses") != sum(
        sum(
            _parse_raw_row(row, expected_seq=window.start + offset).canonical_accesses
            for offset, row in enumerate(window.rows)
        )
        for window in windows
    ):
        raise TraceFormatError("captured canonical replay total is inconsistent")
    return header, trailer, windows, summary


def split_v2_trace(input_path: Path, out_dir: Path, prefix: str) -> list[dict[str, Any]]:
    header, trailer, windows, _summary = parse_capture(input_path)
    out_dir.mkdir(parents=True, exist_ok=True)
    artifacts: list[dict[str, Any]] = []

    for window in windows:
        events = [
            _parse_raw_row(row, expected_seq=window.start + offset)
            for offset, row in enumerate(window.rows)
        ]
        canonical_rows = [
            raw_to_replay(row, expected_seq=window.start + offset)
            for offset, row in enumerate(window.rows)
        ]
        warmup_accesses = sum(
            len(rows) for rows in canonical_rows[: window.warmup]
        )
        measure_accesses = sum(
            len(rows) for rows in canonical_rows[window.warmup :]
        )
        canonical_total = warmup_accesses + measure_accesses
        cross_line_events = sum(event.cross_line for event in events)
        misaligned_events = sum(event.misaligned for event in events)
        if canonical_total != window.count + cross_line_events:
            raise TraceFormatError(
                f"window {window.index}: replay expansion conservation failed"
            )
        sample_path = out_dir / (
            f"{prefix}_w{window.index:02d}_{window.label}_n{canonical_total}.trace"
        )
        with sample_path.open("w", encoding="utf-8", newline="\n") as output:
            output.write("# L1D_REPLAY schema=2 source_schema=L1D_QEMU_MEMTRACE_v3\n")
            output.write("# replay_columns opcode size_shift unsigned paddr [redacted_store_data]\n")
            output.writelines(header)
            output.write(window.marker_line)
            output.write("# PHASE warmup\n")
            for offset, rows in enumerate(canonical_rows):
                if offset == window.warmup:
                    output.write("# PHASE measure\n")
                output.writelines(rows)
            if window.warmup == window.count:
                output.write("# PHASE measure\n")
            output.writelines(trailer)

        quantile: float | None = None
        quantile_match = re.fullmatch(r"q(10|30|50|70|90)", window.label)
        if quantile_match:
            quantile = int(quantile_match.group(1)) / 100
        artifacts.append(
            {
                "index": window.index,
                "kind": "whole" if window.label == "whole" else "sampled",
                "quantile": quantile,
                "start": window.start,
                "warmup_events": warmup_accesses,
                "measure_events": measure_accesses,
                "total_events": canonical_total,
                "source_start": window.start,
                "source_warmup_events": window.warmup,
                "source_measure_events": window.measure,
                "source_total_events": window.count,
                "misaligned_source_events": misaligned_events,
                "cross_line_source_events": cross_line_events,
                "expanded_replay_accesses": canonical_total - window.count,
                "replay": {
                    "path": str(sample_path),
                    "sha256": sha256(sample_path),
                    "payload_lines": payload_lines(sample_path),
                },
            }
        )
    return artifacts


def _relative_paths(value: Any, base: Path) -> Any:
    if isinstance(value, dict):
        return {key: _relative_paths(item, base) for key, item in value.items()}
    if isinstance(value, list):
        return [_relative_paths(item, base) for item in value]
    return value


def write_markdown_manifest(manifest: dict[str, Any], path: Path) -> None:
    lines = [
        "# Private QEMU Capture Manifest",
        "",
        f"Status: **{manifest.get('status', 'UNKNOWN')}**",
        "",
        "Licensed raw and replay traces must remain under the ignored `build/` tree.",
        "",
        "| window | kind | quantile | start | warmup | measure | replay lines | sha256 |",
        "| ---: | --- | ---: | ---: | ---: | ---: | ---: | --- |",
    ]
    for window in manifest.get("windows", []):
        replay = window["replay"]
        quantile = "" if window.get("quantile") is None else f"{window['quantile']:.1f}"
        lines.append(
            f"| {window['index']} | {window['kind']} | {quantile} | {window['start']} | "
            f"{window['warmup_events']} | {window['measure_events']} | "
            f"{replay['payload_lines']} | `{replay['sha256']}` |"
        )
    lines.append("")
    path.write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--manifest-json", type=Path)
    parser.add_argument("--manifest", type=Path, help="Markdown manifest (legacy option name)")
    args = parser.parse_args()

    input_path = args.input.resolve()
    out_dir = args.out_dir.resolve()
    windows = split_v2_trace(input_path, out_dir, args.prefix)
    manifest_path = args.manifest_json or out_dir / f"{args.prefix}_manifest.json"
    manifest_path = manifest_path.resolve()
    manifest = {
        "schema": "l1d-qemu-capture-manifest-v2",
        "status": "PASS",
        "valid": True,
        "artifacts": {
            "raw": {
                "path": str(input_path),
                "sha256": sha256(input_path),
            }
        },
        "windows": windows,
    }
    manifest = _relative_paths(manifest, manifest_path.parent)
    for artifact in manifest["windows"]:
        artifact["replay"]["path"] = str(
            Path(artifact["replay"]["path"]).relative_to(manifest_path.parent)
            if Path(artifact["replay"]["path"]).is_absolute()
            and Path(artifact["replay"]["path"]).is_relative_to(manifest_path.parent)
            else artifact["replay"]["path"]
        )
    raw_path = Path(manifest["artifacts"]["raw"]["path"])
    if raw_path.is_absolute() and raw_path.is_relative_to(manifest_path.parent):
        manifest["artifacts"]["raw"]["path"] = str(raw_path.relative_to(manifest_path.parent))
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    markdown_path = (args.manifest or manifest_path.with_suffix(".md")).resolve()
    write_markdown_manifest(manifest, markdown_path)
    print(f"wrote {len(windows)} replay traces, {manifest_path}, and {markdown_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
