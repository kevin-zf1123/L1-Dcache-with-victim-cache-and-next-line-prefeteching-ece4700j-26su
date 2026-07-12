# Phase 3 Vivado Verification Report

## Evidence Status (2026-07-13)

The 2026-07-01 simulation/PPA and SPEC tables below are historical. Simulation
used `NUM_SETS=4`, whereas synthesis silently used the RTL default
`NUM_SETS=8`; direct-mapped versus two-way replay also changed L1 capacity.
The SPEC traces were full-system multi-vCPU captures and are not attributable
to the named benchmarks. These tables must not be used for controlled
associativity, benchmark, or final PPA claims. Replacement evidence must use a
single explicit geometry record shared by Icarus, XSim, synthesis, timing, and
power.

## Current Replacement Evidence (2026-07-13)

The replacement flow uses remote Vivado 2024.2.1, part
`xc7a35tcpg236-1`, a 10 ns constraint, and the same explicit geometry in XSim
and synthesis. `scripts/run_vivado.tcl` deletes the prior report directory
before each run. `scripts/run_remote_vivado.py` also clears the local download,
requires exactly eight simulation logs and four synthesis directories with
utilization/timing/power reports, checks every `WORKLOAD_RESULT schema=2` row
for geometry, timing, `PASS`, and zero watchdog/protocol/duplicate-line
errors, and writes `build/vivado/evidence_manifest.json` with source and
artifact SHA-256 values.

The stale-report-free 2026-07-13 execution exited with status 0 and scanned
exactly 22 log/report files: eight simulation logs, twelve synthesis reports,
the Vivado log, and the Vivado journal. The representative VCD was validated
and hashed separately. Validation found no stale or missing report and wrote a
`PASS` manifest whose parsed clock period is 10.0 ns.

The eight simulation points are:

| Configuration | Geometry / timing |
| --- | --- |
| `dm_s8_vc4_pf0` | 1 way, 8 sets, 16-byte line, VC4, prefetch off, latency 2, periodic backpressure |
| `2w_s4_vc4_pf0` | 2 ways, 4 sets, 16-byte line, VC4, prefetch off, latency 2, periodic backpressure |
| `2w_s4_vc8_pf0` | 2 ways, 4 sets, 16-byte line, VC8, prefetch off, latency 2, periodic backpressure |
| `2w_s4_vc4_pf1` | 2 ways, 4 sets, 16-byte line, VC4, prefetch on, latency 2, periodic backpressure |
| `trace_replay_smoke_2w_s4_vc4_pf0` | redistributable smoke replay at the matching 2-way geometry |
| `trace_replay_generated_pointer_2w_s4_vc4_pf1` | generated pointer replay at the matching prefetch geometry |
| `2w_s4_vc4_pf1_low_latency` | prefetch on, latency 0, no memory backpressure |
| `2w_s4_vc4_pf1_high_latency_random_bp` | prefetch on, latency 8, randomized memory backpressure |

All four main L1s contain 128 bytes; this isolates logical L1 capacity when
comparing direct-mapped and 2-way behavior. The current post-synthesis reports
are:

| Configuration | LUTs | FFs | Block RAM tiles | WNS at 10 ns | Approx. Fmax | Vectorless power | Dynamic | Static |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `dm_s8_vc4_pf0` | 5,189 | 1,852 | 2 | -1.581 ns | 86.3 MHz | 0.114 W | 0.044 W | 0.070 W |
| `2w_s4_vc4_pf0` | 5,699 | 2,246 | 0 | -2.068 ns | 82.9 MHz | 0.106 W | 0.035 W | 0.070 W |
| `2w_s4_vc8_pf0` | 5,783 | 3,004 | 0 | -1.516 ns | 86.8 MHz | 0.106 W | 0.036 W | 0.070 W |
| `2w_s4_vc4_pf1` | 6,222 | 2,407 | 0 | -1.626 ns | 86.0 MHz | 0.111 W | 0.041 W | 0.070 W |

These are post-synthesis estimates and all miss the 100 MHz constraint. The
Fmax estimate is `1000 / (10 - WNS)`. Power is vectorless and `Low`
confidence. Vivado inferred two block-RAM tiles for the 8-set direct-mapped
arrays, but mapped each 4-set-per-way 2-way array into distributed logic and
registers. Consequently, logical capacity is controlled but FPGA primitive
mapping is not: LUT/FF/timing differences cannot be attributed solely to
associativity. A physically matched experiment would need an explicit common
RAM style or primitive mapping.

The representative current waveform is
`build/vivado/reports/2w_s4_vc4_pf1.vcd`. Licensed SPEC performance remains
unvalidated until the new private, attributable capture campaign passes; the
historical SPEC tables below are not part of this replacement evidence.

## Historical 2026-07-01 Evidence

### Historical Summary

This report records the Phase 3 workload-driven Vivado evidence collected on
2026-07-01. The run used remote Vivado 2024.2.1 on `192.168.1.101`, staged
under the ASCII Windows path `C:/Users/kevin/l1d_codex_ascii_20260701_r10`.
The Vivado Tcl source was passed as a Windows `C:/...` path, and the remote
password was not stored in repository files or logs.

The final remote flow exited with status 0, downloaded the simulation logs,
waveform, utilization, timing, and vectorless power reports, and scanned 22
downloaded log/report files without finding `ERROR:`, `CRITICAL WARNING:`,
`FATAL`, source failures, or testbench failures.

The legacy full-system capture sessions carried the labels `708.sqlite_r`,
`721.gcc_r`, `767.nest_r`, and `777.zstd_r` and used SPEC default O3 base
optimization. They completed mechanically but are not attributable to those
benchmarks. `723.llvm_r` was outside the user-narrowed label set.

### Historical Implemented Phase 3 Changes

- Added `scripts/run_remote_vivado.py` for Paramiko-based upload, ASCII remote
  staging, Windows-path Tcl invocation, report download, and log scanning.
- Added `src/tb_l1d_cache_oop.sv`, a class-based Vivado harness with CPU
  driver, memory model, scoreboard, monitor, workload sequence library, trace
  replay, and `WORKLOAD_RESULT` reporting.
- Added deterministic generated replay traces in `traces/generated/` with
  SHA-256 hashes documented in `traces/generated/MANIFEST.md`.
- Added debug FSM outputs to `src/l1d_cache.sv` so the OOP monitor can report
  state-aware protocol and watchdog failures.
- Fixed the replacement path so an evicted L1 line is invalidated when copied
  into the victim cache, eliminating transient duplicate valid lines before the
  incoming fill installs.
- Added static duplicate-line checks in the Vivado OOP harness; every workload
  now reports `duplicate_lines`.
- Added QEMU memory-trace window capture and replay helpers for licensed SPEC
  CPU 2026 samples: `scripts/capture_spec_qemu_windows.py`,
  `scripts/run_spec_trace_replay.sh`, `scripts/split_qemu_memtrace_windows.py`,
  and `scripts/summarize_spec_replay.py`.

### Historical Vivado Matrix

All eight XSim configurations passed:

| Configuration | Key parameters | Evidence |
| --- | --- | --- |
| `direct_mapped_vc4` | `NUM_WAYS=1`, prefetch off, VC4, latency 2, deterministic memory backpressure | `build/vivado/reports/direct_mapped_vc4_simulation.log` |
| `two_way_vc4` | `NUM_WAYS=2`, prefetch off, VC4, latency 2, deterministic memory backpressure | `build/vivado/reports/two_way_vc4_simulation.log` |
| `two_way_vc8` | `NUM_WAYS=2`, prefetch off, VC8, latency 2, deterministic memory backpressure | `build/vivado/reports/two_way_vc8_simulation.log` |
| `next_line_prefetch_vc4` | `NUM_WAYS=2`, next-line prefetch on, VC4, latency 2, deterministic memory backpressure | `build/vivado/reports/next_line_prefetch_vc4_simulation.log` |
| `trace_replay_smoke_two_way_vc4` | smoke trace replay, prefetch off | `build/vivado/reports/trace_replay_smoke_two_way_vc4_simulation.log` |
| `trace_replay_generated_pointer_prefetch_vc4` | generated pointer trace replay, next-line prefetch on | `build/vivado/reports/trace_replay_generated_pointer_prefetch_vc4_simulation.log` |
| `next_line_prefetch_vc4_low_latency` | next-line prefetch on, latency 0, no memory backpressure | `build/vivado/reports/next_line_prefetch_vc4_low_latency_simulation.log` |
| `next_line_prefetch_vc4_high_latency_random_bp` | next-line prefetch on, latency 8, randomized memory backpressure | `build/vivado/reports/next_line_prefetch_vc4_high_latency_random_bp_simulation.log` |

Every `WORKLOAD_RESULT` row in the final run reports `status=PASS`,
`watchdogs=0`, `protocol=0`, and `duplicate_lines=0`.

### Historical Workload Coverage

The OOP harness covers:

- directed RV64 load/store sizes, sign and zero extension, high-address tags,
  and misaligned response behavior;
- dirty victim replacement and write-back preservation;
- CPU response backpressure;
- matrix row-major, column-major, blocked/tiled, same-set pressure beyond L1,
  same-set pressure beyond L1 plus victim capacity, and store-heavy dirty
  matrix updates;
- pointer random permutation, victim-cache conflict chain, irregular
  next-line-defeating chase, and mixed load/store pointer updates;
- deterministic external prefetch candidate injection; and
- smoke and generated pointer trace replay.

Generated trace artifacts are redistributable synthetic traces, not licensed
SPEC traces:

| Trace | Lines | SHA-256 |
| --- | ---: | --- |
| `phase3_matrix_row_major.trace` | 64 | `400ed1afb8775561e46c10856461fffa13b5bbc6a0ab57f33887d9b8c06f0445` |
| `phase3_matrix_column_major.trace` | 64 | `ae8a522c6c87328ba93c4472ab37fbffa20daacbdbf00c211d1a6e99ca74c8bf` |
| `phase3_pointer_permutation.trace` | 64 | `5c8039c1e6a8f40d376fa2787a6ce85378ab07bcae8e115a51a980206ee50d08` |
| `phase3_pointer_mixed_update.trace` | 64 | `7e52cd734e4f9a36f7e30c4bef858853e0be15bb213fabebecca782ae6033c0e` |

Licensed SPEC sample hashes, sampling commands, replay commands, and detailed
aggregate results are recorded in `docs/spec2026_trace_campaign.md`.
All licensed raw and replay-derived SPEC samples remain local under ignored
`build/spec2026/`; they are not distributed through Git or Git LFS.

### Historical Prefetch Boundary Results

The medium-latency `next_line_prefetch_vc4` run shows the intended boundary:

Coverage below is paired baseline miss reduction, not `useful/accesses`;
workloads without a matching prefetch-off run report N/A.

| Workload | Hits | Misses | Victim hits | Mem reads | Read bytes | Useful | Useless | Pollution | Accuracy | Coverage | Cycles |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `matrix_row_major` | 8 | 8 | 0 | 16 | 256 | 8 | 0 | 4 | 100.00% | 50.00% | 174 |
| `matrix_column_major` | 0 | 16 | 8 | 16 | 256 | 8 | 0 | 0 | 100.00% | 0.00% | 193 |
| `matrix_blocked_tiled` | 8 | 8 | 0 | 16 | 256 | 8 | 0 | 4 | 100.00% | 50.00% | 174 |
| `pointer_random_permutation` | 4 | 12 | 1 | 19 | 304 | 5 | 1 | 5 | 62.50% | 25.00% | 208 |
| `pointer_irregular_defeats_next_line` | 0 | 24 | 0 | 48 | 768 | 0 | 18 | 10 | 0.00% | 0.00% | 474 |
| `external_prefetch_matrix_candidates` | 8 | 0 | 0 | 8 | 128 | 8 | 0 | 0 | 100.00% | N/A | 100 |

Compared with the no-prefetch two-way VC4 baseline, next-line prefetch turns
half of the row-major and blocked/tiled demand accesses into hits, but it does
not reduce lower-memory reads in this blocking implementation. The irregular
pointer chase is harmful: memory reads double from 24 to 48 and cycles grow
from 275 to 474 at the medium-latency setting.

### Historical SPEC CPU 2026 Trace Campaign (Invalid Attribution)

The SPEC campaign captured four requested subitems after O3 build and
test-size run setup:

| Benchmark | Samples | Replay rows | Status |
| --- | ---: | ---: | --- |
| `708.sqlite_r` | 5 | 20 | PASS |
| `721.gcc_r` | 5 | 20 | PASS |
| `767.nest_r` | 5 | 20 | PASS |
| `777.zstd_r` | 5 | 20 | PASS |

Each benchmark has one startup-after-warmup 10,000-line sample and four
later 5,000-line in-run samples. All raw captures reached `captured=30000`,
and all benchmark `speccmds.cmd` plus `compare.cmd` phases exited with `rc=0`.
All 80 Icarus replay logs reported `ALL TESTS PASSED`.

Aggregate replay metrics over the five samples per benchmark:

| Benchmark | Config | Hit rate | Victim hit rate | Mem/access | Cycles/access | Prefetch accuracy |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| `708.sqlite_r` | `direct_mapped_vc4` | 0.4808 | 0.1097 | 0.5933 | 7.58 | 0.0000 |
| `708.sqlite_r` | `two_way_vc4` | 0.5762 | 0.0586 | 0.5319 | 7.22 | 0.0000 |
| `708.sqlite_r` | `two_way_vc8` | 0.5762 | 0.0912 | 0.4865 | 7.01 | 0.0000 |
| `708.sqlite_r` | `next_line_prefetch_vc4` | 0.5829 | 0.0579 | 0.8150 | 9.42 | 0.2011 |
| `721.gcc_r` | `direct_mapped_vc4` | 0.5057 | 0.0797 | 0.6027 | 7.60 | 0.0000 |
| `721.gcc_r` | `two_way_vc4` | 0.5824 | 0.0463 | 0.5452 | 7.27 | 0.0000 |
| `721.gcc_r` | `two_way_vc8` | 0.5824 | 0.0779 | 0.5017 | 7.06 | 0.0000 |
| `721.gcc_r` | `next_line_prefetch_vc4` | 0.5960 | 0.0502 | 0.8037 | 9.32 | 0.2214 |
| `767.nest_r` | `direct_mapped_vc4` | 0.4849 | 0.0780 | 0.6317 | 7.74 | 0.0000 |
| `767.nest_r` | `two_way_vc4` | 0.5672 | 0.0530 | 0.5517 | 7.31 | 0.0000 |
| `767.nest_r` | `two_way_vc8` | 0.5672 | 0.0889 | 0.5000 | 7.07 | 0.0000 |
| `767.nest_r` | `next_line_prefetch_vc4` | 0.5646 | 0.0435 | 0.8954 | 9.91 | 0.1787 |
| `777.zstd_r` | `direct_mapped_vc4` | 0.6226 | 0.0806 | 0.4419 | 6.90 | 0.0000 |
| `777.zstd_r` | `two_way_vc4` | 0.6976 | 0.0437 | 0.3865 | 6.59 | 0.0000 |
| `777.zstd_r` | `two_way_vc8` | 0.6976 | 0.0796 | 0.3353 | 6.35 | 0.0000 |
| `777.zstd_r` | `next_line_prefetch_vc4` | 0.7097 | 0.0417 | 0.5829 | 8.10 | 0.2175 |

When the invalid mixed-system streams are grouped mechanically by their legacy
labels, two-way VC4 has higher measured hit rate than direct-mapped VC4, VC8
reduces measured memory accesses per demand by about 0.044 to 0.052, and
next-line prefetch increases memory/access by +0.196 to +0.344. These are
session-level historical statistics only. They neither reinforce a SPEC
workload claim nor establish behavior for any named benchmark, including
`767.nest_r`.

### Historical Synthesis and Power

Vivado synthesized the four main RTL configurations for `xc7a35tcpg236-1`
using the 10 ns clock constraint. These are post-synthesis estimates, not
post-route sign-off numbers.

| Configuration | LUTs | FFs | Block RAM tiles | WNS at 10 ns | Approx. post-synth Fmax | Vectorless power | Dynamic | Static |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Direct-mapped, VC4, prefetch off | 5,178 | 1,853 | 2 | -1.291 ns | 88.6 MHz | 0.117 W | 0.046 W | 0.070 W |
| 2-way, VC4, prefetch off | 4,721 | 2,008 | 4 | -0.417 ns | 96.0 MHz | 0.107 W | 0.036 W | 0.070 W |
| 2-way, VC8, prefetch off | 5,395 | 2,767 | 4 | -1.462 ns | 87.2 MHz | 0.117 W | 0.047 W | 0.070 W |
| 2-way, VC4, next-line prefetch on | 5,789 | 2,168 | 4 | -1.981 ns | 83.5 MHz | 0.117 W | 0.047 W | 0.070 W |

All four post-synthesis timing reports miss the 100 MHz target. The Fmax
column is calculated as `1000 / (10 - WNS)` and should be treated only as an
early estimate. Power uses Vivado vectorless activity propagation with no
SAIF/VCD switching activity file and `Low` confidence.

### Historical Waveform Artifact

The representative passing waveform is:

```text
build/vivado/reports/next_line_prefetch_vc4.vcd
```

The downloaded VCD is 611 KiB and includes the top clock plus DUT ports and
internal DUT signals such as CPU, memory, prefetch, statistics, and
`debug_state`.

## Remaining Gaps

The current RTL supports the direct-L1D next-line prefetch baseline and
external candidate injection. The broader Phase 2 policy matrix remains a
design gap:

- no `3:1` or `7:1` capacity reservation policy, because the current RTL only
  supports `NUM_WAYS=1` or `NUM_WAYS=2` and has no group-level slot
  indirection;
- no whole-cache greedy prefetch pool;
- no separate prefetch buffer or direct victim-cache prefetch placement;
- no LRU or pointer-based replacement option;
- paired replay sidecars now provide true L1/lower-memory help and pollution,
  but there is no independent issue/fill/accept timeliness measurement or full
  latency distribution beyond the current min/max/average fields;
- no demand-caused versus prefetch-caused dirty write-back split; and
- no post-route timing or activity-based power analysis.

The historical invalid campaign covered labels `708`, `721`, `767`, and
`777`; it is not benchmark-attributable. The replacement private campaign for
those four labels remains a required execution step. `723` stays outside the
requested set.
