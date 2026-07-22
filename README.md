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

The research replay runner defaults to optimized P3, true zero-bubble
production, and schema 3. Deployment uses the separate `l1d_cache_deploy`
seam, whose default is `ENABLE_PREFETCH=0`; P3 and P3-lite are opt-in research
profiles.

The July 22 closure reran the complete local matrix as one serial lane. All 26
campaigns were executed afresh and passed their run, pair,
sidecar, lifecycle, watchdog, protocol, and duplicate-line checks. On the main
25-window profile, full P3 changed aggregate service cycles from 850,547 to
850,546 (`-1`), while the deployable P3-lite profile changed them to 850,578
(`+31`). Both had zero byte overhead and zero prefetch-caused write-backs, but
neither met the required 1% aggregate improvement; P3-lite had only 16/25
non-slow windows.

The matching remote Vivado 2024.2.1 campaign passed evidence collection with
15 XSim logs, eight OOC synthesis configurations, four independent post-route
implementations, activity-based power reports, and no manifest findings. The
P3-lite comparison against optimized PF0 measured +66.25% OOC LUTs, +51.20%
OOC FFs, -4.169 ns post-route WNS, and +87.5% activity-based dynamic power.
Only hold timing and the no-unconstrained-path check passed. The combined gate
therefore records `DISABLE_DEPLOY_PREFETCH_STRUCTURAL_LIMIT`.

Address-free CSVs, the redacted gate result, and provenance hashes are in the
[July 22 evidence package](docs/evidence/2026-07-22-prefetch-ppa/README.md).
The [Phase 3 Vivado report](docs/phase3_vivado_report.md) records the exact
PPA table and explains why the research prefetch structures remain disabled
by default.

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
and adjacent CSV/SVG/provenance files. The July 13 optimized result is also
retained as historical evidence, but the July 22 rerun supersedes its
performance and PPA conclusions.
Licensed traces, addresses, logs, sidecars, and private manifests remain ignored.
The [public provenance index](docs/evidence/2026-07-13/provenance.json) records
their hashes and exclusions; the [prior legacy redacted Vivado manifest](docs/evidence/vivado-2026-07-13.json)
records the earlier eight-simulation/four-synthesis evidence matrix without
overwriting that historical conclusion.

The capture contract, private manifest chain, geometry matrix, and validity
limits are documented in `docs/l1d_baseline.md` and
`docs/spec2026_trace_campaign.md`.
