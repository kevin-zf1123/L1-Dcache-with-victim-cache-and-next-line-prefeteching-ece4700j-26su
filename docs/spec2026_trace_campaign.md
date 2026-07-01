# SPEC CPU 2026 Trace Campaign

## Scope

This document records the licensed SPEC CPU 2026 trace campaign for Phase 3.
English documentation is authoritative. Full uncompressed raw captures remain
local under `build/spec2026/`; compressed replay window samples are checked in
under `traces/spec2026/` through Git LFS for test reuse.

The campaign used SPEC default base optimization from
`config/codex-gcc-linux-riscv64.cfg`, which is derived from
`Example-gcc-linux-riscv64.cfg` and compiles with `-g -O3 -march=rv64gc`.

Benchmarks captured:

- `708.sqlite_r`
- `721.gcc_r`
- `767.nest_r`
- `777.zstd_r`

`723.llvm_r` was intentionally skipped after the user narrowed the campaign
because it overlaps the compiler behavior already represented by `721.gcc_r`.

## Commands

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

By default, `scripts/run_spec_trace_replay.sh` reads the LFS-tracked compressed
samples in `traces/spec2026/`, decompresses them into
`build/spec2026/replay/decompressed/`, and replays those local temporary
`.trace` files. Passing an explicit sample directory still works for
uncompressed `.trace` files.

## Capture Manifest

Each benchmark produced one startup-after-warmup sample of 10,000 payload
trace lines and four later in-run samples of 5,000 payload trace lines. The
capture windows were:

```text
10000:10000;50000:5000;100000:5000;200000:5000;400000:5000
```

Every raw benchmark trace reported `captured=30000`, `valid_seen=405000`,
and all five windows reached the requested line count. The `speccmds.cmd` and
`compare.cmd` phases both exited with `rc=0` for every benchmark.

Compressed sample files are tracked in `traces/spec2026/` via Git LFS. The
same uncompressed SHA-256 values below are also listed with compressed file
hashes in `traces/spec2026/MANIFEST.md`.

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

## Replay Results

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

## Findings

- Moving from direct-mapped VC4 to two-way VC4 improved hit rate by 7.5 to
  9.5 percentage points and reduced memory traffic for every captured SPEC
  benchmark.
- Increasing the victim cache from VC4 to VC8 did not change L1 hit rate, but
  it increased victim-hit rate and reduced memory accesses per demand by
  about 0.044 to 0.052 across the four benchmarks.
- The current direct-L1D next-line prefetch policy is mostly harmful on these
  SPEC samples. It raises hit rate by only -0.26 to +1.36 percentage points
  versus two-way VC4, while increasing memory accesses per demand by +0.196 to
  +0.344 and cycles per access by +1.51 to +2.60.
- `767.nest_r` is the clearest harmful prefetch case in this set: next-line
  prefetch slightly reduces hit rate versus two-way VC4, increases
  memory/access from 0.5517 to 0.8954, and raises cycles/access from 7.31 to
  9.91.
