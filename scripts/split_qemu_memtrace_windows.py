#!/usr/bin/env python3
"""Split a multi-window qemu_memtrace output into replay-ready samples.

The QEMU plugin can write several capture windows into one trace file with
comments like:

    # window index=0 skip=10000 limit=10000

This helper writes one trace file per window and emits a small Markdown
manifest with line counts and SHA-256 hashes. The output traces keep the
original comment header so they remain self-describing for local licensed
analysis while staying compatible with the existing replay parsers.
"""

from __future__ import annotations

import argparse
import hashlib
import re
from pathlib import Path


WINDOW_RE = re.compile(r"^# window index=(\d+) skip=(\d+) limit=(\d+)")
SUMMARY_RE = re.compile(r"^# window_summary index=(\d+) skip=(\d+) limit=(\d+) captured=(\d+)")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def payload_lines(path: Path) -> int:
    count = 0
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.lstrip()
            if stripped and not stripped.startswith("#"):
                count += 1
    return count


def parse_key_values(line: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for field in line.strip().split():
        if "=" in field:
            key, value = field.split("=", 1)
            values[key] = value
    return values


def split_windows(input_path: Path, out_dir: Path, prefix: str) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    outputs: list[Path] = []
    current = None

    with input_path.open("r", encoding="utf-8") as src:
        for line in src:
            match = WINDOW_RE.match(line)
            if match:
                if current is not None:
                    current.close()
                index, skip, limit = match.groups()
                sample_path = out_dir / (
                    f"{prefix}_w{int(index):02d}_skip{skip}_n{limit}.trace"
                )
                current = sample_path.open("w", encoding="utf-8")
                current.write("# opcode size unsigned address [data]\n")
                current.write(line)
                outputs.append(sample_path)
                continue

            if current is not None:
                current.write(line)

    if current is not None:
        current.close()

    return outputs


def read_window_summaries(input_path: Path) -> dict[int, dict[str, str]]:
    summaries: dict[int, dict[str, str]] = {}
    with input_path.open("r", encoding="utf-8") as handle:
        for line in handle:
            if SUMMARY_RE.match(line):
                values = parse_key_values(line)
                summaries[int(values["index"])] = values
    return summaries


def write_manifest(input_path: Path, output_paths: list[Path], manifest_path: Path) -> None:
    summaries = read_window_summaries(input_path)
    lines = [
        "# QEMU Memory Trace Window Manifest",
        "",
        "Raw licensed benchmark traces should stay local unless project policy explicitly allows publication.",
        "",
        "| sample | payload lines | skip | requested lines | captured lines | sha256 |",
        "| --- | ---: | ---: | ---: | ---: | --- |",
    ]
    for sample in output_paths:
        name = sample.name
        index_match = re.search(r"_w(\d+)_", name)
        index = int(index_match.group(1)) if index_match else -1
        summary = summaries.get(index, {})
        lines.append(
            f"| `{name}` | {payload_lines(sample)} | "
            f"{summary.get('skip', '')} | {summary.get('limit', '')} | "
            f"{summary.get('captured', '')} | `{sha256(sample)}` |"
        )
    lines.append("")
    manifest_path.write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()

    outputs = split_windows(args.input, args.out_dir, args.prefix)
    if not outputs:
        raise SystemExit(f"no windows found in {args.input}")
    manifest = args.manifest or args.out_dir / f"{args.prefix}_MANIFEST.md"
    write_manifest(args.input, outputs, manifest)
    print(f"wrote {len(outputs)} samples and {manifest}")


if __name__ == "__main__":
    main()
