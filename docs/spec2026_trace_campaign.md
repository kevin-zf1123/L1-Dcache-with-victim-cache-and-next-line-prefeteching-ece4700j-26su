# SPEC CPU 2026 Trace Campaign

## Validity Status (2026-07-13)

The campaign recorded later under the historical headings is retained only as
evidence of the legacy replay flow. It is **not valid benchmark-attributable
evidence**:

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

Replay sensitivity controls are fail-closed environment inputs:

| Variable | Default | Allowed values |
| --- | --- | --- |
| `L1D_REPLAY_SCOPE` | `full` | `full` four-config matrix or paired off/on only |
| `L1D_PREFETCH_POLICY` / `L1D_PF_OPT_LEVEL` | `1` / `3` | legacy `0/0`, optimized `1/1..3` |
| `L1D_PRODUCER_PROFILE` | `zero-bubble` | `sequential`, `zero-bubble`, `fixed-gap` |
| `L1D_PRODUCER_GAP` | `0` | fixed-gap `1`, `2`, `4`, or `8` |
| `L1D_MEM_LATENCY` | `2` | non-negative integer |
| `L1D_MEM_READY_MODE` | `periodic` | `always-ready`, `periodic`, `deterministic-random` |
| `L1D_SIDECAR_SCHEMA` | `3` | `2` or `3` |

The elaborated latency/ready values are also passed as runtime provenance
plusargs. The testbench rejects a mismatch, and each campaign manifest records
the derived timing profile.

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
and sidecar-derived true L1/lower-memory help and pollution. In the retained
schema-2 legacy campaign, `timely_useful=useful` and `late_useful=0` were
structural proxies. The optimized schema-3 campaign below replaces that proxy
with demand and PF lifecycle timing.

Every validated pair also produces `classification.csv` and
`cycles-on-minus-off.svg`. Classification is deliberately one-dimensional:
`cycles_on_minus_off < 0` is helpful, zero is neutral, and a positive value is
harmful. Other metrics remain visible in the paired and aggregate tables and
do not silently change that label.

## Optimized P0–P3 Campaign (2026-07-13)

The final optimized campaign reuses the same 25 attributable windows and equal
2-way, 4-set, 16-byte-line, VC4 paired geometry. It changes the producer to a
true zero-bubble source: request `i+1` remains valid while response `i` is
pending and transfers on the first ready edge. It also upgrades the sidecars
and result rows to schema 3, while the analyzer continues to accept historical
schema-2 evidence.

All four policy campaigns validated 100/100 runs and 25/25 exact pairs:

| Policy / level | Cycles off | Cycles on | Delta | Byte overhead | Harmful / neutral / helpful | PF issued / merged / installed | PF-caused WB |
| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: |
| Frozen legacy `0/0` | 850,547 | 850,547 | 0 | 0 | 0 / 25 / 0 | 0 / 0 / 0 | 0 |
| Safe next-line P1 `1/1` | 850,547 | 850,547 | 0 | 0 | 0 / 25 / 0 | 0 / 0 / 0 | 0 |
| Adaptive stream P2 `1/2` | 850,547 | 850,547 | 0 | 0 | 0 / 25 / 0 | 0 / 0 / 0 | 0 |
| Shadow + PF MSHR P3 `1/3` | 850,547 | **849,823** | **-724** | **0** | **0 / 7 / 18** | **544 / 544 / 0** | **0** |

P1 and P2 correctly refuse to consume a zero-bubble single-cycle opportunity
because their two-cycle idle guard cannot hide a blocking prefetch. P3 instead
uses response-cycle background issue only when the already-present next demand
matches the candidate and a tag-only L1/VC lookup proves it absent. All 544
issued reads merged with that same-line demand: demand-owned reads fell from
59,275 to 58,731, total read bytes remained 948,400, write bytes remained
300,736, and there were no speculative installs or attributed dirty
write-backs.

The P3 result passes the main-profile hard gates:

- aggregate cycle delta is negative;
- read+write bandwidth overhead is 0%, below 10%;
- 25/25 windows are non-degrading, exceeding the 20/25 requirement;
- maximum slowdown is 0% and the best window saves 80 cycles;
- prefetch-caused dirty write-back is zero; and
- P3 aggregate cycles are lower than legacy with equal bandwidth.

The complete paired sensitivity matrix also passed validation. The table
reports each policy's on-minus-off cycle delta; all P3 byte deltas and
prefetch-caused write-backs were zero.

The strengthened drain check also passed every schema-3 row: an admitted
request must issue or cancel before reporting, and every issue must return to
one install, merge, or discard outcome.

| Producer / memory profile | Legacy cycle delta | Legacy byte overhead | P3 cycle delta | P3 harmful / neutral / helpful | P3 issued / merged |
| --- | ---: | ---: | ---: | --- | ---: |
| Sequential, latency 2, periodic ready | +328,996 | +672,032 (53.80%) | 0 | 0 / 25 / 0 | 0 / 0 |
| Fixed gap 1, latency 2, periodic ready | +328,996 | +672,032 (53.80%) | 0 | 0 / 25 / 0 | 0 / 0 |
| Fixed gap 2, latency 2, periodic ready | +280,654 | +672,032 (53.80%) | 0 | 0 / 25 / 0 | 0 / 0 |
| Fixed gap 4, latency 2, periodic ready | +190,854 | +672,032 (53.80%) | 0 | 0 / 25 / 0 | 0 / 0 |
| Fixed gap 8, latency 2, periodic ready | +13,745 | +672,032 (53.80%) | 0 | 0 / 25 / 0 | 0 / 0 |
| Zero-bubble, latency 0, always ready | 0 | 0 | **-570** | 0 / 2 / 23 | 570 / 570 |
| Zero-bubble, latency 8, deterministic random ready | 0 | 0 | **-859** | 1 / 9 / 15 | 422 / 422 |

The optimized engine therefore spends no traffic in gaps that cannot hide a
request, while the frozen blocking engine still performs 44,193 speculative
reads in every sequential/fixed-gap profile. Under the latency-8 profile, the
single harmful P3 window was +71 cycles (+0.1282%), below the 5% guardrail;
the aggregate still saved 859 cycles. Across the main and all sensitivity
profiles, P3 cycles were lower than or equal to optimized-off and lower than
or equal to legacy, with equal or lower bandwidth. This interprets the
legacy-comparison gate as Pareto non-inferiority in bandwidth plus a strict
cycle improvement whenever legacy performs speculative work.

The address-free public results are in
[the optimized evidence directory](evidence/2026-07-13-optimized/README.md).
These results preserve, rather than replace, the harmful sequential legacy
baseline below. The separate optimized Vivado 2024.2.1 campaign has now passed:
11 XSim logs contain 83 schema-3 workload rows with closed lifecycle
conservation, and four synthesis configurations produced all 12 expected PPA
reports. Its OOP workload matrix uses the sequential producer; the directed
`tb_l1d_cache_optimized_p3` test supplies cross-simulator true-zero-bubble
coverage. Therefore the performance claim in this section still comes from
the local true-zero-bubble trace campaign, not from the OOP matrix. The
post-synthesis PPA and its setup-timing, I/O-overfull, and vectorless-power
limitations are reported in [the Phase 3 Vivado report](phase3_vivado_report.md).

## Legacy Next-Line Authoritative Baseline (2026-07-13)

The complete replacement flow passed. Four benchmark plans contain five timed-
command capture units and 25 sampled windows. Every count/capture snapshot and
SPEC comparison passed, and the top-level campaign validated before its PASS
manifest was atomically published. All 25 windows use `demand-warm-measure`:
5,000 prefetch-disabled warmup source events followed by 5,000 measurement
source events at the 10th, 30th, 50th, 70th, and 90th ROI percentiles. There
are no `whole-roi-short` windows in this campaign. Cross-line canonicalization
expands the 250,000 sampled source events to 250,971 replay accesses.

| benchmark | command | ROI source events | misaligned | cross-line | canonical accesses | sampled source→replay | selected compare IDs | full compare-plan SHA-256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
| `708.sqlite_r` | 0 | 568,742,855 | 6,684,478 | 3,232,848 | 571,975,703 | 50,000→50,259 | `[0]` | `3600fe4088d3967d4de7c1da062fd2534baf859c8a50d8a87b310f768b833f59` |
| `721.gcc_r` | 0 | 15,001,579 | 11,283 | 2,889 | 15,004,468 | 50,000→50,000 | `[0]` | `b9169d2aeee7689a5e5183a8a580665dd067a11b01a169821b83d27d3314af68` |
| `767.nest_r` | 0 | 1,109,373,742 | 167,455 | 14,757 | 1,109,388,499 | 50,000→50,000 | `[0,2]` | `30eeb5b41f4fa3f3491b3b29fc1018bd399cf3043ad20ff014177ab86a6ea4a4` |
| `767.nest_r` | 1 | 9,370,927,478 | 14,557 | 4,518 | 9,370,931,996 | 50,000→50,000 | `[1]` | `30eeb5b41f4fa3f3491b3b29fc1018bd399cf3043ad20ff014177ab86a6ea4a4` |
| `777.zstd_r` | 0 | 662,301,894 | 19,893,851 | 7,849,609 | 670,151,503 | 50,000→50,712 | `[0]` | `e7dbd4b27675c86bde1f74add3fdb88fc6cf3567c98c4fbb34ca91841cab8144` |

For `767.nest_r`, command 0 selects compare commands `[0,2]` and command 1
selects `[1]`; these subsets are disjoint and exactly cover its three-command
full comparison plan. The other three benchmarks each have one timed command
and one comparison.

Replay then completed the exact four-configuration matrix: 100/100 runs and
25/25 prefetch off/on pairs passed, with 50 of the runs serving as standalone
direct-mapped or VC8 controls. All hashed logs and sidecars were present;
watchdog, protocol, and duplicate-line counts were zero. The strict analyzer's
artifact, matrix, geometry/timing, counter-conservation, status, trace/sidecar
identity, and true-pollution delta checks all passed.

Across all 125,511 measured demand accesses, the controlled configuration
totals are:

| config ID | hit rate | victim-hit / access | demand reads / access | all reads / access | replay cycles / access |
| --- | ---: | ---: | ---: | ---: | ---: |
| `dm_s8_vc4_pf0` | 0.4528 | 0.0713 | 0.4759 | 0.4759 | 7.8261 |
| `2w_s4_vc4_pf0` | 0.4699 | 0.0578 | 0.4723 | 0.4723 | 7.7873 |
| `2w_s4_vc8_pf0` | 0.4699 | 0.0982 | 0.4319 | 0.4319 | 7.5258 |
| `2w_s4_vc4_pf1` | 0.4963 | 0.0632 | 0.4405 | 0.7926 | 10.4086 |

The equal-128-byte-L1 direct-mapped/2-way comparison therefore changes both
hit rate and replay cost only modestly in these sampled regions. VC8 leaves L1
hit rate unchanged while increasing victim rescues and reducing demand reads.
Next-line prefetch raises hit rate and reduces demand reads overall, but its
extra prefetch reads dominate total traffic and serialized replay cycles.

| benchmark | pairs | accuracy | L1 coverage | lower coverage | bandwidth overhead | cycles on−off | harmful / neutral / helpful |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `708.sqlite_r` | 5 | 25.70% | +5.49% | +7.32% | +45.98% | +61,554 | 5 / 0 / 0 |
| `721.gcc_r` | 5 | 13.62% | −0.63% | −2.64% | +62.39% | +80,784 | 5 / 0 / 0 |
| `767.nest_r` | 10 | 21.83% | +8.27% | +11.14% | +52.72% | +156,639 | 10 / 0 / 0 |
| `777.zstd_r` | 5 | 31.31% | −1.28% | +0.55% | +57.94% | +30,019 | 5 / 0 / 0 |
| **all** | **25** | **21.57%** | **+4.96%** | **+6.72%** | **+53.80%** | **+328,996** | **25 / 0 / 0** |

The paired sidecars identify 8,079 true L1-help events versus 4,776 true L1-
pollution events, and 9,018 lower-memory-help events versus 5,032 true lower-
memory-pollution events. Thus net miss coverage is positive overall, but every
sampled pair is harmful under the documented blocking replay-cycle criterion.
This is a policy-and-model result, not whole-program CPU time: the current
single-miss FSM serializes demand, prefetch, and write-back traffic.

The public [paired metrics](evidence/2026-07-13/pairs.csv) include per-window
load/store mix, stride, reuse distance, footprint, and set-pressure features.
Across the 25 windows, next-line stride fraction ranges from 0.0062 to 0.3793,
reuse-distance p90 from 8 to 156 unique lines, and set-access imbalance from
1.059 to 2.354. The [classification table](evidence/2026-07-13/classification.csv)
and [cycle-delta plot](evidence/2026-07-13/cycles-on-minus-off.svg) publish the
complete helpful/neutral/harmful result without exposing addresses.

Provenance anchors:

- public evidence and exclusion index:
  [provenance.json](evidence/2026-07-13/provenance.json);
- capture implementation commit: `2d144658ae69a80333ef7e94411b6cad924f49cf`;
- replay/parser commit: `d2c3a8d977135ded40c1bc9067cd0a5987e45888`;
- capture campaign SHA-256: `057965ff31234bac274ce81fc719780dbd2e7d60a59ccceb359b3b7ac64a7f9f`;
- capture replay-list SHA-256: `3eaf06a196b7eb6a34db814ae0815de0eb424a3dfd96e511684a25026642cb98`;
- replay campaign SHA-256: `e593bd279361036e4cb75c4cf9d1b959afb2071fb0d7c4ca1e425323a8f9cc78`;
- public pairs / aggregate / classification / SVG SHA-256:
  `f33ef79f760baaa1351df79349aa659c0a703fbdb9332da750a4c5e186f45c11`,
  `5cc709794c1e5d2b03e267f87df308a758d9bae34c1edf9c6a831d90776f1d5a`,
  `a25012f292b50ffc4143e261660c5d458bf439f8cc0f4033a182d597565b23b5`,
  and `8475251a909a609c384ac53f0bf8268b7bf12ad60b01d7bafeb0246bcf585ac6`.

The capture manifest records `dirty=true` because unrelated documentation
artifacts existed in the working tree. Every one of the 11 executable capture
inputs is individually hashed; their aggregate is
`409764c38342f3693e301f91e7ccda45ddc4eb9bbd09e770f6217a42baa3f161`.
Raw captures, addresses, command text, logs, and per-demand sidecars remain in
ignored private build directories and are not public evidence.

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
