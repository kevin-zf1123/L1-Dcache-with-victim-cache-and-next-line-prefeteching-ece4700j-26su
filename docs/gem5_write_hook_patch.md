# gem5 Write-Capture Hook Patch

This document defines the gem5-side change required to complete read/write
trace capture.

## Target hook point

Attach a probe listener to O3 CPU `DataAccessComplete`:

- `src/cpu/o3/cpu.cc`
- `src/cpu/o3/cpu.hh`

This probe already carries `std::pair<DynInstPtr, PacketPtr>`, which is the
latest point in the current tree where both the dynamic instruction and the
formed memory packet are available.

## Required payload extraction

For each notification:

1. Reject non-load/non-store packets.
2. Read the packet address and size.
3. Read the packet request byte-enable mask from the underlying `Request`.
4. For stores, read the payload bytes from the packet write data.
5. For loads, emit an `r` record even if no payload bytes are present.
6. Emit one ASCII record:

```text
tick op addr size wstrb data [pc]
```

The `data` field must be written in little-endian byte order so the repo-side
converter can preserve the exact byte lanes.

## Suggested implementation shape

- Add a small probe-listener SimObject in gem5, similar to `SimpleTrace` or
  `LocalInstTracker`.
- Register it from Python on the O3 CPU's `DataAccessComplete` probe point.
- Use a text output stream, not protobuf, for the new write trace.
- Keep the write logger single-threaded first; extend later only if needed.

The listener must be implemented in gem5 C++ because the probe framework
(`ProbeListenerObject` / `ProbeListenerArg`) is C++-backed. Python can wire the
object into the simulation, but not extract packet payload bytes on its own.

## Why this hook is correct

- It is later than rename/execute and includes the final store packet.
- It is earlier than memory-system packet traces that discard payload bytes.
- It captures both load and store commands from the same completed-access path.

## Acceptance criteria

- A mixed read/write workload produces both `r` and `w` lines.
- Full-word and partial-byte stores are both represented correctly.
- The repo converter can transform the emitted trace into
  `0 ADDRESS` and `1 ADDRESS DATA WRITE_STROBE` lines consumed by
  `tb_l1d_cache.sv`.
