# L1-Dcache-with-victim-cache-and-next-line-prefeteching-ece4700j-26su
Design and Evaluation of a High-Performance L1 Data Cache with Victim Cache and Next-Line Prefetching

## RV64 QEMU VM

The project-local `debian-rv64/` image is used only through `-snapshot`, so
capture does not modify its base disk or UEFI variables. Licensed SPEC inputs
and all derived addresses remain below the ignored `build/` tree.

Build the QEMU 11.0.1 / Plugin API 6 host plugin:

```bash
scripts/build_qemu_memtrace_plugin.sh
```

Then run the fail-closed capture and manifest-driven replay flow:

```bash
python3 scripts/capture_spec_qemu_windows.py \
  --out-dir build/spec2026/qemu-private \
  --size test --label codexrv64 \
  708.sqlite_r 721.gcc_r 767.nest_r 777.zstd_r
scripts/run_spec_trace_replay.sh \
  build/spec2026/qemu-private/campaign_manifest.json \
  build/spec2026/replay/logs
```

The runner now defaults to optimized P3, true zero-bubble production, and
schema 3. The final July 13 main profile completed 100 four-configuration
replays and 25 exact prefetch off/on pairs. P3 saved 724 aggregate service
cycles with zero byte overhead; all 25 windows were non-degrading. Address-free
results are in the [optimized evidence package](docs/evidence/2026-07-13-optimized/README.md).

The final optimized remote Vivado 2024.2.1 campaign also passed. It validated
11 XSim logs containing 83 schema-3 workload rows with closed prefetch
lifecycle conservation, and produced four synthesis configurations with all
12 utilization/timing/power reports. The OOP workload matrix uses a sequential
producer; cross-simulator true-zero-bubble behavior is covered by the directed
optimized-P3 test, while the performance conclusion above comes from the local
true-zero-bubble trace campaign. Current post-synthesis PPA, the matching PF1
versus PF0 deltas, and the setup/I/O/vectorless-power limitations are recorded
in the [Phase 3 Vivado report](docs/phase3_vivado_report.md).

To reproduce the frozen sequential legacy baseline instead, select its policy,
producer, and schema explicitly:

```bash
L1D_PREFETCH_POLICY=0 L1D_PF_OPT_LEVEL=0 \
L1D_PRODUCER_PROFILE=sequential L1D_SIDECAR_SCHEMA=2 \
scripts/run_spec_trace_replay.sh \
  build/spec2026/qemu-private/campaign_manifest.json \
  build/spec2026/replay-legacy/logs
```

That legacy experiment increased service cycles in all 25 pairs. Its public
artifacts remain in the [historical aggregate](docs/evidence/2026-07-13/aggregate.csv)
and adjacent CSV/SVG/provenance files.
Licensed traces, addresses, logs, sidecars, and private manifests remain ignored.
The [public provenance index](docs/evidence/2026-07-13/provenance.json) records
their hashes and exclusions; the [prior legacy redacted Vivado manifest](docs/evidence/vivado-2026-07-13.json)
records the earlier eight-simulation/four-synthesis evidence matrix without
overwriting that historical conclusion.

The capture contract, private manifest chain, geometry matrix, and validity
limits are documented in `docs/l1d_baseline.md` and
`docs/spec2026_trace_campaign.md`.
