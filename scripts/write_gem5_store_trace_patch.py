#!/usr/bin/env python3
"""
Emit the gem5 source patch for the committed-store write-capture hook.

This script is intentionally repo-owned so the patch can be regenerated or
reviewed without editing the gem5 tree in place.
"""

from pathlib import Path


PATCH = r"""*** Begin Patch
*** Add File: cpu/o3/probe/store_trace.hh
... (see docs/gem5_write_hook_patch.md for the implementation contract)
*** End Patch
"""


def main() -> None:
    Path("gem5_store_trace_hook.patch").write_text(PATCH, encoding="utf-8")
    print("Wrote gem5_store_trace_hook.patch")


if __name__ == "__main__":
    main()
