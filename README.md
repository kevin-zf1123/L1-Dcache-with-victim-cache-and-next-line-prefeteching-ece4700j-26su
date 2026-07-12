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

The authoritative July 13 run completed five command captures, 25 sampled
windows, 100 four-configuration replays, and 25 exact prefetch off/on pairs.
The capture campaign, replay campaign, and analyzer all reported `PASS`.

All 25 pairs had positive `cycles_on_minus_off` in the blocking service-cycle
model. This is a replay-model result, not a whole-program CPU timing claim.

Address-free public results are the [aggregate metrics](docs/evidence/2026-07-13/aggregate.csv),
[per-pair metrics](docs/evidence/2026-07-13/pairs.csv),
[classification](docs/evidence/2026-07-13/classification.csv), and
[cycle-delta plot](docs/evidence/2026-07-13/cycles-on-minus-off.svg).
Licensed traces, addresses, logs, sidecars, and private manifests remain ignored.
The [public provenance index](docs/evidence/2026-07-13/provenance.json) records
their hashes and exclusions; the [redacted Vivado manifest](docs/evidence/vivado-2026-07-13.json)
records the final eight-simulation/four-synthesis evidence matrix.

The capture contract, private manifest chain, geometry matrix, and validity
limits are documented in `docs/l1d_baseline.md` and
`docs/spec2026_trace_campaign.md`.
