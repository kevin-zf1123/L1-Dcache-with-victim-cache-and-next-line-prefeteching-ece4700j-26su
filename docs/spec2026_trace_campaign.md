# SPEC CPU 2026 Trace Campaign

## Validity Status (2026-07-13)

The campaign recorded below is retained only as historical evidence of the
legacy replay flow. It is **not valid benchmark-attributable evidence**:

- QEMU ran four vCPUs and the plugin serialized all vCPU callbacks into one
  single-cache stream;
- tracing was enabled by a different process and did not filter privilege or
  address-space context;
- 108,387 of the 120,000 retained payload accesses (90.323%) use RISC-V Linux
  kernel virtual-address ranges; and
- direct-mapped and two-way replay points did not hold L1 capacity constant.

Consequently, the benchmark-labelled tables and findings below must not be
cited as sqlite, gcc, nest, or zstd behavior. They describe only four legacy
full-system capture sessions. A replacement campaign is accepted only when a
target-process marker binds one U-mode SATP context on one vCPU, replay uses
physical addresses, simulation and PPA share complete geometry, and every
manifest/run/pair conservation check passes. Licensed raw and derived traces
remain local-only; the public repository contains only sanitized evidence.

## Scope

This document records the licensed SPEC CPU 2026 trace campaign for Phase 3.
English documentation is authoritative. All licensed raw and replay-derived
captures remain local under ignored `build/spec2026/`. No licensed sample is
tracked by the public repository and none may be recommitted.

The campaign used SPEC default base optimization from
`config/codex-gcc-linux-riscv64.cfg`, which is derived from
`Example-gcc-linux-riscv64.cfg` and compiles with `-g -O3 -march=rv64gc`.

Legacy session labels (not benchmark-attributable):

- `708.sqlite_r`
- `721.gcc_r`
- `767.nest_r`
- `777.zstd_r`

`723.llvm_r` was outside the user-narrowed label set for this historical run.

## Current Validated Workflow

The replacement flow uses QEMU 11.0.1 / Plugin API 6 in `riscv64` system
emulation with `-smp 1,maxcpus=1` and `-snapshot`. Each dynamic timed command
is wrapped by a versioned `a0..a5` ROI marker carrying a nonce, command index,
PID, and TID. The plugin binds vCPU 0, U privilege, and one non-Bare SATP,
filters and counts kernel/foreign-SATP accesses, records physical addresses,
redacts store data, and rejects incomplete or identity-ambiguous captures.
Before executing the target, `trace_exec` sets and verifies
`ADDR_NO_RANDOMIZE`; inability to disable target ASLR is fatal. This removes
address-layout-dependent pointer hashing from the count/capture control path.
Schema-3 raw rows retain each source operation and both physical endpoints.
The splitter maps an unaligned same-line operation to one byte-sized cache-line
touch and a cross-line operation to two touches after independently translating
the last byte; source and canonical replay counts remain separately auditable.
It independently rebinds context/start/stop/summary identity and requires every
payload row to carry the ROI's exact SATP, vCPU, and privilege.

From the repository root:

```sh
scripts/build_qemu_memtrace_plugin.sh
python3 scripts/capture_spec_qemu_windows.py \
  --out-dir build/spec2026/qemu-private \
  --size test --label codexrv64 \
  708.sqlite_r 721.gcc_r 767.nest_r 777.zstd_r
scripts/run_spec_trace_replay.sh \
  build/spec2026/qemu-private/campaign_manifest.json \
  build/spec2026/replay/logs
```

`capture_spec_qemu_windows.py` performs a source-event count pass and a fresh
snapshot capture pass per timed command. Long ROIs receive five source windows
of 5,000 warmup plus 5,000 measurement events; short ROIs are replayed whole.
Window manifests additionally record the canonical replay-access counts after
any cross-line expansion. In each snapshot, the runner clears every output
declared by SPEC's authoritative `compare.cmd`, runs one timed command, selects
exactly the comparisons for outputs that command produced (including side
outputs), and requires that subset to pass after ROI stop. The count and
capture passes must select byte-identical comparison subsets; their command
copies and logs are mandatory hashed artifacts. A benchmark plan hashes the
original `speccmds.cmd`, requires dense timed-command indices, and proves that
the per-command comparison subsets are disjoint and exactly cover the full
`compare.cmd` plan. It writes
hash-complete unit and campaign manifests below `build/spec2026/qemu-private`.
The evidence graph binds the QEMU executable, plugin, capture/split/build/start
sources, ROI sources, immutable base VM/QEMU firmware inputs, target ELF, and
every command/artifact by SHA-256. The complete temporary campaign graph is
validated before the authoritative PASS JSON is atomically published.
The replay runner consumes only that authoritative campaign, rejects stale,
missing, or extra windows, runs the following matrix, writes per-demand
sidecars with demand and prefetch issue/fill events, creates
`build/spec2026/replay/campaign_manifest.json` plus its SHA-256, and invokes
the strict analyzer automatically:

| config ID | sets | ways | line bytes | L1 bytes | victim entries | prefetch | role |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `dm_s8_vc4_pf0` | 8 | 1 | 16 | 128 | 4 | 0 | equal-capacity associativity baseline |
| `2w_s4_vc4_pf0` | 4 | 2 | 16 | 128 | 4 | 0 | off member of prefetch pair |
| `2w_s4_vc8_pf0` | 4 | 2 | 16 | 128 | 8 | 0 | victim-capacity baseline |
| `2w_s4_vc4_pf1` | 4 | 2 | 16 | 128 | 4 | 1 | on member of prefetch pair |

For direct analyzer use, the current CLI is:

```sh
python3 scripts/summarize_spec_replay.py \
  --manifest build/spec2026/replay/campaign_manifest.json \
  --out-dir build/spec2026/replay/analysis
```

The analyzer requires hashed traces, logs, sidecars, capture manifests,
simulation binaries, simulator, command/cwd identity, and exact command-to-
artifact path binding. It checks the declared per-window four-configuration
matrix, exact off/on pairing, counter and sidecar-event conservation, exact
trace/sidecar demand identity, zero protocol/watchdog/duplicate-line errors,
and sidecar-derived true L1/lower-memory help and pollution. `timely_useful=useful` and
`late_useful=0` are structural consequences of this blocking replay model,
not an independent prefetch-latency measurement.

Every validated pair also produces `classification.csv` and
`cycles-on-minus-off.svg`. Classification is deliberately one-dimensional:
`cycles_on_minus_off < 0` is helpful, zero is neutral, and a positive value is
harmful. Other metrics remain visible in the paired and aggregate tables and
do not silently change that label.

Current execution status: a real snapshot RV64 dynamic-ELF count/capture/split
smoke passed with matching totals and zero violations. The four licensed
benchmarks must still produce a complete private `PASS` campaign before any
new benchmark-labelled result is accepted.

## Historical Commands (Do Not Use)

The commands below reproduce only the retired mixed-system campaign and use
obsolete capture/replay interfaces. They are retained for provenance, not as
instructions.

Build and run setup were performed inside the Debian RV64 VM at
`/home/debian/spec2026`:

```sh
runcpu --action=build --config=codex-gcc-linux-riscv64 \
  --define gcc_dir=/usr --define build_ncpus=4 --define label=codexrv64 \
  --size=test --iterations=1 --tune=base --noreportable \
  708.sqlite_r 721.gcc_r

runcpu --action=build --config=codex-gcc-linux-riscv64 \
  --define gcc_dir=/usr --define build_ncpus=4 --define label=codexrv64 \
  --size=test --iterations=1 --tune=base --noreportable \
  767.nest_r 777.zstd_r

runcpu --action=runsetup --config=codex-gcc-linux-riscv64 \
  --define gcc_dir=/usr --define build_ncpus=4 --define label=codexrv64 \
  --size=test --iterations=1 --tune=base --noreportable \
  708.sqlite_r 721.gcc_r 767.nest_r 777.zstd_r
```

Trace capture used the local QEMU plugin and marker wrapper:

```sh
scripts/build_qemu_memtrace_plugin.sh
scripts/capture_spec_qemu_windows.py 708.sqlite_r 721.gcc_r 767.nest_r 777.zstd_r
```

Replay and summary used:

```sh
scripts/run_spec_trace_replay.sh
scripts/summarize_spec_replay.py build/spec2026/replay/logs \
  --csv build/spec2026/replay/spec_replay_summary.csv \
  --markdown build/spec2026/replay/spec_replay_summary.md
```

The retired runner used to scan LFS files under `traces/spec2026/`. Those
files no longer exist. The current runner deliberately refuses directory
scanning and accepts only an authoritative capture campaign manifest.

## Historical Capture Manifest (Invalid)

Each benchmark produced one startup-after-warmup sample of 10,000 payload
trace lines and four later in-run samples of 5,000 payload trace lines. The
capture windows were:

```text
10000:10000;50000:5000;100000:5000;200000:5000;400000:5000
```

Every raw benchmark trace reported `captured=30000`, `valid_seen=405000`,
and all five windows reached the requested line count. The `speccmds.cmd` and
`compare.cmd` phases both exited with `rc=0` for every benchmark.

These samples were historically stored through Git LFS. They are no longer
tracked or present in the public repository; the hashes below identify only
the invalid historical evidence.

| sample | payload lines | skip | requested lines | captured lines | sha256 |
| --- | ---: | ---: | ---: | ---: | --- |
| `spec2026_708_sqlite_r_test_w00_skip10000_n10000.trace` | 10000 | 10000 | 10000 | 10000 | `e2734306a7896d23128cd422737fbf560fefe12285f5a4b09669db29b04c33bc` |
| `spec2026_708_sqlite_r_test_w01_skip50000_n5000.trace` | 5000 | 50000 | 5000 | 5000 | `c6b96b0098a3c149893f076dacb2fae1de9fd032656e6b00d23da094aa3c1022` |
| `spec2026_708_sqlite_r_test_w02_skip100000_n5000.trace` | 5000 | 100000 | 5000 | 5000 | `139f07cdb2325476284e394ef273effef7fc4d0938926d8aa7674dae8f4ac7c5` |
| `spec2026_708_sqlite_r_test_w03_skip200000_n5000.trace` | 5000 | 200000 | 5000 | 5000 | `1a7ad0cf8f51839ee0b1afba29ef002453cdde0f43789c544ae65ede3a486c9a` |
| `spec2026_708_sqlite_r_test_w04_skip400000_n5000.trace` | 5000 | 400000 | 5000 | 5000 | `94b9804e03b6daecdcec0792c7420784c483f7c485c9bc4368e60cc4587d6c09` |
| `spec2026_721_gcc_r_test_w00_skip10000_n10000.trace` | 10000 | 10000 | 10000 | 10000 | `9a2960abeb6cde5323552dcf7bc9e58acafa0af43e97ada58edbca70e3b47d86` |
| `spec2026_721_gcc_r_test_w01_skip50000_n5000.trace` | 5000 | 50000 | 5000 | 5000 | `8f447569dccd89b52593258572b77dbfd685e36e4c6d4bafb981b10c4f36595c` |
| `spec2026_721_gcc_r_test_w02_skip100000_n5000.trace` | 5000 | 100000 | 5000 | 5000 | `1481a9af40a2724bc244e805612daf23d71fb0a93a72f130d4cd8723d851c9e8` |
| `spec2026_721_gcc_r_test_w03_skip200000_n5000.trace` | 5000 | 200000 | 5000 | 5000 | `d7e10e8a49067f442cd101274aa2bda2b62d5ca9f10d3d5eaf0e39084e92b73b` |
| `spec2026_721_gcc_r_test_w04_skip400000_n5000.trace` | 5000 | 400000 | 5000 | 5000 | `ead9d16d9150633030feb8a9a82fc9b75a2fa70f19d6d1f96fe2512cf8cbe7fe` |
| `spec2026_767_nest_r_test_w00_skip10000_n10000.trace` | 10000 | 10000 | 10000 | 10000 | `ab3cece5c983f63ee7ab41ab62cb1fb7c6fb9d02b9d243cb9bb21ab4692e2987` |
| `spec2026_767_nest_r_test_w01_skip50000_n5000.trace` | 5000 | 50000 | 5000 | 5000 | `2aeab176813bd9a577d17f96c60a8d5132965d411264b515153f63e6817a8af0` |
| `spec2026_767_nest_r_test_w02_skip100000_n5000.trace` | 5000 | 100000 | 5000 | 5000 | `cc39372f101c8bddedea72f1f6379bbe2cb8a76dcf2d7d7f01caab429062e131` |
| `spec2026_767_nest_r_test_w03_skip200000_n5000.trace` | 5000 | 200000 | 5000 | 5000 | `1d5492458ee0d92517b556d88e583579201c2afbaa3456dc8dc56c1f405a553c` |
| `spec2026_767_nest_r_test_w04_skip400000_n5000.trace` | 5000 | 400000 | 5000 | 5000 | `5b9e291e0ff2f1751b14b7c5e01235209ebb9d0d5d0d9bc2b9a02b723c7b7baa` |
| `spec2026_777_zstd_r_test_w00_skip10000_n10000.trace` | 10000 | 10000 | 10000 | 10000 | `e32fc5b9fb30edb0ece6236aaa1108159d46881cfdb353482ca9ace276c35a63` |
| `spec2026_777_zstd_r_test_w01_skip50000_n5000.trace` | 5000 | 50000 | 5000 | 5000 | `96b46c71cf98bc9b1471b666ccbb6daebebcb1ecce526aeac313060c11eb2ac0` |
| `spec2026_777_zstd_r_test_w02_skip100000_n5000.trace` | 5000 | 100000 | 5000 | 5000 | `3e8b9a2d72faa0d84da0735812bc5c798d50d47d01ce5cd094053f345d6f8c65` |
| `spec2026_777_zstd_r_test_w03_skip200000_n5000.trace` | 5000 | 200000 | 5000 | 5000 | `81b2a3ec67a874b83a1b521d5a743b11a71b11e7b9d3feaee234c364876224c4` |
| `spec2026_777_zstd_r_test_w04_skip400000_n5000.trace` | 5000 | 400000 | 5000 | 5000 | `7afab0ca928947442111e2b39739e803c493d115cd1717486e8708a0eeab4c84` |

## Historical Replay Results (Invalid)

All 20 samples were replayed through four cache configurations:

- `direct_mapped_vc4`
- `two_way_vc4`
- `two_way_vc8`
- `next_line_prefetch_vc4`

All 80 Icarus replay logs reported `ALL TESTS PASSED`; load-data checking was
disabled with `+TRACE_SKIP_LOAD_CHECKS` because the samples begin in the
middle of real program execution and do not include the complete initial
memory image.

| benchmark | config | accesses | hit rate | victim hit rate | mem/access | cycles/access | prefetch accuracy | useful | useless | pollution |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 708.sqlite_r | direct_mapped_vc4 | 30000 | 0.4808 | 0.1097 | 0.5933 | 7.58 | 0.0000 | 0 | 0 | 0 |
| 708.sqlite_r | two_way_vc4 | 30000 | 0.5762 | 0.0586 | 0.5319 | 7.22 | 0.0000 | 0 | 0 | 0 |
| 708.sqlite_r | two_way_vc8 | 30000 | 0.5762 | 0.0912 | 0.4865 | 7.01 | 0.0000 | 0 | 0 | 0 |
| 708.sqlite_r | next_line_prefetch_vc4 | 30000 | 0.5829 | 0.0579 | 0.8150 | 9.42 | 0.2011 | 1647 | 6543 | 5384 |
| 721.gcc_r | direct_mapped_vc4 | 30000 | 0.5057 | 0.0797 | 0.6027 | 7.60 | 0.0000 | 0 | 0 | 0 |
| 721.gcc_r | two_way_vc4 | 30000 | 0.5824 | 0.0463 | 0.5452 | 7.27 | 0.0000 | 0 | 0 | 0 |
| 721.gcc_r | two_way_vc8 | 30000 | 0.5824 | 0.0779 | 0.5017 | 7.06 | 0.0000 | 0 | 0 | 0 |
| 721.gcc_r | next_line_prefetch_vc4 | 30000 | 0.5960 | 0.0502 | 0.8037 | 9.32 | 0.2214 | 1745 | 6137 | 5341 |
| 767.nest_r | direct_mapped_vc4 | 30000 | 0.4849 | 0.0780 | 0.6317 | 7.74 | 0.0000 | 0 | 0 | 0 |
| 767.nest_r | two_way_vc4 | 30000 | 0.5672 | 0.0530 | 0.5517 | 7.31 | 0.0000 | 0 | 0 | 0 |
| 767.nest_r | two_way_vc8 | 30000 | 0.5672 | 0.0889 | 0.5000 | 7.07 | 0.0000 | 0 | 0 | 0 |
| 767.nest_r | next_line_prefetch_vc4 | 30000 | 0.5646 | 0.0435 | 0.8954 | 9.91 | 0.1787 | 1662 | 7636 | 6494 |
| 777.zstd_r | direct_mapped_vc4 | 30000 | 0.6226 | 0.0806 | 0.4419 | 6.90 | 0.0000 | 0 | 0 | 0 |
| 777.zstd_r | two_way_vc4 | 30000 | 0.6976 | 0.0437 | 0.3865 | 6.59 | 0.0000 | 0 | 0 | 0 |
| 777.zstd_r | two_way_vc8 | 30000 | 0.6976 | 0.0796 | 0.3353 | 6.35 | 0.0000 | 0 | 0 | 0 |
| 777.zstd_r | next_line_prefetch_vc4 | 30000 | 0.7097 | 0.0417 | 0.5829 | 8.10 | 0.2175 | 1268 | 4563 | 3724 |

## Historical Findings (Do Not Cite by Benchmark)

- Across the four legacy benchmark-labelled mixed-system streams, moving from
  direct-mapped VC4 to two-way VC4 changed the measured hit rate by +7.5 to
  +9.5 percentage points and reduced measured memory traffic. This cannot be
  attributed to the named programs.
- Increasing the victim cache from VC4 to VC8 did not change L1 hit rate, but
  it increased victim-hit rate and reduced memory accesses per demand by
  about 0.044 to 0.052 across the four invalid label groups.
- The current direct-L1D next-line prefetch policy is mostly harmful on these
  mixed streams. It changes hit rate by -0.26 to +1.36 percentage points
  versus two-way VC4, while increasing memory accesses per demand by +0.196 to
  +0.344 and cycles per access by +1.51 to +2.60.
- The mixed stream carrying the legacy `767.nest_r` label had the largest
  negative delta in this invalid table: memory/access changed from 0.5517 to
  0.8954 and cycles/access from 7.31 to 9.91. This says nothing reliable about
  `767.nest_r` itself.
