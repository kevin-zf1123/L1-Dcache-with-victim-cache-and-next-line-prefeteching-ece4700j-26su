# Baseline L1 Data Cache

## Status

This document is the authoritative design and usage description for the
baseline L1 data cache. The current RTL implements a blocking, write-back,
write-allocate cache with:

- configurable direct-mapped or 2-way set-associative organization;
- synchronous tag and data SRAM wrappers;
- ready/valid CPU and line-memory interfaces;
- dirty eviction and line allocation FSM control;
- a parameterized fully associative victim cache;
- next-line prefetching with basic usefulness and pollution counters; and
- self-checking Icarus Verilog tests plus a Vivado batch entry point.

Icarus Verilog is used only for fast preliminary functional checks. Vivado
simulation and synthesis are the final project verification targets.

## Refactor Summary

The original monolithic `src/l1d_cache.sv` has been split into smaller RTL
leaves around stable, toolchain-friendly boundaries:

- `src/l1d_request_arbiter.sv`: idle-cycle CPU / external-prefetch /
  next-line request selection and ready signaling.
- `src/l1d_controller.sv`: packed-port FSM and request-side working state.
- `src/l1d_lookup.sv`: combinational tag hit, invalid-way, and victim-hit
  detection.
- `src/l1d_array_bank.sv`: per-way tag/data SRAM wrapper.
- `src/l1d_victim_cache.sv`: victim entry storage and round-robin pointer.
- `src/l1d_cache_pkg.sv`: shared enums and cache-local types.

`src/l1d_cache.sv` is now primarily an integration layer. It still owns:

- top-level wiring between submodules;
- L1 metadata arrays and replacement policy updates;
- array access control and write-intent generation;
- statistics counters and one-cycle event outputs; and
- simulation-only assertions and configuration guards.

This refactor keeps behavior unchanged while reducing review surface area.
The current regression checkpoint is `bash scripts/run_iverilog.sh`, which
passes after every extraction listed above.

## Source Layout

| Path | Purpose |
| --- | --- |
| `src/l1d_cache_pkg.sv` | Shared cache-local types used across refactored RTL files |
| `src/l1d_lookup.sv` | Pure combinational request decode, L1 hit detection, invalid-way search, victim lookup |
| `src/l1d_array_bank.sv` | Per-way tag/data SRAM wrapper and unified array port boundary |
| `src/l1d_request_arbiter.sv` | `ST_IDLE` request selection, ready signaling, and chosen-request packaging |
| `src/l1d_controller.sv` | Packed-port controller for request-state registers and FSM transitions |
| `src/l1d_victim_cache.sv` | Packed-port victim-cache storage and round-robin pointer state |
| `src/l1d_sram.sv` | Single-port synchronous SRAM inference wrapper |
| `src/l1d_next_line_prefetch.sv` | Replaceable one-entry next-line candidate generator |
| `src/l1d_cache.sv` | Top-level cache integration, controller FSM, victim metadata, counters |
| `src/tb_l1d_cache.sv` | Self-checking testbench and line-memory model |
| `scripts/run_iverilog.sh` | Functional and synthetic-workload preliminary regression |
| `scripts/summarize_workloads.sh` | Convert workload log records to CSV |
| `scripts/run_vivado.tcl` | Vivado simulation, synthesis, utilization, timing, power |
| `constraints/l1d_baseline.xdc` | Default 100 MHz synthesis clock constraint |
| `traces/smoke.trace` | Redistributable trace-replay format smoke test |

All SystemVerilog files remain under `src/` as required by the repository
layout.

## Architecture and Block-Diagram


The following corrections are required for it to represent the current RTL:

- the CPU request and response channels each have their own ready/valid
  handshake; `cpu_req_ready` belongs to the request channel and
  `cpu_rsp_valid`/`cpu_rsp_ready` belong to the response channel;
- hit/miss determination comes from tag, valid metadata, and the fully
  associative victim lookup, not from the data array;
- the next-line address is `line_address + LINE_BYTES`, not byte address
  `+1`; the prefetcher produces a candidate and does not access memory
  directly;
- a victim-cache entry stores the complete line address, line data, valid,
  dirty, and prefetched metadata. A victim hit swaps both data and metadata;
- dirty victim replacement is sent through the controller's write-back state,
  not directly from the victim cache to memory;
- event counters are currently integrated in `l1d_cache`, rather than a
  separate hardware-monitor module; and
- the current blocking design has one serialized lower-memory request path.
  The apparent bus arbiter is therefore FSM request selection, not a separate
  multi-master interconnect.

The implementation-level diagram is:

```mermaid
flowchart TB
    CPU["CPU Core"]
    DRAM["Lower Memory / DRAM Model"]

    subgraph L1D["Blocking L1 Data Cache"]
        SELECT["Request Selection<br/>CPU > External Prefetch > Next-Line"]
        FSM["Cache Controller FSM<br/>Lookup / Allocate / Swap / Write-Back"]
        SRAM["Synchronous Tag and Data SRAMs<br/>Way 0 .. NUM_WAYS-1"]
        META["L1 Metadata<br/>Valid / Dirty / Prefetched / Replacement"]
        VC["Fully Associative Victim Cache<br/>Line Address + Data + Metadata"]
        PF["Next-Line Candidate Queue<br/>Demand Line + LINE_BYTES"]
        MON["Event Pulses and Counters<br/>Integrated in Controller"]
        MEMIF["Serialized Line-Memory Interface<br/>Read Fill or Dirty Write-Back"]
    end

    CPU -->|"Request: valid/ready, address, write, data, strobe"| SELECT
    SELECT -->|"Selected demand or prefetch request"| FSM
    FSM -->|"Response: valid/ready, read data"| CPU

    FSM -->|"Indexed synchronous read/write"| SRAM
    SRAM -->|"Tag and complete-line outputs"| FSM
    FSM <-->|"Metadata update and replacement choice"| META
    FSM <-->|"Associative lookup, eviction, and full-line swap"| VC

    FSM -->|"Completed demand fill"| PF
    PF -->|"Best-effort aligned candidate"| SELECT
    FSM -->|"Hit, miss, victim, write-back, and prefetch events"| MON

    FSM -->|"One line request at a time"| MEMIF
    MEMIF -->|"Read request or dirty line write-back"| DRAM
    DRAM -->|"Complete-line read response"| MEMIF
    MEMIF -->|"Fill response"| FSM
```

`META`, `MON`, and `MEMIF` are still conceptual boundaries inside
`l1d_cache.sv`. As of the June 21, 2026 refactor pass, request selection is a
real leaf RTL module in `src/l1d_request_arbiter.sv`, the packed request-state
controller is a real leaf RTL module in `src/l1d_controller.sv`, victim-cache
storage is a real leaf RTL module in `src/l1d_victim_cache.sv`, the lookup
path is a real leaf RTL module in `src/l1d_lookup.sv`, the tag/data SRAM
wrapper is a real leaf RTL module in `src/l1d_array_bank.sv`, and shared
controller state types live in `src/l1d_cache_pkg.sv`.

## Configurable Parameters

| Parameter | Default | Constraint / meaning |
| --- | ---: | --- |
| `ADDR_WIDTH` | 32 | Byte-address width |
| `DATA_WIDTH` | 32 | CPU transfer width; byte write strobes are supported |
| `LINE_BYTES` | 16 | Power-of-two cache-line size |
| `NUM_SETS` | 8 | Power of two, at least 2 |
| `NUM_WAYS` | 2 | `1` for direct-mapped, `2` for 2-way |
| `VICTIM_ENTRIES` | 4 | Non-zero power of two; intended range is 4 to 8 |
| `ENABLE_PREFETCH` | 1 | Enables idle-cycle next-line prefetch requests |

The current replacement policy is round-robin per set. With two ways this is
equivalent to selecting the way after the most recently selected way. Invalid
ways are always preferred.

## Interface Contract

### CPU request and response

A request transfers when `cpu_req_valid && cpu_req_ready` is true on a rising
clock edge. The request fields are:

- `cpu_req_addr`: byte address;
- `cpu_req_write`: `0` for load, `1` for store;
- `cpu_req_wdata`: store data; and
- `cpu_req_wstrb`: one byte enable per `DATA_WIDTH/8`.

The cache is blocking and accepts one request at a time. A response remains
valid in `cpu_rsp_valid` until accepted with `cpu_rsp_ready`. Loads return the
selected word in `cpu_rsp_rdata`. Stores also produce a completion response;
the returned data is the post-write word and should otherwise be ignored.
CPU addresses must be aligned to `DATA_WIDTH/8`; accesses spanning words or
cache lines are outside this baseline and trigger a simulation assertion.

### Lower line-memory interface

The lower interface transfers complete cache lines:

- reads use `mem_req_valid`, `mem_req_ready`, `mem_req_write=0`, and an aligned
  `mem_req_addr`;
- read data returns later as a pulse on `mem_rsp_valid` with
  `mem_rsp_rdata`; and
- write-backs use `mem_req_write=1` and `mem_req_wdata`.

The baseline assumes a write request is complete when the lower memory accepts
it. There is no separate write-response or error channel.

## FSM and Data Flow

The main states are:

1. `ST_IDLE`: accept a CPU request, or launch a pending prefetch when the CPU
   has no request.
2. `ST_LOOKUP`: consume synchronous SRAM outputs and compare all active ways
   and victim entries.
3. `ST_HIT_WRITE`: commit a byte-enabled store hit.
4. `ST_VC_SWAP`: promote a victim-cache hit into L1 and move the selected L1
   line into the same victim entry.
5. `ST_WB_REQ`: write back a dirty victim entry that must be replaced.
6. `ST_VC_INSERT`: capture an L1 eviction in the victim cache.
7. `ST_MEM_READ_REQ` / `ST_MEM_READ_WAIT`: request and wait for a line fill.
8. `ST_INSTALL`: install the filled demand or prefetched line.
9. `ST_RESP`: hold the CPU response until accepted.

The synchronous SRAM read is initiated in `ST_IDLE`; tag and data outputs are
examined in `ST_LOOKUP`. Metadata valid, dirty, and prefetched bits are
registered separately.

## Refactor Status

The code base is in an incremental modularization phase intended to make
`src/l1d_cache.sv` easier to review and extend without changing behavior.

Completed:

- `state_t` moved into `src/l1d_cache_pkg.sv`;
- idle-cycle CPU / external-prefetch / next-line candidate arbitration moved
  into `src/l1d_request_arbiter.sv`;
- request-state registers and FSM transition logic moved into
  `src/l1d_controller.sv`;
- victim-cache entry storage and RR pointer state moved into
  `src/l1d_victim_cache.sv`;
- request decode, L1 tag hit detection, invalid-way discovery, and victim-hit
  discovery moved into `src/l1d_lookup.sv`; and
- per-way tag/data SRAM instantiation moved into `src/l1d_array_bank.sv`; and
- the main sequential behavior in `src/l1d_cache.sv` was split into separate
  always_ff blocks for controller/request state, L1 metadata, victim-cache
  state, and stats/events; and
- the Icarus regression flow now compiles the package and lookup module
  explicitly before `src/l1d_cache.sv`.

Still integrated in `src/l1d_cache.sv`:

- array access control and write-intent generation;
- victim-cache policy decisions; and
- event counter and pulse generation policy.

Planned next extractions:

1. Optional monitor/statistics extraction if it can preserve the current
   one-cycle event semantics without creating duplicate writers.
2. Optional L1 metadata helper extraction if it reduces top-level policy noise
   without reintroducing fragile unpacked-array ports.

The current refactor order intentionally favors boundaries that can be carried
through Icarus Verilog without relying on unpacked-array module ports, because
those interfaces have already caused elaboration problems in this project.

## Verification Notes

The current documented regression target is:

```bash
./scripts/run_iverilog.sh
```

That script runs directed tests, workload-profile tests, and the redistributable
smoke trace replay using `traces/smoke.trace`.

Icarus still emits non-fatal informational warnings about constant selects in
`always_*` for:

- `src/l1d_lookup.sv`
- `src/l1d_request_arbiter.sv`

Those warnings are a known simulator limitation rather than a functional
failure in the present regression flow.

## Write-Back and Write-Allocate Policy

- A store hit updates only the enabled bytes and marks the L1 line dirty.
- A store miss fetches the complete line, merges the store bytes, installs the
  result, and marks it dirty.
- An L1 replacement first moves the line into the victim cache.
- If the selected victim entry already contains a dirty line, that victim line
  is written to lower memory before the new eviction is inserted.
- A victim hit swaps data and metadata with the selected L1 way. A dirty victim
  hit therefore does not require an immediate lower-memory write.

This deferred write-back behavior is the central baseline mechanism for
reducing conflict-miss penalties without losing dirty data.

## Victim Cache

The victim cache is fully associative and compares aligned line addresses in
parallel. It stores valid, dirty, prefetched, address, and complete-line data
for each entry. Replacement is round-robin.

On a demand victim hit:

1. the victim line is promoted to the selected L1 way;
2. a valid L1 replacement is moved into the hit victim slot;
3. an invalid L1 way causes the victim slot to become invalid; and
4. the CPU operation is applied to the promoted line.

The testbench verifies victim rescue for both direct-mapped and 2-way
configurations, and verifies that a dirty line eventually reaches backing
memory after victim-cache replacement pressure.

## Next-Line Prefetch and Monitoring

After a demand fill, the cache queues the next aligned line. The prefetch runs
only when `ST_IDLE` sees no CPU request, so demand traffic has priority. A line
already present in L1 or the victim cache is not fetched again.

The monitor exports:

| Counter | Meaning |
| --- | --- |
| `stat_prefetch_fills` | Prefetch lines installed in L1 |
| `stat_prefetch_useful` | Prefetched lines later consumed by a CPU request |
| `stat_prefetch_useless` | Unused prefetched lines finally overwritten in the victim cache |
| `stat_prefetch_pollution` | Prefetch allocations that displace a demand L1 line |
| `stat_prefetch_dropped` | Built-in candidates dropped because its one-entry queue was full |

`stat_prefetch_pollution` is a hardware proxy for pressure, not proof of a
performance loss: the displaced line may still be rescued by the victim cache.
Final workload analysis must correlate it with miss count, memory traffic, and
AMAT.

### Adaptation interface

`cfg_prefetch_enable` is the runtime master switch.
`cfg_next_line_enable` enables only the built-in next-line candidate generator.
Disabling the built-in generator clears its pending candidate so re-enabling
does not issue an address learned in an earlier workload phase.
An external policy can submit aligned or unaligned candidate addresses using
`ext_prefetch_valid`, `ext_prefetch_ready`, and `ext_prefetch_addr`; the cache
aligns accepted candidates to a line.

One-cycle event outputs report CPU access/hit/miss, victim hit, write-back, and
prefetch fill/useful/useless/pollution/drop events. They are intended for a
future adaptive controller and verification monitor. The cumulative counters
remain available for software-visible or end-of-run statistics.

See `docs/literature_review.md` for the research rationale and limitations of
direct L1 prefetch insertion.

## Preliminary Icarus Verification

Run:

```bash
./scripts/run_iverilog.sh
```

The script compiles and runs deterministic directed tests, memory-interface
backpressure, CPU-response backpressure, handshake payload stability checks,
a 160-operation randomized golden-memory scoreboard, and three
synthetic-workload configurations:

| Configuration | Covered behavior | Result on 2026-06-10 |
| --- | --- | --- |
| Direct-mapped, VC4, prefetch off | hit/miss, write-allocate, byte stores, victim hit, dirty preservation, randomized traffic | PASS |
| 2-way, VC4, prefetch off | same checks with way replacement and backpressure | PASS |
| 2-way, VC8, prefetch off | 8-entry victim replacement and dirty preservation | PASS |
| 2-way, VC4, prefetch on | next-line fill, victim rescue of prefetched data, external injection, usefulness accounting | PASS |
| Direct-mapped, VC4, prefetch off | five synthetic boundary profiles | PASS |
| 2-way, VC4, prefetch off | five synthetic boundary profiles | PASS |
| 2-way, VC4, prefetch on | five synthetic boundary profiles and prefetch boundary assertions | PASS |
| 2-way, VC4, prefetch off | text trace replay, writes, byte strobes, golden-memory checking | PASS |

Generated `.vvp` files and logs are written under `sim/`. Icarus emits a known
informational message about constant selects in `always_*`; compilation and
all self-checking tests complete successfully.

Each workload emits one machine-readable `WORKLOAD_RESULT` line.
`scripts/summarize_workloads.sh` collects these records into the ignored
`sim/workload_results.csv`. The recorded fields include accesses, hits,
misses, victim hits, accepted lower-memory reads and writes, prefetch events,
and elapsed testbench cycles.

## Vivado Verification

The batch flow was executed successfully on June 10, 2026 with Vivado
2024.2.1 targeting `xc7a35tcpg236-1`. The local macOS host still uses Icarus
for preliminary regression; final XSim and synthesis were run on a remote
Windows installation. All seven XSim configurations completed with
`ALL TESTS PASSED`:

| XSim configuration | Result |
| --- | --- |
| Direct-mapped, VC4, prefetch off | PASS |
| 2-way, VC4, prefetch off | PASS |
| 2-way, VC8, prefetch off | PASS |
| 2-way, VC4, next-line prefetch on | PASS |
| Direct-mapped, VC4 synthetic workloads | PASS |
| 2-way, VC4 synthetic workloads | PASS |
| 2-way, VC4 prefetch synthetic workloads | PASS |

Run the same flow on a machine with Vivado in `PATH` using:

```tcl
vivado -mode batch -source scripts/run_vivado.tcl
```

The script defaults to `xc7a35tcpg236-1`; set environment variable
`L1D_PART` to override the FPGA part. It runs the four functional simulations
plus the three synthetic-workload simulations, then synthesizes the four
hardware configurations with the 10 ns clock constraint. Reports are
generated under
`build/vivado/reports/<configuration>/`:

- `utilization.rpt`;
- `timing_summary.rpt`;
- `power.rpt`.

Simulation logs are copied to `build/vivado/reports/`. The June 10 synthesis
results are:

| Configuration | LUTs | FFs | RAMB36 | WNS at 10 ns | Approx. post-synth Fmax | Vectorless power |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Direct-mapped, VC4, prefetch off | 1,502 | 1,493 | 2 | 1.876 ns | 123.1 MHz | 0.100 W |
| 2-way, VC4, prefetch off | 1,839 | 1,621 | 4 | 1.525 ns | 118.0 MHz | 0.099 W |
| 2-way, VC8, prefetch off | 2,081 | 2,262 | 4 | 1.366 ns | 115.8 MHz | 0.103 W |
| 2-way, VC4, prefetch on | 1,900 | 1,750 | 4 | 2.112 ns | 126.8 MHz | 0.104 W |

All configurations meet the 100 MHz synthesis constraint. The data arrays
were inferred as block RAM; tag arrays were inferred as distributed RAM. The
Fmax column is calculated as `1000 / (10 - WNS)` and is only a post-synthesis
STA estimate. Routing and implementation can reduce it.

The power values use Vivado vectorless activity propagation, with no SAIF/VCD
activity file, default operating conditions, and `Low` confidence. They are
useful only as early relative estimates. The very high top-level I/O count
also makes these figures unsuitable as board-level power predictions.

On Windows, use an ASCII-only project path. Vivado simulation worked under a
Chinese user profile, but the synthesis child process could not reopen the
project when its path contained non-ASCII characters.

Before final project sign-off, inspect XSim waveforms for every FSM path and
run implementation/post-route timing. For meaningful power comparison, rerun
`report_power` with representative switching activity from the workload
traces.

## Workload-Driven Boundary Analysis

### Benchmark basis

SPEC CPU 2017 remains a compatibility and comparison baseline. SPEC CPU 2026,
released on May 5, 2026, is the primary current suite. The official SPEC pages
describe 43 CPU 2017 benchmarks and 52 CPU 2026 benchmarks, each organized as
integer/floating-point and speed/rate suites.

Sources:

- [SPEC CPU 2017](https://www.spec.org/cpu2017/)
- [SPEC CPU 2026](https://www.spec.org/cpu2026/)

Both suites are licensed products. SPEC CPU 2026 offers a free academic
license to eligible accredited institutions, requested by a professor or
full-time staff member. Benchmark source or proprietary input data must never
be committed to this repository.

### Trace-based RTL method

Running complete SPEC programs directly in an RTL testbench is impractical.
The planned method is:

1. build and run licensed SPEC workloads on a host or architectural simulator;
2. capture committed load/store traces with address, size, write data where
   allowed, and instruction count or timestamp;
3. anonymize addresses to preserve set/index/offset behavior while removing
   proprietary data;
4. replay bounded regions through the cache CPU interface;
5. compare configurations with victim cache and prefetch independently on and
   off; and
6. publish only derived statistics and legally redistributable trace metadata.

The reusable replay driver is selected with `+TRACE=<path>`. Its line format
is:

```text
# comments begin with #
0 ADDRESS
1 ADDRESS DATA WRITE_STROBE
```

Fields are hexadecimal except the decimal opcode: `0` is a 32-bit aligned
read and `1` is a 32-bit aligned write. The write strobe contains one bit per
byte. Reads are checked against the testbench golden memory; writes update the
golden memory after cache completion. Blank and comment lines are ignored.
For example:

```bash
vvp sim/two_way_vc4.vvp +TRACE=traces/smoke.trace
```

Run this command from the repository root. Relative ASCII paths avoid a known
Icarus plusarg limitation when an absolute workspace path contains non-ASCII
characters. A SPEC extraction tool must convert committed accesses into this
cache-interface format, align or split accesses as required, and omit
licensed data values when redistribution is not permitted.

### gem5-based extraction notes

The repository now includes repo-local helper scripts for a gem5-assisted
trace flow without placing config files in `~/gem5`:

- `scripts/gem5_trace_capture.py`: a standalone gem5 SE-mode config that
  attaches `CommMonitor` and `MemTraceProbe` to the data side of a
  `TimingSimpleCPU`;
- `scripts/convert_gem5_packet_trace.py`: converts the decoded gem5 packet
  trace into this repository's replay format for read-only regions.
- `scripts/convert_gem5_write_trace.py`: converts a committed-store ASCII
  write trace into the RTL replay format for mixed read/write studies.

Example WSL flow:

```bash
cd /mnt/d/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su

~/gem5/build/X86/gem5.opt \
    scripts/gem5_trace_capture.py \
    --cmd /path/to/workload \
    --options "workload arguments" \
    --trace-file /mnt/d/470/470p/1/L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su/traces/workload.ptrc.gz \
    --max-ticks 1000000000

python3 ~/gem5/util/decode_packet_trace.py \
    traces/workload.ptrc.gz \
    traces/workload_packet.csv

python3 scripts/convert_gem5_packet_trace.py \
    traces/workload_packet.csv \
    traces/workload_readonly.trace

vvp sim/two_way_vc4.vvp +TRACE=traces/workload_readonly.trace
```

Important limitation: stock gem5 packet traces do not store write payload
bytes or write strobes. That means they are sufficient for:

- address-stream studies;
- read-only or mostly-read bounded regions; and
- early victim-cache/prefetch sensitivity exploration.

They are not sufficient for full replay of mixed read/write regions into the
current RTL testbench format. For write-containing traces, one of the
following is required:

1. add a small gem5 instrumentation patch that logs store data bytes at
   commit or at the data-cache request interface;
2. create a read-only filtered region where writes are excluded by design; or
3. extend the RTL replay path to support address-only stores with an external
   memory-image checkpoint, if that approximation is acceptable for the study.

For this project, the safest near-term method is to use gem5 packet traces to
identify and extract read-dominant windows first, then add a small
payload-capturing hook only if mixed read/write replay becomes necessary.

The committed-store logger, when implemented in gem5, should emit:

```text
tick op addr size wstrb data [pc]
```

The `data` field is raw bytes in little-endian order, and the converter will
split each record on 32-bit boundaries while preserving the byte enables.

### Workload classes

The boundary study must include:

- sequential streaming and dense-array regions, expected to favor next-line
  prefetching;
- fixed-stride regions, swept from one word to multiple cache capacities;
- pointer-chasing and graph-like regions, expected to provide low next-line
  accuracy;
- conflict-focused regions mapping multiple active lines to one set, expected
  to demonstrate victim-cache benefit; and
- mixed load/store regions with dirty working sets, stressing deferred
  write-back bandwidth.

### Executable synthetic boundary tests

The preliminary testbench implements five deterministic profiles before
licensed SPEC traces are available:

- `sequential_stream`: one access per consecutive line;
- `stride_two_lines`: every other line, so a next-line prefetch is not used;
- `localized_two_line_loop`: repeated temporal reuse of two adjacent lines;
- `same_set_conflict_thrash`: `NUM_WAYS+1` lines mapping to one set; and
- `irregular_pointer_chase`: a fixed non-adjacent permutation of line
  addresses.

The tests assert counter conservation (`hits + misses = accesses`), expected
next-line usefulness or non-usefulness, stable localized hits, and victim
retention of the complete conflict working set. They are synthetic
microbenchmarks, not substitutes for SPEC traces.

The 2-way VC4 preliminary results on June 10, 2026 were:

| Profile | Prefetch | Hits | Misses | Victim hits | Memory reads | Useful | Useless | Cycles |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Sequential stream | Off | 0 | 12 | 0 | 12 | 0 | 0 | 128 |
| Sequential stream | On | 6 | 6 | 0 | 12 | 6 | 0 | 129 |
| Two-line stride | Off | 0 | 12 | 0 | 12 | 0 | 0 | 133 |
| Two-line stride | On | 0 | 12 | 0 | 24 | 0 | 6 | 227 |
| Localized loop | Off | 10 | 2 | 0 | 2 | 0 | 0 | 63 |
| Localized loop | On | 11 | 1 | 0 | 2 | 1 | 0 | 63 |
| Same-set conflict | Off | 0 | 12 | 9 | 3 | 0 | 0 | 79 |
| Irregular pointer chase | Off | 0 | 12 | 0 | 12 | 0 | 0 | 133 |
| Irregular pointer chase | On | 0 | 12 | 0 | 24 | 0 | 6 | 227 |

These results demonstrate the intended boundary rather than a general
performance claim. With this blocking implementation, next-line prefetching
converts half of the sequential demand accesses into hits but does not reduce
the total lower-memory reads. For the non-adjacent stride and pointer profiles,
it doubles lower-memory reads and increases cycles without removing a demand
miss. The victim cache retains the three-line, single-set working set for the
2-way configuration, so only the first three accesses reach lower memory.

For each trace region, record:

- CPU accesses, L1 hits, demand misses, and victim hits;
- lower-memory reads and write-backs;
- useful, useless, and pollution prefetch events;
- cycles, stall cycles, and measured AMAT;
- working-set size, load/store ratio, stride histogram, and reuse-distance
  summary; and
- the full cache configuration and random/trace seed.

The key boundary plots should sweep associativity, victim entries (0/4/8 in
the final comparison), prefetch enable, cache capacity, line size, and lower
memory latency. The present RTL requires at least one victim entry; a true
zero-entry bypass configuration is future work.

## Current Limitations and Next Steps

- One CPU request can be outstanding; there are no MSHRs or hit-under-miss.
- The lower memory interface has no error response and no write acknowledgment.
- Replacement is round-robin rather than true LRU.
- Prefetching is best-effort and can starve under continuous demand traffic.
- Counter overflow is modulo 32 bits.
- Coherence, atomics, fences, flush/invalidate commands, ECC, and unaligned
  accesses spanning words or lines are outside this baseline.
- XSim behavioral regression and post-synthesis reports are complete;
  waveform review, implementation/post-route timing, and activity-based power
  analysis remain required for final sign-off.
