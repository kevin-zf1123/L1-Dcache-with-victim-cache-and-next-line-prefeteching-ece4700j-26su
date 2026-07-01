#!/usr/bin/env python3
"""Generate deterministic Phase 3 matrix and pointer-chase replay traces."""

from __future__ import annotations

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "traces" / "generated"
LINE_BYTES = 16


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as trace_file:
        for chunk in iter(lambda: trace_file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_trace(path: Path, lines: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def matrix_row_major() -> list[str]:
    lines = ["# phase3 matrix row-major 8x8 one doubleword per cache line"]
    base = 0x1000
    for row in range(8):
        for col in range(8):
            addr = base + (row * 8 + col) * LINE_BYTES
            lines.append(f"0 3 0 {addr:016x}")
    return lines


def matrix_column_major() -> list[str]:
    lines = ["# phase3 matrix column-major 8x8 one doubleword per cache line"]
    base = 0x2000
    for col in range(8):
        for row in range(8):
            addr = base + (row * 8 + col) * LINE_BYTES
            lines.append(f"0 3 0 {addr:016x}")
    return lines


def pointer_permutation() -> list[str]:
    lines = ["# phase3 deterministic pointer-chase permutation"]
    base = 0x3000
    order = list(range(64))
    state = 0x47002026
    for i in range(len(order) - 1, 0, -1):
        state = (state * 1103515245 + 12345) & 0x7fffffff
        j = state % (i + 1)
        order[i], order[j] = order[j], order[i]
    for line_id in order:
        addr = base + line_id * LINE_BYTES
        lines.append(f"0 3 0 {addr:016x}")
    return lines


def mixed_store_update() -> list[str]:
    lines = ["# phase3 mixed pointer-style load/store update"]
    base = 0x4000
    idx = 7
    for i in range(64):
        idx = (idx * 9 + 5) % 47
        addr = base + idx * LINE_BYTES
        if i % 4 == 0:
            data = 0x4700000000000000 + i
            lines.append(f"1 3 0 {addr:016x} {data:016x}")
        else:
            lines.append(f"0 3 0 {addr:016x}")
    return lines


def main() -> int:
    traces = {
        "phase3_matrix_row_major.trace": matrix_row_major(),
        "phase3_matrix_column_major.trace": matrix_column_major(),
        "phase3_pointer_permutation.trace": pointer_permutation(),
        "phase3_pointer_mixed_update.trace": mixed_store_update(),
    }
    manifest_lines = [
        "# Phase 3 Generated Trace Manifest",
        "",
        "These traces are deterministic, redistributable cache-interface samples.",
        "They are not licensed SPEC traces.",
        "",
        "| Trace | Lines | SHA-256 | Generator |",
        "| --- | ---: | --- | --- |",
    ]
    for name, lines in traces.items():
        path = OUT_DIR / name
        write_trace(path, lines)
        payload_lines = sum(1 for line in lines if line and not line.startswith("#"))
        manifest_lines.append(
            f"| `{name}` | {payload_lines} | `{sha256(path)}` | `scripts/generate_phase3_traces.py` |"
        )

    manifest_lines.extend(
        [
            "",
            "Replay with the class-based Vivado harness using:",
            "",
            "```text",
            "+TRACE=traces/generated/<trace-name>",
            "```",
            "",
            "Regenerate from the repository root with:",
            "",
            "```bash",
            "scripts/generate_phase3_traces.py",
            "```",
        ]
    )
    write_trace(OUT_DIR / "MANIFEST.md", manifest_lines)
    print(f"wrote {len(traces)} traces under {OUT_DIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
