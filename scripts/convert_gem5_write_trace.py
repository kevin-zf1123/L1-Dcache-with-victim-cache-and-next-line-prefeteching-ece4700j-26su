#!/usr/bin/env python3
"""
Convert a gem5 write-capture ASCII trace into the RTL replay format.

Expected input format:

    # comments start with #
    tick op addr size wstrb data [pc]

Fields are whitespace-separated.

  - tick: decimal cycle/tick value, retained only for debugging
  - op: "w" for write, "r" for read (optional mixed-capture support)
  - addr: hexadecimal byte address
  - size: hexadecimal or decimal byte count
  - wstrb: hexadecimal byte-enable bitmask, LSB = lowest addressed byte
  - data: hexadecimal bytes in little-endian byte order
  - pc: optional hexadecimal program counter

Output format matches the existing testbench replay trace:

    0 ADDRESS
    1 ADDRESS DATA WRITE_STROBE

The converter splits accesses on 32-bit boundaries and preserves byte enables
exactly. Writes with no active bytes are rejected.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path


def parse_int(text: str) -> int:
    return int(text, 0)


def normalize_hex_bytes(text: str) -> bytes:
    raw = text.strip().lower()
    if raw.startswith("0x"):
        raw = raw[2:]
    if len(raw) % 2 == 1:
        raw = "0" + raw
    if raw == "":
        return b""
    return bytes.fromhex(raw)


def chunk_to_word(chunk: bytes) -> int:
    word = 0
    for index, byte in enumerate(chunk):
        word |= byte << (8 * index)
    return word


@dataclass
class Record:
    op: str
    addr: int
    size: int
    wstrb: int
    data: bytes


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert gem5 write-capture traces into RTL replay traces"
    )
    parser.add_argument("input", help="ASCII gem5 write trace")
    parser.add_argument("output", help="RTL replay trace to write")
    parser.add_argument(
        "--allow-reads",
        action="store_true",
        help="Allow 'r' records and emit 32-bit read accesses",
    )
    return parser.parse_args()


def parse_record(line: str) -> Record | None:
    if not line.strip() or line.lstrip().startswith("#"):
        return None

    fields = line.split()
    if len(fields) < 6:
        if "," in line and len(line.split(",")) >= 5:
            raise ValueError(
                "input looks like decoded MemTraceProbe packet CSV, not the "
                "StoreTrace format. Re-run gem5 with StoreTrace and pass the "
                "resulting store trace to this converter."
            )
        raise ValueError(f"invalid trace line, expected 6+ fields: {line.rstrip()}")

    _tick = fields[0]
    op = fields[1].lower()
    addr = int(fields[2],16)
    size = parse_int(fields[3])
    wstrb_text = fields[4].lower()
    if set(wstrb_text) <= {"0", "1"} and wstrb_text:
        wstrb = int(wstrb_text, 2)
    else:
        wstrb = parse_int(fields[4])
    data = normalize_hex_bytes(fields[5])

    if size < 0:
        raise ValueError(f"invalid size: {size}")
    if op not in {"r", "w"}:
        raise ValueError(f"invalid opcode {op!r}")
    if op == "w" and wstrb == 0:
        raise ValueError(f"write record has zero strobe at addr {addr:08x}")

    return Record(op=op, addr=addr, size=size, wstrb=wstrb, data=data)


def emit_read_lines(out, addr: int, size: int) -> None:
    start = addr & ~0x3
    end = (addr + size + 3) & ~0x3
    for word_addr in range(start, end, 4):
        out.write(f"0 {word_addr:08x}\n")


def emit_write_lines(out, record: Record) -> None:
    if record.size == 0:
        return

    if len(record.data) < record.size:
        raise ValueError(
            f"data field shorter than size at addr {record.addr:08x}: "
            f"{len(record.data)} < {record.size}"
        )

    start = record.addr
    end = record.addr + record.size
    word_start = start & ~0x3
    word_end = (end + 3) & ~0x3

    for word_addr in range(word_start, word_end, 4):
        word_bytes = bytearray(4)
        word_wstrb = 0

        for lane in range(4):
            byte_addr = word_addr + lane
            if byte_addr < start or byte_addr >= end:
                continue

            src_index = byte_addr - record.addr
            if record.wstrb & (1 << src_index):
                word_bytes[lane] = record.data[src_index]
                word_wstrb |= 1 << lane

        if word_wstrb == 0:
            continue

        word_value = chunk_to_word(bytes(word_bytes))
        out.write(
            f"1 {word_addr:08x} {word_value:08x} {word_wstrb:x}\n"
        )


def main() -> None:
    args = parse_args()
    input_path = Path(args.input)
    output_path = Path(args.output)
    parsed = 0
    emitted = 0

    with input_path.open("r", encoding="utf-8") as fin, output_path.open(
        "w", encoding="ascii", newline="\n"
    ) as fout:
        fout.write("# Converted from gem5 write trace\n")
        fout.write("# Replay format: 0 ADDRESS | 1 ADDRESS DATA WRITE_STROBE\n")

        for line in fin:
            record = parse_record(line)
            if record is None:
                continue

            parsed += 1
            if record.op == "r":
                if not args.allow_reads:
                    raise ValueError(
                        "read records present but --allow-reads was not set"
                    )
                emit_read_lines(fout, record.addr, record.size)
                emitted += max(1, (record.size + 3) // 4)
                continue

            before = emitted
            emit_write_lines(fout, record)
            emitted += 0 if emitted == before else 1

    print(
        f"Converted {parsed} records into {emitted} replay access groups "
        f"from {output_path}"
    )


if __name__ == "__main__":
    main()
