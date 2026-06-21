#!/usr/bin/env python3
"""
Convert gem5 decoded packet traces into this repo's RTL replay trace format.

Input format is the ASCII CSV produced by gem5 util/decode_packet_trace.py:
    cmd,addr,size[,flags],tick[,pc]
or:
    pkt_id,cmd,addr,size[,flags],tick[,pc]

Output format matches traces/smoke.trace:
    0 ADDRESS

This converter intentionally emits reads only. Stock gem5 packet traces do not
contain write payload bytes, and this RTL replay format requires DATA and
WRITE_STROBE for writes.
"""

import argparse
import csv


def parse_args():
    parser = argparse.ArgumentParser(
        description="Convert gem5 decoded packet trace into RTL replay reads"
    )
    parser.add_argument("input", help="Decoded gem5 packet trace CSV text")
    parser.add_argument("output", help="RTL replay trace to write")
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Optional maximum number of output accesses",
    )
    parser.add_argument(
        "--base-mask",
        type=lambda x: int(x, 0),
        default=0xFFFFFFFF,
        help="Mask applied to addresses before writing",
    )
    parser.add_argument(
        "--base-offset",
        type=lambda x: int(x, 0),
        default=0,
        help="Offset added after masking",
    )
    return parser.parse_args()


def row_to_fields(row):
    if not row:
        return None
    if row[0] in ("r", "w", "u"):
        return row[0], row[1], row[2]
    if len(row) >= 2 and row[1] in ("r", "w", "u"):
        return row[1], row[2], row[3]
    return None


def main():
    args = parse_args()
    written = 0
    skipped_writes = 0
    skipped_unknown = 0

    with open(args.input, newline="", encoding="utf-8") as fin, open(
        args.output, "w", encoding="ascii", newline=""
    ) as fout:
        fout.write("# Converted from gem5 decoded packet trace\n")
        fout.write("# Reads only: stock gem5 packet traces omit store payload bytes\n")

        reader = csv.reader(fin)
        for row in reader:
            fields = row_to_fields(row)
            if fields is None:
                continue

            cmd, addr_text, size_text = fields
            addr = int(addr_text)
            size = int(size_text)

            if cmd == "w":
                skipped_writes += 1
                continue
            if cmd != "r":
                skipped_unknown += 1
                continue

            if size == 0:
                continue

            for byte_addr in range(addr, addr + size, 4):
                mapped = (byte_addr & args.base_mask) + args.base_offset
                fout.write(f"0 {mapped:08x}\n")
                written += 1
                if args.limit and written >= args.limit:
                    print(
                        f"Wrote {written} read accesses; "
                        f"skipped {skipped_writes} writes and "
                        f"{skipped_unknown} unsupported packets"
                    )
                    return

    print(
        f"Wrote {written} read accesses; "
        f"skipped {skipped_writes} writes and "
        f"{skipped_unknown} unsupported packets"
    )


if __name__ == "__main__":
    main()
