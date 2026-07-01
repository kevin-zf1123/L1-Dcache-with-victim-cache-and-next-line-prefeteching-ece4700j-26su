# Phase 3 Vivado Verification Report

## Summary

This report records the Phase 3 workload-driven Vivado evidence collected on
2026-07-01. The run used remote Vivado 2024.2.1 on `192.168.1.101`, staged
under the ASCII Windows path `C:/Users/kevin/l1d_codex_ascii_20260701_r10`.
The Vivado Tcl source was passed as a Windows `C:/...` path, and the remote
password was not stored in repository files or logs.

The final remote flow exited with status 0, downloaded the simulation logs,
waveform, utilization, timing, and vectorless power reports, and scanned 22
downloaded log/report files without finding `ERROR:`, `CRITICAL WARNING:`,
`FATAL`, source failures, or testbench failures.

The licensed SPEC CPU 2026 campaign also completed for `708.sqlite_r`,
`721.gcc_r`, `767.nest_r`, and `777.zstd_r` using SPEC default O3 base
optimization. `723.llvm_r` was skipped after the user narrowed the requested
scope because it overlaps the compiler behavior represented by `721.gcc_r`.

## Implemented Phase 3 Changes

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

## Vivado Matrix

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

## Workload Coverage

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
Uncompressed raw SPEC captures remain local under `build/spec2026/`; compressed
window samples for replay testing are checked in under `traces/spec2026/`
through Git LFS.

## Prefetch Boundary Results

The medium-latency `next_line_prefetch_vc4` run shows the intended boundary:

| Workload | Hits | Misses | Victim hits | Mem reads | Read bytes | Useful | Useless | Pollution | Accuracy | Coverage | Cycles |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `matrix_row_major` | 8 | 8 | 0 | 16 | 256 | 8 | 0 | 4 | 100.00% | 50.00% | 174 |
| `matrix_column_major` | 0 | 16 | 8 | 16 | 256 | 8 | 0 | 0 | 100.00% | 50.00% | 193 |
| `matrix_blocked_tiled` | 8 | 8 | 0 | 16 | 256 | 8 | 0 | 4 | 100.00% | 50.00% | 174 |
| `pointer_random_permutation` | 4 | 12 | 1 | 19 | 304 | 5 | 1 | 5 | 62.50% | 31.25% | 208 |
| `pointer_irregular_defeats_next_line` | 0 | 24 | 0 | 48 | 768 | 0 | 18 | 10 | 0.00% | 0.00% | 474 |
| `external_prefetch_matrix_candidates` | 8 | 0 | 0 | 8 | 128 | 8 | 0 | 0 | 100.00% | 100.00% | 100 |

Compared with the no-prefetch two-way VC4 baseline, next-line prefetch turns
half of the row-major and blocked/tiled demand accesses into hits, but it does
not reduce lower-memory reads in this blocking implementation. The irregular
pointer chase is harmful: memory reads double from 24 to 48 and cycles grow
from 275 to 474 at the medium-latency setting.

## SPEC CPU 2026 Trace Campaign

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

The SPEC samples reinforce the synthetic workload boundary result. Two-way
associativity consistently improves hit rate versus direct-mapped VC4.
Increasing the victim cache from VC4 to VC8 does not change the L1 hit rate,
but it reduces memory accesses per demand by about 0.044 to 0.052 and reduces
cycles per access in every SPEC benchmark. The current next-line prefetch
policy is mostly harmful for these samples: it provides at most a small hit-rate
gain, slightly hurts `767.nest_r`, and increases memory/access by +0.196 to
+0.344 versus the two-way VC4 no-prefetch baseline.

## Synthesis and Power

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

## Waveform Artifact

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
- no true pollution attribution, prefetch timeliness, or full latency
  distribution beyond the current min/max/average fields;
- no demand-caused versus prefetch-caused dirty write-back split; and
- no post-route timing or activity-based power analysis.

The SPEC CPU 2026 campaign covers `708`, `721`, `767`, and `777`. `723` remains
outside the executed set by the user's narrowed scope, not because of a tooling
blocker.
