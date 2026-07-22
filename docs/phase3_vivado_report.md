# Phase 3 Vivado Verification Report

## Deployment Closure (2026-07-22)

This section supersedes the July 13 performance and PPA conclusion while
retaining the older evidence below as history. The current deployment profile
is `l1d_cache_deploy` with `ENABLE_PREFETCH=0`. Full P3 and P3-lite are
explicit research configurations, not defaults.

### Correctness and evidence integrity

The closure fixed the prefetch lifecycle before measuring it:

- controller token/cost accounting is charged only on an actual PF lower-
  memory request handshake;
- a late merge receives causal shadow credit rather than a timing proxy;
- a response returning after runtime disable is discarded instead of
  installed;
- candidate address/generation snapshots remain stable across FIFO-head
  turnover, and suppression is emitted before same-edge cancellation so every
  sidecar event retains the correct sequence identity; and
- the PF scheduler is registered S0 capture/S1 issue, with request valid and
  address held stable for arbitrary lower-memory backpressure; and
- an explicit lower-port ownership grant prevents a state-owned demand read or
  write-back from being misclassified and charged as a PF handshake.

The exact 5,028-access sqlite gap-4 reproduction passed with 1,425 candidates,
1,425 admissions/cancellations, 1,033 unsafe suppressions, and 392 same-line
coalesces. The complete single-lane matrix then finished with
`MATRIX_ALL_PASS`: all 26 campaigns were executed afresh. Every campaign
validated 50 runs/25 exact pairs, except full P3's
100 runs/25 pairs including its standalone geometry controls. No run reported
a watchdog, protocol, duplicate-line, or lifecycle-conservation failure.

### Replay conclusion

| Variant | Off cycles | On cycles | Delta | Byte overhead | Harmful / neutral / helpful | Issued / merged / installed |
| --- | ---: | ---: | ---: | ---: | --- | ---: |
| legacy | 850,547 | 850,547 | 0 | 0% | 0 / 25 / 0 | 0 / 0 / 0 |
| P1 | 850,547 | 850,547 | 0 | 0% | 0 / 25 / 0 | 0 / 0 / 0 |
| P2 | 850,547 | 850,547 | 0 | 0% | 0 / 25 / 0 | 0 / 0 / 0 |
| full P3 | 850,547 | 850,546 | -1 | 0% | 4 / 16 / 5 | 508 / 508 / 0 |
| P3-lite | 850,547 | 850,578 | +31 | 0% | 9 / 8 / 8 | 1,301 / 1,301 / 0 |

Full P3's 0.000118% improvement and P3-lite's 0.003645% slowdown both fail
the required 1% improvement. P3-lite has only 16/25 non-slow windows versus a
20/25 requirement. It passes zero bandwidth overhead, maximum per-window
slowdown, and zero PF-caused write-back gates. Tuning does not change the
decision: the best `PF_ON_REFILL=16` sweep point still adds 17 cycles.

Sensitivity exposes why a single main timing model is insufficient. Legacy
prefetch increases cycles by 33.66%, 33.66%, 25.48%, 14.10%, and 0.74% under
sequential and fixed-gap 1/2/4/8 producers, with 53.80% byte overhead. P3-lite
safely suppresses or cancels those opportunities and stays byte-neutral, but
does not produce an improvement. At zero-bubble latency 0 it is neutral; at
latency 8 it adds 9 cycles with periodic ready and 146 cycles with
deterministic-random ready.

### OOC synthesis and structural attribution

All configurations use two ways, four sets, 16-byte lines, VC4, and the same
deployment seam unless the row explicitly names the legacy top.

| Configuration | LUTs | FFs | WNS at 10 ns | Vectorless dynamic |
| --- | ---: | ---: | ---: | ---: |
| `optimized_pf0_deploy` (VC swap format) | 6,048 | 2,047 | +0.363 ns | 0.023 W |
| `optimized_pf0_deploy_vc_lookup` | 5,647 | 2,034 | -0.675 ns | 0.015 W |
| `p3_research` | 9,740 | 4,817 | -5.186 ns | 0.044 W |
| `p3_deploy` | 9,488 | 3,928 | -5.404 ns | 0.042 W |
| `p3_no_shadow_proxy` | 9,048 | 3,161 | -6.123 ns | 0.042 W |
| `p3_lite_mshr_fixed` | 10,055 | 3,095 | -5.896 ns | 0.040 W |
| `stream_detector_only` | 7,302 | 2,549 | -5.688 ns | 0.021 W |
| `legacy_matched` | 5,349 | 2,074 | -2.007 ns | 0.014 W |

`VC_FORMAT_IN_SWAP=1` costs 401 LUTs and 13 registers relative to lookup-stage
formatting, but improves WNS by 1.038 ns and is the only PF0 OOC variant to
meet the 10 ns setup constraint. It is therefore the retained formatter.

Hierarchical OOC utilization isolates the dominant speculative structures:

| Configuration / module | LUTs | FFs |
| --- | ---: | ---: |
| P3 deploy controller | 264 | 73 |
| P3 deploy shadow | 368 | 741 |
| P3 deploy stream detector | 1,006 | 414 |
| P3-lite controller | 8 | 5 |
| P3-lite stream detector | 977 | 414 |
| stream-only controller | 6 | 5 |
| stream-only detector | 882 | 414 |

Constant folding removes nearly all controller and shadow state in P3-lite,
yet area and WNS remain far outside the gate. The stream detector and its
candidate logic are therefore a structural limit under the current interface,
not a parameter-tuning problem.

### Independent post-route implementation and activity power

The scalar-I/O FPGA harness eliminates the earlier impossible raw-cache I/O
top. Each row was independently synthesized, placed, and routed with a 10 ns
clock; SAIF was generated by its matching deploy-profile simulation.

| Configuration | LUTs | FFs | WNS | WHS | Activity dynamic | Matched nets |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `optimized_pf0_deploy` | 751 | 748 | -0.407 ns | +0.118 ns | 0.008 W | 128 / 1,646 |
| `p3_deploy` | 3,593 | 3,146 | -3.721 ns | +0.019 ns | 0.020 W | 565 / 7,525 |
| `p3_lite_mshr_fixed` | 2,955 | 2,280 | -4.169 ns | +0.065 ns | 0.015 W | 575 / 5,804 |
| `legacy_matched` | 1,259 | 1,411 | -0.444 ns | +0.106 ns | 0.008 W | 488 / 2,956 |

All four rows are hold-clean and have zero unconstrained paths, but all fail
setup. Against PF0, P3-lite adds 66.25% OOC LUTs, 51.20% OOC FFs, 87.5%
activity dynamic power, and yields a -36.154% achieved-Fmax execution-time
proxy. The hardware gate therefore fails every required item except hold and
constraint completeness.

The final remote execution exited 0. Its `l1d-vivado-evidence-v3` manifest
validated 15 XSim logs, eight OOC syntheses, four implementations, required
VCD/SAIF/checkpoint/report artifacts, and 121 downloaded log/report files with
zero findings. The combined evaluator decision is
`DISABLE_DEPLOY_PREFETCH_STRUCTURAL_LIMIT`; a failed design gate is recorded
as an experimental result, not as a collector failure. Public address-free
evidence is in
[`evidence/2026-07-22-prefetch-ppa/`](evidence/2026-07-22-prefetch-ppa/README.md).

## Historical Evidence Status (2026-07-13)

The 2026-07-01 simulation/PPA and SPEC tables below are historical. Simulation
used `NUM_SETS=4`, whereas synthesis silently used the RTL default
`NUM_SETS=8`; direct-mapped versus two-way replay also changed L1 capacity.
The SPEC traces were full-system multi-vCPU captures and are not attributable
to the named benchmarks. These tables must not be used for controlled
associativity, benchmark, or final PPA claims. Replacement evidence must use a
single explicit geometry record shared by Icarus, XSim, synthesis, timing, and
power.

The current replacement now meets that rule. The stale-free Vivado run and the
private process-attributable SPEC capture/replay/analyzer chain all report
`PASS`. The historical tables remain invalid and are retained only as history.

## Historical Optimized P3 Verification Status (2026-07-13)

The adaptive direct-L1 implementation has passed the local Icarus matrix,
directed P3 regression, true zero-bubble replay, and 82 Python analyzer/runner
tests. The Vivado flow has been upgraded to compile the wrapper with
`PREFETCH_POLICY=1`, `PF_OPT_LEVEL=3`, validate schema-3 records, run eight OOP
workload points plus three directed auxiliary XSim tops, and synthesize the
four controlled geometries.

The final local main-profile replay passed 100/100 runs and 25/25 exact pairs
for each of legacy, P1, P2, and P3. P3 changed aggregate cycles from 850,547
to 849,823 (`-724`), kept total bytes unchanged, produced 18 helpful and seven
neutral windows with no harmful window, merged all 544 issued prefetches, and
caused no dirty write-back. The public roll-up is
[here](evidence/2026-07-13-optimized/README.md).

The sequential, fixed-gap 1/2/4/8, latency-0/always-ready, and
latency-8/deterministic-random sensitivity campaigns also passed all 700 runs
and 350 exact pairs. P3 had zero byte overhead in every profile. It was neutral
in all sequential/fixed-gap windows and saved 570 and 859 aggregate cycles in
the latency-0 and latency-8 zero-bubble profiles respectively. The final local
regression comprised ten cache simulations, 20/20 workload rows, 62 P3 MSHR
checks, ten optimized edge scenarios, 76 stream/controller checks, and 82
Python tests; all passed.

The optimized remote campaign also reports `PASS`. Vivado 2024.2.1 produced
11 XSim logs: eight class-based OOP workload points and three directed
auxiliary tops. The eight OOP logs contain 83 `WORKLOAD_RESULT schema=3` rows;
every row reports `status=PASS`, zero watchdog/protocol/duplicate-line errors,
and closed candidate/admit/issue/return/install/merge/discard/cancel lifecycle
conservation at drain. The auxiliary logs report 76 stream/controller checks,
62 PF-MSHR checks, and the optimized P3 edge scenarios as passing. The same
run synthesized four controlled configurations and downloaded all 12 expected
utilization/timing/power reports. The evidence manifest was generated at
`2026-07-13T06:58:25.192439Z`, reports `PASS` with no findings, records remote
exit status 0 and no download failures, and hashes the Vivado log, journal,
and a 901,858-byte representative VCD. Here `PASS` means that simulation,
lifecycle, flow-completion, and artifact validation passed; it does not mean
that the 100 MHz timing constraint closed.

The OOP workload matrix uses the sequential producer; it is functional and
lifecycle evidence, not a zero-bubble performance measurement. True
zero-bubble behavior is exercised across Icarus and XSim by the directed
`tb_l1d_cache_optimized_p3` test (`p3_prefetch_edges` in the remote matrix).
The performance claims above remain based on the local true-zero-bubble,
25-window trace campaign, not on the sequential OOP rows.

All four optimized-wrapper configurations contain 128 bytes of logical L1
data. Their current post-synthesis reports are:

| Configuration | Slice LUTs | LUT as memory | FFs | Block RAM tiles | Bonded IOB / available | WNS at 10 ns | Approx. Fmax | Vectorless power | Dynamic | Static |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `dm_s8_vc4_pf0` | 5,679 | 57 | 2,897 | 2 | 1,447 / 106 | -1.019 ns | 90.752 MHz | 0.124 W | 0.053 W | 0.070 W |
| `2w_s4_vc4_pf0` | 7,137 | 372 | 3,214 | 0 | 1,447 / 106 | -2.130 ns | 82.440 MHz | 0.125 W | 0.055 W | 0.070 W |
| `2w_s4_vc8_pf0` | 7,891 | 372 | 4,227 | 0 | 1,447 / 106 | -2.500 ns | 80.000 MHz | 0.128 W | 0.058 W | 0.070 W |
| `2w_s4_vc4_pf1` | 10,882 | 372 | 4,757 | 0 | 1,510 / 106 | -9.342 ns | 51.701 MHz | 0.139 W | 0.068 W | 0.070 W |

The matching P3 enable comparison is `2w_s4_vc4_pf1` versus
`2w_s4_vc4_pf0`:

| Metric | Matching PF0 | P3 PF1 | PF1 - PF0 |
| --- | ---: | ---: | ---: |
| Slice LUTs | 7,137 | 10,882 | +3,745 (+52.473%) |
| FFs | 3,214 | 4,757 | +1,543 (+48.009%) |
| LUT as memory | 372 | 372 | 0 |
| Block RAM tiles | 0 | 0 | 0 |
| Bonded IOB | 1,447 | 1,510 | +63 (+4.354%) |
| WNS at 10 ns | -2.130 ns | -9.342 ns | -7.212 ns |
| Approx. Fmax | 82.440 MHz | 51.701 MHz | -30.739 MHz (-37.287%) |
| Total vectorless power | 0.125 W | 0.139 W | +0.014 W (+11.200%) |
| Dynamic power | 0.055 W | 0.068 W | +0.013 W (+23.636%) |

These numbers are estimates from synthesis, not implementation or post-route
sign-off. Every configuration fails 100 MHz setup timing, although all four
hold checks pass. The cache interface is exposed directly as the synthesis
top, so the reported 1,447 or 1,510 bonded I/Os exceed the selected device's
106 I/Os; the design is not a placeable board-level top in this form. Power
uses vectorless activity propagation and has `Low` confidence, so it does not
replace an activity-driven power run. The large optimized PF1 area and timing
cost is therefore a valid post-synthesis comparison against its matching PF0,
but not a post-route implementation result.

## Prior Legacy Replacement Evidence (2026-07-13)

The replacement flow uses remote Vivado 2024.2.1, part
`xc7a35tcpg236-1`, a 10 ns constraint, and the same explicit geometry in XSim
and synthesis. `scripts/run_vivado.tcl` deletes the prior report directory
before each run. The earlier remote runner also cleared the local download and
required exactly eight simulation logs and four synthesis directories with
utilization/timing/power reports, checks every `WORKLOAD_RESULT schema=2` row
for geometry, timing, `PASS`, and zero watchdog/protocol/duplicate-line
errors, and writes `build/vivado/evidence_manifest.json` with source and
artifact SHA-256 values.

The stale-report-free 2026-07-13 execution exited with status 0 and scanned
exactly 22 log/report files: eight simulation logs, twelve synthesis reports,
the Vivado log, and the Vivado journal. The representative VCD was validated
and hashed separately. Validation found no stale or missing report and wrote a
`PASS` manifest whose parsed clock period is 10.0 ns.

The tracked [redacted Vivado manifest](evidence/vivado-2026-07-13.json) has
SHA-256
`3182fe968485c01dcbafd6e82a08dfc5e1c2ec0869f440a230af7f493ce44bab`.
It preserves all input, simulation, synthesis, report, and artifact hashes;
only the remote execution command and absolute launcher path are redacted. Its
private source manifest has SHA-256
`879d61773f47ebdd06c2971d29da99d975d93d5ca6c76afb7dc7f918711d328b`.
The [public provenance index](evidence/2026-07-13/provenance.json) records the
privacy audit and private-artifact exclusions.

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
comparing direct-mapped and 2-way behavior. The prior legacy post-synthesis reports
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

The representative legacy waveform is
`build/vivado/reports/2w_s4_vc4_pf1.vcd`.

The attributable private SPEC campaign also passed on 2026-07-13. It covered
four benchmarks, five timed commands, 25 sampled windows, and 100 four-point
replays. Analyzer validation accepted 25 exact prefetch off/on pairs.

| Accuracy | L1 coverage | Lower coverage | Bandwidth overhead | Bytes on-off | Service cycles on-off | Harmful / neutral / helpful |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 0.215690268 | 0.049647522 | 0.067245888 | 0.537997464 | 672,032 | 328,996 | 25 / 0 / 0 |

These are sampled blocking-model results, not whole-program CPU timing. The
address-free outputs are the [aggregate CSV](evidence/2026-07-13/aggregate.csv),
[pair CSV](evidence/2026-07-13/pairs.csv),
[classification CSV](evidence/2026-07-13/classification.csv), and
[cycle-delta SVG](evidence/2026-07-13/cycles-on-minus-off.svg).

Licensed traces and private manifests remain outside Git. The historical SPEC
tables below are not part of the replacement evidence.

## Historical 2026-07-01 Evidence

### Historical Summary

This report records the Phase 3 workload-driven Vivado evidence collected on
2026-07-01. The run used remote Vivado 2024.2.1 on `192.168.1.101`, staged
under the ASCII Windows path `C:/Users/<remote-user>/l1d_codex_ascii_20260701_r10`.
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

The current RTL supports the frozen next-line baseline, adaptive direct-L1
stream prefetching, external candidate injection, shadow feedback, and one PF
MSHR. The broader placement/replacement policy matrix remains a design gap:

- no `3:1` or `7:1` capacity reservation policy, because the current RTL only
  supports `NUM_WAYS=1` or `NUM_WAYS=2` and has no group-level slot
  indirection;
- no whole-cache greedy prefetch pool;
- no separate prefetch buffer or direct victim-cache prefetch placement;
- no LRU or pointer-based replacement option;
- paired replay sidecars now provide true L1/lower-memory help and pollution,
  but PF events have no shared transaction identity for a per-prefetch
  candidate/issue/return latency distribution; and
- post-route timing and activity-based power are now complete and fail the
  deployment gates; manual all-path waveform review and any architectural
  redesign remain future work.

The historical invalid campaign covered labels `708`, `721`, `767`, and
`777`; it is not benchmark-attributable. The process-attributable replacement
campaign for those four benchmarks completed and passed on 2026-07-13. `723`
stays outside the requested set.
